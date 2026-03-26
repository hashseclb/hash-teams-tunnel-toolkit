# install.ps1
# Installs all prerequisites for the SNI spoof tunnel on Windows.
#
# Usage (run in PowerShell as Administrator):
#   Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
#   .\install.ps1

$ErrorActionPreference = "Continue"

function Log($msg) { Write-Host "[*] $msg" -ForegroundColor Green }
function Warn($msg) { Write-Host "[!] $msg" -ForegroundColor Yellow }
function Err($msg) { Write-Host "[x] $msg" -ForegroundColor Red }

function Refresh-Path {
    $machinePath = [Environment]::GetEnvironmentVariable("Path", "Machine")
    $userPath = [Environment]::GetEnvironmentVariable("Path", "User")
    $env:Path = "$machinePath;$userPath;$env:USERPROFILE\.local\bin;$env:USERPROFILE\AppData\Local\Programs\Python\Python313;$env:USERPROFILE\AppData\Local\Programs\Python\Python313\Scripts;C:\Program Files\Microsoft SDKs\Azure\CLI2\wbin;C:\Program Files (x86)\Microsoft SDKs\Azure\CLI2\wbin"
}

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
$needsRefresh = $false

if (Get-Command python -ErrorAction SilentlyContinue) {
    $pyVer = python --version 2>&1
    if ($pyVer -match "3\.\d+") {
        Log "Python is already installed: $pyVer"
    } else {
        Log "Installing Python 3.13..."
        winget install Python.Python.3.13 --accept-package-agreements --accept-source-agreements
        $needsRefresh = $true
    }
} else {
    Log "Installing Python 3.13..."
    winget install Python.Python.3.13 --accept-package-agreements --accept-source-agreements
    $needsRefresh = $true
}

if ($needsRefresh) {
    Refresh-Path
    if (Get-Command python -ErrorAction SilentlyContinue) {
        Log "Python installed: $(python --version 2>&1)"
    } else {
        Warn "Python was installed but is not in PATH yet."
        Warn "If the next steps fail, close and reopen PowerShell, then run this script again."
    }
}

# ---------- Azure CLI ----------
if (Get-Command az -ErrorAction SilentlyContinue) {
    Log "Azure CLI is already installed"
} else {
    Log "Installing Azure CLI..."
    winget install Microsoft.AzureCLI --accept-package-agreements --accept-source-agreements
    Refresh-Path
    if (Get-Command az -ErrorAction SilentlyContinue) {
        Log "Azure CLI installed"
    } else {
        Warn "Azure CLI was installed but 'az' is not in PATH yet."
        Warn "If the next steps fail, close and reopen PowerShell, then run this script again."
    }
}

# ---------- OpenSSH (for scp/ssh) ----------
if (Get-Command ssh -ErrorAction SilentlyContinue) {
    Log "OpenSSH is already available"
} else {
    Log "Installing OpenSSH client..."
    if ($isAdmin) {
        Add-WindowsCapability -Online -Name OpenSSH.Client~~~~0.0.1.0
        Log "OpenSSH installed"
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
    Refresh-Path
    Log "uv installed"
}

# ---------- Project dependencies ----------
if (Test-Path "pyproject.toml") {
    Log "Installing project dependencies..."
    $uvOut = uv sync 2>&1 | Out-String
    Write-Host $uvOut.Trim().Split("`n")[-1]
    Log "Dependencies installed"
} else {
    Warn "pyproject.toml not found. Run this script from the project directory."
}

# ---------- Azure login check ----------
Write-Host ""
try {
    $azCheck = az account show 2>$null
    if ($LASTEXITCODE -eq 0) {
        $account = az account show --query name -o tsv
        Log "Already logged in to Azure: $account"
    } else {
        Warn "Not logged in to Azure."
        Write-Host "  Run 'az login' to authenticate before using start.ps1"
    }
} catch {
    Warn "Could not check Azure login status. Make sure 'az' is in your PATH."
    Warn "If you just installed Azure CLI, close and reopen PowerShell first."
}

Write-Host ""
Log "All prerequisites are installed."
Log "Next steps:"
Write-Host "  1. If you just installed Python or Azure CLI, close and reopen PowerShell"
Write-Host "  2. Run 'az login' if you have not already"
Write-Host "  3. Run '.\start.ps1' to start the tunnel"
Write-Host ""
