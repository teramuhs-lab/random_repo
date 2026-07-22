#Requires -Version 5.1

#Install StandAlone SQL Server and Configure AG

param(
    [Parameter(Mandatory=$true)]$envDataFilePath,
    $InstallAccount,
    $LocalInstallAccount,      
    $SQLServiceAccount, 
    $SQLAgentServiceAccount,   
    [ValidateSet("SQL2017","SQL2016","SQL2014","SQL2012")] 
    $Version,  
    [switch]$Deploy
    )

#$envDataFilePath = 'C:\SQLInstall\SQLDSC\environments\CAPPT_sqlAG_Enviroment_Data.psd1'
$envData = Invoke-Expression (Get-Content -Path $envDataFilePath | Out-String)
$envDataFile = Get-Item $envDataFilePath
$mofLocationParent = Join-Path -Path "$($envDataFile.DirectoryName)\..\mofs" -ChildPath ($EnvDataFile.BaseName -replace '\.','-')

#Randomize mof folder by creating a new one everytime to avoid accidentlay pushing MOF files that are already applied to different servers but laying around in the same folder

#$TempFolder = [System.IO.Path]::GetTempPath() #use this to store MOF files in temp folder
$Guid = [System.Guid]::NewGuid()
#$TempDir = Join-Path -Path $mofLocationParent -ChildPath $Guid.Guid
$mofLocation = Join-Path -Path $mofLocationParent -ChildPath $Guid.Guid
#New-Item -Path $TempDir -ItemType Directory | Out-Null
New-Item -Path $mofLocation -ItemType Directory | Out-Null

#$mofLocation = [io.path]::combine($mofLocationParent, ($EnvDataFile.BaseName -replace '\.','-'),$TempDir)

[DscLocalConfigurationManager()]
configuration 'SetResourceModuleLocation' {
node $AllNodes.NodeName {
  Settings {
      RefreshMode = 'Push'
      RebootNodeIfNeeded = $true
      ActionAfterReboot = 'StopConfiguration'
      ConfigurationMode = 'ApplyAndMonitor'
      # A configuration Id needs to be specified (bug)
      ConfigurationID = '3a15d863-bd25-432c-9e45-9199afecde91'
  }
  ResourceRepositoryShare FileShare {
      SourcePath = $ConfigurationData.NonNodeData.Data.DSCResourceLocation
                }
        }
}

SetResourceModuleLocation -ConfigurationData $envData -OutputPath $mofLocation

