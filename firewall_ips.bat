@echo off
:: 静默运行 get_dns.ps1
powershell -WindowStyle Hidden -ExecutionPolicy Bypass -File "%~dp0get_dns.ps1" >nul 2>&1

:: 以管理员权限静默运行 allow_dns.ps1
powershell -WindowStyle Hidden -ExecutionPolicy Bypass -Command ^
  "Start-Process powershell -ArgumentList '-WindowStyle Hidden -ExecutionPolicy Bypass -File \"%~dp0allow_dns.ps1\"' -Verb RunAs" >nul 2>&1
