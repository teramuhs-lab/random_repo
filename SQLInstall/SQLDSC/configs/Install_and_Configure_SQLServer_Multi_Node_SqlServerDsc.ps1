#Requires -Version 5.1
<#
.SYNOPSIS
    Installs and configures a standalone SQL Server instance using the modern
    SqlServerDsc module. Intended for SQL Server 2025 and newer.

.DESCRIPTION
    This is the SQL2025+ counterpart to Install_and_Configure_SQLServer_Multi_Node.ps1.
    Both scripts do the same job and read the same environment .psd1; they differ only
    in which DSC module they use:

        Install_and_Configure_SQLServer_Multi_Node.ps1              xSQLServer 9.0.0.0   SQL2012-2017
        Install_and_Configure_SQLServer_Multi_Node_SqlServerDsc.ps1 SqlServerDsc 17.5.1  SQL2025+   <- this file

    WHY A SEPARATE FILE INSTEAD OF ONE SHARED SCRIPT
    ------------------------------------------------
    xSQLServer 9.0.0.0 loads SMO/WMI assemblies with the version pinned to the SQL
    Server major version:

        Microsoft.SqlServer.SqlWmiManagement, Version=<SQLmajor>.0.0.0

    SQL2017 asks for 14.0.0.0, which the vendored SqlServer 21.0.17224 module provides.
    SQL2025 asks for 17.0.0.0, which it does not. MSFT_xSQLServerNetwork (the resource
    that enables TCP/IP and sets the static port) depends on that assembly, so on
    SQL2025 it fails -- and because most other resources DependsOn it, DSC silently
    skips them and the run still reports success. That defect lives inside the module,
    so it cannot be worked around with a conditional in the shared script; SQL2025
    needs a different module entirely.

    Keeping that in a separate file means a SQL2012-2017 deployment never opens this
    script, never imports SqlServerDsc, and never loads SMO 17.x -- so the proven
    legacy path carries zero risk from anything here. See README sections 3 and 9.

    WHAT THIS SCRIPT FIXES RELATIVE TO THE LEGACY ONE
    -------------------------------------------------
      * TCP/IP + static port are configured by SqlSetup/SqlProtocolTcpIp and actually work.
      * Trace flags use the native SqlTraceFlag resource instead of hand-rolled Script
        blocks that hard-coded the default-instance registry path (which failed for a
        named instance).
      * SQL Browser is disabled LAST, so named-instance connections keep working for the
        whole run (see the Disable SQL Browser resource for the full explanation).
      * T-SQL scripts run with Encrypt='Optional' so SQL Server's self-signed
        certificate does not break them under the newer ODBC/SqlClient defaults.

.PARAMETER envDataFilePath
    Path to the environment .psd1 (same file format the legacy script uses -- no
    environment-file changes are required to switch to this script).

.PARAMETER InstallAccount
    Credential of the domain account performing the install.

.PARAMETER LocalInstallAccount
    Credential of the per-node local install account (a SQL sysadmin). Used as
    PsDscRunAsCredential for every resource that has to log in to SQL Server.

.PARAMETER SQLServiceAccount
    Credential for the SQL Server Database Engine service. If $null, SqlSetup falls
    back to the per-instance virtual accounts (NT SERVICE\MSSQL$<instance>).

.PARAMETER SQLAgentServiceAccount
    Credential for the SQL Server Agent service.

.PARAMETER Version
    SQL Server version keyword, e.g. 'SQL2025'. Drives the media subfolder, the
    MSSQL<build>.<instance> paths and the feature list.

.PARAMETER Deploy
    Compile only when omitted; compile AND push to the target nodes when supplied.

.NOTES
    Requires SqlServerDsc 17.5.1 and SqlServer 22.4.5.1 (SMO 17.x) deployed to each
    target node. Do NOT deploy SqlServer 22.4.5.1 to SQL2012-2017 nodes -- see the
    caution in SQLDSC\modules\README.md.
#>

param(
    [Parameter(Mandatory=$true)]$envDataFilePath,
    $InstallAccount,
    $LocalInstallAccount,
    $SQLServiceAccount,
    $SQLAgentServiceAccount,
    # Deliberately permissive: this script is selected by the kickoff script for
    # SQL2025 and is written to keep working for future releases -- add the new
    # version to $sqlVersionInfo below and it needs no other change here.
    [ValidateSet("SQL2025","SQL2017","SQL2016")]
    $Version,
    [switch]$Deploy
)

# ---------------------------------------------------------------------------
# Load the environment configuration.
#
# Invoke-Expression (not Import-PowerShellDataFile) is used deliberately, matching
# the legacy script: the environment files contain dynamic expressions such as
# "\\$env:COMPUTERNAME\SQLInstall\..." which Import-PowerShellDataFile rejects.
# ---------------------------------------------------------------------------
$envData     = Invoke-Expression (Get-Content -Path $envDataFilePath | Out-String)
$envDataFile = Get-Item $envDataFilePath

# MOF output folder. A fresh GUID subfolder per run guarantees we never push stale
# MOFs that were compiled for a different set of servers but left in place.
$mofLocationParent = Join-Path -Path "$($envDataFile.DirectoryName)\..\mofs" -ChildPath ($envDataFile.BaseName -replace '\.','-')
$Guid              = [System.Guid]::NewGuid()
$mofLocation       = Join-Path -Path $mofLocationParent -ChildPath $Guid.Guid
New-Item -Path $mofLocation -ItemType Directory -Force | Out-Null

# ---------------------------------------------------------------------------
# Local Configuration Manager (LCM) settings pushed to each node.
#
# Identical to the legacy script so behaviour around reboots is unchanged:
# RebootNodeIfNeeded lets SQL setup reboot mid-run, and ActionAfterReboot =
# StopConfiguration means the run must be resumed afterwards -- which the deploy
# block at the bottom does with a second Start-DscConfiguration -UseExisting.
# ---------------------------------------------------------------------------
[DscLocalConfigurationManager()]
configuration 'SetResourceModuleLocation'
{
    node $AllNodes.NodeName
    {
        Settings
        {
            RefreshMode        = 'Push'
            RebootNodeIfNeeded = $true
            ActionAfterReboot  = 'StopConfiguration'
            ConfigurationMode  = 'ApplyAndMonitor'
            # A ConfigurationID must be supplied even in push mode (long-standing LCM quirk).
            ConfigurationID    = '3a15d863-bd25-432c-9e45-9199afecde91'
        }

        ResourceRepositoryShare FileShare
        {
            SourcePath = $ConfigurationData.NonNodeData.Data.DSCResourceLocation
        }
    }
}

SetResourceModuleLocation -ConfigurationData $envData -OutputPath $mofLocation


