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

      USER database files are never deleted. The instance serving them goes; the
      .mdf/.ndf/.ldf stay, so a mistake is survivable.

      SSMS is not touched. Use Remove-SSMS.ps1 for that.

    WHAT IT CLEANS UP AFTERWARDS

    An uninstall leaves the instance's files behind, and two of those leftovers stop the
    NEXT install rather than the current one. Both are handled automatically:

      tempdb files    DELETED. Setup refuses to install over them and fails validation
                      with "The tempdb database file tempdb.mdf already exists in
                      F:\MSSQL\TempDB\<instance>", which reads as a mysterious error
                      rather than as leftover state. tempdb is rebuilt at every startup
                      and holds nothing, so deleting it costs nothing.

      user databases  MOVED, never deleted. A database whose files sat under the OLD
                      instance directory is orphaned there once the instance is gone, in
                      a folder that then looks like dead weight. On the server this was
                      written for that was 19.5 GB of production data, one "tidy up C:"
                      away from being lost. They are moved to
                      <RecoveredPath>\<instance>\_recovered and every file is named in
                      the log.

    Databases already living on the data volumes are left exactly where they are -- only
    the ones stranded inside the departing instance directory are moved.

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

.PARAMETER TempDbDir
    Root of the tempdb path from the environment file, WITHOUT the instance name -- the
    instance is appended. tempdb files found there are deleted after the uninstall.

