@echo off
REM ===========================================================
REM  ap-csv.cmd - SOLO genera el CSV con el hash en el USB.
REM  No pide login ni internet. Para importar a mano en Intune.
REM  Uso en OOBE:  SHIFT+F10  ->  escribe  D:\ap-csv.cmd
REM ===========================================================
setlocal

title Autopilot - Solo CSV (offline)

set "USBDIR=%~dp0"
set "PS1=%USBDIR%Autopilot\Run-Autopilot.ps1"
set "PWSH=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"

if not exist "%PWSH%" set "PWSH=powershell.exe"

if not exist "%PS1%" (
    echo.
    echo  ERROR: no encuentro "%PS1%"
    echo.
    pause
    exit /b 1
)

"%PWSH%" -NoProfile -ExecutionPolicy Bypass -File "%PS1%" -CsvOnly %*

endlocal
