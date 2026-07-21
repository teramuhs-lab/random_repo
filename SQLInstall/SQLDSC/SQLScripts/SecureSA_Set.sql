USE [master]

IF EXISTS (SELECT name 
                FROM [sys].[server_principals]
                WHERE name = N'sa')
	Begin
		ALTER LOGIN sa WITH NAME=dsa;
		ALTER LOGIN [dsa] DISABLE;
	end
ELSE
	BEGIN
		if EXISTS (SELECT name 
						FROM [sys].[server_principals]
						WHERE name = N'dsa')
		BEGIN
			ALTER LOGIN [dsa] DISABLE;
		END
		ELSE	
		BEGIN	
			RAISError ('Missing SA and DAS Login', 10, 1, 'SecureSA: ');	
		END
	END
