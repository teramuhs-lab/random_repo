#Requires -Version 5.1

# Get-DscConfigurationStatus -CimSession PPTPOC12K12V001,PPTPOC12K12V002,PPTPOC12K12V003 
# Remove-DscConfigurationDocument -CimSession PPTPOC12K12V001,PPTPOC12K12V002,PPTPOC12K12V003 -Stage Pending -Force
# Stop-DscConfiguration -CimSession PPTPOC12K12V001,PPTPOC12K12V002,PPTPOC12K12V003 
# (Get-DscResource | Out-GridView -PassThru).Properties;

#Change the number of line limit in the console
Write-Host "Changint the scroll back buffer for the console"
#mode con cols=125 lines=32766
mode con lines=32766

#CD C:\SQLInstall\SQLDSC 
#$envDataFilePath = 'C:\SQLInstall\SQLDSC\environments\CAPPT_sqlAG_Enviroment_Data.psd1'
#$envData = Invoke-Expression (Get-Content -Path $envDataFilePath | Out-String)

# Figure out where we are
$invokedScriptPath = $PSCommandPath
if ( [string]::IsNullOrEmpty($invokedScriptPath) ) { $invokedScriptPath = $MyInvocation.MyCommand.Path }
$scriptPath = Split-Path ( Split-Path $invokedScriptPath -Parent ) -Parent

$scriptLocation = $scriptPath + "\SQLDSC" 
Set-Location $scriptLocation 


#Set-ExecutionPolicy 
<#
Push-Location
Set-Location HKLM:\Software\Policies\Microsoft\Windows\PowerShell
Set-ItemProperty . ExecutionPolicy "Bypass"
Pop-Location

Set-ExecutionPolicy -ExecutionPolicy Bypass
#>
# Import the helper functions
Import-Module -Name ( Join-Path -Path "$($scriptPath)\SQLDSC\Help Functions" -ChildPath HelperFunctions.psm1 ) -DisableNameChecking
#Import-Module -Name 'C:\SQLInstall\SQLDSC\Help Functions\HelperFunctions.psm1' -DisableNameChecking

$script:CurrentStep = $null
$script:CurrentStepStartWarnCount = 0
$script:StepLog = [System.Collections.Generic.List[PSCustomObject]]::new()

# Shared counter incremented only by explicit [WARN] messages (here and in the helper
# functions/DSC deploy script) -- unlike $Error.Count, this only reflects things that
# were actually shown on screen, not incidental non-terminating errors from cmdlets
# like Resolve-DnsName that never produce visible output.
$global:SQLInstallWarningCount = 0

function Write-Banner {
    param(
        [Parameter(Mandatory)][string]$Message,
        [ConsoleColor]$Color = 'Cyan'
    )
    # Close out the step that's ending, recording whether it had any [WARN] messages
    if ($script:CurrentStep) {
        $warningsDuringStep = $global:SQLInstallWarningCount - $script:CurrentStepStartWarnCount
        $script:StepLog.Add( [PSCustomObject]@{ Step = $script:CurrentStep; ErrorCount = $warningsDuringStep } )
    }
    $script:CurrentStep = $Message
    $script:CurrentStepStartWarnCount = $global:SQLInstallWarningCount

    $line = '=' * 80
    Write-Host ""
    Write-Host $line -ForegroundColor $Color
    Write-Host " $Message" -ForegroundColor $Color
    Write-Host $line -ForegroundColor $Color
}

function Write-StepSummary {
    # Close out whichever step was still in progress when the run ended
    if ($script:CurrentStep) {
        $warningsDuringStep = $global:SQLInstallWarningCount - $script:CurrentStepStartWarnCount
        $script:StepLog.Add( [PSCustomObject]@{ Step = $script:CurrentStep; ErrorCount = $warningsDuringStep } )
        $script:CurrentStep = $null
    }

    Write-Host ""
    Write-Host ("=" * 80) -ForegroundColor Cyan
    Write-Host " STEP SUMMARY (errors/warnings by step -- some may be expected/benign)" -ForegroundColor Cyan
    Write-Host ("=" * 80) -ForegroundColor Cyan
    foreach ($s in $script:StepLog) {
        if ($s.ErrorCount -gt 0) {
            Write-Host ("  [{0,2} error(s)] {1}" -f $s.ErrorCount, $s.Step) -ForegroundColor Red
        }
        else {
            Write-Host ("  [OK]         {0}" -f $s.Step) -ForegroundColor Green
        }
    }
    Write-Host ("=" * 80) -ForegroundColor Cyan
}

