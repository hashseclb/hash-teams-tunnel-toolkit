#!/bin/bash
# start.sh
# One script to rule them all.
# Creates the Azure VM (if needed), deploys the relay, starts the tunnel,
# and routes all your traffic through it.
#
# Usage:
#   ./start.sh                     # First run: creates VM + starts tunnel
#   ./start.sh                     # Next runs: reuses existing VM
#   ./start.sh "iPhone USB"        # Use USB tethering instead of Wi-Fi
#
# Press Ctrl+C to stop. The script disables the proxy automatically.

set -e

# ========== CONFIGURATION ==========
RESOURCE_GROUP="rg-teams-pentest"
VM_NAME="vm-tunnel-relay"
LOCATION="swedencentral"
VM_SIZE="Standard_B2ts_v2"
ADMIN_USER="hash"
SSH_KEY_PATH="./pentest_key"
NSG_NAME="nsg-tunnel-relay"
RELAY_PORT=9443
LOCAL_PORT=1080
SNI="teams.microsoft.com"
STATE_FILE=".vm_state"
PASSWORD_FILE=".relay_password"
# ====================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log()  { echo -e "${GREEN}[*]${NC} $1"; }
warn() { echo -e "${YELLOW}[!]${NC} $1"; }
err()  { echo -e "${RED}[x]${NC} $1"; }

# ---------- Detect active network interface ----------
detect_interface() {
    if [ -n "$1" ]; then
        INTERFACE="$1"
        return
    fi

    if [ "$(uname -s)" != "Darwin" ]; then
        INTERFACE=""
        return
    fi

    # Get the default route interface (e.g. en0)
    local dev
    dev=$(route get default 2>/dev/null | awk '/interface:/{print $2}')
    if [ -z "$dev" ]; then
        INTERFACE="Wi-Fi"
        return
    fi

    # Map the device (en0, en1, etc.) to the networksetup service name
    while IFS= read -r service; do
        local hw
        hw=$(networksetup -listallhardwareports 2>/dev/null | grep -A1 "Hardware Port: $service" | awk '/Device:/{print $2}')
        if [ "$hw" = "$dev" ]; then
            INTERFACE="$service"
            return
        fi
    done < <(networksetup -listallnetworkservices 2>/dev/null | tail -n +2)

    INTERFACE="Wi-Fi"
}

detect_interface "$1"

# ---------- Cleanup on exit ----------
cleanup() {
    echo ""
    log "Shutting down..."
    if [ -n "$INTERFACE" ]; then
        networksetup -setsocksfirewallproxystate "$INTERFACE" off 2>/dev/null && log "System proxy disabled on $INTERFACE"
    fi
    [ -n "$TUNNEL_PID" ] && kill "$TUNNEL_PID" 2>/dev/null && log "Tunnel stopped"
    if [ -n "$VM_IP" ]; then
        log "Deallocating VM (no charges while stopped)..."
        az vm deallocate --resource-group "$RESOURCE_GROUP" --name "$VM_NAME" --no-wait 2>/dev/null && log "VM deallocating"
    fi
    echo ""
    warn "The VM has been stopped but NOT deleted. It will not cost anything while stopped."
    warn "To delete all Azure resources permanently, run:"
    echo "  ./stop.sh --delete"
    echo ""
    exit 0
}
trap cleanup SIGINT SIGTERM

# ---------- Check prerequisites ----------
check_prereqs() {
    local missing=0

    if ! command -v python3 &>/dev/null; then
        err "Python 3 is not installed."
        echo "  macOS:  brew install python3"
        echo "  Linux:  sudo apt install python3"
        missing=1
    fi

    if ! command -v az &>/dev/null; then
        err "Azure CLI is not installed."
        echo "  macOS:  brew install azure-cli"
        echo "  Linux:  curl -sL https://aka.ms/InstallAzureCLIDeb | sudo bash"
        missing=1
    fi

    if ! command -v uv &>/dev/null; then
        warn "uv is not installed. Installing now..."
        curl -LsSf https://astral.sh/uv/install.sh | sh
        export PATH="$HOME/.local/bin:$PATH"
    fi

    if [ $missing -eq 1 ]; then
        err "Install the missing tools above and try again."
        exit 1
    fi

    # Check Azure login
    if ! az account show &>/dev/null; then
        warn "Not logged in to Azure. Opening login..."
        az login
    fi
}

# ---------- Generate SSH key ----------
ensure_ssh_key() {
    if [ ! -f "$SSH_KEY_PATH" ]; then
        log "Generating SSH key..."
        ssh-keygen -t rsa -b 4096 -f "$SSH_KEY_PATH" -N "" -C "tunnel-pentest" -q
    fi
}

