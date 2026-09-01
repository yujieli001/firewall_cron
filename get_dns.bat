@echo off

:: 运行 get_dns.ps1

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0get_dns.ps1"

:: 判断是否以管理员身份运行

net session >nul 2>&1

if %errorlevel% neq 0 (

    :: 不是管理员，重新以管理员身份运行本脚本

    powershell -Command ^
        "Start-Process -FilePath '%~f0' -Verb RunAs"

    exit /b

)
