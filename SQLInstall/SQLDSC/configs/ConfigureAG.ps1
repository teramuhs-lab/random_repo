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

Configuration 'ConfigureAvailabilityGroup' {

    Import-DscResource -ModuleName 'PSDesiredStateConfiguration'
    Import-DscResource -ModuleName 'xSQLServer'  -ModuleVersion '9.0.0.0'
    Import-DscResource -ModuleName 'xNetworking' -ModuleVersion '5.3.0.0'

    #Import-DscResource -ModuleName 'SecurityPolicyDsc' 

    #Import-DscResource -ModuleName 'AccessControlDSC'



    Node $AllNodes.NodeName
    {
        



#region *** Configure AlwaysON ***

          #Runs only if Environment Varable for SQLAAGBuild is set to 'Yes'
          if ($ConfigurationData.NonNodeData.HADR.SQLAAGBuild -eq 'Yes') {

                $Instance = $ConfigurationData.NonNodeData.SQL.InstanceName

                ## Determine the Service SID if Domain account is not used as service.
                    #If ($ConfigurationData.AllNodes.EngineServiceAccountName -eq $null ) {
                    If ($SQLServiceAccount -eq $null )  {    
                        ## Determine the Service SID to use 
                        if ($Instance -ine 'MSSQLServer') {
                            $EngineServiceAccountName = ('NT SERVICE\MSSQL${0}' -f $Instance)
                            $AgentServiceAccount = ('NT SERVICE\SQLAGENT${0}' -f $Instance)
                        }
                        else {
                            $EngineServiceAccountName = 'NT SERVICE\MSSQLSERVER'
                            $AgentServiceAccount = 'NT SERVICE\SQLSERVERAGENT'
                        }
                    }
                    else
                        {
                
                        $EngineServiceAccountName = $SQLServiceAccount.username
                        $SQLAgentServiceAccount = $SQLAgentServiceAccount.username
                
                        }
            



                #Enable AlwaysON High Availability at the SQL Service(Server needs to be part of a WFSC )
                xSQLServerAlwaysOnService 'EnableAlwaysOn'{
                            #DependsOn            = '[xFirewall]SQL Server TCP - ' + $Instance
                            Ensure               = $ConfigurationData.NonNodeData.HADR.SQLAAGEnsure
                            SQLServer            = $Node.NodeName
                            SQLInstanceName      = $ConfigurationData.NonNodeData.SQL.InstanceName # + ',' + $ConfigurationData.NonNodeData.SQL.SQLEnginePort
                            RestartTimeout       = $ConfigurationData.NonNodeData.HADR.SQLAAGTimeOut
                            PsDscRunAsCredential = $InstallAccount
                }
        
        
            
                xFirewall 'SQLAG Endpoint' {
                                Name          = 'Allow TCP Access SQL Server AG Endpoint'
                                Action        = 'Allow'
                                Description   = 'Allow TCP Access SQL Server AG Endpoint'
                                Direction     = 'Inbound'
                                Profile       = 'Any'
                                LocalPort     = $ConfigurationData.NonNodeData.HADR.SQLAAGPort
                                Protocol      = 'TCP'
                    }

                xFirewall 'SQLAG Listener' {
                                Name          = 'Allow TCP Access SQL Server AG Listener'
                                Action        = 'Allow'
                                Description   = 'Allow TCP Access SQL Server AG Listener'
                                Direction     = 'Inbound'
                                Profile       = 'Any'
                                LocalPort     = $ConfigurationData.NonNodeData.HADR.ListenerPort
                                Protocol      = 'TCP'
                    }       


                #Adding the required Cluster service account to SQL to allow the cluster to log into SQL
                xSQLServerLogin AddNTServiceClusSvc {
                                Ensure               = $ConfigurationData.NonNodeData.HADR.SQLAAGEnsure
                                Name                 = 'NT SERVICE\ClusSvc'
                                LoginType            = 'WindowsUser'
                                SQLServer            = $Node.NodeName
                                SQLInstanceName      = $ConfigurationData.NonNodeData.SQL.InstanceName
                                PsDscRunAsCredential = $InstallAccount
                                }
        
                #Grant the required permissions to the cluster service login
                xSQLServerPermission AddNTServiceClustSvcPermissions {
                                DependsOn            = '[xSQLServerLogin]AddNTServiceClusSvc'
                                Ensure               = $ConfigurationData.NonNodeData.HADR.SQLAAGEnsure
                                NodeName             = $Node.NodeName
                                InstanceName         = $ConfigurationData.NonNodeData.SQL.InstanceName #+ ',' + $ConfigurationData.NonNodeData.SQL.SQLEnginePort
                                Principal            = 'NT SERVICE\ClusSvc'
                                Permission           = 'AlterAnyAvailabilityGroup', 'ViewServerState'
                                PsDscRunAsCredential = $InstallAccount
                        }

                # Create a login for the SQL Server engine service account
                # TO DO: Handle $Node.EngineServiceAccountName;
                xSQLServerLogin AddEngineServiceAccount{ 
                            Ensure               = "Present"; 
                            #Name                 = 'CA\$SQLSvcAct';
                            #Name = $Node.EngineServiceAccountName;
                            Name = $EngineServiceAccountName;
                            LoginType            = "WindowsUser"; 
                            SQLServer            = $Node.NodeName; 
                            SQLInstanceName      = $ConfigurationData.NonNodeData.SQL.InstanceName #+ ',' + $ConfigurationData.NonNodeData.SQL.SQLEnginePort; 
                            PsDscRunAsCredential = $InstallAccount; 

                            #DependsOn            = "[xSqlServerSetup]installSqlServer";
                        }

                #Create a HADR / DatabaseMirroring endpoint
                xSQLServerEndpoint HADREndPoint {
                                EndpointName         = $ConfigurationData.NonNodeData.HADR.SQLAAGEndPoint
                                Ensure               = $ConfigurationData.NonNodeData.HADR.SQLAAGEnsure
                                Port                 = $ConfigurationData.NonNodeData.HADR.SQLAAGPort
                                SQLServer            = $Node.NodeName
                                SQLInstanceName      = $ConfigurationData.NonNodeData.SQL.InstanceName #+ ',' + $ConfigurationData.NonNodeData.SQL.SQLEnginePort
                                PsDscRunAsCredential = $InstallAccount
                                }

                # Grant the required permissions to the SQL Server engine login
                xSQLServerEndpointPermission EndPointPermission {   
                
                                Ensure               = 'Present'
                                NodeName             = $Node.NodeName
                                InstanceName         = $ConfigurationData.NonNodeData.SQL.InstanceName #+ ',' + $ConfigurationData.NonNodeData.SQL.SQLEnginePort
                                Permission           = "CONNECT"
                                #Principal = 'CA\$SQLSvcAct'
                                #Principal = $Node.EngineServiceAccountName;
                                Principal = $EngineServiceAccountName;
                                Name            = $ConfigurationData.NonNodeData.HADR.SQLAAGEndPoint
                                PsDscRunAsCredential = $InstallAccount
                                DependsOn = ('[xSQLServerEndpoint]HADREndPoint','[xSQLServerLogin]AddEngineServiceAccount')
                                }
 
        
     
              
                #Primary Node Configuration
                if ( $Node.Role -eq 'PrimaryReplica' ) {
                    xSQLServerAlwaysOnAvailabilityGroup AddAAG {
                                    DependsOn                     = '[xSQLServerAlwaysOnService]EnableAlwaysOn','[xSQLServerEndpoint]HADREndPoint','[xSQLServerPermission]AddNTServiceClustSvcPermissions'
                                    Ensure                        = $ConfigurationData.NonNodeData.HADR.SQLAAGEnsure
                                    Name                          = $ConfigurationData.NonNodeData.HADR.SQLAAGName
                                    SQLServer                     = $Node.NodeName
                                    SQLInstanceName               = $ConfigurationData.NonNodeData.SQL.InstanceName                                 
                                    AutomatedBackupPreference     = $ConfigurationData.NonNodeData.HADR.AutomatedBackupPreference
                                    AvailabilityMode              = $ConfigurationData.NonNodeData.HADR.AvailabilityMode
                                    BackupPriority                = $ConfigurationData.NonNodeData.HADR.BackupPriority
                                    ConnectionModeInPrimaryRole   = $ConfigurationData.NonNodeData.HADR.ConnectionModeInPrimaryRole
                                    ConnectionModeInSecondaryRole = $ConfigurationData.NonNodeData.HADR.ConnectionModeInSecondaryRole
                                    FailoverMode                  = $ConfigurationData.NonNodeData.HADR.FailoverMode
                                    HealthCheckTimeout            = $ConfigurationData.NonNodeData.HADR.HealthCheckTimeout
                                    PsDscRunAsCredential          = $InstallAccount
                                }  
                 }           

                xWaitForAvailabilityGroup AGWait{
                                Name                 = $ConfigurationData.NonNodeData.HADR.SQLAAGName
                                RetryIntervalSec     = $ConfigurationData.NonNodeData.HADR.AGRetryIntervalSec
                                RetryCount           = $ConfigurationData.NonNodeData.HADR.AGRetryCount
                                PsDscRunAsCredential = $InstallAccount
                        }

      
                #Secondary Nodes Configuration
                if ( $Node.Role -eq 'SecondaryReplica' ) {
        
                    xSQLServerAlwaysOnAvailabilityGroupReplica AddReplica { 
                                    DependsOn                       = '[xSQLServerAlwaysOnService]EnableAlwaysOn','[xWaitForAvailabilityGroup]AGWait'         
                                    Ensure                          = $ConfigurationData.NonNodeData.HADR.SQLAAGEnsure
                                    SQLServer                       = $Node.NodeName
                                    SQLInstanceName                 = $ConfigurationData.NonNodeData.SQL.InstanceName + ',' + $ConfigurationData.NonNodeData.SQL.SQLEnginePort
                                    Name                            = $Node.NodeName + '\' + $ConfigurationData.NonNodeData.SQL.InstanceName #+ ',' + $ConfigurationData.NonNodeData.SQL.SQLEnginePort
                                    AvailabilityGroupName           = $ConfigurationData.NonNodeData.HADR.SQLAAGName   
                                    PrimaryReplicaSQLServer         = ( $AllNodes | Where-Object { $_.Role -eq 'PrimaryReplica' } ).NodeName
                                    PrimaryReplicaSQLInstanceName   = $ConfigurationData.NonNodeData.SQL.InstanceName + ',' + $ConfigurationData.NonNodeData.SQL.SQLEnginePort
                                    AvailabilityMode                = $ConfigurationData.NonNodeData.HADR.AvailabilityMode
                                    BackupPriority                  = $ConfigurationData.NonNodeData.HADR.BackupPriority
                                    ConnectionModeInPrimaryRole     = $ConfigurationData.NonNodeData.HADR.ConnectionModeInPrimaryRole
                                    ConnectionModeInSecondaryRole   = $ConfigurationData.NonNodeData.HADR.ConnectionModeInSecondaryRole
                                    FailoverMode                    = $ConfigurationData.NonNodeData.HADR.FailoverMode
                                    PsDscRunAsCredential            = $InstallAccount
                                    }                        
                }

                #DR Nodes Configuration
                if ( $Node.Role -eq 'DRReplica' ) {

                    xSQLServerAlwaysOnAvailabilityGroupReplica AddDRReplica {        
                                    DependsOn                       = '[xSQLServerAlwaysOnService]EnableAlwaysOn','[xWaitForAvailabilityGroup]AGWait'          
                                    Ensure                          = $ConfigurationData.NonNodeData.HADR.SQLAAGEnsure
                                    SQLServer                       = $Node.NodeName
                                    SQLInstanceName                 = $ConfigurationData.NonNodeData.SQL.InstanceName + ',' + $ConfigurationData.NonNodeData.SQL.SQLEnginePort
                                    Name                            = $Node.NodeName + '\' + $ConfigurationData.NonNodeData.SQL.InstanceName
                                    AvailabilityGroupName           = $ConfigurationData.NonNodeData.HADR.SQLAAGName 
                                    PrimaryReplicaSQLServer         = ( $AllNodes | Where-Object { $_.Role -eq 'PrimaryReplica' } ).NodeName
                                    PrimaryReplicaSQLInstanceName   = $ConfigurationData.NonNodeData.SQL.InstanceName + ',' + $ConfigurationData.NonNodeData.SQL.SQLEnginePort
                                    AvailabilityMode                = $ConfigurationData.NonNodeData.HADR.DRAvailabilityMode
                                    BackupPriority                  = $ConfigurationData.NonNodeData.HADR.DRBackupPriority
                                    ConnectionModeInPrimaryRole     = $ConfigurationData.NonNodeData.HADR.ConnectionModeInPrimaryRole
                                    ConnectionModeInSecondaryRole   = $ConfigurationData.NonNodeData.HADR.ConnectionModeInSecondaryRole
                                    FailoverMode                    = $ConfigurationData.NonNodeData.HADR.DRFailoverMode
                                    PsDscRunAsCredential            = $InstallAccount                 
                                    }
                }

        
        #Add listener,  Configure test database and add to AG
        
                #Configure HADR Listener
                if ( $Node.Role -eq 'PrimaryReplica' ) {

                    #Configure Listener
                    xSQLServerAvailabilityGroupListener AddAGListener {
                                    DependsOn               = '[xSQLServerAlwaysOnService]EnableAlwaysOn','[xWaitForAvailabilityGroup]AGWait'
                                    Ensure                  = $ConfigurationData.NonNodeData.HADR.SQLAAGEnsure
                                    NodeName                = $Node.NodeName
                                    InstanceName            = $ConfigurationData.NonNodeData.SQL.InstanceName + ',' + $ConfigurationData.NonNodeData.SQL.SQLEnginePort
                                    AvailabilityGroup       = $ConfigurationData.NonNodeData.HADR.SQLAAGName
                                    Name                    = $ConfigurationData.NonNodeData.HADR.SQLListenerName 
                                    IpAddress               = $ConfigurationData.NonNodeData.HADR.ListenerIPAddress
                                    Port                    = $ConfigurationData.NonNodeData.HADR.ListenerPort
                                }
                
                    #create testDB and Add to Replica
                    if ( $ConfigurationData.NonNodeData.HADR.CreateTestDB -eq 'yes' ) {
            
                        xSQLServerDatabase 'Create AAGDatabase'{
                                        Ensure              = 'Present'
                                        SQLServer           = $Node.NodeName
                                        SQLInstanceName     = $ConfigurationData.NonNodeData.SQL.InstanceName
                                        Name                = $ConfigurationData.NonNodeData.HADR.DatabaseName
                            }
                        xSQLServerScript 'RunHADR_BackupScript' {
                                        DependsOn               = '[xSQLServerDatabase]Create AAGDatabase'
                                        ServerInstance          = $Node.NodeName + ',' + $ConfigurationData.NonNodeData.SQL.SQLEnginePort
                                        #SetFilePath             = $ConfigurationData.NonNodeData.HADR.HADRSetFilePath
                                        #TestFilePath            = $ConfigurationData.NonNodeData.HADR.HADRTestFilePath
                                        #GetFilePath             = $ConfigurationData.NonNodeData.HADR.HADRGetFilePath
                                        SetFilePath             = "C:\SQLInstall\SQLDSC\SQLScripts\HADR_SQLScript_Set.sql"
                                        TestFilePath            = "C:\SQLInstall\SQLDSC\SQLScripts\HADR_SQLScript_Test.sql"
                                        GetFilePath             = "C:\SQLInstall\SQLDSC\SQLScripts\HADR_SQLScript_Get.sql"
                                        Variable                = $ConfigurationData.NonNodeData.HADR.TestDBVars
                                        PsDscRunAsCredential    = $InstallAccount
                                            }
                        xSQLServerAlwaysOnAvailabilityGroupDatabaseMembership 'HADR_AddTestDB' {
                                        #DependsOn               = '[xWaitForAvailabilityGroup]AGWait','[xSQLServerScript]RunHADR_BackupScript','[xSQLServerAvailabilityGroupListener]AddAGListener'
                                        DependsOn               = '[xWaitForAvailabilityGroup]AGWait','[xSQLServerScript]RunHADR_BackupScript'#,'[xSQLServerAvailabilityGroupListener]AddAGListener'
                                        Ensure                  = 'Present'
                                        DatabaseName            = $ConfigurationData.NonNodeData.HADR.DatabaseName
                                        SQLServer               = $Node.NodeName
                                        SQLInstanceName         = $ConfigurationData.NonNodeData.SQL.InstanceName
                                        AvailabilityGroupName   = $ConfigurationData.NonNodeData.HADR.SQLAAGName
                                        BackupPath              = $ConfigurationData.NonNodeData.HADR.BackupPath
                                        #Variable                = $SQLBackupDir
                                        PsDscRunAsCredential    = $InstallAccount
                                        }
                        } #CreateTestDB
            }#listener
                
          } #SQLAAGBuild   

#endregion *** Configure AlwaysON *** 
    
    
    
    
    } #node $AllNodes.NodeName
  

} #Configuration 'ConfigureAvailabilityGroup'



