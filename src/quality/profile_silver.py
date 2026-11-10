"""Export empirical Silver layer reconciliation, rejection, duplicate, cohort, and matching statistics (M3)."""

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


def run_silver_profile(database: str | None = None) -> dict:
    target_db = database or get_database_name()
    engine = get_engine(database=target_db)

    report: dict = {
        "database": target_db,
        "profiled_at_utc": datetime.now(timezone.utc).isoformat(),
    }

    with engine.connect() as con:
        report["batch_reconciliation"] = fetch_dicts(
            con,
            """
            SELECT recon_id, source_table, silver_table,
                   CAST(batch_id AS VARCHAR(50)) AS batch_id,
                   bronze_rows, accepted_rows, rejected_rows, duplicate_rows_removed,
                   reconciliation_diff, matched_building_rows, unmatched_building_rows,
                   CAST(ROUND(100.0 * matched_building_rows / NULLIF(accepted_rows, 0), 4) AS DECIMAL(8,4)) AS matched_pct,
                   CAST(ROUND(100.0 * unmatched_building_rows / NULLIF(accepted_rows, 0), 4) AS DECIMAL(8,4)) AS unmatched_pct
            FROM silver.batch_reconciliation
            ORDER BY recon_id;
            """,
        )

        report["reject_log_breakdown"] = fetch_dicts(
            con,
            """
            SELECT source_table, reason, COUNT(*) AS rejected_row_count,
                   MIN(raw_row_num) AS first_raw_row_num,
                   MAX(raw_row_num) AS last_raw_row_num
            FROM silver.reject_log
            GROUP BY source_table, reason
            ORDER BY source_table, rejected_row_count DESC;
            """,
        )

        report["reject_log_samples"] = fetch_dicts(
            con,
            """
            SELECT TOP 15 reject_id, source_table, bronze_row_id, raw_row_num, business_key, reason, raw_summary
            FROM silver.reject_log
            ORDER BY reject_id;
            """,
        )

        report["duplicate_log_breakdown"] = fetch_dicts(
            con,
            """
            SELECT source_table, resolution_rule, COUNT(*) AS duplicate_rows_removed
            FROM silver.duplicate_log
            GROUP BY source_table, resolution_rule
            ORDER BY source_table;
            """,
        )

        report["building_summary"] = fetch_dicts(
            con,
            """
            SELECT record_status, lifecycle, is_active_building,
                   COUNT(*) AS building_count,
                   SUM(ISNULL(legal_class_a_units, 0)) AS total_class_a_units,
                   SUM(ISNULL(legal_class_b_units, 0)) AS total_class_b_units
            FROM silver.building
            GROUP BY record_status, lifecycle, is_active_building
            ORDER BY building_count DESC;
            """,
        )

        report["complaint_problem_summary"] = fetch_dicts(
            con,
            """
            SELECT COUNT(*) AS total_problem_rows,
                   COUNT(DISTINCT problem_id) AS distinct_problems,
                   COUNT(DISTINCT complaint_id) AS distinct_complaints,
                   COUNT(DISTINCT building_id) AS distinct_buildings,
                   SUM(CASE WHEN is_duplicate_problem_flag = 1 THEN 1 ELSE 0 END) AS flagged_duplicate_problem_rows,
                   SUM(CASE WHEN is_duplicate_problem_flag = 0 THEN 1 ELSE 0 END) AS non_duplicate_problem_rows,
                   SUM(CASE WHEN is_registered_building = 1 THEN 1 ELSE 0 END) AS registered_building_rows,
                   SUM(CASE WHEN is_registered_building = 0 THEN 1 ELSE 0 END) AS unregistered_building_rows,
                   COUNT(DISTINCT CASE WHEN is_registered_building = 0 THEN building_id END) AS distinct_unregistered_buildings,
                   MIN(received_date) AS min_received_date,
                   MAX(received_date) AS max_received_date
            FROM silver.complaint_problem;
            """,
        )[0]

        report["violation_class_summary"] = fetch_dicts(
            con,
            """
            SELECT violation_class, hazard_class_category, hazard_severity_rank, is_hazardous_violation,
                   COUNT(*) AS total_violations,
                   SUM(CASE WHEN is_open_violation = 1 THEN 1 ELSE 0 END) AS open_violations,
                   SUM(CASE WHEN is_open_violation = 0 THEN 1 ELSE 0 END) AS closed_violations,
                   SUM(CASE WHEN is_rent_impairing = 1 THEN 1 ELSE 0 END) AS rent_impairing_violations,
                   SUM(CASE WHEN is_registered_building = 1 THEN 1 ELSE 0 END) AS registered_building_rows,
                   SUM(CASE WHEN is_registered_building = 0 THEN 1 ELSE 0 END) AS unregistered_building_rows
            FROM silver.violation
            GROUP BY violation_class, hazard_class_category, hazard_severity_rank, is_hazardous_violation
            ORDER BY hazard_severity_rank DESC;
            """,
        )

        report["omo_cohort_summary"] = fetch_dicts(
            con,
            """
            SELECT is_eligible_repair_cohort, repair_cohort_category, financial_value_status,
                   COUNT(*) AS order_count,
                   COUNT(DISTINCT omo_id) AS distinct_omo_ids,
                   COUNT(DISTINCT omo_number) AS distinct_omo_numbers,
                   COUNT(DISTINCT building_id) AS distinct_buildings,
                   SUM(omo_award_amount) AS total_award_amount,
                   AVG(omo_award_amount) AS avg_award_amount,
                   MIN(omo_award_amount) AS min_award_amount,
                   MAX(omo_award_amount) AS max_award_amount,
                   SUM(net_change_orders) AS total_net_change_orders,
                   SUM(CASE WHEN is_registered_building = 1 THEN 1 ELSE 0 END) AS registered_building_rows,
                   SUM(CASE WHEN is_registered_building = 0 THEN 1 ELSE 0 END) AS unregistered_building_rows
            FROM silver.omo_charge
            GROUP BY is_eligible_repair_cohort, repair_cohort_category, financial_value_status
            ORDER BY is_eligible_repair_cohort DESC, order_count DESC;
            """,
        )

        report["omo_worktype_by_cohort"] = fetch_dicts(
            con,
            """
            SELECT is_eligible_repair_cohort, work_type_general,
                   COUNT(*) AS order_count,
                   SUM(omo_award_amount) AS total_award_amount,
                   AVG(omo_award_amount) AS avg_award_amount
            FROM silver.omo_charge
            GROUP BY is_eligible_repair_cohort, work_type_general
            ORDER BY is_eligible_repair_cohort DESC, total_award_amount DESC;
            """,
        )

        report["unmatched_building_detail_by_table"] = fetch_dicts(
            con,
            """
            SELECT 'silver.complaint_problem' AS silver_table, building_id, MAX(house_number) AS house_number,
                   MAX(street_name) AS street_name, MAX(post_code) AS zip_code, COUNT(*) AS event_rows
            FROM silver.complaint_problem
            WHERE is_registered_building = 0
            GROUP BY building_id
            UNION ALL
            SELECT 'silver.violation', building_id, MAX(house_number), MAX(street_name), MAX(zip_code), COUNT(*)
            FROM silver.violation
            WHERE is_registered_building = 0
            GROUP BY building_id
            UNION ALL
            SELECT 'silver.omo_charge', building_id, MAX(house_number), MAX(street_name), MAX(zip_code), COUNT(*)
            FROM silver.omo_charge
            WHERE is_registered_building = 0
            GROUP BY building_id
            ORDER BY silver_table, building_id;
            """,
        )

    out_dir = Path("data/exports/validation")
    out_dir.mkdir(parents=True, exist_ok=True)
    out_path = out_dir / f"m3_silver_profile_{target_db}.json"
    out_path.write_text(json.dumps(report, indent=2, default=str), encoding="utf-8")
    print(f"Saved Silver profile report to {out_path}")
    return report


if __name__ == "__main__":
    run_silver_profile()
