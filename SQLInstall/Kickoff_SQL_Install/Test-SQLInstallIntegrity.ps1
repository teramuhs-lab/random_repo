<#
.SYNOPSIS
    Verifies a SQLInstall tree against a SHA-256 manifest -- the definitive "is this the
    gold copy?" check. Also generates the manifest.

.DESCRIPTION
    Compare-SQLInstallTree counts files, which catches a truncated copy. It cannot catch a
    file that is present but wrong: a stale script, a half-written binary that happens to
    have the right count, or an edit someone made directly on a server. This hashes.

    Two modes:

      -CreateManifest   walk the tree, write SHA-256 for every file to a manifest, and
                        keep the manifest in source control. Run it against the copy you
                        trust -- normally the repository.

      (default)         verify a tree against that manifest and report every file that is
                        missing, altered, or unexpected.

    WHAT IS HASHED, AND WHAT IS NOT

    Everything under SQLDSC\{configs, Help Functions, SQLScripts, environments, modules},
    Kickoff_SQL_Install, docs, and the loose files at the root. That is the code and the
    modules -- the parts that decide whether a deployment behaves correctly.

    SQLDSC\bits is EXCLUDED by default. It is several gigabytes of vendor installation
    media; hashing it takes far longer than it is worth, and it does not change. Use
    -IncludeBits to cover it with size-and-count instead of hashes.

    SQLDSC\mofs and logs are always excluded. MOFs can contain plaintext credentials and
    logs are per-run; neither belongs in an integrity baseline.

.PARAMETER Path
    Tree to verify or to generate the manifest from. Defaults to the SQLInstall folder
    containing this script.

.PARAMETER ManifestPath
    Where the manifest lives. Defaults to docs\INTEGRITY_MANIFEST.txt inside -Path.

.PARAMETER CreateManifest
    Generate the manifest instead of verifying against it.

.PARAMETER IncludeBits
    Also report on SQLDSC\bits, by file count and total size per folder rather than by
    hash.

.PARAMETER ComputerName
    Verify remote nodes over their admin share instead of a local path. The manifest is
    always read from the local -Path.

.EXAMPLE
    .\Test-SQLInstallIntegrity.ps1 -CreateManifest

    Generate the baseline from this copy. Do this on the copy you trust, then commit it.

.EXAMPLE
    .\Test-SQLInstallIntegrity.ps1

    Verify this machine's toolkit against the committed manifest.

.EXAMPLE
    .\Test-SQLInstallIntegrity.ps1 -ComputerName 'NODE01','NODE02'

    Verify two nodes against the manifest held on this machine.

.NOTES
    Read-only in verify mode. Exits 1 if anything fails, so it can gate a deployment.
#>
[CmdletBinding()]
param(
    [string]   $Path,
    [string]   $ManifestPath,
    [switch]   $CreateManifest,
    [switch]   $IncludeBits,
    [string[]] $ComputerName
)

