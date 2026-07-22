@ECHO OFF

SET ThisScriptsDirectory=%~dp0

regedit.exe /S "%ThisScriptsDirectory%..\SQLDSC\Help Functions\EnableRunningPowerShellScripts.reg"

SET PowerShellScriptPath=%ThisScriptsDirectory%%~n0.ps1
IF NOT EXIST "%PowerShellScriptPath%" SET PowerShellScriptPath=%ThisScriptsDirectory%Start_SQL_Server_Installation_Multiple_Node.ps1
IF NOT EXIST "%PowerShellScriptPath%" (
    ECHO.
    ECHO ERROR: Could not find "%PowerShellScriptPath%"
    PAUSE
    EXIT /B 1
)
PowerShell -ExecutionPolicy Bypass -Command "& {try { Start-Process PowerShell -ArgumentList '-NoExit -ExecutionPolicy Bypass -File ""%PowerShellScriptPath%""' -Verb RunAs -ErrorAction Stop } catch { Write-Host 'FAILED to launch elevated PowerShell:' $_.Exception.Message -ForegroundColor Red }}"
IF %ERRORLEVEL% NEQ 0 (
    ECHO.
    ECHO PowerShell launcher command exited with error level %ERRORLEVEL%.
)

ECHO.
ECHO If no new elevated PowerShell window opened, check for a UAC prompt you may have missed,
ECHO or a "FAILED to launch" message above.
PAUSE