@echo off
@echo �����ռ�DNS��Ϣ...
@powershell -ExecutionPolicy Bypass -File "%~dp0dns2ips.ps1"

@echo �������÷���ǽ...
@powershell -ExecutionPolicy Bypass -Command "Start-Process powershell -ArgumentList '-ExecutionPolicy Bypass -File \"%~dp0allow_ips.ps1\"' -Verb RunAs"

@echo ������ɣ