@echo off
REM ===========================================================
REM  ap.cmd - Registro de este equipo en Windows Autopilot
REM  Uso en OOBE:  SHIFT+F10  (o FN+SHIFT+F10)  ->  escribe  D:\ap.cmd
REM  La letra del USB se detecta sola, da igual si no es D:
REM ===========================================================
setlocal

title Autopilot - Registro en Intune

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
echo  Lanzando PowerShell...
echo.

REM -ExecutionPolicy Bypass evita el "running scripts is disabled".
REM -NoProfile arranca mas rapido y evita perfiles raros.
"%PWSH%" -NoProfile -ExecutionPolicy Bypass -File "%PS1%" %*

endlocal
