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
            NodeName = 'DDCWODWCDBS04'
            <#  --- commenting out a block ------
        },
      
        @{
            NodeName = 'DDCWODWCDBS02' 

    
  
         },
        
         @{
            NodeName = 'DDCWOZWCDBS4E'
            
        },

         @{
             NodeName = 'DDCWOZWCDBS4H' 
               
       },

         @{
             NodeName = 'DDCWOZWCDBS4B' 
             
  --- commenting out a block --- #>
  }
        
    )

    NonNodeData = @{

        Data = @{
            DSCResourceLocation              = "\\$env:COMPUTERNAME\SQLInstall\SQLDSC\modules"      # Create a file share named SQLInstall that points to C:\SQLInstall on the Management server
            CopyDSCResources_to_AdminMachine = 'NO'                                                # Set it to 'NO' if DSC resources are already copied to install machine, otherwise 'YES'
            Copy_all_Files_to_TargetNodes    = 'NO'                                                # Set it to 'NO' if DSC resources, SQL Server binary, patches, SSMS etc are ALREADY copied to target servers where SQL will be installed
        }


        SQL  = @{
            SQLVersion            = 'SQL2017' #4/23/2019 - does nothing...                         # C:\SQLInstall\SQLDSC\configs\Install_and_Configure_SQLServer_Multi_Node.ps1
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
            
            
            #4/23/2019 changed to 2017
            <# xSQLServerFirewall #>
            SQLFirewallEnsure     = 'Present'                                               # Ensures that SQL firewall rules are Present or Absent on the machine. 
            SQLFirewallFeatures   = 'SQLENGINE'                                             # SQL features to enable firewall rules for.
            SQLFirewallSourcePath = "\\$env:COMPUTERNAME\SQLInstall\SQLDSC\bits\SQL2017"    # UNC path to the root of the source files for installation


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

# SIG # Begin signature block
# MIIXtQYJKoZIhvcNAQcCoIIXpjCCF6ICAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCAnu6SgTq+cKHFA
# nAiUPL3mseylezqhiSAXSPR2ukHUEqCCFJQwggo1MIIIHaADAgECAgRRsGn6MA0G
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
# CQQxIgQgB+t/jBhJPDzah2mjw8ckzchlsYhZe7Jpc6mgddh6xSAwDQYJKoZIhvcN
# AQEBBQAEggEAs08rgjrjYVprtKS55CDE8Dh7YxgkhgKrHJi4Cow8sjmqQlg61gQ2
# r1qyTL1rUiwWIjef/EQxKumUEA0xpVT3xRr3fDlFyMdZgjVP4ReVbc734o0KsGep
# kkKdF0fZdnH+3Qv2NqdIDoe761i/2UlWIs9K2Pd0suVoLEl0dhCrlghkKZZ/CbSd
# yvuFK+JkLnoMKpInfcWRgUrzRIu9RHczQPv15FiOP7sKaizM6xBnT9Kqn7znRn8u
# uNpDHvD3l/64JGl5U8FqOseJ3biXhSwCEs1gzC3Fm0uETzMIwMG3O5Q3CBlzawgH
# lO1PEf5eO5+UwIh0+XnO1/7r141uhfdcSg==
# SIG # End signature block
