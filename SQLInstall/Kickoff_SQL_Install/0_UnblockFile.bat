@ECHO OFF

: regedit.exe /S "C:\SQLInstall\SQLDSC\Help Functions\EnableRunningPowerShellScripts.reg"

SET ThisScriptsDirectory=%~dp0
SET PowerShellScriptPath=%ThisScriptsDirectory%0_UnblockFile.ps1
PowerShell -NoProfile -ExecutionPolicy Bypass -Command "& {Start-Process PowerShell -ArgumentList '-NoProfile -ExecutionPolicy Bypass -File ""%PowerShellScriptPath%""' -Verb RunAs}"; 