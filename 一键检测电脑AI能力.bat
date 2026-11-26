@echo off
setlocal
cd /d "%~dp0"
where pwsh >nul 2>nul
if %ERRORLEVEL% EQU 0 (
    pwsh.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0AI_PC_Environment_Audit.ps1"
    goto :eof_pause
)
where powershell >nul 2>nul
if %ERRORLEVEL% EQU 0 (
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0AI_PC_Environment_Audit.ps1"
    goto :eof_pause
)
echo [Notice] Neither PowerShell 7 (pwsh) nor Windows PowerShell was found on this PC.
set /p DL_PS="Download PowerShell 7 via China Mirror now? (Y/N): "
if /I "%DL_PS%"=="Y" (
    start https://mirror.ghproxy.com/https://github.com/PowerShell/PowerShell/releases/latest
)
:eof_pause
echo.
pause
