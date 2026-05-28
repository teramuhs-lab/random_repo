#Requires -Module SqlServer

# ════════════════════════════════════════════════════════════════════════════════
#  CONFIGURATION
# ════════════════════════════════════════════════════════════════════════════════

# SQL Server host names — instance and port are appended at connection time
$Servers = @(
    "DDCWODWFDBS52",
    "DDCWODWFDBS53",
    "DDCWODWFDBS54",
    "DDCWODWFDBS55",
    "DDCWODWFDBS56",
    "DDCWNZWFDBS05",
    "DDCWNZWFDBS07"
)
$Instance        = "CAPPT"
$SQLPort         = 1443   # non-default SQL port used by this environment
$RefreshSeconds  = 60     # how long to wait between refreshes (Ctrl+C to exit)

# Network targets tested with Test-NetConnection
# Listeners use port 1443 (SQL); AG endpoints use port 5022 (mirroring)
$NetTests = @(
    [PSCustomObject]@{ Label = "BNFDistLsnr01,1443";  Host = "BNFDistLsnr01";  Port = 1443 }
    [PSCustomObject]@{ Label = "DDLsnrVC01,1443";     Host = "DDLsnrVC01";     Port = 1443 }
    [PSCustomObject]@{ Label = "DDCWODWFDBS52,5022";  Host = "DDCWODWFDBS52";  Port = 5022 }
    [PSCustomObject]@{ Label = "DDCWODWFDBS53,5022";  Host = "DDCWODWFDBS53";  Port = 5022 }
    [PSCustomObject]@{ Label = "DDCWODWFDBS54,5022";  Host = "DDCWODWFDBS54";  Port = 5022 }
    [PSCustomObject]@{ Label = "DDCWODWFDBS55,5022";  Host = "DDCWODWFDBS55";  Port = 5022 }
    [PSCustomObject]@{ Label = "DDCWODWFDBS56,5022";  Host = "DDCWODWFDBS56";  Port = 5022 }
    [PSCustomObject]@{ Label = "DDCWNZWFDBS05,5022";  Host = "DDCWNZWFDBS05";  Port = 5022 }
    [PSCustomObject]@{ Label = "DDCWNZWFDBS07,5022";  Host = "DDCWNZWFDBS07";  Port = 5022 }
)

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

# Per-database sync lag: send queue, redo queue, redo rate, suspend status
$querySyncLag = @"
SELECT
    @@SERVERNAME                        AS ServerName,
    ag.name                             AS AGName,
    DB_NAME(drs.database_id)            AS DatabaseName,
    drs.synchronization_state_desc      AS SyncState,
    ISNULL(drs.log_send_queue_size, 0)  AS SendQueueKB,
    ISNULL(drs.redo_queue_size,     0)  AS RedoQueueKB,
    ISNULL(drs.redo_rate,           0)  AS RedoRateKBps,
    CAST(drs.is_suspended AS INT)       AS IsSuspended,
    ISNULL(drs.suspend_reason_desc, '') AS SuspendReason
FROM sys.dm_hadr_database_replica_states drs
JOIN sys.availability_groups ag ON drs.group_id = ag.group_id
WHERE drs.is_local = 1
  AND drs.database_id IS NOT NULL;
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

$allReplicas  = [System.Collections.Generic.List[PSObject]]::new()
$syncLagData  = [System.Collections.Generic.List[PSObject]]::new()
$clusterNodes = $null   # only need this from one server — same data across all nodes
$listenerData = $null   # same — queried once from the first server that responds

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

    # --- Sync lag (non-fatal; empty on primary-only installs) -------------------
    try {
        foreach ($r in (Invoke-Sqlcmd -ServerInstance $conn -Query $querySyncLag -ErrorAction Stop)) {
            $syncLagData.Add($r)
        }
    } catch {}

    # --- Cluster nodes and listeners (once, from the first responding server) ---
    if (-not $clusterNodes) {
        try { $clusterNodes = Invoke-Sqlcmd -ServerInstance $conn -Query $queryCluster   -ErrorAction Stop } catch {}
    }
    if (-not $listenerData) {
        try { $listenerData  = Invoke-Sqlcmd -ServerInstance $conn -Query $queryListeners -ErrorAction Stop } catch {}
    }
}

# --- Network connectivity (Test-NetConnection per target) ---------------------
Write-Host '  Testing network connectivity…' -ForegroundColor DarkGray
$netResults = @(foreach ($t in $NetTests) {
    $ok = $false
    try {
        $r  = Test-NetConnection -ComputerName $t.Host -Port $t.Port `
                                  -WarningAction SilentlyContinue -ErrorAction SilentlyContinue
        $ok = [bool]$r.TcpTestSucceeded
    } catch {}
    [PSCustomObject]@{ Label = $t.Label; OK = $ok }
})

# --- SQL Server services (Get-Service over SCM/RPC; requires firewall access) -
Write-Host '  Checking SQL services…' -ForegroundColor DarkGray
$svcResults = [System.Collections.Generic.List[PSObject]]::new()
foreach ($Server in $Servers) {
    try {
        foreach ($svc in (Get-Service -ComputerName $Server -Name 'MSSQL*','SQLAgent*' -ErrorAction Stop)) {
            $svcResults.Add([PSCustomObject]@{
                Server  = $Server
                Name    = $svc.Name
                Display = $svc.DisplayName
                Status  = $svc.Status.ToString()
            })
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
    Write-Host ($lagFmt -f 'Server','AGName','Database','SendQueueKB','RedoQueueKB','RedoRate KB/s','Suspended') -ForegroundColor White
    Write-Host $div -ForegroundColor DarkGray

    foreach ($db in ($syncLagData | Sort-Object RedoQueueKB -Descending | Select-Object -First 15)) {
        $color = if ($db.IsSuspended -eq 1)   { 'Red'    }
                 elseif ($db.RedoQueueKB -gt 0){ 'Yellow' }
                 else                           { 'Green'  }
        $susp  = if ($db.IsSuspended -eq 1) { "YES ($($db.SuspendReason))" } else { 'No' }
        Write-Host ($lagFmt -f $db.ServerName, $db.AGName, $db.DatabaseName,
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

# ── AG Listeners ──────────────────────────────────────────────────────────────
if ($listenerData) {
    Write-Host ''
    Write-Host '  ── AG Listeners ──────────────────────────────────────────────────' -ForegroundColor Cyan

    $lFmt = '  {0,-22} {1,-24} {2,-8} {3,-18} {4}'
    Write-Host ($lFmt -f 'AGName','ListenerName','Port','IPAddress','DHCP') -ForegroundColor White
    Write-Host $div -ForegroundColor DarkGray

    foreach ($l in $listenerData) {
        $dhcp = if ($l.IsDHCP) { 'Yes' } else { 'No' }
        Write-Host ($lFmt -f $l.AGName, $l.ListenerName, $l.ListenerPort, $l.IPAddress, $dhcp) -ForegroundColor Gray
    }
}

# ── Network Connectivity ──────────────────────────────────────────────────────
Write-Host ''
Write-Host '  ── Network Connectivity ──────────────────────────────────────────────' -ForegroundColor Cyan

foreach ($n in $netResults) {
    $sym   = if ($n.OK) { '[OK]' } else { '[!!]' }
    $color = if ($n.OK) { 'Green' } else { 'Red' }
    Write-Host "  $sym  $($n.Label)" -ForegroundColor $color
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
