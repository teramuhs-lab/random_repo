@echo off
setlocal

REM Get the folder where this batch file is stored.
set "SCRIPT_DIR=%~dp0"

REM Run each PowerShell report script from the same folder as this batch file.
call :RunPowerShell "TDIS_printed_products.ps1"
call :RunPowerShell "TDIS_applications_not_issued.ps1"
call :RunPowerShell "TDIS_lockbox_status_report.ps1"
call :RunPowerShell "TDIS_completed_batches.ps1"
call :RunPowerShell "TDIS_adjudicated_batches.ps1"

call :RunPowerShell "TDIS_send_daily_email.ps1"
if errorlevel 1 exit /b %ERRORLEVEL%

REM If all scripts finished successfully, return success code 0.
exit /b 0

:RunPowerShell
REM Build the full path to the PowerShell script passed into this function.
set "PS_SCRIPT=%SCRIPT_DIR%%~1"

REM Stop with an error if the PowerShell script file does not exist.
if not exist "%PS_SCRIPT%" (
    echo ERROR: PowerShell script not found: "%PS_SCRIPT%"
    exit /b 1
)

REM Show which script is currently running.
echo Running: %~1

REM Run the PowerShell script without loading a user profile and bypass local execution policy for this run.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%PS_SCRIPT%"

REM Return the same success or failure code that PowerShell returned.
exit /b %ERRORLEVEL%
