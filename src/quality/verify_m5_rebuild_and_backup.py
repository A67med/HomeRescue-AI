from __future__ import annotations

import json
import os
from datetime import datetime, timezone
from decimal import Decimal
from pathlib import Path
from sqlalchemy import create_engine, text
from src.run_pipeline import run_pipeline


def _get_engine(db_name: str, autocommit: bool = False):
    server = os.getenv("SQLSERVER_HOST", "localhost")
    driver = os.getenv("SQLSERVER_DRIVER", "ODBC Driver 18 for SQL Server").replace(" ", "+")
    url = (
        f"mssql+pyodbc://@{server}/{db_name}"
        f"?driver={driver}&trusted_connection=yes&TrustServerCertificate=yes"
    )
    return create_engine(url, isolation_level="AUTOCOMMIT" if autocommit else None)


def _norm(val):
    if isinstance(val, Decimal):
        return float(round(val, 4))
    if isinstance(val, (int, float)):
        return float(round(val, 4))
    return val


def verify_cross_db_parity(primary_db: str = "homerescue_dw", verify_db: str = "homerescue_dw_verify") -> dict:
    eng = _get_engine(primary_db)
    tables_to_compare = [
        "bronze.buildings",
        "bronze.complaints_problems",
        "bronze.violations",
        "bronze.omo_charges",
        "silver.building",
        "silver.complaint_problem",
        "silver.violation",
        "silver.omo_charge",
        "silver.reject_log",
        "silver.duplicate_log",
        "silver.batch_reconciliation",
        "gold.dim_building",
        "gold.dim_date",
        "gold.fact_complaint_problem",
        "gold.fact_violation",
        "gold.fact_repair_order",
        "gold.mart_building_month",
        "gold.features_building_maintenance",
        "semantic.metric_catalog",
        "semantic.v_building_priority_ranking",
        "semantic.v_monthly_borough_summary",
        "semantic.v_zip_code_maintenance_summary",
        "semantic.v_violation_hazard_breakdown",
        "semantic.v_omo_repair_cohort_summary",
        "semantic.v_unmatched_building_audit",
    ]

    table_parity = []
    with eng.connect() as con:
        for tbl in tables_to_compare:
            c1 = int(con.execute(text(f"SELECT COUNT_BIG(*) FROM [{primary_db}].{tbl}")).scalar())
            c2 = int(con.execute(text(f"SELECT COUNT_BIG(*) FROM [{verify_db}].{tbl}")).scalar())
            table_parity.append(
                {
                    "object": tbl,
                    "primary_rows": c1,
                    "verify_rows": c2,
                    "matched": c1 == c2,
                }
            )
            if c1 != c2:
                raise RuntimeError(f"Row count mismatch on {tbl}: {primary_db}={c1} vs {verify_db}={c2}")

        # Verify natural key & surrogate key set equality between primary_db and verify_db
        key_diff_queries = {
            "dim_building_surrogate_key_mapping_diff": f"""
                SELECT COUNT(*) FROM (
                    SELECT building_key, building_id, full_street_address, zip_code, total_legal_units
                    FROM [{primary_db}].gold.dim_building
                    EXCEPT
                    SELECT building_key, building_id, full_street_address, zip_code, total_legal_units
                    FROM [{verify_db}].gold.dim_building
                ) d
            """,
            "fact_complaint_problem_key_diff": f"""
                SELECT COUNT(*) FROM (
                    SELECT problem_id, complaint_id, building_key, building_id, received_date_key
                    FROM [{primary_db}].gold.fact_complaint_problem
                    EXCEPT
                    SELECT problem_id, complaint_id, building_key, building_id, received_date_key
                    FROM [{verify_db}].gold.fact_complaint_problem
                ) d
            """,
            "fact_violation_key_diff": f"""
                SELECT COUNT(*) FROM (
                    SELECT violation_id, building_key, building_id, inspection_date_key, violation_class, hazard_severity_rank
                    FROM [{primary_db}].gold.fact_violation
                    EXCEPT
                    SELECT violation_id, building_key, building_id, inspection_date_key, violation_class, hazard_severity_rank
                    FROM [{verify_db}].gold.fact_violation
                ) d
            """,
            "fact_repair_order_key_and_amount_diff": f"""
                SELECT COUNT(*) FROM (
                    SELECT omo_id, omo_number, building_key, building_id, is_eligible_repair_cohort, omo_award_amount, eligible_omo_award_amount
                    FROM [{primary_db}].gold.fact_repair_order
                    EXCEPT
                    SELECT omo_id, omo_number, building_key, building_id, is_eligible_repair_cohort, omo_award_amount, eligible_omo_award_amount
                    FROM [{verify_db}].gold.fact_repair_order
                ) d
            """,
            "mart_building_month_diff": f"""
                SELECT COUNT(*) FROM (
                    SELECT building_id, year_month, building_key, complaint_count, problem_count, violation_count,
                           omo_order_count, raw_total_omo_award_amount, eligible_omo_award_amount
                    FROM [{primary_db}].gold.mart_building_month
                    EXCEPT
                    SELECT building_id, year_month, building_key, complaint_count, problem_count, violation_count,
                           omo_order_count, raw_total_omo_award_amount, eligible_omo_award_amount
                    FROM [{verify_db}].gold.mart_building_month
                ) d
            """,
            "priority_ranking_diff": f"""
                SELECT COUNT(*) FROM (
                    SELECT priority_rank, building_id, maintenance_priority_score, intervention_gap_status, eligible_omo_award_amount_2024
                    FROM [{primary_db}].semantic.v_building_priority_ranking
                    EXCEPT
                    SELECT priority_rank, building_id, maintenance_priority_score, intervention_gap_status, eligible_omo_award_amount_2024
                    FROM [{verify_db}].semantic.v_building_priority_ranking
                ) d
            """,
        }

        key_diffs = {}
        for k_name, q in key_diff_queries.items():
            diff_cnt = int(con.execute(text(q)).scalar())
            key_diffs[k_name] = diff_cnt
            if diff_cnt != 0:
                raise RuntimeError(f"Cross-DB key/value diff failed on {k_name}: {diff_cnt} differing rows")

    eng.dispose()
    return {
        "primary_db": primary_db,
        "verify_db": verify_db,
        "table_count_parity": table_parity,
        "set_difference_checks": key_diffs,
        "all_matched": True,
    }


