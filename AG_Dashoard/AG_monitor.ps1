#Requires -Module SqlServer

# ════════════════════════════════════════════════════════════════════════════════
#  CONFIGURATION
# ════════════════════════════════════════════════════════════════════════════════

$Instance       = "CAPPT"
$SQLPort        = 1443   # non-default SQL port used by this environment
$RefreshSeconds = 60     # seconds between screen refreshes (Ctrl+C to exit)

# Config files live in the same folder as this script
$ScriptDir = if ($PSScriptRoot) { $PSScriptRoot }
             elseif ($psISE)   { Split-Path $psISE.CurrentFile.FullPath }
             else              { (Get-Location).Path }

# servers.txt  — one hostname per line; blank lines and # comments are ignored
$serversFile = Join-Path $ScriptDir 'servers.txt'
if (-not (Test-Path $serversFile)) {
    Write-Host "  [ERROR] servers.txt not found at: $serversFile" -ForegroundColor Red; exit 1
}
$Servers = Get-Content $serversFile | Where-Object { $_ -match '\S' -and $_ -notmatch '^\s*#' }

# nettests.json — array of {Label, Host, Port} objects
$netTestsFile = Join-Path $ScriptDir 'nettests.json'
if (-not (Test-Path $netTestsFile)) {
    Write-Host "  [ERROR] nettests.json not found at: $netTestsFile" -ForegroundColor Red; exit 1
}
$NetTests = Get-Content $netTestsFile -Raw | ConvertFrom-Json

# ════════════════════════════════════════════════════════════════════════════════
#  SQL QUERIES
# ════════════════════════════════════════════════════════════════════════════════

# Replica health: role, connection state, sync health, failover/seeding/avail mode
$queryReplica = @"
SELECT
    @@SERVERNAME                     AS ServerName,
    ag.name                          AS AGName,
    ar.replica_server_name           AS ReplicaServer,
    ars.role_desc                    AS Role,
    ars.connected_state_desc         AS ConnectedState,
    ars.synchronization_health_desc  AS SyncHealth,
    ar.failover_mode_desc            AS FailoverMode,
    ar.seeding_mode_desc             AS SeedingMode,
    ar.availability_mode_desc        AS AvailabilityMode
FROM sys.dm_hadr_availability_replica_states ars
JOIN sys.availability_groups   ag ON ars.group_id   = ag.group_id
JOIN sys.availability_replicas ar ON ars.replica_id = ar.replica_id
WHERE ars.is_local = 1;
"@

# Per-database sync lag — run on PRIMARY only; returns lag for all secondaries
$querySyncLag = @"
SELECT
    ag.name                             AS AGName,
    ar.replica_server_name              AS ReplicaServer,
    DB_NAME(drs.database_id)            AS DatabaseName,
    drs.synchronization_state_desc      AS SyncState,
    ISNULL(drs.log_send_queue_size, 0)  AS SendQueueKB,
    ISNULL(drs.redo_queue_size,     0)  AS RedoQueueKB,
    ISNULL(drs.redo_rate,           0)  AS RedoRateKBps,
    CAST(drs.is_suspended AS INT)       AS IsSuspended,
    ISNULL(drs.suspend_reason_desc, '') AS SuspendReason
FROM sys.dm_hadr_database_replica_states drs
JOIN sys.availability_groups    ag ON drs.group_id   = ag.group_id
JOIN sys.availability_replicas  ar ON drs.replica_id = ar.replica_id
WHERE drs.database_id IS NOT NULL
  AND ar.replica_server_name != @@SERVERNAME;
"@

# WSFC cluster node membership and quorum votes
$queryCluster = @"
SELECT
    member_name            AS NodeName,
    member_type_desc       AS NodeType,
    member_state_desc      AS NodeState,
    number_of_quorum_votes AS QuorumVotes
FROM sys.dm_hadr_cluster_members;
"@

# AG listener DNS names, ports, and IP addresses
$queryListeners = @"
SELECT
    ag.name       AS AGName,
    l.dns_name    AS ListenerName,
    l.port        AS ListenerPort,
    li.ip_address AS IPAddress,
    li.is_dhcp    AS IsDHCP