configuration 'InstallSQLServerModern'
{
    Import-DscResource -ModuleName 'PSDesiredStateConfiguration'
    # SqlServerDsc replaces xSQLServer here. xNetworking is retained for xFirewall:
    # it is version-agnostic, already proven in this toolkit, and there is no benefit
    # to swapping it for SqlWindowsFirewall.
    Import-DscResource -ModuleName 'SqlServerDsc' -ModuleVersion '17.5.1'
    Import-DscResource -ModuleName 'xNetworking'  -ModuleVersion '5.3.0.0'

    node $AllNodes.NodeName
    {
        # ===================================================================
        # Version -> build number and feature list
        # ===================================================================
        if ( -not $Version )
        {
            $Version = $ConfigurationData.NonNodeData.SQL.SQLVersion
        }

        $SQLInstanceDirectory = $ConfigurationData.NonNodeData.SQL.InstanceDirectory + '\'
        $Instance             = $ConfigurationData.NonNodeData.SQL.InstanceName
        $Port                 = $ConfigurationData.NonNodeData.SQL.SQLEnginePort

        # Build = the MSSQL<NN>.<instance> folder/registry suffix.
        #
        # CONN and BC are intentionally absent for SQL2025: its setup.exe silently
        # ignores them (Summary.txt reports "FEATURES: SQLENGINE, FULLTEXT"), and
        # requesting features that are never installed makes the setup resource's
        # Test-TargetResource fail permanently. See README section 5.
        $sqlVersionInfo = @{
            'SQL2016' = @{ Build = '13'; MajorMinor = '13.0'; SQLEngineFeatures = 'SQLENGINE,FULLTEXT,CONN,BC'; ExtraFeatures = 'FULLTEXT,CONN,BC' }
            'SQL2017' = @{ Build = '14'; MajorMinor = '14.0'; SQLEngineFeatures = 'SQLENGINE,FULLTEXT,CONN,BC'; ExtraFeatures = 'FULLTEXT,CONN,BC' }
            'SQL2025' = @{ Build = '17'; MajorMinor = '17.0'; SQLEngineFeatures = 'SQLENGINE,FULLTEXT';         ExtraFeatures = 'FULLTEXT' }
        }

        if ( $sqlVersionInfo.ContainsKey($Version) )
        {
            $versionInfo = $sqlVersionInfo[$Version]
            $Build       = $versionInfo.Build
            $MajorMinor  = $versionInfo.MajorMinor
            $Program     = $SQLInstanceDirectory + "MSSQL$Build.$Instance\MSSQL\Binn\sqlservr.exe"

            if ( $ConfigurationData.NonNodeData.SQL.SQLFeatures -eq 'SQLEngine' )
            {
                $FeatureList = $versionInfo.SQLEngineFeatures
            }
            else
            {
                $FeatureList = $ConfigurationData.NonNodeData.SQL.SQLFeatures + ',' + $versionInfo.ExtraFeatures
            }
        }
        else
        {
            # Unknown version: install the engine only. Better a minimal install than
            # a guessed feature list that breaks the setup resource's state detection.
            $FeatureList = 'SQLENGINE'
            $Build       = ''
            $MajorMinor  = ''
            $Program     = ''
        }

        # ===================================================================
        # WMI firewall rules (needed for remote management / DSC itself)
        # ===================================================================
        $wmirulenames = 'WMI-RPCSS-In-TCP','WMI-WINMGMT-In-TCP','WMI-WINMGMT-Out-TCP','WMI-ASYNC-In-TCP'
        $wmirulenames | ForEach-Object {
            xFirewall "Enable WMI - $_"
            {
                Name    = $_
                Enabled = 'True'
            }
        }

        # .NET 3.5 -- a prerequisite for some SQL features; sourced from local media
        # because target servers have no internet access.
        WindowsFeature 'DotNet35'
        {
            Name   = 'Net-Framework-Core'
            Source = $ConfigurationData.NonNodeData.SQL.DotNetBitsDestination
        }

        # ===================================================================
        # Stage installation media / modules onto the node
        #
        # Only when Copy_all_Files_to_TargetNodes = 'YES'. With 'NO' the files are
        # expected to already be present locally (staged by hand or by
        # Copy_SQL_Files_To_Servers.ps1).
        # ===================================================================
        $sqlResourceDependsOn = @()

        if ( $ConfigurationData.NonNodeData.Data.Copy_all_Files_to_TargetNodes -eq 'YES' )
        {
            $sqlResourceDependsOn += '[WindowsFeature]DotNet35'
            $sqlResourceDependsOn += '[File]CopySQLSourceFilesLocally'

            File 'CopySQLSourceFilesLocally'
            {
                SourcePath      = $ConfigurationData.NonNodeData.SQL.SQLBitsSource + '\' + $Version
                DestinationPath = $ConfigurationData.NonNodeData.SQL.SQLBitsDestination + $Version
                Type            = 'Directory'
                Recurse         = $true
                Checksum        = 'SHA-256'
                MatchSource     = $true
            }

            File 'CopySQLPatchesLocally'
            {
                SourcePath      = $ConfigurationData.NonNodeData.SQL.UpdateSource
                DestinationPath = $ConfigurationData.NonNodeData.SQL.UpdateDestination
                Type            = 'Directory'
                Recurse         = $true
                Checksum        = 'SHA-256'
                MatchSource     = $true
            }

            File 'CopyDotNetFilesLocally'
            {
                SourcePath      = $ConfigurationData.NonNodeData.SQL.DotNetBitsSource
                DestinationPath = $ConfigurationData.NonNodeData.SQL.DotNetBitsDestination
                Type            = 'Directory'
                Recurse         = $true
                Checksum        = 'SHA-256'
                MatchSource     = $true
            }

            File 'CopySSMSFilesLocally'
            {
                SourcePath      = $ConfigurationData.NonNodeData.SQL.SSMSBitsSource
                DestinationPath = $ConfigurationData.NonNodeData.SQL.SSMSBitsDestination
                Type            = 'Directory'
                Recurse         = $true
                Checksum        = 'SHA-256'
                MatchSource     = $true
            }

            File 'CopySQLScriptsFolderLocally'
            {
                SourcePath      = $ConfigurationData.NonNodeData.SQL.SQLScriptsFolderSource
                DestinationPath = $ConfigurationData.NonNodeData.SQL.SQLScriptsFolderDestination
                Type            = 'Directory'
                Recurse         = $true
                Checksum        = 'SHA-256'
                MatchSource     = $true
            }

            File 'CopyPowerShellDSCModulesLocally'
            {
                SourcePath      = $ConfigurationData.NonNodeData.Data.DSCResourceLocation
                DestinationPath = 'C:\Program Files\WindowsPowerShell\Modules'
                Type            = 'Directory'
                Recurse         = $true
                Checksum        = 'SHA-256'
                MatchSource     = $true
            }
        }

        # ===================================================================
        # Data / log / tempdb / backup folders
        #
        # Per-instance subfolders let multiple instances coexist on one server.
        # The DRIVES themselves must already be provisioned -- only folders are
        # created here.
        #
        # READING THE LOG: during a fresh install these resources emit
        #
        #     [[File]Folder_0] The system cannot find the path specified.
        #     [[File]Folder_0] The related file/directory is: E:\SQLBackups\CAPPT.
        #
        # in BOTH Test and Set. That is not an error -- it is how the File resource
        # narrates "the destination does not exist yet, so we are not in desired
        # state". Set then creates the folder and ends without an error record.
        # Verified on a clean two-node build: all folders were created and
        # setup.exe reported "Final result: Passed".
        # ===================================================================
        $TempDBDataDir   = $ConfigurationData.NonNodeData.SQL.SQLTempDBDir    + '\' + $Instance
        $TempDBLogDir    = $ConfigurationData.NonNodeData.SQL.SQLTempDBLogDir + '\' + $Instance
        $SQLUserDBDir    = $ConfigurationData.NonNodeData.SQL.SQLUserDBDir    + '\' + $Instance
        $SQLUserDBLogDir = $ConfigurationData.NonNodeData.SQL.SQLUserDBLogDir + '\' + $Instance
        $SQLBackupDir    = $ConfigurationData.NonNodeData.SQL.SQLBackupDir    + '\' + $Instance

        # Sort-Object -Unique collapses duplicates: several of these commonly point at
        # the same location (e.g. tempdb data and log often share a drive), and two
        # File resources with the same DestinationPath is a compilation error.
        $uniquefolders = @($SQLUserDBDir, $SQLUserDBLogDir, $TempDBDataDir, $TempDBLogDir, $SQLBackupDir) |
                            Sort-Object -Unique

        for ( $i = 0; $i -lt $uniquefolders.Count; $i++ )
        {
            $sqlResourceDependsOn += "[File]Folder_$i"

            File "Folder_$i"
            {
                Type            = 'Directory'
                DestinationPath = $uniquefolders[$i]
                Checksum        = 'SHA-256'
            }
        }

        # ===================================================================
        # Local accounts and groups
        # ===================================================================

        # The local install account is created by STEP 7 OF THE KICKOFF SCRIPT, not here.
        #
        # A [User]LocalSQLInstallAccount resource used to be declared at this point. It was
        # removed because it failed on every single run and could never succeed:
        #
        #   MSFT_UserResource failed to execute Test-TargetResource ... Exception calling
        #   "ValidateCredentials" ... "Logon failure: the user has not been granted the
        #   requested logon type at this computer."
        #
        # Whenever a Password is supplied, that resource's Test validates it by attempting a
        # logon, which a hardened server's logon-rights policy refuses -- independently of
        # whether the account exists or is an administrator. A run in which Step 7 had
        # verifiably created the account and added it to Administrators still produced this
        # error on both nodes.
        #
        # It was not benign: the resource error makes the LCM report
        # "SendConfigurationApply did not succeed" and fails the whole configuration, which
        # is what a monitoring check keys off.
        #
        # Removing it costs nothing. Nothing DependsOn it, and every resource that runs as
        # this account uses PsDscRunAsCredential, which does not need the account declared
        # here -- proven by the same run, where the T-SQL scripts applied successfully while
        # this resource was failing.
        #
        # To restore it, re-declare a User resource with Ensure = 'Present' and OMIT the
        # Password property; Test then checks only existence and does not attempt a logon.

        # NOTE: if any single name in LocalServerAdmins cannot be resolved in AD, this
        # whole resource fails and the group is not created at all -- not just the one
        # bad member. Verify every name with Get-ADGroup/Get-ADUser before running.
        Group 'CreateSQLAdminsLocalGroup'
        {
            GroupName        = 'SQLAdmins'
            Description      = 'Local group to hold SQL Server administrator accounts'
            Ensure           = 'Present'
            MembersToInclude = $ConfigurationData.NonNodeData.SQL.LocalServerAdmins
        }

        if ( $null -eq $SQLServiceAccount )
        {
            # No service accounts supplied: SQL setup uses per-instance virtual accounts.
            if ( $Instance -ine 'MSSQLServer' )
            {
                $LocalSQLVirtualAccount   = ('NT SERVICE\MSSQL${0}'    -f $Instance)
                $LocalAgentVirtualAccount = ('NT SERVICE\SQLAGENT${0}' -f $Instance)
            }
            else
            {
                $LocalSQLVirtualAccount   = 'NT SERVICE\MSSQLSERVER'
                $LocalAgentVirtualAccount = 'NT SERVICE\SQLSERVERAGENT'
            }

            # The virtual accounts only exist once setup has created the services,
            # hence the dependency (unlike the domain-account branch below).
            Group 'CreateSQLServiceLocalGroup'
            {
                GroupName        = 'SQLServices'
                Description      = 'Local group to hold SQL Server related service accounts'
                Ensure           = 'Present'
                DependsOn        = '[SqlSetup]SetupSQL'
                MembersToInclude = @($LocalSQLVirtualAccount, $LocalAgentVirtualAccount)
            }
        }
        else
        {
            # Domain service accounts already exist, so no dependency on setup.
            Group 'CreateSQLServiceLocalGroup'
            {
                GroupName        = 'SQLServices'
                Description      = 'Local group to hold SQL Server related service accounts'
                Ensure           = 'Present'
                MembersToInclude = $SQLServiceAccount.UserName, $SQLAgentServiceAccount.UserName
            }
        }

        # ===================================================================
        # SQL Server installation
        # ===================================================================
        SqlSetup 'SetupSQL'
        {
            DependsOn            = $sqlResourceDependsOn
            InstanceName         = $Instance
            Features             = $FeatureList
            SourcePath           = $ConfigurationData.NonNodeData.SQL.SQLBitsDestination + $Version

            # Passing SqlVersion stops the resource probing the media to work out the
            # version -- it is the media-independent way to tell it this is build 17.
            SqlVersion           = $MajorMinor

            SQLSvcAccount        = $SQLServiceAccount
            AgtSvcAccount        = $SQLAgentServiceAccount
            SqlSvcStartupType    = 'Automatic'
            AgtSvcStartupType    = 'Automatic'

            # The local install account is added alongside the configured domain
            # sysadmins so post-install T-SQL can authenticate even if AD is unreachable.
            SQLSysAdminAccounts  = @($ConfigurationData.NonNodeData.SQL.SQLSysAdminAccounts) +
                                   @("$($Node.NodeName)\$($ConfigurationData.NonNodeData.SQL.LocalInstallAccount)")

            SQLUserDBDir         = $SQLUserDBDir
            SQLUserDBLogDir      = $SQLUserDBLogDir
            SQLTempDBDir         = $TempDBDataDir
            SQLTempDBLogDir      = $TempDBLogDir
            SQLBackupDir         = $SQLBackupDir

            InstallSharedDir     = $ConfigurationData.NonNodeData.SQL.InstallShareDirectory
            InstallSharedWOWDir  = $ConfigurationData.NonNodeData.SQL.InstallShareWoWDir
            InstallSQLDataDir    = $ConfigurationData.NonNodeData.SQL.InstallSQLDataDir
            InstanceDir          = $ConfigurationData.NonNodeData.SQL.InstanceDirectory

            # Slipstream cumulative updates / patches from this folder during install.
            # IMPORTANT: setup.exe validates this path itself regardless of
            # Copy_all_Files_to_TargetNodes, so it must be reachable FROM THE NODE. Use a
            # local path when the bits are staged locally -- a UNC path to a share that
            # does not exist fails the whole install. See README section 9.
            UpdateEnabled        = $ConfigurationData.NonNodeData.SQL.UpdateEnabled
            UpdateSource         = $ConfigurationData.NonNodeData.SQL.UpdateSource

            # Enable TCP at install time. The legacy script relied on xSQLServerNetwork
            # for this, which cannot work on SQL2025 (see the header). Setting it here
            # means the instance is reachable even before SqlProtocolTcpIp runs.
            TcpEnabled           = $true
            NpEnabled            = $false

            # Browser is left running for now and disabled at the very end of the run --
            # see the Disable SQL Browser resource for why that ordering matters.
            BrowserSvcStartupType = 'Automatic'

            # SQL 2025 setup can take well over an hour on slow storage; the default is
            # 7200s. Raised for headroom because a timeout here leaves a partial install.
            SetupProcessTimeout  = 10800
        }

        # ===================================================================
        # Network protocol and port
        #
        # This is the pair of resources that replaces xSQLServerNetwork -- the part
        # that was silently failing on SQL2025 and leaving TCP/IP disabled.
        # ===================================================================

        # Enable the TCP/IP protocol and listen on all IP addresses.
        # SuppressRestart is $true here so the service is restarted only once, by the
        # port resource below, rather than twice in a row.
        SqlProtocol 'EnableTcpIp'
        {
            DependsOn              = '[SqlSetup]SetupSQL'
            InstanceName           = $Instance
            ProtocolName           = 'TcpIp'
            Enabled                = $true
            ListenOnAllIpAddresses = $true
            SuppressRestart        = $true
        }

        # Pin the instance to the configured static port on IPAll.
        # Supplying TcpPort clears the dynamic port; UseTcpDynamicPort must NOT be set
        # at the same time (the resource rejects both together).
        SqlProtocolTcpIp 'SetStaticPort'
        {
            DependsOn       = '[SqlProtocol]EnableTcpIp'
            InstanceName    = $Instance
            IpAddressGroup  = 'IPAll'
            TcpPort         = [string]$Port
            SuppressRestart = $false
            RestartTimeout  = 180
        }

        # Open the instance's port. Every SQL-connecting resource below depends on this,
        # because those resources connect over TCP using the node's host name, which
        # goes through the Windows firewall even from the local machine.
        xFirewall "SQL Server TCP - $Instance"
        {
            DependsOn   = '[SqlProtocolTcpIp]SetStaticPort'
            Name        = 'Allow TCP Access SQL Server' + $Instance
            Action      = 'Allow'
            Description = 'Allow TCP Access SQL Server - SSMS'
            Direction   = 'Inbound'
            Profile     = 'Any'
            LocalPort   = $Port
            Protocol    = 'TCP'
        }

        # ===================================================================
        # Instance configuration
        #
        # Unlike the legacy resources, SqlServerDsc takes ServerName and InstanceName
        # as separate values -- there is no "<instance>,<port>" composite string.
        # PsDscRunAsCredential supplies the SQL sysadmin login for each one.
        # ===================================================================
        SqlMaxDop 'ConfigureSQLMaxDop'
        {
            DependsOn            = "[xFirewall]SQL Server TCP - $Instance"
            Ensure               = $ConfigurationData.NonNodeData.SQL.SQLMaxDopEnsure
            DynamicAlloc         = $ConfigurationData.NonNodeData.SQL.SQLDynamicAlloc
            MaxDop               = $ConfigurationData.NonNodeData.SQL.SQLMaxDop
            ServerName           = $Node.NodeName
            InstanceName         = $Instance
            PsDscRunAsCredential = $LocalInstallAccount
        }

        SqlMemory 'ConfigureSQLMemory'
        {
            DependsOn            = "[xFirewall]SQL Server TCP - $Instance"
            Ensure               = $ConfigurationData.NonNodeData.SQL.SQLMemmEnsure
            DynamicAlloc         = $ConfigurationData.NonNodeData.SQL.SQLMemmDynamicAlloc
            MinMemory            = $ConfigurationData.NonNodeData.SQL.SQLMinMem
            MaxMemory            = $ConfigurationData.NonNodeData.SQL.SQLMaxMem
            ServerName           = $Node.NodeName
            InstanceName         = $Instance
            PsDscRunAsCredential = $LocalInstallAccount
        }

        # sp_configure options. Defined as a table so adding one is a single line
        # rather than another copy-pasted resource block.
        #
        #   Agent XPs                  1  SQL Agent extended stored procedures
        #   remote admin connections   1  allow DAC connections from remote hosts
        #   backup compression default 1  compress backups by default
        #   remote access              0  block remote-server RPC (hardening; static
        #                                 option, so RestartService is required)
        $sqlConfigOptions = @(
            @{ Name = 'SQLConfigAgentXP';             Option = 'Agent XPs';                  Value = 1; Restart = $false }
            @{ Name = 'SQLConfigRemoteAdmin';         Option = 'remote admin connections';   Value = 1; Restart = $false }
            @{ Name = 'SQLConfigBackUpCompression';   Option = 'backup compression default'; Value = 1; Restart = $false }
            @{ Name = 'DisableRemoteAccess';          Option = 'remote access';              Value = 0; Restart = $true  }
        )

        # Resource IDs of the options above, so anything that needs them applied first can
        # depend on the whole set rather than naming them individually.
        $sqlConfigResourceIds = @( $sqlConfigOptions | ForEach-Object { "[SqlConfiguration]$($_.Name)" } )

        foreach ( $opt in $sqlConfigOptions )
        {
            SqlConfiguration $opt.Name
            {
                DependsOn            = "[xFirewall]SQL Server TCP - $Instance"
                ServerName           = $Node.NodeName
                InstanceName         = $Instance
                OptionName           = $opt.Option
                OptionValue          = $opt.Value
                RestartService        = $opt.Restart
                RestartTimeout       = 180
                PsDscRunAsCredential = $LocalInstallAccount
            }
        }

        # ===================================================================
        # Trace flags
        #
        # SqlTraceFlag replaces the legacy hand-written Script resources, which built
        # the registry path from the DEFAULT instance name and therefore threw
        # "Cannot find path HKLM:\...\MSSQLServer\Parameters" on a named instance.
        #
        # TraceFlagsToInclude (rather than TraceFlags) adds to whatever is already set
        # instead of replacing the whole list, so flags configured outside this toolkit
        # are preserved. Values are plain numbers -- strip the '-T' prefix used in the
        # environment file.
        # ===================================================================
        $traceFlagsToInclude = @(
            $ConfigurationData.NonNodeData.SQL.TraceFlags |
                Where-Object { $_.Ensure -eq 'Present' } |
                ForEach-Object { [uint32]($_.Value -replace '^-T','') }
        )

        $traceFlagsToExclude = @(
            $ConfigurationData.NonNodeData.SQL.TraceFlags |
                Where-Object { $_.Ensure -eq 'Absent' } |
                ForEach-Object { [uint32]($_.Value -replace '^-T','') }
        )

        if ( $traceFlagsToInclude.Count -gt 0 -or $traceFlagsToExclude.Count -gt 0 )
        {
            SqlTraceFlag 'ConfigureTraceFlags'
            {
                DependsOn            = "[xFirewall]SQL Server TCP - $Instance"
                ServerName           = $Node.NodeName
                InstanceName         = $Instance
                TraceFlagsToInclude  = $traceFlagsToInclude
                TraceFlagsToExclude  = $traceFlagsToExclude
                # Trace flags are startup parameters, so they need a restart to apply.
                RestartService       = $true
                RestartTimeout       = 180
                PsDscRunAsCredential = $LocalInstallAccount
            }
        }

        # ===================================================================
        # Remaining firewall rules
        # ===================================================================
        if ( $Program )
        {
            xFirewall "SQL Remote Management Firewall Rules - $Instance"
            {
                Name        = $ConfigurationData.NonNodeData.SQL.SQLFirewallName + $Instance
                Action      = $ConfigurationData.NonNodeData.SQL.SQLFireWallAction
                Description = $ConfigurationData.NonNodeData.SQL.SQLFirewallDescrip
                Direction   = 'Inbound'
                Program     = $Program
                Profile     = 'Any'
            }
        }

        xFirewall 'Firewall RDP Rule'
        {
            Name        = 'Allow RDP Access'
            Action      = 'Allow'
            Description = 'Allow RDP Access - Use PowerShell for System Management'
            Direction   = 'Inbound'
            Profile     = 'Any'
            LocalPort   = '3389'
            Protocol    = 'TCP'
        }

        # ===================================================================
        # SQL Server Agent service
        #
        # Nothing else in this configuration manages the Agent service, yet two things
        # depend on it:
        #
        #   1. Configure_SQLServer_Set.sql calls msdb.dbo.sp_set_sqlagent_properties, which
        #      SQL refuses unless 'Agent XPs' is enabled. 'Agent XPs' is toggled by the
        #      AGENT SERVICE ITSELF -- 1 while Agent runs, 0 while it does not. Setting the
        #      sp_configure option is therefore not sufficient on its own: after the service
        #      restart that 'remote access' triggers, the option reads 0 again until Agent
        #      has finished starting. Depending on this resource is what actually closes
        #      that window.
        #
        #   2. The maintenance solution creates nine Agent jobs. A fresh install commonly
        #      leaves the Agent service on Manual, in which case none of them ever run --
        #      and nothing reports it, because the jobs exist and are enabled.
        #
        # Named instances use SQLAgent$<Instance>; the default instance uses SQLSERVERAGENT.
        $agentServiceName = if ( $Instance -eq 'MSSQLSERVER' ) { 'SQLSERVERAGENT' }
                            else { "SQLAgent`$$Instance" }

        Service 'EnsureSQLAgentRunning'
        {
            DependsOn   = $sqlConfigResourceIds
            Name        = $agentServiceName
            State       = 'Running'
            StartupType = 'Automatic'
        }

        # ===================================================================
        # Post-install T-SQL scripts
        #
        # Every *Set.sql in the scripts folder is executed, paired with its matching
        # *Test.sql (idempotency check) and *Get.sql (reporting). HADR_SQLScript_Set.sql
        # is excluded because the AG phase runs it separately.
        #
        # NOTE: the shipped *Test.sql files are mostly stubs ("SELECT NULL"), which
        # always evaluates to "not in desired state", so the Set scripts re-run on every
        # pass. They are individually idempotent (IF NOT EXISTS guards), so this is safe
        # but not free. Verify the end state with Test_SQLServer_PostInstall.ps1.
        # ===================================================================
        $SQLScriptsFolder = $ConfigurationData.NonNodeData.SQL.SQLScriptsFolderDestination
        $SQLScripts       = Get-ChildItem -Path $SQLScriptsFolder -Filter '*Set.sql' -ErrorAction SilentlyContinue |
                                Where-Object { $_.Name -ine 'HADR_SQLScript_Set.sql' }

        foreach ( $SQLScript in $SQLScripts )
        {
            $SetFilePath  = Join-Path -Path $SQLScriptsFolder -ChildPath  $SQLScript.Name
            $TestFilePath = Join-Path -Path $SQLScriptsFolder -ChildPath ($SQLScript.Name -replace 'Set\.sql$','Test.sql')
            $GetFilePath  = Join-Path -Path $SQLScriptsFolder -ChildPath ($SQLScript.Name -replace 'Set\.sql$','Get.sql')

            SqlScript "RunSQLScript-$($SQLScript.BaseName)"
            {
                # Must wait for the sp_configure options, not just the firewall rule.
                # Configure_SQLServer_Set.sql calls msdb.dbo.sp_set_sqlagent_properties,
                # which SQL refuses unless 'Agent XPs' is enabled -- and 'Agent XPs' is
                # enabled by [SqlConfiguration]SQLConfigAgentXP. With both resources
                # depending only on the firewall, DSC was free to order them either way and
                # ran the script first, failing with
                #   "SQL Server blocked access to procedure 'dbo.sp_set_sqlagent_properties'
                #    of component 'Agent XPs' because this component is turned off"
                # Depending on the whole set also keeps the scripts clear of the service
                # restart that 'remote access' triggers.
                #
                # [Service]EnsureSQLAgentRunning is included because 'Agent XPs' reads 0
                # whenever the Agent service is not running, regardless of the sp_configure
                # value -- on a fresh install, or straight after the restart, waiting for
                # the option alone is not enough.
                # [SqlTraceFlag] is included because it sets RestartService = $true, and on
                # a fresh install the flags really do change -- so it bounces the engine.
                # That stops Agent, which flips 'Agent XPs' back to 0 for the duration of
                # the restart, and the scripts were running inside that window. The scripts
                # now also enable 'Agent XPs' for themselves, which is the real fix; this
                # ordering just avoids the pointless restart-mid-script.
                DependsOn            = @( "[xFirewall]SQL Server TCP - $Instance",
                                          '[Service]EnsureSQLAgentRunning',
                                          '[SqlTraceFlag]ConfigureTraceFlags' ) + $sqlConfigResourceIds
                Id                   = $SQLScript.BaseName
                ServerName           = $Node.NodeName
                InstanceName         = $Instance
                SetFilePath          = $SetFilePath
                TestFilePath         = $TestFilePath
                GetFilePath          = $GetFilePath

                # SQL Server presents a self-signed certificate by default. The modern
                # client stack encrypts by default and rejects untrusted certificates,
                # which would fail every script here with "The certificate chain was
                # issued by an authority that is not trusted". 'Optional' keeps these
                # local, in-server calls working. Use 'Mandatory' only once the instance
                # has a properly trusted certificate installed.
                Encrypt              = 'Optional'

                # Some of these scripts (e.g. the maintenance solution) are large.
                QueryTimeout         = 600
                PsDscRunAsCredential = $LocalInstallAccount
            }
        }

        # ===================================================================
        # SQL Server Management Studio (optional)
        # ===================================================================
        if ( $ConfigurationData.NonNodeData.SSMS.InstallStandAloneSSMS -eq 'YES' )
        {
            # Which SSMS to install is chosen by SSMSVersion in the environment .psd1.
            # Exactly one version is installed per run. If SSMSVersion is absent, fall back
            # to inferring it from whether a layout path was supplied, so older environment
            # files that predate this setting keep working unchanged.
            $ssmsVersion    = $ConfigurationData.NonNodeData.SSMS.SSMSVersion
            $ssmsLayoutPath = $ConfigurationData.NonNodeData.SSMS.LayoutPath

            if ( -not $ssmsVersion )
            {
                $ssmsVersion = if ( $ssmsLayoutPath ) { 'SSMS22' } else { 'SSMS17' }
            }

            if ( $ssmsVersion -eq 'SSMS22' )
            {
                if ( -not $ssmsLayoutPath )
                {
                    throw "SSMSVersion is 'SSMS22' but no LayoutPath is set in the environment file's SSMS block. Point LayoutPath at the offline Visual Studio layout folder, or set SSMSVersion = 'SSMS17'."
                }

                # ---------------------------------------------------------------
                # SSMS 19+ : Visual Studio installer layout
                #
                # A Script resource is used rather than Package because the DSC Package
                # resource is built around MSI semantics and does not fit this installer:
                #
                #   * ProductId  - SSMS 19+ registers through the Visual Studio installer
                #                  and has no classic MSI ProductCode GUID for Package to
                #                  match, so Package would reinstall on every pass.
                #   * Arguments  - the bootstrapper takes '--quiet --norestart' style
                #                  switches; MSI-style '/install /passive' is rejected.
                #   * Exit codes - a successful install commonly returns 3010 (reboot
                #                  required), which Package treats as a failure.
                #
                # Detection is therefore by DisplayName + major version in the uninstall
                # registry, which is stable across SSMS releases.
                # ---------------------------------------------------------------
                $ssmsBootstrapper = Join-Path -Path $ssmsLayoutPath -ChildPath $ConfigurationData.NonNodeData.SSMS.LayoutBootstrapper
                $ssmsArguments    = $ConfigurationData.NonNodeData.SSMS.LayoutArguments
                $ssmsMinMajor     = [int]$ConfigurationData.NonNodeData.SSMS.MinimumMajorVersion

                Script 'InstallSSMS'
                {
                    DependsOn = '[SqlSetup]SetupSQL'

                    TestScript = {
                        $uninstallKeys = @(
                            'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'
                            'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
                        )

                        $installed = Get-ItemProperty $uninstallKeys -ErrorAction SilentlyContinue |
                            Where-Object { $_.DisplayName -like 'SQL Server Management Studio*' }

                        foreach ( $app in $installed )
                        {
                            $major = 0
                            if ( $app.DisplayVersion -match '^(\d+)' ) { $major = [int]$Matches[1] }
                            if ( $major -ge $using:ssmsMinMajor )
                            {
                                Write-Verbose "SSMS $($app.DisplayVersion) already installed."
                                return $true
                            }
                        }

                        Write-Verbose "No SSMS with major version >= $using:ssmsMinMajor found."
                        return $false
                    }

                    SetScript = {
                        if ( -not (Test-Path $using:ssmsBootstrapper) )
                        {
                            throw "SSMS bootstrapper not found at '$using:ssmsBootstrapper'. Copy the offline layout folder to this node (see the SSMS block in the environment .psd1)."
                        }

                        Write-Verbose "Installing SSMS from layout '$using:ssmsLayoutPath'..."

                        $process = Start-Process -FilePath $using:ssmsBootstrapper `
                                                 -ArgumentList $using:ssmsArguments `
                                                 -Wait -PassThru -NoNewWindow

                        # 0 = success, 3010 = success + reboot required,
                        # 1641 = success + reboot initiated. Anything else is a real failure.
                        if ( $process.ExitCode -notin @(0, 3010, 1641) )
                        {
                            throw "SSMS installation failed with exit code $($process.ExitCode). See the Visual Studio installer logs in %TEMP% (dd_setup_*.log)."
                        }

                        if ( $process.ExitCode -in @(3010, 1641) )
                        {
                            Write-Verbose 'SSMS installed successfully; a reboot is required to complete it.'
                        }
                        else
                        {
                            Write-Verbose 'SSMS installed successfully.'
                        }
                    }

                    GetScript = {
                        $installed = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
                                                      'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*' `
                                                      -ErrorAction SilentlyContinue |
                            Where-Object { $_.DisplayName -like 'SQL Server Management Studio*' } |
                            Select-Object -First 1

                        return @{ Result = if ($installed) { "$($installed.DisplayName) $($installed.DisplayVersion)" } else { 'Not installed' } }
                    }
                }
            }
            else
            {
                # Classic MSI-style installer (SSMS 17.x / 18.x).
                #
                # ProductId must match the product code of the installer staged at Path.
                # If it does not, DSC cannot tell SSMS is already installed and reruns the
                # installer every pass. Get the real value after one manual install with:
                #   Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*' |
                #     Where-Object DisplayName -like '*Management Studio*' |
                #     Select-Object DisplayName, DisplayVersion, PSChildName
                Package 'InstallSSMS'
                {
                    DependsOn = '[SqlSetup]SetupSQL'
                    Ensure    = $ConfigurationData.NonNodeData.SSMS.Ensure
                    Name      = $ConfigurationData.NonNodeData.SSMS.Name
                    Path      = $ConfigurationData.NonNodeData.SSMS.Path
                    Arguments = $ConfigurationData.NonNodeData.SSMS.Arguments
                    ProductId = $ConfigurationData.NonNodeData.SSMS.ProductId
                }
            }
        }

        # ===================================================================
        # Disable SQL Server / SSMS telemetry (CEIP)
        # ===================================================================
        # Runs after 'Disable SQL Browser', i.e. dead last. Several resources above
        # restart the Database Engine (the 'remote access' option and the trace
        # flags both require it), and a restart brings the telemetry services back
        # up. Disabling them earlier in the run therefore gets undone -- observed as
        # SQLTELEMETRY$<instance> still Running at the end of an otherwise clean run.
        Script 'Disable-SQLandSSMSErrorReporting'
        {
            DependsOn = '[Service]Disable SQL Browser'

            SetScript = {
                # Stop and disable the telemetry services for engine, SSAS and SSIS.
                Get-Service | Where-Object { $_.Name -like 'SQLTELEMETRY*'  } | Set-Service -StartupType Disabled
                Get-Service | Where-Object { $_.Name -like 'SSASTELEMETRY*' } | Set-Service -StartupType Disabled
                Get-Service | Where-Object { $_.Name -like 'SSISTELEMETRY*' } | Set-Service -StartupType Disabled
                Get-Service | Where-Object { $_.Name -like '*TELEMETRY*' -and $_.Status -eq 'Running' } |
                    Stop-Service -Force -ErrorAction SilentlyContinue

                # Clear the CEIP / error-reporting registry flags wherever they appear
                # under the SQL Server hive (the exact key depends on version and
                # instance, so this walks the tree instead of hard-coding paths).
                foreach ( $root in 'HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server',
                                   'HKLM:\SOFTWARE\Wow6432Node\Microsoft\Microsoft SQL Server' )
                {
                    if ( -not (Test-Path $root) ) { continue }

                    Get-ChildItem $root -Recurse -ErrorAction SilentlyContinue |
                        Where-Object { $_.Property -contains 'EnableErrorReporting' } |
                        ForEach-Object {
                            Set-ItemProperty -Path $_.PSPath -Name 'EnableErrorReporting' -Value 0 -ErrorAction SilentlyContinue
                            Set-ItemProperty -Path $_.PSPath -Name 'CustomerFeedback'     -Value 0 -ErrorAction SilentlyContinue
                        }

                    # SSMS stores its own opt-in flag separately.
                    Get-ChildItem $root -Recurse -ErrorAction SilentlyContinue |
                        Where-Object { $_.Property -contains 'UserFeedbackOptIn' } |
                        ForEach-Object {
                            Set-ItemProperty -Path $_.PSPath -Name 'UserFeedbackOptIn' -Value 0 -ErrorAction SilentlyContinue
                        }
                }
            }

            # Reports whether any telemetry service is still running, so
            # Get-DscConfiguration shows something meaningful.
            GetScript = {
                $running = @(Get-Service | Where-Object { $_.Name -like '*TELEMETRY*' -and $_.Status -eq 'Running' })
                return @{ Result = "TelemetryServicesRunning=$($running.Count)" }
            }

            # Unlike the legacy script (which returned $false unconditionally and so
            # re-ran every pass), this reports true once no telemetry service is left
            # running -- making the resource genuinely idempotent.
            TestScript = {
                $running = @(Get-Service | Where-Object { $_.Name -like '*TELEMETRY*' -and $_.Status -eq 'Running' })
                return ($running.Count -eq 0)
            }
        }

        # ===================================================================
        # Disable SQL Browser -- DELIBERATELY LAST
        #
        # With a non-default port, named-instance resolution ("<node>\<instance>")
        # depends entirely on the SQL Browser service listening on UDP 1434. Several
        # resources -- including SqlSetup's own state check -- connect that way, so
        # disabling Browser early makes them fail with "Failed to connect to SQL
        # instance <node>\<instance>". Because most resources hang off SqlSetup, DSC
        # then skips them and the run still reports success while almost nothing is
        # configured. That is exactly the failure this file exists to avoid.
        #
        # Depending on the last configuration resource keeps Browser up for the whole
        # run. Trade-off: if that resource fails, Browser stays enabled -- which
        # Test_SQLServer_PostInstall.ps1 flags as a [WARN], so it will not go unnoticed.
        #
        # Clients must connect as "<node>,<port>" (not "<node>\<instance>") once Browser
        # is disabled. See README section 9.
        # ===================================================================
        Service 'Disable SQL Browser'
        {
            DependsOn   = '[SqlConfiguration]DisableRemoteAccess'
            Name        = 'SQLBrowser'
            StartupType = 'Disabled'
            State       = 'Stopped'
        }

        # Always On availability groups are configured separately by ConfigureAG.ps1.
    }
}

InstallSQLServerModern -ConfigurationData $envData -OutputPath $mofLocation


# ---------------------------------------------------------------------------
# Deployment
#
# Error handling matches the legacy script: DSC/LCM errors are collected rather than
# dumped as raw PowerShell error records, then reported as clean one-line messages.
# Verbose LCM progress is left untouched.
# ---------------------------------------------------------------------------
if ( $Deploy )
{
    Write-Host "Start Time: $(Get-Date)"

    $dscErrors = @()

    Set-DscLocalConfigurationManager -Path $mofLocation -Verbose -ErrorVariable +dscErrors -ErrorAction SilentlyContinue
    Start-DscConfiguration -Path $mofLocation -Wait -Verbose -Force -ErrorVariable +dscErrors -ErrorAction SilentlyContinue

    Write-Host 'Restarting remote Computer(s)...'

    $targetNodes   = $envData.AllNodes.NodeName | Where-Object { $_ -ne '*' }
    $restartErrors = @()

    Restart-Computer -ComputerName $targetNodes -Wait -For PowerShell -Force -ErrorVariable +restartErrors -ErrorAction SilentlyContinue

    foreach ( $restartErr in $restartErrors )
    {
        $restartMsg = ( $restartErr.Exception.Message -replace '[\r\n]+', ' ' ).Trim()

        if ( $restartErr.FullyQualifiedErrorId -match 'CannotWaitLocalComputer' )
        {
            # Expected when the machine running this script is also a target node:
            # Restart-Computer cannot wait on its own host, but the restart still
            # happens and other nodes are waited on normally.
            Write-Host "  [INFO] Local computer restarted (can't be waited on by its own script; this is normal)." -ForegroundColor Cyan
        }
        elseif ( $restartMsg -match 'shutdown has already been scheduled|1190' )
        {
            # SQL Server setup routinely requests a reboot of its own, so by the time this
            # runs a shutdown is often already queued and Windows refuses to schedule a
            # second one (error 1190). The node still reboots -- this reports that the
            # restart is redundant, not that it failed.
            #
            # Reported rather than swallowed: if the node does NOT come back, this line is
            # the record that a reboot was expected. It is deliberately not counted as an
            # error, because counting it made a fully successful run finish with
            # "[ 1 error(s)] STEP 14".
            $whichNode = if ( $restartMsg -match 'computer\s+(\S+?)\s+with' ) { $Matches[1] } else { 'the target node' }
            Write-Host "  [INFO] $whichNode already had a restart pending (SQL setup requested one); it will still reboot." -ForegroundColor Cyan
        }
        else
        {
            $dscErrors += $restartErr
        }
    }

    # Wait for the SQL Server service to actually be RUNNING before resuming.
    #
    # Restart-Computer -Wait -For PowerShell returns as soon as PowerShell answers, which
    # is well before SQL Server has finished starting. Resuming at that moment re-runs
    # SqlSetup's Test-TargetResource against an instance that is not up yet, it returns
    # false again, and DSC skips every dependent resource a second time -- the static
    # port, SQL Browser, memory, MaxDop, trace flags and all the T-SQL scripts.
    #
    # That is the whole of this failure:
    #
    #   DSC_SqlSetup failed ... Test-TargetResource function returned false when
    #   Set-TargetResource function verified the desired state
    #
    # A fresh run minutes later always succeeded, because by then SQL was up. Waiting here
    # removes the need for that second run.
    # $Instance is scoped inside the configuration block, not here -- read the instance
    # name from the environment data, which is what this scope has.
    $deployInstance      = $envData.NonNodeData.SQL.InstanceName
    $instanceServiceName = if ( $deployInstance -eq 'MSSQLSERVER' ) { 'MSSQLSERVER' } else { "MSSQL`$$deployInstance" }
    $serviceWaitSeconds  = 300

    foreach ( $node in $targetNodes )
    {
        # "Not installed" and "installed but still starting" need opposite treatment, and
        # only the second is worth waiting for. Waiting five minutes for a service that
        # does not exist tells you nothing and delays the report that would have told you
        # setup failed -- observed on a run where SQL had genuinely failed to install and
        # the script sat waiting for a service that was never going to appear.
        $exists = $null -ne (Get-Service -ComputerName $node -Name $instanceServiceName -ErrorAction SilentlyContinue)

        if ( -not $exists )
        {
            Write-Host "  [WARN] $node`: $instanceServiceName does not exist -- SQL Server is not installed on this node." -ForegroundColor Yellow
            Write-Host "         setup.exe ran but produced no instance. The reason is in that node's setup log:" -ForegroundColor DarkYellow
            Write-Host "         Get-ChildItem '\\$node\c`$\Program Files\Microsoft SQL Server\*\Setup Bootstrap\Log\Summary.txt' | Sort LastWriteTime -Desc | Select -First 1 | Get-Content -TotalCount 45" -ForegroundColor DarkYellow
            Write-Host "         Look at 'Exit code (Decimal)', 'Exit message' and 'Final result'." -ForegroundColor DarkYellow
            if ( Test-Path Variable:Global:SQLInstallWarningCount ) { $global:SQLInstallWarningCount++ }
            continue
        }

        $deadline = (Get-Date).AddSeconds($serviceWaitSeconds)
        $state    = $null

        Write-Host "  Waiting for $instanceServiceName on $node to start ..." -ForegroundColor Gray

        while ( (Get-Date) -lt $deadline )
        {
            try   { $state = (Get-Service -ComputerName $node -Name $instanceServiceName -ErrorAction Stop).Status }
            catch { $state = $null }

            if ( $state -eq 'Running' ) { break }
            Start-Sleep -Seconds 10
        }

        if ( $state -eq 'Running' )
        {
            Write-Host "  [OK] $node`: $instanceServiceName is running." -ForegroundColor Green
        }
        else
        {
            # Reported, not fatal. The resume below may still succeed, and if it does not
            # the resource errors are collected and shown like any other.
            Write-Host "  [WARN] $node`: $instanceServiceName did not reach Running within $serviceWaitSeconds seconds (last seen: $(if ($state) { $state } else { 'unknown' }))." -ForegroundColor Yellow
            Write-Host "         Resuming anyway -- SqlSetup may report that it cannot verify the desired state." -ForegroundColor DarkYellow
            if ( Test-Path Variable:Global:SQLInstallWarningCount ) { $global:SQLInstallWarningCount++ }
        }
    }

    # LCM was configured with ActionAfterReboot = StopConfiguration, so the
    # configuration must be explicitly resumed after the reboot.
    Start-DscConfiguration -ComputerName $targetNodes -UseExisting -Wait -Verbose -Force -ErrorVariable +dscErrors -ErrorAction SilentlyContinue

    # MOFs can contain credentials in plain text (PSDSCAllowPlainTextPassword), so
    # remove them as soon as the push is finished.
    Write-Host 'Cleaning up MOF files from this machine since they may contain credential info' -ForegroundColor Green
    if ( Test-Path $mofLocation ) { Remove-Item $mofLocation -Recurse -Force }

    if ( $dscErrors.Count -gt 0 )
    {
        # Collapse identical messages. A resource that fails once per node per pass can
        # emit the same text dozens of times, which buries the distinct problems -- one
        # real run produced 66 issues that were only 3 distinct faults.
        $grouped = $dscErrors |
            ForEach-Object {
                $c = $_.OriginInfo.PSComputerName
                if ( -not $c ) { $c = $_.PSComputerName }
                [pscustomobject]@{
                    Computer = $c
                    Message  = ( $_.Exception.Message -replace '[\r\n]+', ' ' ).Trim()
                }
            } |
            Group-Object -Property Computer, Message

        Write-Host ''
        Write-Host "DSC reported $($dscErrors.Count) resource issue(s) during deployment ($($grouped.Count) distinct):" -ForegroundColor Yellow

        foreach ( $group in $grouped )
        {
            $item   = $group.Group[0]
            $repeat = if ( $group.Count -gt 1 ) { "  (x$($group.Count))" } else { '' }

            Write-Host "  [WARN] $($item.Computer): $($item.Message)$repeat" -ForegroundColor Yellow
            if ( Test-Path Variable:Global:SQLInstallWarningCount ) { $global:SQLInstallWarningCount++ }

            # Add context for the failure that is easiest to misread. This message is
            # NOT always benign: every resource using PsDscRunAsCredential (MaxDop,
            # memory, the sp_configure options, trace flags and all the T-SQL scripts)
            # fails with it when the local install account lacks logon rights on the
            # node -- which leaves SQL installed but almost entirely unconfigured.
            # It was previously reported as [INFO], which hid exactly that failure on
            # a fresh two-node build.
            if ( $item.Message -match 'has not been granted the requested logon type' )
            {
                # Two different situations produce this text, and the advice differs:
                #
                #  * From MSFT_UserResource's Test: a password-validation logon that the
                #    node's logon-rights policy refuses. It happens even when the account
                #    exists and IS an administrator, and it does NOT stop PsDscRunAsCredential
                #    resources from working. The User resource has been removed from this
                #    config for exactly this reason -- if you see it, something re-added it.
                #
                #  * From any other resource: that account genuinely cannot log on, and
                #    everything running as it will fail. Check Step 7's output first.
                Write-Host "         ^ '$($item.Computer)' refused a logon for the install account." -ForegroundColor DarkYellow

                if ( $item.Message -match 'MSFT_UserResource' )
                {
                    Write-Host "           Source is the User resource's own password check, which fails on hardened nodes even when the account is fine. Resources using PsDscRunAsCredential are unaffected -- verify with Test_SQLServer_PostInstall.ps1 before treating this as the cause of anything." -ForegroundColor DarkYellow
                }
                else
                {
                    Write-Host "           Confirm Step 7 reported [OK] for this node, that 'SQLInstallAcc' exists, and that it is in local Administrators. Everything running as that account fails until it can log on." -ForegroundColor DarkYellow
                }
            }
        }

        Write-Host ''
    }

    Write-Host ' '
    Write-Host 'DONE: Verify the result with Test_SQLServer_PostInstall.ps1 -- a clean finish here does NOT prove the desired state was reached.' -ForegroundColor Green
    Write-Host ' '
    Write-Host "End Time: $(Get-Date)"
}
