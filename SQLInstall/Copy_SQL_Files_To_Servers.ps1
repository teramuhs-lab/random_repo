$sqlservers = @('DDCWODWFDBS33','DDCWODWFDBS334','DDCWODWFDBS35')

$folderToCopy = "\\services-cif\services_cif\SQL Install Files\SQL2017\SQLInstall" #This is the folder that will be copied to all the servers
#$sqlservers = Get-Content "c:\temp\sqlvms.txt" #This is the list of sql servers to copy the folder to
$pathOnServers = "c$\SQLInstall" #This is the path the folder will be copied to on each server
$DriveLogOutput = "c:\temp\drivelog.txt"

Write-Output "Date: $(Get-Date -DisplayHint Date)"  | tee $DriveLogOutput

if(Test-Path -Path "$folderToCopy" -PathType Container)
{
    
    foreach ($server in $sqlservers)
    {
        #create directory for sql files
        [system.io.directory]::CreateDirectory("\\$server\c$\SQLInstall")

        if(Test-Path -Path "\\$server\$pathOnServers" -PathType Container)
        {
            Robocopy.exe /COPY:DT /MT:50 "$folderToCopy" "\\$server\$pathOnServers" /E
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