try {

#region** # Verify we are running this script as an administrator LOCALLY

Write-Banner "STEP 1 of 14: Verifying administrator privileges"
Test-IsAdmin
Write-Host "  [OK] Running as Administrator" -ForegroundColor Green

#endregion


#region** Get the environment config Data(settings) files to work with
Write-Banner "STEP 2 of 14: Select environment configuration file"
Write-Host "  Select an environment in the picker window, then click OK." -ForegroundColor Yellow

$settingsPath = Join-Path -Path $scriptPath -ChildPath "\SQLDSC\Environments"
$settingsFile = Select-EnvironmentSettings -settingsPath $settingsPath
#$settingsFile = Select-EnvironmentSettings -settingsPath C:\SQLInstall\SQLDSC\environments
Write-Host "  [OK] Selected: $($settingsFile.BaseName)" -ForegroundColor Green

#endregion

#region *** Edit Config Data Selected and Opened in ISE and Save
Write-Banner "STEP 3 of 14: Review and edit configuration"
Write-Host "  Opening '$($settingsFile.BaseName)' in PowerShell ISE." -ForegroundColor Green
Write-Host "  Edit the file as needed, SAVE it, then return here." -ForegroundColor Green

#Open Config Data Selected in PowerShell ISE
Start-Process PowerShell_ISE $settingsFile.FullName

Write-Host "  Have you edited and saved the config file? [y/n]" -ForegroundColor Yellow
$confirmation = Read-Host
while($confirmation -ne "y" ) {
    if ($confirmation -eq 'n') {
        Write-Host "  Please make sure the config file is edited and saved before continuing." -ForegroundColor Yellow
    }

    Write-Host "  Have you edited and saved the config file? [y/n]" -ForegroundColor Yellow
    $confirmation = Read-Host

}
Write-Host "  [OK] Continuing with saved configuration." -ForegroundColor Green

#endregion ***


#region *** Import/Read Config Data once it is Edited and Saved

    # Import the configuration data
    #Remove-Variable -Name ConfigDate -ErrorAction SilentlyContinue
    #. $settingFile.FullName

    Write-Banner "STEP 4 of 14: Loading configuration data"
    $envData = Invoke-Expression (Get-Content $settingsFile.FullName  | Out-String)
    Write-Host "  [OK] Configuration loaded." -ForegroundColor Green

#endregion ***

#region ** Get credential for Installation account and Service accounts

    Write-Banner "STEP 5 of 14: Collecting credentials"
    Write-Host "  Enter the Install Admin credential (Domain\AdminAccount):" -ForegroundColor Yellow
    $InstallAccount   =  Get-Credential -Message 'Enter Install Admin Credential (Domain\AdminAccount)'   -User 'DOMAIN\admuser'
    #$InstallAccount   =  Get-Credential -Message 'Enter Install Admin Credential (Domain\AdminAccount)'   -User 'contoso\dantem'

    Write-Host "  Enter Service Account credentials as prompted:" -ForegroundColor Yellow

    #SQL Server Engine Service Account
    #Write-Host "Hit Cancel without typing user name and password if you want to use Virtual default Engine service account(Service SID)" -ForegroundColor yellow
    If($envData.AllNodes.SQLServiceAccount -ne $null ) {
        $sqlServiceCred   = Get-Credential -Message '
        Enter SQL Database Engine Service Account
    
        N.B. Hit Cancel without typing password if you want to use Virtual default Engine service account(Service SID)' -User $envData.AllNodes.SQLServiceAccount ; 
    }
    else {
        $sqlServiceCred = $null
    }


    #SQL Server Agent Service Account
    #Instead of cancelling the Pop-up it is preffered to set SQLServiceAccount and SQLAgentServiceAccount to $null in config file
    #Write-Host "Hit Cancel without typing user name and password if you want to use Virtual default Agent service account(Service SID)" -ForegroundColor yellow

    If($envData.AllNodes.SQLAgentServiceAccount -ne $null ) {
        $sqlAgentCred     = Get-Credential -Message '
        Enter SQL Agent Service Account
    
        N.B. Hit Cancel without typing password if you want to use Virtual default Agent service account(Service SID)'  -User $envData.AllNodes.SQLAgentServiceAccount ;
    } 
    else {
        $sqlAgentCred = $null
    }




    #Local account for SQL install and patching

    If($envData.NonNodeData.SQL.LocalInstallAccount -ne $null ) {
        $LocalInstallAccount     = Get-Credential -Message 'Enter NEW Password for Local Admin Install Account'  -User $envData.NonNodeData.SQL.LocalInstallAccount ;
    } 
    else {
        $LocalInstallAccount     = Get-Credential -Message 'Enter USERNAME and Password for Local Admin Install Account'  -User $envData.NonNodeData.SQL.LocalInstallAccount ;
    }


    #$username         = "localhost\SQLInstallAccount";  
    #$username         = "SQLInstallAcc"; 
    #$password         = "SQLServer2050@#@1" | ConvertTo-SecureString -asPlainText -Force;
    #$LocalInstallAccount = New-Object System.Management.Automation.PSCredential($username,$password); 
    #$LocalInstallAccount     = Get-Credential -Message 'Enter Password for Local Install Account'  -User $username

    $password         = $NULL;
    $username         = $NULL;

    Write-Host "  [OK] Credentials collected." -ForegroundColor Green

#endregion

#region *** Check PowerShell Remoting and PowerShell Version(should be > 5)

    #while ( -not ( Get-Variable -Name psSessions -ErrorAction SilentlyContinue ) )
    Write-Banner "STEP 6 of 14: Verifying connectivity and PowerShell remoting"

    $nodes = ( $envData.AllNodes.NodeName | Where-Object { $_ -ne '*' } | Select-Object -Unique )
    $ComputerNameFQDN = $nodes | ForEach-Object { Resolve-DnsName -Name $_ } | Select-Object -ExpandProperty Name

    foreach ($Computer in $ComputerNameFQDN ) {

        #TO DO: Ping servers before doing anything, exit if a server is not reacheable
        try {
        $pingResult = Test-NetConnection $Computer -ErrorAction Stop
        if ( -not $pingResult.PingSucceeded ) { throw "Ping failed" }
        Write-Host "  [OK] $Computer is reachable" -ForegroundColor Green
        }
        catch
	    {

            throw "Could not ping remote server $Computer. Make Sure Server is up"

            # Write-Host $Error
	    }


        #Check powershell remoting
        try {
        $psSessions = New-PSSession -ComputerName $Computer -Credential $InstallAccount -ErrorAction Stop
        }

        catch
	    {

            throw "Could not re-create psSessions to the remote server $Computer. Make Sure Server is up, PowerShell remoting is enabled and firewall is Open."
            # Write-Host $Error
	    }

        #Check PowerShell Versions
        if ($psSessions -ne $null ) {
            $needWmf5 = Invoke-Command -Session $psSessions -ScriptBlock { $PSVersionTable.PSVersion } | Where-Object { $_.Major -lt 5 } | select -ExpandProperty psComputerName
            if ( $needWmf5 -ne $null ) {
            throw 'Make Sure PowerShell Version on target nodes is is atleaset Version 5.'
            }
            Write-Host "  [OK] PowerShell remoting verified on $Computer" -ForegroundColor Green

        # Clean up the PS Sessions
        if ($psSessions -ne $null ) {
        $psSessions | Remove-PSSession
        Remove-Variable -Name psSessions
        }

        }


    }

		#if ( $needWmf5 -ne $null ) { throw 'Make Sure PowerShell Version on target nodes is is atleaset Version 5.' }
	


    # Clean up the PS Sessions
    if ($psSessions -ne $null ) {
    $psSessions | Remove-PSSession
	Remove-Variable -Name psSessions
    }

#endregion ***


#region *** ADD Local Install Account to Administrators Group
Write-Banner "STEP 7 of 14: Adding local install account to Administrators group"
$nodes = ( $envData.AllNodes.NodeName | Where-Object { $_ -ne '*' } | Select-Object -Unique )

    ForEach ($targetNode in $nodes) {
        Write-Host "  Adding $($LocalInstallAccount.username) to Administrators on $targetNode" -ForegroundColor Yellow
        
        Add-UserToLocalGroup -UserName "$($targetNode)\$($envData.NonNodeData.SQL.LocalInstallAccount)" -ComputerName $targetNode -LocalGroupName 'Administrators'  -ErrorAction SilentlyContinue

        
    }

  

#endregion ***


#region *** ADD DBA ADM Group to Local Administrators Group
Write-Banner "STEP 8 of 14: Adding DBA/admin groups to Administrators group"
$nodes = ( $envData.AllNodes.NodeName | Where-Object { $_ -ne '*' } | Select-Object -Unique )

# One call covering all nodes -- Add-UserToLocalGroup already loops over -ComputerName
# internally, so looping over $nodes here too would just repeat the whole operation
# once per node for no reason.
Write-Host "  Adding $($envData.NonNodeData.SQL.LocalServerAdmins) to Administrators on $($nodes -join ', ')" -ForegroundColor Yellow
Add-UserToLocalGroup -UserName $envData.NonNodeData.SQL.LocalServerAdmins -ComputerName $nodes -LocalGroupName 'Administrators'  -ErrorAction SilentlyContinue

    

#endregion ***

#region *** Give each computer account permission to fileshare where SQL binary and DSC resources are stored

Write-Banner "STEP 9 of 14: Granting fileshare permissions"

#Grant fileshare permission to the computer accounts for each node
Grant-SmbSharePermissions -Path $envData.NonNodeData.Data.DSCResourceLocation -Computer $nodes -ShareAccessRight FULL -FileSystemRights FullControl

#Grant fileshare permission to Install Account
#Grant-SmbSharePermissions -Path $envData.NonNodeData.Data.DSCResourceLocation -user $envData.NonNodeData.SQL.SQLSysAdminAccounts -ShareAccessRight FULL -FileSystemRights FullControl  
Grant-SmbSharePermissions -Path $envData.NonNodeData.Data.DSCResourceLocation -user $InstallAccount.UserName -ShareAccessRight FULL -FileSystemRights FullControl  


#endregion ***


#region *** Create SQLServices Local Group
Write-Banner "STEP 10 of 14: Creating SQLServices local group"
$nodes = ( $envData.AllNodes.NodeName | Where-Object { $_ -ne '*' } | Select-Object -Unique )
create-LocalGroup -LocalGroupName 'SQLServices' -ComputerName $nodes -GroupDescription 'Local Group to hold SQL Server related Service Accounts'
#endregion ***



#region *** Update GPO after creating SQLServices Group
Write-Banner "STEP 11 of 14: Updating Group Policy"
Write-Host "  Installing Group Policy PowerShell module..." -ForegroundColor Yellow
Install-WindowsFeature -Name GPMC


Write-Host "  Refreshing Group Policy on target servers..." -ForegroundColor Yellow
$nodes = ( $envData.AllNodes.NodeName | Where-Object { $_ -ne '*' } | Select-Object -Unique )
$ComputerNameFQDN = $nodes | ForEach-Object { Resolve-DnsName -Name $_ } | Select-Object -ExpandProperty Name

#Invoke-GPUpdate -Computer 'SQL1' –RandomDelayInMinutes 0 -Force
$ComputerNameFQDN | ForEach-Object { Invoke-GPUpdate –Computer $_ -Force -RandomDelayInMinutes 0 -Verbose}
Write-Host "  [OK] Group Policy refreshed." -ForegroundColor Green

#endregion ***


#region *** verify Install Account is Local ADMIN on Target Servers

    Write-Banner "STEP 12 of 14: Verifying install account is local admin on target servers"

    # Get the nodes specified in the configuration settings file
	$nodes = ( $envData.AllNodes.NodeName | Where-Object { $_ -ne '*' } | Select-Object -Unique )

	# Get the short names of the nodes. Some cmdlets don't like the FQDN
	#Commented out this one since computer names listed in config file is ShortName.
    #[array]$nodeShortNames = Get-WmiObject -ComputerName $nodes -Class Win32_ComputerSystem | Select-Object -ExpandProperty Name
    

    # Convert the computer names to FQDN in order to support cross-domain Kerberos tickets
	$ComputerNameFQDN = $nodes | ForEach-Object { Resolve-DnsName -Name $_ } | Select-Object -ExpandProperty Name

	# Verify the installation account is a local administrator
    $doNotAddTo = @()
    #foreach($computer in $ComputerNameFQDN ) {}
    
    $doNotAddTo = Get-LocalGroupMembers -ComputerName $ComputerNameFQDN -LocalGroupName 'Administrators' | Where-Object { $_.Name -eq $InstallAccount.UserName.Split('\')[1] } | select -ExpandProperty Computer
    	
	if ( [string]::IsNullOrEmpty($doNotAddTo) )
	{
		# Add the installation account to the local admins on all the boxes
		Add-UserToLocalGroup -UserName $InstallAccount.UserName -LocalGroupName 'Administrators' -ComputerName $ComputerNameFQDN
	}
	else
	{
		# Add the installation account to the local admins on all the other computers
		Add-UserToLocalGroup -UserName $InstallAccount.UserName -LocalGroupName 'Administrators' -ComputerName ( Compare-Object -ReferenceObject $ComputerNameFQDN -DifferenceObject $doNotAddTo | select -ExpandProperty InputObject )
	}
    Write-Host "  [OK] Install account verified as local admin." -ForegroundColor Green


#endregion ***


<#
#region** Give SQL Server Service account Full permission to Registry for auditing to work properly

#TODO: ADD the group that contains SQL Server Service account (either local or AD group) as opposed to individual service account 
#TODO: make this work remotely for muliple target nodes.

    Write-Host "Giving SQL Server Service account Full permission to Registry HKLM:\SYSTEM\CurrentControlSet\Services\EventLog\Security for auditing to work properly.." -ForegroundColor Yellow
    Write-Host ""

    If($envData.AllNodes.SQLServiceAccount -ne $null ) {

        Write-Host "Giving SQL Server Service Account full permission to Registry HKLM:\SYSTEM\CurrentControlSet\Services\EventLog\Security" -ForegroundColor yellow
        Write-Host " "

        $RegistryKeyPath = 'HKLM:\SYSTEM\CurrentControlSet\Services\EventLog\Security'
        $acl = Get-Acl -Path $RegistryKeyPath
        #$rule = New-Object System.Security.AccessControl.RegistryAccessRule ($envData.AllNodes.SQLServiceAccount,"FullControl","Allow")
        $rule = New-Object System.Security.AccessControl.RegistryAccessRule ($envData.AllNodes.SQLServiceAccount,"FullControl",@("ObjectInherit","ContainerInherit"),"None","Allow")
        $acl.SetAccessRule($rule)
        $acl | Set-Acl -Path $RegistryKeyPath

    }

#endregion
#>


#region *** copy powershell modules to each node



    Write-Banner "STEP 13 of 14: Copying DSC resources"
<#
    # Get the nodes specified in the configuration settings file
    $nodes = ( $envData.AllNodes.NodeName | Where-Object { $_ -ne '*' } | Select-Object -Unique )
    ForEach ($targetNode in $nodes) {
        $Destination = "\\"+$targetNode+"\c$\Program Files\WindowsPowerShell\Modules"
        #Copy-Item '\\PPTPOC12K12V003\Temp\SQLInstall\DSCResourceModules\*' -Destination $Destination -Recurse -Force -ErrorAction Stop
        Copy-Item "$($envData.NonNodeData.Data.DSCResourceLocation)\*" -Destination $Destination -Recurse -Force 

    }
#>
    #copy file to localy (install/Admin machine)
    #Temporariy commented out since this part is moved to Step_0 script - unblock file and copy module to install/Admin machine
    if ($envData.NonNodeData.Data.CopyDSCResources_to_AdminMachine -eq 'YES') {

    Copy-Item "$($envData.NonNodeData.Data.DSCResourceLocation)\*" -Destination "C:\Program Files\WindowsPowerShell\Modules" -Recurse -Force -Verbose

    }
    Write-Host "  [OK] DSC resources copied." -ForegroundColor Green
#endregion ***



$param = @{
    envDataFilePath = $settingsFile.FullName
    #envDataFilePath = 'C:\SQLInstall\SQLDSC\environments\CAPPT_sqlAG_Enviroment_Data_001.psd1'
    InstallAccount = $InstallAccount    
    #SQLServiceAccount = $InstallAccount  #  $sqlServiceCred # $null # 
    SQLServiceAccount = if ($sqlServiceCred -eq $null) {$null} else {$sqlServiceCred}
    #SQLAgentServiceAccount = $InstallAccount # $null  # $sqlAgentCred # 
    SQLAgentServiceAccount = if ($sqlAgentCred -eq $null) {$null} else {$sqlAgentCred}
    LocalInstallAccount = $LocalInstallAccount
    # Read the version from the environment config's NonNodeData.SQL.SQLVersion if it's
    # set there (e.g. 'SQL2025'), falling back to the previous hardcoded 'SQL2017' default
    # so existing environment files that don't set it keep behaving exactly as before.
    Version = if ( -not [string]::IsNullOrEmpty($envData.NonNodeData.SQL.SQLVersion) ) { $envData.NonNodeData.SQL.SQLVersion } else { "SQL2017" }
}


Write-Banner "STEP 14 of 14: Deploying SQL Server installation (DSC)" "Magenta"
Write-Host "  Detailed DSC/LCM progress below is normal -- look for '[OK]' lines and any red errors." -ForegroundColor Yellow

#& (Join-Path -Path $scriptLocation -ChildPath "configs\Install_and_Configure_SQLServer_Multi_Node.ps1") @param -Verbose

& (Join-Path -Path $scriptLocation -ChildPath "configs\Install_and_Configure_SQLServer_Multi_Node.ps1") @param -Deploy -Verbose

Write-Banner "Installation script finished. Review the log above for [OK] markers and any errors." "Magenta"

}
catch {
    Write-Host ""
    Write-Host ("=" * 80) -ForegroundColor Red
    Write-Host " SCRIPT FAILED" -ForegroundColor Red
    Write-Host " Failed during: $($script:CurrentStep)" -ForegroundColor Red
    Write-Host " Error: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host " At line $($_.InvocationInfo.ScriptLineNumber): $($_.InvocationInfo.Line.Trim())" -ForegroundColor Red
    Write-Host ("=" * 80) -ForegroundColor Red
}
finally {
    Write-StepSummary
}

#AG listener
<#
$paramAGListener = @{
    envDataFilePath = $settingsFile.FullName
    #envDataFilePath = 'C:\SQLInstall\SQLDSC\environments\CAPPT_sqlAG_Enviroment_Data_001.psd1'
    InstallAccount = $InstallAccount
}
#C:\SQLInstall\SQLDSC\configs\Create_Listener.ps1 @paramAGListener -Verbose
C:\SQLInstall\SQLDSC\configs\Create_Listener.ps1 @paramAGListener -Deploy -Verbose
#>

# If running in the console, wait for input before closing.
if ($Host.Name -eq "ConsoleHost")
{ 
    Write-Host "Press any key to continue..."
    $Host.UI.RawUI.FlushInputBuffer()   # Make sure buffered input doesn't "press a key" and skip the ReadKey().
    $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyUp") > $null
} 

# SIG # Begin signature block
# MIIXtQYJKoZIhvcNAQcCoIIXpjCCF6ICAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCC+oCtgSnhdkdEl
# g69lSc9ec2FaAgbodX+Opcbm97hM6KCCFJQwggo1MIIIHaADAgECAgRRsGn6MA0G
# CSqGSIb3DQEBCwUAMIGxMRMwEQYKCZImiZPyLGQBGRYDc2J1MRUwEwYKCZImiZPy
# LGQBGRYFc3RhdGUxFjAUBgNVBAMMDUNvbmZpZ3VyYXRpb24xETAPBgNVBAMMCFNl
# cnZpY2VzMRwwGgYDVQQDDBNQdWJsaWMgS2V5IFNlcnZpY2VzMQwwCgYDVQQDDANB
# SUExLDAqBgNVBAMMI1UuUy4gRGVwYXJ0bWVudCBvZiBTdGF0ZSBBRCBSb290IENB
# MB4XDTE4MDMwNjIxMjQ1NFoXDTI4MDMwNjIxNTQ1NFowgbsxEzARBgoJkiaJk/Is
# ZAEZFgNzYnUxFTATBgoJkiaJk/IsZAEZFgVzdGF0ZTEWMBQGA1UEAwwNQ29uZmln
# dXJhdGlvbjERMA8GA1UEAwwIU2VydmljZXMxHDAaBgNVBAMME1B1YmxpYyBLZXkg
# U2VydmljZXMxDDAKBgNVBAMMA0FJQTE2MDQGA1UEAwwtVS5TLiBEZXBhcnRtZW50
# IG9mIFN0YXRlIEFEIEhpZ2ggQXNzdXJhbmNlIENBMIICIjANBgkqhkiG9w0BAQEF
# AAOCAg8AMIICCgKCAgEAsC5Y6WPuuADIdbZ3V86ziP/HlQzA71sTqDhbBwP6qUiQ
# Zl7YNiR7LvV1tmQTaByVz3TWWvZOCnvr6K6Sol4BWepD7iffZ8AMvvSuX7NyMGCa
# ak7SGtCbJchhrdDo6D4rGmcPx/74iogTEukw4l3SiIq86O443YqLAXp9fXAhVXU3
# EonV4/QTctu8Ve76ldqbEnPff3b7sgl59gv1jdTLC7O8bO+EXV/Z5Q1X2N+v7zR4
# phQL7+Cle056sgTe3O8SLNRI2My+Md0OlNVveO/nVgVEj0JNV4vNQiiB0GqGld33
# 0ydkt8JPAwsaKedmlErXCeFd/41d2FFbC9UzsafO9jzS6GAYImHtsrL7RDtrNOG0
# sqK2I4NEqQUUylvXdd/76xVJVqiZCLCD3yV3+rG3jzDgOQaPVuK4QDCSRazcZSks
# dGIE+8fOAWtfOj4cVDGlHRCu99O0K19J/N4ZHwbeQVCOWmLAjWXLudrzHvgljkG4
# 81Qxcvv+Ucvdv4bcLn/MgqPbpKGHYXy6/tAO8gt9n/+bKmMuLbIrxuR4Kpz0BA8V
# 4gmr5nrC7V5uCLryUZ4HlZNm4vXqPgC0dgtHzK1yuxyu++WTPJdDLwetGMw2jVd0
# 1wnyZY8rlLoifWc5b9Gp3WWgoWToHedL+X8Pcp1+DeTOCUCDh0ETNONouI7TjkUC
# AwEAAaOCBEcwggRDMA4GA1UdDwEB/wQEAwIBBjBrBgNVHSAEZDBiMAwGCmCGSAFl
# AwIBBgEwDAYKYIZIAWUDAgEGAjAMBgpghkgBZQMCAQYDMAwGCmCGSAFlAwIBBgQw
# DAYKYIZIAWUDAgEGDDAMBgpghkgBZQMCAQYlMAwGCmCGSAFlAwIBBiYwggFyBggr
# BgEFBQcBAQSCAWQwggFgMIHYBggrBgEFBQcwAoaBy2xkYXA6Ly9kaXIucGtpLnN0
# YXRlLmdvdi9jbj1VLlMuJTIwRGVwYXJ0bWVudCUyMG9mJTIwU3RhdGUlMjBBRCUy
# MFJvb3QlMjBDQSxjbj1BSUEsY249UHVibGljJTIwS2V5JTIwU2VydmljZXMsY249
# U2VydmljZXMsY249Q29uZmlndXJhdGlvbixkYz1zdGF0ZSxkYz1zYnU/Y0FDZXJ0
# aWZpY2F0ZTtiaW5hcnksY3Jvc3NDZXJ0aWZpY2F0ZVBhaXI7YmluYXJ5MEYGCCsG
# AQUFBzAChjpodHRwOi8vY3Jscy5wa2kuc3RhdGUuZ292L0FJQS9DZXJ0c0lzc3Vl
# ZFRvRG9TQURSb290Q0EucDdjMDsGCCsGAQUFBzABhi9odHRwOi8vb2NzcC5wa2ku
# c3RhdGUuZ292L09DU1AvRG9TT0NTUFJlc3BvbmRlcjASBgNVHRMBAf8ECDAGAQH/
# AgEAMAwGA1UdJAQFMAOBAQAwggHqBgNVHR8EggHhMIIB3TCCAQqgggEGoIIBAoYy
# aHR0cDovL2NybHMucGtpLnN0YXRlLmdvdi9jcmxzL0RvU0FEUEtJUm9vdENBMS5j
# cmyGgctsZGFwOi8vZGlyLnBraS5zdGF0ZS5nb3YvY249V2luQ29tYmluZWQxLGNu
# PVUuUy4lMjBEZXBhcnRtZW50JTIwb2YlMjBTdGF0ZSUyMEFEJTIwUm9vdCUyMENB
# LGNuPUFJQSxjbj1QdWJsaWMlMjBLZXklMjBTZXJ2aWNlcyxjbj1TZXJ2aWNlcyxj
# bj1Db25maWd1cmF0aW9uLGRjPXN0YXRlLGRjPXNidT9jZXJ0aWZpY2F0ZVJldm9j
# YXRpb25MaXN0O2JpbmFyeTCBzKCByaCBxqSBwzCBwDETMBEGCgmSJomT8ixkARkW
# A3NidTEVMBMGCgmSJomT8ixkARkWBXN0YXRlMRYwFAYDVQQDDA1Db25maWd1cmF0
# aW9uMREwDwYDVQQDDAhTZXJ2aWNlczEcMBoGA1UEAwwTUHVibGljIEtleSBTZXJ2
# aWNlczEMMAoGA1UEAwwDQUlBMSwwKgYDVQQDDCNVLlMuIERlcGFydG1lbnQgb2Yg
# U3RhdGUgQUQgUm9vdCBDQTENMAsGA1UEAwwEQ1JMMTAfBgNVHSMEGDAWgBTMAGhh
# pqUDkxAKG2G3hxjBRVbagjAdBgNVHQ4EFgQUheMozyV6pgGNxW/+xVJyqp6jTE4w
# DQYJKoZIhvcNAQELBQADggIBAIrI6BcRMOZyzGy2Zs9M16r7yK2OYW51BBYc/Z2q
# tPOpMF1n3PsnrTw3dill5SlMLctqIhKTWcgUyy+35O8Um2IFvdOgo0G848rYzxAz
# TTmMDADvzl++KDnfIks1TXmFjh1K1AbqC6D/kxENHQMBMWV8FE7t8JshdIQ2Hg5C
# BfHdIMoG9SU3t18cYNjzmJz/pUQ8g5ckXegBjDiSvby8V1zceSPdGOoPQZQp+dH5
# C1BhNQzY6mlE5zoW7ogfWBBghi07fyC+0T06Ffoffe8mHKzE6qsP+F0ql3G7o3xc
# rT1EMAbCRCy0E3OoFRdsZ+gz73Y/pu+QKJ3CRms0bDO5+5urollHt2eCfvq9WJ5S
# hsYF206BjC05gWQqp0TLi4+5ifKfcpjwN8bYb/6/xEXlGr1jPytVfRmjE0aFS8GI
# oHqjZcmhjvLyqeygplT3mVEJ0xGB0cXHS6uPzlHELNwow1c+iXJYMk1pA+aFAzqi
# cBvnAIXeC39zeRcsdB2cqnC+T5VEdwSsIAYmTNm+1IMwI77+2q8jAJhTVu7jhKn/
# iEk2nJ+zNn9Mqa7ZgCCqpJmKF4Kev3Dns8QxHIxx9H8LubD/2Bppptm3MsiqXMN1
# HvUz3MAQF11HuTobQLz79BkLyCTUUTeL0sjPK3f/6FAXtTWyWpNg8LHEv1G44MpR
# 1CIIMIIKVzCCCD+gAwIBAgIEWp9cgzANBgkqhkiG9w0BAQsFADCBuzETMBEGCgmS
# JomT8ixkARkWA3NidTEVMBMGCgmSJomT8ixkARkWBXN0YXRlMRYwFAYDVQQDDA1D
# b25maWd1cmF0aW9uMREwDwYDVQQDDAhTZXJ2aWNlczEcMBoGA1UEAwwTUHVibGlj
# IEtleSBTZXJ2aWNlczEMMAoGA1UEAwwDQUlBMTYwNAYDVQQDDC1VLlMuIERlcGFy
# dG1lbnQgb2YgU3RhdGUgQUQgSGlnaCBBc3N1cmFuY2UgQ0EwHhcNMTgwMzIyMTkx
# MzA2WhcNMjEwMzIyMTk0MzA2WjCByjETMBEGCgmSJomT8ixkARkWA3NidTEVMBMG
# CgmSJomT8ixkARkWBXN0YXRlMRswGQYKCZImiZPyLGQBGRYLYXBwc2VydmljZXMx
# HDAaBgNVBAsME0VudGVycHJpc2UgU2VydmljZXMxDDAKBgNVBAsMA1BLSTEOMAwG
# A1UECwwFVXNlcnMxQzBBBgNVBAMMOlUuUy4gRGVwYXJ0bWVudCBvZiBTdGF0ZSBP
# cGVuTmV0IENvZGUgU2lnbmluZyBBdXRob3JpdHkgMDQwggEiMA0GCSqGSIb3DQEB
# AQUAA4IBDwAwggEKAoIBAQDKSwdQa/23Z8MBGgm5SKaLQPL7Qu6ZrFcpXASoOh08
# g40xG771f1/8phOB6efJJXSbBO9E5mZLpnbBO3NgrcM4OnyV793d7+jeHwvoBYz/
# yw/5BSRXX4+T+uR7fttd79YBoM+l+/gbZBVeOj0RldAkF03T6XOAGZBH5w/ZPo0U
# ZpZhqjtEAd/f937nwzxR2t4Ek1mJI58Rj3XVhSLcZSSP+LedYRqTVp2mEBhybqcR
# AxaET2VWh0KZpeeia+KLGK/9Uoo8dlfsERlBZ0azQrl9pcEOO/DVcvy+EM/xJYoL
# SSerZYM/qfZIewFlmnuXx9RRGnim3pWDIRzrS70gzjmpAgMBAAGjggVQMIIFTDAO
# BgNVHQ8BAf8EBAMCB4AwQQYDVR0gBDowODAMBgpghkgBZQMCAQYBMAwGCmCGSAFl
# AwIBBgIwDAYKYIZIAWUDAgEGAzAMBgpghkgBZQMCAQYEMBEGCWCGSAGG+EIBAQQE
# AwIEEDATBgNVHSUEDDAKBggrBgEFBQcDAzAMBgNVHRMBAf8EAjAAMIICMgYIKwYB
# BQUHAQEEggIkMIICIDBEBggrBgEFBQcwAoY4aHR0cDovL2NybHMucGtpLnN0YXRl
# Lmdvdi9BSUEvQ2VydHNJc3N1ZWRUb0RvU0FESEFDQS5wN2MwgcgGCCsGAQUFBzAC
# hoG7bGRhcDovL2Rpci5wa2kuc3RhdGUuZ292L2NuPVUuUy4lMjBEZXBhcnRtZW50
# JTIwb2YlMjBTdGF0ZSUyMEFEJTIwSGlnaCUyMEFzc3VyYW5jZSUyMENBLGNuPUFJ
# QSxjbj1QdWJsaWMlMjBLZXklMjBTZXJ2aWNlcyxjbj1TZXJ2aWNlcyxjbj1Db25m
# aWd1cmF0aW9uLGRjPXN0YXRlLGRjPXNidT9jQUNlcnRpZmljYXRlO2JpbmFyeTCB
# zwYIKwYBBQUHMAKGgcJsZGFwOi8vZGlyLnBraS5zdGF0ZS5nb3YvY249VS5TLiUy
# MERlcGFydG1lbnQlMjBvZiUyMFN0YXRlJTIwQUQlMjBIaWdoJTIwQXNzdXJhbmNl
# JTIwQ0EsY249QUlBLGNuPVB1YmxpYyUyMEtleSUyMFNlcnZpY2VzLGNuPVNlcnZp
# Y2VzLGNuPUNvbmZpZ3VyYXRpb24sZGM9c3RhdGUsZGM9c2J1P2Nyb3NzQ2VydGlm
# aWNhdGVQYWlyO2JpbmFyeTA7BggrBgEFBQcwAYYvaHR0cDovL29jc3AucGtpLnN0
# YXRlLmdvdi9PQ1NQL0RvU09DU1BSZXNwb25kZXIwggIBBgNVHR8EggH4MIIB9DCC
# ARWgggERoIIBDYYxaHR0cDovL2NybHMucGtpLnN0YXRlLmdvdi9jcmxzL0RvU0FE
# UEtJSEFDQS0xLmNybIaB12xkYXA6Ly9kaXIucGtpLnN0YXRlLmdvdi9jbj1XaW5D
# b21iaW5lZDEsY249VS5TLiUyMERlcGFydG1lbnQlMjBvZiUyMFN0YXRlJTIwQUQl
# MjBIaWdoJTIwQXNzdXJhbmNlJTIwQ0EsY249QUlBLGNuPVB1YmxpYyUyMEtleSUy
# MFNlcnZpY2VzLGNuPVNlcnZpY2VzLGNuPUNvbmZpZ3VyYXRpb24sZGM9c3RhdGUs
# ZGM9c2J1P2NlcnRpZmljYXRlUmV2b2NhdGlvbkxpc3Q7YmluYXJ5MIHYoIHVoIHS
# pIHPMIHMMRMwEQYKCZImiZPyLGQBGRYDc2J1MRUwEwYKCZImiZPyLGQBGRYFc3Rh
# dGUxFjAUBgNVBAMMDUNvbmZpZ3VyYXRpb24xETAPBgNVBAMMCFNlcnZpY2VzMRww
# GgYDVQQDDBNQdWJsaWMgS2V5IFNlcnZpY2VzMQwwCgYDVQQDDANBSUExNjA0BgNV
# BAMMLVUuUy4gRGVwYXJ0bWVudCBvZiBTdGF0ZSBBRCBIaWdoIEFzc3VyYW5jZSBD
# QTEPMA0GA1UEAwwGQ1JMNDMzMCsGA1UdEAQkMCKADzIwMTgwMzIyMTkxMzA2WoEP
# MjAyMTAzMjIxOTQzMDZaMB8GA1UdIwQYMBaAFIXjKM8leqYBjcVv/sVScqqeo0xO
# MB0GA1UdDgQWBBQ65UchqYXeNa/m+GvElZ/rSDn1KTAZBgkqhkiG9n0HQQAEDDAK
# GwRWOC4xAwIDqDANBgkqhkiG9w0BAQsFAAOCAgEApSZzxe1QY5+suoJlH+wJyvu+
# 4vfGpq9bzGdB7vybaaTeRJ5EiDB1C96lLA9PwKVNgfWLajLknUGFtdTmJ5qdj9cg
# 4xRs790F2r5aD3/s7pDFDbGyxPHkd5lR/Zlo9wsctOR/V0oemF/JM5AaSWiYOBF2
# yEWzcrPyve7iKvqO5fsEr+gYr2gXcx4DdFcmj59xERvEnwgg545M/BgICox8IgBr
# t8dTNWQ6ma86lKZMy8oKnjkKGjFOxFWpwD2RA9DXz4lX/9RhcjXFUpJF0EgPLidm
# 9UcPOAfQZLLyzFroGaRe+EnMifSjy4kUOVPDD9pA3VuOxyvOpCvWN45wkizW+NBV
# teFqQAg4dnPeeK3SRMSTc+/64R4lREuDJ1fW1Y+kmIYWdS/Y3+hZaPen0l2UvyfR
# TATHHCgEXgjpmbNTTN7uvZqY0RVfEISZfw0BdBXtzrGCXJnX1DygM4l+87w++V5u
# iUKU3rjcjNz0cuDG0iamLVA4I4HRNXBeKnHNconWKcbhBaubFSlmWWRdK7lgdZNO
# Z0HDM4HmMSstTeAgVqIz33aB21f3kDhy+uF1fWtjlnzS8i/Wc13aHe4pARO+7n0D
# JmMqdSGAAS2UDxkSe5X1fSvmrEkESz15UI74+We79utAtMJ3Gs+9/7ePXhp08UNF
# yb0WPiv9DR3SdCaDcncxggJ3MIICcwIBATCBxDCBuzETMBEGCgmSJomT8ixkARkW
# A3NidTEVMBMGCgmSJomT8ixkARkWBXN0YXRlMRYwFAYDVQQDDA1Db25maWd1cmF0
# aW9uMREwDwYDVQQDDAhTZXJ2aWNlczEcMBoGA1UEAwwTUHVibGljIEtleSBTZXJ2
# aWNlczEMMAoGA1UEAwwDQUlBMTYwNAYDVQQDDC1VLlMuIERlcGFydG1lbnQgb2Yg
# U3RhdGUgQUQgSGlnaCBBc3N1cmFuY2UgQ0ECBFqfXIMwDQYJYIZIAWUDBAIBBQCg
# gYQwGAYKKwYBBAGCNwIBDDEKMAigAoAAoQKAADAZBgkqhkiG9w0BCQMxDAYKKwYB
# BAGCNwIBBDAcBgorBgEEAYI3AgELMQ4wDAYKKwYBBAGCNwIBFTAvBgkqhkiG9w0B
# CQQxIgQgkOczqjSvSDxC/hjagkmLMwbDlVB3gq8h/Yl00R/u530wDQYJKoZIhvcN
# AQEBBQAEggEAhCoFvP1PITZXLL5blNC8bxpmEVZXBCbpzHDy7NfJJb+qcIsp5D/f
# lc3RuTU9ac+z8gOM15XjoSvd00V6vN5aBg5JDjYcIR+d5CNGUt7tB7PTZDQHNCNK
# EEt9KBvkg1kvB3ragx5WV6eUznXEyFcWSP75YKP5ar22jDfupRBFepQy9Bp6mJKC
# hVRPF3gez5gE6bDjNfKqqJqMd2fWDGejz/AlnPvUsX9g0Zp+31EwhHpg/sT3PDic
# FrLs7F+RftTDRMoszaCVk3t8j8ysSONsXakw6Q7CZL3C8Pw2tkCM1uxXDhIpZAoF
# M8P56WOwY85jg+WoiUUUd7o3+Ey5Qd+5dw==
# SIG # End signature block
