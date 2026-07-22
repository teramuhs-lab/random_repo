@ECHO OFF

: regedit.exe /S "C:\SQLInstall\SQLDSC\Help Functions\EnableRunningPowerShellScripts.reg"

SET ThisScriptsDirectory=%~dp0
SET PowerShellScriptPath=%ThisScriptsDirectory%%~n0.ps1
IF NOT EXIST "%PowerShellScriptPath%" SET PowerShellScriptPath=%ThisScriptsDirectory%0_UnblockFile.ps1
IF NOT EXIST "%PowerShellScriptPath%" (
    ECHO.
    ECHO ERROR: Could not find "%PowerShellScriptPath%"
    PAUSE
    EXIT /B 1
)
PowerShell -NoProfile -ExecutionPolicy Bypass -Command "& {try { Start-Process PowerShell -ArgumentList '-NoExit -NoProfile -ExecutionPolicy Bypass -File ""%PowerShellScriptPath%""' -Verb RunAs -ErrorAction Stop } catch { Write-Host 'FAILED to launch elevated PowerShell:' $_.Exception.Message -ForegroundColor Red; PAUSE }}"