@echo off
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0src\Stop.ps1"
echo Dynamic Island остановлен.
timeout /t 2 >nul
