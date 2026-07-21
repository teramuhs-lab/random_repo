USE [msdb]
GO


DECLARE @operator_name SYSNAME = 'DBAs'
DECLARE @email_address NVARCHAR(128) = N'CA-EntOps-Engineers@state.gov'
IF NOT EXISTS (SELECT * FROM msdb.dbo.sysoperators  WHERE name = @operator_name)
BEGIN
	EXEC msdb.dbo.sp_add_operator @name=@operator_name, 
		@enabled=1, 
		--@weekday_pager_start_time=90000, 
		--@weekday_pager_end_time=180000, 
		--@saturday_pager_start_time=90000, 
		--@saturday_pager_end_time=180000, 
		--@sunday_pager_start_time=90000, 
		--@sunday_pager_end_time=180000, 
		--@pager_days=0, 
		@email_address=@email_address
		--, 
		--@category_name=N'[Uncategorized]'


END;

USE [msdb]
GO