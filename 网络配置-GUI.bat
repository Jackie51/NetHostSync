@echo off
chcp 65001 >nul
setlocal EnableExtensions
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0network_config.ps1" -Gui
endlocal
