"""Optional backup of the successful live warehouse to native SQL Server .bak.
Backs up to the SQL Server instance default Backup directory then copies to project folder.
It never restores or deletes existing databases.
"""
from pathlib import Path
from sqlalchemy import text
from src.db import get_engine
import shutil

def backup():
    master=get_engine('master')
    with master.connect() as con:
        base=con.execute(text("SELECT CAST(SERVERPROPERTY('InstanceDefaultBackupPath') AS NVARCHAR(4000))")).scalar()
    master.dispose()
    if not base:
        print('Backup path not available. Use SSMS > Tasks > Back Up manually.')
        return
    path=str(Path(base)/'homerescue_dw_evaluation.bak')
    safe=path.replace("'","''")
    engine=get_engine('master')
    # backup database must not run inside an explicit user transaction
    with engine.connect().execution_options(isolation_level='AUTOCOMMIT') as con:
        con.exec_driver_sql(f"BACKUP DATABASE [homerescue_dw] TO DISK = N'{safe}' WITH INIT, COMPRESSION, CHECKSUM;")
    engine.dispose()
    print('SQL Server backup created:',path)
    target=Path('07_Database_Backup');target.mkdir(exist_ok=True)
    try:
        shutil.copy2(path,target/'homerescue_dw_evaluation.bak')
        print('Backup copied to 07_Database_Backup/ successfully.')
    except (PermissionError,OSError) as e:
        print('The backup exists on SQL Server but Windows blocked copying it into this folder:',e)
        (target/'BACKUP_LOCATION.txt').write_text(path+'\nOpen SSMS > Database > Tasks > Back Up to save a copy in a folder you control.\n',encoding='utf-8')

if __name__=='__main__':backup()
