#Requires -Version 5.1
<#
.SYNOPSIS
    Post-installation verification for the SQL Server Multi-Node install toolkit.

.DESCRIPTION
    Checks the ACTUAL state of a target node against the Desired State that
    Install_and_Configure_SQLServer_Multi_Node.ps1 (DSC) and the T-SQL scripts in
    SQLDSC\SQLScripts are supposed to produce, and prints a clean [OK]/[WARN]/[FAIL]
    report (plus a timestamped log file).

    This exists because several DSC resources and T-SQL scripts have been observed to
    silently NOT apply (e.g. TCP/IP disabled, firewall rule missing, remote access /
    backup compression left at defaults, SQLAdmins group empty). DSC's own "DONE"
    banner is not proof the desired state was reached -- this script actually verifies it.

    It reads the same environment .psd1 the installer uses, so "desired" values
    (instance name, port, version->build, service accounts, local-admin group list,
    trace flags) come from your real config, not hardcoded assumptions.

.PARAMETER EnvDataFilePath
    Path to the environment .psd1 used for the install
    (e.g. ...\SQLDSC\environments\InstallConfigure_SQLServer2025-CAPPT.psd1).

.PARAMETER ComputerName
    One or more target nodes to check. Defaults to the node list in the .psd1.
    Each node is checked over PowerShell remoting (WinRM); SQL checks run LOCALLY on
    the node (localhost,<port>) because the SQL TCP port is typically not reachable
    across the network (host firewall / GPO). If a listed node is the local machine it
    is checked directly without remoting.

.PARAMETER LogDirectory
    Where to write the transcript/report file. Defaults to the .psd1's ..\..\logs folder.

.EXAMPLE
    .\Test_SQLServer_PostInstall.ps1 -EnvDataFilePath 'C:\SQLInstall\SQLDSC\environments\InstallConfigure_SQLServer2025-CAPPT.psd1'

.NOTES
    Requires that the account running it is a SQL sysadmin on the target instance
    (needed to read sp_configure, xp_instance_regread, audit/mail metadata) and a
    local admin on the target node (needed to read services/firewall/local groups).
#>
param(
    [Parameter(Mandatory = $true)]
    [string] $EnvDataFilePath,

    [string[]] $ComputerName,

    [string] $LogDirectory
)

# ---------------------------------------------------------------------------
# Load environment config (same mechanism the installer uses: Invoke-Expression,
# NOT Import-PowerShellDataFile, so dynamic expressions like $env:COMPUTERNAME work)
# ---------------------------------------------------------------------------
if (-not (Test-Path $EnvDataFilePath)) {
    throw "Environment file not found: $EnvDataFilePath"
}
$envData     = Invoke-Expression (Get-Content -Path $EnvDataFilePath | Out-String)
$envDataFile = Get-Item $EnvDataFilePath

$sqlCfg      = $envData.NonNodeData.SQL
$Instance    = $sqlCfg.InstanceName
$Port        = [string]$sqlCfg.SQLEnginePort
$Version     = if ($sqlCfg.SQLVersion) { $sqlCfg.SQLVersion } else { 'SQL2017' }

# Same version->build mapping as the config script (drives the MSSQL<NN>.<instance> paths)
$buildMap = @{ 'SQL2012'='11'; 'SQL2014'='12'; 'SQL2016'='13'; 'SQL2017'='14'; 'SQL2025'='17' }
$Build    = $buildMap[$Version]

# Desired values pulled from the .psd1
$desired = @{
    Instance          = $Instance
    Port              = $Port
    Version           = $Version
    Build             = $Build
    LocalServerAdmins = @($sqlCfg.LocalServerAdmins)
    SvcAccount        = $envData.AllNodes | Where-Object { $_.NodeName -eq '*' } | ForEach-Object { $_.SQLServiceAccount }
    AgtAccount        = $envData.AllNodes | Where-Object { $_.NodeName -eq '*' } | ForEach-Object { $_.SQLAgentServiceAccount }
    LocalInstallAcct  = $sqlCfg.LocalInstallAccount
    TraceFlags        = @($sqlCfg.TraceFlags | ForEach-Object { ($_.Value -replace '^-T','') })
    InstallSSMS       = $envData.NonNodeData.SSMS.InstallStandAloneSSMS
    # Optional: when the config targets a specific SSMS generation (e.g. 22 via a VS
    # installer layout), an older SSMS being present is NOT the desired state.
    SsmsMinMajor      = $envData.NonNodeData.SSMS.MinimumMajorVersion
}

