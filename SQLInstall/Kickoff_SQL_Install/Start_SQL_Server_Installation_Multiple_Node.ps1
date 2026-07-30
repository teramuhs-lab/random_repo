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
    # Close out whichever step was still in progress when the run ended.
    #
    # $script:FailedStep is set by the catch block when the script threw. Without it, the
    # step that KILLED the run was reported as [OK] whenever it produced no counted
    # warnings -- so a run that died in Step 6 printed "SCRIPT FAILED ... Failed during:
    # STEP 6" and then "[OK] STEP 6 of 14" a few lines later.
    if ($script:CurrentStep) {
        $warningsDuringStep = $global:SQLInstallWarningCount - $script:CurrentStepStartWarnCount
        $script:StepLog.Add( [PSCustomObject]@{
            Step       = $script:CurrentStep
            ErrorCount = $warningsDuringStep
            Failed     = ( $script:CurrentStep -eq $script:FailedStep )
        } )
        $script:CurrentStep = $null
    }

    Write-Host ""
    Write-Host ("=" * 80) -ForegroundColor Cyan
    Write-Host " STEP SUMMARY (errors/warnings by step -- some may be expected/benign)" -ForegroundColor Cyan
    Write-Host ("=" * 80) -ForegroundColor Cyan
    foreach ($s in $script:StepLog) {
        if ($s.Failed) {
            Write-Host ("  [FAILED]     {0}  <-- the run stopped here" -f $s.Step) -ForegroundColor Red
        }
        elseif ($s.ErrorCount -gt 0) {
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

# Cancelling the picker returns nothing. Without this the step still printed
# "[OK] Selected: " with an empty name, and the run died at STEP 4 on a null path -- the
# reported failure pointing at the wrong step entirely.
if ( -not $settingsFile )
{
    throw "No environment file was selected. Choose one in the picker and click OK, or press Ctrl+C to abandon the run."
}

if ( @($settingsFile).Count -gt 1 )
{
    # The picker allows multi-select, but everything downstream assumes exactly one file.
    throw "More than one environment file was selected ($(($settingsFile.BaseName) -join ', ')). Select exactly one."
}

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

    # Get-Credential does not trim the user name, and leading/trailing whitespace is
    # invisible in every message that follows. A single trailing space produced
    #     Principal MS\SomeAccount  was not found          (Add-LocalGroupMember)
    #     The user name or password is incorrect            (New-PSSession)
    # which reads as a wrong password rather than a stray keystroke. PSCredential is
    # immutable, so the credential is rebuilt with the trimmed name and the same password.
    if ( $InstallAccount -and $InstallAccount.UserName -ne $InstallAccount.UserName.Trim() )
    {
        Write-Host "  [INFO] Trimmed whitespace from the user name '$($InstallAccount.UserName)'." -ForegroundColor Cyan
        $InstallAccount = New-Object System.Management.Automation.PSCredential(
                              $InstallAccount.UserName.Trim(), $InstallAccount.Password )
    }
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


    # NOTE: credentials are always collected interactively above. Do not reintroduce
    # hardcoded passwords here -- anything committed to source control stays in the
    # repository history even after it is deleted.

    $password         = $NULL;
    $username         = $NULL;

    Write-Host "  [OK] Credentials collected." -ForegroundColor Green

#endregion

#region *** Check PowerShell Remoting and PowerShell Version(should be > 5)

    #while ( -not ( Get-Variable -Name psSessions -ErrorAction SilentlyContinue ) )
    Write-Banner "STEP 6 of 14: Granting install account admin rights, then verifying remoting"

    $nodes = ( $envData.AllNodes.NodeName | Where-Object { $_ -ne '*' } | Select-Object -Unique )

    # The connectivity check below connects as $InstallAccount, which therefore has to be a
    # local administrator on every node BEFORE that call is made. The environment configs
    # only ever described this as a manual step ("the Installer account is manually added
    # to the local admins group after VMs are provisioned"), and when it had not been done
    # the run died here with "Could not re-create psSessions" while WinRM was perfectly
    # healthy -- the least informative possible symptom.
    #
    # Granted using the CURRENT user's rights, not $InstallAccount's: using the account to
    # grant rights to itself cannot work. Whoever runs the installer must already be an
    # administrator on the nodes.
    Add-InstallAccountToNodeAdmins -UserName $InstallAccount.UserName -ComputerName $nodes

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
            # Keep the underlying exception. The generic advice below covers several very
            # different causes -- WinRM not running, firewall, a rejected credential, an
            # untrusted/Kerberos failure -- and without the real message there is no way to
            # tell which one applies, so every failure looked identical.
            $remotingError = ( $_.Exception.Message -replace '[\r\n]+', ' ' ).Trim()

            Write-Host ''
            Write-Host "  Underlying error: $remotingError" -ForegroundColor Yellow
            Write-Host '  Check, on the target:' -ForegroundColor Yellow
            Write-Host "    Test-WSMan -ComputerName $Computer" -ForegroundColor Gray
            Write-Host "    Invoke-Command -ComputerName $Computer { `$env:COMPUTERNAME }   # as yourself, no -Credential" -ForegroundColor Gray
            Write-Host "    Get-Service WinRM -ComputerName $Computer" -ForegroundColor Gray
            Write-Host '  If the account is what is being rejected, confirm the password collected in Step 5' -ForegroundColor Gray
            Write-Host '  and that the account may log on to that node.' -ForegroundColor Gray
            Write-Host ''

            throw "Could not re-create psSessions to the remote server $Computer. Make Sure Server is up, PowerShell remoting is enabled and firewall is Open. Underlying error: $remotingError"
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
Write-Banner "STEP 7 of 14: Creating local install account and adding it to Administrators"
$nodes = ( $envData.AllNodes.NodeName | Where-Object { $_ -ne '*' } | Select-Object -Unique )

# Most of the SQL configuration resources run under PsDscRunAsCredential = this account,
# and DSC can only do that if the account already holds the "log on as a batch job" right
# -- which it inherits from local Administrators, evaluated at logon time.
#
# The DSC config also declares the account ([User]LocalSQLInstallAccount), but that resource
# executes *inside* the very run that needs the credential. On a fresh node the account
# therefore does not exist when Step 7 previously tried to add it to Administrators; the
# add failed silently, and every RunAs resource then failed with "the user has not been
# granted the requested logon type at this computer" -- which is why a second run used to
# be required to finish the build.
#
# Creating the account here, before any MOF is pushed, makes a single run sufficient. This
# and the DSC resource are both idempotent, so having the account declared in two places
# is safe.
#
# A SecureString created on this machine cannot be decrypted on another one, so the password
# crosses the wire as plaintext via -ArgumentList and is re-wrapped remotely. It only ever
# lives in memory, never on disk.
$installAccountName = $envData.NonNodeData.SQL.LocalInstallAccount
$installAccountPass = $LocalInstallAccount.GetNetworkCredential().Password

Write-Host "  Ensuring local account '$installAccountName' on $($nodes -join ', ')" -ForegroundColor Yellow

# Every outcome is returned as a STATUS|computer|detail string and errors are caught inside
# the scriptblock, because remote failures otherwise land in the error stream where this
# step ignored them: a run in which New-LocalUser rejected its arguments on both nodes --
# so the account was never created and 14 RunAs resources failed later -- still printed
# "[OK] STEP 7" in the summary, because nothing incremented the warning counter.
$step7Results = Invoke-Command -ComputerName $nodes -ArgumentList $installAccountName, $installAccountPass -ScriptBlock {
    param ( [string]$UserName, [string]$PlainPassword )

  try
  {
    $securePassword = ConvertTo-SecureString $PlainPassword -AsPlainText -Force

    if ( Get-LocalUser -Name $UserName -ErrorAction SilentlyContinue )
    {
        # Keep the password aligned with the environment file. DSC would enforce this too,
        # but the RunAs logon happens before that resource is ever evaluated.
        Set-LocalUser -Name $UserName -Password $securePassword
        $action = 'password reset'
    }
    else
    {
        # Description must be 48 characters or fewer -- New-LocalUser validates this and
        # rejects the whole call. The previous text was 65 characters, so the account was
        # never created and the Add-LocalGroupMember below then failed with the misleading
        # "Principal SQLInstallAcc was not found".
        #
        # This step is now the ONLY thing that creates this account; the DSC config no
        # longer declares a [User] resource for it (that resource failed on every run in
        # ValidateCredentials). So there is no description to keep in sync any more.
        New-LocalUser -Name $UserName -Password $securePassword `
                      -FullName    'SQL Install Account' `
                      -Description 'SQL Server install account - disable when idle' | Out-Null
        $action = 'created'
    }

    # Membership in Administrators is what actually confers the batch-logon right.
    # Add blindly and treat "already a member" as success -- Get-LocalGroupMember is avoided
    # here because it throws outright if the group contains any unresolvable SID.
    try
    {
        Add-LocalGroupMember -Group 'Administrators' -Member $UserName -ErrorAction Stop
        $action += ', added to Administrators'
    }
    catch
    {
        if ( $_.FullyQualifiedErrorId -notmatch 'MemberExists' ) { throw }
        $action += ', already in Administrators'
    }

    # Confirm the end state rather than trusting that the calls above worked. This is the
    # check that would have caught the description-length rejection immediately.
    if ( -not ( Get-LocalUser -Name $UserName -ErrorAction SilentlyContinue ) )
    {
        return "FAIL|$($env:COMPUTERNAME)|account does not exist after the attempt to create it"
    }

    "OK|$($env:COMPUTERNAME)|$action"
  }
  catch
  {
    "FAIL|$($env:COMPUTERNAME)|$(($_.Exception.Message -replace '[\r\n]+',' ').Trim())"
  }
}

$step7Failed = @()

foreach ( $line in @($step7Results) )
{
    $status, $computer, $detail = "$line" -split '\|', 3

    if ( $status -eq 'OK' )
    {
        Write-Host "  [OK] $computer : $installAccountName $detail" -ForegroundColor Green
    }
    else
    {
        Write-Host "  [WARN] $computer : could not provision '$installAccountName' -- $detail" -ForegroundColor Yellow
        $global:SQLInstallWarningCount++
        $step7Failed += $computer
    }
}

# A node whose local install account is missing cannot apply ANY resource that uses
# PsDscRunAsCredential -- MaxDop, memory, the sp_configure options, trace flags and every
# post-install T-SQL script, including the maintenance solution. Setup itself still
# succeeds, so Step 14 looks healthy while leaving the instance largely unconfigured.
# Say so here, loudly, rather than letting it be discovered in the Step 14 noise.
if ( $step7Failed.Count -gt 0 )
{
    Write-Host ''
    Write-Host "  [WARN] '$installAccountName' is NOT usable on: $($step7Failed -join ', ')" -ForegroundColor Yellow
    Write-Host "         Every resource using PsDscRunAsCredential will fail on those nodes." -ForegroundColor DarkYellow
    Write-Host "         Fix this before relying on Step 14's result." -ForegroundColor DarkYellow
    Write-Host ''
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

# These permissions exist so each node's LCM -- which runs as SYSTEM and therefore reaches
# the share as DOMAIN\NODE$ -- can read the DSC modules and SQL media over UNC. That only
# happens when the configuration declares File resources pointing at the share, which it
# does only when Copy_all_Files_to_TargetNodes = 'YES'.
#
# With 'NO', nothing reads the share during a run: setup.exe reads local node paths, and
# the toolkit is staged by hand. Granting share rights is then pointless, and on an admin
# machine that has no SQLInstall share at all it produced two counted warnings per run
# ("Share 'SQLInstall' not found on <admin>") that looked like failures but were the
# expected outcome of a supported configuration.
if ( $envData.NonNodeData.Data.Copy_all_Files_to_TargetNodes -eq 'YES' )
{
    #Grant fileshare permission to the computer accounts for each node
    Grant-SmbSharePermissions -Path $envData.NonNodeData.Data.DSCResourceLocation -Computer $nodes -ShareAccessRight FULL -FileSystemRights FullControl

    #Grant fileshare permission to Install Account
    #Grant-SmbSharePermissions -Path $envData.NonNodeData.Data.DSCResourceLocation -user $envData.NonNodeData.SQL.SQLSysAdminAccounts -ShareAccessRight FULL -FileSystemRights FullControl
    Grant-SmbSharePermissions -Path $envData.NonNodeData.Data.DSCResourceLocation -user $InstallAccount.UserName -ShareAccessRight FULL -FileSystemRights FullControl

    Write-Host "  [OK] Fileshare permissions granted on $($envData.NonNodeData.Data.DSCResourceLocation)." -ForegroundColor Green
}
else
{
    Write-Host "  [INFO] Skipped -- Copy_all_Files_to_TargetNodes = 'NO', so no node reads the share during this run." -ForegroundColor Cyan
    Write-Host "         The toolkit and media are expected to be staged on each node already." -ForegroundColor Gray
}


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
#
# Reported per node rather than assumed. This used to run Invoke-GPUpdate with no error
# handling at all and then print "[OK] Group Policy refreshed" unconditionally, so a node
# that refused the refresh -- unreachable, RPC blocked, no rights -- still produced a green
# Step 11. That matters because the policy being refreshed is what grants the install
# account its logon rights on a freshly provisioned node.
$gpFailed = @()

foreach ( $c in $ComputerNameFQDN )
{
    try
    {
        Invoke-GPUpdate -Computer $c -Force -RandomDelayInMinutes 0 -ErrorAction Stop
        Write-Host "  [OK] $c" -ForegroundColor Green
    }
    catch
    {
        $msg = ( $_.Exception.Message -replace '[\r\n]+', ' ' ).Trim()
        Write-Host "  [WARN] $c`: Group Policy refresh failed -- $msg" -ForegroundColor Yellow
        $global:SQLInstallWarningCount++
        $gpFailed += $c
    }
}

if ( $gpFailed.Count -eq 0 )
{
    Write-Host "  [OK] Group Policy refreshed on all nodes." -ForegroundColor Green
}
else
{
    Write-Host "         Policy on $($gpFailed -join ', ') may be stale; rights granted by GPO might not apply yet." -ForegroundColor DarkYellow
}

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
    # Re-read the membership rather than assuming the add above worked. This step is named
    # "Verifying ..." but used to print [OK] unconditionally -- and Add-UserToLocalGroup
    # deliberately warns and CONTINUES on failure, so a node that rejected the add still
    # produced a green Step 12. The same false-OK pattern that hid a failed Step 7.
    $stillMissing = @()
    $accountName  = $InstallAccount.UserName.Split('\')[-1]

    $confirmed = Get-LocalGroupMembers -ComputerName $ComputerNameFQDN -LocalGroupName 'Administrators' |
                    Where-Object { $_.Name -eq $accountName } |
                    Select-Object -ExpandProperty Computer -Unique

    foreach ( $c in $ComputerNameFQDN )
    {
        if ( $confirmed -notcontains $c ) { $stillMissing += $c }
    }

    if ( $stillMissing.Count -eq 0 )
    {
        Write-Host "  [OK] Install account verified as local admin on $($ComputerNameFQDN -join ', ')." -ForegroundColor Green
    }
    else
    {
        Write-Host "  [WARN] '$($InstallAccount.UserName)' is NOT in local Administrators on: $($stillMissing -join ', ')" -ForegroundColor Yellow
        Write-Host "         Step 14 connects as this account; expect resources using it to fail." -ForegroundColor DarkYellow
        $global:SQLInstallWarningCount += $stillMissing.Count
    }


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



    Write-Banner "STEP 13 of 14: Copying and verifying DSC resources"

    # Resolve the SQL Server version once, here, because it decides two things:
    # which modules must be verified below, and which config script Step 14 runs.
    # Read from the environment config's NonNodeData.SQL.SQLVersion, falling back to
    # the original hardcoded 'SQL2017' default so environment files that predate this
    # setting keep behaving exactly as before.
    $sqlVersionForDeploy = if ( -not [string]::IsNullOrEmpty($envData.NonNodeData.SQL.SQLVersion) )
                           { $envData.NonNodeData.SQL.SQLVersion } else { 'SQL2017' }

    # Optionally stage the modules onto THIS (admin) machine from the resource share.
    # Copying to the target nodes is handled by the DSC 'CopyPowerShellDSCModulesLocally'
    # File resource when Copy_all_Files_to_TargetNodes = 'YES'; with 'NO' the modules are
    # expected to be staged on each node already. Either way the verification below is
    # what actually confirms they are in place.
    if ( $envData.NonNodeData.Data.CopyDSCResources_to_AdminMachine -eq 'YES' )
    {
        Write-Host "  Copying DSC modules to this machine from $($envData.NonNodeData.Data.DSCResourceLocation) ..." -ForegroundColor Gray
        Copy-Item "$($envData.NonNodeData.Data.DSCResourceLocation)\*" -Destination "C:\Program Files\WindowsPowerShell\Modules" -Recurse -Force -Verbose
        Write-Host "  [OK] DSC modules copied to this machine." -ForegroundColor Green
    }
    else
    {
        # Previously this branch still printed "[OK] DSC resources copied", which was
        # misleading -- nothing was copied. Say what actually happened instead.
        Write-Host "  [INFO] Skipped copying to this machine (CopyDSCResources_to_AdminMachine = 'NO')." -ForegroundColor Cyan
    }

    # Verify the modules this deployment actually needs are present on the admin machine
    # AND on every target node, before anything is deployed. A module missing here would
    # otherwise surface either as a MOF compilation error, or -- worse -- as an LCM
    # failure part-way through the push, potentially after SQL Server was installed.
    Test-RequiredDscModules -Version $sqlVersionForDeploy -ComputerName $nodes

    # Volumes and staged media, for the same reason: a missing drive or an unstaged bits
    # folder is a precondition, not something the configuration creates, and it otherwise
    # surfaces deep in Step 14 after the MOF has already been pushed.
    Test-NodePrerequisites -EnvData $envData -ComputerName $nodes -Version $sqlVersionForDeploy

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
    # Resolved in Step 13, so the module verification there and the config-script
    # selection below always agree on the version.
    Version = $sqlVersionForDeploy
}


Write-Banner "STEP 14 of 14: Deploying SQL Server installation (DSC)" "Magenta"
Write-Host "  Detailed DSC/LCM progress below is normal -- look for '[OK]' lines and any red errors." -ForegroundColor Yellow

# Select the DSC configuration script by SQL Server version.
#
# SQL2025+ uses the SqlServerDsc build. This is not a preference -- xSQLServer 9.0.0.0
# loads SMO/WMI assemblies pinned to the SQL major version (Version=<major>.0.0.0), and
# no 17.0.0.0 assembly exists in the vendored SqlServer module, so the resource that
# configures TCP/IP and the static port cannot work on SQL2025. Because most other
# resources DependsOn it, DSC skips them and the run still reports success while almost
# nothing is configured.
#
# SQL2012-2017 continue to use the original, battle-tested script. They never load the
# SqlServerDsc script, so that proven path carries no risk from the newer module.
# See README sections 3 and 9.
$configScriptName = if ( $param.Version -eq 'SQL2025' )
                    {
                        'configs\Install_and_Configure_SQLServer_Multi_Node_SqlServerDsc.ps1'
                    }
                    else
                    {
                        'configs\Install_and_Configure_SQLServer_Multi_Node.ps1'
                    }

Write-Host "  Using DSC configuration: $configScriptName" -ForegroundColor Cyan
Write-Host "  (selected for version '$($param.Version)')" -ForegroundColor DarkGray

& (Join-Path -Path $scriptLocation -ChildPath $configScriptName) @param -Deploy -Verbose

Write-Banner "Installation script finished. Review the log above for [OK] markers and any errors." "Magenta"

}
catch {
    # Record which step died so the STEP SUMMARY marks it [FAILED] instead of [OK].
    $script:FailedStep = $script:CurrentStep

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
