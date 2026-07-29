<#
.SYNOPSIS
    Publishes changed toolkit files from the source repo to the admin machine
    (C:\SQLInstall), then pushes the SQLScripts folder from the admin machine out to
    each target node.

.DESCRIPTION
    Two stages, either of which can be run on its own:

      Stage 1  repo  -> admin machine   (C:\SQLInstall\...)
      Stage 2  admin -> target nodes    (\\<node>\c$\SQLInstall\SQLDSC\SQLScripts)

    Stage 2 exists because the environment configs used here set

        Copy_all_Files_to_TargetNodes = 'NO'

    and the DSC resource that would otherwise sync the scripts folder
    ([File]CopySQLScriptsFolderLocally) lives inside the 'YES' branch of
    Install_and_Configure_SQLServer_Multi_Node_SqlServerDsc.ps1. With 'NO', nothing
    copies the scripts to the nodes  -- but the SqlScript resources still execute
    SetFilePath from the node's LOCAL C:\SQLInstall\SQLDSC\SQLScripts. A node that
    never received the update silently runs the previous version of the script.

    Every copy is verified by SHA-256 comparison of source and destination, because a
    partial or blocked copy here is not discovered until it fails mid-deployment.

.PARAMETER SourceRoot
    The SQLInstall folder in the source repo. Defaults to the parent of this script's
    folder, so running it in place needs no arguments.

.PARAMETER AdminRoot
    Toolkit root on the admin/management machine. This is the folder published as the
    \\<admin>\SQLInstall share that the environment .psd1 files point at.

.PARAMETER ComputerName
    Target nodes to receive the SQLScripts folder. Defaults to the nodes in
    InstallConfigure_SQLServer2025-CAPPT.psd1.

.PARAMETER IncludeOlderChanges
    Also publish the files that changed on 28 Jul 2026 (post-install verification
    script, high-severity alerts, environment .psd1 files, docs). Use this if the
    admin machine's copy predates that day's commits.

.PARAMETER IncludeBits
    Also push the installation media (.NET 3.5 source, SQL patches, SSMS layout, SQL
    media) from the admin machine to each node, via robocopy. Needed for nodes that have
    never been built, because Copy_all_Files_to_TargetNodes = 'NO' means DSC does not
    stage them, yet setup.exe reads several of these paths locally on the target.

.PARAMETER BitsSubfolder
    Which subfolders of SQLDSC\bits to push when -IncludeBits is given. Defaults to
    Sxs, SQLPatches, SSMS and SQL2025. Narrow it to skip the multi-gigabyte SQL media
    when only the patches changed.

.PARAMETER AdminOnly
    Run stage 1 only.

.PARAMETER NodesOnly
    Run stage 2 only -- pushes whatever is already on the admin machine.

.EXAMPLE
    .\Publish-SQLInstallFiles.ps1 -WhatIf

    Show everything that would be copied, without copying anything.

.EXAMPLE
    .\Publish-SQLInstallFiles.ps1

    Publish the current change set to the admin machine and both CAPPT nodes.

.EXAMPLE
    .\Publish-SQLInstallFiles.ps1 -IncludeOlderChanges -ComputerName 'NODE01','NODE02'

    Publish the full set since 22 Jul 2026 to a different pair of nodes.

.EXAMPLE
    .\Publish-SQLInstallFiles.ps1 -NodesOnly -ComputerName 'DDCWNZWGDBS05','DDCWNZWGDBS06' -IncludeBits

    Stage everything a never-built pair of nodes needs: the SQLScripts folder and the
    installation media, from the admin machine's copy.

.EXAMPLE
    .\Publish-SQLInstallFiles.ps1 -NodesOnly -ComputerName 'DDCWNZWGDBS05' -IncludeBits -BitsSubfolder 'SQLPatches'

    Push only the patches folder -- useful after a CU drop, when the multi-gigabyte SQL
    media has not changed.

