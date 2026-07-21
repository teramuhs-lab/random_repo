--Custom Script for backing up AG Test Database
--SQLcmd varidables needed $(AGSharePath), $(logicalname), $(backupname)
USE [master]
GO
BACKUP DATABASE [AGTest] TO  DISK = N'$(AGSharePath)$(logicalname).bak'
WITH NOFORMAT, NOINIT,  NAME = N'$(backupname)', SKIP, NOREWIND, NOUNLOAD,  STATS = 10
GO