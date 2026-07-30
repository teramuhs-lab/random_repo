function Test-RequiredDscModules
{
<#
.SYNOPSIS
    Ensures the DSC modules required for a given SQL Server version are present on the
    admin machine and on every target node -- copying any that are missing, and stopping
    the deployment with clear instructions if they cannot be supplied.

.DESCRIPTION
    A missing or wrong-version module is not discovered until it fails, and it fails in
    a confusing place:

      * missing on the ADMIN machine  -> MOF compilation dies with
        "Could not find the module '<name>'"
      * missing on a TARGET NODE      -> the LCM fails part-way through the push,
        possibly after SQL Server has already been installed

    Both are far cheaper to catch here. This function:

      1. inventories the modules on the admin machine and every node,
      2. copies any that are missing from the toolkit's own SQLDSC\modules\ folder,
      3. re-verifies, and
      4. throws with per-machine instructions if anything required is still absent.

    Which modules are required depends on the SQL Server version, because the two
    install paths use different DSC modules:

      SQL2025+       SqlServerDsc + xNetworking, with SqlServer 22.x for SMO 17.x
      SQL2012-2017   xSQLServer   + xNetworking, with SqlServer 21.x for SMO 14.x

    IMPORTANT: only the modules that version actually needs are copied. Copying the
    whole modules folder would put SqlServer 22.x (SMO 17.x) onto SQL2012-2017 nodes,
    where -- because the SqlServer module version is NOT pinned by the configs -- the
    highest installed version wins and can shadow the SMO 14.x assemblies xSQLServer
    depends on.

.PARAMETER Version
    SQL Server version keyword from the environment file, e.g. 'SQL2025', 'SQL2017'.

.PARAMETER ComputerName
    The target nodes to check. The local (admin) machine is always checked as well.

.PARAMETER ModuleSourcePath
    Folder holding the vendored modules in <Name>\<Version>\ layout. Defaults to
    SQLDSC\modules relative to this script.

.PARAMETER NoAutoCopy
    Verify only; do not attempt to copy missing modules.

.PARAMETER WarningCountVariable
    Name of a global counter incremented per warning, so warnings appear in the
    installer's STEP SUMMARY. Defaults to 'SQLInstallWarningCount'.

.EXAMPLE
    Test-RequiredDscModules -Version 'SQL2025' -ComputerName 'NODE01','NODE02'

.NOTES
    Copying to a node writes to \\<node>\c$\Program Files\WindowsPowerShell\Modules,
    so the account running the installer needs administrative access to that share.
    The installer confirms this in Step 12.
#>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $Version,

        [Parameter(Mandatory = $true)]
        [string[]] $ComputerName,

        [string] $ModuleSourcePath,

        [switch] $NoAutoCopy,

        [string] $WarningCountVariable = 'SQLInstallWarningCount'
    )

    # Default the module source to SQLDSC\modules relative to this helper's location.
    if ( -not $ModuleSourcePath )
    {
        $ModuleSourcePath = Join-Path -Path $PSScriptRoot -ChildPath '..\modules'
    }
    if ( Test-Path $ModuleSourcePath ) { $ModuleSourcePath = (Resolve-Path $ModuleSourcePath).Path }

    $moduleRoot = 'C:\Program Files\WindowsPowerShell\Modules'

    # -----------------------------------------------------------------------
    # What each install path needs.
    #
    #   Required = $true   compilation or the LCM cannot work without it -> fatal
    #   Required = $false  runtime dependency that may resolve another way -> warning
    #
    # Admin/Node say where the module must actually be present. The DSC resource
    # modules are needed in BOTH places: on the admin machine to compile the MOF, and
    # on the node for the LCM to apply it. The SqlServer module is a runtime SMO
    # dependency of the resources, so only the nodes truly need it.
    # -----------------------------------------------------------------------
    if ( $Version -eq 'SQL2025' )
    {
        $required = @(
            @{ Name = 'SqlServerDsc'; Version = '17.5.1';     Admin = $true;  Node = $true;  Required = $true
               Why = 'DSC resources for the SQL2025 install path' }
            @{ Name = 'xNetworking';  Version = '5.3.0.0';    Admin = $true;  Node = $true;  Required = $true
               Why = 'xFirewall resource' }
            @{ Name = 'SqlServer';    Version = '22.4.5.1';   Admin = $false; Node = $true;  Required = $false
               Why = 'SMO 17.x, matching SQL2025 major version 17' }
        )
    }
    else
    {
        $required = @(
            @{ Name = 'xSQLServer';   Version = '9.0.0.0';    Admin = $true;  Node = $true;  Required = $true
               Why = 'DSC resources for the SQL2012-2017 install path' }
            @{ Name = 'xNetworking';  Version = '5.3.0.0';    Admin = $true;  Node = $true;  Required = $true
               Why = 'xFirewall resource' }
            @{ Name = 'SqlServer';    Version = '21.0.17224'; Admin = $false; Node = $true;  Required = $false
               Why = 'SMO 14.x, matching SQL2017 major version 14' }
        )
    }

    function Script:Write-ModuleWarning
    {
        param($Message)
        Write-Host "  [WARN] $Message" -ForegroundColor Yellow
        if ( Test-Path "Variable:Global:$WarningCountVariable" )
        {
            Set-Variable -Name $WarningCountVariable -Scope Global `
                         -Value ((Get-Variable -Name $WarningCountVariable -Scope Global -ValueOnly) + 1)
        }
    }

    # Collect installed module versions from one machine as a name -> version[] map.
    $inventoryScript = {
        $names = 'SqlServerDsc','xSQLServer','xNetworking','SqlServer','xFailOverCluster'
        $found = @{}
        foreach ( $m in (Get-Module -ListAvailable -Name $names -ErrorAction SilentlyContinue) )
        {
            if ( -not $found.ContainsKey($m.Name) ) { $found[$m.Name] = @() }
            $found[$m.Name] += $m.Version.ToString()
        }
        return $found
    }

    function Script:Get-ModuleInventory
    {
        param($Machine)
        if ( $Machine -eq $env:COMPUTERNAME ) { return (& $inventoryScript) }
        return (Invoke-Command -ComputerName $Machine -ScriptBlock $inventoryScript -ErrorAction Stop)
    }

    # How many files a deployed module actually has. Compared against the vendored source
    # to detect a truncated copy -- see the note at the completeness check below for why
    # the manifest alone is not enough.
    $fileCountScript = {
        param($Name, $ModuleVersion)
        $p = "C:\Program Files\WindowsPowerShell\Modules\$Name\$ModuleVersion"
        if ( -not (Test-Path -LiteralPath $p) ) { return -1 }
        return @(Get-ChildItem -LiteralPath $p -Recurse -File -ErrorAction SilentlyContinue).Count
    }

    function Script:Get-DeployedFileCount
    {
        param($Machine, $ModuleName, $ModuleVersion)
        try
        {
            if ( $Machine -eq $env:COMPUTERNAME ) { return (& $fileCountScript $ModuleName $ModuleVersion) }
            return (Invoke-Command -ComputerName $Machine -ScriptBlock $fileCountScript `
                                   -ArgumentList $ModuleName, $ModuleVersion -ErrorAction Stop)
        }
        catch { return -1 }
    }

    Write-Host "  Verifying DSC modules required for $Version ..." -ForegroundColor Gray
    Write-Host "  Module source: $ModuleSourcePath" -ForegroundColor DarkGray

    # -----------------------------------------------------------------------
    # Inventory every machine involved.
    # -----------------------------------------------------------------------
    $machines = [ordered]@{}
    $machines[$env:COMPUTERNAME] = @{ IsAdmin = $true; IsNode = ($ComputerName -contains $env:COMPUTERNAME); Reachable = $true }

    foreach ( $node in $ComputerName )
    {
        if ( $node -eq $env:COMPUTERNAME ) { continue }   # already listed as admin+node
        $machines[$node] = @{ IsAdmin = $false; IsNode = $true; Reachable = $true }
    }

    foreach ( $m in @($machines.Keys) )
    {
        try   { $machines[$m].Modules = Get-ModuleInventory -Machine $m }
        catch { $machines[$m].Modules = @{}; $machines[$m].Reachable = $false }
    }

    # -----------------------------------------------------------------------
    # Evaluate, copying anything missing that we have a source for.
    # -----------------------------------------------------------------------
    $unresolved = New-Object System.Collections.Generic.List[object]
    $copied     = 0

    foreach ( $machine in $machines.Keys )
    {
        $info = $machines[$machine]

        if ( -not $info.Reachable )
        {
            Write-ModuleWarning "$machine`: could not be reached to verify modules -- check it manually before deploying."
            continue
        }

        foreach ( $req in $required )
        {
            # Skip requirements that do not apply to this machine's role.
            if ( -not ( ($info.IsAdmin -and $req.Admin) -or ($info.IsNode -and $req.Node) ) ) { continue }

            # Filter out nulls: @($hashtable['missing-key']) yields a one-element array
            # containing $null, which would otherwise look like "installed, wrong version".
            $installed = @($info.Modules[$req.Name]) | Where-Object { $_ }

            $sourceFolder = Join-Path -Path $ModuleSourcePath -ChildPath "$($req.Name)\$($req.Version)"

            if ( $installed -contains $req.Version )
            {
                # Already installed -- but check it is COMPLETE, not merely discoverable.
                # A module deployed by an interrupted or space-limited copy keeps a readable
                # manifest while missing the files that matter, and only reveals itself at
                # MOF compilation as "Undefined DSC resource".
                $expected = @(Get-ChildItem -LiteralPath $sourceFolder -Recurse -File -ErrorAction SilentlyContinue).Count
                $actual   = Get-DeployedFileCount -Machine $machine -ModuleName $req.Name -ModuleVersion $req.Version

                if ( $expected -gt 0 -and $actual -ge 0 -and $actual -lt $expected )
                {
                    Write-Host ("  [INCOMPLETE] {0,-15} {1} {2} -- {3} of {4} files" -f $machine, $req.Name, $req.Version, $actual, $expected) -ForegroundColor Red

                    if ( $NoAutoCopy )
                    {
                        $unresolved.Add([pscustomobject]@{
                            Machine = $machine; Module = $req.Name; Version = $req.Version
                            Required = $req.Required; Why = $req.Why
                            Detail = "installed but incomplete ($actual of $expected files); auto-copy disabled"
                        })
                        continue
                    }

                    # Fall through to the copy path below to repair it. Do not 'continue'.
                    Write-Host ("  [..] {0,-22} repairing from {1} ..." -f $machine, $sourceFolder) -ForegroundColor Cyan
                }
                else
                {
                    Write-Host ("  [OK] {0,-22} {1} {2}" -f $machine, $req.Name, $req.Version) -ForegroundColor Green
                    continue
                }
            }

            # -------------------------------------------------------------
            # Missing, wrong version, or present but incomplete. Try to supply it from the
            # toolkit's own modules folder before giving up. ($sourceFolder is set above.)
            # -------------------------------------------------------------
            $haveText = if ( $installed.Count -gt 0 ) { "have: $($installed -join ', ')" } else { 'not installed' }

            if ( $NoAutoCopy -or -not (Test-Path $sourceFolder) )
            {
                $reason = if ( $NoAutoCopy ) { 'auto-copy disabled' } else { "no source at $sourceFolder" }
                $unresolved.Add([pscustomobject]@{
                    Machine = $machine; Module = $req.Name; Version = $req.Version
                    Required = $req.Required; Why = $req.Why; Detail = "$haveText; $reason"
                })
                continue
            }

            # Destination: a local path for this machine, an admin share for a node.
            $destParent = if ( $machine -eq $env:COMPUTERNAME ) { Join-Path $moduleRoot $req.Name }
                          else { "\\$machine\c`$\Program Files\WindowsPowerShell\Modules\$($req.Name)" }

            Write-Host ("  [..] {0,-22} copying {1} {2} ..." -f $machine, $req.Name, $req.Version) -ForegroundColor Cyan

            try
            {
                if ( -not (Test-Path $destParent) ) { New-Item -Path $destParent -ItemType Directory -Force | Out-Null }
                Copy-Item -Path $sourceFolder -Destination $destParent -Recurse -Force -ErrorAction Stop
                $copied++
            }
            catch
            {
                $unresolved.Add([pscustomobject]@{
                    Machine = $machine; Module = $req.Name; Version = $req.Version
                    Required = $req.Required; Why = $req.Why
                    Detail = "$haveText; copy failed: $(($_.Exception.Message -replace '[\r\n]+',' ').Trim())"
                })
                continue
            }

            # Confirm the copy actually satisfied the requirement, rather than assuming.
            try   { $after = (Get-ModuleInventory -Machine $machine)[$req.Name] }
            catch { $after = @() }

            if ( -not (@($after) -contains $req.Version) )
            {
                $unresolved.Add([pscustomobject]@{
                    Machine = $machine; Module = $req.Name; Version = $req.Version
                    Required = $req.Required; Why = $req.Why
                    Detail = 'copied, but the module is still not visible to PowerShell on that machine'
                })
                continue
            }

            # Visible is not the same as complete. Get-Module -ListAvailable only reads the
            # .psd1 manifest, so a module missing almost all of its files still reports as
            # installed at the right version -- and then fails at MOF compilation with
            #
            #   Failed to parse module script file '...\SqlServerDsc.psm1' ...
            #   using module .\Modules\DscResource.Base
            #   Could not find the module '.\Modules\DscResource.Base'.
            #   ... Undefined DSC resource 'SqlSetup' / 'SqlProtocol' / 'xFirewall' ...
            #
            # which reads as a missing module rather than a truncated one. Compare the file
            # count against the vendored source, which is the copy we just made.
            $expectedCount = @(Get-ChildItem -LiteralPath $sourceFolder -Recurse -File -ErrorAction SilentlyContinue).Count
            $actualCount   = Get-DeployedFileCount -Machine $machine -ModuleName $req.Name -ModuleVersion $req.Version

            if ( $expectedCount -gt 0 -and $actualCount -lt $expectedCount )
            {
                $unresolved.Add([pscustomobject]@{
                    Machine = $machine; Module = $req.Name; Version = $req.Version
                    Required = $req.Required; Why = $req.Why
                    Detail = "copied but INCOMPLETE -- $actualCount of $expectedCount files present. The manifest is readable, so PowerShell reports the module as installed, but it will fail to load and every resource in it becomes 'Undefined'."
                })
                continue
            }

            Write-Host ("  [OK] {0,-22} {1} {2}  (copied, {3} files)" -f $machine, $req.Name, $req.Version, $actualCount) -ForegroundColor Green
        }

        # ---------------------------------------------------------------
        # Version-precedence trap: the SqlServer module version is NOT pinned by the
        # configs -- the helper simply imports "SqlServer", so the HIGHEST installed
        # version wins. On a SQL2012-2017 node a newer SqlServer module can shadow the
        # SMO 14.x assemblies xSQLServer requires.
        # ---------------------------------------------------------------
        if ( $info.IsNode -and $Version -ne 'SQL2025' )
        {
            $tooNew = @($info.Modules['SqlServer']) | Where-Object { $_ -and ([version]$_).Major -ge 22 }
            if ( $tooNew )
            {
                Write-ModuleWarning "$machine`: SqlServer $($tooNew -join ', ') is present on a $Version node. That version is not pinned by the configs, so the highest wins and may shadow the SMO 14.x assemblies xSQLServer needs. Remove it from SQL2012-2017 nodes if the install misbehaves."
            }
        }
    }

    if ( $copied -gt 0 ) { Write-Host "  [OK] Supplied $copied missing module(s) from $ModuleSourcePath." -ForegroundColor Green }

    # -----------------------------------------------------------------------
    # Report anything still unresolved. Non-required items warn; required items stop
    # the run -- failing here costs seconds, failing mid-push can leave a
    # half-configured SQL Server behind.
    # -----------------------------------------------------------------------
    $fatal = @($unresolved | Where-Object { $_.Required })

    foreach ( $item in ($unresolved | Where-Object { -not $_.Required }) )
    {
        Write-ModuleWarning "$($item.Machine): $($item.Module) $($item.Version) unavailable ($($item.Detail)) -- $($item.Why)"
    }

    if ( $fatal.Count -gt 0 )
    {
        $lines = foreach ( $f in $fatal )
        {
            $target = if ( $f.Machine -eq $env:COMPUTERNAME ) { "'$moduleRoot\$($f.Module)'" }
                      else { "'\\$($f.Machine)\c`$\Program Files\WindowsPowerShell\Modules\$($f.Module)'" }
            @"
    - $($f.Machine): $($f.Module) $($f.Version)
        needed for : $($f.Why)
        status     : $($f.Detail)
        fix        : Copy-Item '$ModuleSourcePath\$($f.Module)\$($f.Version)' ``
                               -Destination $target -Recurse -Force
"@
        }

        throw @"
Required DSC modules are missing and could not be supplied automatically.
The deployment has been STOPPED before making any changes.

$($lines -join [Environment]::NewLine)

Keep the <Name>\<Version>\ folder layout intact -- PowerShell will not find a module
whose folder does not match its name and manifest version.

If the source folder itself is empty, the modules are not in source control: see
SQLDSC\modules\README.md for the Save-Module commands that rebuild it.
"@
    }

    Write-Host "  [OK] All required DSC modules verified." -ForegroundColor Green
}
