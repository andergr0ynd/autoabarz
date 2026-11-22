@echo off
if "%~1"=="" (
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Install-ArzMarketBridge.ps1"
) else (
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Install-ArzMarketBridge.ps1" -MoonloaderPath "%~1"
)
pause
