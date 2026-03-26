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

:: Run install first (skips anything already installed)
echo [*] Checking prerequisites...
powershell -ExecutionPolicy Bypass -NoProfile -File ".\install.ps1"

:: Run the tunnel
echo.
echo [*] Starting tunnel...
powershell -ExecutionPolicy Bypass -NoProfile -File ".\start.ps1"

if %errorLevel% neq 0 (
    echo.
    echo [x] Something went wrong. Check the errors above.
)

echo.
pause
