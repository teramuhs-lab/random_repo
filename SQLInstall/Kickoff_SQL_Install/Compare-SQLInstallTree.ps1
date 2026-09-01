<#
.SYNOPSIS
    Compares the SQLInstall tree on this machine against one or more target nodes and
    reports what is missing, short, or different.

.DESCRIPTION
    Written after three DSC modules were found truncated on target nodes while every
    existing check reported them present. The failures looked like missing modules --

        Could not find the module '.\Modules\DscResource.Base'
        Could not find the type of DSC resource class MSFT_xFirewall

    -- but the folders existed; they were simply empty or nearly so. Presence checks
    (Test-Path, Get-Module -ListAvailable) cannot see that. Only counting files can.

    Compares in two passes:

      1. A per-folder summary: file count and total size for each subtree, both sides.
         This is what makes a partial copy obvious at a glance.
      2. The specific files that differ, from robocopy in list-only mode -- it never
         copies anything, it only reports what a real copy would do.

    Read-only. Nothing is created, changed or deleted on either machine.

.PARAMETER ComputerName
    Target nodes to compare against.

.PARAMETER SourcePath
    The reference tree, normally C:\SQLInstall on the admin machine.

.PARAMETER Depth
    How deep to break down the summary. 2 gives SQLDSC\modules, SQLDSC\bits and so on,
    which is usually the right granularity.

.PARAMETER ShowFiles
    Also list the individual differing files. Off by default -- on a first run against a
    bare node that is thousands of lines.

.EXAMPLE
    .\Compare-SQLInstallTree.ps1 -ComputerName 'TDCWODWGDBS16'

.EXAMPLE
    .\Compare-SQLInstallTree.ps1 -ComputerName 'TDCWODWGDBS16','TDCWODWGDBS17' -ShowFiles

.NOTES
    Requires administrative access to each node's c$ share.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string[]] $ComputerName,

    [string] $SourcePath = 'C:\SQLInstall',

    [int] $Depth = 2,

    # Folders whose absence on a node is CORRECT, so comparing them only produces noise.
    #
    #   mofs  compiled MOF files. The environment configs set
    #         PSDSCAllowPlainTextPassword = $true, so a MOF can hold recoverable service
    #         and install account passwords. They must never reach a node -- reporting
    #         them as MISSING actively encourages copying them across.
    #   logs  run reports written on whichever machine ran the installer.
    #
    # Left in the first version, these produced nine false failures against a node that
    # was otherwise perfect, and buried the one real finding.
    [string[]] $ExcludeFolder = @('mofs', 'logs'),

    [switch] $ShowFiles
)

if ( -not (Test-Path -LiteralPath $SourcePath) ) { throw "Source '$SourcePath' not found." }

