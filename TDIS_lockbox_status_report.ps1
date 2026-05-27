# =============================================================================
# TDIS Lockbox Status Report
# -----------------------------------------------------------------------------
# Purpose  : Queries each SQL server for Ingest records loaded during the
#            current week through the end of the current business day. Shows
#            processing site, file details, arrival/status info, and AppCount.
#            A Grand Total row for AppCount is appended at the end.
# Output   : CSV saved to E:\SQLReports\Reports.
#            Collected and emailed by TDIS_send_daily_email.ps1.
# Schedule : Run daily via Windows Task Scheduler before TDIS_send_daily_email.
# =============================================================================

# -------- DATABASE SETTINGS --------
$Servers = @(
    "PNPCODWFDBSLE,1443",
    "PSEAODWCSQLVE\CAPPT",
    "PLAAODWFDBSLE,1443",
    "PWPCODWFDBSLE,1443",
    "PMMAODWFDBSLE,1443",
    "PMNAODWFDBSLE,1443"
)
$Database = "TDIS"

# -------- OUTPUT FILE PATH --------
$ReportFolder = "E:\SQLReports\Reports"
$Timestamp    = Get-Date -Format yyyyMMdd_HHmmss
$ExcelFile    = "$ReportFolder\TDIS_lockbox_status_report_$Timestamp.csv"

if (!(Test-Path $ReportFolder)) {
    New-Item -ItemType Directory -Path $ReportFolder -Force | Out-Null
}

# -------- SQL CONNECTION HELPER --------
function Get-DataTable {
    param([string]$Server, [string]$Query)
    $conn = New-Object System.Data.SqlClient.SqlConnection "Server=$Server;Database=$Database;Integrated Security=True;TrustServerCertificate=True;"
    $cmd  = $conn.CreateCommand()
    $cmd.CommandText    = $Query
    $cmd.CommandTimeout = 300
    $adapter = New-Object System.Data.SqlClient.SqlDataAdapter $cmd
    $table   = New-Object System.Data.DataTable
    try   { $adapter.Fill($table) | Out-Null }
    finally { $conn.Close() }
    return $table
}

# -------- SQL QUERY --------
# Ingest records from Monday of the current week through end of current day.
# The end-of-week boundary uses the Friday 11:59:59 PM calculation so
# weekend files are excluded. SortKey 0 = detail rows, 1 = Grand Total.
$Query = @"
;WITH BaseData AS (
    SELECT
        (SELECT sitename FROM ossite WHERE siteid = dbo.fnSiteGetCurrent()) AS ProcessingSite,
        loaddate,
        UPPER(FORMAT(LoadDate, 'ddd')) AS DayOfTheWeek,
        FileID, c.ArrivalName, b.IngestStatusName,
        ProcessedDate, BatchedDate, Duration,
        d.SiteName AS SourceSite, AppCount
    FROM [TDIS].[dbo].[Ingest] a
    JOIN osIngestStatus b ON a.IngestStatusID = b.IngestStatusID
    JOIN osArrivalType c ON a.ArrivalID = c.ArrivalID
    JOIN osSite d ON a.SourceSiteID = d.SiteID
    WHERE LoadDate BETWEEN
        DATEADD(wk, DATEDIFF(wk, 0, GETDATE()), 0)
        AND DATEADD(ms, -3, DATEADD(day, 1, CAST(DATEADD(day, DATEDIFF(day, '19000103', GETDATE()) / 7*7, '19000103') AS DATETIME)))
)
SELECT ProcessingSite, loaddate, DayOfTheWeek, FileID, ArrivalName, IngestStatusName,
       ProcessedDate, BatchedDate, Duration, SourceSite, AppCount
FROM (
    SELECT ProcessingSite, loaddate, DayOfTheWeek, FileID, ArrivalName, IngestStatusName,
           ProcessedDate, BatchedDate, Duration, SourceSite, AppCount, 0 AS SortKey
    FROM BaseData

    UNION ALL

    SELECT 'Grand Total', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, SUM(AppCount), 1
    FROM BaseData
) x
ORDER BY SortKey, loaddate, ProcessedDate, BatchedDate
"@

# -------- QUERY ALL SERVERS AND COLLECT ROWS --------
$AllRows = [System.Collections.Generic.List[PSObject]]::new()

foreach ($Server in $Servers) {
    try {
        Write-Host "Querying $Server"
        $data = Get-DataTable -Server $Server -Query $Query
        @($data) | Select-Object `
            ProcessingSite,
            @{Name='LoadDate';      Expression={ if ($null -ne $_.loaddate)      { ([datetime]$_.loaddate).ToString('yyyy-MM-dd HH:mm') }      else { '' } }},
            DayOfTheWeek, FileID, ArrivalName, IngestStatusName,
            @{Name='ProcessedDate'; Expression={ if ($null -ne $_.ProcessedDate) { ([datetime]$_.ProcessedDate).ToString('yyyy-MM-dd HH:mm') } else { '' } }},
            @{Name='BatchedDate';   Expression={ if ($null -ne $_.BatchedDate)   { ([datetime]$_.BatchedDate).ToString('yyyy-MM-dd HH:mm') }   else { '' } }},
            Duration, SourceSite, AppCount |
        ForEach-Object { $AllRows.Add($_) }
    }
    catch {
        $msg = if ($_.Exception.Message -match 'network-related|instance-specific|not found|not accessible|timed out|wait operation') {
            "connection timed out or server not reachable"
        } else { $_.Exception.Message }
        Write-Host "ERROR on $Server : $msg" -ForegroundColor Red
    }
}

# -------- EXPORT TO CSV --------
if ($AllRows.Count -gt 0) {
    $AllRows | Export-Csv -Path $ExcelFile -NoTypeInformation -Encoding UTF8
    Write-Host "CSV saved: $ExcelFile"
} else {
    Write-Host "No data returned — CSV not created." -ForegroundColor Yellow
}
