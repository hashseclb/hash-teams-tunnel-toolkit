# install.ps1
# Installs all prerequisites for the SNI spoof tunnel on Windows.
#
# Usage (run in PowerShell as Administrator):
#   Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
#   .\install.ps1

$ErrorActionPreference = "Stop"

function Log($msg) { Write-Host "[*] $msg" -ForegroundColor Green }
function Warn($msg) { Write-Host "[!] $msg" -ForegroundColor Yellow }
function Err($msg) { Write-Host "[x] $msg" -ForegroundColor Red }

Write-Host ""
Write-Host "=================================="
Write-Host "  SNI Spoof Tunnel - Installer"
Write-Host "  OS: Windows"
Write-Host "=================================="
Write-Host ""

# ---------- Check if running as admin ----------
$isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

# ---------- winget check ----------
if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
    Err "winget is not available. Install App Installer from the Microsoft Store."
    exit 1
}

# ---------- Python ----------
if (Get-Command python3 -ErrorAction SilentlyContinue) {
    $pyVer = python3 --version 2>&1
    Log "Python is already installed: $pyVer"
} elseif (Get-Command python -ErrorAction SilentlyContinue) {
    $pyVer = python --version 2>&1
    if ($pyVer -match "3\.\d+") {
        Log "Python is already installed: $pyVer"
    } else {
        Log "Installing Python..."
        winget install Python.Python.3.13 --accept-package-agreements --accept-source-agreements
        Log "Python installed. Close and reopen PowerShell, then run this script again."
        exit 0
    }
} else {
    Log "Installing Python 3.13..."
    winget install Python.Python.3.13 --accept-package-agreements --accept-source-agreements
    Log "Python installed. Close and reopen PowerShell, then run this script again."
    exit 0
}

# ---------- Azure CLI ----------
if (Get-Command az -ErrorAction SilentlyContinue) {
    $azVer = az version --query '"azure-cli"' -o tsv 2>$null
    Log "Azure CLI is already installed: $azVer"
} else {
    Log "Installing Azure CLI..."
    winget install Microsoft.AzureCLI --accept-package-agreements --accept-source-agreements
    Log "Azure CLI installed. Close and reopen PowerShell, then run this script again."
    exit 0
}

# ---------- OpenSSH (for scp/ssh) ----------
if (Get-Command ssh -ErrorAction SilentlyContinue) {
    Log "OpenSSH is already available"
} else {
    Log "Installing OpenSSH client..."
    if ($isAdmin) {
        Add-WindowsCapability -Online -Name OpenSSH.Client~~~~0.0.1.0
    } else {
        Warn "Run this script as Administrator to install OpenSSH, or install it manually:"
        Write-Host "  Settings > Apps > Optional Features > Add OpenSSH Client"
    }
}

# ---------- uv ----------
if (Get-Command uv -ErrorAction SilentlyContinue) {
    $uvVer = uv --version 2>&1
    Log "uv is already installed: $uvVer"
} else {
    Log "Installing uv..."
    irm https://astral.sh/uv/install.ps1 | iex
    $env:Path = "$env:USERPROFILE\.local\bin;$env:Path"
    Log "uv installed"
}

# ---------- Project dependencies ----------
if (Test-Path "pyproject.toml") {
    Log "Installing project dependencies..."
    uv sync 2>&1 | Select-Object -Last 1
    Log "Dependencies installed"
} else {
    Warn "pyproject.toml not found. Run this script from the project directory."
}

# ---------- Azure login check ----------
Write-Host ""
$azCheck = az account show 2>$null
if ($LASTEXITCODE -eq 0) {
    $account = az account show --query name -o tsv
    Log "Already logged in to Azure: $account"
} else {
    Warn "Not logged in to Azure."
    Write-Host "  Run 'az login' to authenticate before using start.ps1"
}

Write-Host ""
Log "All prerequisites are installed."
Log "Next steps:"
Write-Host "  1. Run 'az login' if you have not already"
Write-Host "  2. Run '.\start.ps1' to start the tunnel"
Write-Host ""
