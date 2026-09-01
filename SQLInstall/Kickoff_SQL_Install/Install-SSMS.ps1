<#
.SYNOPSIS
    Installs SQL Server Management Studio on one or more nodes, on its own, without
    installing or configuring the database engine.

.DESCRIPTION
    The main installer cannot do this. In
    SQLDSC\configs\Install_and_Configure_SQLServer_Multi_Node_SqlServerDsc.ps1 the SSMS
    resource is declared

        Script 'InstallSSMS' { DependsOn = '[SqlSetup]SetupSQL' ... }

    so SSMS is ordered after the engine setup inside one monolithic configuration. There
    is no SSMS-only switch, and running that configuration just to get SSMS also applies
    TCP, firewall, memory, MaxDop, trace flags, sp_configure and the post-install T-SQL.

    That dependency is ORDERING, not need. The SSMS step's own Test/Set/Get touch nothing
    but the uninstall registry and the layout bootstrapper -- SSMS is a client tool and
    does not require a local engine. This script runs that same step by itself.

    SQL SERVER IS REPORTED, NOT REQUIRED
    Every node is checked for an installed engine and the result is printed, because
    installing SSMS onto a box you believed was a database server -- or onto a database
    server you believed was a bare workstation -- is worth catching before it happens.
    Absence is reported and the install proceeds. Pass -RequireSqlServer to make absence
    a hard stop instead.

    DETECTION MATCHES DSC
    SSMS presence is decided exactly as [Script]InstallSSMS decides it: an uninstall-key
    DisplayName of 'SQL Server Management Studio*' whose major DisplayVersion is at least
    the environment file's MinimumMajorVersion. So a node this script reports as done is
    a node the main installer will also leave alone, and the reverse.

    CONFIGURATION IS NOT DUPLICATED
    LayoutPath, LayoutBootstrapper, LayoutArguments, Components and MinimumMajorVersion
    are read from the environment .psd1 -- the same values the main installer uses.
    Uncomment a component there and both paths agree.

    Reports by default. Installing requires -Execute and a typed confirmation.

.PARAMETER ComputerName
    Target nodes.

.PARAMETER EnvironmentFile
    The environment .psd1 whose SSMS block supplies the layout path and arguments.

.PARAMETER Execute
    Perform the install. Without this, the script only reports.

.PARAMETER RequireSqlServer
    Treat a node with no SQL Server engine as an error and skip it, instead of reporting
    the absence and continuing.

