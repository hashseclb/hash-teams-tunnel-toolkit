# start.ps1
# One script to rule them all (Windows version).
# Creates the Azure VM (if needed), deploys the relay, starts the tunnel,
# and routes all your traffic through it.
#
# Usage:
#   .\start.ps1                       # First run: creates VM + starts tunnel
#   .\start.ps1                       # Next runs: reuses existing VM
#   .\start.ps1 -Interface "Ethernet" # Use a specific network interface
#
# Press Ctrl+C to stop.

param(
    [string]$Interface = "Wi-Fi"
)

$ErrorActionPreference = "Continue"

# ========== CONFIGURATION ==========
$RESOURCE_GROUP = "rg-teams-pentest"
$VM_NAME = "vm-tunnel-relay"
$LOCATION = "swedencentral"
$VM_SIZE = "Standard_B2ts_v2"
$ADMIN_USER = "hash"
$SSH_KEY_PATH = ".\pentest_key"
$NSG_NAME = "nsg-tunnel-relay"
$RELAY_PORT = 9443
$LOCAL_PORT = 1080
$SNI = "teams.microsoft.com"
$STATE_FILE = ".vm_state"
$PASSWORD_FILE = ".relay_password"
# ====================================

function Log($msg) { Write-Host "[*] $msg" -ForegroundColor Green }
function Warn($msg) { Write-Host "[!] $msg" -ForegroundColor Yellow }
function Err($msg) { Write-Host "[x] $msg" -ForegroundColor Red }

# ---------- Refresh PATH (picks up newly installed tools) ----------
function Refresh-Path {
    $machinePath = [Environment]::GetEnvironmentVariable("Path", "Machine")
    $userPath = [Environment]::GetEnvironmentVariable("Path", "User")
    $env:Path = "$machinePath;$userPath;$env:USERPROFILE\.local\bin"
}
Refresh-Path

# ---------- Cleanup on exit ----------
$tunnelProcess = $null

function Cleanup {
    Write-Host ""
    Log "Shutting down..."

    # Disable proxy
    try {
        $reg = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings"
        Set-ItemProperty -Path $reg -Name ProxyEnable -Value 0
        Log "System proxy disabled"
    } catch {}

    # Kill tunnel
    if ($tunnelProcess -and !$tunnelProcess.HasExited) {
        $tunnelProcess.Kill()
        Log "Tunnel stopped"
    }

    # Deallocate VM
    if ($VM_IP) {
        Log "Deallocating VM (no charges while stopped)..."
        az vm deallocate --resource-group $RESOURCE_GROUP --name $VM_NAME --no-wait 2>$null
        Log "VM deallocating"
    }

    Write-Host ""
    Warn "The VM has been stopped but NOT deleted. It will not cost anything while stopped."
    Warn "To delete all Azure resources permanently, run:"
    Write-Host "  .\stop.ps1 -Delete"
    Write-Host ""
}

trap { Cleanup; break }

# ---------- Check prerequisites ----------
function Check-Prereqs {
    $missing = $false

    $script:PYTHON = $null
    if (Get-Command python -ErrorAction SilentlyContinue) {
        $pyVer = python --version 2>&1
        if ($pyVer -match "3\.\d+") { $script:PYTHON = "python" }
    }
    if (-not $PYTHON -and (Get-Command python3 -ErrorAction SilentlyContinue)) {
        $script:PYTHON = "python3"
    }
    if (-not $PYTHON) {
        Err "Python 3 is not installed. Run .\install.ps1 first."
        $missing = $true
    }

    if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
        Err "Azure CLI is not installed. Run .\install.ps1 first."
        $missing = $true
    }

    if (-not (Get-Command uv -ErrorAction SilentlyContinue)) {
        Warn "uv is not installed. Installing now..."
        irm https://astral.sh/uv/install.ps1 | iex
        $env:Path = "$env:USERPROFILE\.local\bin;$env:Path"
    }

    if ($missing) {
        Err "Install the missing tools and try again."
        exit 1
    }

    # Check Azure login
    $azCheck = az account show 2>$null
    if ($LASTEXITCODE -ne 0) {
        Warn "Not logged in to Azure. Opening login..."
        az login
    }
}

