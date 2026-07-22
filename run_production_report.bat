@echo off
setlocal

REM Get the folder where this batch file is stored.
set "SCRIPT_DIR=%~dp0"

call :RunPowerShell "production_report .ps1"
call :RunPowerShell "production_report_email.ps1"
if errorlevel 1 exit /b %ERRORLEVEL%

exit /b 0

:RunPowerShell
set "PS_SCRIPT=%SCRIPT_DIR%%~1"

if not exist "%PS_SCRIPT%" (
    echo ERROR: PowerShell script not found: "%PS_SCRIPT%"
    exit /b 1
)

echo Running: %~1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%PS_SCRIPT%"
exit /b %ERRORLEVEL%
