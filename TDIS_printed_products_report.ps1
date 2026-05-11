# =============================================================================
# TDIS Printed Products Report
# -----------------------------------------------------------------------------
# Purpose  : Queries the TDIS ProductInventory/ProductTrace tables on each SQL
#            server for products with status 'Printed' (StatusID 6) during
#            yesterday. Results are grouped by site, arrival type, and product
#            type, with a Grand Total row appended at the end.
# Output   : CSV file saved to E:\SQLReports\printed_products and emailed as
#            an attachment. One file is produced per run, timestamped.
# Schedule : Intended to run daily via Windows Task Scheduler.
# Note     : HTML report output is available but currently disabled.
#            To re-enable, uncomment all <# HTML report - commented out #>
#            blocks and the $HtmlFile variable below.
# =============================================================================

# -------- SMTP AND DATABASE SETTINGS --------
$Servers = @(
    "PNPCODWFDBSLE,1443",
    "PSEAODWCSQLVE\CAPPT",
    "PLAAODWFDBSLE,1443",
    "PWPCODWCSQLVE\CAPPT",
    "PMMAODWFDBSLE,1443",
    "PMNAODWFDBSLE,1443"
)

$Database   = "TDIS"
$From       = "TDIS_printed_products@state.gov"
$To         = "teramuh1@state.gov"
$SmtpServer = "carelay.ca.state.sbu"

# -------- OUTPUT FILE PATHS --------
# $Timestamp ensures each run produces a unique, non-overwriting file name.
$ReportFolder = "E:\SQLReports\printed_products"
$Timestamp    = Get-Date -Format yyyyMMdd_HHmmss
#$HtmlFile     = "$ReportFolder\TDIS_printed_products_report_$Timestamp.html"   # HTML output (disabled)
$ExcelFile    = "$ReportFolder\TDIS_printed_products_report_$Timestamp.csv"

# Create the output folder if it does not already exist
if (!(Test-Path $ReportFolder)) {
    New-Item -ItemType Directory -Path $ReportFolder -Force | Out-Null
}

# -------- FUNCTION: ConvertTo-HtmlSection [RESERVED - HTML OUTPUT DISABLED] --------
# Converts a DataTable to an HTML table fragment.
# DBNull date values are rendered as empty strings to avoid cast errors.
# Uncomment the HTML report blocks below to use this function.
function ConvertTo-HtmlSection {
    param($Table)

    if ($null -eq $Table) {
        return '<p style="color:#888888; font-style:italic;">No records found for this period.</p>'
    }

    $rowCount = if ($Table -is [System.Data.DataTable]) { $Table.Rows.Count } else { @($Table).Count }

    if ($rowCount -eq 0) {
        return '<p style="color:#888888; font-style:italic;">No records found for this period.</p>'
    }

    return @($Table) |
        Select-Object sitecode, SiteName,
            @{Name='ProductPrintDate'; Expression={ if ($null -ne $_.ProductPrintDate) { ([datetime]$_.ProductPrintDate).ToString('yyyy-MM-dd') } else { '' } }},
            ArrivalID, ArrivalName, ProductType, TotalProductPrinted |
        ConvertTo-Html -Fragment
}

# -------- FUNCTION: Get-DataTable --------
# Opens a SQL connection to the given server, executes the query, and returns
# the results as a DataTable. The connection is always closed in the finally block.
function Get-DataTable {
    param(
        [string]$Server,
        [string]$Query
    )

    $ConnectionString = "Server=$Server;Database=$Database;Integrated Security=True;TrustServerCertificate=True;"
    $Connection = New-Object System.Data.SqlClient.SqlConnection $ConnectionString
    $Command = $Connection.CreateCommand()
    $Command.CommandText = $Query
    $Command.CommandTimeout = 300

    $Adapter = New-Object System.Data.SqlClient.SqlDataAdapter $Command
    $Table   = New-Object System.Data.DataTable

    try {
        $Adapter.Fill($Table) | Out-Null
    }
    finally {
        $Connection.Close()
    }

    return $Table
}

