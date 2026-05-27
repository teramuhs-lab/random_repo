# =============================================================================
# TDIS Printed Products Report
# -----------------------------------------------------------------------------
# Purpose  : Queries each SQL server for product inventory records with
#            ProductTrace status Printed (StatusID 6) yesterday. Results are
#            grouped by site, arrival type, and product type, with a Grand
#            Total row at the end.
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
$ExcelFile    = "$ReportFolder\TDIS_printed_products_report_$Timestamp.csv"

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
# Products with ProductTrace status Printed (StatusID 6) yesterday.
# ProductData join (ProductDataRS = 1) selects only the primary data record
# to avoid duplicate rows when multiple data records exist per product.
# SortOrder 0 = detail rows, 1 = Grand Total (sorts last).
$Query = @"
SELECT sitecode, SiteName, ProductPrintDate, ArrivalID, ArrivalName, ProductType, TotalProductPrinted
FROM (
    SELECT
        ost.sitecode, ost.siteName AS SiteName,
        CAST(pt.TraceStamp AS DATE) AS ProductPrintDate,
        arrival.ArrivalID, arrival.ArrivalName, p.ProductType,
        COUNT(*) AS TotalProductPrinted, 0 AS SortOrder
    FROM dbo.ProductInventory p WITH (NOLOCK)
    JOIN dbo.ProductTrace pt WITH (NOLOCK) ON pt.InventoryUID = p.InventoryUID
    JOIN dbo.ProductData pd WITH (NOLOCK) ON pd.ProductDataRS = 1 AND pd.InventoryUID = p.InventoryUID
    JOIN dbo.[Application] a WITH (NOLOCK) ON a.ApplicationUID = pd.ApplicationUID
    JOIN dbo.osArrivalType arrival WITH (NOLOCK) ON arrival.ArrivalID = a.ArrivalID
    JOIN dbo.osSite ost WITH (NOLOCK) ON ost.siteID = a.BeingProcessedBy
    WHERE pt.StatusID = 6 -- Printed
    AND pt.TraceStamp BETWEEN
        CAST(DATEADD(DAY, -1, CAST(CAST(GETDATE() AS DATE) AS DATETIME)) AS datetime)
        AND CAST(DATEADD(SECOND, -1, CAST(CAST(GETDATE() AS DATE) AS DATETIME)) AS datetime)
    GROUP BY ost.SiteCode, ost.SiteName, CAST(pt.TraceStamp AS DATE),
        arrival.ArrivalID, arrival.ArrivalName, p.ProductType

    UNION ALL

    SELECT 'Grand Total', '', NULL, NULL, '', '', COUNT(*), 1
    FROM dbo.ProductInventory p WITH (NOLOCK)
    JOIN dbo.ProductTrace pt WITH (NOLOCK) ON pt.InventoryUID = p.InventoryUID
    WHERE pt.StatusID = 6
    AND pt.TraceStamp BETWEEN
        CAST(DATEADD(DAY, -1, CAST(CAST(GETDATE() AS DATE) AS DATETIME)) AS datetime)
        AND CAST(DATEADD(SECOND, -1, CAST(CAST(GETDATE() AS DATE) AS DATETIME)) AS datetime)
) x
ORDER BY SortOrder, sitecode, SiteName, ProductPrintDate, ArrivalID, ProductType
"@

# -------- QUERY ALL SERVERS AND COLLECT ROWS --------
$AllRows = [System.Collections.Generic.List[PSObject]]::new()

foreach ($Server in $Servers) {
    try {
        Write-Host "Querying $Server"
        $data = Get-DataTable -Server $Server -Query $Query
        @($data) | Select-Object `
            sitecode, SiteName,
            @{Name='ProductPrintDate'; Expression={ if ($null -ne $_.ProductPrintDate) { ([datetime]$_.ProductPrintDate).ToString('yyyy-MM-dd') } else { '' } }},
            ArrivalID, ArrivalName, ProductType, TotalProductPrinted |
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
