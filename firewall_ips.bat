@echo off
:: 静默运行 dns2ips.ps1
powershell -WindowStyle Hidden -ExecutionPolicy Bypass -File "%~dp0dns2ips.ps1" >nul 2>&1

:: 以管理员权限静默运行 allow_ips.ps1
powershell -WindowStyle Hidden -ExecutionPolicy Bypass -Command ^
  "Start-Process powershell -ArgumentList '-WindowStyle Hidden -ExecutionPolicy Bypass -File \"%~dp0allow_ips.ps1\"' -Verb RunAs" >nul 2>&1
