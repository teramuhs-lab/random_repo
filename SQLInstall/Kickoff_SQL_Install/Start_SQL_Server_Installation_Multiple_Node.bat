@ECHO OFF

regedit.exe /S "C:\SQLInstall\SQLDSC\Help Functions\EnableRunningPowerShellScripts.reg"

SET ThisScriptsDirectory=%~dp0
SET PowerShellScriptPath=%ThisScriptsDirectory%Start_SQL_Server_Installation_Multiple_Node.ps1
PowerShell -ExecutionPolicy Bypass -Command "& {Start-Process PowerShell -ArgumentList '-ExecutionPolicy Bypass -File ""%PowerShellScriptPath%""' -Verb RunAs}"; 