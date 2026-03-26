#!/bin/bash
# stop.sh
# Stops the tunnel and optionally cleans up Azure resources.
#
# Usage:
#   ./stop.sh              # Stop tunnel, keep VM (deallocated, no charges)
#   ./stop.sh --delete     # Stop tunnel and DELETE all Azure resources

set -e

RESOURCE_GROUP="rg-teams-pentest"
VM_NAME="vm-tunnel-relay"
STATE_FILE=".vm_state"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log()  { echo -e "${GREEN}[*]${NC} $1"; }
warn() { echo -e "${YELLOW}[!]${NC} $1"; }

echo ""

# Disable system proxy on all interfaces
for iface in "Wi-Fi" "iPhone USB" "USB 10/100/1000 LAN" "Ethernet"; do
    networksetup -setsocksfirewallproxystate "$iface" off 2>/dev/null && \
        log "Proxy disabled on $iface"
done

# Kill tunnel process
TUNNEL_PID=$(lsof -ti :1080 2>/dev/null || true)
if [ -n "$TUNNEL_PID" ]; then
    kill $TUNNEL_PID 2>/dev/null
    log "Tunnel process stopped"
else
    log "No tunnel process found"
fi

# Handle Azure resources
if [ "$1" = "--delete" ]; then
    warn "Deleting ALL Azure resources..."
    az group delete --name "$RESOURCE_GROUP" --yes --no-wait 2>/dev/null && \
        log "Resource group deletion started (runs in background)"
    rm -f "$STATE_FILE"
    log "Done. All Azure resources will be removed."
else
    # Just deallocate (stop billing but keep the VM)
    if az vm show -g "$RESOURCE_GROUP" -n "$VM_NAME" &>/dev/null; then
        log "Deallocating VM (no compute charges while stopped)..."
        az vm deallocate --resource-group "$RESOURCE_GROUP" --name "$VM_NAME" --no-wait 2>/dev/null
        log "VM is deallocating"
    fi
    echo ""
    log "VM is kept for next time. To delete everything:"
    echo "  ./stop.sh --delete"
fi

echo ""
