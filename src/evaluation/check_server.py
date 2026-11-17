"""Early connection test with practical SQL Server/ODBC diagnostic messages."""
from sqlalchemy import text
from src.db import get_engine

def main():
    try:
        engine=get_engine('master')
        with engine.connect() as c:
            print('Connected to',c.execute(text('SELECT @@SERVERNAME')).scalar())
            exists=c.execute(text("SELECT DB_ID(N'homerescue_dw')")).scalar()
            print('Existing homerescue_dw:', 'YES' if exists else 'NO (pipeline will create it)')
        engine.dispose()
    except Exception as e:
        print('Local SQL Server connection failed:',e)
        print('In SSMS verify that localhost works with Windows Authentication; pyodbc needs ODBC Driver 18 for SQL Server.')
        raise

if __name__=='__main__':main()
