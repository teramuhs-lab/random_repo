USE [MSDB]
Go

IF EXISTS
(Select top 1 logical_name 
From dbo.backupfile 
where logical_name = N'$(logicalname)'
)
Print Null
ELSE
PRINT 1/0
GO
