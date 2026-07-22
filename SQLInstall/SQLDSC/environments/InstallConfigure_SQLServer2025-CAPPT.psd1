@{
    AllNodes = @(
        @{
            NodeName = '*'

            PSDscAllowDomainUser        = $true              # Suppress errors about using domain users. We want to use domain accounts!
            PSDSCAllowPlainTextPassword = $true              # Suppress error and warning regarding plain text passwords   TO DO: use certificate to encrypt MOF files
			SQLServiceAccount           = 'MS\$SQL2016SQLAcct'    # Service Account: SQL Server Database Engine
			SQLAgentServiceAccount      = 'MS\$SQL2016SQLAgt'    # Service Account: SQL Server Agent
        },

        @{
            NodeName = 'DDCWNZWGDBS03'


       },

        @{
           NodeName = 'DDCWNZWGDBS04'



         }

    )

    NonNodeData = @{

        Data = @{
            DSCResourceLocation              = "\\$env:COMPUTERNAME\SQLInstall\SQLDSC\modules"      # Create a file share named SQLInstall that points to C:\SQLInstall on the Management server
            CopyDSCResources_to_AdminMachine = 'NO'                                                # Set it to 'NO' if DSC resources are already copied to install machine, otherwise 'YES'
            Copy_all_Files_to_TargetNodes    = 'NO'                                                # Set it to 'NO' if DSC resources, SQL Server binary, patches, SSMS etc are ALREADY copied to target servers where SQL will be installed
        }


        SQL  = @{
            SQLVersion            = 'SQL2025'                                                    # C:\SQLInstall\SQLDSC\configs\Install_and_Configure_SQLServer_Multi_Node.ps1 -- now actually used (see README)
            InstanceName          = 'CAPPT'
            SQLEnginePort         = '1443'

            SQLSysAdminAccounts   = 'MS\NPE-SQLAdmins','MS\NPEADMBaydushsl','MS\NPEADMRodriguezdk','NPE-SO-DBAs'                            # The Installer domain account and SQL Server DBA domain group have sysadmin rights
            LocalServerAdmins     = 'MS\NPE-SQLAdmins','MS\NPE-ISSO-ComputerAdmins','MS\NPE-CSM-DBA'                                               # The SQL Server DBA domain is a local admin; the Installer account is manually added to the local admins group after VMs are provisioned
            LocalInstallAccount   = 'SQLInstallAcc'                                                # SQLInstallAcc is a local user with sysadmin rights, but is not a local admin



            SQLFeatures           = 'SQLEngine'

            DotNetBitsSource      = "\\$env:COMPUTERNAME\SQLInstall\SQLDSC\bits\Sxs"
            DotNetBitsDestination = 'C:\SQLInstall\SQLDSC\bits\Sxs'
            SQLBitsSource         = "\\$env:COMPUTERNAME\SQLInstall\SQLDSC\bits"
            SQLBitsDestination    = 'C:\SQLInstall\SQLDSC\bits\'
            SSMSBitsSource        = "\\$env:COMPUTERNAME\SQLInstall\SQLDSC\bits\SSMS"
            SSMSBitsDestination   = 'C:\SQLInstall\SQLDSC\bits\SSMS'

            InstanceDirectory     = 'C:\Program Files\Microsoft SQL Server'
            InstallShareDirectory = 'C:\Program Files\Microsoft SQL Server'
            InstallShareWoWDir    = 'C:\Program Files (x86)\Microsoft SQL Server'
            InstallSQLDataDir     = 'C:\Program Files\Microsoft SQL Server'

            SQLUserDBDir          = 'G:\MSSQL\DATA'
            SQLUserDBLogDir       = 'H:\MSSQL\LOG'
            SQLTempDBDir          = 'F:\MSSQL\TempDB'
            SQLTempDBLogDir       = 'F:\MSSQL\TempDB'
            SQLBackupDir          = 'E:\SQLBackups'


            <# xSQLServerFirewall #>
            SQLFirewallEnsure     = 'Present'                                               # Ensures that SQL firewall rules are Present or Absent on the machine.
            SQLFirewallFeatures   = 'SQLENGINE'                                             # SQL features to enable firewall rules for.
            SQLFirewallSourcePath = "\\$env:COMPUTERNAME\SQLInstall\SQLDSC\bits\SQL2025"    # UNC path to the root of the source files for installation


            <# Max Dop Config #>
            SQLMaxDopEnsure       = 'Present'                                               # When set to 'Present' then max degree of parallelism will be set to either the value in parameter MaxDop or dynamically configured when parameter DynamicAlloc is set to $true. When set to 'Absent' max degree of parallelism will be set to 0 which means no limit in number of processors used in parallel plan execution. { Present | Absent }.
            SQLDynamicAlloc       = $true                                                   # Set to $true then max degree of parallelism will be dynamically configured. When this is set parameter is set to $true, the parameter MaxDop must be set to $null or not be configured.
            SQLMaxDop             = $null                                                   # Numeric value to limit the number of processors used in parallel plan execution


            <# SQL Server Memmory #>
            SQLMemmEnsure         = 'Present'                                               # When set to 'Present' then min and max memory will be set to either the value in parameter MinMemory and MaxMemory or dynamically configured when parameter DynamicAlloc is set to $true. When set to 'Absent' min and max memory will be set to default values. { Present | Absent }.
            SQLMemmDynamicAlloc   = $true                                                   # If set to $true then max memory will be dynamically configured. When this is set parameter is set to $true, the parameter MaxMemory must be set to $null or not be configured. Default value is $false.
            SQLMaxMem             = $null                                                   # Maximum amount of memory, in MB, in the buffer pool used by the instance of SQL Server.
            SQLMinMem             = $null                                                   # Minimum amount of memory, in MB, in the buffer pool used by the instance of SQL Server.


            <# TraceFlags #>
            TraceFlags = @(
                @{
                    value  = '-T1222'
                    Ensure = 'Present'
                },
                @{
                    value  = '-T3226'
                    Ensure = 'Present'
                }
            )


            #SQL Server Report RDP Firewall Rule
            SQLFirewallName    = 'SQL Remote Management Firewall Rule'
            SQLFirewallDescrip = 'Allows SQL Connections from SQL management servers'
            SQLFireWallAction  = 'Allow'


            <# SQL Server Post Install Config SQL Script #>
            SQLScriptsFolderSource      = "\\$env:COMPUTERNAME\SQLInstall\SQLDSC\SQLScripts"
            SQLScriptsFolderDestination = 'C:\SQLInstall\SQLDSC\SQLScripts'
            SQLSetFilePath              = 'C:\SQLInstall\SQLDSC\SQLScripts\Configure_SQLServer_Set.sql'
            SQLTestFilePath             = 'C:\SQLInstall\SQLDSC\SQLScripts\Configure_SQLServer_Test.sql'
            SQLGetFilePath              = 'C:\SQLInstall\SQLDSC\SQLScripts\Configure_SQLServer_Get.sql'


            <# Update SQL by Slipstreaming Patches #>
            UpdateEnabled     = $true
            UpdateSource      = "\\$env:COMPUTERNAME\SQLInstall\SQLDSC\bits\SQLPatches"
            UpdateDestination = 'C:\SQLInstall\SQLDSC\bits\SQLPatches'
        }


        SSMS = @{
            InstallStandAloneSSMS = 'YES'       # Option to add or not add SSMS
            Ensure                = 'Present'
            Name                  = 'SSMS-Setup-ENU'
            Path                  = 'C:\SQLInstall\SQLDSC\bits\SSMS\SSMS-Setup-ENU.exe'
            Arguments             = '/install /passive /norestart'
            ProductId             = 'ac84c935-8f13-4f73-b541-7b09a11bdea8'

            # GUID for Microsoft SQL Server Management Studio - 17.4 {ac84c935-8f13-4f73-b541-7b09a11bdea8}
            # GUID for Microsoft SQL Server Management Studio - 17.9 {91a1b895-c621-4038-b34a-01e7affbcb6b}
        }
    }
}