.PARAMETER RecoveredPath
    Root of the user-database path, WITHOUT the instance name. Databases stranded in the
    old instance directory are moved to <RecoveredPath>\<instance>\_recovered. Pass an
    empty string to leave them in place and have them only reported.

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

    # Post-uninstall cleanup. tempdb files left behind here block the NEXT
    # install; user databases stranded in the old instance directory are moved
    # under $RecoveredPath rather than deleted.
    [string] $TempDbDir = 'F:\MSSQL\TempDB',

    [string] $RecoveredPath = 'G:\MSSQL\DATA',

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

        # The single fact that decides whether a reinstall can use a different volume.
        # Registry keys and Add/Remove entries can all be clear while this directory
        # survives, and while it does, setup keeps the shared path pinned to C:.
        SharedDirs  = @()
        Pending     = $false
    }

    foreach ( $drive in @('C:','D:','E:','F:','G:','H:') )
    {
        $p = "$drive\Program Files\Microsoft SQL Server"
        if ( Test-Path $p )
        {
            $vers = @( Get-ChildItem $p -Directory -ErrorAction SilentlyContinue |
                         Where-Object { $_.Name -match '^\d{2,3}$' } |
                         ForEach-Object { $_.Name } )
            if ( $vers.Count -gt 0 ) { $r.SharedDirs += "$p  [$($vers -join ', ')]" }
        }
    }

    $r.Pending = (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending') -or
                 (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired')

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
    #
    # Windows keeps its own .mdf files in the component store -- aspnetdb.mdf under
    # WinSxS and servicing, among others -- and an unfiltered scan of C:\ lists those as
    # though they were user databases. They are not, they are not at risk, and padding
    # the warning with them teaches the operator to skim past the part that matters.
    $excluded = @(
        [regex]::Escape($env:WINDIR)
        '\\WinSxS\\'
        '\\servicing\\'
        '\\Program Files\\WindowsApps\\'
    ) -join '|'

    foreach ( $root in @('C:','D:','E:','F:','G:','H:') )
    {
        if ( Test-Path "$root\" )
        {
            $r.UserDbFiles += @( Get-ChildItem "$root\" -Include '*.mdf','*.ndf' -Recurse -File -Force -ErrorAction SilentlyContinue |
                                   Where-Object { $_.Name -notmatch '^(master|model|msdb|tempdb|mssqlsystemresource)' } |
                                   Where-Object { $_.FullName -notmatch $excluded } |
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
    Write-Host "  Restart pending     : $($inv.Pending)" -ForegroundColor $(if ($inv.Pending) { 'Yellow' } else { 'Gray' })

    if ( @($inv.SharedDirs).Count -eq 0 )
    {
        Write-Host '  Shared directories  : none on disk -- a reinstall is free to use any volume' -ForegroundColor Green
    }
    else
    {
        foreach ( $d in $inv.SharedDirs ) { Write-Host "  Shared directory    : $d" -ForegroundColor Yellow }
    }

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

    # Registry keys and Add/Remove entries can all be clear while the directory itself
    # survives -- and the directory is what setup actually honours.
    $onC = @( $inv.SharedDirs | Where-Object { $_ -like 'C:*' } )
    if ( $onC.Count -gt 0 -and $legacy.Count -eq 0 )
    {
        Write-Host ''
        Write-Host "  [IMPORTANT] A shared directory still exists on C: even though no SQL products remain:" -ForegroundColor Magenta
        foreach ( $d in $onC ) { Write-Host "              $d" -ForegroundColor Magenta }
        Write-Host "              A reinstall will keep using it regardless of InstallShareDirectory." -ForegroundColor Magenta
        Write-Host "              Reboot first -- an uninstall often cannot delete files still in use, and" -ForegroundColor Magenta
        Write-Host "              the pending file-rename operations complete on restart. Re-check after." -ForegroundColor Magenta
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
$answer = Read-Host '  Type REMOVE in capitals to proceed, anything else to abort'

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


# ---------------------------------------------------------------------------
# POST-UNINSTALL CLEANUP
#
# An uninstall leaves the instance's files behind, and two of those leftovers
# stop the NEXT install rather than the current one:
#
#   tempdb files       setup refuses to install over them --
#                      "The tempdb database file tempdb.mdf already exists in
#                      F:\MSSQL\TempDB\<instance>" -- and fails before touching
#                      anything, which reads as a mysterious validation error
#                      rather than as leftover state.
#
#   user databases     a database whose files sat under the OLD instance
#                      directory is now orphaned in a folder that looks like
#                      dead weight. On the server this was written for, that was
#                      19.5 GB of production data one 'tidy up C:' away from
#                      being deleted.
#
# So: tempdb files are DELETED (they are rebuilt at every startup and hold
# nothing), and user database files are MOVED to a clearly named folder on a
# data volume. Nothing belonging to a user database is ever deleted here.
# ---------------------------------------------------------------------------
$cleanupScript = {
    param ( $Instance, $InstanceDir, $TempDbDir, $RecoveredRoot )

    $log = @()
    # templog.ldf is tempdb's LOG file and does not start with 'tempdb'.
    $systemDb = '^(master|model|msdb|tempdb|templog|mssqlsystemresource)'

    # --- tempdb, wherever it may block setup -------------------------------
    $tempPaths = @()
    if ( $TempDbDir )   { $tempPaths += (Join-Path $TempDbDir $Instance) }
    if ( $InstanceDir ) { $tempPaths += (Join-Path $InstanceDir 'MSSQL\DATA') }

    foreach ( $p in ($tempPaths | Sort-Object -Unique) )
    {
        if ( -not (Test-Path $p) ) { continue }

        $tempFiles = @( Get-ChildItem $p -File -Force -ErrorAction SilentlyContinue |
                          Where-Object { $_.Name -match '^(tempdb|templog)' } )

        if ( $tempFiles.Count -eq 0 ) { $log += "[OK  ] no tempdb files in '$p'"; continue }

        try
        {
            $tempFiles | Remove-Item -Force -ErrorAction Stop
            $log += "[FIXED] deleted $($tempFiles.Count) tempdb file(s) from '$p'"
        }
        catch
        {
            $log += "[FAILED] could not delete tempdb files in '$p': $($_.Exception.Message)"
        }
    }

    # --- user databases stranded in the old instance directory -------------
    if ( $InstanceDir )
    {
        $oldData = Join-Path $InstanceDir 'MSSQL\DATA'

        if ( Test-Path $oldData )
        {
            $stranded = @( Get-ChildItem $oldData -File -Force -ErrorAction SilentlyContinue |
                             Where-Object { $_.Extension -in '.mdf','.ndf','.ldf','.tuf' -and $_.Name -notmatch $systemDb } )

            if ( $stranded.Count -eq 0 )
            {
                $log += "[OK  ] no user database files stranded in '$oldData'"
            }
            elseif ( -not $RecoveredRoot )
            {
                $log += "[WARN] $($stranded.Count) user database file(s) in '$oldData' -- no -RecoveredPath given, so they were LEFT IN PLACE. Do not delete that folder."
                $stranded | ForEach-Object { $log += "        $($_.Name)  ($('{0:N1}' -f ($_.Length/1GB)) GB)" }
            }
            else
            {
                $dest = Join-Path (Join-Path $RecoveredRoot $Instance) '_recovered'
                try
                {
                    New-Item -ItemType Directory $dest -Force | Out-Null

                    # Moved one at a time so a single failure does not hide the rest,
                    # and so the log names every file that was relocated.
                    foreach ( $f in $stranded )
                    {
                        Move-Item -LiteralPath $f.FullName -Destination $dest -Force -ErrorAction Stop
                        $log += "[MOVED] $($f.Name)  ($('{0:N1}' -f ($f.Length/1GB)) GB)  -> $dest"
                    }
                }
                catch
                {
                    $log += "[FAILED] moving user database files to '$dest': $($_.Exception.Message)"
                }
            }
        }
    }

    # --- what is left, so nothing is deleted on assumption -----------------
    if ( $InstanceDir -and (Test-Path $InstanceDir) )
    {
        $rest = Get-ChildItem $InstanceDir -Recurse -File -Force -ErrorAction SilentlyContinue |
                  Measure-Object Length -Sum
        $log += "[INFO] '$InstanceDir' still holds $($rest.Count) file(s), $('{0:N1}' -f ($rest.Sum/1GB)) GB -- logs and traces once the moves above are done. Safe to delete AFTER the reinstall is verified."
    }

    return $log
}

foreach ( $node in $inventory.Keys )
{
    Write-Banner "CLEANING UP on $node"

    # The instance directory is derived from the engine path captured BEFORE the
    # uninstall -- afterwards the service is gone and there is nothing left to ask.
    $instanceDir = $null
    $enginePath  = $inventory[$node].EnginePath

    if ( $enginePath -and $enginePath -match '^"?([^"]+sqlservr\.exe)' )
    {
        # ...\MSSQL17.CAPPT\MSSQL\Binn\sqlservr.exe -> ...\MSSQL17.CAPPT
        $instanceDir = Split-Path (Split-Path (Split-Path $Matches[1] -Parent) -Parent) -Parent
        Write-Host "  Old instance directory : $instanceDir" -ForegroundColor Gray
    }
    else
    {
        Write-Host '  [WARN] could not determine the old instance directory from the engine service path -- stranded database files will not be found' -ForegroundColor Yellow
    }

    try
    {
        Invoke-Command -ComputerName $node -ScriptBlock $cleanupScript `
                       -ArgumentList $InstanceName, $instanceDir, $TempDbDir, $RecoveredPath -ErrorAction Stop |
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
