@echo off
rem Double-click me to uninstall: removes the startup shortcut, stops the guard, restores the pet.
setlocal
set "DIR=%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -File "%DIR%PetGameGuard.ps1" -Uninstall
pause
