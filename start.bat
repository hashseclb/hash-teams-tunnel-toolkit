@echo off
:: start.bat
:: Double-click this file to start the tunnel.
:: It handles everything: prerequisites, Azure VM, relay, tunnel, proxy.
:: Press Ctrl+C to stop.

title SNI Spoof Tunnel

:: Check for admin rights (needed for proxy and OpenSSH install)
net session >nul 2>&1
if %errorLevel% neq 0 (
    echo [!] Requesting administrator privileges...
    powershell -Command "Start-Process '%~f0' -Verb RunAs"
    exit /b
)

:: Change to the directory where this script lives
cd /d "%~dp0"

echo.
echo ==================================
echo   SNI Spoof Tunnel - Windows
echo   One-click setup and start
echo ==================================
echo.

:: Run install + start in one PowerShell session
powershell -ExecutionPolicy Bypass -NoProfile -Command ^
    "& {" ^
    "  $ErrorActionPreference = 'Stop';" ^
    "  " ^
    "  function Refresh-Path {" ^
    "    $m = [Environment]::GetEnvironmentVariable('Path','Machine');" ^
    "    $u = [Environment]::GetEnvironmentVariable('Path','User');" ^
    "    $env:Path = \"$m;$u;$env:USERPROFILE\.local\bin\"" ^
    "  }" ^
    "  Refresh-Path;" ^
    "  " ^
    "  # --- Install prerequisites if missing ---" ^
    "  $installed = $false;" ^
    "  " ^
    "  if (-not (Get-Command python -EA SilentlyContinue)) {" ^
    "    Write-Host '[*] Installing Python...' -FG Green;" ^
    "    winget install Python.Python.3.13 --accept-package-agreements --accept-source-agreements;" ^
    "    Refresh-Path; $installed = $true" ^
    "  }" ^
    "  " ^
    "  if (-not (Get-Command az -EA SilentlyContinue)) {" ^
    "    Write-Host '[*] Installing Azure CLI...' -FG Green;" ^
    "    winget install Microsoft.AzureCLI --accept-package-agreements --accept-source-agreements;" ^
    "    Refresh-Path; $installed = $true" ^
    "  }" ^
    "  " ^
    "  if (-not (Get-Command ssh -EA SilentlyContinue)) {" ^
    "    Write-Host '[*] Installing OpenSSH...' -FG Green;" ^
    "    Add-WindowsCapability -Online -Name OpenSSH.Client~~~~0.0.1.0 2>$null" ^
    "  }" ^
    "  " ^
    "  if (-not (Get-Command uv -EA SilentlyContinue)) {" ^
    "    Write-Host '[*] Installing uv...' -FG Green;" ^
    "    irm https://astral.sh/uv/install.ps1 | iex;" ^
    "    Refresh-Path" ^
    "  }" ^
    "  " ^
    "  if (-not (Test-Path '.venv')) {" ^
    "    Write-Host '[*] Installing project dependencies...' -FG Green;" ^
    "    uv sync 2>&1 | Select-Object -Last 1" ^
    "  }" ^
    "  " ^
    "  # --- Check Azure login ---" ^
    "  az account show 2>$null | Out-Null;" ^
    "  if ($LASTEXITCODE -ne 0) {" ^
    "    Write-Host '[!] Not logged in to Azure. Opening browser...' -FG Yellow;" ^
    "    az login" ^
    "  }" ^
    "  " ^
    "  # --- Run the start script ---" ^
    "  Write-Host '' ; Write-Host '[*] Starting tunnel...' -FG Green;" ^
    "  & '.\start.ps1'" ^
    "}"

if %errorLevel% neq 0 (
    echo.
    echo [x] Something went wrong. Check the errors above.
    echo.
    pause
)
