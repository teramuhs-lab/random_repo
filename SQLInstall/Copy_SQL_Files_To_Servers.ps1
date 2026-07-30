$sqlservers = @('DDCWNZWGDBS07','DDCWNZWGDBS08')

# CHANGED: was "\\services-cif\services_cif\SQL Install Files\SQL2017\SQLInstall".
# That share holds the SQL2017-era tree and does NOT carry edits made on the admin
# machine, so nodes staged from it would run older scripts. Copy from the admin
# machine's own tree, which is the copy being maintained.
$folderToCopy = "C:\SQLInstall" #This is the folder that will be copied to all the servers
#$sqlservers = Get-Content "c:\temp\sqlvms.txt" #This is the list of sql servers to copy the folder to
$pathOnServers = "c$\SQLInstall" #This is the path the folder will be copied to on each server
$DriveLogOutput = "c:\temp\drivelog.txt"

# Folders and files not to send to the nodes.
#
# DO NOT blanket-exclude *.exe -- setup.exe under SQLDSC\bits\SQL2025 IS the installer,
# and vs_SSMS.exe is the SSMS bootstrapper. Only name the big standalone installers that
# this build does not read.
#
# SQL2017 is excluded because the environment config sets SQLVersion = 'SQL2025'; setup
# reads SQLDSC\bits\SQL2025. That folder alone carries a 1.4 GB ISO.
$excludeDirs  = @('SQL2017', '.git')
$excludeFiles = @('SSMS-Setup-ENU_18.11.1.exe')

Write-Output "Date: $(Get-Date -DisplayHint Date)"  | tee $DriveLogOutput

if(Test-Path -Path "$folderToCopy" -PathType Container)
{
    
    foreach ($server in $sqlservers)
    {
        #create directory for sql files
        [system.io.directory]::CreateDirectory("\\$server\c$\SQLInstall")

        if(Test-Path -Path "\\$server\$pathOnServers" -PathType Container)
        {
            Robocopy.exe /COPY:DT /MT:50 "$folderToCopy" "\\$server\$pathOnServers" /E /XD $excludeDirs /XF $excludeFiles
            # Robocopy exit codes are a bit field: 1 = files copied, 2 = extra files on the
            # destination, 3 = both. Only >= 8 contains a failure bit, so testing -ne 0
            # would report every successful copy as an error.
            if ($LASTEXITCODE -ge 8) { Write-Output "ROBOCOPY FAILED for $server (exit code $LASTEXITCODE)" }
            #Copy-Item "$folderToCopy" "\\$server\$pathOnServers" -Recurse -Force
            Invoke-Command -ComputerName $server -ScriptBlock { Get-ChildItem C:\SQLInstall -Recurse -Force | Unblock-File }
        }else
        {
            Write-Output "Having trouble accessing the computer named $server. Skipping"
        }
        
        if(Test-Path -Path "$folderToCopy\SQLDSC\modules")
        {
            if(Test-Path -Path "\\$server\c$\Program Files\WindowsPowerShell\Modules")
            { 
                Robocopy.exe /COPY:DT /MT:50 "$folderToCopy\SQLDSC\modules" "\\$server\c$\Program Files\WindowsPowerShell\Modules" /E
                if ($LASTEXITCODE -ge 8) { Write-Output "ROBOCOPY FAILED copying modules to $server (exit code $LASTEXITCODE)" }
                #Copy-Item "$folderToCopy\SQLDSC\modules" "\\$server\c$\Program Files\WindowsPowerShell" -Recurse -Force
                Invoke-Command -ComputerName $server -ScriptBlock { Get-ChildItem 'C:\Program Files\WindowsPowerShell\Modules' -Recurse -Force | Unblock-File }
                Invoke-Command -ComputerName $server -ScriptBlock { Get-PSDrive -PSProvider FileSystem } | Select-Object PSComputerName, Root | tee -Append $DriveLogOutput
            }else
            {
                write-output "Powershell modules folder doesn't exist in C:\Program Files\WindowsPowerShell\Modules for $server"
            }
            
        }else
        {
            Write-Output "SQLDSC\modules folder is missing at $folderToCopy"
        }
    }
    }else{
        Write-Output "Source folder to copy doesn't exist or permissions issue exists"
}