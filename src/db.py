import os
import re
import urllib.parse
from sqlalchemy import create_engine

try:
    from dotenv import load_dotenv
    load_dotenv()
except ImportError:
    pass


def get_database_name(default: str = "homerescue_dw") -> str:
    """Return the configured target SQL Server database name."""
    return os.environ.get("SQLSERVER_DB", default).strip() or default


def get_connection_string(database: str | None = None) -> str:
    """Build the ODBC connection string from environment variables without hardcoded secrets."""
    target_db = database or get_database_name()
    server = os.environ.get("SQLSERVER_SERVER", "localhost").strip() or "localhost"
    conn = os.environ.get("SQLSERVER_CONN")
    if conn:
        if database or "SQLSERVER_DB" in os.environ:
            conn = re.sub(r"(?i)(DATABASE=)[^;]+", rf"\g<1>{target_db}", conn)
        return conn
    return (
        "DRIVER={ODBC Driver 18 for SQL Server};"
        f"SERVER={server};DATABASE={target_db};"
        "Trusted_Connection=yes;TrustServerCertificate=yes;"
    )


def get_engine(database: str | None = None):
    """Create a SQLAlchemy engine for the configured SQL Server database."""
    conn = get_connection_string(database=database)
    url = "mssql+pyodbc:///?odbc_connect=" + urllib.parse.quote_plus(conn)
    return create_engine(url, fast_executemany=True)
