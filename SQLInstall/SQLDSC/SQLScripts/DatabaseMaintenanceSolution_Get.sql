-- Reporting query for [SqlScript]RunSQLScript-DatabaseMaintenanceSolution.
--
-- The SqlScript resource runs this file in Get-TargetResource and surfaces whatever
-- it returns as the GetResult property of Get-DscConfiguration. It must therefore be
-- READ-ONLY: this file used to be a byte-for-byte copy of _Set.sql, which meant a
-- Get-DscConfiguration re-executed the entire 538 KB installer -- idempotent, but slow
-- and it re-synced job step commands over any local edits.
--
-- Reports the same things Test_SQLServer_PostInstall.ps1 checks, so the two agree.

USE [master]

SET NOCOUNT ON

--Check the four maintenance solution procedures exist
SELECT [name] AS MaintenanceProcedure
FROM   sys.procedures
WHERE  [name] IN ('CommandExecute', 'DatabaseBackup', 'DatabaseIntegrityCheck', 'IndexOptimize')
ORDER BY [name]

--Check the logging table exists (installed with @LogToTable = 'Y')
SELECT COUNT(*) AS CommandLogTable
FROM   sys.tables
WHERE  [name] = 'CommandLog'

--Check the installed version, taken from the header comment of CommandExecute
SELECT SUBSTRING([definition], CHARINDEX('Version: ', [definition]) + 9, 19) AS SolutionVersion
FROM   sys.sql_modules
WHERE  [object_id] = OBJECT_ID('[dbo].[CommandExecute]')
       AND CHARINDEX('Version: ', [definition]) > 0

--Check the Agent jobs, matching the name patterns Test_SQLServer_PostInstall.ps1 uses
SELECT COUNT(*)                                                  AS MaintenanceJobs,
       ISNULL(SUM(CASE WHEN [enabled] = 1 THEN 1 ELSE 0 END), 0) AS EnabledJobs
FROM   msdb.dbo.sysjobs
WHERE  [name] LIKE 'DatabaseBackup%'
       OR [name] LIKE 'DatabaseIntegrityCheck%'
       OR [name] LIKE 'IndexOptimize%'
       OR [name] LIKE 'CommandLog Cleanup%'
       OR [name] LIKE 'Output File Cleanup%'

--Check the backup root and retention the jobs actually run with. Both are read out of the
--job step command rather than out of _Set.sql, so they report what is deployed on this
--instance, not what the script in this folder would apply.
--
--Ola's job builder always emits both parameters, substituting the literal text 'NULL'
--when the variable was not set -- an unset value therefore appears as the string NULL
--rather than as a missing parameter. @Directory is replaced by @URL when backing up to URL.
SELECT TOP 1
       CASE WHEN d.Value IS NULL  THEN '(backup to URL - see @URL in the job step)'
            WHEN d.Value = 'NULL' THEN '(instance default backup directory)'
            ELSE d.Value END AS BackupDirectory,
       CASE WHEN c.Value IS NULL  THEN '(not specified in the job step)'
            WHEN c.Value = 'NULL' THEN '(none - backup files are never deleted)'
            ELSE c.Value END AS CleanupTimeHours
FROM   msdb.dbo.sysjobs AS j
       INNER JOIN msdb.dbo.sysjobsteps AS js ON js.job_id = j.job_id
       CROSS APPLY (SELECT CHARINDEX('@Directory = ',   js.[command]) AS P) AS dp
       CROSS APPLY (SELECT CHARINDEX('@CleanupTime = ', js.[command]) AS P) AS cp
       CROSS APPLY (SELECT CASE WHEN dp.P > 0
                                THEN SUBSTRING(js.[command], dp.P + 13,
                                               CHARINDEX(',', js.[command] + ',', dp.P) - dp.P - 13)
                           END AS Value) AS d
       CROSS APPLY (SELECT CASE WHEN cp.P > 0
                                THEN SUBSTRING(js.[command], cp.P + 15,
                                               CHARINDEX(',', js.[command] + ',', cp.P) - cp.P - 15)
                           END AS Value) AS c
WHERE  j.[name] LIKE 'DatabaseBackup%'
ORDER BY j.[name]

--Check when the maintenance last actually ran. Guarded because this file is also read
--on an instance where the Set script has never run: an unguarded reference to a
--non-existent table would throw and fail Get-TargetResource outright.
IF OBJECT_ID('[dbo].[CommandLog]') IS NOT NULL
BEGIN
  SELECT MAX([StartTime]) AS LastCommandLogEntry
  FROM   [dbo].[CommandLog]
END
