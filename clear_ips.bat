@echo off
:: ������ ����Ƿ�������������Ա ���� 
@net session >nul 2>&1
if errorlevel 1 (
    @echo [!] ��ǰû�й���ԱȨ�ޣ����ڳ����Թ���Ա��������ű�...
    @powershell -NoProfile -Command ^
      "Start-Process -FilePath '%~f0' -Verb RunAs"
    goto :eof
)

:: ������ �������ȷ���ǹ���ԱȨ���� ���� 
@echo [*] �ѻ�ù���ԱȨ�ޣ���ʼִ������ű�...
@powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0clear_ips.ps1"

@echo [*] ������ɣ�
