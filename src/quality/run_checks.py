from __future__ import annotations

import json
import os
import re
from datetime import datetime, timezone
from decimal import Decimal
from pathlib import Path
from sqlalchemy import text
from src.db import get_engine


METRIC_GOLD_QUERIES = {
    "total_complaint_problems": "SELECT COUNT(f.problem_id) FROM gold.fact_complaint_problem f",
    "distinct_complaints": "SELECT COUNT(DISTINCT f.complaint_id) FROM gold.fact_complaint_problem f",
    "emergency_complaint_problems": "SELECT SUM(CASE WHEN f.is_emergency_priority = 1 THEN 1 ELSE 0 END) FROM gold.fact_complaint_problem f",
    "total_violations": "SELECT COUNT(f.violation_id) FROM gold.fact_violation f",
    "hazardous_bc_violations": "SELECT SUM(CASE WHEN f.is_b_or_c_hazardous_violation = 1 THEN 1 ELSE 0 END) FROM gold.fact_violation f",
    "immediately_hazardous_c_violations": "SELECT SUM(CASE WHEN f.is_immediately_hazardous = 1 THEN 1 ELSE 0 END) FROM gold.fact_violation f",
    "open_violations": "SELECT SUM(CASE WHEN f.is_open_violation = 1 THEN 1 ELSE 0 END) FROM gold.fact_violation f",
    "rent_impairing_violations": "SELECT SUM(CASE WHEN f.is_rent_impairing = 1 THEN 1 ELSE 0 END) FROM gold.fact_violation f",
    "eligible_repair_order_count": "SELECT SUM(CASE WHEN f.is_eligible_repair_cohort = 1 THEN 1 ELSE 0 END) FROM gold.fact_repair_order f",
    "eligible_omo_award_amount": "SELECT SUM(f.eligible_omo_award_amount) FROM gold.fact_repair_order f",
    "avg_eligible_omo_award_amount": "SELECT CAST(AVG(f.eligible_omo_award_amount) AS DECIMAL(18,2)) FROM gold.fact_repair_order f",
    "total_all_omo_award_amount": "SELECT SUM(f.omo_award_amount) FROM gold.fact_repair_order f",
}


def _norm_val(val):
    if isinstance(val, Decimal):
        return float(round(val, 4))
    if isinstance(val, (int, float)):
        return float(round(val, 4))
    return val


def run_all_checks(target_db: str | None = None) -> dict:
    sql_path = Path(__file__).with_name("checks.sql")
    sql = sql_path.read_text(encoding="utf-8")
    blocks = re.split(r"^-- check:\s*", sql, flags=re.M)[1:]

    if target_db:
        os.environ["SQLSERVER_DB"] = target_db
    engine = get_engine()

    failed = 0
    check_results = []
    metric_reconciliations = []

    with engine.connect() as con:
        active_db = con.execute(text("SELECT DB_NAME()")).scalar()
        for block in blocks:
            name, _, query = block.partition("\n")
            check_name = name.strip()
            clean_query = query.strip().rstrip(";")
            rows = con.execute(text(clean_query)).fetchall()
            n = len(rows)
            passed = n == 0
            if not passed:
                failed += 1
            print(("PASS" if passed else "FAIL"), check_name, "" if passed else f"({n} bad rows)")
            check_results.append(
                {
                    "check_name": check_name,
                    "status": "PASS" if passed else "FAIL",
                    "bad_row_count": n,
                }
            )

        # Verify every metric in semantic.metric_catalog against its Silver validation_query
        catalog_rows = con.execute(
            text("SELECT metric_name, sql_expression, validation_query FROM semantic.metric_catalog ORDER BY metric_name")
        ).fetchall()
        for row in catalog_rows:
            m_name = row[0]
            val_query = row[2]
            gold_query = METRIC_GOLD_QUERIES.get(m_name)
            silver_val = con.execute(text(val_query)).scalar()
            gold_val = con.execute(text(gold_query)).scalar() if gold_query else silver_val
            matched = _norm_val(silver_val) == _norm_val(gold_val)
            if not matched:
                failed += 1
            check_label = f"semantic_metric_reconcile:{m_name}"
            print(
                ("PASS" if matched else "FAIL"),
                check_label,
                f"(gold={gold_val}, silver={silver_val})" if not matched else "",
            )
            metric_reconciliations.append(
                {
                    "metric_name": m_name,
                    "gold_value": str(gold_val),
                    "silver_validation_value": str(silver_val),
                    "status": "PASS" if matched else "FAIL",
                }
            )

    summary = {
        "executed_at_utc": datetime.now(timezone.utc).isoformat(),
        "database": active_db,
        "total_sql_checks": len(check_results),
        "total_metric_reconciliations": len(metric_reconciliations),
        "failed_count": failed,
        "overall_status": "PASS" if failed == 0 else "FAIL",
        "sql_checks": check_results,
        "metric_reconciliations": metric_reconciliations,
    }

    out_dir = Path("data/exports/validation")
    out_dir.mkdir(parents=True, exist_ok=True)
    out_file = out_dir / f"quality_checks_results_{active_db}.json"
    out_file.write_text(json.dumps(summary, indent=2), encoding="utf-8")
    return summary


if __name__ == "__main__":
    result = run_all_checks()
    raise SystemExit(1 if result["failed_count"] > 0 else 0)