# ---------- Generate or load relay password ----------
ensure_password() {
    if [ -f "$PASSWORD_FILE" ]; then
        RELAY_PASSWORD=$(cat "$PASSWORD_FILE")
        return
    fi

    # Generate a random 32-character password
    RELAY_PASSWORD=$(python3 -c "import secrets; print(secrets.token_urlsafe(32))")
    echo "$RELAY_PASSWORD" > "$PASSWORD_FILE"
    chmod 600 "$PASSWORD_FILE"
    log "Generated relay password (saved to $PASSWORD_FILE)"
}

# ---------- Create or start the VM ----------
ensure_vm() {
    # --- First, check if the VM already exists in Azure (regardless of state file) ---
    VM_STATUS=$(az vm get-instance-view \
        --resource-group "$RESOURCE_GROUP" \
        --name "$VM_NAME" \
        --query "instanceView.statuses[1].displayStatus" \
        -o tsv 2>/dev/null || echo "not_found")

    if [ "$VM_STATUS" != "not_found" ]; then
        # VM exists in Azure
        VM_IP=$(az vm show -g "$RESOURCE_GROUP" -n "$VM_NAME" -d --query publicIps -o tsv 2>/dev/null)
        echo "$VM_IP" > "$STATE_FILE"

        if [ "$VM_STATUS" = "VM running" ]; then
            log "VM is already running ($VM_IP)"
            return
        else
            log "VM exists but is stopped ($VM_STATUS). Starting..."
            az vm start --resource-group "$RESOURCE_GROUP" --name "$VM_NAME" -o none
            # IP might have changed after start
            VM_IP=$(az vm show -g "$RESOURCE_GROUP" -n "$VM_NAME" -d --query publicIps -o tsv)
            echo "$VM_IP" > "$STATE_FILE"
            log "VM started. IP: $VM_IP"
            return
        fi
    fi

    # --- VM does not exist, check if the resource group exists ---
    EXISTING_RG_LOCATION=$(az group show --name "$RESOURCE_GROUP" --query location -o tsv 2>/dev/null || echo "")

    if [ -n "$EXISTING_RG_LOCATION" ]; then
        # Resource group exists, use its location
        if [ "$EXISTING_RG_LOCATION" != "$LOCATION" ]; then
            warn "Resource group '$RESOURCE_GROUP' already exists in '$EXISTING_RG_LOCATION' (not '$LOCATION')"
            log "Using existing resource group location: $EXISTING_RG_LOCATION"
            LOCATION="$EXISTING_RG_LOCATION"
        else
            log "Resource group '$RESOURCE_GROUP' already exists in '$LOCATION'"
        fi
    else
        log "Creating resource group in $LOCATION..."
        az group create --name "$RESOURCE_GROUP" --location "$LOCATION" -o none
    fi

    # --- Create the VM ---
    log "Creating VM (this takes 1-2 minutes)..."

    # Try zones 1, 2, 3, then no zone, to handle capacity issues
    VM_OUTPUT=""
    for zone in 1 2 3; do
        VM_OUTPUT=$(az vm create \
            --resource-group "$RESOURCE_GROUP" \
            --name "$VM_NAME" \
            --image Ubuntu2404 \
            --size "$VM_SIZE" \
            --admin-username "$ADMIN_USER" \
            --ssh-key-values "${SSH_KEY_PATH}.pub" \
            --public-ip-sku Standard \
            --nsg "$NSG_NAME" \
            --os-disk-size-gb 30 \
            --storage-sku StandardSSD_LRS \
            --location "$LOCATION" \
            --zone "$zone" \
            -o json 2>/dev/null) && break
        warn "Zone $zone not available in $LOCATION, trying next..."
        VM_OUTPUT=""
    done

    if [ -z "$VM_OUTPUT" ]; then
        err "Failed to create VM in $LOCATION (all zones). Try a different location:"
        echo "  Edit LOCATION in start.sh and try again."
        echo "  Or delete the resource group first: ./stop.sh --delete"
        exit 1
    fi

    VM_IP=$(echo "$VM_OUTPUT" | python3 -c "import sys,json; print(json.load(sys.stdin)['publicIpAddress'])")
    echo "$VM_IP" > "$STATE_FILE"
    log "VM created. IP: $VM_IP"

    # Open relay port (ignore error if rule already exists)
    az network nsg rule create \
        --resource-group "$RESOURCE_GROUP" \
        --nsg-name "$NSG_NAME" \
        --name AllowTLSRelay \
        --priority 1010 \
        --direction Inbound \
        --access Allow \
        --protocol Tcp \
        --destination-port-ranges "$RELAY_PORT" \
        --source-address-prefixes '*' \
        -o none 2>/dev/null || log "NSG rule already exists"

    log "Port $RELAY_PORT opened"

    # Wait for SSH to be ready
    log "Waiting for SSH..."
    for i in $(seq 1 30); do
        if ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 \
            -i "$SSH_KEY_PATH" "$ADMIN_USER@$VM_IP" "echo ok" &>/dev/null; then
            break
        fi
        sleep 2
    done
}

