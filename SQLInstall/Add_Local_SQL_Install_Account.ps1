<#
.SYNOPSIS
    Creates (or recreates) the local 'SQLInstallAcc' account and adds it to Administrators
    on each server in $SQLServers..
.DESCRIPTION
    Pings every server in $SQLServers first; only proceeds if all of them respond. Then, for
    the password, prompts once locally (never hardcode it - PowerShell remoting can't decrypt a
    SecureString created on this machine when it arrives on a different one, so the plaintext is
    passed via -ArgumentList and re-wrapped into a SecureString inside the remote scriptblock -
    it only ever lives in memory, never on disk).
.NOTES
    Please comply with your organization's password policy (length and complexity) when prompted.
#>

[string[]]$SQLServers = @('DDCWODWFDBS33','DDCWODWFDBS34','DDCWODWFDBS35')
[string[]]$UnresponsiveSQLServers = @()
[int]$Counter = 0
ForEach ($Server in $SQLServers) {
if ((Test-Connection -ComputerName $Server -ErrorAction SilentlyContinue) -ne $null) {
$Counter++
}
else {
$UnresponsiveSQLServers += $Server
}
}
if ($Counter -eq $SQLServers.Count) {
Write-Host "Adding local account, 'SQLInstallAcc', to the following servers: $SQLServers" -ForegroundColor Green

$sqlInstallAccCred = Get-Credential -UserName 'SQLInstallAcc' -Message 'Enter the password to set for the local SQLInstallAcc account on the target servers'
$plainPassword = $sqlInstallAccCred.GetNetworkCredential().Password

Invoke-Command -ComputerName $SQLServers -WarningAction SilentlyContinue -ArgumentList $plainPassword -ScriptBlock {
param($PlainPassword)
$VerbosePreference = 'SilentlyContinue' # Continue, SilentlyContinue
[string]$LocalGroup = 'Administrators'
[string]$Member = 'SQLInstallAcc'
[SecureString]$UserPassword = ConvertTo-SecureString $PlainPassword -AsPlainText –Force
[string]$Description = 'SQL Server 2017 with PowerShell DSC'
[object[]]$Result = @()
$Result = Get-LocalUser | Select Name
Write-Verbose $LocalGroup
Write-Verbose $Member
Write-Verbose $Description
$Result | ForEach-Object {
Write-Verbose $_.Name
if($_.Name -eq $Member) {
Remove-LocalUser -Name $Member
}
}
# Add retry logic for no password case.
New-LocalUser -Name $Member -Password $UserPassword -Description $Description | Out-Null
Add-LocalGroupMember -Group $LocalGroup -Member $Member
Write-Host "Added $Member to $env:COMPUTERNAME." -ForegroundColor Green
}
}
else {
$UnresponsiveSQLServers = $UnresponsiveSQLServers -join ','
Write-Host "One or more of the following servers were inaccessible: $UnresponsiveSQLServers. Task did not initiate." -ForegroundColor Red
}