FROM sys.availability_group_listeners l
JOIN sys.availability_groups ag ON l.group_id = ag.group_id
LEFT JOIN sys.availability_group_listener_ip_addresses li
    ON l.listener_id = li.listener_id;
"@

# ════════════════════════════════════════════════════════════════════════════════
#  DATA COLLECTION
# ════════════════════════════════════════════════════════════════════════════════

while ($true) {
Clear-Host


$allReplicas     = [System.Collections.Generic.List[PSObject]]::new()
$syncLagData     = [System.Collections.Generic.List[PSObject]]::new()
$allListenerRows = [System.Collections.Generic.List[PSObject]]::new()
$clusterNodes    = $null   # only need this from one server — same data across all nodes

foreach ($Server in $Servers) {
    $conn = "$Server\$Instance,$SQLPort"

    # --- Replica states (primary data; failures add a placeholder row) ----------
    try {
        foreach ($r in (Invoke-Sqlcmd -ServerInstance $conn -Query $queryReplica -ErrorAction Stop)) {
            $allReplicas.Add($r)
        }
    }
    catch {
        Write-Host "  [FAIL] $conn — $_" -ForegroundColor Red
        $allReplicas.Add([PSCustomObject]@{
            ServerName = $Server;  AGName = 'N/A';  ReplicaServer = 'UNREACHABLE'
            Role = 'UNKNOWN';  ConnectedState = 'DISCONNECTED';  SyncHealth = 'NOT_HEALTHY'
            FailoverMode = 'N/A';  SeedingMode = 'N/A';  AvailabilityMode = 'N/A'
        })
    }

    # --- Cluster nodes (once, from the first responding server) -----------------
    if (-not $clusterNodes) {
        try { $clusterNodes = Invoke-Sqlcmd -ServerInstance $conn -Query $queryCluster -ErrorAction Stop } catch {}
    }

    # --- Listeners (all servers — each cluster only knows its own listeners) ---
    try {
        foreach ($lr in (Invoke-Sqlcmd -ServerInstance $conn -Query $queryListeners -ErrorAction Stop)) {
            $allListenerRows.Add([PSCustomObject]@{
                AGName       = ([string]$lr.AGName).Trim()
                ListenerName = ([string]$lr.ListenerName).Trim()
                ListenerPort = [int]$lr.ListenerPort
                IPAddress    = ([string]$lr.IPAddress).Trim()
                IsDHCP       = $lr.IsDHCP
            })
        }
    } catch {}
}

# Deduplicate listener rows — each secondary reports the same listener as its primary
$listenerData = @(
    $allListenerRows |
    Group-Object AGName, ListenerName, IPAddress |
    ForEach-Object { $_.Group[0] } |
    Sort-Object AGName, ListenerName, IPAddress
)

# --- Sync lag — query each unique primary once; it sees all secondaries' lag ---
$primaryConns = @(
    $allReplicas |
    Where-Object { $_.Role -eq 'PRIMARY' -and $_.ServerName -ne 'UNREACHABLE' } |
    Select-Object -ExpandProperty ServerName -Unique
)
foreach ($primarySrv in $primaryConns) {
    $conn = "$primarySrv,$SQLPort"
    try {
        foreach ($r in (Invoke-Sqlcmd -ServerInstance $conn -Query $querySyncLag -ErrorAction Stop)) {
            $syncLagData.Add($r)
        }
    } catch {}
}

# --- Network connectivity (Test-NetConnection per target) ---------------------
Write-Host '  Testing network connectivity…' -ForegroundColor DarkGray
$netResults = [System.Collections.Generic.List[PSObject]]::new()
foreach ($t in $NetTests) {
    $ok = $false
    try {
        $r  = Test-NetConnection -ComputerName $t.Host -Port $t.Port `
                                  -WarningAction SilentlyContinue -ErrorAction SilentlyContinue
        $ok = [bool]$r.TcpTestSucceeded
    } catch {}
    $netResults.Add([PSCustomObject]@{ Label = $t.Label; Host = $t.Host; Port = $t.Port; OK = $ok })
}

# --- Listener IP connectivity (one Test-NetConnection per IP from SQL data) ---
$listenerIPResults = [System.Collections.Generic.List[PSObject]]::new()
if ($listenerData) {
    foreach ($l in $listenerData) {
        if ([string]::IsNullOrWhiteSpace($l.IPAddress)) { continue }
        $ok = $false
        try {
            $r  = Test-NetConnection -ComputerName $l.IPAddress -Port $l.ListenerPort `
                      -WarningAction SilentlyContinue -ErrorAction SilentlyContinue
            $ok = [bool]$r.TcpTestSucceeded
        } catch {}
        $listenerIPResults.Add([PSCustomObject]@{
            AGName       = $l.AGName
            ListenerName = $l.ListenerName
            IPAddress    = $l.IPAddress
            Port         = $l.ListenerPort
            OK           = $ok
        })
    }
}

