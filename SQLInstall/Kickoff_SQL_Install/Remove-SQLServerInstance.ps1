<#
.SYNOPSIS
    Uninstalls a SQL Server instance from one or more nodes.

.DESCRIPTION
    THIS DESTROYS A DATABASE SERVER. It exists for one reason: SQL Server fixes its shared
    feature directories (INSTALLSHAREDDIR / INSTALLSHAREDWOWDIR) at the FIRST SQL install
    on a machine and never moves them, so an instance whose binaries must live on a
    different volume has to be removed and reinstalled rather than reconfigured.

    Reports by default. Removal requires BOTH -Execute AND -AcknowledgeDataLoss, then a
    typed confirmation naming every node -- two switches rather than one because a report
    is easy to skim and this is not recoverable.

    READ THE VERSION-KEY LINE IN THE REPORT

    While shared components from ANY SQL version remain on the machine, the shared
    directory stays pinned where the earliest install put it. Removing this instance will
    not free it, and a reinstall will ignore a new InstallShareDirectory. PDCWODWGDBSVR,
    for example, carries 100, 110 and 120 alongside 170 -- remnants of SQL 2008, 2012 and
    2014 -- each a separate product with its own uninstaller, usually without its original
    media still on the box.

    If the report lists version keys other than the one you are removing, REBUILDING THE
    VM is faster and more certain than uninstalling. You are reinstalling SQL either way.

    WHAT THIS DOES NOT DO

      No backups are taken. Backups, logins and their SIDs, SQL Agent jobs, operators,
      alerts, Database Mail, audit specifications, certificates and server configuration
      are yours to capture first. The script cannot know which of them matter to you.

      Database FILES are not deleted. The instance serving them goes; the .mdf/.ndf/.ldf
      stay where they are, so a mistake is survivable. Remove them by hand once the
      rebuild is verified.

      SSMS is not touched. Use Remove-SSMS.ps1 for that.

.PARAMETER ComputerName
    Target nodes.

.PARAMETER InstanceName
    Instance to remove, e.g. 'CAPPT'.

.PARAMETER Features
    Feature list for setup.exe /Action=Uninstall. Must match what is installed -- see the
    report's product list. Setup ignores features that are not present.

.PARAMETER SetupPath
    setup.exe ON THE NODE, from the staged media. An uninstall needs the same media that
    performed the install.

.PARAMETER Execute
    Perform the uninstall. Without this, the script only reports.

.PARAMETER AcknowledgeDataLoss
    Required alongside -Execute.

.EXAMPLE
    .\Remove-SQLServerInstance.ps1 -ComputerName PDCWODWGDBSVR -InstanceName CAPPT

    Reports only. Always start here, and read the version-key line.

.EXAMPLE
    .\Remove-SQLServerInstance.ps1 -ComputerName PDCWODWGDBSVR -InstanceName CAPPT -Execute -AcknowledgeDataLoss

.NOTES
    Reboot before reinstalling. SQL setup refuses to install while a restart is pending,
    and an uninstall commonly leaves pending file renames behind.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string[]] $ComputerName,

    [Parameter(Mandatory = $true)]
    [string] $InstanceName,

    [string] $Features = 'SQLENGINE,FULLTEXT',

    [string] $SetupPath = 'C:\SQLInstall\SQLDSC\bits\SQL2025\setup.exe',

    [switch] $Execute,

    [switch] $AcknowledgeDataLoss
)

$ErrorActionPreference = 'Stop'

# Checked before anything else runs. Validating this after the inventory meant an
# unreachable node returned early and a dangerous invocation looked accepted -- the
# operator would only discover the missing switch on the run that reached a live server.
if ( $Execute -and -not $AcknowledgeDataLoss )
{
    throw @"
-Execute was given without -AcknowledgeDataLoss.

Both are required. This removes SQL Server and leaves its databases without an instance to
serve them. Confirm you have backups, and that logins (with SIDs), Agent jobs, Database
Mail, audits and server configuration are scripted out, then re-run with:

    -Execute -AcknowledgeDataLoss
"@
}

function Write-Banner
{
    param([string] $Text)
    Write-Host ''
    Write-Host ('=' * 80) -ForegroundColor Cyan
    Write-Host " $Text" -ForegroundColor Cyan
    Write-Host ('=' * 80) -ForegroundColor Cyan
}

