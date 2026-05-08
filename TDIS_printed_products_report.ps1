# ============================================
# SIMPLE TDIS REPORT
# MULTI-SERVER HTML EMAIL BODY + HTML ATTACHMENT
# Shows only 3 columns in HTML report
# ============================================

# -------- CONFIGURATION --------
$Servers = @(
    "PNPCODWFDBSLE,1443",
    "PSEAODWCSQLVE\CAPPT",
    "PLAAODWFDBSLE,1443",
    "PWPCODWCSQLVE\CAPPT",
    "PMMAODWFDBSLE,1443",
    "PMNAODWFDBSLE,1443"
)

$Database = "TDIS"

$From = "TDIS_printed_products@state.gov"
$To = "teramuh1@state.gov"
$SmtpServer = "carelay.ca.state.sbu"

# -------- REPORT FILE LOCATION --------
$ReportFolder = "E:\SQLReports\printed_products"
$Timestamp    = Get-Date -Format yyyyMMdd_HHmmss
$HtmlFile     = "$ReportFolder\TDIS_printed_products_report_$Timestamp.html"
$ExcelFile    = "$ReportFolder\TDIS_printed_products_report_$Timestamp.csv"

# Create report folder if it does not exist
if (!(Test-Path $ReportFolder)) {
    New-Item -ItemType Directory -Path $ReportFolder -Force | Out-Null
}

# -------- FUNCTION: CONVERT DATATABLE TO HTML OR "NO RECORDS" MESSAGE --------
function ConvertTo-HtmlSection {
    param($Table)

    # An empty DataTable is enumerated to $null by PowerShell on function return
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

# -------- FUNCTION: RUN SQL QUERY AGAINST ONE SERVER --------
function Get-DataTable {
    param(
        [string]$Server,
        [string]$Query
    )

    # Build connection string for the current server
    $ConnectionString = "Server=$Server;Database=$Database;Integrated Security=True;TrustServerCertificate=True;"

    # Create SQL connection
    $Connection = New-Object System.Data.SqlClient.SqlConnection $ConnectionString
    $Command = $Connection.CreateCommand()
    $Command.CommandText = $Query
    $Command.CommandTimeout = 300

    # Prepare table to store SQL results
    $Adapter = New-Object System.Data.SqlClient.SqlDataAdapter $Command
    $Table = New-Object System.Data.DataTable

    try {
        # Execute query and fill table
        $Adapter.Fill($Table) | Out-Null
    }
    finally {
        # Always close SQL connection
        $Connection.Close()
    }

    return $Table
}

# -------- COMMON DATE LOGIC --------
$DateLogic = @"
DECLARE @StartDate datetime;
DECLARE @EndDate datetime;

-- Beginning of current week, Monday
SET @StartDate = DATEADD(WEEK, DATEDIFF(WEEK, 0, GETDATE()), 0);

-- Last second of current year
SET @EndDate = DATEADD(SECOND, -1, DATEADD(YEAR, DATEDIFF(YEAR, 0, GETDATE()) + 1, 0));
"@

# -------- QUERY 1: LOADED DATE --------
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


# -------- START HTML REPORT --------
$ReportSections = ""
$AllRows = [System.Collections.Generic.List[PSObject]]::new()

# -------- RUN REPORT FOR EACH SERVER --------
foreach ($Server in $Servers) {

    try {
        Write-Host "Running report for server: $Server"

        # Run SQL query against current server
        $Loaded = Get-DataTable -Server $Server -Query $LoadedQuery

        # Collect rows for Excel export
        @($Loaded) | Select-Object `
            sitecode, SiteName,
            @{Name='ProductPrintDate'; Expression={ if ($null -ne $_.ProductPrintDate) { ([datetime]$_.ProductPrintDate).ToString('yyyy-MM-dd') } else { '' } }},
            ArrivalID, ArrivalName, ProductType, TotalProductPrinted |
        ForEach-Object { $AllRows.Add($_) }

        # Convert results to HTML, or emit a "no records" message if empty
        $LoadedHtml = ConvertTo-HtmlSection -Table $Loaded

        # Add this server's report section
        $ReportSections += @"
<h1></h1>

$LoadedHtml

<hr>
"@
    }
    catch {
        # If one server fails, continue with the next server
        $ErrorMessage = $_.Exception.Message

        $ReportSections += @"
<h1>Server: $Server</h1>
<p style="color:red;"><b>Error:</b> $ErrorMessage</p>
<hr>
"@
    }
}

# -------- SAVE EXCEL (CSV) REPORT --------
if ($AllRows.Count -gt 0) {
    $AllRows | Export-Csv -Path $ExcelFile -NoTypeInformation -Encoding UTF8
}

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

# -------- SEND EMAIL WITH HTML BODY AND HTML ATTACHMENT --------
$Attachments = @($HtmlFile)
if (Test-Path $ExcelFile) { $Attachments += $ExcelFile }

Send-MailMessage `
    -From $From `
    -To $To `
    -Subject "TDIS Printed Products" `
    -Body $Html `
    -BodyAsHtml `
    -SmtpServer $SmtpServer `
    -Attachments $Attachments

# -------- DONE --------
Write-Host "Report sent successfully!"
Write-Host "HTML attachment: $HtmlFile"
Write-Host "Excel attachment: $ExcelFile"