# --- SQL Server services (Get-Service over SCM/RPC; requires firewall access) -
Write-Host '  Checking SQL services…' -ForegroundColor DarkGray
$svcResults = [System.Collections.Generic.List[PSObject]]::new()
foreach ($Server in $Servers) {
    try {
        # Wildcard covers named instance (MSSQL$CAPPT), default instance (MSSQLSERVER),
        # and servers where the instance name differs from $Instance.
        # Wildcards never throw on no-match — only on connection failure.
        # Regex filter keeps only SQL engine / agent services, excluding
        # MSSQLFDLauncher, MSSQLServerADHelper, MSSQLServerOLAPService, etc.
        $svcs = @(Get-Service -ComputerName $Server -Name "MSSQL*","SQLAGENT*" -ErrorAction Stop |
                  Where-Object { $_.Name -match '^MSSQL(\$|SERVER$)|^SQLAGENT(\$|SERVERAGENT$)' })
        if ($svcs.Count -eq 0) {
            $svcResults.Add([PSCustomObject]@{
                Server = $Server; Name = '—'
                Display = 'No SQL Server services found'; Status = 'NOT FOUND'
            })
        } else {
            foreach ($svc in $svcs) {
                $svcResults.Add([PSCustomObject]@{
                    Server  = $Server
                    Name    = $svc.Name
                    Display = $svc.DisplayName
                    Status  = $svc.Status.ToString()
                })
            }
        }
    }
    catch {
        $svcResults.Add([PSCustomObject]@{
            Server = $Server;  Name = '—'
            Display = "Could not query: $($_.Exception.Message)"
            Status  = 'UNKNOWN'
        })
    }
}

# ════════════════════════════════════════════════════════════════════════════════
#  SUMMARY COUNTERS
# ════════════════════════════════════════════════════════════════════════════════

$ts          = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
$total       = $allReplicas.Count
$healthy     = @($allReplicas | Where-Object SyncHealth   -eq 'HEALTHY').Count
$partial     = @($allReplicas | Where-Object SyncHealth   -eq 'PARTIALLY_HEALTHY').Count
$unhealthy   = $total - $healthy - $partial
$autoFOCount = @($allReplicas | Where-Object FailoverMode -eq 'AUTOMATIC').Count

# ════════════════════════════════════════════════════════════════════════════════
#  CONSOLE OUTPUT
# ════════════════════════════════════════════════════════════════════════════════

$div = '  ' + ('─' * 148)

# ── AG Replica Health ─────────────────────────────────────────────────────────
Write-Host ''
Write-Host "  ┌─  SQL Always-On AG Dashboard  ──────────────────────────  $ts  ─┐" -ForegroundColor Cyan
Write-Host ''

$fmt = '  {0,-20} {1,-22} {2,-24} {3,-11} {4,-13} {5,-19} {6,-11} {7,-10} {8}'
Write-Host ($fmt -f 'Server','AGName','ReplicaServer','Role',
                     'Connected','SyncHealth','Failover','Seeding','AvailMode') -ForegroundColor White
Write-Host $div -ForegroundColor DarkGray