# ---------- Generate SSH key ----------
function Ensure-SSHKey {
    if (-not (Test-Path $SSH_KEY_PATH)) {
        Log "Generating SSH key..."
        ssh-keygen -t rsa -b 4096 -f $SSH_KEY_PATH -N '""' -C "tunnel-pentest" -q
    }
}

# ---------- Generate or load relay password ----------
function Ensure-Password {
    if (Test-Path $PASSWORD_FILE) {
        $script:RELAY_PASSWORD = Get-Content $PASSWORD_FILE
        return
    }

    $script:RELAY_PASSWORD = & $PYTHON -c "import secrets; print(secrets.token_urlsafe(32))"
    Set-Content -Path $PASSWORD_FILE -Value $RELAY_PASSWORD
    Log "Generated relay password (saved to $PASSWORD_FILE)"
}

# ---------- Create or start the VM ----------
function Ensure-VM {
    $script:VM_IP = $null

    # Check if VM already exists in Azure
    $vmStatus = az vm get-instance-view `
        --resource-group $RESOURCE_GROUP `
        --name $VM_NAME `
        --query "instanceView.statuses[1].displayStatus" `
        -o tsv 2>$null

    if ($LASTEXITCODE -eq 0 -and $vmStatus) {
        # VM exists
        $script:VM_IP = az vm show -g $RESOURCE_GROUP -n $VM_NAME -d --query publicIps -o tsv 2>$null
        Set-Content -Path $STATE_FILE -Value $VM_IP

        if ($vmStatus -eq "VM running") {
            Log "VM is already running ($VM_IP)"
            return
        } else {
            Log "VM exists but is stopped ($vmStatus). Starting..."
            az vm start --resource-group $RESOURCE_GROUP --name $VM_NAME -o none
            $script:VM_IP = az vm show -g $RESOURCE_GROUP -n $VM_NAME -d --query publicIps -o tsv
            Set-Content -Path $STATE_FILE -Value $VM_IP
            Log "VM started. IP: $VM_IP"
            return
        }
    }

    # VM does not exist. Check if resource group exists in a different location.
    $existingRgLocation = az group show --name $RESOURCE_GROUP --query location -o tsv 2>$null
    if ($LASTEXITCODE -eq 0 -and $existingRgLocation) {
        if ($existingRgLocation -ne $LOCATION) {
            Warn "Resource group '$RESOURCE_GROUP' already exists in '$existingRgLocation' (not '$LOCATION')"
            Log "Using existing resource group location: $existingRgLocation"
            $script:LOCATION = $existingRgLocation
        } else {
            Log "Resource group '$RESOURCE_GROUP' already exists in '$LOCATION'"
        }
    } else {
        Log "Creating resource group in $LOCATION..."
        az group create --name $RESOURCE_GROUP --location $LOCATION -o none
    }

    Log "Creating VM (this takes 1-2 minutes)..."

    # Try zones 1, 2, 3 to handle capacity issues
    $vmOutput = $null
    foreach ($zone in 1, 2, 3) {
        $vmOutput = az vm create `
            --resource-group $RESOURCE_GROUP `
            --name $VM_NAME `
            --image Ubuntu2404 `
            --size $VM_SIZE `
            --admin-username $ADMIN_USER `
            --ssh-key-values "$SSH_KEY_PATH.pub" `
            --public-ip-sku Standard `
            --nsg $NSG_NAME `
            --os-disk-size-gb 30 `
            --storage-sku StandardSSD_LRS `
            --location $LOCATION `
            --zone $zone `
            -o json 2>$null

        if ($LASTEXITCODE -eq 0 -and $vmOutput) { break }
        Warn "Zone $zone not available in $LOCATION, trying next..."
        $vmOutput = $null
    }

    if (-not $vmOutput) {
        Err "Failed to create VM in $LOCATION (all zones). Try a different location:"
        Write-Host "  Edit LOCATION in start.ps1 and try again."
        Write-Host "  Or delete the resource group first: .\stop.ps1 -Delete"
        exit 1
    }

    $script:VM_IP = ($vmOutput | ConvertFrom-Json).publicIpAddress
    Set-Content -Path $STATE_FILE -Value $VM_IP
    Log "VM created. IP: $VM_IP"

    # Open relay port (ignore error if rule already exists)
    az network nsg rule create `
        --resource-group $RESOURCE_GROUP `
        --nsg-name $NSG_NAME `
        --name AllowTLSRelay `
        --priority 1010 `
        --direction Inbound `
        --access Allow `
        --protocol Tcp `
        --destination-port-ranges $RELAY_PORT `
        --source-address-prefixes '*' `
        -o none 2>$null
    if ($LASTEXITCODE -ne 0) { Log "NSG rule already exists" }

    Log "Port $RELAY_PORT opened"

    Log "Waiting for SSH..."
    for ($i = 0; $i -lt 30; $i++) {
        $sshTest = cmd /c "ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 -i $SSH_KEY_PATH $ADMIN_USER@$VM_IP `"echo ok`" 2>nul"
        if ($sshTest -eq "ok") { break }
        Start-Sleep -Seconds 2
    }
}