.NOTES
    Requires administrative access to each node's c$ share. Run from an elevated
    PowerShell session on the admin machine.
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [string]   $SourceRoot,

    [string]   $AdminRoot = 'C:\SQLInstall',

    [string[]] $ComputerName = @('DDCWNZWGDBS03', 'DDCWNZWGDBS04'),

    [switch]   $IncludeOlderChanges,

    [switch]   $IncludeBits,

    [string[]] $BitsSubfolder = @('Sxs', 'SQLPatches', 'SSMS', 'SQL2025'),

    [switch]   $AdminOnly,

    [switch]   $NodesOnly
)

$ErrorActionPreference = 'Stop'

if ( -not $SourceRoot )
{
    $SourceRoot = Split-Path -Path $PSScriptRoot -Parent
}

# Relative to the SQLInstall root, in both the repo and on the admin machine, so one
# list drives the copy and the verification.
$currentChangeSet = @(
    # This script publishes itself, so the admin machine's copy stays current without
    # anyone having to remember to hand-copy it.
    'Kickoff_SQL_Install\Publish-SQLInstallFiles.ps1'
    'Kickoff_SQL_Install\Start_SQL_Server_Installation_Multiple_Node.ps1'
    'SQLDSC\configs\Install_and_Configure_SQLServer_Multi_Node_SqlServerDsc.ps1'
    'SQLDSC\Help Functions\Test-RequiredDscModules.ps1'
    'SQLDSC\SQLScripts\DatabaseMaintenanceSolution_Get.sql'
    'SQLDSC\SQLScripts\DatabaseMaintenanceSolution_Set.sql'
    'README.md'
)

# The 28 Jul 2026 commits. Only needed when the admin machine is further behind.
$olderChangeSet = @(
    'SQLDSC\SQLScripts\Alerts_HighSeverity_Set.sql'
    'SQLDSC\SQLScripts\Alerts_HighSeverity_Test.sql'
    'SQLDSC\configs\Test_SQLServer_PostInstall.ps1'
    'SQLDSC\configs\Install_and_Configure_SQLServer_Multi_Node.ps1'
    'SQLDSC\modules\README.md'
    'docs\INSTALLATION_FLOW.md'
    '.gitignore'
)

$scriptsFolderRelative = 'SQLDSC\SQLScripts'

$results = New-Object System.Collections.Generic.List[object]

function Add-Result
{
    param($Stage, $Target, $Item, $Status, $Detail)

    $results.Add([pscustomobject]@{
        Stage  = $Stage
        Target = $Target
        Item   = $Item
        Status = $Status
        Detail = $Detail
    })

    $colour = switch ( $Status )
    {
        'OK'      { 'Green'  }
        'SKIPPED' { 'Cyan'   }
        'WARN'    { 'Yellow' }
        default   { 'Red'    }
    }

    Write-Host ("  [{0,-7}] {1,-22} {2} {3}" -f $Status, $Target, $Item, $Detail) -ForegroundColor $colour
}

