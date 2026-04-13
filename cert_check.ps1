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

function New-ReportBody {
    # Builds the HTML email/report body from the scan results and server status lists.
    param(
        [Parameter(Mandatory = $true)]
        [datetime]$ScanDate,
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
<style>
body { font-family: Arial, Helvetica, sans-serif; font-size: 13pt; }
table { border: 1px solid black; border-collapse: collapse; font-size: 13pt; width: 100%; }
th { border: 1px solid black; background: #dddddd; padding: 5px; color: #000000; }
td { border: 1px solid black; padding: 5px; }
h2 { text-align: center; }
</style>
</head>
<body>
<h2>$title</h2>
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
$allCertificates = [System.Collections.Generic.List[object]]::new()
$expiringCertificates = [System.Collections.Generic.List[object]]::new()
$unreachableServers = [System.Collections.Generic.List[string]]::new()
$noIssuerMatchServers = [System.Collections.Generic.List[string]]::new()
$servers = Get-Content -Path $ServerListPath | Where-Object { $_.Trim() -and -not $_.Trim().StartsWith('#') }

foreach ($server in $servers) {
    $computerName = $server.Trim().ToUpperInvariant()
    $matchedIssuerForServer = $false

    if (-not (Test-Connection -ComputerName $computerName -Count 1 -Quiet)) {
        Write-Log "$computerName failed Test-Connection."
        $unreachableServers.Add($computerName)
        continue
    }

    Write-Log "$computerName responded to Test-Connection."

    try {
        $certificates = Get-ServerCertificates -ComputerName $computerName -StorePaths $CertificateStores
    }
    catch {
        Write-Log "$computerName certificate query failed: $($_.Exception.Message)"
        $unreachableServers.Add($computerName)
        continue
    }

    if (-not $certificates) {
        Write-Log "$computerName returned no certificates from the configured stores."
        continue
    }

    Write-Log "$computerName returned $($certificates.Count) certificate(s) from the configured stores."

    foreach ($certificate in $certificates) {
        if (-not ($IssuerPattern | Where-Object { $certificate.Issuer -like $_ })) {
            continue
        }

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
        Write-Log "$computerName matched issuer filter with certificate '$($certificate.Subject)' in '$($certificate.StorePath)'."

        if ($daysUntilExpiration -le $DaysRemaining) {
            $expiringCertificates.Add($certificateRecord)

            Write-Log "$computerName certificate '$($certificate.Subject)' in '$($certificate.StorePath)' expires on $($certificate.NotAfter.ToString('yyyy-MM-dd HH:mm:ss')) ($daysUntilExpiration day(s) remaining)."
        }
    }

    if (-not $matchedIssuerForServer) {
        Write-Log "$computerName returned certificates but no issuer match found in the configured stores."
        $noIssuerMatchServers.Add($computerName)
    }
}

$reportBody = New-ReportBody -ScanDate $scanDate -AllCertificates $allCertificates -ExpiringCertificates $expiringCertificates -UnreachableServers $unreachableServers -NoIssuerMatchServers $noIssuerMatchServers -ThresholdDays $DaysRemaining
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
