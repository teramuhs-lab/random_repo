# =============================================================================
# TDIS Completed Batches Report
# -----------------------------------------------------------------------------
# Purpose  : Queries each SQL server for batches with status Completed
#            (BatchStatusID 5) yesterday. Results are grouped by site and
#            batch type, with a Grand Total row at the end.
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
$ExcelFile    = "$ReportFolder\TDIS_completed_batches_$Timestamp.csv"

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
# Batches with status Completed (BatchStatusID 5) yesterday, grouped by site
# and batch type. SortOrder 0 = detail rows, 1 = Grand Total (sorts last).
$Query = @"
;WITH CompletedBatches AS (
    SELECT
        ost.sitecode, ost.siteName AS SiteName, bh.Stamp,
        b.BatchTypeID, bt.BatchTypeName, bh.TotalApplications
    FROM dbo.BatchHist bh WITH (NOLOCK)
    JOIN dbo.Batch b WITH (NOLOCK) ON b.BatchUID = bh.BatchUID
    JOIN dbo.osBatchType bt WITH (NOLOCK) ON bt.BatchTypeID = b.BatchTypeID
    JOIN dbo.osSite ost WITH (NOLOCK) ON ost.siteID = b.SiteID
    WHERE bh.BatchStatusID = 5 -- Completed
    AND bh.Stamp BETWEEN
        CAST(DATEADD(DAY, -1, CAST(CAST(GETDATE() AS DATE) AS DATETIME)) AS datetime)
        AND CAST(DATEADD(SECOND, -1, CAST(CAST(GETDATE() AS DATE) AS DATETIME)) AS datetime)
),
Combined AS (
    SELECT
        sitecode, SiteName, CAST(Stamp AS DATE) AS BatchDate,
        BatchTypeID, BatchTypeName,
        SUM(TotalApplications) AS TotalApps_Completed,
        0 AS SortOrder
    FROM CompletedBatches
    GROUP BY sitecode, SiteName, CAST(Stamp AS DATE), BatchTypeID, BatchTypeName

    UNION ALL

    SELECT 'Grand Total', '', NULL, NULL, '', SUM(TotalApplications), 1
    FROM CompletedBatches
)
SELECT sitecode, SiteName, BatchDate, BatchTypeID, BatchTypeName, TotalApps_Completed
FROM Combined
ORDER BY SortOrder, sitecode, SiteName, BatchDate, BatchTypeID, BatchTypeName
"@

# -------- QUERY ALL SERVERS AND COLLECT ROWS --------
$AllRows = [System.Collections.Generic.List[PSObject]]::new()

foreach ($Server in $Servers) {
    try {
        Write-Host "Querying $Server"
        $data = Get-DataTable -Server $Server -Query $Query
        @($data) | Select-Object `
            sitecode, SiteName,
            @{Name='BatchDate'; Expression={ if ($null -ne $_.BatchDate) { ([datetime]$_.BatchDate).ToString('yyyy-MM-dd') } else { '' } }},
            BatchTypeID, BatchTypeName, TotalApps_Completed |
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
