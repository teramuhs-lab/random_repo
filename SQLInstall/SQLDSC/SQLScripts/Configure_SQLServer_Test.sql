--Check AuditLevel
DECLARE @AuditLevel int
EXEC master.dbo.xp_instance_regread N'HKEY_LOCAL_MACHINE', 
   N'Software\Microsoft\MSSQLServer\MSSQLServer', 
   N'AuditLevel', @AuditLevel OUTPUT
SELECT case when @AuditLevel <> 3 then -1 else Null end as AuditLevelTest


--Check TempDB File Count
Select 
case when a.TempDBCount > 1 then Null else -1 end TempDBCount
From (
SELECT COUNT(*) as TempDBCount  FROM sys.master_files WHERE [database_id] = 2 AND [file_id] <> 2) a



--Check Agent Job History Max Rows
DECLARE @JobHistory_MaxRows int
EXECUTE master.dbo.xp_instance_regread N'HKEY_LOCAL_MACHINE',
                                         N'SOFTWARE\Microsoft\MSSQLServer\SQLServerAgent',
                                         N'JobHistoryMaxRows',
                                         @JobHistory_MaxRows OUTPUT
Select case when @JobHistory_MaxRows = 50000 then null else @JobHistory_MaxRows end  as AgentJobhistory_MaxRows

--Check Agent Job History Max Rows
DECLARE @JobHistory_MaxRowsJobs int
EXECUTE master.dbo.xp_instance_regread N'HKEY_LOCAL_MACHINE',
                                         N'SOFTWARE\Microsoft\MSSQLServer\SQLServerAgent',
                                         N'JobHistoryMaxRowsPerJob',
                                         @JobHistory_MaxRowsJobs OUTPUT
Select case when @JobHistory_MaxRowsJobs  = 10000 then null else @JobHistory_MaxRowsJobs end as AgentJobhistory_MaxRowsJobs
                              



Declare @NumErrorLogs int
EXECUTE master.dbo.xp_instance_regread N'HKEY_LOCAL_MACHINE',
                                         N'Software\Microsoft\MSSQLServer\MSSQLServer',
                                         N'NumErrorLogs',
                                         @NumErrorLogs OUTPUT
Select case when @NumErrorLogs = 99 then Null else @NumErrorLogs end  as NumErrorLogs


Select case when page_verify_option_desc = 'CHECKSUM' then Null else page_verify_option_desc end  as [PAGE_VERIFY] From master.sys.databases where database_id = 3


