
-------------------------------------------------------------
--  Database Mail Simple Configuration Template.
--
--  This template creates a Database Mail profile, an SMTP account and 
--  associates the account to the profile.
--  The template does not grant access to the new profile for
--  any database principals.  Use msdb.dbo.sysmail_add_principalprofile
--  to grant access to the new profile for users who are not
--  members of sysadmin.
-------------------------------------------------------------

DECLARE @instance_name SYSNAME = ( SELECT  REPLACE(@@SERVERNAME,'\','-' )),--MachineName + InstanceName
--DECLARE @instance_name SYSNAME = ( SELECT SUBSTRING(@@SERVERNAME,CHARINDEX('\',@@SERVERNAME)+1,LEN(@@SERVERNAME))), --Just InstanceName
		@profile_name sysname,
        @account_name sysname,
        @SMTP_servername sysname,
        @email_address NVARCHAR(128),
           @display_name NVARCHAR(128);

-- Profile name. Replace with the name for your profile
        SET @profile_name = 'SQLAlerts(' + @Instance_name + ')';
		
-- Account information. Replace with the information for your account.

             SET @account_name = 'SQLAlerts(' + @Instance_name + ')';
             SET @SMTP_servername = 'carelay.ca.state.sbu';
             SET @email_address = @instance_name + '-SQL@stage.gov';
        SET @display_name = 'SQLAlerts(' + @Instance_name + ')';

-- Start a transaction before adding the account and the profile
BEGIN TRANSACTION ;
	IF NOT EXISTS (SELECT * FROM msdb.dbo.sysmail_account WHERE name = @account_name )
	BEGIN
	DECLARE @rv INT;
	
	-- Add the account
	EXECUTE @rv=msdb.dbo.sysmail_add_account_sp
		@account_name = @account_name,
		@email_address = @email_address,
		@display_name = @display_name,
		@mailserver_name = @SMTP_servername;

	IF @rv<>0
		BEGIN
			RAISERROR('Failed to create the specified Database Mail account [%]).', 16, 1, @account_name) ;
			GOTO done;
		END
	
	END;

	-- Verify the specified account and profile do not already exist.
	IF NOT EXISTS (SELECT * FROM msdb.dbo.sysmail_profile WHERE name = @profile_name)
	BEGIN
	  -- Add the profile
		EXECUTE @rv=msdb.dbo.sysmail_add_profile_sp
			@profile_name = @profile_name ;

		IF @rv<>0
		BEGIN
			RAISERROR('Failed to create the specified Database Mail profile [%]).', 16, 1, @profile_name);
			   ROLLBACK TRANSACTION;
			GOTO done;
		END;

	-- Associate the account with the profile.
		EXECUTE @rv=msdb.dbo.sysmail_add_profileaccount_sp
			@profile_name = @profile_name,
			@account_name = @account_name,
			@sequence_number = 1 ;

		IF @rv<>0
		BEGIN
			RAISERROR('Failed to associate the speficied profile with the specified account [%s]).', 16, 1, @account_name) ;
			   ROLLBACK TRANSACTION;
			GOTO done;
		END;
		
		-- Enable Mail Profile for Alert System
		EXEC msdb.dbo.sp_set_sqlagent_properties @email_save_in_sent_folder=1, 
				@databasemail_profile= @profile_name, 
				@use_databasemail=1

	END;	


COMMIT TRANSACTION;

done:

GO



----Turning on Database mail XPs
sp_CONFIGURE 'show advanced', 1
GO
RECONFIGURE
GO
sp_CONFIGURE 'Database Mail XPs', 1
GO
RECONFIGURE
GO 
sp_CONFIGURE 'show advanced', 0
GO
RECONFIGURE
GO
