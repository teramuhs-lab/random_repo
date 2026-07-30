/* Audit Level (Successful and Failed) */
USE [master]
GO
EXEC xp_instance_regwrite N'HKEY_LOCAL_MACHINE', N'Software\Microsoft\MSSQLServer\MSSQLServer', N'AuditLevel', REG_DWORD, 3
GO



/* TempDB Files setup */
IF ((SELECT COUNT(*) FROM sys.master_files WHERE [database_id] = 2 AND [file_id] <> 2) = 1)
BEGIN
	DECLARE	@path NVARCHAR(500)
			,@sql  NVARCHAR(MAX)
			,@sizeMB INT
			,@i TINYINT = 2;

	-- Set the new size of data files to a variable
	SET @sizeMB = 9;

	-- Get the path of the existing data file
	-- NOTE: You may wish to modify this path for performance
	SELECT @path = LEFT(FILENAME, (LEN(FILENAME)-10)) FROM sysdatabases WHERE name = 'tempdb';

	-- Modify the size of the primary tempdb data file to the new size
	SET @sql = 'ALTER DATABASE [tempdb] MODIFY FILE (NAME = tempdev, SIZE = ' + CAST(@sizeMB AS VARCHAR) + 'MB)';
	EXEC SP_EXECUTESQL @sql

	-- Build the other 7 files
	WHILE @i < 9
	BEGIN
		SET @sql = 'ALTER DATABASE [tempdb] ADD FILE ( NAME = N''tempdev' + CAST(@i AS VARCHAR) + ''', FILENAME = ''' + @path + '\tempdev' + CAST(@i AS VARCHAR) + '.ndf'' , SIZE = ' + CAST(@sizeMB AS VARCHAR) + 'MB , FILEGROWTH = 10%)'
		EXEC SP_EXECUTESQL @sql
		SET @i = @i + 1;
	END
END

/* Configure SQL Server Agent Job History

   'Agent XPs' must be on for sp_set_sqlagent_properties, and it is NOT a stable setting:
   SQL turns it on when the Agent service starts and off when it stops. Anything that
   restarts the engine -- the trace-flag resource and the 'remote access' option both do,
   on a fresh install -- leaves it reading 0 until Agent finishes coming back up. This
   script then failed with

     Msg 15281 ... SQL Server blocked access to procedure 'dbo.sp_set_sqlagent_properties'
     of component 'Agent XPs' because this component is turned off

   Enabling it here rather than relying on resource ordering makes the script correct no
   matter when it runs. Same pattern this file's sibling already uses for Database Mail XPs.
*/
DECLARE @agentXPs int = ( SELECT CAST([value_in_use] AS int) FROM sys.configurations WHERE [name] = 'Agent XPs' );

IF @agentXPs = 0
BEGIN
  EXEC sp_configure 'show advanced options', 1; RECONFIGURE;
  EXEC sp_configure 'Agent XPs', 1;             RECONFIGURE;
  EXEC sp_configure 'show advanced options', 0; RECONFIGURE;
END
GO

EXEC [msdb].[dbo].[sp_set_sqlagent_properties] @jobhistory_max_rows=50000, @jobhistory_max_rows_per_job=10000;
GO

/* Default Error Log Retention */
EXEC xp_instance_regwrite N'HKEY_LOCAL_MACHINE', N'Software\Microsoft\MSSQLServer\MSSQLServer', N'NumErrorLogs', REG_DWORD, 99
GO


/* PAGE_VERIFY for Model Database */
ALTER DATABASE [MODEL] SET PAGE_VERIFY CHECKSUM WITH NO_WAIT;
GO



/*
/* Set Startup Parameter  */


declare		@Parameters			varchar(30)='-T1118',
			@Argument_Number	int,
			@Argument			varchar(255),
			@Reg_Hive			varchar(255),
			@CMD				varchar(255)

