# =============================================================================
# TDIS Applications Not Issued Report
# -----------------------------------------------------------------------------
# Purpose  : Queries each SQL server for applications traced to NOT ISSUED
#            (LocationID 1) or NOT ISSUED CARD (LocationID 170) yesterday.
#            Results are grouped by site, location, arrival type, and form
#            type, with a Grand Total row at the end.
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
$ExcelFile    = "$ReportFolder\TDIS_applications_not_issued_report_$Timestamp.csv"

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
# Applications traced to NOT ISSUED (1) or NOT ISSUED CARD (170) yesterday.
# FormName strips the leading "DS- " prefix via SUBSTRING from character 5.
# SortOrder 0 = detail rows, 1 = Grand Total (sorts last).
$Query = @"
SELECT sitecode, SiteName, NotIssuedDate, LocationDesc, ArrivalID, ArrivalName, FormName, TotalApps_NotIssued
FROM (
    SELECT
        ost.sitecode, ost.siteName AS SiteName,
        CAST(t.TraceStamp AS DATE) AS NotIssuedDate,
        l.LocationDesc, arrival.ArrivalID, arrival.ArrivalName,
        SUBSTRING(f.FormName, 5, LEN(f.FormName)) AS FormName,
        COUNT(*) AS TotalApps_NotIssued, 0 AS SortOrder
    FROM dbo.Trace t WITH (NOLOCK)
    JOIN dbo.[Application] a WITH (NOLOCK) ON a.ApplicationUID = t.ApplicationUID
    JOIN dbo.[osArrivalType] arrival WITH (NOLOCK) ON arrival.ArrivalID = a.ArrivalID
    JOIN dbo.[osLocation] l WITH (NOLOCK) ON l.LocationID = t.LocationID
    JOIN dbo.[osFormType] f WITH (NOLOCK) ON f.FormID = a.FormID
    JOIN dbo.osSite ost WITH (NOLOCK) ON ost.siteID = a.BeingProcessedBy
    WHERE t.LocationID IN (1, 170) -- 1 NOT ISSUED, 170 NOT ISSUED CARD
    AND t.TraceStamp BETWEEN
        CAST(DATEADD(DAY, -1, CAST(CAST(GETDATE() AS DATE) AS DATETIME)) AS datetime)
        AND CAST(DATEADD(SECOND, -1, CAST(CAST(GETDATE() AS DATE) AS DATETIME)) AS datetime)
    GROUP BY ost.SiteCode, ost.SiteName, CAST(t.TraceStamp AS DATE),
        l.LocationDesc, arrival.ArrivalID, arrival.ArrivalName,
        SUBSTRING(f.FormName, 5, LEN(f.FormName))

    UNION ALL

    SELECT 'Grand Total', '', NULL, '', NULL, '', '', COUNT(*), 1
    FROM dbo.Trace t WITH (NOLOCK)
    WHERE t.LocationID IN (1, 170)
    AND t.TraceStamp BETWEEN
        CAST(DATEADD(DAY, -1, CAST(CAST(GETDATE() AS DATE) AS DATETIME)) AS datetime)
        AND CAST(DATEADD(SECOND, -1, CAST(CAST(GETDATE() AS DATE) AS DATETIME)) AS datetime)
) x
ORDER BY SortOrder, sitecode, SiteName, NotIssuedDate, LocationDesc, ArrivalID, FormName
"@

# -------- QUERY ALL SERVERS AND COLLECT ROWS --------
$AllRows = [System.Collections.Generic.List[PSObject]]::new()

foreach ($Server in $Servers) {
    try {
        Write-Host "Querying $Server"
        $data = Get-DataTable -Server $Server -Query $Query
        @($data) | Select-Object `
            sitecode, SiteName,
            @{Name='NotIssuedDate'; Expression={ if ($null -ne $_.NotIssuedDate) { ([datetime]$_.NotIssuedDate).ToString('yyyy-MM-dd') } else { '' } }},
            LocationDesc, ArrivalID, ArrivalName, FormName, TotalApps_NotIssued |
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
