# SQL Server Installation Toolkit — Advanced Guide

**Looking for how to run an installation? Start with [../README.md](../README.md).** That
is the short, task-oriented guide, and it is enough for a normal install.

This document is the engineering reference underneath it: module versions and why they are
pinned, how to add support for a new SQL Server version, why there are two DSC
configuration scripts, and a catalogue of failure modes in full detail. Read it before
changing the DSC configuration, upgrading SQL Server versions, or touching module versions.

This toolkit installs and configures standalone SQL Server instances across one or
more Windows servers using PowerShell Desired State Configuration (DSC), with an
optional second phase for an Always On Availability Group (AG) and listener.
**SQL Server 2012–2017 and 2025 are supported**, each driven by the DSC module built
for that release (see section 6).

### Documentation map

| Document | Covers |
|---|---|
| [../README.md](../README.md) | **Start here.** Prerequisites, running the installer, verifying the result, common problems — in plain language |
| **ADVANCED_GUIDE.md** (this file) | Module versions, adding a SQL version, the two config scripts, every known issue in detail |
| [INSTALLATION_FLOW.md](INSTALLATION_FLOW.md) | Diagrams of the end-to-end flow, the DSC dependency graph, the deploy/reboot sequence, and where failures come from |
| [../SQLDSC/modules/README.md](../SQLDSC/modules/README.md) | Which DSC modules are needed for which SQL version, and how to restore them |

> **Section numbers below still refer to sections of this document.** Where the text says
> "see section 8", it means section 8 here, not in the README.

### Maturity

| Path | Status |
|---|---|
| Main installation flow (`Start_SQL_Server_Installation_Multiple_Node.bat/.ps1`) | Run end-to-end against real two-node targets for both SQL2017 and SQL2025, and verified with the post-install checker (section 8). The most hardened path. |
| Post-install verification (`Test_SQLServer_PostInstall.ps1`) | Used routinely; reports live state rather than intent. |
| AG / listener phase (`Start_AG_Configuration.ps1`, `ConfigureAG.ps1`, `Create_Listener.ps1`) | **Not hardened or tested.** Expect the class of issues the main installer had before hardening. Review before relying on it. |