#$envDataFilePath = 'C:\SQLInstall\SQLDSC\environments\CAPPT_sqlAG_Enviroment_Data.psd1'
#$envData = Invoke-Expression (Get-Content -Path $envDataFilePath | Out-String)
Configuration 'InstallSQLandConfigureAvailabilityGroup' {

    Import-DscResource -ModuleName 'PSDesiredStateConfiguration'
    Import-DscResource -ModuleName 'xSQLServer'  -ModuleVersion '9.0.0.0'
    Import-DscResource -ModuleName 'xNetworking' -ModuleVersion '5.3.0.0'

    #Import-DscResource -ModuleName 'SecurityPolicyDsc' 

    #Import-DscResource -ModuleName 'AccessControlDSC'

Node $AllNodes.NodeName
    {

#$SQLVersion = $ConfigurationData.NonNodeData.SQL.SQLVersion
        if(!$Version) {
                $Version = $ConfigurationData.NonNodeData.SQL.SQLVersion
            }

        $SQLInstanceDirectory = $ConfigurationData.NonNodeData.SQL.InstanceDirectory + '\'
        $Instance = $ConfigurationData.NonNodeData.SQL.InstanceName

        # SSMS/ADV_SSMS are bundled with the engine installer through SQL2014 only; from SQL2016 onwards
        # they're a separate installer, so they're dropped from the feature list. Build number is the
        # MSSQL<NN> folder suffix under the instance directory (e.g. MSSQL13.<instance> for SQL2016).
        $sqlVersionInfo = @{
            'SQL2012' = @{ Build = '11'; SQLEngineFeatures = 'SSMS,ADV_SSMS,SQLENGINE,FULLTEXT,CONN,BC'; ExtraFeatures = 'SSMS,ADV_SSMS,FULLTEXT,CONN,BC,SDK,SNAC_SDK' }
            'SQL2014' = @{ Build = '12'; SQLEngineFeatures = 'SSMS,ADV_SSMS,SQLENGINE,FULLTEXT,CONN,BC'; ExtraFeatures = 'SSMS,ADV_SSMS,FULLTEXT,CONN,BC' }
            'SQL2016' = @{ Build = '13'; SQLEngineFeatures = 'SQLENGINE,FULLTEXT,CONN,BC';               ExtraFeatures = 'FULLTEXT,CONN,BC' }
            'SQL2017' = @{ Build = '14'; SQLEngineFeatures = 'SQLENGINE,FULLTEXT,CONN,BC';               ExtraFeatures = 'FULLTEXT,CONN,BC' }
        }

        if ($sqlVersionInfo.ContainsKey($Version)) {
            $versionInfo = $sqlVersionInfo[$Version]
            $Program = $SQLInstanceDirectory + "MSSQL$($versionInfo.Build).$Instance\MSSQL\Binn\sqlservr.exe"
            if ($ConfigurationData.NonNodeData.SQL.SQLFeatures -eq 'SQLEngine') {
                $FeatureList = $versionInfo.SQLEngineFeatures
            } else {
                $FeatureList = $ConfigurationData.NonNodeData.SQL.SQLFeatures + ',' + $versionInfo.ExtraFeatures
            }
        } else {
            $FeatureList = "SQLENGINE,CONN,BC"
        }

#Enable Firewall Rules
        $wmirulenames = 'WMI-RPCSS-In-TCP','WMI-WINMGMT-In-TCP','WMI-WINMGMT-Out-TCP','WMI-ASYNC-In-TCP'
        $wmirulenames | ForEach-Object {
            xFirewall "Enable WMI - $_" {
                Name    = $_
                Enabled = 'True'
            }
       
        }   

        WindowsFeature 'DotNet35' {
        Name   = 'Net-Framework-Core'
        Source = $ConfigurationData.NonNodeData.SQL.DotNetBitsDestination
        #DependsOn = '[File]CopyDotNetFilesLocally'
          }

#$sqlResourceDependsOn += '[WindowsFeature]DotNet35'
          #$sqlResourceDependsOn += '[File]CopySQLSourceFilesLocally'

#region COPY files 
     $sqlResourceDependsOn = @()
        
     #Copy files(softwares bits and powershell modules)         
     if ($ConfigurationData.NonNodeData.Data.Copy_all_Files_to_TargetNodes -eq 'YES') {
        
          $sqlResourceDependsOn += '[WindowsFeature]DotNet35'
          $sqlResourceDependsOn += '[File]CopySQLSourceFilesLocally'
            
        #Copy SQL binaries Locally
        File 'CopySQLSourceFilesLocally' {
              SourcePath      = $ConfigurationData.NonNodeData.SQL.SQLBitsSource + '\' + $Version
              DestinationPath = $ConfigurationData.NonNodeData.SQL.SQLBitsDestination + $Version
              Type            = 'Directory'
              Recurse         = $true
              Checksum        = 'SHA-256'
              MatchSource     = $true
          }
        
        #Copy SQL Patches Locally
        File 'CopySQLPatchesLocally' {
              SourcePath      = $ConfigurationData.NonNodeData.SQL.UpdateSource   
              DestinationPath = $ConfigurationData.NonNodeData.SQL.UpdateDestination 
              Type            = 'Directory'
              Recurse         = $true
              Checksum        = 'SHA-256'
              MatchSource     = $true
          }

        File 'CopyDotNetFilesLocally' {
                  SourcePath      = $ConfigurationData.NonNodeData.SQL.DotNetBitsSource
                  DestinationPath = $ConfigurationData.NonNodeData.SQL.DotNetBitsDestination
                  Type            = 'Directory'
                  Recurse         = $true
                  Checksum        = 'SHA-256'
                  MatchSource     = $true
          }
  
        File 'CopySSMSFilesLocally' {
                SourcePath      = $ConfigurationData.NonNodeData.SQL.SSMSBitsSource
                DestinationPath = $ConfigurationData.NonNodeData.SQL.SSMSBitsDestination
                Type            = 'Directory'
                Recurse         = $true
                Checksum        = 'SHA-256'
                MatchSource     = $true
        }

        File 'CopySQLScriptsFolderLocally' {
                #\\PPTPOC12K12V003\c$\Temp\SQLInstall\SQLDSC\SQLScripts
                SourcePath      = $ConfigurationData.NonNodeData.SQL.SQLScriptsFolderSource
                DestinationPath = $ConfigurationData.NonNodeData.SQL.SQLScriptsFolderDestination
                Type            = 'Directory'
                Recurse         = $true
                Checksum        = 'SHA-256'
                MatchSource     = $true
        }
        
        #Copy powershell modules to nodes
        File 'CopyPowerShellDSCModulesLocally' {
              SourcePath      = $ConfigurationData.NonNodeData.Data.DSCResourceLocation   
              DestinationPath = "C:\Program Files\WindowsPowerShell\Modules"
              Type            = 'Directory'
              Recurse         = $true
              Checksum        = 'SHA-256'
              MatchSource     = $true
          }
        #this logic creates new data and log folder for every instance, avoiding naming conflict when installing multiple instance per server
        #Helpful especially in test environments where we install multiple instances

} 
        
#endregion        
        
        ## create folders
        
        $TempDBDataDir = $ConfigurationData.NonNodeData.SQL.SQLTempDBDir + '\' + $Instance
        $TempDBLogDir = $ConfigurationData.NonNodeData.SQL.SQLTempDBLogDir + '\' + $Instance
        $SQLUserDBDir = $ConfigurationData.NonNodeData.SQL.SQLUserDBDir + '\' + $Instance
        $SQLUserDBLogDir = $ConfigurationData.NonNodeData.SQL.SQLUserDBLogDir + '\' + $Instance
        $SQLBackupDir = $ConfigurationData.NonNodeData.SQL.SQLBackupDir + '\' + $Instance

#Define array of folders to be created
        
        $folders = @($SQLUserDBDir,
                    $SQLUserDBLogDir,
                    $TempDBDataDir,
                    $TempDBLogDir,
                    $SQLBackupDir)
          
        #$sqlResourceDependsOn = @()
        $uniquefolders = $folders | Sort-Object -Unique 
  
        for($i=0;$i -lt $uniquefolders.count;$i++) {
            $sqlResourceDependsOn += "[File]Folder_$i"
            File "Folder_$i" {
                Type = 'Directory'
                DestinationPath = $uniquefolders[$i]
                Checksum        = "SHA-256"
            }
        }

#placeholder for REGION Permission for AD and/or LOCAL Virtual service Accounts#

#region *** Permission for Domain and/or LOCAL Virtual service Accounts ***       
        
        #Create a local user account that will be used for Installation and patching
        #Account should be disabled and removed from admin role when not used
        User LocalSQLInstallAccount
            {
                UserName = $LocalInstallAccount.UserName
                Description = 'Local account to install SQL Server, Please disable when not used'
                Disabled = $false #TO DO: include this parameter in the config data file
                Ensure = 'Present'
                FullName = 'SQL Install Account'
                Password = $LocalInstallAccount
                #Password = $InstallAccount.password
                PasswordChangeRequired = $false
                PasswordNeverExpires = $false
                
            }
        
        Group CreateSQLAdminsLocalGroup 
        {
            GroupName = 'SQLAdmins'
            Description = 'Local Group to hold SQL Server Administrator Accounts'
            Ensure = 'Present'
            MembersToInclude = $ConfigurationData.NonNodeData.SQL.LocalServerAdmins
        }

If ($SQLServiceAccount -eq $null )  {
        #If ($ConfigurationData.AllNodes.EngineServiceAccountName -eq $null ) {

## Determine the Service SID to use 
            if ($Instance -ine 'MSSQLServer') {
                $LocalSQLVirtualAccount = ('NT SERVICE\MSSQL${0}' -f $Instance)
                $LocalAgentVirtualAccount = ('NT SERVICE\SQLAGENT${0}' -f $Instance)
            }
            else {
                $LocalSQLVirtualAccount = 'NT SERVICE\MSSQLSERVER'
                $LocalAgentVirtualAccount = 'NT SERVICE\SQLSERVERAGENT'
            }

Group CreateSQLServiceLocalGroup 
                {
                
                    GroupName = 'SQLServices'
                    Description = 'Local Group to hold SQL Server related Service Accounts'
                    Ensure = 'Present'
                    DependsOn = '[xSQLServerSetup]SetupSQL'
                    #MembersToInclude = @($LocalSQLVirtualAccount,$LocalAgentVirtualAccount)
                    MembersToInclude = @($LocalSQLVirtualAccount,$LocalAgentVirtualAccount)
                }

}

        else
        {

            Group CreateSQLServiceLocalGroup 
                {
                
                    GroupName = 'SQLServices'
                    Description = 'Local Group to hold SQL Server related Service Accounts'
                    Ensure = 'Present'
                    #DependsOn = '[xSQLServerSetup]SetupSQL'
                    MembersToInclude = $SQLServiceAccount.UserName,$SQLAgentServiceAccount.UserName
                }

}

#endregion *** Permission for AD and/or LOCAL Virtual service Accounts ***        

#region *** SQL Server Install ***

xSQLServerSetup 'SetupSQL' {
                  DependsOn            = $sqlResourceDependsOn
                  InstanceName         = $ConfigurationData.NonNodeData.SQL.InstanceName
                  #PsDscRunAsCredential = $ConfigurationData.NonNodeData.Accounts.Setup  #Added PsDscRunAsCredential to replace old parm SetupCredential
                  #PsDscRunAsCredential = $InstallAccount
                  #PsDscRunAsCredential = $LocalInstallAccount
                  SourcePath           = $ConfigurationData.NonNodeData.SQL.SQLBitsDestination + $Version
                  #Features             = $ConfigurationData.NonNodeData.SQL.SQLFeatures
                  Features             = $FeatureList
                  #SQLSvcAccount        = $ConfigurationData.NonNodeData.Accounts.SQLService
                  #AgtSvcAccount        = $ConfigurationData.NonNodeData.Accounts.SQLAgent
 
                  SQLSvcAccount        = $SQLServiceAccount #$SQLServiceAccount  #$null #
                  AgtSvcAccount        = $SQLAgentServiceAccount #$InstallAccount # $null #
                  
                  SQLSysAdminAccounts  = @($ConfigurationData.NonNodeData.SQL.SQLSysAdminAccounts) + @( "$($Node.NodeName)\$($ConfigurationData.NonNodeData.SQL.LocalInstallAccount)")
                  #SQLSysAdminAccounts  = "$($Node.NodeName)\$($ConfigurationData.NonNodeData.SQL.LocalInstallAccount)"
                  #SQLSysAdminAccounts  = $ConfigurationData.NonNodeData.SQL.SQLSysAdminAccounts,"$($Node.NodeName)\$($ConfigurationData.AllNodes.LocalInstallAccount)"
                  
                  SQLUserDBDir         = $SQLUserDBDir
                  SQLUserDBLogDir      = $SQLUserDBLogDir
                  SQLTempDBDir         = $TempDBDataDir  
                  SQLTempDBLogDir      = $TempDBLogDir
                  SQLBackupDir         = $SQLBackupDir
         
                 InstallSharedDir = $ConfigurationData.NonNodeData.SQL.InstallShareDirectory
                 InstallSharedWOWDir = $ConfigurationData.NonNodeData.SQL.InstallShareWoWDir
                 InstallSQLDataDir = $ConfigurationData.NonNodeData.SQL.InstallSQLDataDir
                 InstanceDir = $ConfigurationData.NonNodeData.SQL.InstanceDirectory  
                 
                 UpdateEnabled = $ConfigurationData.NonNodeData.SQL.UpdateEnabled  
                 UpdateSource = $ConfigurationData.NonNodeData.SQL.UpdateSource           
                 
                 }

        ## Ensure sql instance is listening on specific Assigned TCP port
          xSQLServerNetwork 'ConfigureSQLPort' {
                DependsOn            = '[xSQLServerSetup]SetupSQL'
                InstanceName         = $ConfigurationData.NonNodeData.SQL.InstanceName
                TCPPort              = $ConfigurationData.NonNodeData.SQL.SQLEnginePort
                ProtocolName         = 'tcp'
                RestartService       = $true
                IsEnabled            = $true
         }

        #$firewallName = "SQL Server TCP - $Instance"
         xFirewall "SQL Server TCP - $Instance" {
                DependsOn     = '[xSQLServerSetup]SetupSQL' 
                Name          = 'Allow TCP Access SQL Server' + $Instance
                Action        = 'Allow'
                Description   = 'Allow TCP Access SQL Server - SSMS'
                Direction     = 'Inbound'
                Profile       = 'Any'
                LocalPort     = $ConfigurationData.NonNodeData.SQL.SQLEnginePort
                Protocol      = 'TCP'
                  }
        ## set Maximum Degree of Parallelism(MAXDOP)
         xSQLServerMaxDop 'ConfigureSQLMaxDop' {
                 DependsOn             = '[xFirewall]SQL Server TCP - ' + $Instance
                 Ensure                = $ConfigurationData.NonNodeData.SQL.SQLMaxDopEnsure
                 DynamicAlloc          = $ConfigurationData.NonNodeData.SQL.SQLDynamicAlloc
                 MaxDop                = $ConfigurationData.NonNodeData.SQL.SQLMaxdop
                 SQLServer             = $Node.NodeName
                 SQLInstanceName       = $ConfigurationData.NonNodeData.SQL.InstanceName + ',' + $ConfigurationData.NonNodeData.SQL.SQLEnginePort
                 PsDscRunAsCredential  = $LocalInstallAccount
          }

        ## Dynamically setup Max and Min Memory using DSC memory rules
          xSQLServerMemory 'ConfigureSQLMemory' {
                 DependsOn            = '[xFirewall]SQL Server TCP - ' + $Instance
                 Ensure               = $ConfigurationData.NonNodeData.SQL.SQLMemmEnsure
                 DynamicAlloc         = $ConfigurationData.NonNodeData.SQL.SQLMemmDynamicAlloc
                 SQLServer            = $Node.NodeName
                 SQLInstanceName      = $ConfigurationData.NonNodeData.SQL.InstanceName + ',' + $ConfigurationData.NonNodeData.SQL.SQLEnginePort
                 MaxMemory            = $ConfigurationData.NonNodeData.SQL.SQLMaxMem
                 MinMemory            = $ConfigurationData.NonNodeData.SQL.SQLMinMem
                 PsDscRunAsCredential = $LocalInstallAccount

          }

        ## TODO - Replace with one xSQLServerConfiguration and have the data in config file, loop through the hash table here
        xSQLServerConfiguration 'SQLConfigAgentXP' {
                DependsOn         = '[xFirewall]SQL Server TCP - ' + $Instance
                SQLServer         = $Node.NodeName
                SQLInstanceName   = $ConfigurationData.NonNodeData.SQL.InstanceName + ',' + $ConfigurationData.NonNodeData.SQL.SQLEnginePort
                OptionName        = 'Agent XPs'
                OptionValue       = 1
                RestartService    = $false
        }

        xSQLServerConfiguration 'SQLConfigRemoteAdmin' {
                DependsOn         = '[xFirewall]SQL Server TCP - ' + $Instance
                SQLServer         = $Node.NodeName
                SQLInstanceName   = $ConfigurationData.NonNodeData.SQL.InstanceName + ',' + $ConfigurationData.NonNodeData.SQL.SQLEnginePort
                OptionName        = 'remote admin connections'
                OptionValue       = 1
                RestartService    = $false
        }

        xSQLServerConfiguration 'SQLConfigBackUpCompression' {
                DependsOn         = '[xFirewall]SQL Server TCP - ' + $Instance
                SQLServer         = $Node.NodeName
                SQLInstanceName   = $ConfigurationData.NonNodeData.SQL.InstanceName + ',' + $ConfigurationData.NonNodeData.SQL.SQLEnginePort
                OptionName        = 'backup compression default'
                OptionValue       = 1
                RestartService    = $false
        }

        xSQLServerConfiguration 'DisableRemoteAccess' {
                DependsOn         = '[xFirewall]SQL Server TCP - ' + $Instance
                SQLServer         = $Node.NodeName
                SQLInstanceName   = $ConfigurationData.NonNodeData.SQL.InstanceName + ',' + $ConfigurationData.NonNodeData.SQL.SQLEnginePort
                OptionName        = 'remote access'
                OptionValue       = 0
                RestartService    = $false
        }

#$Instance = $ConfigurationData.NonNodeData.SQL.InstanceName
        xFirewall "SQL Remote Management Firewall Rules - $Instance" {
                 Name                 = $ConfigurationData.NonNodeData.SQL.SQLFirewallName + $Instance
                 Action               = $ConfigurationData.NonNodeData.SQL.SQLFireWallAction
                 Description          = $ConfigurationData.NonNodeData.SQL.SQLFirewallDescrip
                 Direction            = 'Inbound'
                 #Program              = "C:\Program Files\Microsoft SQL Server\MSSQL13.$Instance\MSSQL\binn\sqlservr.exe"
                 Program              = $Program
                 #Program              = Join-Path -Path $InstanceDirectory -ChildPath "MSSQL13.$InstanceName\MSSQL\Binn\sqlservr.exe"
                 Profile              = 'Any'
                 #RemoteAddress        = $ConfigurationData.NonNodeData.SQL.SQLManagementSubnets
          }
  
          xFirewall 'Firewall RDP Rule' {
              Name          = 'Allow RDP Access'
              Action        = 'Allow'
              Description   = 'Allow RDP Access - Use PowerShell for System Management'
              Direction     = 'Inbound'
              Profile       = 'Any'
              LocalPort     = '3389'
              Protocol      = 'TCP'
                }

        #Execute TSQL Scripts by loop through SQLScripts folder 
        #TO DO: Replace TSQL Scripts with PowerShell when possible 
        
        $SQLScriptsFolder = $ConfigurationData.NonNodeData.SQL.SQLScriptsFolderDestination
        $SQLScripts = dir $SQLScriptsFolder -Filter *Set.sql   | where  {$_.Name -ine 'HADR_SQLScript_Set.sql'}   #HADR_SQLScript_Set will be executed separately below if EnableAAG is turned on
        foreach($SQLScript in $SQLScripts ) {
                #$SQLScript = $SQLScript -replace "_Get", ""   
       
               $SetFilePath          = Join-Path -Path $SQLScriptsFolder -ChildPath  $SQLScript
               $TestFilePath         = Join-Path -Path $SQLScriptsFolder -ChildPath  ($SQLScript -replace "Set", "Test")
               $GetFilePath          = Join-Path -Path $SQLScriptsFolder -ChildPath  ($SQLScript-replace "Set", "Get")
        
               xSQLServerScript "RunSQLScript-$SQLScript-AsUSER" {
                     DependsOn            = '[xFirewall]SQL Server TCP - ' + $Instance
                     ServerInstance       = $Node.NodeName + ',' + $ConfigurationData.NonNodeData.SQL.SQLEnginePort
                     SetFilePath          = $SetFilePath
                     TestFilePath         = $TestFilePath 
                     GetFilePath          = $GetFilePath
                     PsDscRunAsCredential = $LocalInstallAccount
                     #Variable             = @("FilePath=C:\temp\log\AuditFiles")
                }  
           }

#endregion *** SQL Server Install ***

#region *** SSMS Install ***
      
        #Install SSMS 17.x
    if ($ConfigurationData.NonNodeData.SSMS.InstallStandAloneSSMS -eq 'Yes') {
        
        Package InstallSSMS
            {
                DependsOn = '[xSQLServerSetup]SetupSQL'
                Ensure = $ConfigurationData.NonNodeData.SSMS.Ensure
                Name = $ConfigurationData.NonNodeData.SSMS.Name
                Path = $ConfigurationData.NonNodeData.SSMS.Path
                Arguments = $ConfigurationData.NonNodeData.SSMS.Arguments
                ProductId = $ConfigurationData.NonNodeData.SSMS.ProductId
               # PsDscRunAsCredential = $ConfigurationData.NonNodeData.Accounts.Setup
       
                #GUID Microsoft SQL Server Management Studio - 17.3 {422d7f9a-52c7-4ac7-82a9-2c2d77d67254}   
                #GUID for Microsoft SQL Server Management Studio - 17.4    {ac84c935-8f13-4f73-b541-7b09a11bdea8}    
 
            }
    }

# Disable SQL Browser
            Service 'Disable SQL Browser' {
                #DependsOn            = '[xSQLServerSetup]SetupSQL'
                Name        = 'SQLBrowser'
                StartupType = 'Disabled'
                State       = 'Stopped'
            }

# define script
            Script Disable-SQLandSSMSErrorReporting
            {
                SetScript = {
        
                #region ** DISABLE SQL TELEMETRY/ERROR REPORTING                     
                    ##################################################
                    # Disable CEIP services  #
                    ##################################################
                    #Check Status of Telemetry services before disabling them
                    Get-Service | Where-Object  name -Like "*TELEMETRY*" | select -property name,starttype,status

#Disable TELEMETRY Service for SQL, SSIS, SSAS

                    Get-Service | Where-Object  name -Like "SQLTELEMETRY*" | Set-Service -startmode disabled
                    Get-Service | Where-Object  name -Like "SSASTELEMETRY*" | Set-Service -startmode disabled
                    Get-Service | Where-Object  name -Like "SSISTELEMETRY*" | Set-Service -startmode disabled

                    Get-Service | Where-Object  name -Like "SQLTELEMETRY*" | Stop-Service
                    Get-Service | Where-Object  name -Like "SSASTELEMETRY*" | Stop-Service
                    Get-Service | Where-Object  name -Like "SSISTELEMETRY*" | Stop-Service

#Verify Status of Telemetry Services after they are disabled
                    Get-Service | ? name -Like "*TELEMETRY*" | select -property name,starttype,status

##################################################
                    #  Deactivate CEIP registry keys #
                    ##################################################
                    # Set all CustomerFeedback & EnableErrorReporting in the key directory HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server to 0
                    # Set HKEY_LOCAL_MACHINE\Software\Microsoft\Microsoft SQL Server\***\CustomerFeedback=0
                    # Set HKEY_LOCAL_MACHINE\Software\Microsoft\Microsoft SQL Server\***\EnableErrorReporting=0
                    # *** --> Version of SQL Server (100,110,120,130,140,...)
                    # For the Engine
                    # Set HKEY_LOCAL_MACHINE\Software\Microsoft\Microsoft SQL Server\MSSQL**.<instance>\CPE\CustomerFeedback=0
                    # Set HKEY_LOCAL_MACHINE\Software\Microsoft\Microsoft SQL Server\MSSQL**.<instance>\CPE\EnableErrorReporting=0
                    # For SQL Server Analysis Server (SSAS)
                    # Set HKEY_LOCAL_MACHINE\Software\Microsoft\Microsoft SQL Server\MSAS**.<instance>\CPE\CustomerFeedback=0
                    # Set HKEY_LOCAL_MACHINE\Software\Microsoft\Microsoft SQL Server\MSAS**.<instance>\CPE\EnableErrorReporting=0
                    # For Server Reporting Server (SSRS)
                    # Set HKEY_LOCAL_MACHINE\Software\Microsoft\Microsoft SQL Server\MSRS**.<instance>\CPE\CustomerFeedback=0
                    # Set HKEY_LOCAL_MACHINE\Software\Microsoft\Microsoft SQL Server\MSRS**.<instance>\CPE\EnableErrorReporting=0
                    # ** --> Version of SQL Server (10,11,12,13,14,...)
                    ##################################################
                    $Key = 'HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server'
                    $FoundKeys = Get-ChildItem $Key -Recurse | Where-Object -Property Property -eq 'EnableErrorReporting'
                    foreach ($Sqlfoundkey in $FoundKeys)
                    {
                    $SqlFoundkey | Set-ItemProperty -Name EnableErrorReporting -Value 0
                    $SqlFoundkey | Set-ItemProperty -Name CustomerFeedback -Value 0
                    }
                    ##################################################
                    # Set HKEY_LOCAL_MACHINE\Software\Wow6432Node\Microsoft\Microsoft SQL Server\***\CustomerFeedback=0
                    # Set HKEY_LOCAL_MACHINE\Software\Wow6432Node\Microsoft\Microsoft SQL Server\***\EnableErrorReporting=0
                    # *** --> Version of SQL Server(100,110,120,130,140,...)
                    ##################################################
                    $WowKey = "HKLM:\SOFTWARE\Wow6432Node\Microsoft\Microsoft SQL Server"
                    $FoundWowKeys = Get-ChildItem $WowKey | Where-Object -Property Property -eq 'EnableErrorReporting'
                    foreach ($SqlFoundWowKey in $FoundWowKeys)
                    {
                    $SqlFoundWowKey | Set-ItemProperty -Name EnableErrorReporting -Value 0
                    $SqlFoundWowKey | Set-ItemProperty -Name CustomerFeedback -Value 0
                    } 

##DISABLE SSMS TELEMETRY
                    ##################################################
                    # Set HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Microsoft SQL Server\***\Tools\Setup\UserFeedbackOptIn=0
                    # *** --> Version of SQL Server(100,110,120,130,140,...)
                    ##################################################

                    $SSMSKey = 'HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server'
                    $SSMSFoundKeys = Get-ChildItem $SSMSKey -Recurse | Where-Object -Property Property -eq 'UserFeedbackOptIn'
                    foreach ($SSMSTelemetryFoundkey in $SSMSFoundKeys)
                    {
                    $SSMSTelemetryFoundkey | Set-ItemProperty -Name UserFeedbackOptIn -Value 0
                    }
                #endregion **

}

                GetScript = {
                    # not really used
                    $Result = {}

                    # reuturn result
                    return $Result
                }

                TestScript = {

                    return $false
                }
                
                DependsOn = '[xSQLServerSetup]SetupSQL'
            }
            
        # check to see if there are any trace flags that need to be set
        if($ConfigurationData.NonNodeData.SQL.TraceFlags)
        {
            # set instance name
            $InstanceName = $ConfigurationData.NonNodeData.SQL.InstanceName

            # loop through the traceflags
            ForEach($TraceFlag in $ConfigurationData.NonNodeData.SQL.TraceFlags)
            {
                # define variables
                $TraceFlagValue = $TraceFlag.Value

                # check whether it shoudl be there or not
                switch($TraceFlag.Ensure.ToLower())
                {
                    "present"
                    {
                    
                        Script "Add-TraceFlag$($TraceFlag.Value)"
                        {
                            SetScript = {
                                # define registry location
                                $RegistryNode = "HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server"

                                # get registry info
                                $NodeProperties = Get-ItemProperty -Path "$RegistryNode\Instance Names\SQL"

                                # get instance info
                                $InstanceNode = $NodeProperties.PSObject.Properties | Where-Object {$_.Name -eq $using:InstanceName}

                                # get the parameters
                                $Parameters = Get-ItemProperty "$RegistryNode\$($InstanceNode.Value)\MSSQLServer\Parameters"

                                # write activity
                                Write-Verbose "Adding trace flag $using:TraceFlagValue"

                                # create new registry value
                                $RegProperty = "SQLArg" + ($Parameters.PSObject.Properties | Where-Object {$_.Name -like "SQLArg*"}).Count

                                # add to registry
                                Set-ItemProperty -Path "$RegistryNode\$($InstanceNode.Value)\MSSQLServer\Parameters" -Name $RegProperty -Value $using:TraceFlagValue

                                # display warning
                                Write-Warning "Trace flags have been altered, change will not take effect until the service has been restarted."
                            }

                            GetScript = {
                                # not really used
                                $Result = {}

                                # reuturn result
                                return $Result
                            }

                            TestScript = {
                                # define registry location
                                $RegistryNode = "HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server"

                                # get registry info
                                $NodeProperties = Get-ItemProperty -Path "$RegistryNode\Instance Names\SQL"

                                # get instance info
                                $InstanceNode = $NodeProperties.PSObject.Properties | Where-Object {$_.Name -eq $using:InstanceName}

                                # get the parameters
                                $Parameters = Get-ItemProperty "$RegistryNode\$($InstanceNode.Value)\MSSQLServer\Parameters"

                                # get existing trace flags
                                $ExistingFlags = $Parameters.PSObject.Properties | Where-Object {$_.Name -like "SQLArg*" -and $_.Value -like "-T*"} | Select -Property Value | ForEach-Object {$_.Value.Trim()}

                                # check to see if trace flag exits
                                if($ExistingFlags -contains $using:TraceFlagValue)
                                {
                                    # display message
                                    Write-Verbose "Trace flag $using:TraceFlagValue is present"
                                    
                                    # script does not need to run
                                    return $true
                                }
                                else
                                {
                                    # script needs to run
                                    return $false
                                }
                            }

                            #DependsOn = '[xSQLServerSetup]SetupSQL'
                        }
                    }
                    "absent"
                    {
                        Script "Remove-TraceFlag$($TraceFlag.Value)"
                        {
                            SetScript = {
                                # define registry location
                                $RegistryNode = "HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server"

                                # get registry info
                                $NodeProperties = Get-ItemProperty -Path "$RegistryNode\Instance Names\SQL"

                                # get instance info
                                $InstanceNode = $NodeProperties.PSObject.Properties | Where-Object {$_.Name -eq $using:InstanceName}

                                # get the parameters
                                $Parameters = Get-ItemProperty "$RegistryNode\$($InstanceNode.Value)\MSSQLServer\Parameters"

                                # get specific property to remove
                                $PropertyToRemove = $Parameters.PSObject.Properties | Where-Object {$_.Value -eq $using:TraceFlagValue}

                                # write activity
                                Write-Verbose "Removing trace flag $using:TraceFlagValue"

                                # create new registry value
                                $RegProperty = "SQLArg" + ($Parameters.PSObject.Properties | Where-Object {$_.Name -like "SQLArg*"}).Count

                                # Remove to registry
                                Remove-ItemProperty -Path "$RegistryNode\$($InstanceNode.Value)\MSSQLServer\Parameters" -Name $PropertyToRemove.Name 

                                # display warning
                                Write-Warning "Trace flags have been altered, change will not take effect until the service has been restarted."
                            }

                            GetScript = {
                                # not really used
                                $Result = {}

                                # reuturn result
                                return $Result
                            }

                            TestScript = {
                                # define registry location
                                $RegistryNode = "HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server"

                                # get registry info
                                $NodeProperties = Get-ItemProperty -Path "$RegistryNode\Instance Names\SQL"

                                # get instance info
                                $InstanceNode = $NodeProperties.PSObject.Properties | Where-Object {$_.Name -eq $using:InstanceName}

                                # get the parameters
                                $Parameters = Get-ItemProperty "$RegistryNode\$($InstanceNode.Value)\MSSQLServer\Parameters"

                                # get existing trace flags
                                $ExistingFlags = $Parameters.PSObject.Properties | Where-Object {$_.Name -like "SQLArg*" -and $_.Value -like "-T*"} | Select -Property Value | ForEach-Object {$_.Value.Trim()}

                                # check to see if trace flag exits
                                if($ExistingFlags -contains $using:TraceFlagValue)
                                {
                                    # display message
                                    Write-Verbose "Trace flag $using:TraceFlagValue is present"
                                    
                                    # script does not need to run
                                    return $false
                                }
                                else
                                {
                                    # script needs to run
                                    return $true
                                }
                            }

                            #DependsOn = '[xSQLServerSetup]SetupSQL'
                        }
                    }
                }
            }
        }

#endregion *** SSMS Install ***
    
# Always-On Availability Group configuration is handled separately by ConfigureAG.ps1, not by this script.

} #node $AllNodes.NodeName

} #Configuration 'InstallSQLandConfigureAvailabilityGroup'