# A copy that reports success without the bytes landing is the failure mode this whole
# script exists to prevent, so confirm content rather than trusting the exit of Copy-Item.
function Copy-Verified
{
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [string] $Source,
        [string] $Destination,
        [string] $Stage,
        [string] $Target,
        [string] $Item
    )

    if ( -not (Test-Path -LiteralPath $Source) )
    {
        Add-Result $Stage $Target $Item 'MISSING' '- not present in source'
        return
    }

    $destFolder = Split-Path -Path $Destination -Parent

    if ( -not (Test-Path -LiteralPath $destFolder) )
    {
        if ( $PSCmdlet.ShouldProcess($destFolder, 'Create folder') )
        {
            New-Item -Path $destFolder -ItemType Directory -Force | Out-Null
        }
    }

    # Nothing to do when the destination already matches -- reported, not silently hidden,
    # so an unexpected "already current" is visible.
    if ( Test-Path -LiteralPath $Destination )
    {
        $sourceHash = (Get-FileHash -LiteralPath $Source      -Algorithm SHA256).Hash
        $destHash   = (Get-FileHash -LiteralPath $Destination -Algorithm SHA256).Hash

        if ( $sourceHash -eq $destHash )
        {
            Add-Result $Stage $Target $Item 'SKIPPED' '- already current'
            return
        }
    }

    if ( -not $PSCmdlet.ShouldProcess($Destination, "Copy from $Source") )
    {
        Add-Result $Stage $Target $Item 'SKIPPED' '- WhatIf'
        return
    }

    try
    {
        Copy-Item -LiteralPath $Source -Destination $Destination -Force -ErrorAction Stop

        # Files that travelled through a browser, e-mail or a zip carry a mark-of-the-web
        # that makes PowerShell refuse to dot-source or import them on the far side.
        Unblock-File -LiteralPath $Destination -ErrorAction SilentlyContinue
    }
    catch
    {
        Add-Result $Stage $Target $Item 'FAILED' ("- " + ($_.Exception.Message -replace '[\r\n]+', ' ').Trim())
        return
    }

    $sourceHash = (Get-FileHash -LiteralPath $Source      -Algorithm SHA256).Hash
    $destHash   = (Get-FileHash -LiteralPath $Destination -Algorithm SHA256).Hash

    if ( $sourceHash -eq $destHash )
    {
        $sizeKB = [math]::Round((Get-Item -LiteralPath $Destination).Length / 1KB, 1)
        Add-Result $Stage $Target $Item 'OK' "- copied, $sizeKB KB, hash verified"
    }
    else
    {
        Add-Result $Stage $Target $Item 'FAILED' '- copied but SHA-256 does not match the source'
    }
}

# Whole-folder copy, used for the installation media. Deliberately robocopy rather than
# the per-file hash comparison above: these folders are gigabytes, and hashing every file
# on both ends over SMB would take far longer than the copy itself. Robocopy skips files
# whose size and timestamp already match, so re-running is cheap.
#
# NOT /MIR -- mirroring deletes anything on the node that is absent from the admin
# machine, which would silently strip a node if the admin copy were ever incomplete.
function Copy-FolderRobocopy
{
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [string] $Source,
        [string] $Destination,
        [string] $Target,
        [string] $Item
    )

    if ( -not (Test-Path -LiteralPath $Source) )
    {
        Add-Result 'Nodes' $Target $Item 'SKIPPED' '- not present on the admin machine'
        return
    }

    if ( -not $PSCmdlet.ShouldProcess($Destination, "Robocopy from $Source") )
    {
        Add-Result 'Nodes' $Target $Item 'SKIPPED' '- WhatIf'
        return
    }

    $sizeMB = [math]::Round(
        ((Get-ChildItem -LiteralPath $Source -Recurse -File -ErrorAction SilentlyContinue |
            Measure-Object -Property Length -Sum).Sum / 1MB), 0)

    Write-Host ("  [..] {0,-22} {1} ({2} MB) ..." -f $Target, $Item, $sizeMB) -ForegroundColor Cyan

    # /E   include subdirectories, empty ones too
    # /R:2 /W:2  two retries, two seconds apart, instead of the default million
    # /NP  no per-file percentage, which floods a transcript
    & robocopy $Source $Destination /E /R:2 /W:2 /NP /NFL /NDL | Out-Null
    $rc = $LASTEXITCODE

    # Robocopy exit codes are a bit field, not a conventional status: 0 = nothing needed
    # copying, 1 = files copied, 2 = extra files present, 3 = both. Anything >= 8 contains
    # a genuine failure bit. Treating non-zero as failure would report every successful
    # copy as an error.
    if ( $rc -ge 8 )
    {
        Add-Result 'Nodes' $Target $Item 'FAILED' "- robocopy exit code $rc (see robocopy documentation; >= 8 is a real failure)"
    }
    elseif ( $rc -eq 0 )
    {
        Add-Result 'Nodes' $Target $Item 'SKIPPED' '- already current'
    }
    else
    {
        Add-Result 'Nodes' $Target $Item 'OK' "- $sizeMB MB synced (robocopy exit code $rc)"
    }
}

