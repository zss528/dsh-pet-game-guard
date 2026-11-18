@echo off
rem Double-click me to install: creates a startup shortcut and starts the guard.
setlocal
set "DIR=%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -File "%DIR%PetGameGuard.ps1" -Install
echo.
echo If it failed, right-click this file and pick "Run as administrator", then try again.
pause