InstallSQLandConfigureAvailabilityGroup -ConfigurationData $envData -OutputPath $mofLocation 

if($Deploy)
    {
        Write-Host "Start Time: $(Get-Date)"

        # Capture DSC/LCM errors instead of letting them print as raw PowerShell error
        # records (the "+ CategoryInfo" / "+ FullyQualifiedErrorId" noise) -- Verbose LCM
        # progress is untouched, only the ugly per-resource error display is replaced below.
        $dscErrors = @()
        Set-DscLocalConfigurationManager -Path $mofLocation -verbose -ErrorVariable +dscErrors -ErrorAction SilentlyContinue

        Start-DscConfiguration -Path $mofLocation -wait -verbose -force -ErrorVariable +dscErrors -ErrorAction SilentlyContinue

        Write-Host 'Restarting remote Computer(s)...'

        $restartErrors = @()
        Restart-Computer -ComputerName ($envData.AllNodes.NodeName | where-object {$_ -ne '*'}) -wait -for PowerShell -Force -ErrorVariable +restartErrors -ErrorAction SilentlyContinue

        foreach ( $restartErr in $restartErrors )
        {
            if ( $restartErr.FullyQualifiedErrorId -match 'CannotWaitLocalComputer' )
            {
                # Expected/benign: happens when the machine running this script is also
                # one of the target SQL nodes -- Restart-Computer can't "wait" on its own
                # host, but it still restarts it fine and waits normally on the other nodes.
                Write-Host "  [INFO] Local computer restarted (can't be waited on by its own script; this is normal)." -ForegroundColor Cyan
            }
            else
            {
                $dscErrors += $restartErr
            }
        }

        Start-DscConfiguration -ComputerName ($envData.AllNodes.NodeName | where-object {$_ -ne '*'}) -UseExisting -Wait -Verbose -Force -ErrorVariable +dscErrors -ErrorAction SilentlyContinue

        Write-host "Cleaning up MOF files from this machine since they may contain credential info" -ForegroundColor Green
        If(Test-Path $mofLocation){Remove-Item $mofLocation -Recurse -Force}

        if ( $dscErrors.Count -gt 0 )
        {
            Write-Host ""
            Write-Host "DSC reported $($dscErrors.Count) resource issue(s) during deployment:" -ForegroundColor Yellow
            foreach ( $dscErr in $dscErrors )
            {
                $targetComputer = $dscErr.OriginInfo.PSComputerName
                if ( -not $targetComputer ) { $targetComputer = $dscErr.PSComputerName }
                $cleanMessage = ( $dscErr.Exception.Message -replace '[\r\n]+', ' ' ).Trim()
                Write-Host "  [WARN] $($targetComputer): $cleanMessage" -ForegroundColor Yellow
                if ( Test-Path Variable:Global:SQLInstallWarningCount ) { $global:SQLInstallWarningCount++ }
            }
            Write-Host ""
        }

        Write-host " "
        Write-host "DONE: Please confirm if SQL is properly installed and Configured." -ForegroundColor Green
        Write-host " "

        Write-Host "End Time: $(Get-Date)"
    }
