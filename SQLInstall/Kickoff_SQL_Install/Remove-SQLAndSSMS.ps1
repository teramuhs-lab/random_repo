<#
.SYNOPSIS
    Removes SQL Server instances and/or SSMS from one or more nodes, so a server can be
    rebuilt with binaries on a different volume.

.DESCRIPTION
    This DELETES SOFTWARE AND CAN DESTROY DATA. It exists for one purpose: relocating an
    installation that cannot be relocated any other way, because SQL Server fixes its
    shared feature directories (INSTALLSHAREDDIR / INSTALLSHAREDWOWDIR) at the FIRST SQL
    install on a machine and never moves them afterwards.

    HOW IT BEHAVES

      By default it only REPORTS -- instances, SQL products, SSMS, and user database files
      it can find. Nothing is removed. Read that report before going further.

      Removal requires BOTH -Execute AND -AcknowledgeDataLoss. Two switches rather than
      one because the report is easy to skim and the consequence is not recoverable.

    WHAT IT DOES NOT DO, AND WHY

      It does not back anything up. Backups, logins, SQL Agent jobs, Database Mail
      profiles, audit specifications, certificates and server configuration are yours to
      capture before running this. The script cannot know which of them matter.

      It does not delete database FILES. The .mdf/.ldf under the data, log and backup
      volumes are left where they are, so a mistake is survivable. Remove them by hand
      once the rebuild is confirmed good.

      It does not remove shared components belonging to OLDER SQL versions (the 100, 110
      and 120 registry keys -- SQL 2008/2012/2014). Those are separate products, often
      without their original media on the box, and each needs its own uninstaller. They
      are REPORTED, because while any of them remain the shared directory stays pinned to
      its original volume and a reinstall will NOT honour a new one.

      That last point is the one that decides whether this script is enough. If the report
      lists older shared components you cannot cleanly remove, rebuilding the VM is
      faster and more certain than fighting them.

.PARAMETER ComputerName
    Target nodes.

.PARAMETER InstanceName
    SQL Server instance to remove, e.g. 'CAPPT'.

.PARAMETER Features
    Feature list passed to setup.exe /Action=Uninstall. Must match what is installed --
    check the report's 'Features' line. Setup ignores features that are not present.

.PARAMETER SetupPath
    setup.exe on the NODE, from the staged media. Uninstall needs the same media that
    installed it.

.PARAMETER IncludeSSMS
    Also uninstall SQL Server Management Studio.

.PARAMETER Execute
    Perform the removal. Without this, the script only reports.

.PARAMETER AcknowledgeDataLoss
    Required alongside -Execute. Confirms you have backups and scripted out everything
    you need to restore.

.EXAMPLE
    .\Remove-SQLAndSSMS.ps1 -ComputerName PDCWODWGDBSVR

    Reports only. Always start here.

.EXAMPLE
    .\Remove-SQLAndSSMS.ps1 -ComputerName PDCWODWGDBSVR -InstanceName CAPPT -IncludeSSMS -Execute -AcknowledgeDataLoss

    Removes the CAPPT instance and SSMS, after an interactive confirmation.

.NOTES
    Reboot each node after removal and before reinstalling. SQL setup refuses to install
    while a restart is pending, and leftover pending file renames are common after an
    uninstall.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string[]] $ComputerName,

    [string] $InstanceName = 'CAPPT',

    [string] $Features = 'SQLENGINE,FULLTEXT',

    [string] $SetupPath = 'C:\SQLInstall\SQLDSC\bits\SQL2025\setup.exe',

    [switch] $IncludeSSMS,

    [switch] $Execute,

    [switch] $AcknowledgeDataLoss
)

$ErrorActionPreference = 'Stop'

function Write-Banner
{
    param([string] $Text)
    Write-Host ''
    Write-Host ('=' * 80) -ForegroundColor Cyan
    Write-Host " $Text" -ForegroundColor Cyan
    Write-Host ('=' * 80) -ForegroundColor Cyan
}

