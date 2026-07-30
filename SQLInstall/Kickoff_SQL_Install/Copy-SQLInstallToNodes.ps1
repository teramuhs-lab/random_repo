<#
.SYNOPSIS
    Robocopies the whole C:\SQLInstall tree from the admin machine to each target node,
    copying only files that are new or have changed.

.DESCRIPTION
    Robocopy compares size and timestamp and skips anything already identical, so the
    first run to a fresh node copies everything and later runs copy only what you edited.

    Not /MIR: mirroring would DELETE files on the node that are absent from the admin
    machine, which would strip a working node if the admin copy were ever incomplete.

.PARAMETER ComputerName
    Target nodes.

.PARAMETER Source
    Toolkit root on the admin machine.

.PARAMETER Preview
    List what would be copied without copying it (robocopy /L).

.EXAMPLE
    .\Copy-SQLInstallToNodes.ps1 -Preview
    .\Copy-SQLInstallToNodes.ps1
#>
[CmdletBinding()]
param(
    [string[]] $ComputerName = @('DDCWNZWGDBS07', 'DDCWNZWGDBS08'),
    [string]   $Source       = 'C:\SQLInstall',

    # Folder names to skip, matched anywhere in the tree (robocopy /XD). Empty by
    # default so behaviour is unchanged unless you ask for it. The usual reason to set
    # this is the media for a SQL version this deployment does not install -- e.g. the
    # SQL2017 folder carries a 1.4 GB ISO that a SQLVersion = 'SQL2025' build never reads.
    [string[]] $ExcludeDir   = @(),

    # File names or wildcards to skip (robocopy /XF).
    [string[]] $ExcludeFile  = @(),

    [switch]   $Preview
)

if ( -not (Test-Path $Source) ) { throw "Source '$Source' not found." }

$logFile = Join-Path $env:TEMP ('SQLInstall_Copy_{0}.log' -f (Get-Date -Format 'yyyyMMdd_HHmmss'))
$failed  = @()

Write-Host ''
Write-Host "Source : $Source"
Write-Host "Targets: $($ComputerName -join ', ')"
Write-Host "Log    : $logFile"
if ( $Preview ) { Write-Host 'PREVIEW MODE - nothing will be copied' -ForegroundColor Yellow }
Write-Host ''

foreach ( $node in $ComputerName )
{
    $dest = "\\$node\c$\SQLInstall"

    if ( -not (Test-Path "\\$node\c$") )
    {
        Write-Host "[FAIL] $node - cannot reach \\$node\c`$ (offline, or no admin rights)" -ForegroundColor Red
        $failed += $node
        continue
    }

    Write-Host "[....] $node - copying ..." -ForegroundColor Cyan

    # /E    all subfolders, including empty ones
    # /XD   skip source-control noise
    # /R:2 /W:5   two retries, five seconds apart, instead of robocopy's default million
    # /NP   no per-file percentage counter, which floods the output
    # /NDL  no directory headers -- each file line carries its full path anyway
    # /TEE  echo to the console as well as the log; without it /LOG+ swallows everything,
    #       which is what previously made -Preview print nothing at all
    # /L    list only, when -Preview
    $flags = @('/E', '/XD', '.git') + $ExcludeDir
    if ( $ExcludeFile ) { $flags += @('/XF') + $ExcludeFile }
    $flags += @('/R:2', '/W:5', '/NP', '/NDL', '/TEE', "/LOG+:$logFile")
    if ( $Preview ) { $flags += '/L' }

    # Captured rather than streamed so the per-file lines can be summarised below.
    $output = & robocopy $Source $dest @flags
    $rc     = $LASTEXITCODE

    # Robocopy tags each file it acts on. Anything else in the stream is header,
    # summary or blank, and is not interesting here.
    $acted = @($output | Where-Object { $_ -match '\s(New File|Newer|Older|Changed|\*EXTRA File)\s' })

    $newFiles = @($acted | Where-Object { $_ -match '\sNew File\s' }).Count
    $updated  = @($acted | Where-Object { $_ -match '\s(Newer|Older|Changed)\s' }).Count
    $extra    = @($acted | Where-Object { $_ -match '\*EXTRA File' }).Count

    # Show what actually moved. Without this the script reports a bare exit code and you
    # cannot tell whether the files you edited were among them.
    foreach ( $line in ($acted | Where-Object { $_ -notmatch '\*EXTRA File' } | Select-Object -First 40) )
    {
        Write-Host "         $($line.Trim())" -ForegroundColor DarkGray
    }
    if ( ($acted.Count - $extra) -gt 40 )
    {
        Write-Host "         ... and $(($acted.Count - $extra) - 40) more; full list in $logFile" -ForegroundColor DarkGray
    }

    # Robocopy exit codes are a bit field, NOT a normal status: 0 = nothing needed
    # copying, 1 = files copied, 2 = extra files on the destination, 3 = both.
    # Only >= 8 contains a real failure bit. Testing -ne 0 would flag every
    # successful copy as an error.
    if ( $rc -ge 8 )
    {
        Write-Host "[FAIL] $node - robocopy exit code $rc; see $logFile" -ForegroundColor Red
        $failed += $node
    }
    else
    {
        $verb    = if ( $Preview ) { 'would copy' } else { 'copied' }
        $summary = "$verb $newFiles new, $updated changed"

        if ( $newFiles -eq 0 -and $updated -eq 0 ) { $summary = 'already up to date, nothing to copy' }

        Write-Host "[ OK ] $node - $summary (exit code $rc)" -ForegroundColor Green

        # Bit 2 means the node holds files the admin machine does not. Not an error --
        # this script never deletes -- but it is worth knowing, because it usually means
        # the node carries something left over from an earlier build.
        if ( $extra -gt 0 )
        {
            Write-Host "         note: $extra file(s) exist on $node but not on the admin machine (left alone, never deleted)" -ForegroundColor DarkYellow
        }
    }
}

Write-Host ''
if ( $failed.Count -gt 0 )
{
    Write-Host "FAILED on: $($failed -join ', ')" -ForegroundColor Red
    Write-Host "Full detail in $logFile" -ForegroundColor Red
    exit 1
}

# Distinguish preview from a real run. Printing "All nodes up to date" after a /L pass
# claims a state that was never reached -- nothing was copied, so nothing is up to date.
if ( $Preview )
{
    Write-Host 'Preview complete. NOTHING was copied - re-run without -Preview to apply.' -ForegroundColor Yellow
}
else
{
    Write-Host 'All nodes up to date.' -ForegroundColor Green
}
Write-Host ''

# Explicit success. Without this the process inherits robocopy's exit code, and robocopy
# returns 1 for "files were copied" -- so a successful run would look like a failure to
# anything gating on $LASTEXITCODE or ERRORLEVEL.
exit 0
