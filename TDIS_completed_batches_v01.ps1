# =============================================================================
# TDIS Completed Batches Report
# -----------------------------------------------------------------------------
# Purpose  : Queries the TDIS database on each SQL server for batches with
#            status 'Completed' (BatchStatusID 5) during yesterday. Results
#            are grouped by site and batch type, with a Grand Total row
#            appended at the end.
# Output   : CSV file saved to E:\SQLReports\completed_batches and emailed
#            as an attachment. One file is produced per run, timestamped.
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
    "PWPCODWFDBSLE,1443",
    "PMMAODWFDBSLE,1443",
    "PMNAODWFDBSLE,1443"
)

$Database   = "TDIS"
$From       = "TDIS_completed_batches_report@state.gov"
$To         = "teramuh1@state.gov"
$SmtpServer = "carelay.ca.state.sbu"

# -------- OUTPUT FILE PATHS --------
# $Timestamp ensures each run produces a unique, non-overwriting file name.
$ReportFolder = "E:\SQLReports\completed_batches"
$Timestamp    = Get-Date -Format yyyyMMdd_HHmmss
#$HtmlFile     = "$ReportFolder\TDIS_completed_batches_$Timestamp.html"   # HTML output (disabled)
$ExcelFile    = "$ReportFolder\TDIS_completed_batches_$Timestamp.csv"

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
            @{Name='BatchDate'; Expression={ if ($null -ne $_.BatchDate) { ([datetime]$_.BatchDate).ToString('yyyy-MM-dd') } else { '' } }},
            BatchTypeID, BatchTypeName, TotalApps_Completed |
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

# -------- SQL QUERY: COMPLETED BATCHES --------
# Returns all batches with status 'Completed' (BatchStatusID 5) from yesterday,
# grouped by site and batch type, with a Grand Total row appended.
# SortOrder 0 = detail rows; SortOrder 1 = Grand Total (always last).
$LoadedQuery = @"
$DateLogic

WITH CompletedBatches AS(
SELECT
 ost.sitecode, ost.siteName as SiteName, bh.Stamp, b.BatchTypeID, bt.BatchTypeName, bh.TotalApplications
FROM dbo.BatchHist bh WITH (NOLOCK)
JOIN dbo.Batch b WITH (NOLOCK) on b.BatchUID = bh.BatchUID
JOIN dbo.osBatchType bt WITH (NOLOCK) on bt.BatchTypeID = b.BatchTypeID
JOIN dbo.osSite ost WITH (NOLOCK) on ost.siteID = b.SiteID
WHERE 1=1
AND (bh.Stamp BETWEEN CAST(DATEADD(DAY, -1, CAST(CAST(GETDATE() AS DATE) AS DATETIME)) AS datetime)
AND CAST(DATEADD(SECOND, -1, CAST(CAST(GETDATE() AS DATE) AS DATETIME)) AS datetime))
AND bh.BatchStatusID = 5), -- 'Completed'
Combined AS (
    SELECT c.sitecode, c.SiteName, CAST(c.Stamp AS DATE) AS BatchDate, c.BatchTypeID, c.BatchTypeName,
        SUM(c.TotalApplications) AS [TotalApps_Completed], 0 AS SortOrder
    FROM CompletedBatches c
    GROUP BY c.sitecode, c.SiteName, CAST(c.Stamp AS DATE), c.BatchTypeID, c.BatchTypeName

    UNION ALL

    SELECT 'Grand Total', '', NULL, NULL, '', SUM(TotalApplications), 1
    FROM CompletedBatches
)
SELECT sitecode, SiteName, BatchDate, BatchTypeID, BatchTypeName, TotalApps_Completed
FROM Combined
ORDER BY SortOrder, sitecode, SiteName, BatchDate, BatchTypeID, BatchTypeName
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

        # Execute the completed batches query against this server
        $Loaded = Get-DataTable -Server $Server -Query $LoadedQuery

        # Project and format columns for the CSV; NULL dates become empty strings
        @($Loaded) | Select-Object `
            sitecode, SiteName,
            @{Name='BatchDate'; Expression={ if ($null -ne $_.BatchDate) { ([datetime]$_.BatchDate).ToString('yyyy-MM-dd') } else { '' } }},
            BatchTypeID, BatchTypeName, TotalApps_Completed |
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

<h1>Completed Batches</h1>
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
    Subject    = "TDIS Completed Batches"
    Body       = $Body
    SmtpServer = $SmtpServer
}
if ($Attachments.Count -gt 0) { $MailParams['Attachments'] = $Attachments }
Send-MailMessage @MailParams

Write-Host "Report sent successfully!"
if ($Attachments.Count -gt 0) { Write-Host "Excel attachment: $ExcelFile" }