Write-Host ''
Write-Host '================================================================' -ForegroundColor Cyan
Write-Host ' Publish SQLInstall toolkit files' -ForegroundColor Cyan
Write-Host '================================================================' -ForegroundColor Cyan
Write-Host "  Source repo  : $SourceRoot"
Write-Host "  Admin machine: $AdminRoot"
Write-Host "  Target nodes : $($ComputerName -join ', ')"
if ( $IncludeOlderChanges ) { Write-Host '  Change set   : current + 28 Jul 2026' }
else                        { Write-Host '  Change set   : current only' }
Write-Host ''

if ( -not (Test-Path -LiteralPath $SourceRoot) )
{
    throw "Source root '$SourceRoot' does not exist. Pass -SourceRoot explicitly."
}

# -------------------------------------------------------------------------------
# Stage 1: repo -> admin machine
# -------------------------------------------------------------------------------
if ( -not $NodesOnly )
{
    Write-Host 'STAGE 1 of 2: repo -> admin machine' -ForegroundColor Cyan

    $fileSet = $currentChangeSet
    if ( $IncludeOlderChanges ) { $fileSet = $currentChangeSet + $olderChangeSet }

    foreach ( $relative in $fileSet )
    {
        Copy-Verified -Source      (Join-Path -Path $SourceRoot -ChildPath $relative) `
                      -Destination (Join-Path -Path $AdminRoot  -ChildPath $relative) `
                      -Stage 'Admin' -Target 'admin machine' -Item $relative
    }

    # The environment .psd1 files hold per-site settings and are frequently edited on the
    # admin machine directly, so overwriting them from the repo is not assumed. Report the
    # difference and let the operator decide.
    if ( $IncludeOlderChanges )
    {
        $envSource = Join-Path -Path $SourceRoot -ChildPath 'SQLDSC\environments'
        $envDest   = Join-Path -Path $AdminRoot  -ChildPath 'SQLDSC\environments'

        foreach ( $envFile in (Get-ChildItem -Path $envSource -Filter '*.psd1' -ErrorAction SilentlyContinue) )
        {
            $destFile = Join-Path -Path $envDest -ChildPath $envFile.Name

            if ( -not (Test-Path -LiteralPath $destFile) )
            {
                Copy-Verified -Source $envFile.FullName -Destination $destFile `
                              -Stage 'Admin' -Target 'admin machine' -Item "SQLDSC\environments\$($envFile.Name)"
                continue
            }

            $same = (Get-FileHash -LiteralPath $envFile.FullName -Algorithm SHA256).Hash -eq
                    (Get-FileHash -LiteralPath $destFile         -Algorithm SHA256).Hash

            if ( $same )
            {
                Add-Result 'Admin' 'admin machine' "SQLDSC\environments\$($envFile.Name)" 'SKIPPED' '- already current'
            }
            else
            {
                Add-Result 'Admin' 'admin machine' "SQLDSC\environments\$($envFile.Name)" 'WARN' `
                           '- differs; NOT overwritten (site-specific settings). Merge by hand if needed.'
            }
        }
    }

    Write-Host ''
}

