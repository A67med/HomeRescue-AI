The existing SQL Server database on your computer is homerescue_dw.
Bronze, Silver and Gold are SCHEMAS inside this SINGLE database, not three standalone databases.
After a successful local run, the start script tries to create a native compressed SQL Server backup file:
  07_Database_Backup/homerescue_dw_evaluation.bak
If Windows permissions do not permit copying, BACKUP_LOCATION.txt will provide the SQL Server backup location.
The original ZIP did not include any database backup. A .bak is not present before the live SQL run.