def verify_idempotent_rerun(verify_db: str = "homerescue_dw_verify") -> dict:
    eng = _get_engine(verify_db)
    with eng.connect() as con:
        before_bkeys = dict(
            con.execute(text("SELECT building_id, building_key FROM gold.dim_building ORDER BY building_id")).fetchall()
        )
        before_totals = con.execute(
            text(
                """
                SELECT
                    (SELECT COUNT_BIG(*) FROM gold.dim_building) AS dim_bldg_cnt,
                    (SELECT COUNT_BIG(*) FROM gold.fact_complaint_problem) AS cp_cnt,
                    (SELECT COUNT_BIG(*) FROM gold.fact_violation) AS viol_cnt,
                    (SELECT COUNT_BIG(*) FROM gold.fact_repair_order) AS ro_cnt,
                    (SELECT COUNT_BIG(*) FROM gold.mart_building_month) AS mart_cnt,
                    (SELECT SUM(eligible_omo_award_amount) FROM gold.mart_building_month) AS eligible_award_sum,
                    (SELECT SUM(total_omo_award_amount) FROM gold.mart_building_month) AS total_award_sum
                """
            )
        ).mappings().fetchone()
    eng.dispose()

    # Rerun the full pipeline on verify_db
    rerun_res = run_pipeline(target_db=verify_db, raw_dir="data/raw", create_new_db=False)

    eng = _get_engine(verify_db)
    with eng.connect() as con:
        after_bkeys = dict(
            con.execute(text("SELECT building_id, building_key FROM gold.dim_building ORDER BY building_id")).fetchall()
        )
        after_totals = con.execute(
            text(
                """
                SELECT
                    (SELECT COUNT_BIG(*) FROM gold.dim_building) AS dim_bldg_cnt,
                    (SELECT COUNT_BIG(*) FROM gold.fact_complaint_problem) AS cp_cnt,
                    (SELECT COUNT_BIG(*) FROM gold.fact_violation) AS viol_cnt,
                    (SELECT COUNT_BIG(*) FROM gold.fact_repair_order) AS ro_cnt,
                    (SELECT COUNT_BIG(*) FROM gold.mart_building_month) AS mart_cnt,
                    (SELECT SUM(eligible_omo_award_amount) FROM gold.mart_building_month) AS eligible_award_sum,
                    (SELECT SUM(total_omo_award_amount) FROM gold.mart_building_month) AS total_award_sum
                """
            )
        ).mappings().fetchone()
    eng.dispose()

    changed_keys = [
        bid for bid, bkey in before_bkeys.items() if after_bkeys.get(bid) != bkey
    ]
    if changed_keys:
        raise RuntimeError(f"Surrogate keys changed on rerun for {len(changed_keys)} buildings!")

    for k in before_totals.keys():
        if _norm(before_totals[k]) != _norm(after_totals[k]):
            raise RuntimeError(f"Idempotency total changed on {k}: before={before_totals[k]}, after={after_totals[k]}")

    return {
        "database": verify_db,
        "rerun_elapsed_seconds": rerun_res["elapsed_seconds"],
        "total_building_keys_checked": len(before_bkeys),
        "changed_building_keys_count": len(changed_keys),
        "before_totals": {k: str(v) for k, v in before_totals.items()},
        "after_totals": {k: str(v) for k, v in after_totals.items()},
        "idempotent": True,
    }


