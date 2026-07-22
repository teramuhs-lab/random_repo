# =============================================================================
# TDIS Production Report (Issued Applications)
# -----------------------------------------------------------------------------
# Purpose  : Queries each SQL server for applications issued yesterday at
#            specific trace locations. Uses ROW_NUMBER to count each
#            application only once (first trace). Results are grouped by
#            site, arrival type, and location, with a Grand Total row.
# Output   : CSV saved to E:\SQLReports\Reports.
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
$ExcelFile    = "$ReportFolder\TDIS_production_report_$Timestamp.csv"

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
# Applications issued yesterday at specific trace locations.
# ROW_NUMBER partitioned by ApplicationUID keeps only the first trace per
# application to avoid double-counting.
# SortOrder 0 = detail rows, 1 = Grand Total (sorts last).
$Query = @"
DECLARE @SiteCode varchar(3)
SET @SiteCode = (SELECT SiteCode FROM dbo.osSite WHERE SiteID = dbo.fnSiteGetCurrent())

;WITH IssuedApps AS (
    SELECT
        arr.ArrivalID, arr.ArrivalName,
        t.TraceStamp AS IssuedDate,
        t.LocationID, l.LocationDesc,
        ROW_NUMBER() OVER (PARTITION BY t.ApplicationUID ORDER BY t.TraceStamp ASC) AS r_num
    FROM dbo.Trace t WITH (NOLOCK)
    JOIN dbo.[Application] a WITH (NOLOCK) ON a.ApplicationUID = t.ApplicationUID
    JOIN dbo.osArrivalType arr WITH (NOLOCK) ON arr.ArrivalID = a.ArrivalID
    JOIN dbo.osLocation l WITH (NOLOCK) ON l.LocationID = t.LocationID
    WHERE t.LocationID IN (16, 40, 42, 61, 129, 141, 151, 153, 164, 173, 179, 211, 225, 226, 227, 244)
    AND t.TraceStamp BETWEEN
        CAST(DATEADD(DAY, -1, CAST(CAST(GETDATE() AS DATE) AS DATETIME)) AS datetime)
        AND CAST(DATEADD(SECOND, -1, CAST(CAST(GETDATE() AS DATE) AS DATETIME)) AS datetime)
),
FilteredApps AS (
    SELECT * FROM IssuedApps WHERE r_num = 1
)
SELECT SiteCode, ArrivalID, ArrivalName, IssuedDate, LocationID, LocationDesc, Application_Count
FROM (
    SELECT
        @SiteCode AS SiteCode,
        ArrivalID, ArrivalName,
        CAST(IssuedDate AS DATE) AS IssuedDate,
        LocationID, LocationDesc,
        COUNT(*) AS Application_Count,
        0 AS SortOrder
    FROM FilteredApps
    GROUP BY ArrivalID, ArrivalName, CAST(IssuedDate AS DATE), LocationID, LocationDesc

    UNION ALL

    SELECT 'Grand Total', NULL, '', NULL, NULL, '', COUNT(*), 1
    FROM FilteredApps
) x
ORDER BY SortOrder, SiteCode, ArrivalID, LocationID
"@

# -------- QUERY ALL SERVERS AND COLLECT ROWS --------
$AllRows = [System.Collections.Generic.List[PSObject]]::new()

foreach ($Server in $Servers) {
    try {
        Write-Host "Querying $Server"
        $data = Get-DataTable -Server $Server -Query $Query
        @($data) | Select-Object `
            SiteCode, ArrivalID, ArrivalName,
            @{Name='IssuedDate'; Expression={ if ($null -ne $_.IssuedDate) { ([datetime]$_.IssuedDate).ToString('yyyy-MM-dd') } else { '' } }},
            LocationID, LocationDesc, Application_Count |
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
