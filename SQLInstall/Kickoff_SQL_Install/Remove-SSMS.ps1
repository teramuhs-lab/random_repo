<#
.SYNOPSIS
    Uninstalls SQL Server Management Studio from one or more nodes.

.DESCRIPTION
    SSMS holds no state. Nothing about SQL Server's operation depends on it, no database
    lives inside it, and removing it cannot lose data -- which is why this is a separate,
    lighter script than the one that removes the engine.

    The usual reason to run it: SSMS 19+ installs wherever the Visual Studio installer
    defaults to, and that path cannot be changed in place. To move SSMS to another volume
    you uninstall it, set --installPath in the environment file's LayoutArguments, and let
    DSC reinstall it.

    Reports by default. Removal requires -Execute and a typed confirmation.

    WHAT IT LEAVES BEHIND

    Uninstalling the product does not remove the Visual Studio installer infrastructure or
    its package cache, typically under:

        C:\Program Files (x86)\Microsoft Visual Studio\Installer
        C:\ProgramData\Microsoft\VisualStudio\Packages

    Those are shared by any VS-based product and are not this script's to delete. If you
    are uninstalling to reclaim C: space rather than to relocate, check those folders --
    they are often the larger share.

.PARAMETER ComputerName
    Target nodes.

.PARAMETER Execute
    Perform the uninstall. Without this, the script only reports.

.EXAMPLE
    .\Remove-SSMS.ps1 -ComputerName PDCWODWGDBSVR

    Reports what is installed and where. Changes nothing.

.EXAMPLE
    .\Remove-SSMS.ps1 -ComputerName PDCWODWGDBSVR,PDCWODWGDBSVR2 -Execute

    Uninstalls SSMS on both, after confirmation.

.NOTES
    After removing, set LayoutArguments in the environment file, e.g.

        LayoutArguments = '--quiet --norestart --wait --noWeb --installPath E:\SSMS22'

    then re-run the installer. [Script]InstallSSMS detects SSMS by registry DisplayName
    and version rather than by path, so it will see it missing and reinstall to the new
    location.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string[]] $ComputerName,

    [switch] $Execute
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

$findScript = {
    $keys = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )

    $found = @( Get-ItemProperty $keys -ErrorAction SilentlyContinue |
                  Where-Object { $_.DisplayName -like 'SQL Server Management Studio*' } |
                  Select-Object DisplayName, DisplayVersion, InstallLocation, UninstallString, QuietUninstallString )

    # Reported so an uninstall driven by "reclaim C: space" can be judged honestly --
    # the package cache often outweighs the product itself.
    $cacheGB = 0
    foreach ( $p in @('C:\ProgramData\Microsoft\VisualStudio\Packages') )
    {
        if ( Test-Path $p )
        {
            $cacheGB += ( Get-ChildItem $p -Recurse -File -Force -ErrorAction SilentlyContinue |
                            Measure-Object Length -Sum ).Sum / 1GB
        }
    }

    [PSCustomObject]@{
        Computer   = $env:COMPUTERNAME
        Installed  = $found
        CacheGB    = [math]::Round($cacheGB, 2)
        FreeCGB    = [math]::Round((Get-PSDrive C).Free / 1GB, 1)
    }
}

Write-Banner 'SSMS INVENTORY -- nothing is being changed'

$targets = @()

foreach ( $node in $ComputerName )
{
    try
    {
        $inv = Invoke-Command -ComputerName $node -ScriptBlock $findScript -ErrorAction Stop
    }
    catch
    {
        Write-Host "  [UNREACHABLE] $node -- $(($_.Exception.Message -replace '[\r\n]+',' ').Trim())" -ForegroundColor Red
        continue
    }

    Write-Host ''
    Write-Host "  ---- $node ----" -ForegroundColor White
    Write-Host ("  C: free                 : {0} GB" -f $inv.FreeCGB)
    Write-Host ("  VS package cache on C:  : {0} GB  (not removed by this script)" -f $inv.CacheGB)

    if ( @($inv.Installed).Count -eq 0 )
    {
        Write-Host '  SSMS                    : not installed -- nothing to do' -ForegroundColor Green
        continue
    }

    foreach ( $app in $inv.Installed )
    {
        $where = if ( $app.InstallLocation ) { $app.InstallLocation } else { '(location not recorded)' }
        Write-Host "  SSMS                    : $($app.DisplayName) $($app.DisplayVersion)" -ForegroundColor Yellow
        Write-Host "                            $where"
    }

    $targets += $node
}

if ( $targets.Count -eq 0 )
{
    Write-Banner 'Nothing to uninstall'
    return
}

if ( -not $Execute )
{
    Write-Banner 'REPORT ONLY -- nothing was removed'
    Write-Host '  Re-run with -Execute to uninstall.' -ForegroundColor Yellow
    return
}