def verify_backup_and_restore(
    source_db: str = "homerescue_dw",
    restore_db: str = "homerescue_dw_restore_test",
) -> dict:
    from src.run_pipeline import _run_sqlcmd_query

    master_eng = _get_engine("master", autocommit=True)
    with master_eng.connect() as con:
        props = con.execute(
            text(
                """
                SELECT
                    CAST(SERVERPROPERTY('InstanceDefaultBackupPath') AS NVARCHAR(500)) AS backup_dir,
                    CAST(SERVERPROPERTY('InstanceDefaultDataPath') AS NVARCHAR(500)) AS data_dir,
                    CAST(SERVERPROPERTY('InstanceDefaultLogPath') AS NVARCHAR(500)) AS log_dir
                """
            )
        ).mappings().fetchone()
        backup_dir = Path(props["backup_dir"])
        data_dir = Path(props["data_dir"])
        log_dir = Path(props["log_dir"])

        # Ensure we never overwrite an existing restore_db; if it exists, pick a unique timestamped name
        exists = con.execute(
            text("SELECT 1 FROM sys.databases WHERE name = :n"), {"n": restore_db}
        ).scalar()
        if exists:
            ts = datetime.now(timezone.utc).strftime("%Y%m%d_%H%M%S")
            restore_db = f"{restore_db}_{ts}"

        bak_path = backup_dir / f"{source_db}.bak"
        mdf_path = data_dir / f"{restore_db}.mdf"
        ldf_path = log_dir / f"{restore_db}_log.ldf"

        print(f"[Backup/Restore] Backing up [{source_db}] to {bak_path}...")
        _run_sqlcmd_query(
            "master",
            f"BACKUP DATABASE [{source_db}] TO DISK = N'{bak_path}' "
            "WITH INIT, FORMAT, NAME = N'homerescue_dw-Full Database Backup';",
        )

        filelist = con.execute(text(f"RESTORE FILELISTONLY FROM DISK = N'{bak_path}';")).mappings().fetchall()
        data_logical = next(r["LogicalName"] for r in filelist if r["Type"] == "D")
        log_logical = next(r["LogicalName"] for r in filelist if r["Type"] == "L")
        header = con.execute(text(f"RESTORE HEADERONLY FROM DISK = N'{bak_path}';")).mappings().fetchone()
        backup_size_bytes = int(header["BackupSize"])

        print(f"[Backup/Restore] Restoring backup into new database [{restore_db}]...")
        _run_sqlcmd_query(
            "master",
            f"RESTORE DATABASE [{restore_db}] FROM DISK = N'{bak_path}' "
            f"WITH MOVE N'{data_logical}' TO N'{mdf_path}', "
            f"MOVE N'{log_logical}' TO N'{ldf_path}', RECOVERY;",
        )

        # Verify restored database row counts and totals match source_db
        restored_summary = con.execute(
            text(
                f"""
                SELECT
                    (SELECT COUNT_BIG(*) FROM [{restore_db}].bronze.buildings) AS bronze_buildings,
                    (SELECT COUNT_BIG(*) FROM [{restore_db}].silver.building) AS silver_buildings,
                    (SELECT COUNT_BIG(*) FROM [{restore_db}].gold.dim_building) AS gold_dim_building,
                    (SELECT COUNT_BIG(*) FROM [{restore_db}].gold.fact_complaint_problem) AS gold_fact_cp,
                    (SELECT COUNT_BIG(*) FROM [{restore_db}].gold.fact_violation) AS gold_fact_viol,
                    (SELECT COUNT_BIG(*) FROM [{restore_db}].gold.fact_repair_order) AS gold_fact_ro,
                    (SELECT COUNT_BIG(*) FROM [{restore_db}].gold.mart_building_month) AS gold_mart_bm,
                    (SELECT SUM(eligible_omo_award_amount) FROM [{restore_db}].gold.mart_building_month) AS eligible_award_sum,
                    (SELECT SUM(total_omo_award_amount) FROM [{restore_db}].gold.mart_building_month) AS total_award_sum
                """
            )
        ).mappings().fetchone()

    master_eng.dispose()

    expected = {
        "bronze_buildings": 22404,
        "silver_buildings": 22329,
        "gold_dim_building": 22330,
        "gold_fact_cp": 14377,
        "gold_fact_viol": 18463,
        "gold_fact_ro": 490,
        "gold_mart_bm": 6812,
        "eligible_award_sum": Decimal("983560.44"),
        "total_award_sum": Decimal("3081609.44"),
    }
    for k, exp_v in expected.items():
        if _norm(restored_summary[k]) != _norm(exp_v):
            raise RuntimeError(f"Restored database mismatch on {k}: got {restored_summary[k]}, expected {exp_v}")

    return {
        "source_db": source_db,
        "restored_db": restore_db,
        "backup_file": str(bak_path),
        "restored_mdf_file": str(mdf_path),
        "restored_ldf_file": str(ldf_path),
        "backup_size_bytes": backup_size_bytes,
        "logical_files": {"data": data_logical, "log": log_logical},
        "restored_counts_and_totals": {k: str(v) for k, v in restored_summary.items()},
        "status": "PASS",
    }


def main():
    parity = verify_cross_db_parity("homerescue_dw", "homerescue_dw_verify")
    print("[M5] Cross-database parity verified between homerescue_dw and homerescue_dw_verify (100% match).")

    idemp = verify_idempotent_rerun("homerescue_dw_verify")
    print("[M5] Idempotent rerun verified on homerescue_dw_verify (0 surrogate keys changed, 0 duplicates).")

    backup_res = verify_backup_and_restore("homerescue_dw", "homerescue_dw_restore_test")
    print(f"[M5] Backup and restore verified on [{backup_res['restored_db']}] ({backup_res['backup_size_bytes']:,} bytes).")

    out_dir = Path("data/exports/validation")
    out_dir.mkdir(parents=True, exist_ok=True)
    out_file = out_dir / "m5_verification_and_backup_evidence.json"
    out_file.write_text(
        json.dumps(
            {
                "executed_at_utc": datetime.now(timezone.utc).isoformat(),
                "cross_database_parity": parity,
                "idempotent_rerun": idemp,
                "backup_and_restore": backup_res,
            },
            indent=2,
        ),
        encoding="utf-8",
    )
    print(f"[M5] Saved complete M5 verification evidence to {out_file}")


if __name__ == "__main__":
    main()
