<#
.SYNOPSIS
    Lists the SQL Server edition product IDs (PIDs) a node's media can install, what each
    one selects, and which edition the node is currently running.

.DESCRIPTION
    Edition is chosen at install time by PID. SQLProductKey in the environment .psd1
    supplies it; with that empty, setup falls back to the PID in the media's
    x64\DefaultSetup.ini. Getting it wrong is invisible until after the install.

    NOTHING ON A BUILT MACHINE RECORDS THE PID IT WAS INSTALLED WITH. Summary.txt masks
    it ("PID: *****"), the generated ConfigurationFile.ini omits it, and the Setup
    registry key keeps only the edition NAME -- there is no DigitalProductID to decode.
    All three were checked on DDCWNZWGDBS04 on 2026-09-01 and all three came back empty.
    That is why the table below exists: it is the only record.

    HOW THE TABLE WAS ESTABLISHED
    The media carries the PIDs but not their meaning -- they sit in
    Microsoft.SqlServer.Configuration.SetupExtension.dll as a bare list beside the literal
    FREEEDITIONS, with no edition names adjacent, so the mapping is in compiled code and
    cannot be read out. It was established empirically instead, by launching setup's
    wizard with each PID and reading which edition the Edition page preselected:

        setup.exe /ACTION=Install /UIMODE=Normal /PID=<candidate>

    Cancel at the Edition page; nothing is installed.

    WHAT THIS SCRIPT WILL NOT DO
    It will not guess. A PID found in the media that is not in the table is reported as
    UNKNOWN together with the command to identify it. A future SQL Server version may use
    different PIDs entirely, and a plausible-looking assumption here would be worse than
    no answer -- a wrong edition is only discoverable after an install, and cannot be
    fixed without /ACTION=EditionUpgrade or a rebuild.

.PARAMETER ComputerName
    Nodes to inspect. Each is checked for its media, its DefaultSetup.ini default PID, and
    the edition it is actually running.

.PARAMETER MediaPath
    Root of the staged SQL Server media on those nodes.

.PARAMETER Instance
    Instance name, used to read the installed edition from the registry.

.PARAMETER Build
    MSSQL<NN> build number for the instance key: 17 = SQL2025, 14 = SQL2017.

.EXAMPLE
    .\Get-SqlEditionPids.ps1 -ComputerName DDCWNZWGDBS03,DDCWNZWGDBS04

.EXAMPLE
    .\Get-SqlEditionPids.ps1 -ComputerName PDCWODWGDBSVR -Instance CAPPT

    Production. Reports which edition it is running and which PID its media defaults to.

.NOTES
    Read-only. Opens files and registry keys for reading and writes nothing.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string[]] $ComputerName,

    [string] $MediaPath = 'C:\SQLInstall\SQLDSC\bits\SQL2025',

    [string] $Instance  = 'CAPPT',

    [string] $Build     = '17'
)

$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# The mapping. Each entry records HOW it was established, because "verified" and
# "assumed" are not the same claim and the difference decides whether you can act on it.
#
# Established for SQL Server 2025 (17.0.1000.7) media. A different major version may use
# different PIDs -- re-verify with the wizard rather than trusting this table.
# ---------------------------------------------------------------------------
$knownPids = [ordered]@{
    '00000-00000-00000-00000-00000' = @{
        Edition  = 'Evaluation'
        Verified = $false
        How      = 'INFERRED by elimination -- the remaining entry after the other three were confirmed. NOT tested. Evaluation EXPIRES after 180 days and stops the instance, so confirm before using it.'
    }
    '11111-00000-00000-00000-00000' = @{
        Edition  = 'Express'
        Verified = $true
        How      = 'wizard preselected Express for this PID -- DDCWNZWGDBS04, 2026-09-01'
    }
    '22222-00000-00000-00000-00000' = @{
        Edition  = 'Enterprise Developer'
        Verified = $true
        How      = 'wizard preselected Enterprise Developer; install completed and reported it -- DDCWNZWGDBS04, 2026-09-01'
    }
    '33333-00000-00000-00000-00000' = @{
        Edition  = 'Standard Developer'
        Verified = $true
        How      = "media's own x64\DefaultSetup.ini default, confirmed by Summary.txt on DDCWNZWGDBS03"
    }
}

