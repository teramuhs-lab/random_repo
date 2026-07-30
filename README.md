# DBA scripts and tooling

A collection of SQL Server and Windows administration scripts. Each area is independent —
there is no shared framework and nothing here needs to be installed.

## SQL Server Installation Toolkit

The one substantial, documented project in this repository.

**→ [SQLInstall/README.md](SQLInstall/README.md)**

Installs and configures SQL Server across one or more Windows servers from a single script,
using PowerShell DSC. Supports SQL Server 2012–2017 and 2025. It has been run end to end
against both existing and brand-new servers, and ships a verification script that checks the
result rather than assuming it.

| Document | For |
|---|---|
| [SQLInstall/README.md](SQLInstall/README.md) | Running an installation — start here |
| [SQLInstall/docs/INSTALLATION_FLOW.md](SQLInstall/docs/INSTALLATION_FLOW.md) | Diagrams: the flow, the dependency graph, where failures come from |
| [SQLInstall/docs/ADVANCED_GUIDE.md](SQLInstall/docs/ADVANCED_GUIDE.md) | Engineering reference: module pinning, adding a SQL version, failure modes in detail |

## Everything else

The remaining top-level items are standalone scripts, **not documented and not covered by
the testing above**. Read one before you run it.

| Item | Apparent purpose |
|---|---|
| `TDIS_*.ps1`, `run_*TDIS*.bat` | TDIS batch/application reporting, with a daily email sender |
| `production_report*.ps1`, `run_production_report.bat` | Production reporting |
| `disk_space.ps1`, `disk_space.py` | Free-space reporting across servers |
| `cert_check.ps1` | Certificate expiry checking |
| `failover_sql.ps1` | SQL Server failover |
| `cluster_build/`, `clusters.json` | Windows cluster build scripts and their inventory |
| `sql_alert/` | SQL alerting |
| `AG_Dashoard/` | Availability Group dashboard |

Those descriptions are inferred from filenames only — treat them as a table of contents,
not documentation. If one of them becomes important enough to rely on, it deserves the same
treatment `SQLInstall` has had.
