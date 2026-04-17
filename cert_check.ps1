<#
    This script scans a list of servers for SSL certificates, filters them to the issuer you care about, checks how many days remain before expiration, builds an HTML report, writes a log, and emails the results.

    In general, it does this:

    Reads configuration from the parameters at the top:
    server list file, log file, report file, expiration threshold, SMTP settings, recipients, issuer pattern, and certificate stores.

    Loads the server names from all_cert_server_list.txt, ignoring blank lines and lines starting with #.

    For each server:
    tests whether the server is reachable,
    remotely queries the configured certificate stores,
    filters certificates whose Issuer matches the configured pattern,
    calculates days until expiration,
    records matching certificates,
    tracks unreachable servers,
    tracks servers where no matching issuer was found.

    Builds an HTML report showing:
    certificates that are expired or within the threshold,
    servers that could not be reached,
    servers that had certificates but none matching the issuer filter.

    Saves the HTML report to disk and writes detailed events to the log file.

    Sends an email with:
    the HTML report as the email body,
    the log file attached,
    a subject that changes depending on whether expiring certificates were found.

    A few important notes about this script:

    DaysRemaining = 3000 means it currently flags almost any certificate expiring within about 8 years, which is probably much higher than intended.
    It only reports certificates whose issuer matches IssuerPattern.
    It checks these stores by default:
    Cert:\LocalMachine\My
    Cert:\LocalMachine\WebHosting
#>

param(
    [string]$ServerListPath = 'D:\scripts\cert_check\all_cert_server_list.txt',
    [string]$LogFile = 'D:\scripts\cert_check\log.txt',
    [string]$ReportFile = 'D:\scripts\cert_check\cert_report.html',
    [int]$DaysRemaining = 3000,
    [string]$SmtpServer = 'carelay.ca.state.sbu',
    [int]$SmtpPort = 25,
    [string]$From = 'eio-sql-server-monitoring@state.gov',
    [string[]]$To = @('TeramuH1@state.gov'),
    [string[]]$IssuerPattern = @(
        '*CN=U.S. Department of State NPE03 Sub CA, OU=Certification Authorities, OU=Department of State, O=U.S. Government, C=US*'
    ),
    [string[]]$CertificateStores = @(
        'Cert:\LocalMachine\My',
        'Cert:\LocalMachine\WebHosting'
    )
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-Log {
    # Appends a timestamped entry to the configured log file.
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message
    )

    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    Add-Content -Path $LogFile -Value "[$timestamp] $Message"
}

function Get-ServerCertificates {
    # Queries the requested certificate stores on a remote server and returns certificate details.
    param(
        [Parameter(Mandatory = $true)]
        [string]$ComputerName,
        [Parameter(Mandatory = $true)]
        [string[]]$StorePaths
    )

    Invoke-Command -ComputerName $ComputerName -ArgumentList (, $StorePaths) -ErrorAction Stop -ScriptBlock {
        param(
            [string[]]$RemoteStorePaths
        )

        foreach ($storePath in $RemoteStorePaths) {
            if (Test-Path -Path $storePath) {
                Get-ChildItem -Path $storePath |
                    Select-Object PSComputerName, Subject, Issuer, NotAfter, Thumbprint,
                        @{ Name = 'StorePath'; Expression = { $storePath } }
            }
        }
    }
}

function New-ServerStatusRecord {
    # Creates a consistent status object for summary/report output.
    param(
        [Parameter(Mandatory = $true)]
        [string]$Server,
        [Parameter(Mandatory = $true)]
        [string]$Status,
        [Parameter(Mandatory = $true)]
        [int]$CertificateCount,
        [Parameter(Mandatory = $true)]
        [int]$MatchingCertificateCount,
        [Parameter(Mandatory = $true)]
        [int]$ExpiringCertificateCount,
        [Nullable[datetime]]$ExpirationDate,
        [Nullable[int]]$DaysUntilExpiration,
        [string]$Issuer = '',
        [Parameter(Mandatory = $true)]
        [string]$Detail
    )

    [pscustomobject]@{
        Server                   = $Server
        Status                   = $Status
        CertificateCount         = $CertificateCount
        MatchingCertificateCount = $MatchingCertificateCount
        ExpiringCertificateCount = $ExpiringCertificateCount
        ExpirationDate           = $ExpirationDate
        DaysUntilExpiration      = $DaysUntilExpiration
        Issuer                   = $Issuer
        Detail                   = $Detail
    }
}

