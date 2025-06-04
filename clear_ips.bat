@echo off
:: ——— 检查是否已提升到管理员 —— 
@net session >nul 2>&1
if errorlevel 1 (
    @echo [!] 当前没有管理员权限，正在尝试以管理员身份重启脚本...
    @powershell -NoProfile -Command ^
      "Start-Process -FilePath '%~f0' -Verb RunAs"
    goto :eof
)

:: ——— 到这里就确认是管理员权限了 —— 
@echo [*] 已获得管理员权限，开始执行清理脚本...
@powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0clear_ips.ps1"

@echo [*] 操作完成！