--Add Paramter -T1118
---------------------------------------------------------------------------------------------------------{Parameter Cleanup}
if exists (select * from sys.dm_server_registry where value_name like 'SQLArg%' and value_data=@Parameters)
begin 
			select 
			@Argument=value_name,@Reg_Hive=substring(registry_key,len('HKLM\')+1,len(registry_key))
			from sys.dm_server_registry where value_name like 'SQLArg%' and value_data=@Parameters
			set  @CMD='master..xp_regdeletevalue
					  ''HKEY_LOCAL_MACHINE'',
					  '''+@Reg_Hive+''',
					  '''+@Argument+''''
			exec (@CMD)
end 

---------------------------------------------------------------------------------------------------------{Add Parameter}
--select * from sys.dm_server_registry where value_name like 'SQLArg%'
select @Reg_Hive=substring(registry_key,len('HKLM\')+1,len(registry_key)) ,@Argument_Number=max(convert(int,right(value_name,1)))+1
from sys.dm_server_registry
 where value_name like 'SQLArg%' 
group by substring(registry_key,len('HKLM\')+1,len(registry_key)) 

set @Argument= 'SQLArg'+convert(varchar(1),@Argument_Number)
select @Argument,@Reg_Hive

set  @CMD='master..xp_regwrite
''HKEY_LOCAL_MACHINE'',
'''+@Reg_Hive+''',
'''+@Argument+''',
''REG_SZ'',
'''+@Parameters+''''

exec  (@CMD)

--Add Paramter -T3226
---------------------------------------------------------------------------------------------------------{Parameter Cleanup}
Select @Parameters = '-T3226'
if exists (select * from sys.dm_server_registry where value_name like 'SQLArg%' and value_data=@Parameters)
begin 
			select 
			@Argument=value_name,@Reg_Hive=substring(registry_key,len('HKLM\')+1,len(registry_key))
			from sys.dm_server_registry where value_name like 'SQLArg%' and value_data=@Parameters
			set  @CMD='master..xp_regdeletevalue
					  ''HKEY_LOCAL_MACHINE'',
					  '''+@Reg_Hive+''',
					  '''+@Argument+''''
			exec (@CMD)
end 

---------------------------------------------------------------------------------------------------------{Add Parameter}
--select * from sys.dm_server_registry where value_name like 'SQLArg%'
select @Reg_Hive=substring(registry_key,len('HKLM\')+1,len(registry_key)) ,@Argument_Number=max(convert(int,right(value_name,1)))+1
from sys.dm_server_registry
 where value_name like 'SQLArg%' 
group by substring(registry_key,len('HKLM\')+1,len(registry_key)) 

set @Argument= 'SQLArg'+convert(varchar(1),@Argument_Number)
select @Argument,@Reg_Hive

set  @CMD='master..xp_regwrite
''HKEY_LOCAL_MACHINE'',
'''+@Reg_Hive+''',
'''+@Argument+''',
''REG_SZ'',
'''+@Parameters+''''

exec  (@CMD)


--Add Paramter -T1222
---------------------------------------------------------------------------------------------------------{Parameter Cleanup}
Select @Parameters = '-T1222'
if exists (select * from sys.dm_server_registry where value_name like 'SQLArg%' and value_data=@Parameters)
begin 
			select 
			@Argument=value_name,@Reg_Hive=substring(registry_key,len('HKLM\')+1,len(registry_key))
			from sys.dm_server_registry where value_name like 'SQLArg%' and value_data=@Parameters
			set  @CMD='master..xp_regdeletevalue
					  ''HKEY_LOCAL_MACHINE'',
					  '''+@Reg_Hive+''',
					  '''+@Argument+''''
			exec (@CMD)
end 

---------------------------------------------------------------------------------------------------------{Add Parameter}
--select * from sys.dm_server_registry where value_name like 'SQLArg%'
select @Reg_Hive=substring(registry_key,len('HKLM\')+1,len(registry_key)) ,@Argument_Number=max(convert(int,right(value_name,1)))+1
from sys.dm_server_registry
 where value_name like 'SQLArg%' 
group by substring(registry_key,len('HKLM\')+1,len(registry_key)) 

set @Argument= 'SQLArg'+convert(varchar(1),@Argument_Number)
select @Argument,@Reg_Hive

set  @CMD='master..xp_regwrite
''HKEY_LOCAL_MACHINE'',
'''+@Reg_Hive+''',
'''+@Argument+''',
''REG_SZ'',
'''+@Parameters+''''

exec  (@CMD)

*/