function New-ReportBody {
    # Builds the HTML email/report body from the scan results and server status lists.
    param(
        [Parameter(Mandatory = $true)]
        [datetime]$ScanDate,
        [Parameter(Mandatory = $true)]
        [int]$TotalServers,
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [array]$ServerStatuses,
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [array]$AllCertificates,
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [array]$ExpiringCertificates,
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [array]$UnreachableServers,
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [array]$NoIssuerMatchServers,
        [Parameter(Mandatory = $true)]
        [int]$ThresholdDays
    )

    $reportDate = $ScanDate.ToString('dddd MM/dd/yyyy')
    $generatedTimestamp = $ScanDate.ToString('MM/dd/yyyy HH:mm:ss')
    $title = if ($ExpiringCertificates.Count -gt 0) {
        "Expired Certificate Report $reportDate"
    }
    else {
        "Nothing to Report $reportDate"
    }

    $expiringRows = if ($ExpiringCertificates.Count -gt 0) {
        $ExpiringCertificates |
            Sort-Object DaysUntilExpiration, Server, Subject |
            ForEach-Object {
                "<tr><td>$($_.Server)</td><td>$($_.ExpirationDate.ToString('MM/dd/yyyy HH:mm:ss'))</td><td>$($_.DaysUntilExpiration)</td><td>$($_.Issuer)</td></tr>"
            }
    }
    else {
        @("<tr><td colspan='4'>There is NO server that the certificate will be expired within $ThresholdDays days. Please check the attached log.</td></tr>")
    }

    # Group the final per-server statuses so the summary table shows counts by outcome.
    $statusSummaryRows = $ServerStatuses |
        Group-Object Status |
        Sort-Object Name |
        ForEach-Object {
            "<tr><td>$($_.Name)</td><td>$($_.Count)</td></tr>"
        }

    $unreachableSection = if ($UnreachableServers.Count -gt 0) {
        $serverList = ($UnreachableServers | Sort-Object | ForEach-Object { "<li>$_</li>" }) -join ''
        "<h3>Servers not reachable or not queryable</h3><ul>$serverList</ul>"
    }
    else {
        '<h3>Servers not reachable or not queryable</h3><p>None</p>'
    }

    $noIssuerMatchSection = if ($NoIssuerMatchServers.Count -gt 0) {
        $serverList = ($NoIssuerMatchServers | Sort-Object | ForEach-Object { "<li>$_</li>" }) -join ''
        "<h3>Servers with no issuer match found</h3><ul>$serverList</ul>"
    }
    else {
        '<h3>Servers with no issuer match found</h3><p>None</p>'
    }

    @"
<html>
<head>
<meta http-equiv="Cache-Control" content="no-store, no-cache, must-revalidate" />
<meta http-equiv="Pragma" content="no-cache" />
<meta http-equiv="Expires" content="0" />
<style>
body { font-family: Arial, Helvetica, sans-serif; font-size: 13pt; }
table { border: 1px solid black; border-collapse: collapse; font-size: 13pt; width: 100%; }
th { border: 1px solid black; background: #dddddd; padding: 5px; color: #000000; }
td { border: 1px solid black; padding: 5px; }
h2 { text-align: center; }
p.report-generated { text-align: center; font-size: 11pt; }
</style>
</head>
<body>
<h2>$title</h2>
<p class="report-generated">Report generated: $generatedTimestamp</p>
<p class="report-generated">Total servers read from input list: $TotalServers</p>
<h3>Server Status Summary</h3>
<table>
<tr>
<th>Status</th>
<th>Server Count</th>
</tr>
$($statusSummaryRows -join [Environment]::NewLine)
</table>
<h3>Expiring Matching Certificates</h3>
<table>
<tr>
<th>Server</th>
<th>Expiration Date</th>
<th>Days Until Expiration</th>
<th>Issuer</th>
</tr>
$($expiringRows -join [Environment]::NewLine)
</table>
$unreachableSection
$noIssuerMatchSection
</body>
</html>
"@
}

if (-not (Test-Path -Path $ServerListPath)) {
    throw "Server list file not found: $ServerListPath"
}

if (-not $To -or $To.Count -eq 0) {
    throw 'At least one email recipient is required.'
}

$logDirectory = Split-Path -Path $LogFile -Parent
if ($logDirectory -and -not (Test-Path -Path $logDirectory)) {
    New-Item -Path $logDirectory -ItemType Directory -Force | Out-Null
}

$reportDirectory = Split-Path -Path $ReportFile -Parent
if ($reportDirectory -and -not (Test-Path -Path $reportDirectory)) {
    New-Item -Path $reportDirectory -ItemType Directory -Force | Out-Null
}

Set-Content -Path $LogFile -Value ''
Write-Log ("Certificate check started. Threshold={0} day(s). SMTP={1}:{2}. Recipients={3}." -f $DaysRemaining, $SmtpServer, $SmtpPort, ($To -join ', '))
Write-Log "Certificate stores to scan: $($CertificateStores -join ', ')"
Write-Log "Issuer filter: $IssuerPattern"

$scanDate = Get-Date
$serverStatuses = [System.Collections.Generic.List[object]]::new()
$allCertificates = [System.Collections.Generic.List[object]]::new()
$expiringCertificates = [System.Collections.Generic.List[object]]::new()
$unreachableServers = [System.Collections.Generic.List[string]]::new()
$noIssuerMatchServers = [System.Collections.Generic.List[string]]::new()

# Blank lines and comment lines in the input file are ignored before the scan starts.
$servers = Get-Content -Path $ServerListPath | Where-Object { $_.Trim() -and -not $_.Trim().StartsWith('#') }
$totalServers = @($servers).Count

foreach ($server in $servers) {
    $computerName = $server.Trim().ToUpperInvariant()
    $matchedIssuerForServer = $false
    $matchingCertificateCount = 0
    $expiringCertificateCount = 0
    $expiredCertificateCount = 0
    $selectedExpirationDate = $null
    $selectedDaysUntilExpiration = $null
    $selectedIssuer = ''

    # Skip remote certificate work entirely when basic connectivity fails.
    if (-not (Test-Connection -ComputerName $computerName -Count 1 -Quiet)) {
        Write-Log "$computerName failed Test-Connection."
        $unreachableServers.Add($computerName)
        $serverStatuses.Add((New-ServerStatusRecord -Server $computerName -Status 'Unreachable' -CertificateCount 0 -MatchingCertificateCount 0 -ExpiringCertificateCount 0 -ExpirationDate $null -DaysUntilExpiration $null -Detail 'Failed Test-Connection.'))
        continue
    }

    Write-Log "$computerName responded to Test-Connection."

    try {
        $certificates = Get-ServerCertificates -ComputerName $computerName -StorePaths $CertificateStores
    }
    catch {
        Write-Log "$computerName certificate query failed: $($_.Exception.Message)"
        $unreachableServers.Add($computerName)
        $serverStatuses.Add((New-ServerStatusRecord -Server $computerName -Status 'Query Failed' -CertificateCount 0 -MatchingCertificateCount 0 -ExpiringCertificateCount 0 -ExpirationDate $null -DaysUntilExpiration $null -Detail $_.Exception.Message))
        continue
    }

    $certificateCount = @($certificates).Count

    if (-not $certificates) {
        Write-Log "$computerName returned no certificates from the configured stores."
        $serverStatuses.Add((New-ServerStatusRecord -Server $computerName -Status 'No Certificates Found' -CertificateCount 0 -MatchingCertificateCount 0 -ExpiringCertificateCount 0 -ExpirationDate $null -DaysUntilExpiration $null -Detail 'No certificates returned from the configured stores.'))
        continue
    }

    Write-Log "$computerName returned $certificateCount certificate(s) from the configured stores."

    foreach ($certificate in $certificates) {
        # Only certificates issued by the configured issuer pattern participate in the report.
        if (-not ($IssuerPattern | Where-Object { $certificate.Issuer -like $_ })) {
            continue
        }

        $matchingCertificateCount++
        $daysUntilExpiration = [math]::Floor(($certificate.NotAfter - $scanDate).TotalDays)
        $certificateRecord = [pscustomobject]@{
            Server              = $computerName
            Subject             = $certificate.Subject
            Issuer              = $certificate.Issuer
            Thumbprint          = $certificate.Thumbprint
            StorePath           = $certificate.StorePath
            ExpirationDate      = $certificate.NotAfter
            DaysUntilExpiration = $daysUntilExpiration
        }

        $allCertificates.Add($certificateRecord)
        $matchedIssuerForServer = $true

        # Keep the earliest matching certificate so the summary points to the closest date.
        if (($null -eq $selectedExpirationDate) -or ($certificate.NotAfter -lt $selectedExpirationDate)) {
            $selectedExpirationDate = $certificate.NotAfter
            $selectedDaysUntilExpiration = $daysUntilExpiration
            $selectedIssuer = $certificate.Issuer
        }
        Write-Log "$computerName matched issuer filter with certificate '$($certificate.Subject)' in '$($certificate.StorePath)'."

        # This threshold drives the detail table and email subject, not the per-server expired status.
        if ($daysUntilExpiration -le $DaysRemaining) {
            $expiringCertificateCount++
            $expiringCertificates.Add($certificateRecord)

            Write-Log "$computerName certificate '$($certificate.Subject)' in '$($certificate.StorePath)' expires on $($certificate.NotAfter.ToString('yyyy-MM-dd HH:mm:ss')) ($daysUntilExpiration day(s) remaining)."
        }

        if ($daysUntilExpiration -lt 0) {
            $expiredCertificateCount++
        }
    }

    if (-not $matchedIssuerForServer) {
        Write-Log "$computerName returned certificates but no issuer match found in the configured stores."
        $noIssuerMatchServers.Add($computerName)
        $serverStatuses.Add((New-ServerStatusRecord -Server $computerName -Status 'No Issuer Match' -CertificateCount $certificateCount -MatchingCertificateCount 0 -ExpiringCertificateCount 0 -ExpirationDate $null -DaysUntilExpiration $null -Detail 'Certificates were found, but none matched the issuer filter.'))
        continue
    }

    # A server is marked expired only when at least one matching certificate is already past its date.
    $serverStatus = if ($expiredCertificateCount -gt 0) {
        'Expired Certificate Found'
    }
    else {
        'Matching Certificate Found'
    }

    $serverStatuses.Add((New-ServerStatusRecord -Server $computerName -Status $serverStatus -CertificateCount $certificateCount -MatchingCertificateCount $matchingCertificateCount -ExpiringCertificateCount $expiringCertificateCount -ExpirationDate $selectedExpirationDate -DaysUntilExpiration $selectedDaysUntilExpiration -Issuer $selectedIssuer -Detail "Issuer matches found in configured stores. ExpiredMatches=$expiredCertificateCount. Threshold=$DaysRemaining day(s)."))
}

if (Test-Path -Path $ReportFile) {
    Remove-Item -Path $ReportFile -Force
    Write-Log "Existing report removed before generating a new report: $ReportFile"
}

# The HTML body is built after all servers are processed so the report reflects one complete scan.
$reportBody = New-ReportBody -ScanDate $scanDate -TotalServers $totalServers -ServerStatuses $serverStatuses -AllCertificates $allCertificates -ExpiringCertificates $expiringCertificates -UnreachableServers $unreachableServers -NoIssuerMatchServers $noIssuerMatchServers -ThresholdDays $DaysRemaining
Set-Content -Path $ReportFile -Value $reportBody -Encoding UTF8
Write-Log "HTML report written to $ReportFile."

$mailMessage = [System.Net.Mail.MailMessage]::new()
$smtpClient = [System.Net.Mail.SmtpClient]::new($SmtpServer)
$smtpClient.Port = $SmtpPort
$attachment = $null
$emailSent = $false

try {
    $mailMessage.From = $From
    foreach ($recipient in $To) {
        if ($recipient) {
            [void]$mailMessage.To.Add($recipient)
        }
    }

    $mailMessage.Subject = if ($expiringCertificates.Count -gt 0) {
        "[ATTENTION] There is SSL Certificate(s) that need your attention E, F and EW Servers"
    }
    else {
        "[OK] There is NO SSL Certificate(s) expiring within $DaysRemaining days"
    }

    # The generated HTML is used directly as the email body so the email matches the saved report.
    $mailMessage.Body = $reportBody
    $mailMessage.IsBodyHtml = $true
    Write-Log "Sending certificate report email. ExpiringCertificates=$($expiringCertificates.Count). UnreachableServers=$($unreachableServers.Count)."
    $attachment = [System.Net.Mail.Attachment]::new($LogFile)
    $mailMessage.Attachments.Add($attachment)

    $smtpClient.Send($mailMessage)
    $emailSent = $true
}
finally {
    if ($attachment) {
        $attachment.Dispose()
    }
    $mailMessage.Dispose()
    $smtpClient.Dispose()
}

if ($emailSent) {
    Write-Log 'Email report sent successfully.'
}