# SIG # Begin signature block
# MIIXtQYJKoZIhvcNAQcCoIIXpjCCF6ICAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCCYvBZThRjaZKzT
# c0v312cmrWmg46kMQ/i1k92/iMYpIKCCFJQwggo1MIIIHaADAgECAgRRsGn6MA0G
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
# CQQxIgQgS6b9Oh4KmHuZA5mTdEfiziDuIjHnRMe39D67NbscyygwDQYJKoZIhvcN
# AQEBBQAEggEAN0iZE96Sfo6cXKoN4t3fF3kio3Ty8cX/TmQgQPyR7EAlJ4m+hucQ
# aW34uxy7+Wc4tBVZmkLT6v6tN2FXpiJdoQDFqPuyX7sVoOLZrxiCyMlU+B+U6y+n
# Q8W5etYqlTQ4YCsZz+Vy0KER06KM+BhV5PYrGBegSLi+Vczq7d7/hPTvur3tNB24
# Fuqea5WFRrj5GTdgm3RqfLgFjZD71w/FU9GPASW4txD/CcFf522L18xrESAsJrHA
# oPaa/lpVjZyct+oZi+9+1hq027a6SZGQnivvb0lRRAuIqwvp+iw/qFhqLBskaklX
# DQ/aiHkd4DQm5QEIjMQ5KjFpRZBEJzc8ZQ==
# SIG # End signature block
