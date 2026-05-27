# =============================================================================
# TDIS Daily Report Emailer
# -----------------------------------------------------------------------------
# Purpose  : Checks the report folder for today's CSV files and sends one
#            email with all five as attachments.
# Schedule : Run this script after all five TDIS data scripts have completed.
# =============================================================================

# -------- SMTP SETTINGS --------
$From       = "TDIS_daily_report@state.gov"
$To         = "teramuh1@state.gov"
$SmtpServer = "carelay.ca.state.sbu"

# -------- PATHS --------
$ReportFolder = "E:\SQLReports\Reports"
$Today        = (Get-Date).Date

# -------- COLLECT TODAY'S CSV FILES --------
# Each report is matched by the filename prefix its data script uses.
# Only files written today are attached — stale files from prior runs are ignored.
$Reports = @(
    [PSCustomObject]@{ Name = "Adjudicated Batches";     FilePrefix = "TDIS_adjudicated_batches_" },
    [PSCustomObject]@{ Name = "Completed Batches";       FilePrefix = "TDIS_completed_batches_" },
    [PSCustomObject]@{ Name = "Lockbox Status";          FilePrefix = "TDIS_lockbox_status_report_" },
    [PSCustomObject]@{ Name = "Applications Not Issued"; FilePrefix = "TDIS_applications_not_issued_report_" },
    [PSCustomObject]@{ Name = "Printed Products";        FilePrefix = "TDIS_printed_products_report_" }
)

$Attachments = [System.Collections.Generic.List[string]]::new()
$Missing     = [System.Collections.Generic.List[string]]::new()

Write-Host "`n=== Collecting CSV files ==="
foreach ($report in $Reports) {
    $latest = Get-ChildItem -Path $ReportFolder -Filter "$($report.FilePrefix)*.csv" -ErrorAction SilentlyContinue |
              Where-Object { $_.LastWriteTime -ge $Today } |
              Sort-Object LastWriteTime -Descending |
              Select-Object -First 1

    if ($latest) {
        $Attachments.Add($latest.FullName)
        Write-Host "Attaching: $($latest.Name)"
    } else {
        $Missing.Add("  $($report.Name)")
        Write-Host "MISSING: $($report.Name)" -ForegroundColor Yellow
    }
}

# -------- BUILD EMAIL BODY --------
$Body = if ($Attachments.Count -gt 0) {
    "Please find today's TDIS reports attached ($($Attachments.Count) of 5)."
} else {
    "No TDIS report CSVs were found for today. All five data scripts may have failed."
}

if ($Missing.Count -gt 0) {
    $Body += "`r`n`r`nThe following reports had no CSV for today:`r`n" + ($Missing -join "`r`n")
}

# -------- SEND EMAIL --------
$MailParams = @{
    From       = $From
    To         = $To
    Subject    = "TDIS Daily Reports - $(Get-Date -Format 'yyyy-MM-dd')"
    Body       = $Body
    SmtpServer = $SmtpServer
}
if ($Attachments.Count -gt 0) { $MailParams['Attachments'] = $Attachments.ToArray() }
Send-MailMessage @MailParams

Write-Host "`nEmail sent with $($Attachments.Count) attachment(s)."

# -------- CLEAN UP OLD CSV FILES --------
# Delete any CSV files in the report folder older than 3 hours.
$Cutoff = (Get-Date).AddHours(-3)
$Deleted = 0
Get-ChildItem -Path $ReportFolder -Filter "*.csv" -ErrorAction SilentlyContinue |
    Where-Object { $_.LastWriteTime -lt $Cutoff } |
    ForEach-Object {
        Remove-Item $_.FullName -Force
        Write-Host "Deleted old file: $($_.Name)"
        $Deleted++
    }
Write-Host "$Deleted old CSV file(s) deleted."
