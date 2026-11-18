@echo off
rem Double-click me to check status: DSH endpoint, pet display value, current verdict.
setlocal
set "DIR=%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -File "%DIR%PetGameGuard.ps1" -Status
pause
