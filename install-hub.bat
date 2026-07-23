@echo off
REM EDGE-PKG-2-WIN / EDGE-PKG-5-WIN - double-click launcher for the Edge Hub installer.
REM
REM Runs install-hub.ps1 AS THE INTERACTIVE USER (no self-elevation). Docker Desktop
REM is per-user, so `docker info` / `docker compose` must run as the logged-in user -
REM elevating the whole installer would switch accounts and make Docker unreachable
REM (that was the EDGE-PKG-5 hang). The script asks for admin only for the few steps
REM that need it (opening the firewall port, installing Docker), each via its own UAC
REM prompt. Do NOT right-click "Run as administrator".
setlocal

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0install-hub.ps1" %*
echo.
pause