.EXAMPLE
    .\Install-SSMS.ps1 -ComputerName PDCWODWGDBSVR `
                       -EnvironmentFile ..\SQLDSC\environments\InstallConfigure_SQLServer2025-CAPPT-Prod.psd1

    Reports what is installed, whether the engine is present, and whether the layout is
    staged. Changes nothing.

.EXAMPLE
    .\Install-SSMS.ps1 -ComputerName tdcwodwgdbs16,tdcwodwgdbs17 `
                       -EnvironmentFile ..\SQLDSC\environments\InstallConfigure_SQLServer2025-CAPPT-0708.psd1 `
                       -Execute

    Installs SSMS on both, after confirmation.

.NOTES
    Applies at INSTALL time only, like the DSC step. A node that already has SSMS at or
    above MinimumMajorVersion is left alone even if the component list has since grown --
    the Visual Studio installer does not add components to an existing install from here.
    That needs Remove-SSMS.ps1 and a re-run, or a one-off
    'vs_installer.exe modify --add <id>'.

    --noWeb in LayoutArguments confines the installer to the local layout, so every node
    needs the full layout staged at LayoutPath. This script refuses a node whose
    bootstrapper is missing rather than letting it fail minutes into the install.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string[]] $ComputerName,

    [Parameter(Mandatory = $true)]
    [string] $EnvironmentFile,

    [switch] $Execute,

    [switch] $RequireSqlServer
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

#region Read the environment file

if ( -not (Test-Path -LiteralPath $EnvironmentFile) )
{
    throw "Environment file not found: '$EnvironmentFile'"
}

# Not Import-PowerShellDataFile: these files interpolate "\\$env:COMPUTERNAME\..." in the
# Data block, and Import-PowerShellDataFile refuses a file containing any dynamic
# expression. The main installer evaluates them the same way.
$configurationData = & ([scriptblock]::Create( (Get-Content -Raw -LiteralPath $EnvironmentFile) ))
$ssms = $configurationData.NonNodeData.SSMS

if ( -not $ssms )
{
    throw "No NonNodeData.SSMS block in '$EnvironmentFile'."
}

if ( $ssms.SSMSVersion -ne 'SSMS22' )
{
    throw "This script installs the SSMS 22 layout only. The environment file sets SSMSVersion = '$($ssms.SSMSVersion)'."
}

$layoutPath   = $ssms.LayoutPath
$bootstrapper = Join-Path $layoutPath $ssms.LayoutBootstrapper
$minMajor     = [int]$ssms.MinimumMajorVersion

# Same assembly as the configuration: filter blanks, one --add per surviving entry. A
# fully commented-out Components list yields an empty array and no --add at all.
$components = @( $ssms.Components | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } )
$arguments  = $ssms.LayoutArguments
foreach ( $component in $components )
{
    $arguments += " --add $component"
}

# --installPath names a volume, and the volume it names is usually the engine's data
# drive -- which a node without SQL Server installed may simply not have. The Visual
# Studio installer does not fall back to C: when the path is unreachable; it fails, and
# it fails several minutes in. Checked per node below.
$installDrive = $null
if ( $arguments -match '--installPath\s+"?([A-Za-z]):' )
{
    $installDrive = $Matches[1] + ':'
}

Write-Banner 'SSMS STANDALONE INSTALL -- nothing is being changed yet'
Write-Host "  Environment file : $EnvironmentFile"
Write-Host "  Layout           : $layoutPath"
Write-Host "  Arguments        : $arguments"
if ( $components.Count -gt 0 )
{
    Write-Host ("  Components       : {0}" -f ($components -join ', '))
}
else
{
    Write-Host '  Components       : (none -- base product only)'
}
Write-Host "  Wanted version   : SSMS major $minMajor or higher"
if ( $installDrive )
{
    Write-Host "  Install drive    : $installDrive (from --installPath; must exist on every node)"
}

#endregion

$inventoryScript = {
    param($LayoutPath, $Bootstrapper, $MinMajor, $InstallDrive)

    $keys = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )

    $ssmsApps = @( Get-ItemProperty $keys -ErrorAction SilentlyContinue |
                     Where-Object { $_.DisplayName -like 'SQL Server Management Studio*' } |
                     Select-Object DisplayName, DisplayVersion, InstallLocation )

    # The DSC step's test, verbatim: at or above MinMajor counts as done.
    $satisfied = $false
    foreach ( $app in $ssmsApps )
    {
        $major = 0
        if ( $app.DisplayVersion -match '^(\d+)' ) { $major = [int]$Matches[1] }
        if ( $major -ge $MinMajor ) { $satisfied = $true }
    }

    # Engine presence, established the same way Remove-SQLServerInstance.ps1 establishes it.
    $names = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\Instance Names\SQL' -ErrorAction SilentlyContinue
    $instances = @()
    if ( $names )
    {
        $instances = @( $names.PSObject.Properties |
                          Where-Object { $_.Name -notlike 'PS*' } |
                          ForEach-Object { $_.Name } )
    }

    $layoutFiles = 0
    if ( Test-Path -LiteralPath $LayoutPath )
    {
        $layoutFiles = @( Get-ChildItem -LiteralPath $LayoutPath -Recurse -File -Force -ErrorAction SilentlyContinue ).Count
    }

    # The volume --installPath names. Absent on a node that is not a database server and
    # therefore never got the data volumes.
    $installDrivePresent = $true
    $installDriveFreeGB  = $null
    if ( $InstallDrive )
    {
        $drive = Get-PSDrive -Name $InstallDrive.TrimEnd(':') -ErrorAction SilentlyContinue
        if ( $drive )
        {
            $installDriveFreeGB = [math]::Round($drive.Free / 1GB, 1)
        }
        else
        {
            $installDrivePresent = $false
        }
    }

    [PSCustomObject]@{
        Computer            = $env:COMPUTERNAME
        SSMSApps            = $ssmsApps
        SSMSSatisfied       = $satisfied
        SQLInstances        = $instances
        LayoutPresent       = (Test-Path -LiteralPath $Bootstrapper)
        LayoutFileCount     = $layoutFiles
        FreeCGB             = [math]::Round((Get-PSDrive C).Free / 1GB, 1)
        InstallDrivePresent = $installDrivePresent
        InstallDriveFreeGB  = $installDriveFreeGB
    }
}

Write-Banner 'NODE INVENTORY'

$targets = @()

foreach ( $node in $ComputerName )
{
    try
    {
        $inv = Invoke-Command -ComputerName $node -ScriptBlock $inventoryScript `
                              -ArgumentList $layoutPath, $bootstrapper, $minMajor, $installDrive -ErrorAction Stop
    }
    catch
    {
        Write-Host "  [UNREACHABLE] $node -- $(($_.Exception.Message -replace '[\r\n]+',' ').Trim())" -ForegroundColor Red
        continue
    }

    Write-Host ''
    Write-Host "  ---- $node ----" -ForegroundColor White
    Write-Host ("  C: free                 : {0} GB" -f $inv.FreeCGB)

    # Reported, not required -- see the .DESCRIPTION.
    if ( @($inv.SQLInstances).Count -gt 0 )
    {
        Write-Host ("  SQL Server engine       : present -- instance(s): {0}" -f ($inv.SQLInstances -join ', ')) -ForegroundColor Green
    }
    else
    {
        Write-Host '  SQL Server engine       : NOT installed' -ForegroundColor Yellow
    }

    if ( @($inv.SSMSApps).Count -eq 0 )
    {
        Write-Host '  SSMS                    : not installed' -ForegroundColor Yellow
    }
    else
    {
        foreach ( $app in $inv.SSMSApps )
        {
            $where = if ( $app.InstallLocation ) { $app.InstallLocation } else { '(location not recorded)' }
            Write-Host "  SSMS                    : $($app.DisplayName) $($app.DisplayVersion)"
            Write-Host "                            $where"
        }
    }

    if ( $inv.LayoutPresent )
    {
        Write-Host ("  Layout                  : staged, {0} files" -f $inv.LayoutFileCount)
    }
    else
    {
        Write-Host "  Layout                  : MISSING -- no bootstrapper at $bootstrapper" -ForegroundColor Red
    }

    if ( $installDrive )
    {
        if ( $inv.InstallDrivePresent )
        {
            Write-Host ("  Install drive {0,-9} : present, {1} GB free" -f $installDrive, $inv.InstallDriveFreeGB)
        }
        else
        {
            Write-Host "  Install drive $installDrive        : MISSING -- --installPath points at a volume this node does not have" -ForegroundColor Red
        }
    }

    # Decided in the order that produces the most useful message.
    if ( $inv.SSMSSatisfied )
    {
        Write-Host "  -> already at SSMS $minMajor or higher; nothing to do" -ForegroundColor Green
        continue
    }

    if ( $RequireSqlServer -and @($inv.SQLInstances).Count -eq 0 )
    {
        Write-Host '  -> SKIPPED: -RequireSqlServer was given and no engine is installed here' -ForegroundColor Red
        continue
    }

    if ( -not $inv.LayoutPresent )
    {
        Write-Host '  -> SKIPPED: stage the layout on this node first. LayoutArguments carries' -ForegroundColor Red
        Write-Host '     --noWeb, so the installer cannot download what is not already there.' -ForegroundColor Red
        continue
    }

    if ( -not $inv.InstallDrivePresent )
    {
        Write-Host "  -> SKIPPED: LayoutArguments sets --installPath on $installDrive, which does not exist here." -ForegroundColor Red
        Write-Host '     The Visual Studio installer does not fall back to C:; it would fail minutes in.' -ForegroundColor Red
        Write-Host '     Either add the volume, or drop --installPath from LayoutArguments for this' -ForegroundColor Red
        Write-Host '     environment so SSMS installs to the default location.' -ForegroundColor Red
        continue
    }

    Write-Host '  -> will install' -ForegroundColor Yellow
    $targets += $node
}