# Build "relative folder -> file count + bytes" for a tree. Comparing these two maps is
# what turns "the folder is there" into "the folder has what it should have".
function Get-TreeProfile
{
    param([string]$Root, [int]$MaxDepth, [string[]]$Skip = @())

    $profile = @{}

    # Normalise the root the SAME WAY the children report themselves, or the substring
    # below cuts at the wrong offset and every folder label comes out mangled
    # ("Install\SQLDSC\modules" instead of "SQLDSC\modules").
    #
    # Get-Item, not Resolve-Path: Resolve-Path preserves whatever form it was handed,
    # including an 8.3 short path such as C:\Users\LOCAL_~2\..., while Get-ChildItem
    # reports the expanded C:\Users\local_teramuh11\... for the children. Get-Item goes
    # through the same .NET FileSystemInfo the children do, so the two always agree.
    $Root    = (Get-Item -LiteralPath $Root).FullName.TrimEnd('\')
    $rootLen = $Root.Length

    Get-ChildItem -LiteralPath $Root -Recurse -File -ErrorAction SilentlyContinue | ForEach-Object {
        $rel   = $_.DirectoryName.Substring([Math]::Min($rootLen, $_.DirectoryName.Length)).TrimStart('\')
        $parts = if ( $rel ) { $rel -split '\\' } else { @() }

        # Skip anything under an excluded folder, at any level.
        if ( $Skip.Count -gt 0 -and ($parts | Where-Object { $Skip -contains $_ }) ) { return }

        $key   = if ( $parts.Count -eq 0 ) { '(root)' }
                 else { ($parts | Select-Object -First $MaxDepth) -join '\' }

        if ( -not $profile.ContainsKey($key) ) { $profile[$key] = [pscustomobject]@{ Files = 0; Bytes = [int64]0 } }
        $profile[$key].Files++
        $profile[$key].Bytes += $_.Length
    }

    return $profile
}

Write-Host ''
Write-Host "Reference : $SourcePath  (on $env:COMPUTERNAME)" -ForegroundColor Cyan
Write-Host "Comparing : $($ComputerName -join ', ')" -ForegroundColor Cyan
Write-Host ''

$srcProfile = Get-TreeProfile -Root $SourcePath -MaxDepth $Depth -Skip $ExcludeFolder
$srcFiles   = ($srcProfile.Values | Measure-Object -Property Files -Sum).Sum

Write-Host ("Reference tree: {0} files in {1} folder group(s)" -f $srcFiles, $srcProfile.Count) -ForegroundColor Gray
Write-Host ''

foreach ( $node in $ComputerName )
{
    $dstPath = "\\$node\c`$\SQLInstall"

    Write-Host ("=" * 78) -ForegroundColor Cyan
    Write-Host " NODE: $node" -ForegroundColor Cyan
    Write-Host ("=" * 78) -ForegroundColor Cyan

    if ( -not (Test-Path -LiteralPath $dstPath) )
    {
        Write-Host "  [FAIL] $dstPath not reachable, or SQLInstall does not exist there." -ForegroundColor Red
        continue
    }

    $dstProfile = Get-TreeProfile -Root $dstPath -MaxDepth $Depth -Skip $ExcludeFolder

    $rows = foreach ( $key in ($srcProfile.Keys + $dstProfile.Keys | Sort-Object -Unique) )
    {
        $s = $srcProfile[$key]
        $d = $dstProfile[$key]

        $sFiles = if ( $s ) { $s.Files } else { 0 }
        $dFiles = if ( $d ) { $d.Files } else { 0 }
        $sMB    = if ( $s ) { [math]::Round($s.Bytes/1MB,1) } else { 0 }
        $dMB    = if ( $d ) { [math]::Round($d.Bytes/1MB,1) } else { 0 }

        # 'Extra' is not a fault -- the node legitimately accumulates logs and its own
        # files. Only a SHORTFALL against the reference matters.
        $status = if ( $dFiles -eq 0 -and $sFiles -gt 0 ) { 'MISSING' }
                  elseif ( $dFiles -lt $sFiles )          { 'SHORT'   }
                  elseif ( $dFiles -gt $sFiles )          { 'extra'   }
                  else                                    { 'ok'      }

        [pscustomobject]@{
            Folder    = $key
            SrcFiles  = $sFiles
            NodeFiles = $dFiles
            Diff      = $dFiles - $sFiles
            SrcMB     = $sMB
            NodeMB    = $dMB
            Status    = $status
        }
    }

    $problems = @($rows | Where-Object { $_.Status -in 'MISSING','SHORT' })

    $rows | Sort-Object @{e={ $_.Status -in 'MISSING','SHORT' }; Descending=$true}, Folder |
        Format-Table Folder, SrcFiles, NodeFiles, Diff, SrcMB, NodeMB, Status -AutoSize |
        Out-String -Width 200 | Write-Host

    if ( $problems.Count -eq 0 )
    {
        Write-Host "  [OK] Every folder on $node has at least as many files as the reference." -ForegroundColor Green
    }
    else
    {
        Write-Host ("  [FAIL] {0} folder(s) short or missing on {1}:" -f $problems.Count, $node) -ForegroundColor Red
        foreach ( $p in $problems )
        {
            Write-Host ("         {0,-45} {1} of {2} files" -f $p.Folder, $p.NodeFiles, $p.SrcFiles) -ForegroundColor Yellow
        }

        Write-Host ''
        Write-Host "  To repair, from this machine:" -ForegroundColor Gray
        Write-Host "    robocopy '$SourcePath' '$dstPath' /E /R:2 /W:5 /NP /NDL" -ForegroundColor Gray
    }

    if ( $ShowFiles )
    {
        Write-Host ''
        Write-Host "  Individual differences (robocopy /L -- lists only, copies nothing):" -ForegroundColor Gray

        # /L makes robocopy report what a copy WOULD do without touching anything.
        $out = & robocopy $SourcePath $dstPath /E /L /R:0 /W:0 /NP /NDL /NJH /NJS
        $diff = @($out | Where-Object { $_ -match '\s(New File|Newer|Older|Changed)\s' })

        if ( $diff.Count -eq 0 ) { Write-Host '    (no file-level differences)' -ForegroundColor Green }
        else
        {
            $diff | Select-Object -First 60 | ForEach-Object { Write-Host "    $($_.Trim())" -ForegroundColor DarkGray }
            if ( $diff.Count -gt 60 ) { Write-Host "    ... and $($diff.Count - 60) more" -ForegroundColor DarkGray }
        }
    }

    Write-Host ''
}