# ---------- Deploy and start the relay ----------
ensure_relay() {
    # Test SSH connectivity first
    SSH_TEST=$(ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 -o BatchMode=yes \
        -i "$SSH_KEY_PATH" "$ADMIN_USER@$VM_IP" "echo connected" 2>&1 || true)

    if echo "$SSH_TEST" | grep -q "Permission denied"; then
        warn "SSH key mismatch. The VM was created with a different SSH key."
        log "Pushing your SSH key to the VM..."
        az vm user update \
            --resource-group "$RESOURCE_GROUP" \
            --name "$VM_NAME" \
            --username "$ADMIN_USER" \
            --ssh-key-value "${SSH_KEY_PATH}.pub" \
            -o none 2>/dev/null
        log "SSH key updated. Retrying connection..."
        sleep 5
    fi

    # Check if relay is already running
    RELAY_RUNNING=$(ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 -i "$SSH_KEY_PATH" "$ADMIN_USER@$VM_IP" \
        "ps aux | grep s2_server.py | grep -v grep" 2>/dev/null || true)

    if [ -n "$RELAY_RUNNING" ]; then
        log "Relay is already running on VM"
        return
    fi

    log "Deploying relay server to VM..."
    scp -o StrictHostKeyChecking=no -i "$SSH_KEY_PATH" \
        src/scenarios/s2_domain_fronting/server.py \
        "$ADMIN_USER@$VM_IP":~/s2_server.py 2>/dev/null

    ssh -i "$SSH_KEY_PATH" "$ADMIN_USER@$VM_IP" \
        "nohup python3 ~/s2_server.py --port $RELAY_PORT --password '$RELAY_PASSWORD' --auto-cert > ~/relay.log 2>&1 &"

    sleep 2

    # Verify
    RELAY_CHECK=$(ssh -i "$SSH_KEY_PATH" "$ADMIN_USER@$VM_IP" \
        "ps aux | grep s2_server.py | grep -v grep" 2>/dev/null || true)

    if [ -z "$RELAY_CHECK" ]; then
        err "Relay failed to start. Check logs:"
        ssh -i "$SSH_KEY_PATH" "$ADMIN_USER@$VM_IP" "cat ~/relay.log"
        exit 1
    fi

    log "Relay is running on $VM_IP:$RELAY_PORT"
}

# ---------- Install Python dependencies ----------
ensure_deps() {
    if [ ! -d ".venv" ]; then
        log "Installing Python dependencies..."
        uv sync 2>&1 | tail -1
    fi
}

# ---------- Start the tunnel ----------
start_tunnel() {
    log "Starting local tunnel (SNI=$SNI)..."

    uv run tunnel-test s2 \
        --relay-host "$VM_IP" \
        --relay-port "$RELAY_PORT" \
        --password "$RELAY_PASSWORD" \
        --test-mb 0 \
        --local-port "$LOCAL_PORT" \
        --sni "$SNI" &
    TUNNEL_PID=$!
    sleep 3

    # Check it started
    if ! kill -0 "$TUNNEL_PID" 2>/dev/null; then
        err "Tunnel failed to start"
        exit 1
    fi

    log "SOCKS5 proxy running on 127.0.0.1:$LOCAL_PORT"
}

# ---------- Route all traffic ----------
enable_proxy() {
    if [ "$(uname -s)" = "Darwin" ] && [ -n "$INTERFACE" ]; then
        log "Detected active interface: $INTERFACE"
        log "Routing all traffic on '$INTERFACE' through the tunnel..."
        networksetup -setsocksfirewallproxy "$INTERFACE" 127.0.0.1 "$LOCAL_PORT"
        networksetup -setsocksfirewallproxystate "$INTERFACE" on
    else
        warn "Could not set system proxy automatically."
        warn "Set it manually:"
        echo "  export ALL_PROXY=socks5://127.0.0.1:$LOCAL_PORT"
        echo "  Or configure SOCKS5 proxy 127.0.0.1:$LOCAL_PORT in your network settings"
    fi
}

# ========== MAIN ==========
echo ""
echo "=================================="
echo "  SNI Spoof Tunnel"
echo "  SNI: $SNI"
echo "  Interface: $INTERFACE"
echo "=================================="
echo ""

check_prereqs
ensure_ssh_key
ensure_password
ensure_deps
ensure_vm
ensure_relay
start_tunnel
enable_proxy

echo ""
log "All traffic is now tunneled through Azure VM ($VM_IP)"
log "The carrier sees SNI=$SNI for all connections"
echo ""
log "Press Ctrl+C to stop"
echo ""

wait $TUNNEL_PID
