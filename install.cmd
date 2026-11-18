@echo off
chcp 65001 >nul
setlocal
set "DIR=%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -File "%DIR%PetGameGuard.ps1" -Install
echo.
echo 如果上面提示失败，请右键本文件 ->「以管理员身份运行」再试一次。
pause