foreach ($row in $allReplicas) {
    # Colour drives off sync health; disconnected/unknown replicas always red
    $color = switch ($row.SyncHealth) {
        'HEALTHY'           { 'Green'  }
        'PARTIALLY_HEALTHY' { 'Yellow' }
        default             { 'Red'    }
    }
    if ($row.ConnectedState -eq 'DISCONNECTED' -or $row.Role -eq 'UNKNOWN') { $color = 'Red' }

    Write-Host ($fmt -f $row.ServerName, $row.AGName, $row.ReplicaServer,
        $row.Role, $row.ConnectedState, $row.SyncHealth,
        $row.FailoverMode, $row.SeedingMode, $row.AvailabilityMode) -ForegroundColor $color
}

Write-Host $div -ForegroundColor DarkGray
Write-Host ("  Replicas: $total total  |  ") -NoNewline -ForegroundColor White
Write-Host "$healthy HEALTHY "       -NoNewline -ForegroundColor Green
Write-Host "| $partial PARTIAL "     -NoNewline -ForegroundColor Yellow
Write-Host "| $unhealthy NOT-HEALTHY " -NoNewline -ForegroundColor Red
Write-Host "| $autoFOCount AUTO-FAILOVER" -ForegroundColor Cyan

# ── Sync Lag (top 15 databases by redo queue) ─────────────────────────────────
if ($syncLagData.Count -gt 0) {
    Write-Host ''
    Write-Host '  ── Sync Lag (Redo Queue KB) ──────────────────────────────────────' -ForegroundColor Cyan

    $lagFmt = '  {0,-20} {1,-22} {2,-24} {3,14} {4,14} {5,14} {6}'
    Write-Host ($lagFmt -f 'ReplicaServer','AGName','Database','SendQueueKB','RedoQueueKB','RedoRate KB/s','Suspended') -ForegroundColor White
    Write-Host $div -ForegroundColor DarkGray

    foreach ($db in ($syncLagData | Sort-Object RedoQueueKB -Descending | Select-Object -First 15)) {
        $color = if ($db.IsSuspended -eq 1)   { 'Red'    }
                 elseif ($db.RedoQueueKB -gt 0){ 'Yellow' }
                 else                           { 'Green'  }
        $susp  = if ($db.IsSuspended -eq 1) { "YES ($($db.SuspendReason))" } else { 'No' }
        Write-Host ($lagFmt -f $db.ReplicaServer, $db.AGName, $db.DatabaseName,
            $db.SendQueueKB, $db.RedoQueueKB, $db.RedoRateKBps, $susp) -ForegroundColor $color
    }
}

# ── Cluster Nodes ─────────────────────────────────────────────────────────────
if ($clusterNodes) {
    Write-Host ''
    Write-Host '  ── Cluster Nodes ─────────────────────────────────────────────────' -ForegroundColor Cyan

    $clFmt = '  {0,-30} {1,-20} {2,-15} {3}'
    Write-Host ($clFmt -f 'NodeName','NodeType','State','QuorumVotes') -ForegroundColor White
    Write-Host $div -ForegroundColor DarkGray

    foreach ($n in $clusterNodes) {
        $color = if ($n.NodeState -eq 'UP') { 'Green' } else { 'Red' }
        Write-Host ($clFmt -f $n.NodeName, $n.NodeType, $n.NodeState, $n.QuorumVotes) -ForegroundColor $color
    }
}

# ── AG Listeners & Connectivity ───────────────────────────────────────────────
#
# DNS row — tests the listener's hostname (e.g. DDLsnrBNEA01). This goes through
#   DNS resolution first, then connects. It confirms the name resolves AND reaches
#   the active IP. This row only appears if the listener is in nettests.json.
#
# IP row  — tests a specific IP address assigned to the listener directly, bypassing
#   DNS. A multi-subnet AG has one IP per subnet — only the IP on the active
#   replica's subnet will answer, so seeing [!!] on one IP is normal and expected.
#   It tells you which subnet the primary is currently on.
#
Write-Host ''
Write-Host '  ── AG Listeners & Connectivity ───────────────────────────────────────' -ForegroundColor Cyan

