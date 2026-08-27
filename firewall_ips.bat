@echo off
:: 静默运行 get_dns.ps1
powershell -WindowStyle Hidden  -NoProfile -ExecutionPolicy Bypass -File "%~dp0get_dns.ps1" >nul 2>&1

:: 判断是否以管理员身份运行
net session >nul 2>&1
if %errorlevel% neq 0 (
    :: 不是管理员，重新以管理员身份运行本脚本
    powershell -WindowStyle Hidden -Command ^
        "Start-Process -FilePath '%~f0' -Verb RunAs"
    exit /b
)

:: 以管理员权限静默运行 allow_dns.ps1
powershell -WindowStyle Hidden  -NoProfile -ExecutionPolicy Bypass -File "%~dp0allow_dns.ps1" >nul 2>&1


