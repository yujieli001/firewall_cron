@echo off
:: ��Ĭ���� get_dns.ps1
powershell -WindowStyle Hidden  -NoProfile -ExecutionPolicy Bypass -File "%~dp0get_dns.ps1" >nul 2>&1

:: �ж��Ƿ��Թ���Ա�������
net session >nul 2>&1
if %errorlevel% neq 0 (
    :: ���ǹ���Ա�������Թ���Ա������б��ű�
    powershell -WindowStyle Hidden -Command ^
        "Start-Process -FilePath '%~f0' -Verb RunAs"
    exit /b
)

:: �Թ���ԱȨ�޾�Ĭ���� allow_dns.ps1
powershell -WindowStyle Hidden  -NoProfile -ExecutionPolicy Bypass -File "%~dp0allow_dns.ps1" >nul 2>&1


