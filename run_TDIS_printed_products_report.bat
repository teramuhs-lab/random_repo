@echo off
setlocal

set "SCRIPT_DIR=%~dp0"
set "PS_SCRIPT=%SCRIPT_DIR%TDIS_printed_products_report.ps1"

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%PS_SCRIPT%"

exit /b %ERRORLEVEL%
