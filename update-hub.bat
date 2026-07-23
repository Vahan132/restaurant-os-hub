@echo off
REM EDGE-PKG-2-WIN - double-click launcher to update the Edge Hub.
setlocal
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0update-hub.ps1" %*
echo.
pause
