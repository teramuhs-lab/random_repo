@ECHO OFF

SET ThisScriptsDirectory=%~dp0

regedit.exe /S "%ThisScriptsDirectory%..\SQLDSC\Help Functions\EnableRunningPowerShellScripts.reg"

