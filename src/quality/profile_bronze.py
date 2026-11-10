"""Profile populated Bronze tables in SQL Server and export empirical evidence for M2 & M3 design."""

from __future__ import annotations

import json
from datetime import datetime, timezone
from pathlib import Path
from sqlalchemy import text
from src.db import get_database_name, get_engine


def fetch_dicts(con, sql_query: str) -> list[dict]:
    res = con.execute(text(sql_query))
    cols = list(res.keys())
    return [dict(zip(cols, row)) for row in res.fetchall()]


def run_bronze_profile(database: str | None = None) -> dict:
    target_db = database or get_database_name()
    engine = get_engine(database=target_db)
    manifest_path = Path("data/raw/manifest.json")
    manifest = json.loads(manifest_path.read_text(encoding="utf-8")) if manifest_path.exists() else {}

    report: dict = {
        "database": target_db,
        "profiled_at_utc": datetime.now(timezone.utc).isoformat(),
        "manifest_scope": manifest.get("scope", {}),
    }

    with engine.connect() as con:
        # 1. Row counts & provenance completeness
        report["table_summary"] = fetch_dicts(
            con,
            """
            SELECT 'bronze.buildings' AS table_name,
                   COUNT_BIG(*) AS total_rows,
                   SUM(CASE WHEN source_dataset_id IS NULL OR source_file IS NULL OR batch_id IS NULL OR ingested_at IS NULL OR raw_row_num IS NULL THEN 1 ELSE 0 END) AS null_provenance_rows,
                   MIN(raw_row_num) AS min_raw_row_num,
                   MAX(raw_row_num) AS max_raw_row_num
            FROM bronze.buildings
            UNION ALL
            SELECT 'bronze.complaints_problems',
                   COUNT_BIG(*),
                   SUM(CASE WHEN source_dataset_id IS NULL OR source_file IS NULL OR batch_id IS NULL OR ingested_at IS NULL OR raw_row_num IS NULL THEN 1 ELSE 0 END),
                   MIN(raw_row_num),
                   MAX(raw_row_num)
            FROM bronze.complaints_problems
            UNION ALL
            SELECT 'bronze.violations',
                   COUNT_BIG(*),
                   SUM(CASE WHEN source_dataset_id IS NULL OR source_file IS NULL OR batch_id IS NULL OR ingested_at IS NULL OR raw_row_num IS NULL THEN 1 ELSE 0 END),
                   MIN(raw_row_num),
                   MAX(raw_row_num)
            FROM bronze.violations
            UNION ALL
            SELECT 'bronze.omo_charges',
                   COUNT_BIG(*),
                   SUM(CASE WHEN source_dataset_id IS NULL OR source_file IS NULL OR batch_id IS NULL OR ingested_at IS NULL OR raw_row_num IS NULL THEN 1 ELSE 0 END),
                   MIN(raw_row_num),
                   MAX(raw_row_num)
            FROM bronze.omo_charges;
            """,
        )

        # 2. Buildings profiling
        report["buildings_profile"] = fetch_dicts(
            con,
            """
            SELECT COUNT_BIG(*) AS total_rows,
                   SUM(CASE WHEN NULLIF(TRIM(buildingid), '') IS NULL THEN 1 ELSE 0 END) AS missing_buildingid,
                   SUM(CASE WHEN NULLIF(TRIM(buildingid), '') IS NOT NULL AND TRY_CONVERT(INT, TRIM(buildingid)) IS NULL THEN 1 ELSE 0 END) AS invalid_buildingid,
                   COUNT(DISTINCT NULLIF(TRIM(buildingid), '')) AS distinct_buildingid,
                   COUNT(NULLIF(TRIM(buildingid), '')) - COUNT(DISTINCT NULLIF(TRIM(buildingid), '')) AS duplicate_buildingid_rows,
                   SUM(CASE WHEN NULLIF(TRIM(zip), '') IS NULL THEN 1 ELSE 0 END) AS missing_zip,
                   SUM(CASE WHEN NULLIF(TRIM(bin), '') IS NULL THEN 1 ELSE 0 END) AS missing_bin,
                   SUM(CASE WHEN NULLIF(TRIM(legalclassa), '') IS NULL THEN 1 ELSE 0 END) AS missing_legalclassa,
                   SUM(CASE WHEN NULLIF(TRIM(legalclassa), '') IS NOT NULL AND TRY_CONVERT(INT, TRIM(legalclassa)) IS NULL THEN 1 ELSE 0 END) AS invalid_legalclassa,
                   SUM(CASE WHEN TRY_CONVERT(INT, TRIM(legalclassa)) < 0 THEN 1 ELSE 0 END) AS negative_legalclassa,
                   SUM(CASE WHEN NULLIF(TRIM(legalstories), '') IS NULL THEN 1 ELSE 0 END) AS missing_legalstories,
                   SUM(CASE WHEN TRY_CONVERT(INT, TRIM(legalstories)) < 0 THEN 1 ELSE 0 END) AS negative_legalstories
            FROM bronze.buildings;
            """,
        )[0]

        report["buildings_status_breakdown"] = fetch_dicts(
            con,
            """
            SELECT recordstatus, lifecycle, managementprogram, COUNT(*) AS row_count
            FROM bronze.buildings
            GROUP BY recordstatus, lifecycle, managementprogram
            ORDER BY row_count DESC;
            """,
        )

        # 3. Complaints & Problems profiling
        report["complaints_problems_profile"] = fetch_dicts(
            con,
            """
            SELECT COUNT_BIG(*) AS total_rows,
                   SUM(CASE WHEN NULLIF(TRIM(problem_id), '') IS NULL THEN 1 ELSE 0 END) AS missing_problem_id,
                   SUM(CASE WHEN NULLIF(TRIM(problem_id), '') IS NOT NULL AND TRY_CONVERT(BIGINT, TRIM(problem_id)) IS NULL THEN 1 ELSE 0 END) AS invalid_problem_id,
                   COUNT(DISTINCT NULLIF(TRIM(problem_id), '')) AS distinct_problem_id,
                   COUNT(NULLIF(TRIM(problem_id), '')) - COUNT(DISTINCT NULLIF(TRIM(problem_id), '')) AS duplicate_problem_id_rows,
                   SUM(CASE WHEN NULLIF(TRIM(complaint_id), '') IS NULL THEN 1 ELSE 0 END) AS missing_complaint_id,
                   SUM(CASE WHEN NULLIF(TRIM(complaint_id), '') IS NOT NULL AND TRY_CONVERT(BIGINT, TRIM(complaint_id)) IS NULL THEN 1 ELSE 0 END) AS invalid_complaint_id,
                   COUNT(DISTINCT NULLIF(TRIM(complaint_id), '')) AS distinct_complaint_id,
                   SUM(CASE WHEN NULLIF(TRIM(building_id), '') IS NULL THEN 1 ELSE 0 END) AS missing_building_id,
                   SUM(CASE WHEN NULLIF(TRIM(building_id), '') IS NOT NULL AND TRY_CONVERT(INT, TRIM(building_id)) IS NULL THEN 1 ELSE 0 END) AS invalid_building_id,
                   SUM(CASE WHEN TRY_CONVERT(INT, TRIM(building_id)) <= 0 THEN 1 ELSE 0 END) AS nonpositive_building_id,
                   SUM(CASE WHEN NULLIF(TRIM(received_date), '') IS NULL THEN 1 ELSE 0 END) AS missing_received_date,
                   SUM(CASE WHEN NULLIF(TRIM(received_date), '') IS NOT NULL AND TRY_CONVERT(DATETIME2, TRIM(received_date)) IS NULL THEN 1 ELSE 0 END) AS unparseable_received_date,
                   SUM(CASE WHEN TRY_CONVERT(DATE, TRIM(received_date)) < '1900-01-01' OR TRY_CONVERT(DATE, TRIM(received_date)) > '2026-12-31' THEN 1 ELSE 0 END) AS out_of_range_received_date,
                   MIN(TRY_CONVERT(DATE, TRIM(received_date))) AS min_received_date,
                   MAX(TRY_CONVERT(DATE, TRIM(received_date))) AS max_received_date,
                   SUM(CASE WHEN NULLIF(TRIM(complaint_status_date), '') IS NULL THEN 1 ELSE 0 END) AS missing_complaint_status_date,
                   SUM(CASE WHEN NULLIF(TRIM(complaint_status_date), '') IS NOT NULL AND TRY_CONVERT(DATETIME2, TRIM(complaint_status_date)) IS NULL THEN 1 ELSE 0 END) AS unparseable_complaint_status_date,
                   SUM(CASE WHEN NULLIF(TRIM(problem_status_date), '') IS NULL THEN 1 ELSE 0 END) AS missing_problem_status_date,
                   SUM(CASE WHEN NULLIF(TRIM(problem_status_date), '') IS NOT NULL AND TRY_CONVERT(DATETIME2, TRIM(problem_status_date)) IS NULL THEN 1 ELSE 0 END) AS unparseable_problem_status_date
            FROM bronze.complaints_problems;
            """,
        )[0]

        report["complaints_duplicate_flag_breakdown"] = fetch_dicts(
            con,
            """
            SELECT problem_duplicate_flag, complaint_status, problem_status, type, COUNT(*) AS row_count
            FROM bronze.complaints_problems
            GROUP BY problem_duplicate_flag, complaint_status, problem_status, type
            ORDER BY row_count DESC;
            """,
        )

        # 4. Violations profiling
        report["violations_profile"] = fetch_dicts(
            con,
            """
            SELECT COUNT_BIG(*) AS total_rows,
                   SUM(CASE WHEN NULLIF(TRIM(violationid), '') IS NULL THEN 1 ELSE 0 END) AS missing_violationid,
                   SUM(CASE WHEN NULLIF(TRIM(violationid), '') IS NOT NULL AND TRY_CONVERT(BIGINT, TRIM(violationid)) IS NULL THEN 1 ELSE 0 END) AS invalid_violationid,
                   COUNT(DISTINCT NULLIF(TRIM(violationid), '')) AS distinct_violationid,
                   COUNT(NULLIF(TRIM(violationid), '')) - COUNT(DISTINCT NULLIF(TRIM(violationid), '')) AS duplicate_violationid_rows,
                   SUM(CASE WHEN NULLIF(TRIM(buildingid), '') IS NULL THEN 1 ELSE 0 END) AS missing_buildingid,
                   SUM(CASE WHEN NULLIF(TRIM(buildingid), '') IS NOT NULL AND TRY_CONVERT(INT, TRIM(buildingid)) IS NULL THEN 1 ELSE 0 END) AS invalid_buildingid,
                   SUM(CASE WHEN TRY_CONVERT(INT, TRIM(buildingid)) <= 0 THEN 1 ELSE 0 END) AS nonpositive_buildingid,
                   SUM(CASE WHEN NULLIF(TRIM(class), '') IS NULL THEN 1 ELSE 0 END) AS missing_class,
                   SUM(CASE WHEN UPPER(NULLIF(TRIM(class), '')) NOT IN ('A', 'B', 'C', 'I') THEN 1 ELSE 0 END) AS unexpected_class,
                   SUM(CASE WHEN NULLIF(TRIM(inspectiondate), '') IS NULL THEN 1 ELSE 0 END) AS missing_inspectiondate,
                   SUM(CASE WHEN NULLIF(TRIM(inspectiondate), '') IS NOT NULL AND TRY_CONVERT(DATETIME2, TRIM(inspectiondate)) IS NULL THEN 1 ELSE 0 END) AS unparseable_inspectiondate,
                   SUM(CASE WHEN TRY_CONVERT(DATE, TRIM(inspectiondate)) < '1900-01-01' OR TRY_CONVERT(DATE, TRIM(inspectiondate)) > '2026-12-31' THEN 1 ELSE 0 END) AS out_of_range_inspectiondate,
                   MIN(TRY_CONVERT(DATE, TRIM(inspectiondate))) AS min_inspectiondate,
                   MAX(TRY_CONVERT(DATE, TRIM(inspectiondate))) AS max_inspectiondate,
                   SUM(CASE WHEN NULLIF(TRIM(approveddate), '') IS NULL THEN 1 ELSE 0 END) AS missing_approveddate,
                   SUM(CASE WHEN NULLIF(TRIM(approveddate), '') IS NOT NULL AND TRY_CONVERT(DATETIME2, TRIM(approveddate)) IS NULL THEN 1 ELSE 0 END) AS unparseable_approveddate,
                   SUM(CASE WHEN TRY_CONVERT(DATE, TRIM(approveddate)) < '1900-01-01' OR TRY_CONVERT(DATE, TRIM(approveddate)) > '2026-12-31' THEN 1 ELSE 0 END) AS out_of_range_approveddate,
                   SUM(CASE WHEN NULLIF(TRIM(novissueddate), '') IS NULL THEN 1 ELSE 0 END) AS missing_novissueddate,
                   SUM(CASE WHEN NULLIF(TRIM(certifieddate), '') IS NULL THEN 1 ELSE 0 END) AS missing_certifieddate
            FROM bronze.violations;
            """,
        )[0]

        report["violations_class_status_breakdown"] = fetch_dicts(
            con,
            """
            SELECT class, violationstatus, rentimpairing, COUNT(*) AS row_count
            FROM bronze.violations
            GROUP BY class, violationstatus, rentimpairing
            ORDER BY class, violationstatus;
            """,
        )

        # 5. OMO Charges profiling
        report["omo_charges_profile"] = fetch_dicts(
            con,
            """
            SELECT COUNT_BIG(*) AS total_rows,
                   SUM(CASE WHEN NULLIF(TRIM(omoid), '') IS NULL THEN 1 ELSE 0 END) AS missing_omoid,
                   SUM(CASE WHEN NULLIF(TRIM(omoid), '') IS NOT NULL AND TRY_CONVERT(BIGINT, TRIM(omoid)) IS NULL THEN 1 ELSE 0 END) AS invalid_omoid,
                   COUNT(DISTINCT NULLIF(TRIM(omoid), '')) AS distinct_omoid,
                   COUNT(NULLIF(TRIM(omoid), '')) - COUNT(DISTINCT NULLIF(TRIM(omoid), '')) AS duplicate_omoid_rows,
                   SUM(CASE WHEN NULLIF(TRIM(omonumber), '') IS NULL THEN 1 ELSE 0 END) AS missing_omonumber,
                   COUNT(DISTINCT NULLIF(TRIM(omonumber), '')) AS distinct_omonumber,
                   COUNT(NULLIF(TRIM(omonumber), '')) - COUNT(DISTINCT NULLIF(TRIM(omonumber), '')) AS duplicate_omonumber_rows,
                   SUM(CASE WHEN NULLIF(TRIM(buildingid), '') IS NULL THEN 1 ELSE 0 END) AS missing_buildingid,
                   SUM(CASE WHEN NULLIF(TRIM(buildingid), '') IS NOT NULL AND TRY_CONVERT(INT, TRIM(buildingid)) IS NULL THEN 1 ELSE 0 END) AS invalid_buildingid,
                   SUM(CASE WHEN TRY_CONVERT(INT, TRIM(buildingid)) <= 0 THEN 1 ELSE 0 END) AS nonpositive_buildingid,
                   SUM(CASE WHEN NULLIF(TRIM(omoawardamount), '') IS NULL THEN 1 ELSE 0 END) AS missing_omoawardamount,
                   SUM(CASE WHEN NULLIF(TRIM(omoawardamount), '') IS NOT NULL AND TRY_CONVERT(DECIMAL(18,2), TRIM(omoawardamount)) IS NULL THEN 1 ELSE 0 END) AS unparseable_omoawardamount,
                   SUM(CASE WHEN TRY_CONVERT(DECIMAL(18,2), TRIM(omoawardamount)) < 0 THEN 1 ELSE 0 END) AS negative_omoawardamount,
                   SUM(CASE WHEN TRY_CONVERT(DECIMAL(18,2), TRIM(omoawardamount)) = 0 THEN 1 ELSE 0 END) AS zero_omoawardamount,
                   SUM(CASE WHEN TRY_CONVERT(DECIMAL(18,2), TRIM(omoawardamount)) > 0 THEN 1 ELSE 0 END) AS positive_omoawardamount,
                   MIN(TRY_CONVERT(DECIMAL(18,2), TRIM(omoawardamount))) AS min_omoawardamount,
                   MAX(TRY_CONVERT(DECIMAL(18,2), TRIM(omoawardamount))) AS max_omoawardamount,
                   SUM(TRY_CONVERT(DECIMAL(18,2), TRIM(omoawardamount))) AS sum_omoawardamount,
                   SUM(CASE WHEN NULLIF(TRIM(netchangeorders), '') IS NULL THEN 1 ELSE 0 END) AS missing_netchangeorders,
                   SUM(CASE WHEN NULLIF(TRIM(netchangeorders), '') IS NOT NULL AND TRY_CONVERT(DECIMAL(18,2), TRIM(netchangeorders)) IS NULL THEN 1 ELSE 0 END) AS unparseable_netchangeorders,
                   SUM(CASE WHEN TRY_CONVERT(DECIMAL(18,2), TRIM(netchangeorders)) < 0 THEN 1 ELSE 0 END) AS negative_netchangeorders,
                   SUM(CASE WHEN TRY_CONVERT(DECIMAL(18,2), TRIM(netchangeorders)) = 0 THEN 1 ELSE 0 END) AS zero_netchangeorders,
                   SUM(CASE WHEN TRY_CONVERT(DECIMAL(18,2), TRIM(netchangeorders)) > 0 THEN 1 ELSE 0 END) AS positive_netchangeorders,
                   MIN(TRY_CONVERT(DECIMAL(18,2), TRIM(netchangeorders))) AS min_netchangeorders,
                   MAX(TRY_CONVERT(DECIMAL(18,2), TRIM(netchangeorders))) AS max_netchangeorders,
                   SUM(TRY_CONVERT(DECIMAL(18,2), TRIM(netchangeorders))) AS sum_netchangeorders,
                   SUM(CASE WHEN NULLIF(TRIM(omocreatedate), '') IS NULL THEN 1 ELSE 0 END) AS missing_omocreatedate,
                   SUM(CASE WHEN NULLIF(TRIM(omocreatedate), '') IS NOT NULL AND TRY_CONVERT(DATETIME2, TRIM(omocreatedate)) IS NULL THEN 1 ELSE 0 END) AS unparseable_omocreatedate,
                   MIN(TRY_CONVERT(DATE, TRIM(omocreatedate))) AS min_omocreatedate,
                   MAX(TRY_CONVERT(DATE, TRIM(omocreatedate))) AS max_omocreatedate,
                   SUM(CASE WHEN NULLIF(TRIM(omoawarddate), '') IS NULL THEN 1 ELSE 0 END) AS missing_omoawarddate,
                   SUM(CASE WHEN NULLIF(TRIM(omoawarddate), '') IS NOT NULL AND TRY_CONVERT(DATETIME2, TRIM(omoawarddate)) IS NULL THEN 1 ELSE 0 END) AS unparseable_omoawarddate
            FROM bronze.omo_charges;
            """,
        )[0]

        report["omo_worktype_program_breakdown"] = fetch_dicts(
            con,
            """
            SELECT worktypegeneral, lifecycle, isaep, iscommercialdemolition, servicechargeflag, omostatusreason,
                   COUNT(*) AS row_count,
                   SUM(TRY_CONVERT(DECIMAL(18,2), TRIM(omoawardamount))) AS total_award_amount,
                   SUM(TRY_CONVERT(DECIMAL(18,2), TRIM(netchangeorders))) AS total_net_change_orders
            FROM bronze.omo_charges
            GROUP BY worktypegeneral, lifecycle, isaep, iscommercialdemolition, servicechargeflag, omostatusreason
            ORDER BY row_count DESC;
            """,
        )

        # 6. Cross-source building_id matching against bronze.buildings
        report["cross_source_building_match"] = fetch_dicts(
            con,
            """
            WITH b AS (
                SELECT DISTINCT TRY_CONVERT(INT, TRIM(buildingid)) AS building_id
                FROM bronze.buildings
                WHERE TRY_CONVERT(INT, TRIM(buildingid)) IS NOT NULL
            )
            SELECT 'complaints_problems' AS source_table,
                   COUNT(*) AS total_rows,
                   SUM(CASE WHEN b.building_id IS NOT NULL THEN 1 ELSE 0 END) AS matched_rows,
                   SUM(CASE WHEN b.building_id IS NULL THEN 1 ELSE 0 END) AS unmatched_rows,
                   COUNT(DISTINCT CASE WHEN b.building_id IS NULL THEN TRY_CONVERT(INT, TRIM(c.building_id)) END) AS distinct_unmatched_buildings
            FROM bronze.complaints_problems c
            LEFT JOIN b ON TRY_CONVERT(INT, TRIM(c.building_id)) = b.building_id
            UNION ALL
            SELECT 'violations',
                   COUNT(*),
                   SUM(CASE WHEN b.building_id IS NOT NULL THEN 1 ELSE 0 END),
                   SUM(CASE WHEN b.building_id IS NULL THEN 1 ELSE 0 END),
                   COUNT(DISTINCT CASE WHEN b.building_id IS NULL THEN TRY_CONVERT(INT, TRIM(v.buildingid)) END)
            FROM bronze.violations v
            LEFT JOIN b ON TRY_CONVERT(INT, TRIM(v.buildingid)) = b.building_id
            UNION ALL
            SELECT 'omo_charges',
                   COUNT(*),
                   SUM(CASE WHEN b.building_id IS NOT NULL THEN 1 ELSE 0 END),
                   SUM(CASE WHEN b.building_id IS NULL THEN 1 ELSE 0 END),
                   COUNT(DISTINCT CASE WHEN b.building_id IS NULL THEN TRY_CONVERT(INT, TRIM(o.buildingid)) END)
            FROM bronze.omo_charges o
            LEFT JOIN b ON TRY_CONVERT(INT, TRIM(o.buildingid)) = b.building_id;
            """,
        )

        report["buildings_anomalies"] = fetch_dicts(
            con,
            """
            SELECT COUNT(*) AS total_anomalous_buildings,
                   SUM(CASE WHEN TRY_CONVERT(INT, TRIM(block)) <= 0 OR TRY_CONVERT(INT, TRIM(lot)) <= 0 THEN 1 ELSE 0 END) AS zero_block_or_lot,
                   SUM(CASE WHEN NULLIF(TRIM(streetname), '') IS NULL OR TRIM(streetname) IN ('0', '00') THEN 1 ELSE 0 END) AS placeholder_streetname,
                   SUM(CASE WHEN NULLIF(TRIM(housenumber), '') IS NULL OR TRIM(housenumber) IN ('0', '00') THEN 1 ELSE 0 END) AS placeholder_housenumber
            FROM bronze.buildings;
            """,
        )[0]

        report["unmatched_building_details"] = {
            "complaints": fetch_dicts(
                con,
                """
                SELECT DISTINCT TRIM(c.building_id) AS building_id, c.house_number, c.street_name, c.post_code, c.block, c.lot, COUNT(*) AS row_count
                FROM bronze.complaints_problems c
                LEFT JOIN bronze.buildings b ON TRIM(c.building_id) = TRIM(b.buildingid)
                WHERE b.buildingid IS NULL
                GROUP BY TRIM(c.building_id), c.house_number, c.street_name, c.post_code, c.block, c.lot;
                """,
            ),
            "violations": fetch_dicts(
                con,
                """
                SELECT DISTINCT TRIM(v.buildingid) AS building_id, v.housenumber, v.streetname, v.zip, v.block, v.lot, COUNT(*) AS row_count
                FROM bronze.violations v
                LEFT JOIN bronze.buildings b ON TRIM(v.buildingid) = TRIM(b.buildingid)
                WHERE b.buildingid IS NULL
                GROUP BY TRIM(v.buildingid), v.housenumber, v.streetname, v.zip, v.block, v.lot;
                """,
            ),
            "omo_charges": fetch_dicts(
                con,
                """
                SELECT DISTINCT TRIM(o.buildingid) AS building_id, o.housenumber, o.streetname, o.zip, o.block, o.lot, o.lifecycle, o.worktypegeneral, COUNT(*) AS row_count
                FROM bronze.omo_charges o
                LEFT JOIN bronze.buildings b ON TRIM(o.buildingid) = TRIM(b.buildingid)
                WHERE b.buildingid IS NULL
                GROUP BY TRIM(o.buildingid), o.housenumber, o.streetname, o.zip, o.block, o.lot, o.lifecycle, o.worktypegeneral;
                """,
            ),
        }

        report["omo_zero_or_negative_details"] = fetch_dicts(
            con,
            """
            SELECT omoid, omonumber, buildingid, lifecycle, worktypegeneral, omostatusreason,
                   omoawardamount, omoawarddate, iscommercialdemolition, servicechargeflag
            FROM bronze.omo_charges
            WHERE TRY_CONVERT(DECIMAL(18,2), TRIM(omoawardamount)) <= 0;
            """,
        )

    # 7. Test safe staging rollback (failed load preserves last valid dataset)
    with engine.begin() as con:
        con.execute(text("TRUNCATE TABLE bronze.stg_buildings;"))
    rollback_verified = False
    error_captured = None
    try:
        with engine.begin() as con:
            con.execute(
                text(
                    "EXEC bronze.load_buildings @file_path = N'deliberate_empty_stage_test.csv', @use_staged = 1"
                )
            )
    except Exception as exc:
        error_captured = str(exc)

    with engine.connect() as con:
        surviving_rows = int(
            con.execute(text("SELECT COUNT_BIG(*) FROM bronze.buildings")).scalar()
        )
        rollback_verified = surviving_rows == 22404
        audit_logs = fetch_dicts(
            con,
            """
            SELECT load_id, CAST(batch_id AS VARCHAR(50)) AS batch_id, source_name, target_table,
                   CONVERT(VARCHAR(30), start_time, 126) AS start_time,
                   CONVERT(VARCHAR(30), end_time, 126) AS end_time,
                   rows_loaded, status, message
            FROM audit.load_log
            ORDER BY load_id;
            """,
        )

    report["safe_staging_rollback_test"] = {
        "surviving_buildings_rows": surviving_rows,
        "rollback_preserved_valid_data": rollback_verified,
        "expected_error_captured": error_captured is not None,
    }
    report["audit_load_log"] = audit_logs

    out_dir = Path("data/exports/validation")
    out_dir.mkdir(parents=True, exist_ok=True)
    out_path = out_dir / f"m2_bronze_profile_{target_db}.json"
    out_path.write_text(json.dumps(report, indent=2, default=str), encoding="utf-8")
    print(f"Saved Bronze profile report to {out_path}")
    return report


if __name__ == "__main__":
    run_bronze_profile()
