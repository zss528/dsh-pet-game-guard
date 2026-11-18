@echo off
chcp 65001 >nul
setlocal
set "DIR=%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -File "%DIR%PetGameGuard.ps1" -Status
pause