# ---------------------------------------------------------------------------
# INVENTORY -- always runs, changes nothing.
# ---------------------------------------------------------------------------
$inventoryScript = {
    param ( $Instance )

    $r = @{
        Computer      = $env:COMPUTERNAME
        Instances     = @()
        SQLProducts   = @()
        OlderShared   = @()
        SSMS          = @()
        UserDbFiles   = @()
        EnginePath    = $null
        SharedOnC     = $false
        PendingReboot = $false
    }

    # Installed instances, from the canonical mapping key.
    $names = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\Instance Names\SQL' -ErrorAction SilentlyContinue
    if ( $names )
    {
        $r.Instances = @( $names.PSObject.Properties |
                            Where-Object { $_.Name -notlike 'PS*' } |
                            ForEach-Object { "$($_.Name) -> $($_.Value)" } )
    }

    $svc = Get-CimInstance Win32_Service -Filter "Name='MSSQL`$$Instance'" -ErrorAction SilentlyContinue
    if ( -not $svc ) { $svc = Get-CimInstance Win32_Service -Filter "Name='MSSQLSERVER'" -ErrorAction SilentlyContinue }
    if ( $svc ) { $r.EnginePath = $svc.PathName }

    # Every SQL-related product the uninstall registry knows about. Older shared
    # components show up here and are the reason a relocated reinstall can silently
    # keep using the original volume.
    $uninstallKeys = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )
    $apps = Get-ItemProperty $uninstallKeys -ErrorAction SilentlyContinue

    $r.SQLProducts = @( $apps |
        Where-Object { $_.DisplayName -like 'Microsoft SQL Server*' } |
        Select-Object -Property DisplayName, DisplayVersion |
        Sort-Object DisplayName )

    $r.SSMS = @( $apps |
        Where-Object { $_.DisplayName -like 'SQL Server Management Studio*' } |
        Select-Object -Property DisplayName, DisplayVersion, InstallLocation, UninstallString, QuietUninstallString )

    # Shared-component version keys. While any of these exist the shared directory is
    # pinned wherever the earliest SQL install put it.
    $r.OlderShared = @( Get-ChildItem 'HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server' -ErrorAction SilentlyContinue |
                          Where-Object { $_.PSChildName -match '^\d{2,3}$' } |
                          ForEach-Object { $_.PSChildName } |
                          Sort-Object )

    $r.SharedOnC = Test-Path 'C:\Program Files\Microsoft SQL Server\170'

    # Database files, so the report can say what is at stake. Not deleted by this script.
    foreach ( $root in @('C:','D:','E:','F:','G:','H:') )
    {
        if ( Test-Path "$root\" )
        {
            $r.UserDbFiles += @( Get-ChildItem "$root\" -Include '*.mdf','*.ndf' -Recurse -File -Force -ErrorAction SilentlyContinue |
                                    Where-Object { $_.Name -notmatch '^(master|model|msdb|tempdb|mssqlsystemresource)' } |
                                    Select-Object -First 200 |
                                    ForEach-Object { "{0}  ({1:N1} MB)" -f $_.FullName, ($_.Length / 1MB) } )
        }
    }

    $r.PendingReboot = (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending') -or
                       (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired')

    return $r
}

Write-Banner 'INVENTORY -- nothing is being changed'

$inventory = @{}

foreach ( $node in $ComputerName )
{
    try
    {
        $inv = Invoke-Command -ComputerName $node -ScriptBlock $inventoryScript -ArgumentList $InstanceName -ErrorAction Stop
    }
    catch
    {
        Write-Host "  [UNREACHABLE] $node -- $(($_.Exception.Message -replace '[\r\n]+',' ').Trim())" -ForegroundColor Red
        continue
    }

    $inventory[$node] = $inv

    Write-Host ''
    Write-Host "  ---- $node ----" -ForegroundColor White
    Write-Host "  Engine service path : $($inv.EnginePath)"
    Write-Host "  Instances           : $(if ($inv.Instances) { $inv.Instances -join '; ' } else { 'none' })"
    Write-Host "  Shared on C:        : $($inv.SharedOnC)"
    Write-Host "  Version keys        : $($inv.OlderShared -join ', ')"

    if ( $inv.SSMS )
    {
        foreach ( $s in $inv.SSMS ) { Write-Host "  SSMS                : $($s.DisplayName) $($s.DisplayVersion)  [$($s.InstallLocation)]" }
    }
    else { Write-Host '  SSMS                : not installed' }

    Write-Host "  SQL products        : $(@($inv.SQLProducts).Count) entries in Add/Remove Programs"

    if ( @($inv.UserDbFiles).Count -gt 0 )
    {
        Write-Host "  USER DATABASE FILES : $(@($inv.UserDbFiles).Count) found -- these are NOT deleted, but the instance serving them will be removed" -ForegroundColor Yellow
        $inv.UserDbFiles | Select-Object -First 10 | ForEach-Object { Write-Host "      $_" -ForegroundColor Yellow }
        if ( @($inv.UserDbFiles).Count -gt 10 ) { Write-Host "      ... and $(@($inv.UserDbFiles).Count - 10) more" -ForegroundColor Yellow }
    }
    else { Write-Host '  User database files : none found' }

    # The finding that decides whether uninstalling is even worth attempting.
    $legacy = @( $inv.OlderShared | Where-Object { $_ -ne '170' } )
    if ( $legacy.Count -gt 0 )
    {
        Write-Host ''
        Write-Host "  [IMPORTANT] $node also carries shared components from earlier SQL versions: $($legacy -join ', ')" -ForegroundColor Magenta
        Write-Host "              Removing the $InstanceName instance will NOT free the shared directory while these" -ForegroundColor Magenta
        Write-Host "              remain, so a reinstall will keep using the original volume. Each is a separate" -ForegroundColor Magenta
        Write-Host "              product with its own uninstaller. If they cannot be removed cleanly, REBUILDING" -ForegroundColor Magenta
        Write-Host "              the VM is faster and more certain than uninstalling." -ForegroundColor Magenta
    }
}

if ( -not $Execute )
{
    Write-Banner 'REPORT ONLY -- nothing was removed'
    Write-Host '  To remove, re-run with BOTH switches once you have backups and scripted out' -ForegroundColor Yellow
    Write-Host '  logins, Agent jobs, Database Mail, audits and server configuration:' -ForegroundColor Yellow
    Write-Host ''
    Write-Host "      -Execute -AcknowledgeDataLoss" -ForegroundColor Yellow
    return
}

if ( -not $AcknowledgeDataLoss )
{
    throw @"
-Execute was given without -AcknowledgeDataLoss.

Both are required. This removes SQL Server and leaves its databases without an instance
to serve them. Confirm you have:

    - a restorable backup of every user database
    - logins and their SIDs scripted out
    - SQL Agent jobs, operators and alerts scripted out
    - Database Mail profiles and accounts scripted out
    - audit specifications, certificates and server configuration recorded

then re-run with -Execute -AcknowledgeDataLoss.
"@
}

# ---------------------------------------------------------------------------
# CONFIRMATION -- names every node, so a wrong -ComputerName is caught here.
# ---------------------------------------------------------------------------
Write-Banner 'CONFIRM REMOVAL'
Write-Host "  Instance to remove : $InstanceName" -ForegroundColor Yellow
Write-Host "  Features           : $Features" -ForegroundColor Yellow
Write-Host "  SSMS               : $(if ($IncludeSSMS) { 'YES -- will be uninstalled' } else { 'left alone' })" -ForegroundColor Yellow
Write-Host "  Nodes              : $($inventory.Keys -join ', ')" -ForegroundColor Yellow
Write-Host ''
$answer = Read-Host "  Type REMOVE to proceed, anything else to abort"

if ( $answer -cne 'REMOVE' )
{
    Write-Host '  Aborted. Nothing was changed.' -ForegroundColor Green
    return
}

# ---------------------------------------------------------------------------
# REMOVAL
# ---------------------------------------------------------------------------
$removalScript = {
    param ( $Instance, $Features, $SetupPath, $DoSSMS )

    $log = @()

    if ( $DoSSMS )
    {
        $uninstallKeys = @(
            'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'
            'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
        )
        $ssms = @( Get-ItemProperty $uninstallKeys -ErrorAction SilentlyContinue |
                     Where-Object { $_.DisplayName -like 'SQL Server Management Studio*' } )

        foreach ( $app in $ssms )
        {
            # SSMS 19+ is a Visual Studio package: its UninstallString invokes the VS
            # installer, which needs --quiet --norestart added to run unattended.
            $cmd = if ( $app.QuietUninstallString ) { $app.QuietUninstallString } else { $app.UninstallString }

            if ( -not $cmd ) { $log += "SSMS '$($app.DisplayName)': no uninstall string found -- remove by hand"; continue }

            if ( $cmd -notmatch '--quiet' ) { $cmd = "$cmd --quiet --norestart" }

            $log += "SSMS uninstall: $cmd"
            try
            {
                $p = Start-Process -FilePath 'cmd.exe' -ArgumentList '/c', $cmd -Wait -PassThru -NoNewWindow
                $log += "SSMS '$($app.DisplayName)' exit code $($p.ExitCode)"
            }
            catch { $log += "SSMS '$($app.DisplayName)' FAILED: $($_.Exception.Message)" }
        }
    }

    if ( -not (Test-Path $SetupPath) )
    {
        $log += "SQL uninstall SKIPPED: setup.exe not found at '$SetupPath'. Uninstall needs the same media that installed it."
        return $log
    }

    $args = @(
        '/Action=Uninstall'
        '/Q'
        '/IACCEPTSQLSERVERLICENSETERMS'
        "/INSTANCENAME=$Instance"
        "/FEATURES=$Features"
    )

    $log += "SQL uninstall: $SetupPath $($args -join ' ')"

    try
    {
        $p = Start-Process -FilePath $SetupPath -ArgumentList $args -Wait -PassThru -NoNewWindow
        $log += "SQL setup exit code $($p.ExitCode)"
        if ( $p.ExitCode -notin @(0, 3010) ) { $log += "SQL uninstall did NOT succeed. Read Summary.txt under 'C:\Program Files\Microsoft SQL Server\170\Setup Bootstrap\Log'." }
    }
    catch { $log += "SQL uninstall FAILED: $($_.Exception.Message)" }

    return $log
}

foreach ( $node in $inventory.Keys )
{
    Write-Banner "REMOVING on $node"
    try
    {
        $out = Invoke-Command -ComputerName $node -ScriptBlock $removalScript `
                              -ArgumentList $InstanceName, $Features, $SetupPath, $IncludeSSMS.IsPresent -ErrorAction Stop
        $out | ForEach-Object { Write-Host "  $_" }
    }
    catch
    {
        Write-Host "  [FAILED] $node -- $(($_.Exception.Message -replace '[\r\n]+',' ').Trim())" -ForegroundColor Red
    }
}

Write-Banner 'DONE -- verify before rebuilding'
Write-Host @"
  Reboot every node before reinstalling. SQL setup refuses to install while a restart is
  pending, and an uninstall commonly leaves pending file renames behind:

      Restart-Computer -ComputerName <node> -Wait -For PowerShell -Force

  Then confirm the shared directory is actually gone -- this is what decides whether a
  reinstall will honour a new volume:

      Invoke-Command -ComputerName <node> {
          Test-Path 'C:\Program Files\Microsoft SQL Server\170'
          Get-ChildItem 'HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server' -Name
      }

  If that path still exists, or version keys other than 170 remain, the shared directory
  is still pinned to C: and a reinstall will use it regardless of InstallShareDirectory.
  Rebuild the VM instead.

  Database files were NOT deleted. Remove them by hand once the rebuild is verified.
"@ -ForegroundColor Yellow
