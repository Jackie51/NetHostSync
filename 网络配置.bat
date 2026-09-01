@echo off
chcp 65001 >nul
setlocal EnableExtensions
REM ============================================================
REM 菜单已改为纯英文 ASCII，以彻底规避旧版 conhost（以及任意终端）对全角中文
REM 的 ClearType“右侧同字残影”渲染 bug。该 bug 在 conhost 与 Windows Terminal
REM 中对全角字形均存在，只有去掉全角字形才能根治，故不依赖 Windows Terminal。
REM 任何控制台（含默认 conhost）下菜单都不会出现残影。
REM ============================================================
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0network_config.ps1"
endlocal
