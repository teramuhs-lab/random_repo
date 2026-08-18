<#
.SYNOPSIS
    Uninstalls SQL Server Management Studio from one or more nodes.

.DESCRIPTION
    SSMS holds no state. Nothing about SQL Server's operation depends on it, no database
    lives inside it, and removing it cannot lose data -- which is why this is a separate,
    lighter script than the one that removes the engine.

    The usual reason to run it: SSMS 19+ installs wherever the Visual Studio installer
    defaults to, and that path cannot be changed in place. To move SSMS to another volume
    you uninstall it, set --installPath in the environment file's LayoutArguments, and let
    DSC reinstall it.

    Reports by default. Removal requires -Execute and a typed confirmation.

    WHAT IT LEAVES BEHIND

    Uninstalling the product does not remove the Visual Studio installer infrastructure or
    its package cache, typically under:

        C:\Program Files (x86)\Microsoft Visual Studio\Installer
        C:\ProgramData\Microsoft\VisualStudio\Packages

    Those are shared by any VS-based product and are not this script's to delete. If you
    are uninstalling to reclaim C: space rather than to relocate, check those folders --
    they are often the larger share.

.PARAMETER ComputerName
    Target nodes.

.PARAMETER Execute
    Perform the uninstall. Without this, the script only reports.

.EXAMPLE
    .\Remove-SSMS.ps1 -ComputerName PDCWODWGDBSVR

    Reports what is installed and where. Changes nothing.

.EXAMPLE
    .\Remove-SSMS.ps1 -ComputerName PDCWODWGDBSVR,PDCWODWGDBSVR2 -Execute

    Uninstalls SSMS on both, after confirmation.

.NOTES
    After removing, set LayoutArguments in the environment file, e.g.

        LayoutArguments = '--quiet --norestart --wait --noWeb --installPath E:\SSMS22'

    then re-run the installer. [Script]InstallSSMS detects SSMS by registry DisplayName
    and version rather than by path, so it will see it missing and reinstall to the new
    location.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string[]] $ComputerName,

    [switch] $Execute
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

$findScript = {
    $keys = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )

    $found = @( Get-ItemProperty $keys -ErrorAction SilentlyContinue |
                  Where-Object { $_.DisplayName -like 'SQL Server Management Studio*' } |
                  Select-Object DisplayName, DisplayVersion, InstallLocation, UninstallString, QuietUninstallString )

    # Reported so an uninstall driven by "reclaim C: space" can be judged honestly --
    # the package cache often outweighs the product itself.
    $cacheGB = 0
    foreach ( $p in @('C:\ProgramData\Microsoft\VisualStudio\Packages') )
    {
        if ( Test-Path $p )
        {
            $cacheGB += ( Get-ChildItem $p -Recurse -File -Force -ErrorAction SilentlyContinue |
                            Measure-Object Length -Sum ).Sum / 1GB
        }
    }

    [PSCustomObject]@{
        Computer   = $env:COMPUTERNAME
        Installed  = $found
        CacheGB    = [math]::Round($cacheGB, 2)
        FreeCGB    = [math]::Round((Get-PSDrive C).Free / 1GB, 1)
    }
}

Write-Banner 'SSMS INVENTORY -- nothing is being changed'

$targets = @()

foreach ( $node in $ComputerName )
{
    try
    {
        $inv = Invoke-Command -ComputerName $node -ScriptBlock $findScript -ErrorAction Stop
    }
    catch
    {
        Write-Host "  [UNREACHABLE] $node -- $(($_.Exception.Message -replace '[\r\n]+',' ').Trim())" -ForegroundColor Red
        continue
    }

    Write-Host ''
    Write-Host "  ---- $node ----" -ForegroundColor White
    Write-Host ("  C: free                 : {0} GB" -f $inv.FreeCGB)
    Write-Host ("  VS package cache on C:  : {0} GB  (not removed by this script)" -f $inv.CacheGB)

    if ( @($inv.Installed).Count -eq 0 )
    {
        Write-Host '  SSMS                    : not installed -- nothing to do' -ForegroundColor Green
        continue
    }

    foreach ( $app in $inv.Installed )
    {
        $where = if ( $app.InstallLocation ) { $app.InstallLocation } else { '(location not recorded)' }
        Write-Host "  SSMS                    : $($app.DisplayName) $($app.DisplayVersion)" -ForegroundColor Yellow
        Write-Host "                            $where"
    }

    $targets += $node
}

