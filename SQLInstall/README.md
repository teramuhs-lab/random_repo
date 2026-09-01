# SQL Server Installation Toolkit

This installs and configures SQL Server on one or more Windows servers, the same way
every time, from a single script you run once.

You do not need to know PowerShell DSC to use it. You need to prepare a few things, edit
one settings file, run one script, and then run a second script that checks the result.

**Status:** stable. Verified end to end on both a server that already had SQL Server and
a brand-new server, with all checks passing.

---

## What it does for you

- Installs the SQL Server engine, with patches applied during setup
- Puts data, log, tempdb and backup files on the drives you specify
- Sets the network port and opens the firewall for it
- Applies standard settings: memory limits, parallelism, trace flags, tempdb file count
- Creates the local `SQLAdmins` and `SQLServices` groups and fills them from your AD groups
- Secures the `sa` account and turns on login auditing
- Sets up Database Mail, an operator, and high-severity alerts (created switched off)
- Installs Ola Hallengren's maintenance solution — backup, integrity check and index jobs,
  with a 7-day backup retention

---

## The three machines

| | What it is | What runs there |
|---|---|---|
| **Your PC** | Where you edit files | Nothing. Copy files from here to the admin server. |
| **Admin server** | The management server | You run the installer here |
| **Target servers** | Where SQL Server ends up | Nothing by hand — the installer drives them |

Everything lives in `C:\SQLInstall` on the admin server, and the same folder gets copied
to each target server.

---

## Before you start

Work through this list. The installer now checks most of it for you and stops with a clear
message if something is missing — but it cannot create any of it.

**1. The drives must exist on each target server.** The installer creates *folders*, not
disks. Whatever drive letters your settings file names (typically `E:` backups, `F:` tempdb,
`G:` data, `H:` logs) must already be there.

**2. Your account must already be a local administrator on each target server.** The
installer grants rights to the *install account* for you, but it cannot grant rights to
itself. Ask whoever provisions the servers to add you.

**3. The toolkit and the SQL Server media must be on each target server.** Copy
`C:\SQLInstall` from the admin server to each target:

```powershell
C:\SQLInstall\Copy-SQLInstallToNodes.ps1 -ComputerName 'SERVER1','SERVER2' -Preview
C:\SQLInstall\Copy-SQLInstallToNodes.ps1 -ComputerName 'SERVER1','SERVER2'
```

Run with `-Preview` first — it lists what would copy without copying anything. Only new and
changed files move, so running it again later is quick and safe.

The first copy to a new server is several GB. You can skip media this build does not need:

```powershell
C:\SQLInstall\Copy-SQLInstallToNodes.ps1 -ComputerName 'SERVER1' `
    -ExcludeDir 'SQL2017' -ExcludeFile 'SSMS-Setup-ENU_18.11.1.exe'
```

**4. Check your AD group names are real.** If even one name in your settings file does not
exist in Active Directory, the whole `SQLAdmins` group fails to be created — and the install
still reports success. Check every one:

```powershell
'NPE-SQLAdmins','NPE-CSM-DBA','NPE-ISSO-Computer-Admins' | ForEach-Object {
    try { (Get-ADGroup -Identity $_).Name } catch { "NOT FOUND: $_" }
}
```

**5. Run from a local folder, not a network share.** Use `C:\SQLInstall\...` on the admin
server. Running the installer directly from a UNC path is the most common reason it fails
to start at all.

---

## Step 1 — Set up your settings file

Settings live in `C:\SQLInstall\SQLDSC\Environments\`. Copy one that is close to what you
want and edit it. The important lines:

```powershell
NodeName = 'SERVER1'          # one block per target server
InstanceName          = 'CAPPT'
SQLEnginePort         = '1443'
SQLVersion            = 'SQL2025'
SQLSysAdminAccounts   = 'MS\NPE-SQLAdmins', ...    # get sysadmin inside SQL
LocalServerAdmins     = 'MS\NPE-SQLAdmins', ...    # become local admins on the server
SQLUserDBDir          = 'G:\MSSQL\DATA'
SQLUserDBLogDir       = 'H:\MSSQL\LOG'
SQLTempDBDir          = 'F:\MSSQL\TempDB'
SQLBackupDir          = 'E:\SQLBackups'
```

Give the file a name that says which servers it is for. A file called `...-0708` that
actually targets a different server will catch someone out later.

---

## Step 2 — Run the installer

On the **admin server**, in an **elevated** PowerShell window:

```powershell
C:\SQLInstall\Kickoff_SQL_Install\Start_SQL_Server_Installation_Multiple_Node.ps1
```

It will:

1. Show a picker — choose your settings file
2. Open it for a last look — save and close, then answer `y`
3. Ask for passwords — the install admin account, the SQL service accounts, and a new
   password for the local `SQLInstallAcc`
4. Work through 14 steps, printing `[OK]` as it goes

It takes roughly 10–20 minutes on a fresh server. The servers may reboot; that is normal.

### The one line to watch

**Step 7** must show this for every server:

```
[OK] SERVER1 : SQLInstallAcc created, added to Administrators
```

That account is what applies nearly all the SQL settings. If Step 7 warns instead, stop —
the rest of the run cannot configure anything, and it will tell you so.

### Reading the ending

Every step ends `[OK]`, or shows a count of problems, or `[FAILED]` for the step that
stopped the run. The step that killed a run is always marked `[FAILED]` — a green step is
genuinely green.

A clean finish is not the same as a correct result, which is why there is a second script.

---

## Step 3 — Check it actually worked

```powershell
C:\SQLInstall\SQLDSC\configs\Test_SQLServer_PostInstall.ps1 `
    -EnvDataFilePath 'C:\SQLInstall\SQLDSC\Environments\<your settings file>'
```