# DELIBERATELY EMPTY -- and it must stay that way.
#
# An earlier version of this script hardcoded two real 25-character keys found in the
# media, labelled "Azure billing PIDs" because they sat near the literal
# AZUREBILLEDEDITIONS in SetupExtension.dll. That was an inference from string proximity
# and it was wrong: PDCWODWGDBSVR's own x64\DefaultSetup.ini carries one of them, that
# node has an empty SQLProductKey, and it is running Enterprise Edition: Core-based
# Licensing. The key selects a PAID edition -- it is a licence key, not a placeholder.
#
# This file is in version control and pushed to GitHub, so no real key belongs in it.
# The four free-edition placeholders above (00000/11111/22222/33333) are not secrets;
# anything else found in a media is treated as UNKNOWN and printed with the command to
# identify it, rather than being named here.

function Write-Banner
{
    param([string] $Text)
    Write-Host ''
    Write-Host ('=' * 80) -ForegroundColor Cyan
    Write-Host " $Text" -ForegroundColor Cyan
    Write-Host ('=' * 80) -ForegroundColor Cyan
}

Write-Banner 'KNOWN EDITION PIDs (SQL Server 2025 media)'
foreach ( $pid_ in $knownPids.Keys )
{
    $e = $knownPids[$pid_]
    $tag = if ( $e.Verified ) { 'verified ' } else { 'INFERRED ' }
    $col = if ( $e.Verified ) { 'Green' } else { 'Yellow' }
    Write-Host ("  {0}  {1,-22} [{2}]" -f $pid_, $e.Edition, $tag) -ForegroundColor $col
    Write-Host ("      {0}" -f $e.How) -ForegroundColor DarkGray
}
Write-Host ''
Write-Host '  Any OTHER key found in a media is a paid-edition licence key, not a free-edition' -ForegroundColor Yellow
Write-Host '  selector. PDCWODWGDBSVR installs Enterprise Core-based from one baked into its own' -ForegroundColor Yellow
Write-Host '  DefaultSetup.ini. Treat those as secrets: do not copy them into the .psd1, this' -ForegroundColor Yellow
Write-Host '  script, or anything else that reaches version control.' -ForegroundColor Yellow

$inspect = {
    param($MediaPath, $Instance, $Build, $KnownList)

    # The default the media applies when SQLProductKey is empty.
    $defaultPid = $null
    $ini = Join-Path $MediaPath 'x64\DefaultSetup.ini'
    if ( Test-Path $ini )
    {
        $line = Select-String -Path $ini -Pattern '^\s*PID\s*=' -ErrorAction SilentlyContinue | Select-Object -First 1
        if ( $line ) { $defaultPid = ($line.Line -replace '^\s*PID\s*=', '') -replace '"', '' }
    }

    # Every PID the media carries. Anchored on a PID already known: if no known PID is
    # found, the extraction is not working on this media and its output must not be
    # treated as a PID list.
    $found = @()
    $anchored = $false
    $dllRoot = Join-Path $MediaPath 'x64'
    if ( Test-Path $dllRoot )
    {
        $files = Get-ChildItem $dllRoot -File -ErrorAction SilentlyContinue |
                   Where-Object { $_.Extension -match '^\.(dll|ini)$' -and $_.Length -le 80MB }

        foreach ( $f in $files )
        {
            try   { $bytes = [IO.File]::ReadAllBytes($f.FullName) } catch { continue }

            # UTF-16LE strings can start at an odd byte offset; decoding only from 0
            # silently misses half of them.
            $texts = @( [Text.Encoding]::ASCII.GetString($bytes),
                        [Text.Encoding]::Unicode.GetString($bytes) )
            if ( $bytes.Length -gt 1 ) { $texts += [Text.Encoding]::Unicode.GetString($bytes, 1, $bytes.Length - 1) }

            foreach ( $t in $texts )
            {
                foreach ( $m in [regex]::Matches($t, '[A-Z0-9]{5}(?:-[A-Z0-9]{5}){4}') )
                {
                    $found += $m.Value
                    if ( $KnownList -contains $m.Value ) { $anchored = $true }
                }
            }
        }
    }

    # What this node is actually running.
    $setup = Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\MSSQL$Build.$Instance\Setup" -ErrorAction SilentlyContinue

    [PSCustomObject]@{
        Node        = $env:COMPUTERNAME
        MediaExists = (Test-Path $MediaPath)
        DefaultPid  = $defaultPid
        Anchored    = $anchored
        FoundPids   = @($found | Sort-Object -Unique)
        Edition     = $setup.Edition
        FeatureList = $setup.FeatureList
    }
}