if ( $targets.Count -eq 0 )
{
    Write-Banner 'Nothing to uninstall'
    return
}

if ( -not $Execute )
{
    Write-Banner 'REPORT ONLY -- nothing was removed'
    Write-Host '  Re-run with -Execute to uninstall.' -ForegroundColor Yellow
    return
}

Write-Banner 'CONFIRM'
Write-Host "  SSMS will be uninstalled on: $($targets -join ', ')" -ForegroundColor Yellow
Write-Host ''
$answer = Read-Host '  Type REMOVE to proceed, anything else to abort'

if ( $answer -cne 'REMOVE' )
{
    Write-Host '  Aborted. Nothing was changed.' -ForegroundColor Green
    return
}

$removeScript = {
    $keys = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )
    $log = @()

    $apps = @( Get-ItemProperty $keys -ErrorAction SilentlyContinue |
                 Where-Object { $_.DisplayName -like 'SQL Server Management Studio*' } )

    foreach ( $app in $apps )
    {
        # SSMS 19+ is a Visual Studio package, so its UninstallString invokes the VS
        # installer and needs the unattended switches added.
        $cmd = if ( $app.QuietUninstallString ) { $app.QuietUninstallString } else { $app.UninstallString }

        if ( -not $cmd )
        {
            $log += "[SKIP] $($app.DisplayName): no uninstall string recorded -- remove via Apps & Features"
            continue
        }

        if ( $cmd -notmatch '--quiet|/quiet|/qn' ) { $cmd = "$cmd --quiet --norestart" }

        $log += "[RUN ] $cmd"

        try
        {
            $p = Start-Process -FilePath 'cmd.exe' -ArgumentList '/c', $cmd -Wait -PassThru -NoNewWindow
            $verdict = if ( $p.ExitCode -in @(0, 3010, 1641) ) { 'OK' } else { 'FAILED' }
            $log += "[$verdict] $($app.DisplayName) exit code $($p.ExitCode)"
        }
        catch
        {
            $log += "[FAILED] $($app.DisplayName): $($_.Exception.Message)"
        }
    }

    # Re-read rather than assume the uninstall worked.
    $left = @( Get-ItemProperty $keys -ErrorAction SilentlyContinue |
                 Where-Object { $_.DisplayName -like 'SQL Server Management Studio*' } )
    $log += if ( $left.Count -eq 0 ) { '[OK] no SSMS remains in the uninstall registry' }
            else { "[WARN] still present: $(($left | ForEach-Object { "$($_.DisplayName) $($_.DisplayVersion)" }) -join '; ')" }

    return $log
}

foreach ( $node in $targets )
{
    Write-Banner "UNINSTALLING SSMS on $node"
    try
    {
        Invoke-Command -ComputerName $node -ScriptBlock $removeScript -ErrorAction Stop |
            ForEach-Object { Write-Host "  $_" }
    }
    catch
    {
        Write-Host "  [FAILED] $node -- $(($_.Exception.Message -replace '[\r\n]+',' ').Trim())" -ForegroundColor Red
    }
}

Write-Banner 'DONE'
Write-Host @"
  To reinstall SSMS on a different volume, set this in the environment file's SSMS block:

      LayoutArguments = '--quiet --norestart --wait --noWeb --installPath E:\SSMS22'

  then run the installer. Detection is by registry DisplayName and version, not by path,
  so DSC will see SSMS missing and install it to the new location.

  No reboot is required for SSMS alone.
"@ -ForegroundColor Yellow
