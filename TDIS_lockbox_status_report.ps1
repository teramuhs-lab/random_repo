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

$From = "TDIS_completed_batches_report@state.gov"
$To = "teramuh1@state.gov"
$SmtpServer = "carelay.ca.state.sbu"

# -------- REPORT FILE LOCATION --------
$ReportFolder = "E:\SQLReports\lockbox_status"
$Timestamp    = Get-Date -Format yyyyMMdd_HHmmss
$HtmlFile     = "$ReportFolder\TDIS_lockbox_status_report_$Timestamp.html"
$ExcelFile    = "$ReportFolder\TDIS_lockbox_status_report_$Timestamp.csv"

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
        Select-Object ProcessingSite,
            @{Name='LoadDate';       Expression={ if ($null -ne $_.loaddate)      { ([datetime]$_.loaddate).ToString('yyyy-MM-dd HH:mm') }      else { '' } }},
            DayOfTheWeek, FileID, ArrivalName, IngestStatusName,
            @{Name='ProcessedDate'; Expression={ if ($null -ne $_.ProcessedDate) { ([datetime]$_.ProcessedDate).ToString('yyyy-MM-dd HH:mm') } else { '' } }},
            @{Name='BatchedDate';   Expression={ if ($null -ne $_.BatchedDate)   { ([datetime]$_.BatchedDate).ToString('yyyy-MM-dd HH:mm') }   else { '' } }},
            Duration, SourceSite, AppCount |
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

;WITH BaseData AS (
    SELECT
        (SELECT sitename FROM ossite WHERE siteid = dbo.fnSiteGetCurrent()) AS ProcessingSite,
        loaddate,
        UPPER(FORMAT(LoadDate, 'ddd')) AS DayOfTheWeek,
        FileID, c.ArrivalName, b.IngestStatusName, ProcessedDate, BatchedDate, Duration,
        d.SiteName AS SourceSite, AppCount
    FROM [TDIS].[dbo].[Ingest] a, osIngestStatus b, osArrivalType c, osSite d
    WHERE a.IngestStatusID = b.IngestStatusID
    AND a.ArrivalID = c.ArrivalID
    AND a.SourceSiteID = d.SiteID
    AND LoadDate BETWEEN DATEADD(wk, DATEDIFF(wk, 0, GETDATE()), 0)
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
            ProcessingSite,
            @{Name='LoadDate';       Expression={ if ($null -ne $_.loaddate)      { ([datetime]$_.loaddate).ToString('yyyy-MM-dd HH:mm') }      else { '' } }},
            DayOfTheWeek, FileID, ArrivalName, IngestStatusName,
            @{Name='ProcessedDate'; Expression={ if ($null -ne $_.ProcessedDate) { ([datetime]$_.ProcessedDate).ToString('yyyy-MM-dd HH:mm') } else { '' } }},
            @{Name='BatchedDate';   Expression={ if ($null -ne $_.BatchedDate)   { ([datetime]$_.BatchedDate).ToString('yyyy-MM-dd HH:mm') }   else { '' } }},
            Duration, SourceSite, AppCount |
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
<h1></h1>
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

<h1>Lockbox Status</h1>
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
    -Subject "TDIS Lockbox Status" `
    -Body $Html `
    -BodyAsHtml `
    -SmtpServer $SmtpServer `
    -Attachments $Attachments

# -------- DONE --------
Write-Host "Report sent successfully!"
Write-Host "HTML attachment: $HtmlFile"
Write-Host "Excel attachment: $ExcelFile"
