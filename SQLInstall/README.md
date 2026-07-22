# SQL Server Multi-Node Installation Toolkit — Production Guide

This toolkit automates standalone SQL Server 2017 installation and configuration
across one or more Windows servers using PowerShell Desired State Configuration
(DSC), with an optional second phase to configure an Always On Availability
Group (AG) and listener. This document covers everything needed to run it in
production: prerequisites, what each script does, the step-by-step flow, and
the gotchas discovered while hardening this toolkit.

> **Status as of this document**: the main installation flow
> (`Start_SQL_Server_Installation_Multiple_Node.bat/.ps1`) has been run
> end-to-end successfully against a real two-node target (`ddcwnzwgdbs01`,
> `ddcwnzwgdbs02`) and is the most thoroughly hardened path. The AG/listener
> phase (`Start_AG_Configuration.ps1`, `ConfigureAG.ps1`, `Create_Listener.ps1`)
> has **not** been run or hardened this session — treat it as less battle-tested.

---

## 1. Architecture at a glance

```
Kickoff_SQL_Install\Start_SQL_Server_Installation_Multiple_Node.bat
  -> elevates, launches PowerShell -File on the matching .ps1
     Kickoff_SQL_Install\Start_SQL_Server_Installation_Multiple_Node.ps1
       -> imports SQLDSC\Help Functions\HelperFunctions.psm1
       -> Steps 1-13: local prep (admin check, credentials, remoting check,
          local group membership, fileshare perms, GPO refresh, copy DSC
          resources)
       -> Step 14: invokes
          SQLDSC\configs\Install_and_Configure_SQLServer_Multi_Node.ps1
            -> builds a DSC Configuration, compiles MOF files, pushes them to
               all target nodes via Set-DscLocalConfigurationManager +
               Start-DscConfiguration (reboots nodes mid-run, resumes after)

Kickoff_SQL_Install\AG\Start_AG_Configuration.bat
  -> same elevation pattern, launches
     Kickoff_SQL_Install\AG\Start_AG_Configuration.ps1
       -> invokes SQLDSC\configs\ConfigureAG.ps1 (Always On + AG creation)
       -> invokes SQLDSC\configs\Create_Listener.ps1 (AG listener)
```

Both entry points read a per-environment configuration file from
`SQLDSC\environments\*.psd1`, prompt for credentials interactively (never
hardcoded), and drive DSC in **push mode** — no pull server is required.

---

## 2. Directory structure

