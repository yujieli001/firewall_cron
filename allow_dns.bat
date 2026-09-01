@echo off

net session >nul 2>&1

if errorlevel 1 (

    powershell.exe -NoProfile -Command "Start-Process '%~f0' -Verb RunAs"

    exit /b

)

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0allow_dns.ps1"

if errorlevel 1 (

    echo [ERROR] allow_dns.ps1 failed, error code %errorlevel%

    pause

    exit /b 1

)

exit /b 0