# -------- SHARED SQL DATE VARIABLES --------
# Declares @StartDate and @EndDate T-SQL variables that are injected into
# $LoadedQuery at runtime. They are available within the query but the
# yesterday-window filter is applied directly in the WHERE clause.
$DateLogic = @"
DECLARE @StartDate datetime;
DECLARE @EndDate datetime;

-- Beginning of current week, Monday
SET @StartDate = DATEADD(WEEK, DATEDIFF(WEEK, 0, GETDATE()), 0);

-- Last second of current year
SET @EndDate = DATEADD(SECOND, -1, DATEADD(YEAR, DATEDIFF(YEAR, 0, GETDATE()) + 1, 0));
"@

# -------- SQL QUERY: PRINTED PRODUCTS --------
# Returns all product inventory records with ProductTrace status 'Printed'
# (StatusID 6) from yesterday, grouped by site, arrival type, and product type.
# ProductData join (ProductDataRS = 1) selects only the primary data record.
# A Grand Total row counting all printed products is appended last.
# SortOrder 0 = detail rows; SortOrder 1 = Grand Total (always last).
$LoadedQuery = @"
$DateLogic

SELECT sitecode, SiteName, ProductPrintDate, ArrivalID, ArrivalName, ProductType, TotalProductPrinted
FROM (
    SELECT ost.sitecode, ost.siteName AS SiteName, CAST(pt.TraceStamp AS DATE) AS ProductPrintDate,
        arrival.ArrivalID, arrival.ArrivalName, p.ProductType, COUNT(*) AS TotalProductPrinted, 0 AS SortOrder
    FROM dbo.ProductInventory p WITH (NOLOCK)
    JOIN dbo.ProductTrace pt WITH (NOLOCK) ON pt.InventoryUID = p.InventoryUID
    JOIN dbo.osProductStatus ps WITH (NOLOCK) ON ps.StatusID = pt.StatusID
    JOIN dbo.ProductData pd WITH (NOLOCK) ON pd.ProductDataRS = 1 AND pd.InventoryUID = p.InventoryUID
    JOIN dbo.[Application] a WITH (NOLOCK) ON a.ApplicationUID = pd.ApplicationUID
    JOIN dbo.osArrivalType arrival WITH (NOLOCK) ON arrival.ArrivalID = a.ArrivalID
    JOIN dbo.osSite ost WITH (NOLOCK) ON ost.siteID = a.BeingProcessedBy
    WHERE pt.StatusID = 6 -- 6 Printed
    AND (pt.TraceStamp BETWEEN
        CAST(DATEADD(DAY, -1, CAST(CAST(GETDATE() AS DATE) AS DATETIME)) AS datetime) AND
        CAST(DATEADD(SECOND, -1, CAST(CAST(GETDATE() AS DATE) AS DATETIME)) AS datetime))
    GROUP BY ost.SiteCode, ost.SiteName, CAST(pt.TraceStamp AS DATE), arrival.ArrivalID, arrival.ArrivalName, p.ProductType

    UNION ALL

    SELECT 'Grand Total', '', NULL, NULL, '', '', COUNT(*), 1
    FROM dbo.ProductInventory p WITH (NOLOCK)
    JOIN dbo.ProductTrace pt WITH (NOLOCK) ON pt.InventoryUID = p.InventoryUID
    WHERE pt.StatusID = 6
    AND (pt.TraceStamp BETWEEN
        CAST(DATEADD(DAY, -1, CAST(CAST(GETDATE() AS DATE) AS DATETIME)) AS datetime) AND
        CAST(DATEADD(SECOND, -1, CAST(CAST(GETDATE() AS DATE) AS DATETIME)) AS datetime))
) x
ORDER BY SortOrder, sitecode, SiteName, ProductPrintDate, ArrivalID, ProductType
"@

# -------- INITIALIZE ROW COLLECTION FOR EXCEL EXPORT --------
# $AllRows accumulates results from all servers into a single list
# so they can be written to one combined CSV file.
#$ReportSections = ""   # reserved for HTML output (disabled)
$AllRows       = [System.Collections.Generic.List[PSObject]]::new()
$FailedServers = [System.Collections.Generic.List[string]]::new()

