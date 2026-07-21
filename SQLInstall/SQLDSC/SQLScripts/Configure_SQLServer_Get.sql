--Check AuditLevel
DECLARE @AuditLevel int
EXEC master.dbo.xp_instance_regread N'HKEY_LOCAL_MACHINE', 
   N'Software\Microsoft\MSSQLServer\MSSQLServer', 
   N'AuditLevel', @AuditLevel OUTPUT
SELECT @AuditLevel AuditLevelTest 

--Check TempDB File Count
SELECT COUNT(*) as TempDBCount  FROM sys.master_files WHERE [database_id] = 2 AND [file_id] <> 2



--Check Agent Job History Max Rows
DECLARE @JobHistory_MaxRows int
EXECUTE master.dbo.xp_instance_regread N'HKEY_LOCAL_MACHINE',
                                         N'SOFTWARE\Microsoft\MSSQLServer\SQLServerAgent',
                                         N'JobHistoryMaxRows',
                                         @JobHistory_MaxRows OUTPUT
Select @JobHistory_MaxRows as AgentJobhistory_MaxRows

--Check Agent Job History Max Rows
DECLARE @JobHistory_MaxRowsJobs int
EXECUTE master.dbo.xp_instance_regread N'HKEY_LOCAL_MACHINE',
                                         N'SOFTWARE\Microsoft\MSSQLServer\SQLServerAgent',
                                         N'JobHistoryMaxRowsPerJob',
                                         @JobHistory_MaxRowsJobs OUTPUT
Select @JobHistory_MaxRowsJobs as AgentJobhistory_MaxRowsJobs
                              

--Check How Number of Error Logs
Declare @NumErrorLogs int
EXECUTE master.dbo.xp_instance_regread N'HKEY_LOCAL_MACHINE',
                                         N'Software\Microsoft\MSSQLServer\MSSQLServer',
                                         N'NumErrorLogs',
                                         @NumErrorLogs OUTPUT
Select @NumErrorLogs as NumErrorLogs




Select page_verify_option_desc as [PAGE_VERIFY] From master.sys.databases where database_id = 3