$inventoryScript = {
    param ( $Instance, $SetupPath )

    $r = @{
        Computer    = $env:COMPUTERNAME
        EnginePath  = $null
        Instances   = @()
        VersionKeys = @()
        SQLProducts = @()
        UserDbFiles = @()
        SetupFound  = (Test-Path $SetupPath)
    }

    $svc = Get-CimInstance Win32_Service -Filter "Name='MSSQL`$$Instance'" -ErrorAction SilentlyContinue
    if ( -not $svc ) { $svc = Get-CimInstance Win32_Service -Filter "Name='MSSQLSERVER'" -ErrorAction SilentlyContinue }
    if ( $svc ) { $r.EnginePath = $svc.PathName }

    $names = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\Instance Names\SQL' -ErrorAction SilentlyContinue
    if ( $names )
    {
        $r.Instances = @( $names.PSObject.Properties |
                            Where-Object { $_.Name -notlike 'PS*' } |
                            ForEach-Object { "$($_.Name) -> $($_.Value)" } )
    }

    $r.VersionKeys = @( Get-ChildItem 'HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server' -ErrorAction SilentlyContinue |
                          Where-Object { $_.PSChildName -match '^\d{2,3}$' } |
                          ForEach-Object { $_.PSChildName } | Sort-Object )

    $keys = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )
    $r.SQLProducts = @( Get-ItemProperty $keys -ErrorAction SilentlyContinue |
                          Where-Object { $_.DisplayName -like 'Microsoft SQL Server*' } |
                          ForEach-Object { "$($_.DisplayName)  [$($_.DisplayVersion)]" } |
                          Sort-Object )

    # Reported so the confirmation is informed. Never deleted by this script.
    foreach ( $root in @('C:','D:','E:','F:','G:','H:') )
    {
        if ( Test-Path "$root\" )
        {
            $r.UserDbFiles += @( Get-ChildItem "$root\" -Include '*.mdf','*.ndf' -Recurse -File -Force -ErrorAction SilentlyContinue |
                                   Where-Object { $_.Name -notmatch '^(master|model|msdb|tempdb|mssqlsystemresource)' } |
                                   Select-Object -First 200 |
                                   ForEach-Object { '{0}  ({1:N1} MB)' -f $_.FullName, ($_.Length / 1MB) } )
        }
    }

    return $r
}

Write-Banner 'SQL SERVER INVENTORY -- nothing is being changed'

$inventory = @{}