# Nodes to check
if (-not $ComputerName) {
    $ComputerName = $envData.AllNodes.NodeName | Where-Object { $_ -ne '*' }
}

# Log file
if (-not $LogDirectory) {
    $LogDirectory = Join-Path -Path $envDataFile.DirectoryName -ChildPath '..\..\logs'
}
if (-not (Test-Path $LogDirectory)) { New-Item -Path $LogDirectory -ItemType Directory -Force | Out-Null }
$LogDirectory = (Resolve-Path $LogDirectory).Path      # collapse any ..\.. so the printed path is readable
$stamp   = Get-Date -Format 'yyyyMMdd_HHmmss'
$logFile = Join-Path -Path $LogDirectory -ChildPath "PostInstallCheck_$($envDataFile.BaseName)_$stamp.log"

# ---------------------------------------------------------------------------
# The check scriptblock -- runs ON each target node (locally or via Invoke-Command).
# Returns an array of result objects: @{ Category; Name; Status; Detail } where
# Status is 'OK' | 'WARN' | 'FAIL' | 'INFO'.
# ---------------------------------------------------------------------------
$checkScript = {
    param($desired)

    $Instance = $desired.Instance
    $Port     = $desired.Port
    $Build    = $desired.Build
    $results  = New-Object System.Collections.Generic.List[object]

    function Add-Result($Category, $Name, $Status, $Detail) {
        $results.Add([pscustomobject]@{
            Category = $Category; Name = $Name; Status = $Status; Detail = $Detail
        })
    }

    # Safely turn a SQL column value into an int.
    #
    # Several checks below query things that legitimately do not exist yet on a
    # partially-configured node -- a missing registry value read via
    # xp_instance_regread, or a scalar subquery over a login that has not been
    # created. Those come back as [System.DBNull], and a plain [int] cast on DBNull
    # throws "Object cannot be cast from DBNull to other types", which would abort
    # the entire check run for that node. Returning $null instead lets each check
    # report "not set" and carry on.
    function Get-IntOrNull($value) {
        if ( $null -eq $value -or $value -is [System.DBNull] -or "$value" -eq '' ) { return $null }
        try   { return [int]$value }
        catch { return $null }
    }

    # --- SQL query helper (via .NET SqlClient, localhost + port, trust self-signed cert) ---
    $connStr = "Server=localhost,$Port;Database=master;Integrated Security=SSPI;Encrypt=True;TrustServerCertificate=True;Connect Timeout=15;Application Name=PostInstallCheck"
    $script:SqlOk = $false
    function Invoke-Sql($query) {
        $conn = New-Object System.Data.SqlClient.SqlConnection $connStr
        try {
            $conn.Open()
            $cmd = $conn.CreateCommand(); $cmd.CommandText = $query; $cmd.CommandTimeout = 30
            $da  = New-Object System.Data.SqlClient.SqlDataAdapter $cmd
            $dt  = New-Object System.Data.DataTable
            [void]$da.Fill($dt)
            return ,$dt
        } finally { $conn.Dispose() }
    }

    # ==================== 1. ENGINE / CONNECTIVITY ====================
    $svcName = "MSSQL`$$Instance"
    $agtName = "SQLAgent`$$Instance"
    $sqlSvc  = Get-Service -Name $svcName -ErrorAction SilentlyContinue
    if ($sqlSvc -and $sqlSvc.Status -eq 'Running') { Add-Result 'Engine' "SQL Server service ($svcName)" 'OK' 'Running' }
    elseif ($sqlSvc) { Add-Result 'Engine' "SQL Server service ($svcName)" 'FAIL' "State: $($sqlSvc.Status)" }
    else { Add-Result 'Engine' "SQL Server service ($svcName)" 'FAIL' 'Service not found (instance not installed?)' }

    $agtSvc = Get-Service -Name $agtName -ErrorAction SilentlyContinue
    if ($agtSvc -and $agtSvc.Status -eq 'Running') { Add-Result 'Engine' "SQL Agent service ($agtName)" 'OK' 'Running' }
    elseif ($agtSvc) { Add-Result 'Engine' "SQL Agent service ($agtName)" 'WARN' "State: $($agtSvc.Status)" }
    else { Add-Result 'Engine' "SQL Agent service ($agtName)" 'WARN' 'Service not found' }

    # TCP listening on the desired port
    $listen = Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue
    if ($listen) { Add-Result 'Network' "TCP port $Port listening" 'OK' "$($listen.Count) endpoint(s) listening" }
    else { Add-Result 'Network' "TCP port $Port listening" 'FAIL' 'Nothing listening -- TCP/IP protocol likely disabled' }

    # Registry: TCP/IP enabled + static port for this instance
    $tcpKey = "HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\MSSQL$Build.$Instance\MSSQLServer\SuperSocketNetLib\Tcp"
    $tcpAll = "$tcpKey\IPAll"
    if (Test-Path $tcpKey) {
        $enabled = (Get-ItemProperty $tcpKey -ErrorAction SilentlyContinue).Enabled
        $tcpPort = (Get-ItemProperty $tcpAll -ErrorAction SilentlyContinue).TcpPort
        if ($enabled -eq 1) { Add-Result 'Network' 'TCP/IP protocol enabled' 'OK' 'Enabled' }
        else { Add-Result 'Network' 'TCP/IP protocol enabled' 'FAIL' "Enabled=$enabled (expected 1)" }
        if ($tcpPort -eq $Port) { Add-Result 'Network' "Static TCP port = $Port" 'OK' "IPAll TcpPort=$tcpPort" }
        else { Add-Result 'Network' "Static TCP port = $Port" 'WARN' "IPAll TcpPort='$tcpPort' (expected $Port)" }
    } else {
        Add-Result 'Network' 'TCP/IP registry key' 'WARN' "Not found at MSSQL$Build.$Instance"
    }

    # ==================== 2. FIREWALL ====================
    $fw1443 = Get-NetFirewallRule -ErrorAction SilentlyContinue | ForEach-Object {
        $pf = $_ | Get-NetFirewallPortFilter -ErrorAction SilentlyContinue
        if ($pf.LocalPort -eq $Port) { $_ }
    }
    if ($fw1443) { Add-Result 'Firewall' "Inbound rule for port $Port" 'OK' (($fw1443.DisplayName) -join '; ') }
    else { Add-Result 'Firewall' "Inbound rule for port $Port" 'WARN' "No firewall rule opens TCP $Port (remote connections will fail)" }

    $rdp = Get-NetFirewallRule -DisplayName 'Allow RDP Access' -ErrorAction SilentlyContinue
    Add-Result 'Firewall' 'RDP rule (Allow RDP Access)' ($(if ($rdp) {'OK'} else {'WARN'})) ($(if ($rdp) {"Enabled=$($rdp.Enabled)"} else {'Not found'}))

    # ==================== 3. LOCAL GROUPS ====================
    foreach ($grp in 'SQLAdmins','SQLServices') {
        $members = Get-LocalGroupMember -Group $grp -ErrorAction SilentlyContinue
        if ($members) { Add-Result 'LocalGroups' "$grp populated" 'OK' (($members.Name) -join '; ') }
        elseif (Get-LocalGroup -Name $grp -ErrorAction SilentlyContinue) { Add-Result 'LocalGroups' "$grp populated" 'WARN' 'Group exists but is EMPTY' }
        else { Add-Result 'LocalGroups' "$grp populated" 'WARN' 'Group does not exist' }
    }
    $installAcct = Get-LocalUser -Name $desired.LocalInstallAcct -ErrorAction SilentlyContinue
    if ($installAcct) { Add-Result 'LocalGroups' "Local install account ($($desired.LocalInstallAcct))" 'OK' "Enabled=$($installAcct.Enabled)" }
    else { Add-Result 'LocalGroups' "Local install account ($($desired.LocalInstallAcct))" 'WARN' 'Local user not found' }

    # ==================== 4. SQL BROWSER (should be disabled) ====================
    $browser = Get-Service SQLBrowser -ErrorAction SilentlyContinue
    if ($browser -and $browser.StartType -eq 'Disabled' -and $browser.Status -eq 'Stopped') {
        Add-Result 'Services' 'SQL Browser disabled/stopped' 'OK' 'Disabled + Stopped (as desired)'
    } elseif ($browser) {
        Add-Result 'Services' 'SQL Browser disabled/stopped' 'WARN' "StartType=$($browser.StartType) Status=$($browser.Status) (desired Disabled/Stopped)"
    } else { Add-Result 'Services' 'SQL Browser disabled/stopped' 'INFO' 'SQLBrowser service not present' }

    # ==================== 5. SSMS INSTALLED ====================
    if ($desired.InstallSSMS -eq 'YES') {
        $ssmsAll = @(Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*','HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*' -ErrorAction SilentlyContinue |
                     Where-Object { $_.DisplayName -like '*SQL Server Management Studio*' })

        if (-not $ssmsAll) {
            Add-Result 'SSMS' 'SSMS installed' 'WARN' 'Not detected (InstallStandAloneSSMS=YES in config)'
        }
        elseif ($desired.SsmsMinMajor) {
            # A specific generation is required -- an older SSMS being present is not enough.
            $minMajor = [int]$desired.SsmsMinMajor
            $match = $ssmsAll | Where-Object {
                        $_.DisplayVersion -match '^(\d+)' -and [int]$Matches[1] -ge $minMajor
                     } | Select-Object -First 1
            if ($match) {
                Add-Result 'SSMS' "SSMS installed (>= v$minMajor)" 'OK' "$($match.DisplayName) $($match.DisplayVersion)"
            } else {
                $found = ($ssmsAll | ForEach-Object { "$($_.DisplayName) $($_.DisplayVersion)" }) -join '; '
                Add-Result 'SSMS' "SSMS installed (>= v$minMajor)" 'WARN' "Only older SSMS found: $found"
            }
        }
        else {
            $ssms = $ssmsAll | Select-Object -First 1
            Add-Result 'SSMS' 'SSMS installed' 'OK' "$($ssms.DisplayName) $($ssms.DisplayVersion)"
        }
    }

    # ==================== 6. SQL-LEVEL CHECKS (require a working connection) ====================
    try {
        $ping = Invoke-Sql "SELECT SERVERPROPERTY('ProductVersion') AS v, SERVERPROPERTY('ProductUpdateLevel') AS lvl, SERVERPROPERTY('Edition') AS ed"
        $script:SqlOk = $true
        Add-Result 'Engine' 'SQL version / patch level' 'OK' "v$($ping.Rows[0].v)  $($ping.Rows[0].lvl)  [$($ping.Rows[0].ed)]"
    } catch {
        Add-Result 'Engine' "SQL connection (localhost,$Port)" 'FAIL' "Could not connect: $($_.Exception.Message.Split([Environment]::NewLine)[0])"
    }

    # The SQL-level checks are wrapped so that an unexpected failure in any single
    # query degrades to one WARN instead of throwing out every result already
    # collected for this node (the scriptblock returns nothing if an exception
    # escapes, which would report the whole node as a single unhelpful [FAIL]).
    if ($script:SqlOk) {
      try {
        # ---- sp_configure options (DSC: xSQLServerConfiguration / xSQLServerMaxDop / xSQLServerMemory) ----
        $cfg = Invoke-Sql @"
SELECT name, CONVERT(bigint, value_in_use) AS value_in_use
FROM sys.configurations
WHERE name IN ('max degree of parallelism','max server memory (MB)','min server memory (MB)',
               'Agent XPs','remote admin connections','backup compression default','remote access')
"@
        $cfgH = @{}; foreach ($r in $cfg.Rows) { $cfgH[$r.name] = [int64]$r.value_in_use }

        $expectOne = @{
            'Agent XPs'                  = 1
            'remote admin connections'   = 1
            'backup compression default' = 1
            'remote access'              = 0
        }
        foreach ($opt in $expectOne.Keys) {
            $act = $cfgH[$opt]; $exp = $expectOne[$opt]
            if ($act -eq $exp) { Add-Result 'SQLConfig' "sp_configure '$opt'" 'OK' "= $act" }
            else { Add-Result 'SQLConfig' "sp_configure '$opt'" 'WARN' "= $act (desired $exp -- DSC value not applied)" }
        }

        # MaxDop: desired is dynamic; flag only if left at 0 (default/unlimited)
        $maxdop = $cfgH['max degree of parallelism']
        if ($maxdop -gt 0) { Add-Result 'SQLConfig' 'max degree of parallelism' 'OK' "= $maxdop" }
        else { Add-Result 'SQLConfig' 'max degree of parallelism' 'WARN' '= 0 (default/unlimited -- dynamic MaxDop not applied)' }

        # Memory: dynamic alloc; flag if max is left at the 2147483647 default (unlimited)
        $maxmem = $cfgH['max server memory (MB)']; $minmem = $cfgH['min server memory (MB)']
        if ($maxmem -lt 2147483647) { Add-Result 'SQLConfig' 'max server memory (MB)' 'OK' "= $maxmem (min=$minmem)" }
        else { Add-Result 'SQLConfig' 'max server memory (MB)' 'WARN' "= UNLIMITED default (min=$minmem -- dynamic memory alloc not applied)" }

        # ---- Trace flags (DSC: Script Add-TraceFlag...) ----
        $tf = Invoke-Sql "DBCC TRACESTATUS(-1) WITH NO_INFOMSGS"
        $activeTf = @(); foreach ($r in $tf.Rows) { if ($r.Global -eq 1) { $activeTf += [string]$r.TraceFlag } }
        foreach ($want in $desired.TraceFlags) {
            if ($activeTf -contains $want) { Add-Result 'TraceFlags' "Trace flag -T$want" 'OK' 'Active (Global)' }
            else { Add-Result 'TraceFlags' "Trace flag -T$want" 'WARN' 'Not active' }
        }

        # ---- Configure_SQLServer_Set.sql effects ----
        # tempdb file count (should be > 1; script builds up to 8 data files)
        $tdb = Invoke-Sql "SELECT COUNT(*) AS c FROM sys.master_files WHERE database_id = 2 AND file_id <> 2"
        $tdbCount = [int]$tdb.Rows[0].c
        if ($tdbCount -gt 1) { Add-Result 'SQLScripts' 'tempdb multiple data files' 'OK' "$tdbCount data file(s)" }
        else { Add-Result 'SQLScripts' 'tempdb multiple data files' 'WARN' "$tdbCount data file (Configure_SQLServer_Set.sql not applied)" }

        # model PAGE_VERIFY = CHECKSUM
        $pv = Invoke-Sql "SELECT page_verify_option_desc AS pv FROM sys.databases WHERE name = 'model'"
        if ($pv.Rows[0].pv -eq 'CHECKSUM') { Add-Result 'SQLScripts' 'model PAGE_VERIFY = CHECKSUM' 'OK' 'CHECKSUM' }
        else { Add-Result 'SQLScripts' 'model PAGE_VERIFY = CHECKSUM' 'WARN' "$($pv.Rows[0].pv)" }

        # AuditLevel (registry via SQL) = 3
        $al = Invoke-Sql @"
DECLARE @lvl INT
EXEC master.dbo.xp_instance_regread N'HKEY_LOCAL_MACHINE', N'Software\Microsoft\MSSQLServer\MSSQLServer', N'AuditLevel', @lvl OUTPUT
SELECT @lvl AS lvl
"@
        $alVal = Get-IntOrNull $al.Rows[0].lvl
        if ($alVal -eq 3) { Add-Result 'SQLScripts' 'Login audit level (both)' 'OK' 'AuditLevel=3' }
        elseif ($null -eq $alVal) { Add-Result 'SQLScripts' 'Login audit level (both)' 'WARN' 'AuditLevel not set (Configure_SQLServer_Set.sql not applied)' }
        else { Add-Result 'SQLScripts' 'Login audit level (both)' 'WARN' "AuditLevel=$alVal (expected 3)" }

        # NumErrorLogs = 99
        $nel = Invoke-Sql @"
DECLARE @n INT
EXEC master.dbo.xp_instance_regread N'HKEY_LOCAL_MACHINE', N'Software\Microsoft\MSSQLServer\MSSQLServer', N'NumErrorLogs', @n OUTPUT
SELECT @n AS n
"@
        $nelVal = Get-IntOrNull $nel.Rows[0].n
        if ($nelVal -eq 99) { Add-Result 'SQLScripts' 'Error log retention (99)' 'OK' 'NumErrorLogs=99' }
        elseif ($null -eq $nelVal) { Add-Result 'SQLScripts' 'Error log retention (99)' 'WARN' 'NumErrorLogs not set (Configure_SQLServer_Set.sql not applied)' }
        else { Add-Result 'SQLScripts' 'Error log retention (99)' 'WARN' "NumErrorLogs=$nelVal (expected 99)" }

        # Agent job history retention (50000 / 10000)
        $jh = Invoke-Sql @"
DECLARE @a INT, @b INT
EXEC master.dbo.xp_instance_regread N'HKEY_LOCAL_MACHINE', N'SOFTWARE\Microsoft\MSSQLServer\SQLServerAgent', N'JobHistoryMaxRows', @a OUTPUT
EXEC master.dbo.xp_instance_regread N'HKEY_LOCAL_MACHINE', N'SOFTWARE\Microsoft\MSSQLServer\SQLServerAgent', N'JobHistoryMaxRowsPerJob', @b OUTPUT
SELECT @a AS maxrows, @b AS perjob
"@
        $jhMax = Get-IntOrNull $jh.Rows[0].maxrows
        $jhJob = Get-IntOrNull $jh.Rows[0].perjob
        if ($jhMax -eq 50000 -and $jhJob -eq 10000) {
            Add-Result 'SQLScripts' 'Agent job history (50000/10000)' 'OK' "$jhMax/$jhJob"
        } else {
            $shown = "$(if ($null -eq $jhMax) {'<not set>'} else {$jhMax})/$(if ($null -eq $jhJob) {'<not set>'} else {$jhJob})"
            Add-Result 'SQLScripts' 'Agent job history (50000/10000)' 'WARN' "$shown (expected 50000/10000)"
        }

        # ---- SecureSA_Set.sql: sa renamed to dsa and disabled ----
        $sa = Invoke-Sql @"
SELECT
  (SELECT COUNT(*) FROM sys.server_principals WHERE name='sa') AS sa_exists,
  (SELECT COUNT(*) FROM sys.server_principals WHERE name='dsa') AS dsa_exists,
  (SELECT is_disabled FROM sys.server_principals WHERE name='dsa') AS dsa_disabled
"@
        # dsa_disabled is a scalar subquery: it returns NULL (DBNull) when no 'dsa'
        # login exists, which is exactly the un-remediated case.
        $saExists    = Get-IntOrNull $sa.Rows[0].sa_exists
        $dsaExists   = Get-IntOrNull $sa.Rows[0].dsa_exists
        $dsaDisabled = Get-IntOrNull $sa.Rows[0].dsa_disabled

        if ($saExists -eq 0 -and $dsaExists -eq 1 -and $dsaDisabled -eq 1) {
            Add-Result 'SQLScripts' "sa secured (renamed 'dsa' + disabled)" 'OK' 'sa renamed to dsa and disabled'
        } elseif ($saExists -eq 1) {
            Add-Result 'SQLScripts' "sa secured (renamed 'dsa' + disabled)" 'WARN' "'sa' still exists (SecureSA_Set.sql not applied)"
        } elseif ($dsaExists -ne 1) {
            Add-Result 'SQLScripts' "sa secured (renamed 'dsa' + disabled)" 'WARN' "neither 'sa' nor 'dsa' login found"
        } else {
            Add-Result 'SQLScripts' "sa secured (renamed 'dsa' + disabled)" 'WARN' "dsa exists but is_disabled=$(if ($null -eq $dsaDisabled) {'<unknown>'} else {$dsaDisabled})"
        }

        # ---- Operators_Set.sql: 'DBAs' operator ----
        $op = Invoke-Sql "SELECT COUNT(*) AS c FROM msdb.dbo.sysoperators WHERE name = 'DBAs'"
        if ([int]$op.Rows[0].c -ge 1) { Add-Result 'SQLScripts' "SQL Agent operator 'DBAs'" 'OK' 'Present' }
        else { Add-Result 'SQLScripts' "SQL Agent operator 'DBAs'" 'WARN' 'Not found (Operators_Set.sql not applied)' }

        # ---- DatabaseMail: a profile + account exist, Database Mail XPs on ----
        $mail = Invoke-Sql @"
SELECT
  (SELECT COUNT(*) FROM msdb.dbo.sysmail_profile) AS profiles,
  (SELECT COUNT(*) FROM msdb.dbo.sysmail_account) AS accounts,
  (SELECT CONVERT(int, value_in_use) FROM sys.configurations WHERE name='Database Mail XPs') AS mailxps
"@
        $mailProfiles = Get-IntOrNull $mail.Rows[0].profiles
        $mailAccounts = Get-IntOrNull $mail.Rows[0].accounts
        $mailXps      = Get-IntOrNull $mail.Rows[0].mailxps
        if ($mailProfiles -ge 1 -and $mailAccounts -ge 1) {
            Add-Result 'SQLScripts' 'Database Mail profile + account' 'OK' "$mailProfiles profile(s), $mailAccounts account(s), XPs=$(if ($null -eq $mailXps) {'<not set>'} else {$mailXps})"
        } else {
            Add-Result 'SQLScripts' 'Database Mail profile + account' 'WARN' "$mailProfiles profile(s)/$mailAccounts account(s) (DatabaseMail script not applied)"
        }

        # ---- AuditsAndBroker: server audit + audit specification, both ON ----
        $aud = Invoke-Sql @"
SELECT
  (SELECT COUNT(*) FROM sys.server_audits WHERE is_state_enabled = 1) AS audits_on,
  (SELECT COUNT(*) FROM sys.server_audit_specifications WHERE is_state_enabled = 1) AS specs_on
"@
        if ([int]$aud.Rows[0].audits_on -ge 1 -and [int]$aud.Rows[0].specs_on -ge 1) {
            Add-Result 'SQLScripts' 'Server audit + specification (ON)' 'OK' "$($aud.Rows[0].audits_on) audit(s), $($aud.Rows[0].specs_on) spec(s) enabled"
        } else {
            Add-Result 'SQLScripts' 'Server audit + specification (ON)' 'WARN' "audits_on=$($aud.Rows[0].audits_on), specs_on=$($aud.Rows[0].specs_on) (AuditsAndBroker not applied)"
        }

        # ---- Ola Hallengren maintenance solution jobs (DatabaseMaintenanceSolution) ----
        $jobs = Invoke-Sql "SELECT COUNT(*) AS c FROM msdb.dbo.sysjobs WHERE name LIKE 'DatabaseBackup%' OR name LIKE 'DatabaseIntegrityCheck%' OR name LIKE 'IndexOptimize%' OR name LIKE 'CommandLog Cleanup%' OR name LIKE 'Output File Cleanup%'"
        if ([int]$jobs.Rows[0].c -ge 1) { Add-Result 'SQLScripts' 'Maintenance solution jobs' 'OK' "$($jobs.Rows[0].c) maintenance job(s) present" }
        else { Add-Result 'SQLScripts' 'Maintenance solution jobs' 'WARN' 'No maintenance jobs found (DatabaseMaintenanceSolution not applied)' }

        # ---- High-severity alerts (Alerts_HighSeverity) ----
        #
        # Alerts_HighSeverity_Set.sql deliberately creates these DISABLED, so a
        # disabled alert is the expected state, not a problem. The enabled/disabled
        # split is reported so it is obvious at a glance whether anyone has turned
        # them on (which starts mail flowing to the 'DBAs' operator).
        $alerts = Invoke-Sql @"
SELECT COUNT(*) AS total,
       SUM(CASE WHEN enabled = 1 THEN 1 ELSE 0 END) AS enabled_count
FROM msdb.dbo.sysalerts
WHERE severity BETWEEN 16 AND 25
"@
        $alertTotal   = Get-IntOrNull $alerts.Rows[0].total
        $alertEnabled = Get-IntOrNull $alerts.Rows[0].enabled_count
        if ($alertTotal -ge 1) {
            Add-Result 'SQLScripts' 'High-severity alerts (16-25)' 'OK' "$alertTotal alert(s) defined ($alertEnabled enabled, $($alertTotal - $alertEnabled) disabled)"
        } else {
            Add-Result 'SQLScripts' 'High-severity alerts (16-25)' 'WARN' 'No severity 16-25 alerts (Alerts_HighSeverity not applied)'
        }

        # ---- Telemetry / CEIP disabled (Script Disable-SQLandSSMSErrorReporting) ----
        $ceip = Get-Service -ErrorAction SilentlyContinue | Where-Object { $_.Name -like '*TELEMETRY*' -and $_.Status -eq 'Running' }
        if ($ceip) { Add-Result 'SQLScripts' 'Telemetry/CEIP services disabled' 'WARN' (($ceip.Name) -join '; ') }
        else { Add-Result 'SQLScripts' 'Telemetry/CEIP services disabled' 'OK' 'No running TELEMETRY services' }
      }
      catch {
          $msg = ( $_.Exception.Message -replace '[\r\n]+', ' ' ).Trim()
          Add-Result 'SQLScripts' 'SQL-level checks incomplete' 'WARN' "A check threw an error and the remaining SQL checks were skipped: $msg"
      }
    }

    return $results
}

