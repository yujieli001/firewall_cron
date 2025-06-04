@echo off
@echo 正在收集DNS信息...
@powershell -ExecutionPolicy Bypass -File "%~dp0dns2ips.ps1"

@echo 正在启用防火墙...
@powershell -ExecutionPolicy Bypass -Command "Start-Process powershell -ArgumentList '-ExecutionPolicy Bypass -File \"%~dp0allow_ips.ps1\"' -Verb RunAs"

@echo 操作完成！