# -------- QUERY EACH SERVER AND COLLECT ROWS --------
foreach ($Server in $Servers) {

    try {
        Write-Host "Querying server: $Server"

        # Execute the printed products query against this server
        $Loaded = Get-DataTable -Server $Server -Query $LoadedQuery

        # Project and format columns for the CSV; NULL dates become empty strings
        @($Loaded) | Select-Object `
            sitecode, SiteName,
            @{Name='ProductPrintDate'; Expression={ if ($null -ne $_.ProductPrintDate) { ([datetime]$_.ProductPrintDate).ToString('yyyy-MM-dd') } else { '' } }},
            ArrivalID, ArrivalName, ProductType, TotalProductPrinted |
        ForEach-Object { $AllRows.Add($_) }

        <# HTML report - commented out
        # Convert results to HTML, or emit a "no records" message if empty
        $LoadedHtml = ConvertTo-HtmlSection -Table $Loaded

        # Add this server's report section
        $ReportSections += @"
<h1></h1>

$LoadedHtml

<hr>
"@
        #>
    }
    catch {
        $ErrMsg = if ($_.Exception.Message -match 'network-related|instance-specific|not found|not accessible|timed out|wait operation') {
            "connection timed out or server not reachable"
        } else {
            $_.Exception.Message
        }
        Write-Host "ERROR on server $Server : $ErrMsg" -ForegroundColor Red
        $FailedServers.Add("  $Server — $ErrMsg")

        <# HTML report - commented out
        $ReportSections += @"
<h1>Server: $Server</h1>
<p style="color:red;"><b>Error:</b> $ErrorMessage</p>
<hr>
"@
        #>
    }
}

# -------- EXPORT COLLECTED ROWS TO CSV --------
# Skips export if no rows were returned from any server
if ($AllRows.Count -gt 0) {
    $AllRows | Export-Csv -Path $ExcelFile -NoTypeInformation -Encoding UTF8
}

<# HTML report - commented out
# -------- BUILD FINAL HTML REPORT --------
$Html = @"
<html>
<head>
<style>
body {
    font-family: Arial;
    font-size: 14px;
}

h1 {
    color: #333333;
    margin-top: 30px;
}

h2 {
    color: #555555;
    margin-top: 25px;
}

table {
    border-collapse: collapse;
    width: 70%;
    margin-bottom: 20px;
}

th {
    background-color: #333333;
    color: white;
    padding: 6px;
    text-align: left;
}

td {
    border: 1px solid #cccccc;
    padding: 6px;
}

tr:nth-child(even) {
    background-color: #f2f2f2;
}

hr {
    margin-top: 35px;
    margin-bottom: 35px;
}
</style>
</head>

<body>

<h1>Printed Products</h1>
<p><b>Generated:</b> $(Get-Date -Format "yyyy-MM-dd HH:mm:ss")</p>

$ReportSections

</body>
</html>
"@

# -------- SAVE HTML REPORT AS ATTACHMENT --------
$Html | Out-File -FilePath $HtmlFile -Encoding UTF8
#>

# -------- BUILD EMAIL BODY AND ATTACHMENTS --------
$Body = if ($AllRows.Count -gt 0) { "Please find the Excel report attached." } else { "No data was returned for this period." }
if ($FailedServers.Count -gt 0) {
    $Body += "`r`n`r`nThe following servers could not be reached:`r`n" + ($FailedServers -join "`r`n")
}

$Attachments = @()
if (Test-Path $ExcelFile) { $Attachments += $ExcelFile }

# -------- SEND EMAIL --------
$MailParams = @{
    From       = $From
    To         = $To
    Subject    = "TDIS Printed Products"
    Body       = $Body
    SmtpServer = $SmtpServer
}
if ($Attachments.Count -gt 0) { $MailParams['Attachments'] = $Attachments }
Send-MailMessage @MailParams

Write-Host "Report sent successfully!"
if ($Attachments.Count -gt 0) { Write-Host "Excel attachment: $ExcelFile" }
