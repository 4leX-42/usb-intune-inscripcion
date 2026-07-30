@echo off
REM ===========================================================
REM  ap-online.cmd - Registro usando el camino OFICIAL:
REM  Get-WindowsAutopilotInfo.ps1 -Online
REM  El CSV se guarda antes en el USB por si el login falla.
REM  OJO: la ventana de login puede quedar detras. ALT+TAB.
REM  Uso en OOBE:  SHIFT+F10  ->  escribe  D:\ap-online.cmd
REM ===========================================================
setlocal

title Autopilot - Registro oficial (-Online)

set "USBDIR=%~dp0"
set "PS1=%USBDIR%Autopilot\Run-Autopilot.ps1"
set "PWSH=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"

if not exist "%PWSH%" set "PWSH=powershell.exe"

if not exist "%PS1%" (
    echo.
    echo  ERROR: no encuentro "%PS1%"
    echo  El USB esta incompleto.
    echo.
    pause
    exit /b 1
)

echo.
echo  USB detectado en: %USBDIR%
echo  Modo: -Online (script oficial de Microsoft)
echo.

"%PWSH%" -NoProfile -ExecutionPolicy Bypass -File "%PS1%" -Online %*

endlocal
