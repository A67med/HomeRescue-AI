from __future__ import annotations

import argparse
import json
import os
import subprocess
import time
from datetime import datetime, timezone
from pathlib import Path
from sqlalchemy import create_engine, text
from src.ingest.load_csv import load_all_datasets
from src.quality.run_checks import run_all_checks


SQLCMD_PATH = r"C:\Program Files\Microsoft SQL Server\Client SDK\ODBC\180\Tools\Binn\sqlcmd.exe"


def _get_engine_for_db(db_name: str, autocommit: bool = False):
    server = os.getenv("SQLSERVER_HOST", "localhost")
    driver = os.getenv("SQLSERVER_DRIVER", "ODBC Driver 18 for SQL Server").replace(" ", "+")
    url = (
        f"mssql+pyodbc://@{server}/{db_name}"
        f"?driver={driver}&trusted_connection=yes&TrustServerCertificate=yes"
    )
    return create_engine(url, isolation_level="AUTOCOMMIT" if autocommit else None)


def _run_sqlcmd_script(db_name: str, script_path: str) -> None:
    server = os.getenv("SQLSERVER_HOST", "localhost")
    cmd = [
        SQLCMD_PATH,
        "-S",
        server,
        "-d",
        db_name,
        "-E",
        "-C",
        "-b",
        "-i",
        str(Path(script_path)),
    ]
    res = subprocess.run(cmd, capture_output=True, text=True, check=False)
    if res.returncode != 0:
        raise RuntimeError(f"sqlcmd failed on {script_path} (db={db_name}):\n{res.stdout}\n{res.stderr}")


def _run_sqlcmd_query(db_name: str, query: str) -> None:
    server = os.getenv("SQLSERVER_HOST", "localhost")
    cmd = [
        SQLCMD_PATH,
        "-S",
        server,
        "-d",
        db_name,
        "-E",
        "-C",
        "-b",
        "-Q",
        query,
    ]
    res = subprocess.run(cmd, capture_output=True, text=True, check=False)
    if res.returncode != 0:
        raise RuntimeError(f"sqlcmd failed on query '{query}' (db={db_name}):\n{res.stdout}\n{res.stderr}")


def run_pipeline(
    target_db: str,
    raw_dir: str = "data/raw",
    create_new_db: bool = False,
) -> dict:
    t0 = time.time()
    os.environ["SQLSERVER_DB"] = target_db

    master_eng = _get_engine_for_db("master", autocommit=True)
    with master_eng.connect() as con:
        exists = con.execute(
            text("SELECT 1 FROM sys.databases WHERE name = :n"), {"n": target_db}
        ).scalar()
        if create_new_db:
            if exists:
                raise RuntimeError(
                    f"Database '{target_db}' already exists! Refusing to overwrite existing database when --create-new-db is set."
                )
            print(f"[Pipeline] Creating new database [{target_db}]...")
            con.execute(text(f"CREATE DATABASE [{target_db}]"))
        elif not exists:
            print(f"[Pipeline] Database [{target_db}] does not exist; creating it...")
            con.execute(text(f"CREATE DATABASE [{target_db}]"))
    master_eng.dispose()

    print(f"[Pipeline] Step 1/7: Initializing schemas and Bronze objects on [{target_db}]...")
    _run_sqlcmd_script(target_db, "sql/00_init.sql")
    _run_sqlcmd_script(target_db, "sql/01_bronze.sql")

    print(f"[Pipeline] Step 2/7: Loading saved raw CSV files from '{raw_dir}' into [{target_db}].bronze.*...")
    bronze_recon = load_all_datasets(raw_dir=Path(raw_dir), target_db=target_db)

    print(f"[Pipeline] Step 3/7: Executing Silver DDL and silver.load_all on [{target_db}]...")
    _run_sqlcmd_script(target_db, "sql/02_silver.sql")
    _run_sqlcmd_query(target_db, "EXEC silver.load_all;")

    print(f"[Pipeline] Step 4/7: Executing Gold DDL and gold.load_all on [{target_db}]...")
    _run_sqlcmd_script(target_db, "sql/03_gold.sql")
    _run_sqlcmd_query(target_db, "EXEC gold.load_all;")

    print(f"[Pipeline] Step 5/7: Creating Gold feature views and Semantic views on [{target_db}]...")
    _run_sqlcmd_script(target_db, "sql/05_feature_views.sql")
    _run_sqlcmd_script(target_db, "sql/04_semantic.sql")

    print(f"[Pipeline] Step 6/7: Synchronizing semantic/metrics.yml and executing sql/06_analytics.sql on [{target_db}]...")
    import yaml

    metrics = yaml.safe_load(Path("semantic/metrics.yml").read_text(encoding="utf-8"))["metrics"]
    db_eng = _get_engine_for_db(target_db)
    with db_eng.begin() as con:
        con.execute(text("DELETE FROM semantic.metric_catalog"))
        for m in metrics:
            con.execute(
                text(
                    "INSERT semantic.metric_catalog (metric_name, label, definition, owner, grain, sql_expression, "
                    "dimensions, null_policy, validation_query) VALUES (:n, :l, :d, :o, :g, :s, :dim, :np, :v)"
                ),
                {
                    "n": m["name"],
                    "l": m["label"],
                    "d": m["definition"],
                    "o": m["owner"],
                    "g": m["grain"],
                    "s": m["sql"],
                    "dim": ", ".join(m["dimensions"]),
                    "np": m["null_policy"],
                    "v": m["validation_query"],
                },
            )
    db_eng.dispose()
    _run_sqlcmd_script(target_db, "sql/06_analytics.sql")

    print(f"[Pipeline] Step 7/7: Running quality checks and semantic metric reconciliations on [{target_db}]...")
    checks_summary = run_all_checks(target_db=target_db)
    if checks_summary["failed_count"] > 0:
        raise RuntimeError(f"Quality checks failed on [{target_db}]: {checks_summary['failed_count']} failures")

    elapsed = round(time.time() - t0, 2)
    result = {
        "executed_at_utc": datetime.now(timezone.utc).isoformat(),
        "target_db": target_db,
        "raw_dir": raw_dir,
        "elapsed_seconds": elapsed,
        "bronze_reconciliation": bronze_recon,
        "quality_checks_summary": {
            "total_sql_checks": checks_summary["total_sql_checks"],
            "total_metric_reconciliations": checks_summary["total_metric_reconciliations"],
            "failed_count": checks_summary["failed_count"],
            "overall_status": checks_summary["overall_status"],
        },
    }
    print(f"[Pipeline] Completed successfully on [{target_db}] in {elapsed}s (0 failed checks).")
    return result


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Run end-to-end HomeRescue AI warehouse build from saved raw inputs.")
    parser.add_argument("--target-db", default=os.getenv("SQLSERVER_DB", "homerescue_dw"), help="Target SQL Server database name")
    parser.add_argument("--raw-dir", default="data/raw", help="Directory containing saved raw CSV extracts")
    parser.add_argument("--create-new-db", action="store_true", help="Require that target-db does not yet exist and create it")
    args = parser.parse_args()
    run_pipeline(target_db=args.target_db, raw_dir=args.raw_dir, create_new_db=args.create_new_db)