# ---------------------------------------------------------------------------
# Runner: execute the check scriptblock on each node, collect + report
# ---------------------------------------------------------------------------
function Write-Log { param($msg) ; $msg | Tee-Object -FilePath $logFile -Append | Out-Null }
function Say {
    param($msg, $color = 'Gray')
    if ([string]::IsNullOrEmpty($color)) { $color = 'Gray' }   # never let an unmapped status kill the report
    Write-Host $msg -ForegroundColor $color
    Add-Content -Path $logFile -Value $msg
}

$statusColor = @{ OK='Green'; WARN='Yellow'; FAIL='Red'; INFO='Cyan' }

Say ""
Say "================================================================================" 'DarkCyan'
Say " SQL SERVER POST-INSTALL VERIFICATION" 'White'
Say " Config : $($envDataFile.Name)" 'Gray'
Say " Version: $Version (build $Build)   Instance: $Instance   Port: $Port" 'Gray'
Say " Nodes  : $($ComputerName -join ', ')" 'Gray'
Say " Log    : $logFile" 'Gray'
Say " Time   : $(Get-Date)" 'Gray'
Say "================================================================================" 'DarkCyan'

$grandTotals = @{ OK=0; WARN=0; FAIL=0; INFO=0 }

foreach ($node in $ComputerName) {
    Say ""
    Say "==================== NODE: $node ====================" 'White'

    $isLocal = ($node -eq $env:COMPUTERNAME) -or ($node -eq 'localhost') -or ($node -eq '.')
    try {
        if ($isLocal) {
            $nodeResults = & $checkScript $desired
        } else {
            $nodeResults = Invoke-Command -ComputerName $node -ScriptBlock $checkScript -ArgumentList $desired -ErrorAction Stop
        }
    } catch {
        Say "  [FAIL] Could not run checks on $node -- $($_.Exception.Message)" 'Red'
        $grandTotals.FAIL++
        continue
    }

    $lastCat = ''
    foreach ($r in $nodeResults) {
        if ($r.Category -ne $lastCat) { Say ""; Say "  -- $($r.Category) --" 'DarkGray'; $lastCat = $r.Category }
        $tag = $r.Status.PadRight(4)
        $line = "  [$tag] {0,-42} {1}" -f $r.Name, $r.Detail
        Say $line $statusColor[$r.Status]
        if ($grandTotals.ContainsKey($r.Status)) { $grandTotals[$r.Status]++ }
    }
}

Say ""
Say "================================================================================" 'DarkCyan'
Say " SUMMARY:  [OK] $($grandTotals.OK)   [WARN] $($grandTotals.WARN)   [FAIL] $($grandTotals.FAIL)   [INFO] $($grandTotals.INFO)" 'White'
Say "          Full report saved to: $logFile" 'Gray'
if ($grandTotals.FAIL -gt 0)      { Say " RESULT: FAIL -- one or more critical checks failed (see [FAIL] lines above)." 'Red' }
elseif ($grandTotals.WARN -gt 0)  { Say " RESULT: WARN -- install succeeded but some desired settings did not apply (see [WARN])." 'Yellow' }
else                              { Say " RESULT: PASS -- all checked settings match desired state." 'Green' }
Say "================================================================================" 'DarkCyan'