Write-Banner 'CONFIRM'
Write-Host "  SSMS will be uninstalled on: $($targets -join ', ')" -ForegroundColor Yellow
Write-Host ''
$answer = Read-Host '  Type REMOVE to proceed, anything else to abort'

if ( $answer -cne 'REMOVE' )
{
    Write-Host '  Aborted. Nothing was changed.' -ForegroundColor Green
    return
}

$removeScript = {
    $keys = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )
    $log = @()

    $apps = @( Get-ItemProperty $keys -ErrorAction SilentlyContinue |
                 Where-Object { $_.DisplayName -like 'SQL Server Management Studio*' } )

    foreach ( $app in $apps )
    {
        # SSMS 19+ is a Visual Studio package, so its UninstallString invokes the VS
        # installer and needs the unattended switches added.
        $cmd = if ( $app.QuietUninstallString ) { $app.QuietUninstallString } else { $app.UninstallString }

        if ( -not $cmd )
        {
            $log += "[SKIP] $($app.DisplayName): no uninstall string recorded -- remove via Apps & Features"
            continue
        }

        # Split the executable from its arguments and launch it DIRECTLY.
        #
        # Routing this through cmd.exe fails: the string already contains quoted paths
        # ("...\Installer\setup.exe" uninstall --installPath "...\Management Studio 22\Release"),
        # and cmd's own quote handling mangles them, so setup.exe receives a broken
        # --installPath and exits 1 without uninstalling anything.
        if ( $cmd -match '^\s*"([^"]+)"\s*(.*)$' )
        {
            $exe     = $Matches[1]
            $exeArgs = $Matches[2]
        }
        elseif ( $cmd -match '^\s*(\S+)\s*(.*)$' )
        {
            $exe     = $Matches[1]
            $exeArgs = $Matches[2]
        }
        else
        {
            $log += "[SKIP] $($app.DisplayName): could not parse uninstall string '$cmd'"
            continue
        }

        # Two families of uninstaller, two switch syntaxes. SSMS 19+ is a Visual Studio
        # package and takes --quiet; SSMS 17.x is an MSI and takes /qn. Giving msiexec
        # the VS switches leaves it prompting, which in a remote session means it hangs
        # or fails with no useful message.
        if ( $exeArgs -notmatch '--quiet|/quiet|/qn' )
        {
            $exeArgs = if ( $exe -match 'msiexec' ) { "$exeArgs /qn /norestart" }
                       else                         { "$exeArgs --quiet --norestart" }
        }

        # Some MSI products record their UninstallString with /I -- the INSTALL action --
        # rather than /X. All four SSMS 17.x products do. Run verbatim, msiexec reinstalls
        # or repairs the product, exits 0, and the script reports success while the
        # product is still there. It is the most misleading failure in this script's
        # history: four green [OK] lines and nothing removed.
        #
        # Force the uninstall action for msiexec. Only the action switch immediately
        # preceding a product code is rewritten, so a path or a property value containing
        # something like '/i' is untouched.
        if ( $exe -match 'msiexec' )
        {
            $exeArgs = $exeArgs -replace '(?i)(^|\s)/(?:i|package)(\s*\{[0-9A-Fa-f-]+\})', '$1/x$2'
        }

        # An MSI product records its UninstallString as a BARE COMMAND NAME -- literally
        # 'MsiExec.exe /X{GUID}', with no directory. Test-Path then resolves it against the
        # remote session's working directory, finds nothing, and the product is skipped as
        # "uninstaller not found" even though msiexec is on the PATH of every Windows
        # machine. That is how four SSMS 17.x products survived a run that reported exit
        # code 0 for SSMS 22 on the same node.
        #
        # Resolve a bare name through the PATH before deciding it is missing. Only a name
        # with no directory separator is looked up; a full path still has to exist.
        if ( -not (Test-Path -LiteralPath $exe) -and $exe -notmatch '[\\/]' )
        {
            $resolved = Get-Command -Name $exe -CommandType Application -ErrorAction SilentlyContinue |
                          Select-Object -First 1
            if ( $resolved ) { $exe = $resolved.Source }
        }

        if ( -not (Test-Path -LiteralPath $exe) )
        {
            $log += "[SKIP] $($app.DisplayName): uninstaller not found at '$exe'"
            continue
        }

        $log += "[RUN ] `"$exe`" $exeArgs"

        try
        {
            $p = Start-Process -FilePath $exe -ArgumentList $exeArgs -Wait -PassThru -NoNewWindow
            $verdict = if ( $p.ExitCode -in @(0, 3010, 1641) ) { 'OK' } else { 'FAILED' }
            $log += "[$verdict] $($app.DisplayName) exit code $($p.ExitCode)"

            if ( $p.ExitCode -notin @(0, 3010, 1641) )
            {
                # The exit code alone says nothing useful; the installer's own log does.
                $dd = Get-ChildItem "$env:TEMP\dd_*.log", 'C:\Users\*\AppData\Local\Temp\dd_*.log' -ErrorAction SilentlyContinue |
                        Sort-Object LastWriteTime -Descending | Select-Object -First 1
                if ( $dd ) { $log += "[INFO] newest installer log: $($dd.FullName)" }
            }
        }
        catch
        {
            $log += "[FAILED] $($app.DisplayName): $($_.Exception.Message)"
        }
    }

    # Re-read rather than assume the uninstall worked.
    $left = @( Get-ItemProperty $keys -ErrorAction SilentlyContinue |
                 Where-Object { $_.DisplayName -like 'SQL Server Management Studio*' } )
    $log += if ( $left.Count -eq 0 ) { '[OK] no SSMS remains in the uninstall registry' }
            else { "[WARN] still present: $(($left | ForEach-Object { "$($_.DisplayName) $($_.DisplayVersion)" }) -join '; ')" }

    # ---- What the removal leaves the NEXT install unable to do ----
    #
    # Removing SSMS 17.x leaves the x86 Visual C++ runtime registration reporting the
    # version SSMS 17.x shipped with -- v14.0.23026.00 -- even though a much newer
    # redistributable is installed and Add/Remove Programs says so. Only this one key
    # is wrong; the x64 key stays correct.
    #
    # Nothing notices until the next SSMS install, which fails like this: the OLE DB
    # Driver 19 MSI's VCRedistX86Check action reads this key, requires 14.38 or higher,
    # reads minor version 0, and aborts. That fails the MsOledbSql19 package, which
    # fails the whole Visual Studio install with a bare exit code 1603 after about four
    # minutes -- naming none of the above.
    #
    # Observed on DDCWNZWGDBS03 and DDCWNZWGDBS04, 2026-09-01, after removing four
    # SSMS 17.x MSI products. DDCWNZWGDBS01 and 02, which only ever had SSMS 22,
    # were unaffected.
    #
    # Reported rather than repaired: this script uninstalls, and silently reinstalling
    # a runtime is not what an operator asked for. The repair command is printed instead.
    $vcMinMinor = 38
    $vcKey = Get-ItemProperty 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\VisualStudio\14.0\VC\Runtimes\x86' -ErrorAction SilentlyContinue

    if ( -not $vcKey )
    {
        $log += '[WARN] x86 VC++ runtime key missing -- a later SSMS install will fail 1603 at VCRedistX86Check'
    }
    elseif ( [int]$vcKey.Minor -lt $vcMinMinor )
    {
        $log += "[WARN] x86 VC++ runtime registration reads $($vcKey.Version) (minor $($vcKey.Minor), needs >= $vcMinMinor)."
        $log += '        A later SSMS install WILL fail with exit code 1603. Repair it with:'
        $log += '          $e = Get-ChildItem "C:\ProgramData\Package Cache" -Recurse -Filter VC_redist.x86.exe |'
        $log += '                 Sort-Object LastWriteTime -Descending | Select-Object -First 1'
        $log += '          Start-Process $e.FullName -ArgumentList "/repair /quiet /norestart" -Wait'
    }
    else
    {
        $log += "[OK] x86 VC++ runtime registration is $($vcKey.Version) -- a later SSMS install will not trip on it"
    }

    return $log
}

foreach ( $node in $targets )
{
    Write-Banner "UNINSTALLING SSMS on $node"
    try
    {
        Invoke-Command -ComputerName $node -ScriptBlock $removeScript -ErrorAction Stop |
            ForEach-Object { Write-Host "  $_" }
    }
    catch
    {
        Write-Host "  [FAILED] $node -- $(($_.Exception.Message -replace '[\r\n]+',' ').Trim())" -ForegroundColor Red
    }
}

Write-Banner 'DONE'
Write-Host @"
  To reinstall SSMS on a different volume, set this in the environment file's SSMS block:

      LayoutArguments = '--quiet --norestart --wait --noWeb --installPath E:\SSMS22'

  then run the installer. Detection is by registry DisplayName and version, not by path,
  so DSC will see SSMS missing and install it to the new location.

  READ THE x86 VC++ RUNTIME LINE ABOVE before installing anything.

  Removing SSMS 17.x leaves that registration reporting SSMS 17.x's own runtime version,
  and the next SSMS install then dies at exit code 1603 with no explanation -- the OLE DB
  Driver 19 MSI checks that key, needs 14.38 or higher, and aborts. If the line above says
  [WARN], run the repair it prints first.

  No reboot is required for the product itself. An MSI removal (SSMS 17.x) leaves pending
  file renames, so reboot before a reinstall if anything behaves oddly.
"@ -ForegroundColor Yellow