$cFmt = '  {0}  {1,-20} {2,-22} {3,-6} {4,-4} {5}'
Write-Host ($cFmt -f '    ', 'AGName', 'ListenerName', 'Port', 'Type', 'Address') -ForegroundColor White
Write-Host $div -ForegroundColor DarkGray

$matchedHosts = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

if ($listenerData) {
    $uniqueListeners = $listenerData |
        Group-Object AGName, ListenerName |
        Sort-Object Name |
        ForEach-Object { $_.Group[0] }

    foreach ($ul in $uniqueListeners) {
        $null = $matchedHosts.Add($ul.ListenerName)

        # DNS row — matched from nettests.json
        $dnsEntry = $netResults | Where-Object { $_.Host -eq $ul.ListenerName } | Select-Object -First 1
        if ($dnsEntry) {
            $sym   = if ($dnsEntry.OK) { '[OK]' } else { '[!!]' }
            $color = if ($dnsEntry.OK) { 'Green' } else { 'Red' }
            Write-Host ($cFmt -f $sym, $ul.AGName, $ul.ListenerName, $ul.ListenerPort, 'DNS', $ul.ListenerName) -ForegroundColor $color
        } else {
            Write-Host ($cFmt -f '    ', $ul.AGName, $ul.ListenerName, $ul.ListenerPort, 'DNS', $ul.ListenerName) -ForegroundColor DarkGray
        }

        # IP rows — one per IP address from SQL listener data
        foreach ($ipRow in ($listenerIPResults | Where-Object { $_.AGName -eq $ul.AGName -and $_.ListenerName -eq $ul.ListenerName })) {
            $sym   = if ($ipRow.OK) { '[OK]' } else { '[!!]' }
            $color = if ($ipRow.OK) { 'Green' } else { 'Red' }
            Write-Host ($cFmt -f $sym, $ul.AGName, $ul.ListenerName, $ul.ListenerPort, 'IP', $ipRow.IPAddress) -ForegroundColor $color
        }
    }
}

# nettests.json listener entries with no matching SQL listener (e.g. external clusters)
foreach ($n in ($netResults | Where-Object { $_.Port -eq 1443 })) {
    if ($matchedHosts.Contains($n.Host)) { continue }
    $sym   = if ($n.OK) { '[OK]' } else { '[!!]' }
    $color = if ($n.OK) { 'Green' } else { 'Red' }
    Write-Host ($cFmt -f $sym, '—', '—', $n.Port, 'DNS', $n.Host, '—') -ForegroundColor $color
}

$hadrEndpts = @($netResults | Where-Object { $_.Port -ne 1443 })
Write-Host ''
Write-Host '  ── HADR Endpoint Connectivity ────────────────────────────────────────' -ForegroundColor Cyan
if ($hadrEndpts.Count -gt 0) {
    foreach ($n in $hadrEndpts) {
        $sym   = if ($n.OK) { '[OK]' } else { '[!!]' }
        $color = if ($n.OK) { 'Green' } else { 'Red' }
        Write-Host "  $sym  $($n.Label)" -ForegroundColor $color
    }
} else {
    Write-Host '  (no endpoint tests configured)' -ForegroundColor DarkGray
}

# ── SQL Services ──────────────────────────────────────────────────────────────
Write-Host ''
Write-Host '  ── SQL Server Services ───────────────────────────────────────────────' -ForegroundColor Cyan

$svcFmt = '  {0,-20} {1,-25} {2,-40} {3}'
Write-Host ($svcFmt -f 'Server','ServiceName','DisplayName','Status') -ForegroundColor White
Write-Host $div -ForegroundColor DarkGray

foreach ($svc in $svcResults) {
    $color = switch ($svc.Status) {
        'Running' { 'Green'  }
        'Stopped' { 'Red'    }
        default   { 'Yellow' }
    }
    Write-Host ($svcFmt -f $svc.Server, $svc.Name, $svc.Display, $svc.Status) -ForegroundColor $color
}

Write-Host ''
Write-Host "  Next refresh in $RefreshSeconds s — press Ctrl+C to exit." -ForegroundColor DarkGray
Start-Sleep -Seconds $RefreshSeconds

} # end while ($true)