> **The installer printing `DONE` is not evidence of success.** It reports what the
> script attempted, not whether the desired state was reached — a run can complete
> cleanly while almost nothing was configured. Always confirm with the verification
> script in section 8. The mechanism behind this is documented in
> [INSTALLATION_FLOW.md §4](INSTALLATION_FLOW.md#4-dsc-resource-dependency-graph-️).

---

## 1. Architecture at a glance

> Diagrams of the full flow, the DSC dependency graph and the deployment sequence
> live in [INSTALLATION_FLOW.md](INSTALLATION_FLOW.md). The text below is
> the short version.

```
Kickoff_SQL_Install\Start_SQL_Server_Installation_Multiple_Node.bat
  -> elevates, launches PowerShell -File on the matching .ps1
     Kickoff_SQL_Install\Start_SQL_Server_Installation_Multiple_Node.ps1
       -> imports SQLDSC\Help Functions\HelperFunctions.psm1
       -> Steps 1-13: local prep (admin check, credentials, remoting check,
          local group membership, fileshare perms, GPO refresh, copy DSC
          resources)
       -> Step 14: invokes ONE of two config scripts, chosen by SQLVersion (see section 6)
            SQL2012-2017:
              SQLDSC\configs\Install_and_Configure_SQLServer_Multi_Node.ps1
                (xSQLServer 9.0.0.0)
            SQL2025+:
              SQLDSC\configs\Install_and_Configure_SQLServer_Multi_Node_SqlServerDsc.ps1
                (SqlServerDsc 17.5.1)
            -> builds a DSC Configuration, compiles MOF files, pushes them to
               all target nodes via Set-DscLocalConfigurationManager +
               Start-DscConfiguration (reboots nodes mid-run, resumes after)

       -> after the run, verify with (see section 7):
          SQLDSC\configs\Test_SQLServer_PostInstall.ps1

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
  baked into these scripts are stale/expired (see section 11). If you must stage from
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
  note in section 11.

**Directory/accounts:**
- Every AD group/account referenced in the environment config
  (`LocalServerAdmins`, `SQLSysAdminAccounts`, service accounts) must
  **actually exist and be spelled correctly**. A bad name does not stop the
  run — it fails that one item, prints a `[WARN]`, and continues. Verify with
  `Get-ADGroup`/`Get-ADUser` before running, especially after copying an
  environment file to a new deployment.
- The local install account (default name `SQLInstallAcc` in the sample
  configs) does **not** need to exist beforehand. **Step 7 of the kickoff script
  creates it** on every node, sets its password from the credential you supply,
  adds it to local Administrators, and verifies it exists before reporting `[OK]`.
  It has to happen there rather than in DSC: the `PsDscRunAsCredential`
  resources need the account before the MOF is pushed. The DSC `User` resource
  that used to declare it has been removed — see the logon-type entry in
  section 11 for why.
  `Add_Local_SQL_Install_Account.ps1` at the repo root does the same job
  standalone, but note it **deletes and recreates** the account rather than
  resetting the password, which orphans any SQL login tied to the old SID.
  Prefer Step 7.
- **Whoever runs the installer must already be a local administrator on every
  target node.** Step 6 makes the *install account* an administrator, using the
  operator's own rights to do it — an account cannot grant rights to itself.
  This is one of only two prerequisites nothing in the toolkit can create; the
  other is the data volumes.

### DSC modules — what's required, where they live, and SQL-version compatibility

#### Where the modules live

There are two locations, and the distinction matters:

| Location | Purpose |
|---|---|
| `SQLDSC\modules\<Name>\<Version>\` | **Source** — vendored in this repo, version-pinned. Nothing loads them from here. |
| `C:\Program Files\WindowsPowerShell\Modules\` | **Deployed** — where PowerShell/DSC actually loads them from, on both the admin machine and every target node. |

How they get from source to deployed:
- **Admin machine** — Step 13 of the main installer ("Copying DSC resources").
- **Target nodes** — the `File 'CopyPowerShellDSCModulesLocally'` DSC resource, but
  **only when `Copy_all_Files_to_TargetNodes = 'YES'`**. With `'NO'` (the common
  setting when you stage servers by hand) you must copy them yourself along with
  the rest of `SQLDSC\`.
- The environment config also references them as a share:
  `DSCResourceLocation = "\\<adminserver>\SQLInstall\SQLDSC\modules"` — this
  requires a file share named `SQLInstall` on the admin machine. If that share
  doesn't exist you'll see the harmless Step 9 warning described in section 10.

#### Required for SQL Server 2012–2017 (the proven path)

| Module | Version | Imported by | Provides |
|---|---|---|---|
| `PSDesiredStateConfiguration` | built into Windows | all DSC configs | `File`, `User`, `Group`, `Service`, `Script`, `Package`, `WindowsFeature` |
| `xSQLServer` | 9.0.0.0 | `Install_and_Configure_SQLServer_Multi_Node.ps1` (line 56), `ConfigureAG.ps1` (55), `Create_Listener.ps1` (45) | `xSQLServerSetup`, `xSQLServerNetwork`, `xSQLServerConfiguration`, `xSQLServerMaxDop`, `xSQLServerMemory`, `xSQLServerScript`, AG resources |
| `xNetworking` | 5.3.0.0 | same three scripts | `xFirewall` |
| `SqlServer` | 21.0.17224 | **never imported explicitly** — implicit runtime dependency | `xSQLServer`'s `Import-SQLPSModule` helper loads it for SMO. Ships SMO **14.0.x**, which is why this combination works for SQL2017 (major version 14). |
| `xFailOverCluster` | 1.8.0.0 | **not imported by any config** in this repo | Vendored but currently unused — kept in case the AG phase needs it. |

Note the two module versions are **hard-pinned** in the configs
(`Import-DscResource -ModuleName 'xSQLServer' -ModuleVersion '9.0.0.0'`), so
adding newer modules alongside them does not change which DSC resources load.

#### Required for SQL Server 2025

SQL2025 needs the **same** imports as above to compile — the version difference
is only the `$sqlVersionInfo` entry (section 5). But `xSQLServer` 9.0.0.0 **cannot fully
configure SQL2025**, for a reason that can't be fixed in the config:

`xSQLServerHelper.psm1` loads SMO assemblies with a **version pinned to the SQL
major version** (lines 214 and 276):

```powershell
$sqlSmoAssemblyName = "Microsoft.SqlServer.Smo, Version=$sqlMajorVersion.0.0.0, ..."
$sqlSqlWmiManagementAssemblyName = "Microsoft.SqlServer.SqlWmiManagement, Version=$sqlMajorVersion.0.0.0, ..."
```

- SQL2017 → asks for `Version=14.0.0.0` → the vendored `SqlServer` 21.0.17224
  ships exactly 14.0.x → **works**.
- SQL2025 → asks for `Version=17.0.0.0` → no such assembly in that module →
  **fails**.

`MSFT_xSQLServerNetwork` (the `ConfigureSQLPort` resource, which sets TCP/IP and
the static port) calls `Register-SqlWmiManagement` in both its `Get` and `Set`
(lines 38 and 150), so it depends directly on that pinned
`SqlWmiManagement` assembly. **This is why TCP/IP and the static port are never
configured on SQL2025** — independent of the `DependsOn` cascade in section 11.

Two modules are therefore vendored for the SQL2025 path:

| Module | Version | Why |
|---|---|---|
| `SqlServerDsc` | 17.5.1 | Maintained successor to `xSQLServer`. Loads SMO via `Import-SqlDscPreferredModule` (dynamic) instead of a pinned assembly version, so it isn't tied to one SQL release. Provides `SqlSetup`, `SqlProtocol`/`SqlProtocolTcpIp`, `SqlConfiguration`, `SqlMaxDop`, `SqlMemory`, `SqlScript`, `SqlWindowsFirewall`, the AG resources, plus native `SqlTraceFlag`, `SqlAudit`, `SqlDatabaseMail`, `SqlAgentOperator`, `SqlAgentAlert`. |
| `SqlServer` | 22.4.5.1 | Ships SMO **17.100.73.0**, i.e. major version 17 — the version SQL2025 needs. Vendored alongside 21.0.17224, not replacing it. |

> **These two are in use by the SQL2025 path only.**
> `Install_and_Configure_SQLServer_Multi_Node_SqlServerDsc.ps1` imports
> `SqlServerDsc` 17.5.1 and is selected automatically when
> `SQLVersion = 'SQL2025'`; `Install_and_Configure_SQLServer_Multi_Node.ps1`
> still imports `xSQLServer` 9.0.0.0 and serves SQL2012–2017 unchanged. A
> SQL2012–2017 run never opens the newer script, so it never loads
> `SqlServerDsc` or SMO 17.x. See section 6.

> ⚠️ **Caution when deploying `SqlServer` 22.4.5.1 to SQL2012–2017 nodes.**
> Unlike the DSC modules, the `SqlServer` module version is **not** pinned by the
> configs — `xSQLServer`'s `Import-SQLPSModule` just imports "SqlServer", which
> resolves to the **highest installed version**. If 22.4.5.1 (SMO 17.x) is
> present on a SQL2017 node, the pinned `Version=14.0.0.0` lookup may no longer
> be satisfied, which could break a currently-working path. Deploy 22.4.5.1 only
> to nodes running SQL2025, or re-test SQL2017 explicitly before rolling it out
> broadly.

#### Quick reference

```
SQLDSC\modules\
  PSDesiredStateConfiguration     (not vendored - built into Windows)
  xSQLServer\9.0.0.0\             SQL2012-2017   <- pinned by all configs today
  xNetworking\5.3.0.0\            all versions   <- pinned by all configs today
  xFailOverCluster\1.8.0.0\       unused
  SqlServer\21.0.17224\           SQL2017 (SMO 14.0.x)
  SqlServer\22.4.5.1\             SQL2025 (SMO 17.100.x)   <- staged, see caution
  SqlServerDsc\17.5.1\            SQL2025                  <- staged, not wired in
```

Verify what is actually deployed on any node with:
```powershell
Get-Module -ListAvailable -Name xSQLServer, xNetworking, SqlServer, SqlServerDsc, xFailOverCluster |
    Select-Object Name, Version, Path
```

#### Obtaining the modules (they are NOT in source control)

`SQLDSC/modules/` is listed in `.gitignore` — like `SQLDSC/bits/`, these are
vendored binaries rather than source, so **a fresh clone of this repo will not
contain them** and the installer will fail to compile until they are staged.

`xSQLServer` 9.0.0.0 and `xNetworking` 5.3.0.0 are kept in the repo's history as
`.zip` + `.checksum` files next to the extracted folders, so those can be restored
by unzipping. The two newer modules come from the PowerShell Gallery:

```powershell
# Run on a machine WITH internet access, then copy the folders to the target servers.
# Save-Module (not Install-Module) writes a plain <Name>\<Version>\ tree you can copy anywhere,
# which is what makes this work for air-gapped nodes.
Save-Module -Name SqlServerDsc -RequiredVersion 17.5.1   -Path 'C:\SQLInstall\SQLDSC\modules'
Save-Module -Name SqlServer    -RequiredVersion 22.4.5.1 -Path 'C:\SQLInstall\SQLDSC\modules'
```

Gallery pages (for hash/signature verification or manual `.nupkg` download if
`Save-Module` is blocked by proxy):
- `https://www.powershellgallery.com/packages/SqlServerDsc/17.5.1`
- `https://www.powershellgallery.com/packages/SqlServer/22.4.5.1`

Approximate sizes, for copy planning — the `SqlServer` module is by far the
largest single item in the toolkit apart from the SQL media itself:

| Module | Files | Size |
|---|---:|---:|
| `SqlServer` 22.4.5.1 | 913 | 216 MB |
| `SqlServer` 21.0.17224 | 268 | 57 MB |
| `SqlServerDsc` 17.5.1 | 197 | 7.6 MB |
| `xSQLServer` + `xNetworking` + `xFailOverCluster` | — | ~6 MB |
| **Total `SQLDSC\modules\`** | **1762** | **287 MB** |

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

## 5. Installing a different SQL Server version (e.g. SQL2025)

The main installer supports SQL Server 2012/2014/2016/2017 out of the box, and
**SQL2025** as of this writing. It's designed to be additive — adding a new
version doesn't change behavior for environment configs that don't request it.

> **Status**: SQL2025 media is staged and verified in `SQLDSC\bits\SQL2025\`
> (confirmed via `setup.exe`'s own version info — Build 17). The code changes
> below have been run end-to-end successfully against a real two-node target
> (`DDCWNZWGDBS03`, `DDCWNZWGDBS04`, instance `CAPPT`) using
> `SQLDSC\environments\InstallConfigure_SQLServer2025-CAPPT.psd1` — the DSC
> deployment correctly invoked `SQL2025\setup.exe` against
> `HKLM:\...\Microsoft SQL Server\170\...` (build 17) with
> `/FEATURES=SQLENGINE,FULLTEXT,CONN,BC`, confirming the version-selection
> logic works as designed.

### How version selection works

- `Kickoff_SQL_Install\Start_SQL_Server_Installation_Multiple_Node.ps1` reads
  `NonNodeData.SQL.SQLVersion` from the selected environment `.psd1`. If that
  field is blank/absent, it falls back to `"SQL2017"` (the original hardcoded
  default), so existing environment files that don't set it are unaffected.
- `SQLDSC\configs\Install_and_Configure_SQLServer_Multi_Node.ps1` validates the
  version against a `[ValidateSet(...)]` and looks up its internal build
  number + feature list from a `$sqlVersionInfo` hashtable — this is what
  drives the `MSSQL<Build>.<Instance>\...\sqlservr.exe` firewall rule path and
  the `/FEATURES=` argument passed to `xSQLServerSetup`.

### Exact code changes made for SQL2025 (as a reference example)

Only 4 lines across 2 files — everything else in both scripts is untouched:

| File | Line | Change |
|---|---|---|
| `Kickoff_SQL_Install\Start_SQL_Server_Installation_Multiple_Node.ps1` | 455 | `Version = ...` now reads `NonNodeData.SQL.SQLVersion` from the environment config instead of a hardcoded `"SQL2017"` |
| `SQLDSC\configs\Install_and_Configure_SQLServer_Multi_Node.ps1` | 11 | Added `"SQL2025"` to the `$Version` param's `[ValidateSet(...)]` |
| `SQLDSC\configs\Install_and_Configure_SQLServer_Multi_Node.ps1` | 84 | Added the `'SQL2025' = @{ Build = '17'; ... }` entry to `$sqlVersionInfo` |

**`Kickoff_SQL_Install\Start_SQL_Server_Installation_Multiple_Node.ps1`, line 455**
(inside the `$param` hashtable passed to the deploy script) — was a fixed
literal, now reads from the environment config with a fallback:
```powershell
# Before: Version = "SQL2017"
Version = if ( -not [string]::IsNullOrEmpty($envData.NonNodeData.SQL.SQLVersion) ) { $envData.NonNodeData.SQL.SQLVersion } else { "SQL2017" }
```
This is the actual switch — everything else below is just making the value it
produces valid.

**`SQLDSC\configs\Install_and_Configure_SQLServer_Multi_Node.ps1`, line 11**
— added `"SQL2025"` to the `$Version` parameter's `[ValidateSet(...)]`. Without
this, the value coming from line 455 above throws a parameter-validation
error before the script runs at all:
```powershell
# Before: [ValidateSet("SQL2017","SQL2016","SQL2014","SQL2012")]
[ValidateSet("SQL2025","SQL2017","SQL2016","SQL2014","SQL2012")]
```

**Same file, line 84** — a new entry added to the existing `$sqlVersionInfo`
hashtable (every other version already has one):
```powershell
'SQL2025' = @{ Build = '17'; SQLEngineFeatures = 'SQLENGINE,FULLTEXT'; ExtraFeatures = 'FULLTEXT' }
```
`Build` drives the firewall rule's path to `sqlservr.exe`
(`MSSQL17.<Instance>\...`); `SQLEngineFeatures`/`ExtraFeatures` become the
`/FEATURES=` argument passed to `xSQLServerSetup`.

> **Why `CONN,BC` are omitted for SQL2025 (learned the hard way).** Every other
> version in the table includes `CONN` (Client Tools Connectivity) and `BC`
> (Backward Compatibility). SQL2025's `setup.exe` **silently ignores both** — its
> `Summary.txt` reports `FEATURES: SQLENGINE, FULLTEXT` and discovers only
> Database Engine + Full-Text, even when CONN,BC were requested. The install
> still succeeds, but `xSQLServerSetup`'s `Test-TargetResource` then looks for
> CONN/BC, never finds them, and returns `false` forever — so DSC marks the
> resource **failed** and skips its entire `DependsOn` chain (TCP port, SQL
> firewall rule, SSMS, all `sp_configure` options, MaxDop/memory, and all the
> T-SQL scripts), while the run still prints "DONE". Symptom: SQL is installed
> and running, but virtually nothing is configured. See section 11 for the full
> description of this failure mode.

### To add support for a new version

1. **Stage the installation media** under `SQLDSC\bits\<VersionName>\` (e.g.
   `SQLDSC\bits\SQL2025\`) so that **`setup.exe` sits directly at that path**,
   alongside `x64\`, `redist\`, `resources\`, `1033_ENU_LP\`,
   `MediaInfo.xml`, `autorun.inf`, and `SqlSetupBootstrapper.dll` — the exact
   layout an extracted SQL Server ISO produces. If your media arrives as an
   `.iso`, mount and copy it (don't just drop the `.iso` file in the folder —
   DSC's `File` resource copies the folder's *contents*, and `xSQLServerSetup`
   needs `setup.exe` to actually be there, not inside an unmounted image):
   ```powershell
   $mount = Mount-DiskImage -ImagePath 'C:\SQLInstall\SQLDSC\bits\SQL2025\SQLServer2025-x64-ENU-StdDev.iso' -PassThru
   $drive = ($mount | Get-Volume).DriveLetter
   Copy-Item "$drive`:\*" 'C:\SQLInstall\SQLDSC\bits\SQL2025\' -Recurse -Force
   Dismount-DiskImage -ImagePath 'C:\SQLInstall\SQLDSC\bits\SQL2025\SQLServer2025-x64-ENU-StdDev.iso'
   ```
   Verify the extraction actually worked — check `setup.exe`'s own version
   info to confirm you got the right build:
   ```powershell
   (Get-Item 'C:\SQLInstall\SQLDSC\bits\SQL2025\setup.exe').VersionInfo | Format-List ProductVersion, FileVersion
   ```
   A newer release's folder layout doesn't have to match an older reference
   version's (e.g. `SQLDSC\bits\SQL2017\`) file-for-file — Microsoft's own
   packaging can legitimately change between releases. SQL2025's media, for
   example, ships several VC++ runtime DLLs (`msvcp140*.dll`,
   `vcruntime140*.dll`, `concrt140.dll`, etc.) loose at the root next to
   `setup.exe` that SQL2017's media doesn't have — that's a real, current
   dependency of a self-contained bootstrapper, not clutter, and shouldn't be
   deleted just because an older version's folder didn't have it.

   What *is* safe to clean up is a genuinely redundant duplicate of the same
   media sitting alongside an already-verified extraction (e.g. a `.zip`/
   `.7z`/second `.iso` copy someone left in the same folder after staging).
   The way to tell the difference: check file timestamps. Files that share
   the same original build date/time as `setup.exe` are genuine media
   content — keep them regardless of whether an older reference version had
   an equivalent. A file (or archive) with a much *later* modified date,
   inconsistent with the rest of the media's build timestamp, is almost
   always a staging/transfer artifact, safe to remove once the primary
   extraction is confirmed working via the version check above.

2. **Add the version to `Install_and_Configure_SQLServer_Multi_Node.ps1`**:
   - Add the version name to the `[ValidateSet(...)]` on the `$Version`
     parameter.
   - Add an entry to `$sqlVersionInfo` with the correct internal `Build`
     number (confirm it from the real `setup.exe`'s `ProductVersion`/
     `FileVersion`, as above, rather than guessing — SQL Server's internal
     build numbers have incremented by exactly 1 each release: 2016=13,
     2017=14, 2019=15, 2022=16, 2025=17) and the feature token list your
     edition/release actually supports (`SQLENGINE,FULLTEXT,CONN,BC` has
     been stable across 2016/2017/2025; verify against your own media if a
     future version changes this).

3. **Point an environment config at it**: copy an existing `.psd1`, set
   `NonNodeData.SQL.SQLVersion = 'SQL2025'` (or your new version name) — the
   `SQLBitsSource`/`SQLBitsDestination` paths already build the final path as
   `...\bits\ + $Version`, so no other path changes are needed as long as the
   folder name under `bits\` matches the version string exactly.

4. **Test on one throwaway node before trusting the full DSC-driven flow.**
   The `xSQLServerSetup` DSC resource comes from the vendored `xSQLServer`
   module version 9.0.0.0 — an old, unmaintained community module that
   predates every SQL Server release after 2017. Adding a hashtable entry
   makes this *toolkit's* logic accept a new version, but it does not
   guarantee that resource's `Test`/`Set` logic (which parses `setup.exe`
   output, inspects specific registry paths, and passes through command-line
   arguments) is actually compatible with a newer installer's behavior. A
   manual, non-DSC test install
   (`setup.exe /ACTION=install /FEATURES=SQLENGINE,FULLTEXT,CONN,BC /IACCEPTSQLSERVERLICENSETERMS /QUIETSIMPLE ...`)
   on one server is the cheapest way to confirm the installer itself behaves
   as expected before running the full multi-node DSC deployment against it.

---

## 6. Two DSC configuration scripts, selected by version

There are **two** installer configuration scripts. The kickoff script picks one
automatically from `NonNodeData.SQL.SQLVersion`; you never select it by hand.

| Script | DSC module | Serves |
|---|---|---|
| `Install_and_Configure_SQLServer_Multi_Node.ps1` | `xSQLServer` 9.0.0.0 | **SQL2012–2017** — the original, battle-tested path |
| `Install_and_Configure_SQLServer_Multi_Node_SqlServerDsc.ps1` | `SqlServerDsc` 17.5.1 | **SQL2025+** |

The selection happens in `Start_SQL_Server_Installation_Multiple_Node.ps1`, just
before Step 14 invokes the config script:

```powershell
$configScriptName = if ( $param.Version -eq 'SQL2025' )
                    { 'configs\Install_and_Configure_SQLServer_Multi_Node_SqlServerDsc.ps1' }
                    else
                    { 'configs\Install_and_Configure_SQLServer_Multi_Node.ps1' }
```

The console prints which one it chose, so it is visible in every run's transcript.

### Why two scripts instead of one with conditionals

`xSQLServer` 9.0.0.0 cannot configure SQL2025's network protocol — the defect is
inside the module, not in our configuration (see section 11), so it cannot be worked
around with an `if` statement. SQL2025 needs a different DSC module, and swapping
the module inside a file that SQL2017 also compiles would put the proven path at
risk.

Separate files give a guarantee that a shared file cannot: **a SQL2012–2017
deployment never opens the newer script, never imports `SqlServerDsc`, and never
loads SMO 17.x.** There is no shared surface to regress. This is the same
additive pattern used to add SQL2025 support in the first place (section 5).

### What the SqlServerDsc version does better

| Concern | Legacy (`xSQLServer`) | New (`SqlServerDsc`) |
|---|---|---|
| TCP/IP + static port | `xSQLServerNetwork` — **broken on SQL2025** | `SqlSetup -TcpEnabled` + `SqlProtocol` + `SqlProtocolTcpIp` |
| Trace flags | hand-written `Script` blocks using the **default-instance** registry path (fails on a named instance) | native `SqlTraceFlag`, using `TraceFlagsToInclude` so flags set outside the toolkit are preserved |
| SQL Browser | disabled early, breaking `Server\Instance` connections mid-run | disabled last, after configuration completes |
| T-SQL scripts | fail against a self-signed cert under modern client defaults | `SqlScript -Encrypt 'Optional'` |
| Telemetry `Script` | `TestScript` returned `$false` unconditionally, so it re-ran every pass | reports true once no telemetry service runs — genuinely idempotent |
| Connection target | `SQLInstanceName = '<instance>,<port>'` composite string | separate `ServerName` / `InstanceName` |
| Final message | "DONE: Please confirm if SQL is properly installed" | points explicitly at `Test_SQLServer_PostInstall.ps1` |

Both scripts read the **same environment `.psd1`** with no changes, run the
**same T-SQL scripts** from `SQLDSC\SQLScripts\`, and use the same LCM settings,
reboot/resume behaviour, and clean `[WARN]`/`[INFO]` error reporting.

### Deployment requirement

`SqlServerDsc` 17.5.1 **and** `SqlServer` 22.4.5.1 must be present on each
SQL2025 target node. Per the caution in section 3, do **not** deploy `SqlServer`
22.4.5.1 to SQL2012–2017 nodes.

---

## 7. Running the main installer (production)

1. Copy the whole `SQLInstall` folder to a local path (typically
   `C:\SQLInstall`) on the machine you'll run the install from (see section 3 — do
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
   background noise) — see section 10 for how to read it.
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

## 8. Post-install verification (`Test_SQLServer_PostInstall.ps1`)

**Run this after every install.** `SQLDSC\configs\Test_SQLServer_PostInstall.ps1`
checks the *actual* state of each node against the desired state the DSC config
and T-SQL scripts are supposed to produce, and prints an `[OK]`/`[WARN]`/`[FAIL]`
report plus a timestamped log under `SQLDSC\..\logs\`.

It exists because **the installer printing "DONE" is not evidence the desired
state was reached** — the `DependsOn`-cascade failure in section 11 can leave SQL running
but almost entirely unconfigured, with no obvious error.

It reads the same environment `.psd1` as the installer, so the "desired" values
(instance, port, version→build, service accounts, trace flags, SSMS flag) come
from your real config rather than hardcoded assumptions.

```powershell
# all nodes listed in the .psd1 (uses WinRM for remote nodes)
.\Test_SQLServer_PostInstall.ps1 -EnvDataFilePath 'C:\SQLInstall\SQLDSC\environments\InstallConfigure_SQLServer2025-CAPPT.psd1'

# just the node you're sitting on
.\Test_SQLServer_PostInstall.ps1 -EnvDataFilePath '...\InstallConfigure_SQLServer2025-CAPPT.psd1' -ComputerName localhost
```

What it verifies:

| Area | Checks |
|---|---|
| Engine | SQL Server + Agent services running; version and patch level |
| Network | TCP/IP protocol enabled, static port set, actually listening |
| Firewall | inbound rule for the SQL port; RDP rule |
| Local groups | `SQLAdmins` / `SQLServices` populated; local install account |
| Services | SQL Browser disabled+stopped (as intended with a fixed port) |
| SSMS | installed, if `InstallStandAloneSSMS = 'YES'` |
| `sp_configure` | Agent XPs, remote admin connections, backup compression, remote access, MaxDop, min/max memory |
| Trace flags | every flag in the config's `TraceFlags` list is active globally |
| T-SQL scripts | tempdb multi-file, model `PAGE_VERIFY`, audit level, error-log retention, agent job history (Configure_SQLServer); `sa`→`dsa` disabled (SecureSA); `DBAs` operator; Database Mail profile+account; server audit+specification ON; maintenance jobs; severity 16–25 alerts; telemetry services disabled |

Notes:
- Requires **local admin** on the node (services/firewall/local groups) and **SQL
  sysadmin** on the instance (`sp_configure`, `xp_instance_regread`, audit/mail metadata).
- SQL connections are made **locally on each node** (`localhost,<port>`, via
  .NET SqlClient with `TrustServerCertificate`) because the SQL port is often not
  reachable across the network in this environment (host firewall / GPO), and
  because ODBC Driver 18 rejects SQL Server's self-signed cert by default.
- Every `[WARN]` names the resource or script that didn't apply, so the output
  doubles as a remediation checklist.

---

## 9. Standalone utility scripts (repo root)

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

## 10. Reading the output / troubleshooting

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

## 11. Known issues and design notes

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
- **Must run from a local path, not a live UNC share.** Covered in section 3 — this
  is the single most common reason the installer silently fails to start.
- **Local (non-domain) accounts cannot be added to a different machine's
  local groups.** `Add-UserToLocalGroup` correctly scopes the local install
  account to its own node; if you add new logic that
  loops over nodes, make sure any *local* account reference stays scoped to
  `-ComputerName` = that same node, not the full node list. Domain
  accounts/groups don't have this restriction.
- **`Restart-Computer -Wait` cannot wait on its own host.** If the kickoff
  machine is also one of the target SQL nodes (common in this toolkit's
  usage), you'll see an informational message about this during Step 14 —
  it's expected, not a failure; the local computer still restarts and the
  script correctly waits on the *other* node(s).
- **"The user has not been granted the requested logon type at this computer"
  means two different things, and the advice differs.** Read which resource
  reported it.
  - **From `MSFT_UserResource`:** harmless to the rest of the run. Whenever a
    `Password` is supplied, that resource's `Test` validates it by attempting a
    logon, which a hardened server's logon-rights policy refuses — *regardless*
    of whether the account exists or is an administrator. It was observed
    failing on runs where Step 7 had verifiably created the account and added it
    to Administrators, while the `PsDscRunAsCredential` T-SQL scripts executed
    successfully in the same run. It was not cost-free, though: the resource
    error made the LCM report `SendConfigurationApply did not succeed` and fail
    the whole configuration. **The `User` resource has therefore been removed
    from the SqlServerDsc config** — if you see this from that resource,
    something re-added it. To declare the account in DSC without this problem,
    use `Ensure = 'Present'` and omit `Password`.
  - **From any other resource:** genuinely fatal for anything running as that
    account. `PsDscRunAsCredential` needs the account to hold the *log on as a
    batch job* right, which it inherits from local Administrators and which
    Windows evaluates at logon. Step 7 creates the account and adds it to
    Administrators before any MOF is pushed; check Step 7 reported `[OK]` for
    that node first, then that no GPO has stripped Administrators from "Log on
    as a batch job" (`secedit /export /cfg out.cfg /areas USER_RIGHTS`, then
    look for `SeBatchLogonRight`).
- **`Agent XPs` is not a stable setting, and two T-SQL scripts depend on it.**
  SQL turns it on when the SQL Server Agent service starts and off when it
  stops, so setting the `sp_configure` option does not keep it on across a
  service restart — and both the `remote access` option and `SqlTraceFlag`
  restart the engine. `Configure_SQLServer_Set.sql` and
  `DatabaseMailAccountandProfile_Set.SQL` both call
  `msdb.dbo.sp_set_sqlagent_properties`, which fails with `Msg 15281` while the
  option reads 0. Both scripts now enable it for themselves; in the mail script
  that enablement has to sit in its own batch at the top of the file, because
  the call is inside a user transaction where `RECONFIGURE` is not permitted.
  **This only reproduces on a fresh install** — an existing node's trace flags
  already match, so the resource skips and no restart occurs.
- **Leftover DSC jobs from an interrupted prior run** can cause
  `Cannot invoke the Set-DscLocalConfigurationManager cmdlet...` errors on
  the next attempt. This usually self-resolves (`-Force` cancels the stale
  job automatically), but if you deliberately killed a run mid-flight, you
  may need `Stop-DscConfiguration -Force -CimSession <node>` before retrying.
- **One unresolvable AD principal fails the *whole* `Group` resource, not just
  that member.** A group name typo, a stale/deleted group, or a wrong domain
  prefix anywhere in `LocalServerAdmins` means the local `SQLAdmins` group is
  **not created at all** — DSC does not add the members it *could* resolve and
  skip the rest. The install still completes and still reports success, so this
  only surfaces as a `[WARN]` in the post-install check
  (`SQLAdmins populated — Group does not exist`). Verify every name with
  `Get-ADGroup` / `Get-ADUser` before running, and always check the STEP SUMMARY
  and any `[WARN]` lines against your actual AD structure after a run, not just
  whether it reached "DONE."
- **A failed `xSQLServerSetup` silently skips most of the configuration.** This is
  the single highest-impact failure mode in this toolkit, and it looks like a
  successful install. `xSQLServerSetup 'SetupSQL'` is the root of a long
  `DependsOn` chain: the TCP port (`xSQLServerNetwork`), the SQL port firewall
  rule, SSMS (`Package InstallSSMS`), all four `xSQLServerConfiguration`
  options, `xSQLServerMaxDop`, `xSQLServerMemory`, and **every** `xSQLServerScript`
  T-SQL run hang off it (some directly, some via the firewall rule). DSC skips
  any resource whose dependency failed — so if `SetupSQL` reports failure, SQL
  Server itself still installs fine (`setup.exe` says `Passed`), but almost none
  of the configuration gets applied, and the run still ends with
  "DONE: Please confirm if SQL is properly installed."
  The tell is this DSC error: `Test-TargetResource returned false after calling
  Set-TargetResource`. It means the install ran but the resource can't *detect*
  the desired state afterwards. The known cause is a **feature-list mismatch**:
  if `$sqlVersionInfo`'s feature list for your version names a feature that
  version's `setup.exe` doesn't actually install, the check never passes.
  This is exactly what happened with SQL2025 and `CONN,BC` (see section 5).
  **Diagnosis**: compare the `FEATURES:` line and `Product features discovered:`
  in the target node's `Summary.txt` against the feature list in
  `$sqlVersionInfo` — anything requested but not discovered will break the check.
  **Verification**: run `Test_SQLServer_PostInstall.ps1` (section 8) after every install;
  the cascade's signature is that everything with no `DependsOn` passes while
  everything downstream of `SetupSQL` is missing.
- **`xSQLServer` 9.0.0.0 cannot configure the SQL Server network protocol on
  SQL2025 — this one is not fixable in the config.** The module loads SMO/WMI
  assemblies with a version pinned to the SQL major version
  (`Microsoft.SqlServer.SqlWmiManagement, Version=<major>.0.0.0`), and
  `MSFT_xSQLServerNetwork` — the `ConfigureSQLPort` resource that enables TCP/IP
  and sets the static port — depends on it. SQL2017 asks for `14.0.0.0` and the
  vendored `SqlServer` 21.0.17224 provides it; SQL2025 asks for `17.0.0.0`, which
  that module doesn't contain. **Consequence: on SQL2025 you must either enable
  TCP/IP and set the port manually (SQL Server Configuration Manager → Protocols
  → TCP/IP → Enable, set `IPAll` `TCP Port`, clear `TCP Dynamic Ports`, then
  restart the instance), or migrate that resource to `SqlServerDsc` (see section 3).**
  This is separate from — and additional to — the `DependsOn` cascade below.
- **Disabling SQL Browser breaks `Server\Instance` connections that DSC resources
  rely on — so it must run last.** With a non-default port (`SQLEnginePort`),
  named-instance resolution (`<node>\<instance>`) depends entirely on the SQL
  Browser service listening on UDP 1434. Several `xSQLServer` resources —
  including `xSQLServerSetup`'s own `Test-TargetResource` — connect using that
  form, so if Browser is already stopped they fail with
  `Failed to connect to SQL instance <node>\<instance>`, which triggers the
  `DependsOn`-cascade above. Originally `Service 'Disable SQL Browser'` had its
  `DependsOn` commented out, so DSC ran it early — sometimes before SQL was even
  installed (hence the misleading `The service 'SQLBrowser' does not exist`
  error). It now depends on `[xSQLServerConfiguration]DisableRemoteAccess` so
  Browser stays available for the whole run and is disabled only at the end.
  Verify the end state with `Test_SQLServer_PostInstall.ps1` (section 8), which reports
  Browser as `[WARN]` if it was left running.
  Quick way to confirm this behaviour by hand on a node:
  `sqlcmd -S <node>\<instance> -C` fails while `sqlcmd -S localhost,<port> -C`
  succeeds — that difference *is* the missing Browser service.
- **`UpdateSource` is passed to `setup.exe` unconditionally, even in
  "already copied locally" mode.** The DSC `File 'CopySQLPatchesLocally'`
  resource (which copies patches from `UpdateSource` to `UpdateDestination`)
  is correctly gated behind `Copy_all_Files_to_TargetNodes -eq 'YES'`, but the
  `UpdateSource` value passed to `xSQLServerSetup` itself
  (`Install_and_Configure_SQLServer_Multi_Node.ps1` line ~323) is **not** —
  native `setup.exe` validates that path directly regardless of the switch.
  If `Copy_all_Files_to_TargetNodes = 'NO'` and `UpdateSource` is a UNC path
  to a share that doesn't actually exist (e.g. no live `SQLInstall` file
  share was ever set up because the toolkit was staged via manual local
  copies instead), setup fails with `InvalidUpdateSourcePath` even though the
  patches folder is already sitting locally on the target node. **Fix**: when
  running in "already copied locally" mode, set `UpdateSource` to the *same
  local path* as `UpdateDestination` in the environment config (not a UNC
  path), or set `UpdateEnabled = $false` if patch slipstreaming isn't needed.
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

## 12. Version and compatibility

### Supported SQL Server versions

| Version | Config script | DSC module | Status |
|---|---|---|---|
| SQL2025 | `..._SqlServerDsc.ps1` | `SqlServerDsc` 17.5.1 | Verified end-to-end (installed, patched to CU6, configured) |
| SQL2017 | `Install_and_Configure_SQLServer_Multi_Node.ps1` | `xSQLServer` 9.0.0.0 | Verified end-to-end |
| SQL2016 | same as SQL2017 | `xSQLServer` 9.0.0.0 | Accepted by `ValidateSet`; not exercised recently |
| SQL2014 / SQL2012 | same as SQL2017 | `xSQLServer` 9.0.0.0 | Accepted by `ValidateSet`; not exercised recently |

A version is only usable if its media is staged under `SQLDSC\bits\<Version>\` —
see section 5.

### Platform

- **Windows PowerShell 5.1** on both the admin machine and the target nodes. Not
  validated on PowerShell 7+.
- Target nodes tested on **Windows Server 2022** (10.0.20348).

### Module version pinning

DSC module versions are pinned in the config scripts
(`Import-DscResource -ModuleVersion ...`) and must match the folder names under
`SQLDSC\modules\` exactly, or compilation fails with
`Could not find the module '<name>'`. If you update a module, update every
`Import-DscResource` line that references it — `Install_and_Configure_SQLServer_Multi_Node.ps1`,
`..._SqlServerDsc.ps1`, `ConfigureAG.ps1` and `Create_Listener.ps1`.

The `SqlServer` PowerShell module is the exception: it is **not** version-pinned by
the configs, so the highest installed version wins. See the caution in section 3
before deploying `SqlServer` 22.4.5.1 to SQL2012–2017 nodes.

---