This connects to each server and inspects the real state — services, port, firewall,
groups, memory, trace flags, audit settings, mail, jobs — and prints one line per check.
You want:

```
SUMMARY:  [OK] 32   [WARN] 0   [FAIL] 0
RESULT: PASS -- all checked settings match desired state.
```

Anything `[WARN]` or `[FAIL]` names what is wrong. This script changes nothing, so it is
safe to run as often as you like.

---

## What the 14 steps do

| Step | What happens |
|---|---|
| 1 | Checks you are running elevated |
| 2 | You pick the settings file |
| 3 | Opens it so you can review, then waits for you |
| 4 | Loads the settings |
| 5 | Asks for the passwords |
| 6 | Makes your install account a local admin on each server, then tests the connection |
| 7 | Creates the local `SQLInstallAcc` on each server — **the important one** |
| 8 | Adds your AD admin groups to local Administrators |
| 9 | Grants file-share rights — skipped when the servers already have their own copy |
| 10 | Creates the `SQLServices` local group |
| 11 | Refreshes Group Policy |
| 12 | Confirms the install account is a local admin |
| 13 | Checks the required modules, drives and media are all present — **stops here if not** |
| 14 | Installs and configures SQL Server |

---

## If something goes wrong

**Read the message.** The installer prints the underlying error and, where useful, the
exact commands to run next. Most failures name their own cause.

**"Could not re-create psSessions ... The user name or password is incorrect"**
Usually a typo — or a stray space — in the account or password at Step 5. Try it by hand:

```powershell
$c = Get-Credential
New-PSSession -ComputerName SERVER1.your.domain -Credential $c
```

**Step 13 stops with something missing.** That is the point of Step 13 — it found the
problem before changing anything. Add the drive or copy the missing folder and run again.

**The run stopped part-way after a reboot.** Normal on a fresh install. Run it again; it
picks up where it left off and skips what is already done.

**A step shows a problem count but the run continues.** Some steps report and carry on by
design. Always finish with the check script in Step 3 rather than trusting the summary.

**Running it twice is safe.** Every step is written to be repeatable — existing things are
left alone or corrected, not duplicated.

---

## Useful extras

```powershell
# Copy the toolkit to target servers (new and changed files only)
C:\SQLInstall\Copy-SQLInstallToNodes.ps1 -ComputerName 'SERVER1' -Preview

# Copy the toolkit from your PC to the admin server, with checksum verification
C:\SQLInstall\Kickoff_SQL_Install\Publish-SQLInstallFiles.ps1 -WhatIf

# See what the maintenance solution installed, and its backup retention
Invoke-Sqlcmd -ServerInstance 'SERVER1,1443' -TrustServerCertificate -OutputAs DataTables `
  -InputFile 'C:\SQLInstall\SQLDSC\SQLScripts\DatabaseMaintenanceSolution_Get.sql' |
  ForEach-Object { $_ | Format-Table -AutoSize | Out-String }
```

Note the port (`SERVER1,1443`) rather than `SERVER1\CAPPT`. The SQL Browser service is
deliberately switched off, so connections must name the port.

---

## Where to find more

| Document | For |
|---|---|
| [docs/INSTALLATION_FLOW.md](docs/INSTALLATION_FLOW.md) | Diagrams of the flow, the order things happen, and where failures come from |
| [docs/ADVANCED_GUIDE.md](docs/ADVANCED_GUIDE.md) | Full engineering reference — module versions, adding a new SQL Server version, every known issue in detail |
| `SQLDSC\modules\README.md` | How to rebuild the DSC modules folder |
| `Get-Help <function> -Full` | Every helper function in `SQLDSC\Help Functions\` is documented |

Read `docs/ADVANCED_GUIDE.md` before changing the DSC configuration, upgrading to a new
SQL Server version, or touching module versions. It records a number of traps that are not
obvious from the code.