if ( -not $Path ) { $Path = Split-Path -Path $PSScriptRoot -Parent }
$Path = (Get-Item -LiteralPath $Path).FullName.TrimEnd('\')

if ( -not $ManifestPath ) { $ManifestPath = Join-Path $Path 'docs\INTEGRITY_MANIFEST.txt' }

# Folders never covered. 'bits' is handled separately via -IncludeBits.
$alwaysSkip = @('mofs', 'logs', '.git')

function Get-CoveredFiles
{
    param([string]$Root, [switch]$WithBits)

    $rootLen = (Get-Item -LiteralPath $Root).FullName.TrimEnd('\').Length
    $skip    = $alwaysSkip + $(if ( -not $WithBits ) { 'bits' } else { @() })

    Get-ChildItem -LiteralPath $Root -Recurse -File -ErrorAction SilentlyContinue | ForEach-Object {
        $rel   = $_.FullName.Substring($rootLen).TrimStart('\')
        $parts = $rel -split '\\'
        if ( $parts | Where-Object { $skip -contains $_ } ) { return }
        [pscustomobject]@{ Relative = $rel; File = $_ }
    }
}

# ---------------------------------------------------------------------------
# Generate
# ---------------------------------------------------------------------------
if ( $CreateManifest )
{
    Write-Host "Generating manifest from: $Path" -ForegroundColor Cyan

    $covered = @(Get-CoveredFiles -Root $Path)
    $lines   = New-Object System.Collections.Generic.List[string]

    $lines.Add("# SQLInstall integrity manifest")
    $lines.Add("# Generated from : $Path")
    $lines.Add("# Files          : $($covered.Count)")
    $lines.Add("# Format         : <sha256>  <size>  <relative path>")
    $lines.Add("#")
    $lines.Add("# SQLDSC\bits is deliberately not hashed -- vendor media, gigabytes, unchanging.")
    $lines.Add("# SQLDSC\mofs and logs are never included: MOFs can hold plaintext credentials.")

    $i = 0
    foreach ( $c in ($covered | Sort-Object Relative) )
    {
        $i++
        if ( $i % 200 -eq 0 ) { Write-Host "  hashed $i of $($covered.Count) ..." -ForegroundColor DarkGray }
        $h = (Get-FileHash -LiteralPath $c.File.FullName -Algorithm SHA256).Hash
        $lines.Add("$h  $($c.File.Length)  $($c.Relative)")
    }

    $manifestDir = Split-Path $ManifestPath -Parent
    if ( -not (Test-Path $manifestDir) ) { New-Item -Path $manifestDir -ItemType Directory -Force | Out-Null }

    Set-Content -Path $ManifestPath -Value $lines -Encoding UTF8
    Write-Host "  [OK] $($covered.Count) files hashed -> $ManifestPath" -ForegroundColor Green
    exit 0
}

# ---------------------------------------------------------------------------
# Verify
# ---------------------------------------------------------------------------
if ( -not (Test-Path -LiteralPath $ManifestPath) )
{
    throw "Manifest not found at '$ManifestPath'. Generate one with -CreateManifest against a copy you trust."
}

$expected = @{}
foreach ( $line in (Get-Content -LiteralPath $ManifestPath) )
{
    if ( $line -match '^\s*#' -or -not $line.Trim() ) { continue }
    # <sha256>  <size>  <relative path>   -- the path may contain spaces, so split on the
    # first two runs of whitespace only.
    if ( $line -match '^(\S+)\s+(\d+)\s+(.+)$' )
    {
        $expected[$Matches[3]] = [pscustomobject]@{ Hash = $Matches[1]; Size = [int64]$Matches[2] }
    }
}

Write-Host ''
Write-Host "Manifest : $ManifestPath  ($($expected.Count) files)" -ForegroundColor Cyan

$targets = if ( $ComputerName ) { $ComputerName } else { @($env:COMPUTERNAME) }
$anyFail = $false

foreach ( $target in $targets )
{
    $treePath = if ( $target -eq $env:COMPUTERNAME ) { $Path } else { "\\$target\c`$\SQLInstall" }

    Write-Host ''
    Write-Host ("=" * 78) -ForegroundColor Cyan
    Write-Host " $target  --  $treePath" -ForegroundColor Cyan
    Write-Host ("=" * 78) -ForegroundColor Cyan

    if ( -not (Test-Path -LiteralPath $treePath) )
    {
        Write-Host "  [FAIL] not reachable, or SQLInstall does not exist there." -ForegroundColor Red
        $anyFail = $true
        continue
    }

    $actual = @{}
    foreach ( $c in (Get-CoveredFiles -Root $treePath) ) { $actual[$c.Relative] = $c.File }

    $missing = New-Object System.Collections.Generic.List[string]
    $altered = New-Object System.Collections.Generic.List[string]
    $checked = 0

    foreach ( $rel in $expected.Keys )
    {
        if ( -not $actual.ContainsKey($rel) ) { $missing.Add($rel); continue }

        $checked++
        $f = $actual[$rel]

        # Compare size first -- it is free, and catches most differences without reading
        # the file across the network.
        if ( $f.Length -ne $expected[$rel].Size )
        {
            $altered.Add("$rel  (size $($f.Length), expected $($expected[$rel].Size))")
            continue
        }

        if ( (Get-FileHash -LiteralPath $f.FullName -Algorithm SHA256).Hash -ne $expected[$rel].Hash )
        {
            $altered.Add("$rel  (content differs)")
        }
    }

    $unexpected = @($actual.Keys | Where-Object { -not $expected.ContainsKey($_) })

    Write-Host ("  verified {0} file(s)" -f $checked) -ForegroundColor Gray

    if ( $missing.Count -eq 0 -and $altered.Count -eq 0 )
    {
        Write-Host "  [OK] Every file in the manifest is present and identical." -ForegroundColor Green
    }
    else
    {
        $anyFail = $true
        if ( $missing.Count ) { Write-Host "  [FAIL] $($missing.Count) missing:" -ForegroundColor Red
                                $missing | Select-Object -First 30 | ForEach-Object { Write-Host "         $_" -ForegroundColor Yellow }
                                if ( $missing.Count -gt 30 ) { Write-Host "         ... and $($missing.Count - 30) more" -ForegroundColor Yellow } }
        if ( $altered.Count ) { Write-Host "  [FAIL] $($altered.Count) altered:" -ForegroundColor Red
                                $altered | Select-Object -First 30 | ForEach-Object { Write-Host "         $_" -ForegroundColor Yellow }
                                if ( $altered.Count -gt 30 ) { Write-Host "         ... and $($altered.Count - 30) more" -ForegroundColor Yellow } }
    }

    # Extra files are reported but never treated as a failure -- a machine legitimately
    # accumulates its own environment files, and the manifest is a floor, not a ceiling.
    if ( $unexpected.Count )
    {
        Write-Host "  [INFO] $($unexpected.Count) file(s) present but not in the manifest (not a fault):" -ForegroundColor Cyan
        $unexpected | Select-Object -First 10 | ForEach-Object { Write-Host "         $_" -ForegroundColor DarkGray }
        if ( $unexpected.Count -gt 10 ) { Write-Host "         ... and $($unexpected.Count - 10) more" -ForegroundColor DarkGray }
    }

    if ( $IncludeBits )
    {
        $bits = Join-Path $treePath 'SQLDSC\bits'
        if ( Test-Path $bits )
        {
            $bf = @(Get-ChildItem $bits -Recurse -File -ErrorAction SilentlyContinue)
            Write-Host ("  [INFO] SQLDSC\bits: {0} files, {1:N1} GB (not hashed)" -f $bf.Count, (($bf | Measure-Object Length -Sum).Sum/1GB)) -ForegroundColor Cyan
        }
        else { Write-Host "  [WARN] SQLDSC\bits not present." -ForegroundColor Yellow }
    }
}

Write-Host ''
if ( $anyFail ) { Write-Host 'RESULT: FAIL -- see above.' -ForegroundColor Red; exit 1 }
Write-Host 'RESULT: PASS -- all verified copies match the manifest.' -ForegroundColor Green
exit 0
