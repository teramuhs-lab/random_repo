function Test-NodePrerequisites
{
<#
.SYNOPSIS
    Verifies, on every target node, the volumes and staged files the DSC configuration
    expects to find already present -- and stops the run before any MOF is pushed if
    something required is missing.

.DESCRIPTION
    The configuration creates FOLDERS, not volumes, and with
    Copy_all_Files_to_TargetNodes = 'NO' it copies nothing to the nodes. Several paths are
    therefore preconditions rather than outcomes, and when one is absent it surfaces deep
    inside Step 14's verbose output, after the MOF has been pushed:

        [[File]Folder_0] The system cannot find the path specified.
        [[File]Folder_0] The related file/directory is: E:\SQLBackups\CAPPT.

    That is cheap to catch here and expensive to diagnose there. This function is the same
    idea as Test-RequiredDscModules, applied to volumes and media instead of modules.

    WHAT IS CHECKED

      Volumes (always)      the drive of every data/log/tempdb/backup path. Only the ROOT
                            is checked -- the folders themselves are what DSC creates.
      SQLScripts (always)   SQLScriptsFolderDestination, because the SqlScript resources
                            execute SetFilePath from the node's LOCAL copy. A node missing
                            this silently runs no post-install scripts; a node holding a
                            STALE copy silently runs the wrong ones, which this cannot
                            detect -- compare file sizes if in doubt.
      .NET 3.5 source       DotNetBitsDestination. Required regardless of the copy switch,
                            because [WindowsFeature]DotNet35 reads it as -Source.
      SQL media             SQLBitsDestination + <Version>, when the copy switch is 'NO'.
      Patches               UpdateSource, when UpdateEnabled is $true. setup.exe validates
                            this path directly whatever the copy switch says.
      SSMS layout           LayoutPath, only when InstallStandAloneSSMS = 'YES' and
                            SSMSVersion is 'SSMS22'.

    WHAT IS NOT CHECKED, AND WHY

      Free space is reported for information but never enforced -- how much a build needs
      depends on database sizes this toolkit knows nothing about.

      Whether a staged file is the CORRECT version. Presence is all that is verified.

.PARAMETER EnvData
    The environment configuration hashtable, as loaded from the .psd1.

.PARAMETER ComputerName
    Target nodes to check.

.PARAMETER Version
    SQL Server version keyword, e.g. 'SQL2025'. Used to locate the media folder.

.PARAMETER WarningCountVariable
    Global counter incremented per warning so warnings reach the STEP SUMMARY.

.EXAMPLE
    Test-NodePrerequisites -EnvData $envData -ComputerName $nodes -Version 'SQL2025'

.NOTES
    Throws on a missing volume or missing required media. Warns on anything advisory.
    Nothing here changes state -- it is read-only.
#>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [hashtable] $EnvData,

        [Parameter(Mandatory = $true)]
        [string[]] $ComputerName,

        [Parameter(Mandatory = $true)]
        [string] $Version,

        [string] $WarningCountVariable = 'SQLInstallWarningCount'
    )

    function Script:Write-PrereqWarning
    {
        param($Message)
        Write-Host "  [WARN] $Message" -ForegroundColor Yellow
        if ( Test-Path "Variable:Global:$WarningCountVariable" )
        {
            Set-Variable -Name $WarningCountVariable -Scope Global `
                         -Value ((Get-Variable -Name $WarningCountVariable -Scope Global -ValueOnly) + 1)
        }
    }

    $sql  = $EnvData.NonNodeData.SQL
    $ssms = $EnvData.NonNodeData.SSMS
    $copyToNodes = ( $EnvData.NonNodeData.Data.Copy_all_Files_to_TargetNodes -eq 'YES' )

    # -----------------------------------------------------------------------
    # Build the list of paths to check, each tagged with why it is needed.
    # Only the drive ROOT is checked for the data paths -- DSC creates the folders.
    # -----------------------------------------------------------------------
    $volumePaths = @(
        @{ Path = $sql.SQLUserDBDir;    Why = 'user database data files' }
        @{ Path = $sql.SQLUserDBLogDir; Why = 'user database log files' }
        @{ Path = $sql.SQLTempDBDir;    Why = 'tempdb data files' }
        @{ Path = $sql.SQLTempDBLogDir; Why = 'tempdb log files' }
        @{ Path = $sql.SQLBackupDir;    Why = 'backups' }
    ) | Where-Object { $_.Path }

    $requiredFolders = New-Object System.Collections.Generic.List[object]

    $requiredFolders.Add(@{ Path = $sql.SQLScriptsFolderDestination
                            Why  = 'post-install T-SQL scripts, executed from the node''s local copy' })

    $requiredFolders.Add(@{ Path = $sql.DotNetBitsDestination
                            Why  = '.NET 3.5 source for [WindowsFeature]DotNet35' })

    if ( -not $copyToNodes )
    {
        $requiredFolders.Add(@{ Path = ($sql.SQLBitsDestination + $Version)
                                Why  = "SQL Server $Version setup media (Copy_all_Files_to_TargetNodes = 'NO')" })
    }

    if ( $sql.UpdateEnabled -eq $true -and $sql.UpdateSource )
    {
        $requiredFolders.Add(@{ Path = $sql.UpdateSource
                                Why  = 'slipstream patches; setup.exe validates this path directly' })
    }

    if ( $ssms -and $ssms.InstallStandAloneSSMS -eq 'YES' -and $ssms.SSMSVersion -eq 'SSMS22' -and $ssms.LayoutPath )
    {
        $requiredFolders.Add(@{ Path = $ssms.LayoutPath
                                Why  = 'SSMS 22 offline layout' })
    }

    # Only local paths can be checked on the node. A UNC entry is somebody else's problem.
    $localFolders = @( $requiredFolders | Where-Object { $_.Path -notmatch '^\\\\' } )

    Write-Host "  Verifying node prerequisites (volumes and staged files) ..." -ForegroundColor Gray

    $checkScript = {
        param ( $VolumeRoots, $Folders )

        $result = @{ Computer = $env:COMPUTERNAME; Volumes = @(); Folders = @() }

        foreach ( $root in $VolumeRoots )
        {
            $exists = Test-Path -LiteralPath $root
            $freeGB = $null
            if ( $exists )
            {
                try
                {
                    $d = Get-PSDrive -Name $root.Substring(0,1) -ErrorAction Stop
                    $freeGB = [math]::Round($d.Free / 1GB, 1)
                }
                catch { $freeGB = $null }
            }
            $result.Volumes += @{ Root = $root; Exists = $exists; FreeGB = $freeGB }
        }

        foreach ( $f in $Folders )
        {
            $result.Folders += @{ Path = $f; Exists = (Test-Path -LiteralPath $f) }
        }

        # ------------------------------------------------------------------
        # Pending reboot.
        #
        # SQL Server setup refuses to install while one is outstanding. It fails its
        # prerequisite rules in about three seconds with
        #
        #   Exit error code 3010
        #   A computer restart is required. You must restart this computer before
        #   installing SQL Server.
        #   Final result: Passed but reboot required
        #
        # DSC then reports only that SqlSetup could not reach the desired state, and
        # because every other resource depends on it, the entire configuration is
        # skipped -- the run still finishes, and the node ends up with nothing
        # installed. Two nodes were lost to this before the setup log was read.
        #
        # These are the indicators SQL setup's own rule inspects.
        # ------------------------------------------------------------------
        $rebootReasons = @()

        if ( Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending' )
        { $rebootReasons += 'Component Based Servicing (pending servicing operation)' }

        if ( Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired' )
        { $rebootReasons += 'Windows Update' }

        $sm = Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' -Name 'PendingFileRenameOperations' -ErrorAction SilentlyContinue
        if ( $sm -and $sm.PendingFileRenameOperations )
        { $rebootReasons += "PendingFileRenameOperations ($(@($sm.PendingFileRenameOperations).Count) entries)" }

        $cn = Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\ComputerName\ActiveComputerName' -Name 'ComputerName' -ErrorAction SilentlyContinue
        $pn = Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\ComputerName\ComputerName'       -Name 'ComputerName' -ErrorAction SilentlyContinue
        if ( $cn -and $pn -and $cn.ComputerName -ne $pn.ComputerName )
        { $rebootReasons += "rename pending ($($cn.ComputerName) -> $($pn.ComputerName))" }

        $result.RebootReasons = $rebootReasons
        $result.LastBoot      = (Get-CimInstance Win32_OperatingSystem).LastBootUpTime

        return $result
    }

    # Distinct drive roots -- several paths commonly share one drive (tempdb data and log).
    $volumeRoots = @( $volumePaths |
                        ForEach-Object { [System.IO.Path]::GetPathRoot($_.Path) } |
                        Where-Object { $_ } |
                        Sort-Object -Unique )

    $folderPaths = @( $localFolders | ForEach-Object { $_.Path } | Sort-Object -Unique )

    $failures = New-Object System.Collections.Generic.List[string]

    foreach ( $node in $ComputerName )
    {
        try
        {
            $r = Invoke-Command -ComputerName $node -ScriptBlock $checkScript `
                                -ArgumentList $volumeRoots, $folderPaths -ErrorAction Stop
        }
        catch
        {
            Write-PrereqWarning "$node`: could not be reached to verify prerequisites -- check it by hand. $(($_.Exception.Message -replace '[\r\n]+',' ').Trim())"
            continue
        }

        # Checked first, because it is the one condition that makes everything else
        # irrelevant: setup will not install at all while it is true.
        if ( @($r.RebootReasons).Count -gt 0 )
        {
            Write-Host ("  [REBOOT PENDING] {0,-14} last booted {1}" -f $node, $r.LastBoot) -ForegroundColor Red
            foreach ( $reason in $r.RebootReasons )
            {
                Write-Host ("                   - {0}" -f $reason) -ForegroundColor Yellow
            }
            $failures.Add("$node : a restart is pending. SQL Server setup refuses to install until the node is rebooted (setup exit code 3010). Reasons: $($r.RebootReasons -join '; ')")
        }
        else
        {
            Write-Host ("  [OK] {0,-22} no restart pending" -f $node) -ForegroundColor Green
        }

        foreach ( $v in $r.Volumes )
        {
            if ( $v.Exists )
            {
                $space = if ( $null -ne $v.FreeGB ) { "$($v.FreeGB) GB free" } else { 'free space unknown' }
                Write-Host ("  [OK] {0,-22} volume {1}  ({2})" -f $node, $v.Root, $space) -ForegroundColor Green
            }
            else
            {
                $why = ( $volumePaths | Where-Object { [System.IO.Path]::GetPathRoot($_.Path) -eq $v.Root } |
                            ForEach-Object { $_.Why } ) -join ', '
                Write-Host ("  [MISSING] {0,-18} volume {1}  needed for: {2}" -f $node, $v.Root, $why) -ForegroundColor Red
                $failures.Add("$node : volume $($v.Root) does not exist (needed for $why)")
            }
        }

        foreach ( $f in $r.Folders )
        {
            if ( $f.Exists )
            {
                Write-Host ("  [OK] {0,-22} {1}" -f $node, $f.Path) -ForegroundColor Green
            }
            else
            {
                $why = ( $localFolders | Where-Object { $_.Path -eq $f.Path } | ForEach-Object { $_.Why } ) -join ', '
                Write-Host ("  [MISSING] {0,-18} {1}" -f $node, $f.Path) -ForegroundColor Red
                $failures.Add("$node : '$($f.Path)' is missing (needed for $why)")
            }
        }
    }

    if ( $failures.Count -gt 0 )
    {
        throw @"
Node prerequisites are not satisfied. The deployment has been STOPPED before any
configuration was pushed.

$(($failures | ForEach-Object { "    - $_" }) -join [Environment]::NewLine)

Volumes must be provisioned before running this installer -- the configuration creates
folders, not disks. Staged folders are copied by hand, or by
Kickoff_SQL_Install\Copy-SQLInstallToNodes.ps1, because
Copy_all_Files_to_TargetNodes = '$($EnvData.NonNodeData.Data.Copy_all_Files_to_TargetNodes)'
means DSC does not copy them for you.

For a pending restart, reboot the node and run again:

    Restart-Computer -ComputerName <node> -Wait -For PowerShell -Force

Stopping here is deliberate. SQL Server setup fails its prerequisite rules in about three
seconds with exit code 3010 and installs nothing, DSC reports only that SqlSetup could not
reach the desired state, and because every other resource depends on it the whole
configuration is skipped -- while the run still reaches the end and prints DONE.
"@
    }

    Write-Host "  [OK] All node prerequisites verified." -ForegroundColor Green
}
