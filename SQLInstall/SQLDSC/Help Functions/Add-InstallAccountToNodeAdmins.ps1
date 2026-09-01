function Add-InstallAccountToNodeAdmins
{
<#
.SYNOPSIS
    Adds the domain installation account to the local Administrators group on each target
    node, so the installer can open a PowerShell remoting session as that account.

.DESCRIPTION
    This removes a manual post-provisioning step that the environment configs only
    described in a comment:

        "the Installer account is manually added to the local admins group after VMs are
         provisioned"

    When it had not been done, the run died in Step 6 with

        Could not re-create psSessions to the remote server <node>

    even though WinRM was healthy and the node answered ping -- because Step 6 connects
    with -Credential <install account>, and that account could not log on.

    ORDERING -- this is why the work cannot be left to DSC or to Step 7:

      * Step 6 needs the install account to already be an administrator, and Step 6 runs
        before everything else that touches the nodes.
      * Step 7 creates the LOCAL SQLInstallAcc used as PsDscRunAsCredential. That is a
        different account and a different problem.
      * A DSC resource cannot do it either: pushing a MOF happens later still.

    CHICKEN AND EGG -- the remote call here deliberately does NOT pass -Credential. It
    runs as whoever is executing the installer, who must already be an administrator on
    the nodes (Step 1 checks local elevation; this is the remote equivalent). Using the
    install account to grant rights to the install account cannot work.

    Idempotent: an account that is already a member is reported as such, not treated as
    an error.

.PARAMETER UserName
    The domain account, ideally DOMAIN\user. A bare name is qualified with the domain
    from -Credential if given, otherwise with $env:USERDOMAIN.

.PARAMETER ComputerName
    Target nodes.

.PARAMETER Credential
    Optional. An account with administrative rights on the nodes, if the current user is
    not. Omit to use the current session's identity, which is the normal case.

.PARAMETER WarningCountVariable
    Global counter incremented per warning so failures appear in the installer's STEP
    SUMMARY. Defaults to 'SQLInstallWarningCount'.

.EXAMPLE
    Add-InstallAccountToNodeAdmins -UserName 'MS\NPEADMsomeone' -ComputerName 'NODE07','NODE08'

.NOTES
    Membership in Administrators is also what confers the "log on as a batch job" right,
    which Windows evaluates at logon -- so this must happen before the session is opened,
    not merely before the account is used.
#>
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory = $true)]
        [string] $UserName,

        [Parameter(Mandatory = $true)]
        [string[]] $ComputerName,

        [System.Management.Automation.PSCredential] $Credential,

        [string] $WarningCountVariable = 'SQLInstallWarningCount'
    )

    # ---------------------------------------------------------------------------
    # Normalise to DOMAIN\user. Add-LocalGroupMember will not accept a bare name for a
    # domain principal -- it would look for a local user of that name and fail with
    # "principal not found", which reads like the account does not exist at all.
    # ---------------------------------------------------------------------------
    # Trim first, independently of the caller. Whitespace round a user name is invisible in
    # every downstream message: a trailing space turns into "Principal MS\User  was not
    # found" here and "The user name or password is incorrect" from New-PSSession, neither
    # of which points at whitespace.
    if ( $UserName -ne $UserName.Trim() )
    {
        Write-Host "  [INFO] Trimmed whitespace from '$UserName'." -ForegroundColor Cyan
        $UserName = $UserName.Trim()
    }

    $resolvedName = $UserName

    if ( $UserName -notmatch '[\\@]' )
    {
        $domain = if ( $Credential -and $Credential.GetNetworkCredential().Domain )
                  { $Credential.GetNetworkCredential().Domain } else { $env:USERDOMAIN }
        $resolvedName = "$domain\$UserName"
        Write-Host "  [INFO] '$UserName' has no domain qualifier; using '$resolvedName'." -ForegroundColor Cyan
    }
    elseif ( $UserName -match '^(?<user>[^@]+)@' )
    {
        # A UPN works for authentication but not reliably as a group member name.
        Write-Host "  [INFO] '$UserName' is a UPN; if this fails, pass it as DOMAIN\user instead." -ForegroundColor Cyan
    }

    Write-Host "  Ensuring '$resolvedName' is a local administrator on $($ComputerName -join ', ')" -ForegroundColor Yellow

    $scriptBlock = {
        param ( [string]$Member )

        # Add blindly and treat "already a member" as success. Get-LocalGroupMember is
        # avoided deliberately: it throws outright if the group contains ANY unresolvable
        # SID -- a stale domain account left in Administrators is enough to break it, and
        # these groups routinely carry them.
        try
        {
            Add-LocalGroupMember -Group 'Administrators' -Member $Member -ErrorAction Stop
            "OK|$($env:COMPUTERNAME)|added to Administrators"
        }
        catch
        {
            if ( $_.FullyQualifiedErrorId -match 'MemberExists' )
            {
                "OK|$($env:COMPUTERNAME)|already a member"
            }
            else
            {
                "FAIL|$($env:COMPUTERNAME)|$(($_.Exception.Message -replace '[\r\n]+',' ').Trim())"
            }
        }
    }

    $failures = New-Object System.Collections.Generic.List[string]

    foreach ( $node in $ComputerName )
    {
        if ( -not $PSCmdlet.ShouldProcess($node, "Add '$resolvedName' to local Administrators") )
        {
            continue
        }

        $invokeParams = @{
            ComputerName = $node
            ScriptBlock  = $scriptBlock
            ArgumentList = $resolvedName
            ErrorAction  = 'Stop'
        }
        if ( $Credential ) { $invokeParams.Credential = $Credential }

        try
        {
            $result = Invoke-Command @invokeParams
        }
        catch
        {
            # Reaching the node at all failed -- a different problem from the membership
            # change being rejected, so say which one happened.
            $msg = ( $_.Exception.Message -replace '[\r\n]+', ' ' ).Trim()
            Write-Host "  [WARN] $node`: could not connect to grant admin rights. $msg" -ForegroundColor Yellow
            Write-Host "         Run as an account that is already an administrator on $node, or add '$resolvedName' by hand." -ForegroundColor DarkYellow
            $failures.Add($node)

            if ( Test-Path "Variable:Global:$WarningCountVariable" )
            {
                Set-Variable -Name $WarningCountVariable -Scope Global `
                             -Value ((Get-Variable -Name $WarningCountVariable -Scope Global -ValueOnly) + 1)
            }
            continue
        }

        foreach ( $line in @($result) )
        {
            $status, $computer, $detail = $line -split '\|', 3

            if ( $status -eq 'OK' )
            {
                Write-Host "  [OK] $computer`: $resolvedName $detail" -ForegroundColor Green
            }
            else
            {
                Write-Host "  [WARN] $computer`: could not add $resolvedName -- $detail" -ForegroundColor Yellow
                $failures.Add($computer)

                if ( Test-Path "Variable:Global:$WarningCountVariable" )
                {
                    Set-Variable -Name $WarningCountVariable -Scope Global `
                                 -Value ((Get-Variable -Name $WarningCountVariable -Scope Global -ValueOnly) + 1)
                }
            }
        }
    }

    # Reported, not thrown. The very next thing the installer does is open a session as
    # this account, which is a far better test of whether it worked than anything here --
    # and it fails with a clear message of its own if it did not.
    if ( $failures.Count -gt 0 )
    {
        Write-Host "  [WARN] Admin rights unconfirmed on: $($failures -join ', '). Step 6 will fail if the account cannot log on." -ForegroundColor Yellow
    }
}
