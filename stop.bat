@echo off
:: stop.bat
:: Double-click to stop the tunnel and deallocate the VM.
:: To delete all Azure resources: stop.bat --delete

title SNI Spoof Tunnel - Stop

cd /d "%~dp0"

set "DELETE_FLAG="
if "%1"=="--delete" set "DELETE_FLAG=-Delete"

powershell -ExecutionPolicy Bypass -NoProfile -Command "& '.\stop.ps1' %DELETE_FLAG%"

pause
