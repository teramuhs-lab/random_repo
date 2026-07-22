# =============================================================================
# TDIS Production Report Emailer
# -----------------------------------------------------------------------------
# Purpose  : Checks the report folder for today's production report CSV and
#            sends it as an email attachment.
# Schedule : Run after Production Report .ps1 has completed.
# =============================================================================

# -------- SMTP SETTINGS --------
$From       = "TDIS_daily_report@state.gov"
$To         = "teramuh1@state.gov"
$SmtpServer = "carelay.ca.state.sbu"

# -------- PATHS --------
$ReportFolder = "E:\SQLReports\Reports"
$Today        = (Get-Date).Date

# -------- COLLECT TODAY'S CSV FILE --------
$latest = Get-ChildItem -Path $ReportFolder -Filter "TDIS_production_report_*.csv" -ErrorAction SilentlyContinue |
          Where-Object { $_.LastWriteTime -ge $Today } |
          Sort-Object LastWriteTime -Descending |
          Select-Object -First 1

# -------- BUILD EMAIL BODY --------
if ($latest) {
    $Body = "Please find today's TDIS Production Report attached."
    Write-Host "Attaching: $($latest.Name)"
} else {
    $Body = "No Production Report CSV was found for today. The data script may have failed."
    Write-Host "MISSING: Production Report" -ForegroundColor Yellow
}

# -------- SEND EMAIL --------
$MailParams = @{
    From       = $From
    To         = $To
    Subject    = "TDIS Production Report - $(Get-Date -Format 'yyyy-MM-dd')"
    Body       = $Body
    SmtpServer = $SmtpServer
}
if ($latest) { $MailParams['Attachments'] = $latest.FullName }
Send-MailMessage @MailParams

Write-Host "`nEmail sent."

# -------- CLEAN UP OLD CSV FILES --------
$Cutoff  = (Get-Date).AddHours(-3)
$Deleted = 0
Get-ChildItem -Path $ReportFolder -Filter "TDIS_production_report_*.csv" -ErrorAction SilentlyContinue |
    Where-Object { $_.LastWriteTime -lt $Cutoff } |
    ForEach-Object {
        Remove-Item $_.FullName -Force
        Write-Host "Deleted old file: $($_.Name)"
        $Deleted++
    }
Write-Host "$Deleted old CSV file(s) deleted."