ConfigureAvailabilityGroup -ConfigurationData $envData -OutputPath $mofLocation 
       

if($Deploy) 
    {
        Write-Host "Start Time: $(Get-Date)"

        Set-DscLocalConfigurationManager -Path $mofLocation -verbose

        Start-DscConfiguration -Path $mofLocation -wait  -verbose -force

        Write-Host 'Restarting remote Computer(s)...'

        #Restart-Computer -ComputerName ($envData.AllNodes.NodeName | where-object {$_ -ne '*'}) -wait -for PowerShell -Force

        #Start-DscConfiguration -ComputerName ($envData.AllNodes.NodeName | where-object {$_ -ne '*'}) -UseExisting -Wait -Verbose -Force

        Write-host "Cleaning up MOF files from this machine since they may contain credential info" -ForegroundColor Green
        If(Test-Path $mofLocation){Remove-Item $mofLocation -Recurse -Force} 

        Write-host " "
        Write-host "DONE: Please confirm if SQL is properly installed and Configured." -ForegroundColor Green
        Write-host " "

        Write-Host "End Time: $(Get-Date)"
    }
# SIG # Begin signature block
# MIIXtQYJKoZIhvcNAQcCoIIXpjCCF6ICAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCByPH0Kj+9Lim+n
# TVEknzhwipkzjSJcNa6buJ31xF0n+6CCFJQwggo1MIIIHaADAgECAgRRsGn6MA0G
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
# CQQxIgQgoXAgwXV+V7ZMr2L05sLHrsrfTO5kTOJth51MsaF0uZ4wDQYJKoZIhvcN
# AQEBBQAEggEAoozzX1Yo9yFo3wM/bhd5+2PAZZJwdQ3t6VmPMx/pjzuR/BqoIMUB
# aVBz+YCPHL1B+/sXtDxFl0/w1eihDqhon+DmnKNWfsIRK09YCIWtj45sJzXKBqUN
# dfdfY2nqolYYVC7VRjASQU37dlyFIkEjk8aTgIEVK4Q0suThBRqjASsOz7zcGdKm
# +fHW+Zm78L72YL8NGMIjZI1NFRV1b4MHp37wTFOfmB9AdgZf5n/iCIiJq7MhIkO6
# qtQBgxArQhvSflGEBTem8hWjlysZ/LkAgTHKTCOaH4A535VLgoigPxx0pkyDmAWw
# AdG1qxH0h0yRno8AEY323jCcrWYsvEe3hg==
# SIG # End signature block