| Path | Purpose |
|---|---|
| `Kickoff_SQL_Install\` | Entry points (`.bat` launchers + their `.ps1`) |
| `Kickoff_SQL_Install\AG\` | Entry point for the AG/listener phase |
| `SQLDSC\Help Functions\` | Reusable PowerShell functions, loaded as a module |
| `SQLDSC\configs\` | The actual DSC configuration scripts ("recipes") |
| `SQLDSC\environments\` | Per-deployment configuration data (`.psd1`) |
| `SQLDSC\modules\` | Vendored/pinned DSC resource modules (dependencies) |
| `SQLDSC\bits\` | SQL Server installation media, patches, SSMS, .NET 3.5 source — **must be populated before running; not something this doc can supply** |
| `SQLDSC\mofs\` | Generated at runtime (compiled MOF files); cleaned up automatically after each deploy |
| Repo root (`Add_Local_SQL_Install_Account.ps1`, `Copy_SQL_Files_To_Servers.ps1`, disk-space checker) | Standalone utility scripts, not part of the main automated flow |

---

## 3. Prerequisites

**Admin ("kickoff") machine:**
- Windows, PowerShell 5.1 (Windows PowerShell — this toolkit has not been
  validated on PowerShell 7+).
- Local administrator rights.
- PowerShell ISE available (used to open the environment config for review/edit
  mid-run).
- **The toolkit must be run from a genuinely local path (e.g. `C:\SQLInstall`),
  not live from a UNC network share.** Running it from a UNC path (e.g.
  `\\server\share\SQLInstall`) causes Windows to treat every script as
  "remote," and under a `RemoteSigned` execution policy (which this toolkit's
  own `.reg` file sets) that requires a valid signature — and the signatures
  baked into these scripts are stale/expired (see §8). If you must stage from
  a share, copy the whole folder to a local drive first
  (`Copy_SQL_Files_To_Servers.ps1` can do this for you), or at minimum run
  `Get-ChildItem <path> -Recurse | Unblock-File` on the local copy before
  launching.

**Target SQL nodes:**
- Reachable by name/FQDN, ping and PowerShell remoting (WinRM) both working
  from the kickoff machine, PowerShell 5+.
- Data/log/tempdb/backup drive letters referenced in the environment config
  (e.g. `E:`, `F:`, `G:`, `H:`) must already exist and be provisioned — the
  toolkit creates *folders* on those drives, not the drives themselves.
- If the kickoff machine is also one of the target nodes (common in this
  toolkit's usage), that's fine and expected — see the `Restart-Computer`
  note in §8.

**Directory/accounts:**
- Every AD group/account referenced in the environment config
  (`LocalServerAdmins`, `SQLSysAdminAccounts`, service accounts) must
  **actually exist and be spelled correctly**. A bad name does not stop the
  run — it fails that one item, prints a `[WARN]`, and continues. Verify with
  `Get-ADGroup`/`Get-ADUser` before running, especially after copying an
  environment file to a new deployment.
- The local install account (default name `SQLInstallAcc` in the sample
  configs) should exist on each target node **before** running the main
  installer, or the DSC `User` resource will create it — but if you want to
  pre-seed a specific password across many servers, use
  `Add_Local_SQL_Install_Account.ps1` first (see §6).

**DSC resource modules** (vendored under `SQLDSC\modules\`, version-pinned):
- `xSQLServer` 9.0.0.0
- `xNetworking` 5.3.0.0
- `xFailOverCluster` 1.8.0.0
- `SqlServer` 21.0.17224

These get copied to the local admin machine's
`C:\Program Files\WindowsPowerShell\Modules` (and to each target node, mid-run)
automatically as part of the flow — you don't need to install them manually,
but do confirm the versions above match what your environment config's DSC
scripts expect (`Import-DscResource -ModuleVersion ...`).

---

## 4. Environment configuration files (`SQLDSC\environments\*.psd1`)

Each file is a PowerShell data (`.psd1`) document with three top-level keys:

- **`AllNodes`** — an array of node hashtables. The first entry with
  `NodeName = '*'` supplies defaults for every node (service accounts,
  `PSDscAllowDomainUser`, `PSDSCAllowPlainTextPassword`). Subsequent entries
  are the actual target server names.
- **`NonNodeData.Data`** — toolkit-level switches:
  - `DSCResourceLocation` — UNC path DSC resources are sourced from.
  - `CopyDSCResources_to_AdminMachine` — `'YES'`/`'NO'`.
  - `Copy_all_Files_to_TargetNodes` — `'YES'`/`'NO'`; controls whether the DSC
    configuration itself copies SQL binaries/patches/SSMS/PowerShell modules
    to each node as part of the `File` resources (separate from the toolkit's
    own Step 13 copy).
- **`NonNodeData.SQL`** — instance name, port, sysadmin/local-admin account
  lists, all data/log/tempdb/backup paths, feature list, firewall settings,
  MaxDop/memory tuning, trace flags, post-install T-SQL script locations,
  patch source.
- **`NonNodeData.HADR`** — only relevant if you're running the AG phase;
  controls whether `SQLAAGBuild` is `'Yes'`, AG name, endpoint/listener ports,
  failover mode, backup preference, and (per-node) `Role` (`PrimaryReplica` /
  `SecondaryReplica` / `DRReplica`) referenced from `ConfigureAG.ps1`.

Five sample environment files ship in `SQLDSC\environments\`:
`InstallConfigure_SQLServer-0607.psd1`,
`InstallConfigure_SQLServer-09082022.psd1`,
`InstallConfigure_SQLServer-CENTRAL.psd1`,
`InstallConfigure_SQLServer-Single_Node -08262022.psd1`,
`InstallConfigure_SQLServer-Single_Node.psd1`. Copy the closest match, rename
it, and edit before each new deployment — Step 3 of the main installer opens
your selection in ISE specifically for this.

---

## 5. Running the main installer (production)

1. Copy the whole `SQLInstall` folder to a local path (typically
   `C:\SQLInstall`) on the machine you'll run the install from (see §3 — do
   not run live from a UNC share).
2. Ensure `SQLDSC\bits\<Version>\` actually contains the SQL Server
   installation media for the version you're installing (`setup.exe`, etc.) —
   this is not included in source control and must be staged separately.
3. Double-click (or run) `Kickoff_SQL_Install\Start_SQL_Server_Installation_Multiple_Node.bat`.
   It elevates via UAC and launches the matching `.ps1` in a new PowerShell
   window with `-NoExit`, so any failure stays on screen instead of flashing
   shut.
4. The script proceeds through 14 numbered steps, each announced with a
   banner:

   | Step | What it does |
   |---|---|
   | 1 | Verifies the console is running as Administrator |
   | 2 | Opens an `Out-GridView` picker to choose the environment `.psd1` |
   | 3 | Opens the selected config in PowerShell ISE for review/edit; waits for you to confirm it's saved |
   | 4 | Loads the (now-edited) configuration data |
   | 5 | Prompts for the Install Admin credential and any SQL service account credentials |
   | 6 | Pings and verifies PowerShell remoting + version 5+ on every target node |
   | 7 | Adds the local install account to each node's local Administrators group |
   | 8 | Adds the configured DBA/admin AD groups to each node's local Administrators group |
   | 9 | Grants fileshare permissions on the DSC resource share (skips gracefully if running from a local copy — no share to grant) |
   | 10 | Creates the local `SQLServices` group on each node |
   | 11 | Installs the GPMC feature and refreshes Group Policy on all nodes |
   | 12 | Confirms the Install Account is a local admin on every node (adds it if not) |
   | 13 | Copies DSC resource modules to the local admin machine |
   | 14 | Runs the actual DSC deployment — compiles the configuration, applies it, reboots both nodes, resumes after reboot, and reports a summary |

5. At the end, a **STEP SUMMARY** table shows `[OK]` or `[N warning(s)]` per
   step, based only on things actually printed to screen (not incidental
   background noise) — see §7 for how to read it.
6. SQL Server's own real install progress is independent of this console —
   for a second opinion during Step 14, check
   `C:\Program Files\Microsoft SQL Server\140\Setup Bootstrap\Log\<timestamp>\Summary.txt`
   on the target node.

### Running the AG phase (if applicable)

Only relevant if `NonNodeData.HADR.SQLAAGBuild = 'Yes'` in your environment
file and the target nodes are already part of a Windows Failover Cluster.
Run `Kickoff_SQL_Install\AG\Start_AG_Configuration.bat` the same way — it
verifies admin, prompts for the same environment picker and credentials, then
calls `ConfigureAG.ps1` (Always On + AG + optional test database) followed by
`Create_Listener.ps1` (AG listener). **This path has not been hardened this
session** — expect it may hit the same class of issues the main installer had
before this round of fixes (raw error output, hardcoded `C:\SQLInstall`
references in a few commented-out blocks, etc.). Review it before relying on
it in production.

---

## 6. Standalone utility scripts (repo root)

These are not called by the main flow — run them manually when needed:

- **`Add_Local_SQL_Install_Account.ps1`** — (re)creates the local
  `SQLInstallAcc` account and adds it to local Administrators on a hardcoded
  list of servers. Prompts for the password once locally; never writes it to
  disk. **Edit the `$SQLServers` list at the top before running** — it's
  hardcoded to specific server names in the source.
- **`Copy_SQL_Files_To_Servers.ps1`** — Robocopies the entire toolkit
  (including SQL binaries) from a source share out to `C:\SQLInstall` on a
  hardcoded list of target servers, then unblocks the copied files remotely.
  Useful for getting the whole toolkit staged locally on each target node
  ahead of time. **Also has a hardcoded `$sqlservers` list and source
  path — edit before running.**
- **`PowerShell script to Check Free Disk Space of Multiple Servers.ps1`** —
  disk space checker; self-explanatory by name, not reviewed in depth for
  this document.

---

## 7. Reading the output / troubleshooting

- **Banners** (`==== STEP N of 14: ... ====`) mark each stage.
- **`[OK]`** — a specific check or action succeeded.
- **`[WARN]`** — something didn't work but execution continued (a bad AD
  group name, a missing fileshare, a DSC resource issue). These are always
  shown as a clean one-line message, never a raw PowerShell stack trace.
- **`SCRIPT FAILED`** (red banner) — a genuine, unrecoverable error. Shows
  which step it happened in, the error message, and the exact line.
- **`STEP SUMMARY`** at the very end — one line per step, `[OK]` or
  `[N warning(s)]`, so you can see at a glance which steps need a closer look
  without scrolling back through the whole transcript.
- **DSC/LCM "no progress" during Step 14** — during `xSQLServerSetup`, DSC is
  waiting on the real `setup.exe`, which can run 15–40+ minutes with little
  or no console output. To confirm it's actually working rather than stuck:
  - From a separate session (not the one running `-Wait`), check
    `Get-Process setup*` / `Get-Process msiexec` on the target node for real
    CPU/memory activity.
  - Check the real setup log:
    `Get-ChildItem 'C:\Program Files\Microsoft SQL Server\140\Setup Bootstrap\Log' -Directory | Sort LastWriteTime -Descending | select -First 1`
  - `Get-DscConfigurationStatus -CimSession <node>` failing with "Update-DscConfiguration cmdlet is in progress" is actually a **good sign** — it means the LCM is alive and busy, not dead.
  - Don't interrupt a mid-install DSC/setup process — killing it can leave
    SQL Server partially installed.

---

## 8. Known issues and design notes

- **Digital signatures are stale.** Every custom script in this toolkit
  carries an Authenticode signature block from a certificate that expired in
  March 2021, and several scripts' current content no longer matches their
  original signed hash (any edit invalidates a signature). These signatures
  are effectively decorative at this point — **do not rely on them for trust
  or integrity verification.** Execution currently works because these
  scripts run from a local path under a `RemoteSigned` policy, which doesn't
  require signing for local-origin scripts. If your environment enforces
  `AllSigned` or WDAC/AppLocker, this toolkit will need to be re-signed with
  a current, valid certificate before it will run at all.
- **`0_UnblockFile.ps1` makes a machine-wide security-relevant change.** It
  writes `ExecutionPolicy = Bypass` directly into
  `HKLM:\Software\Policies\Microsoft\Windows\PowerShell` (the Group Policy
  cache location) to force past `RemoteSigned` restrictions. This is a
  **local override of your organization's execution policy**, not scoped to
  this toolkit — it affects all PowerShell script execution on that machine
  until the next domain Group Policy refresh reapplies the real policy.
  Review this with your security/compliance team before using it in a
  production environment with a security baseline you don't control.
- **Must run from a local path, not a live UNC share.** Covered in §3 — this
  is the single most common reason the installer silently fails to start.
- **Local (non-domain) accounts cannot be added to a different machine's
  local groups.** `Add-UserToLocalGroup` correctly scopes the local install
  account to its own node (fixed this session); if you add new logic that
  loops over nodes, make sure any *local* account reference stays scoped to
  `-ComputerName` = that same node, not the full node list. Domain
  accounts/groups don't have this restriction.
- **`Restart-Computer -Wait` cannot wait on its own host.** If the kickoff
  machine is also one of the target SQL nodes (common in this toolkit's
  usage), you'll see an informational message about this during Step 14 —
  it's expected, not a failure; the local computer still restarts and the
  script correctly waits on the *other* node(s).
- **Leftover DSC jobs from an interrupted prior run** can cause
  `Cannot invoke the Set-DscLocalConfigurationManager cmdlet...` errors on
  the next attempt. This usually self-resolves (`-Force` cancels the stale
  job automatically), but if you deliberately killed a run mid-flight, you
  may need `Stop-DscConfiguration -Force -CimSession <node>` before retrying.
- **Environment config lists can silently contain unresolvable AD
  principals.** A group name typo, a stale/deleted group, or a wrong domain
  prefix in `LocalServerAdmins` or `SQLSysAdminAccounts` doesn't stop the
  install — it fails just that one entry and moves on. Always check the
  STEP SUMMARY and any `[WARN]` lines against your actual AD structure after
  a run, not just whether it reached "DONE."
- **MOF files can contain recoverable credentials.** The sample environment
  configs set `PSDSCAllowPlainTextPassword = $true`, and MOF compilation
  embeds the credentials you provide interactively. The toolkit deletes the
  MOF output folder immediately after each deploy
  (`Remove-Item $mofLocation -Recurse -Force`), which is good hygiene, but if
  a run is interrupted before that cleanup step, MOF files containing
  credentials could be left behind under `SQLDSC\mofs\`. For a genuinely
  hardened production posture, consider DSC certificate-based MOF encryption
  instead of plaintext-allowed credentials.

---

## 9. Version/compatibility

- Primary target: **SQL Server 2017** (the `Version` parameter also accepts
  `SQL2012`/`SQL2014`/`SQL2016`, but only 2017's media has been verified
  present in `SQLDSC\bits\` this session).
- **Windows PowerShell 5.1** — not tested on PowerShell 7+.
- DSC resource module versions are pinned exactly as listed in §3; if you
  update them, update the `-ModuleVersion` references in
  `Install_and_Configure_SQLServer_Multi_Node.ps1` and `ConfigureAG.ps1` to
  match, or DSC compilation will fail outright.

---

## 10. Summary of fixes applied this session

For context on why some of the above behaviors exist, this session fixed (in
roughly this order): hardcoded `C:\SQLInstall` paths in every `.bat` launcher
that broke as soon as the toolkit lived anywhere else; a launcher `.bat` that
silently failed before ever opening PowerShell due to a missing `.reg` file
path; `$PSScriptRoot` coming back empty under the elevated `Start-Process`
invocation chain; the Authenticode-signature-vs-`RemoteSigned` conflict
described in §8; a cross-machine local-account bug in
`Add-UserToLocalGroup`'s caller; raw PowerShell error dumps replaced with
clean `[WARN]`/`[INFO]` messages across the launcher, helper functions, and
DSC deploy script; a `$Error.Count`-based step-summary that picked up
incidental noise, replaced with an explicit warning counter; and a redundant
loop that repeated a multi-node operation once per node unnecessarily. See
git history on `main` for the individual commits.