if ( $targets.Count -eq 0 )
{
    Write-Banner 'Nothing to install'
    return
}

if ( -not $Execute )
{
    Write-Banner 'REPORT ONLY -- nothing was installed'
    Write-Host "  Would install on: $($targets -join ', ')" -ForegroundColor Yellow
    Write-Host '  Re-run with -Execute to install.' -ForegroundColor Yellow
    return
}

Write-Banner 'CONFIRM'
Write-Host "  SSMS will be installed on: $($targets -join ', ')" -ForegroundColor Yellow
Write-Host "  Arguments: $arguments"
Write-Host ''
$answer = Read-Host '  Type INSTALL to proceed, anything else to abort'

if ( $answer -cne 'INSTALL' )
{
    Write-Host '  Aborted. Nothing was changed.' -ForegroundColor Green
    return
}

$installScript = {
    param($Bootstrapper, $Arguments)

    if ( -not (Test-Path -LiteralPath $Bootstrapper) )
    {
        return [PSCustomObject]@{
            Computer = $env:COMPUTERNAME
            ExitCode = $null
            Message  = "Bootstrapper not found at '$Bootstrapper'."
        }
    }

    $process = Start-Process -FilePath $Bootstrapper -ArgumentList $Arguments `
                             -Wait -PassThru -NoNewWindow

    # The same codes the DSC step accepts: 0 = success, 3010 = success + reboot required,
    # 1641 = success + reboot initiated. Anything else is a real failure.
    $message = switch ( $process.ExitCode )
    {
        0       { 'Installed.' }
        3010    { 'Installed; a reboot is required to complete it.' }
        1641    { 'Installed; a reboot has been initiated.' }
        default { "FAILED with exit code $($process.ExitCode). See %TEMP%\dd_setup_*.log on this node." }
    }

    [PSCustomObject]@{
        Computer = $env:COMPUTERNAME
        ExitCode = $process.ExitCode
        Message  = $message
    }
}

Write-Banner 'INSTALLING -- this takes several minutes per node'

$failed = @()

foreach ( $node in $targets )
{
    Write-Host ''
    Write-Host "  ---- $node ----" -ForegroundColor White

    try
    {
        $result = Invoke-Command -ComputerName $node -ScriptBlock $installScript `
                                 -ArgumentList $bootstrapper, $arguments -ErrorAction Stop
    }
    catch
    {
        Write-Host "  [ERROR] $(($_.Exception.Message -replace '[\r\n]+',' ').Trim())" -ForegroundColor Red
        $failed += $node
        continue
    }

    if ( $result.ExitCode -in @(0, 3010, 1641) )
    {
        Write-Host "  [OK] $($result.Message)" -ForegroundColor Green
    }
    else
    {
        Write-Host "  [FAILED] $($result.Message)" -ForegroundColor Red
        $failed += $node
    }
}

if ( $failed.Count -gt 0 )
{
    Write-Banner "FINISHED WITH FAILURES on: $($failed -join ', ')"
}
else
{
    Write-Banner 'FINISHED -- SSMS installed on every target node'
}