# -------------------------------------------------------------------------------
# Stage 2: admin machine -> target nodes
#
# The whole SQLScripts folder is pushed rather than just the changed files. The node
# executes every *Set.sql the admin machine enumerated at compile time, so a node
# holding a stale copy of ANY of them runs the wrong script -- not just the ones
# changed in this batch.
# -------------------------------------------------------------------------------
if ( -not $AdminOnly )
{
    Write-Host 'STAGE 2 of 2: admin machine -> target nodes' -ForegroundColor Cyan

    $scriptsSource = Join-Path -Path $AdminRoot -ChildPath $scriptsFolderRelative

    if ( -not (Test-Path -LiteralPath $scriptsSource) )
    {
        throw "'$scriptsSource' does not exist on the admin machine. Run stage 1 first."
    }

    $scriptFiles = Get-ChildItem -Path $scriptsSource -File

    foreach ( $node in $ComputerName )
    {
        Write-Host "  $node" -ForegroundColor Gray

        $nodeShare = "\\$node\c`$\SQLInstall\$scriptsFolderRelative"

        if ( -not (Test-Path -LiteralPath "\\$node\c`$") )
        {
            Add-Result 'Nodes' $node 'admin share' 'FAILED' `
                       "- cannot reach \\$node\c`$ (node offline, or no admin rights from this account)"
            continue
        }

        foreach ( $file in $scriptFiles )
        {
            Copy-Verified -Source      $file.FullName `
                          -Destination (Join-Path -Path $nodeShare -ChildPath $file.Name) `
                          -Stage 'Nodes' -Target $node -Item $file.Name
        }

        # -----------------------------------------------------------------------
        # Installation media, for nodes that have never been built.
        #
        # With Copy_all_Files_to_TargetNodes = 'NO' the DSC File resources that would
        # stage these are not declared at all, yet several paths are read LOCALLY on the
        # target: UpdateSource (SQLPatches) is a local path that setup.exe validates
        # directly, and the .NET 3.5 source and SSMS layout are likewise expected to be
        # on the node already. A fresh node without them fails part-way through setup.
        #
        # Skipped by default because on an already-built node this is gigabytes of
        # no-op comparison.
        # -----------------------------------------------------------------------
        if ( $IncludeBits )
        {
            foreach ( $folder in $BitsSubfolder )
            {
                Copy-FolderRobocopy -Source      (Join-Path -Path $AdminRoot -ChildPath "SQLDSC\bits\$folder") `
                                    -Destination "\\$node\c`$\SQLInstall\SQLDSC\bits\$folder" `
                                    -Target $node -Item "bits\$folder"
            }
        }
    }

    if ( -not $IncludeBits )
    {
        Write-Host '  [INFO] Installation media not pushed. Add -IncludeBits for nodes that have never been built.' -ForegroundColor Cyan
    }

    Write-Host ''
}

# -------------------------------------------------------------------------------
# Summary
# -------------------------------------------------------------------------------
Write-Host '================================================================' -ForegroundColor Cyan
Write-Host ' SUMMARY' -ForegroundColor Cyan
Write-Host '================================================================' -ForegroundColor Cyan

$copied  = @($results | Where-Object { $_.Status -eq 'OK'      })
$skipped = @($results | Where-Object { $_.Status -eq 'SKIPPED' })
$warned  = @($results | Where-Object { $_.Status -eq 'WARN'    })
$failed  = @($results | Where-Object { $_.Status -in 'FAILED', 'MISSING' })

Write-Host ("  Copied : {0}" -f $copied.Count)  -ForegroundColor Green
Write-Host ("  Skipped: {0}" -f $skipped.Count) -ForegroundColor Cyan
if ( $warned.Count -gt 0 ) { Write-Host ("  Warnings: {0}" -f $warned.Count) -ForegroundColor Yellow }

if ( $failed.Count -gt 0 )
{
    Write-Host ("  FAILED : {0}" -f $failed.Count) -ForegroundColor Red
    Write-Host ''
    $failed | Format-Table Target, Item, Status, Detail -AutoSize | Out-String | Write-Host
    Write-Host 'Resolve the failures above before starting the installation.' -ForegroundColor Red
    exit 1
}

Write-Host ''
Write-Host '  All files published and verified.' -ForegroundColor Green
Write-Host '  Next: run Start_SQL_Server_Installation_Multiple_Node.ps1 from the admin machine.' -ForegroundColor Green
Write-Host ''
