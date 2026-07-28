# `SQLDSC\modules\` — PowerShell DSC modules

This folder holds the PowerShell modules the DSC configurations depend on.

> ## ⚠️ Do not rename or reorganise these folders
>
> The layout is **`<ModuleName>\<ModuleVersion>\`** — for example
> `xSQLServer\9.0.0.0\`. This is not a naming convention we chose; it is how
> PowerShell itself discovers modules. Renaming a folder, flattening the version
> subfolder, or adding a folder level makes the module invisible to PowerShell and
> DSC compilation will fail with `Could not find the module '<name>'`.
>
> The folder name must exactly match the module name, and the subfolder name must
> exactly match the version in that module's `.psd1` manifest.

---

## What's in here

| Folder | Version | Needed for | Status |
|---|---|---|---|
| `xSQLServer\` | 9.0.0.0 | **SQL 2012–2017** | In use — pinned by all DSC configs today |
| `xNetworking\` | 5.3.0.0 | **all versions** | In use — provides `xFirewall` |
| `SqlServer\` | 21.0.17224 | **SQL 2017** | In use — ships SMO 14.0.x (matches SQL2017's major version 14) |
| `SqlServer\` | 22.4.5.1 | **SQL 2025** | In use by the SQL2025 path — ships SMO 17.100.x (matches SQL2025's major version 17). See caution below. |
| `SqlServerDsc\` | 17.5.1 | **SQL 2025** | In use — imported by `Install_and_Configure_SQLServer_Multi_Node_SqlServerDsc.ps1` |
| `xFailOverCluster\` | 1.8.0.0 | (AG phase) | Vendored but **not imported by any config** in this repo |

`PSDesiredStateConfiguration` is also required, but it is built into Windows and
is not vendored here.

Two `.zip` + `.checksum` pairs (`xSQLServer_9.0.0.0.zip`,
`xNetworking_5.3.0.0.zip`) are the original downloaded packages, kept as a restore
source for the two modules that are not available from the gallery at these exact
legacy versions.

---

## Why there are two `SqlServer` versions

`xSQLServer` 9.0.0.0 loads SMO assemblies with the version **pinned to the SQL
Server major version** it is installing:

```
Microsoft.SqlServer.SqlWmiManagement, Version=<SQLmajor>.0.0.0
```

* SQL2017 → needs `14.0.0.0` → provided by `SqlServer` **21.0.17224**
* SQL2025 → needs `17.0.0.0` → provided by `SqlServer` **22.4.5.1**

Both are kept side by side so each SQL version has the assemblies it needs.

> ### ⚠️ Caution: do not blindly deploy `SqlServer` 22.4.5.1 to SQL2017 nodes
>
> The DSC module versions are pinned in the configs
> (`Import-DscResource -ModuleVersion '9.0.0.0'`), but the **`SqlServer` module
> version is not** — `xSQLServer`'s `Import-SQLPSModule` helper simply imports
> "SqlServer", which resolves to the **highest installed version**. Putting
> 22.4.5.1 on a SQL2017 node can therefore change which SMO loads and break a
> currently-working install path.
>
> Deploy `SqlServer\22.4.5.1\` **only to nodes running SQL2025**, or re-test a
> SQL2017 install explicitly before rolling it out more widely.

---

## Where these get deployed

Nothing loads modules from *this* folder. They must end up in the PowerShell
module path on each machine:

```
C:\Program Files\WindowsPowerShell\Modules\
```

| Machine | How they get there |
|---|---|
| Admin / kickoff machine | Step 13 of `Start_SQL_Server_Installation_Multiple_Node.ps1` ("Copying DSC resources") |
| Target SQL nodes | The `File 'CopyPowerShellDSCModulesLocally'` DSC resource — **only when `Copy_all_Files_to_TargetNodes = 'YES'`** in the environment `.psd1`. With `'NO'`, you must copy them yourself. |

Verify what is actually deployed on a node:

```powershell
Get-Module -ListAvailable -Name xSQLServer, xNetworking, SqlServer, SqlServerDsc, xFailOverCluster |
    Select-Object Name, Version, Path
```

---

## Restoring this folder after a fresh clone

**This folder is in `.gitignore`** (only this README is tracked) because the
modules are vendored binaries, not source — roughly 287 MB in total. A fresh clone
will therefore be missing them, and DSC compilation will fail until they are
staged.

From the gallery (run on a machine with internet access, then copy the resulting
folders to air-gapped servers — `Save-Module` writes a plain `<Name>\<Version>\`
tree specifically so it can be copied):

```powershell
Save-Module -Name SqlServerDsc -RequiredVersion 17.5.1   -Path 'C:\SQLInstall\SQLDSC\modules'
Save-Module -Name SqlServer    -RequiredVersion 22.4.5.1 -Path 'C:\SQLInstall\SQLDSC\modules'
Save-Module -Name SqlServer    -RequiredVersion 21.0.17224 -Path 'C:\SQLInstall\SQLDSC\modules'
Save-Module -Name xNetworking  -RequiredVersion 5.3.0.0  -Path 'C:\SQLInstall\SQLDSC\modules'
Save-Module -Name xSQLServer   -RequiredVersion 9.0.0.0  -Path 'C:\SQLInstall\SQLDSC\modules'
```

If a module is unavailable from the gallery or `Save-Module` is blocked by a
proxy, unzip the `.zip` files in this folder, or download the `.nupkg` manually:

* `https://www.powershellgallery.com/packages/SqlServerDsc/17.5.1`
* `https://www.powershellgallery.com/packages/SqlServer/22.4.5.1`

---

See the main [README](../../README.md) — section 3 for full module/SQL-version
compatibility details, and section 9 for the known `xSQLServer` 9.0.0.0
limitations on SQL2025.