# ---------- Deploy and start the relay ----------
function Ensure-Relay {
    $relayCheck = cmd /c "ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 -i $SSH_KEY_PATH $ADMIN_USER@$VM_IP `"ps aux | grep s2_server.py | grep -v grep`" 2>nul"

    if ($relayCheck) {
        Log "Relay is already running on VM"
        return
    }

    Log "Deploying relay server to VM..."
    cmd /c "scp -o StrictHostKeyChecking=no -i $SSH_KEY_PATH `"src/scenarios/s2_domain_fronting/server.py`" $ADMIN_USER@${VM_IP}:~/s2_server.py 2>nul"

    cmd /c "ssh -o StrictHostKeyChecking=no -i $SSH_KEY_PATH $ADMIN_USER@$VM_IP `"nohup python3 ~/s2_server.py --port $RELAY_PORT --password '$RELAY_PASSWORD' --auto-cert > ~/relay.log 2>&1 &`" 2>nul"

    Start-Sleep -Seconds 2
    Log "Relay is running on ${VM_IP}:${RELAY_PORT}"
}

# ---------- Install dependencies ----------
function Ensure-Deps {
    if (-not (Test-Path ".venv")) {
        Log "Installing Python dependencies..."
        uv sync 2>&1 | Select-Object -Last 1
    }
}

# ---------- Start the tunnel ----------
function Start-Tunnel {
    Log "Starting local tunnel (SNI=$SNI)..."

    $script:tunnelProcess = Start-Process -NoNewWindow -PassThru -FilePath "uv" `
        -ArgumentList "run", "tunnel-test", "s2",
            "--relay-host", $VM_IP,
            "--relay-port", $RELAY_PORT,
            "--password", $RELAY_PASSWORD,
            "--test-mb", "0",
            "--local-port", $LOCAL_PORT,
            "--sni", $SNI

    Start-Sleep -Seconds 3

    if ($tunnelProcess.HasExited) {
        Err "Tunnel failed to start"
        exit 1
    }

    Log "SOCKS5 proxy running on 127.0.0.1:$LOCAL_PORT"
}

# ---------- Route all traffic (Windows) ----------
function Enable-Proxy {
    Log "Routing all traffic through the tunnel..."

    $reg = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings"
    Set-ItemProperty -Path $reg -Name ProxyServer -Value "socks=127.0.0.1:$LOCAL_PORT"
    Set-ItemProperty -Path $reg -Name ProxyEnable -Value 1

    Log "System proxy enabled (SOCKS 127.0.0.1:$LOCAL_PORT)"
    Warn "Some apps may need manual proxy configuration or a restart"
}

# ========== MAIN ==========
Write-Host ""
Write-Host "=================================="
Write-Host "  SNI Spoof Tunnel"
Write-Host "  SNI: $SNI"
Write-Host "  Interface: $Interface"
Write-Host "=================================="
Write-Host ""

Check-Prereqs
Ensure-SSHKey
Ensure-Password
Ensure-Deps
Ensure-VM
Ensure-Relay
Start-Tunnel
Enable-Proxy

Write-Host ""
Log "All traffic is now tunneled through Azure VM ($VM_IP)"
Log "The carrier sees SNI=$SNI for all connections"
Write-Host ""
Log "Press Ctrl+C to stop"
Write-Host ""

try {
    $tunnelProcess.WaitForExit()
} finally {
    Cleanup
}