foreach ( $node in $ComputerName )
{
    try
    {
        $inv = Invoke-Command -ComputerName $node -ScriptBlock $inventoryScript `
                              -ArgumentList $InstanceName, $SetupPath -ErrorAction Stop
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
    Write-Host "  Version keys        : $($inv.VersionKeys -join ', ')"
    Write-Host "  SQL products        : $(@($inv.SQLProducts).Count) entries in Add/Remove Programs"
    Write-Host "  setup.exe on node   : $(if ($inv.SetupFound) { $SetupPath } else { "NOT FOUND at $SetupPath -- uninstall cannot run" })" `
               -ForegroundColor $(if ($inv.SetupFound) { 'Gray' } else { 'Red' })

    if ( @($inv.UserDbFiles).Count -gt 0 )
    {
        Write-Host "  USER DATABASE FILES : $(@($inv.UserDbFiles).Count) found -- not deleted, but their instance will be removed" -ForegroundColor Yellow
        $inv.UserDbFiles | Select-Object -First 10 | ForEach-Object { Write-Host "      $_" -ForegroundColor Yellow }
        if ( @($inv.UserDbFiles).Count -gt 10 ) { Write-Host "      ... and $(@($inv.UserDbFiles).Count - 10) more" -ForegroundColor Yellow }
    }
    else { Write-Host '  User database files : none found' }

    # The finding that decides whether uninstalling achieves anything at all.
    $legacy = @( $inv.VersionKeys | Where-Object { $_ -ne '170' } )
    if ( $legacy.Count -gt 0 )
    {
        Write-Host ''
        Write-Host "  [IMPORTANT] Shared components from earlier SQL versions are present: $($legacy -join ', ')" -ForegroundColor Magenta
        Write-Host "              Removing '$InstanceName' will NOT free the shared directory while these remain," -ForegroundColor Magenta
        Write-Host "              so a reinstall will keep using the original volume regardless of" -ForegroundColor Magenta
        Write-Host "              InstallShareDirectory. Each is a separate product with its own uninstaller." -ForegroundColor Magenta
        Write-Host "              If they cannot be removed cleanly, REBUILD THE VM -- faster and more certain." -ForegroundColor Magenta
    }
}

if ( $inventory.Count -eq 0 )
{
    Write-Banner 'No reachable nodes'
    return
}

if ( -not $Execute )
{
    Write-Banner 'REPORT ONLY -- nothing was removed'
    Write-Host '  Before removing, capture from every instance:' -ForegroundColor Yellow
    Write-Host '    - a restorable backup of each user database' -ForegroundColor Yellow
    Write-Host '    - logins WITH THEIR SIDs, or they will not match on restore' -ForegroundColor Yellow
    Write-Host '    - SQL Agent jobs, operators and alerts' -ForegroundColor Yellow
    Write-Host '    - Database Mail profiles and accounts' -ForegroundColor Yellow
    Write-Host '    - audit specifications, certificates, server configuration' -ForegroundColor Yellow
    Write-Host ''
    Write-Host '  Then re-run with:  -Execute -AcknowledgeDataLoss' -ForegroundColor Yellow
    return
}

Write-Banner 'CONFIRM REMOVAL'
Write-Host "  Instance : $InstanceName" -ForegroundColor Yellow
Write-Host "  Features : $Features" -ForegroundColor Yellow
Write-Host "  Nodes    : $($inventory.Keys -join ', ')" -ForegroundColor Yellow
Write-Host ''
$answer = Read-Host '  Type REMOVE to proceed, anything else to abort'

if ( $answer -cne 'REMOVE' )
{
    Write-Host '  Aborted. Nothing was changed.' -ForegroundColor Green
    return
}

$removeScript = {
    param ( $Instance, $Features, $SetupPath )

    $log = @()

    if ( -not (Test-Path $SetupPath) )
    {
        $log += "[FAILED] setup.exe not found at '$SetupPath'. An uninstall needs the same media that installed it."
        return $log
    }

    # Not $args -- that is an automatic variable inside a scriptblock, and assigning to it
    # would shadow the block's own arguments.
    $setupArgs = @(
        '/Action=Uninstall'
        '/Q'
        '/IACCEPTSQLSERVERLICENSETERMS'
        "/INSTANCENAME=$Instance"
        "/FEATURES=$Features"
    )

    $log += "[RUN ] $SetupPath $($setupArgs -join ' ')"

    try
    {
        $p = Start-Process -FilePath $SetupPath -ArgumentList $setupArgs -Wait -PassThru -NoNewWindow
        $log += "[INFO] setup exit code $($p.ExitCode)"

        if ( $p.ExitCode -notin @(0, 3010) )
        {
            $log += "[FAILED] uninstall did not succeed. Read Summary.txt under 'C:\Program Files\Microsoft SQL Server\170\Setup Bootstrap\Log'."
        }
    }
    catch
    {
        $log += "[FAILED] $($_.Exception.Message)"
        return $log
    }

    # Verified rather than assumed -- setup returning 0 has already been shown, on this
    # very estate, not to mean the requested change actually happened.
    $svc = Get-CimInstance Win32_Service -Filter "Name='MSSQL`$$Instance'" -ErrorAction SilentlyContinue
    $log += if ( $svc ) { "[WARN] the service MSSQL`$$Instance still exists -- the instance was not fully removed" }
            else { "[OK  ] the service MSSQL`$$Instance is gone" }

    $keysLeft = @( Get-ChildItem 'HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server' -ErrorAction SilentlyContinue |
                     Where-Object { $_.PSChildName -match '^\d{2,3}$' } |
                     ForEach-Object { $_.PSChildName } | Sort-Object )
    $log += "[INFO] version keys remaining: $($keysLeft -join ', ')"

    if ( Test-Path 'C:\Program Files\Microsoft SQL Server\170' )
    {
        $log += "[WARN] 'C:\Program Files\Microsoft SQL Server\170' still exists -- the shared directory is still pinned to C:, so a reinstall will NOT honour a different volume"
    }

    return $log
}

foreach ( $node in $inventory.Keys )
{
    Write-Banner "REMOVING '$InstanceName' on $node"
    try
    {
        Invoke-Command -ComputerName $node -ScriptBlock $removeScript `
                       -ArgumentList $InstanceName, $Features, $SetupPath -ErrorAction Stop |
            ForEach-Object { Write-Host "  $_" }
    }
    catch
    {
        Write-Host "  [FAILED] $node -- $(($_.Exception.Message -replace '[\r\n]+',' ').Trim())" -ForegroundColor Red
    }
}

Write-Banner 'DONE -- verify before reinstalling'
Write-Host @"
  Reboot every node first. SQL setup refuses to install while a restart is pending, and an
  uninstall commonly leaves pending file renames behind:

      Restart-Computer -ComputerName <node> -Wait -For PowerShell -Force

  Then confirm the shared directory is genuinely gone. This is what decides whether a
  reinstall will honour a new volume:

      Invoke-Command -ComputerName <node> {
          Test-Path 'C:\Program Files\Microsoft SQL Server\170'
          Get-ChildItem 'HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server' -Name
      }

  If that path still exists, or version keys other than the one you removed remain, the
  shared directory is still pinned to C: -- rebuild the VM instead.

  Database files were NOT deleted. Remove them by hand once the rebuild is verified good.
"@ -ForegroundColor Yellow
