@echo off
rem get_dns.bat - launcher for get_dns.py
rem get_dns.py visits the URL list (urls.txt next to it) and writes every
rem domain/IP touched during the visits to dns.txt. It replaces the old
rem get_dns.ps1 subfinder/dnsx enumerator, and needs no administrator
rem privileges. Arguments are passed through, e.g.:
rem     get_dns.bat --allow-partial

setlocal
rem UTF-8 stdout so the Chinese progress log survives redirection to files
set "PYTHONIOENCODING=utf-8"

rem Prefer the Windows py launcher, fall back to python on PATH
where py >nul 2>&1
if errorlevel 1 (
    python "%~dp0get_dns.py" %*
) else (
    py -3 "%~dp0get_dns.py" %*
)

set "rc=%errorlevel%"
endlocal & exit /b %rc%
