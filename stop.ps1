# stop.ps1
# Stops the tunnel and optionally cleans up Azure resources (Windows version).
#
# Usage:
#   .\stop.ps1              # Stop tunnel, keep VM (deallocated, no charges)
#   .\stop.ps1 -Delete      # Stop tunnel and DELETE all Azure resources

param(
    [switch]$Delete
)

$RESOURCE_GROUP = "rg-teams-pentest"
$VM_NAME = "vm-tunnel-relay"
$STATE_FILE = ".vm_state"

function Log($msg) { Write-Host "[*] $msg" -ForegroundColor Green }
function Warn($msg) { Write-Host "[!] $msg" -ForegroundColor Yellow }

Write-Host ""

# Disable system proxy
$reg = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings"
Set-ItemProperty -Path $reg -Name ProxyEnable -Value 0
Log "System proxy disabled"

# Kill tunnel process (anything listening on port 1080)
$proc = Get-NetTCPConnection -LocalPort 1080 -ErrorAction SilentlyContinue | Select-Object -ExpandProperty OwningProcess -Unique
if ($proc) {
    Stop-Process -Id $proc -Force -ErrorAction SilentlyContinue
    Log "Tunnel process stopped"
} else {
    Log "No tunnel process found"
}

# Handle Azure resources
if ($Delete) {
    Warn "Deleting ALL Azure resources..."
    az group delete --name $RESOURCE_GROUP --yes --no-wait 2>$null
    Log "Resource group deletion started (runs in background)"
    Remove-Item $STATE_FILE -ErrorAction SilentlyContinue
    Log "Done. All Azure resources will be removed."
} else {
    $vmExists = az vm show -g $RESOURCE_GROUP -n $VM_NAME 2>$null
    if ($LASTEXITCODE -eq 0) {
        Log "Deallocating VM (no compute charges while stopped)..."
        az vm deallocate --resource-group $RESOURCE_GROUP --name $VM_NAME --no-wait 2>$null
        Log "VM is deallocating"
    }
    Write-Host ""
    Log "VM is kept for next time. To delete everything:"
    Write-Host "  .\stop.ps1 -Delete"
}

Write-Host ""