foreach ( $node in $ComputerName )
{
    try
    {
        $r = Invoke-Command -ComputerName $node -ScriptBlock $inspect `
                            -ArgumentList $MediaPath, $Instance, $Build, @($knownPids.Keys) -ErrorAction Stop
    }
    catch
    {
        Write-Host ''
        Write-Host "  [UNREACHABLE] $node -- $(($_.Exception.Message -replace '[\r\n]+',' ').Trim())" -ForegroundColor Red
        continue
    }

    Write-Banner "NODE: $($r.Node)"
    Write-Host ("  Currently running   : {0}" -f $(if ($r.Edition) { $r.Edition } else { "no $Instance instance found" }))
    Write-Host ("  Media present       : {0}  ({1})" -f $r.MediaExists, $MediaPath)
    Write-Host ("  DefaultSetup.ini PID: {0}" -f $(if ($r.DefaultPid) { $r.DefaultPid } else { '(not readable)' }))

    if ( $r.DefaultPid -and $knownPids.Contains($r.DefaultPid) )
    {
        Write-Host ("                        -> installs as {0} when SQLProductKey is empty" -f $knownPids[$r.DefaultPid].Edition)
    }

    if ( -not $r.Anchored )
    {
        Write-Host '  PIDs in media       : extraction found no PID this script recognises.' -ForegroundColor Red
        Write-Host '                        Treat the list below as UNIDENTIFIED, not as edition keys.' -ForegroundColor Red
    }

    Write-Host '  PIDs carried by the media:'
    foreach ( $p in $r.FoundPids )
    {
        if ( $knownPids.Contains($p) )
        {
            $e = $knownPids[$p]
            $col = if ( $e.Verified ) { 'Green' } else { 'Yellow' }
            Write-Host ("      {0}  {1}" -f $p, $e.Edition) -ForegroundColor $col
        }
        else
        {
            # Not one of the four free-edition placeholders, so it is a paid-edition
            # licence key. Shown because the operator needs to see what their media
            # carries, flagged because it must not be pasted anywhere public.
            Write-Host ("      {0}  NOT a free-edition selector -- treat as a LICENCE KEY" -f $p) -ForegroundColor Red
            Write-Host  '          Do not copy it into the .psd1 or any file under version control.' -ForegroundColor Red
            Write-Host ("          To see which edition it installs: {0}\setup.exe /ACTION=Install /UIMODE=Normal /PID=<key>" -f $MediaPath) -ForegroundColor DarkGray
            Write-Host  '          then read the Edition page and CANCEL. Nothing is installed.' -ForegroundColor DarkGray
        }
    }
}

Write-Banner 'TO CHANGE THE EDITION'
Write-Host "  Set SQLProductKey in the environment .psd1 -- NOT the media's DefaultSetup.ini," -ForegroundColor Yellow
Write-Host '  which is vendor media and is overwritten whenever the media is restaged:' -ForegroundColor Yellow
Write-Host ''
Write-Host "      SQLProductKey = '22222-00000-00000-00000-00000'   # Enterprise Developer" -ForegroundColor Gray
Write-Host ''
Write-Host '  Applies at INSTALL time only. It will not convert an existing instance --' -ForegroundColor Yellow
Write-Host '  that needs /ACTION=EditionUpgrade or a rebuild. Confirm the result afterwards' -ForegroundColor Yellow
Write-Host "  with Test_SQLServer_PostInstall.ps1, which reports the engine's own Edition." -ForegroundColor Yellow
