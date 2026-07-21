@ECHO OFF

regedit.exe /S "C:\SQLInstall\SQLDSC\Help Functions\EnableRunningPowerShellScripts.reg"

SET ThisScriptsDirectory=%~dp0
SET PowerShellScriptPath=%ThisScriptsDirectory%Start_AG_Configuration.ps1
PowerShell -NoProfile -ExecutionPolicy Bypass -Command "& {Start-Process PowerShell -ArgumentList '-NoProfile -ExecutionPolicy Bypass -File ""%PowerShellScriptPath%""' -Verb RunAs}"; 