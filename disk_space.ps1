$serverListPath = ".\servers.txt"
$outputPath = ".\disk_space_report.csv"
$smtpServer = "smtp.example.com"
$smtpPort = 25
$from = "disk-report@example.com"
$to = "ops@example.com"
$subject = "Disk Space Report"

function Get-ServerList {
  param(
    [string]$Path
  )

  # Load server names from file (one server name per line).
  return Get-Content -Path $Path | Where-Object { $_.Trim() -ne "" }
}

function Get-DiskData {
  param(
    [string]$Server
  )

  # Run the disk query on the remote server.
  return Invoke-Command -ComputerName $Server -ScriptBlock {
    # Get fixed disks only (DriveType 3).
    Get-CimInstance -ClassName Win32_LogicalDisk -Filter "DriveType=3" |
      Select-Object `
        @{Name="Server";Expression={$env:COMPUTERNAME}}, `
        @{Name="Drive";Expression={$_.DeviceID}}, `
        @{Name="SizeGB";Expression={[math]::Round($_.Size / 1GB, 2)}}, `
        @{Name="FreeGB";Expression={[math]::Round($_.FreeSpace / 1GB, 2)}}, `
        @{Name="FreePct";Expression={[math]::Round(($_.FreeSpace / $_.Size) * 100, 1)}}
  }
}

function Send-ReportEmail {
  param(
    [string]$SmtpServer,
    [int]$SmtpPort,
    [string]$From,
    [string]$To,
    [string]$Subject,
    [string]$AttachmentPath
  )

  # Email the report as an attachment.
  Send-MailMessage `
    -SmtpServer $SmtpServer `
    -Port $SmtpPort `
    -From $From `
    -To $To `
    -Subject $Subject `
    -Body "Disk space report attached." `
    -Attachments $AttachmentPath
}

function Main {
  $servers = Get-ServerList -Path $serverListPath
  $results = @()

  foreach ($server in $servers) {
    try {
      $results += Get-DiskData -Server $server
    }
    catch {
      # Report any connection or query errors and continue.
      Write-Warning "Failed to query $server. $($_.Exception.Message)"
    }
  }

  # Show a simple table in the console.
  $results | Sort-Object Server, Drive | Format-Table -AutoSize

  # Export to CSV for sharing.
  $results | Sort-Object Server, Drive | Export-Csv -Path $outputPath -NoTypeInformation

  Send-ReportEmail `
    -SmtpServer $smtpServer `
    -SmtpPort $smtpPort `
    -From $from `
    -To $to `
    -Subject $subject `
    -AttachmentPath $outputPath
}

Main
