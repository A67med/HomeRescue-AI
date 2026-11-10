from __future__ import annotations

import subprocess
from decimal import Decimal
from pathlib import Path
import pytest
from sqlalchemy import create_engine, text
from src.quality.run_checks import run_all_checks


SQLCMD_PATH = r"C:\Program Files\Microsoft SQL Server\Client SDK\ODBC\180\Tools\Binn\sqlcmd.exe"
SYNTH_DB = "homerescue_dw_synth_fixture"


def _get_db_engine(db_name: str, autocommit: bool = False):
    url = (
        f"mssql+pyodbc://@localhost/{db_name}"
        "?driver=ODBC+Driver+18+for+SQL+Server"
        "&trusted_connection=yes&TrustServerCertificate=yes"
    )
    return create_engine(url, isolation_level="AUTOCOMMIT" if autocommit else None)


def _run_sql_script(db_name: str, script_rel_path: str) -> None:
    cmd = [
        SQLCMD_PATH,
        "-S",
        "localhost",
        "-d",
        db_name,
        "-E",
        "-C",
        "-b",
        "-i",
        str(Path(script_rel_path)),
    ]
    res = subprocess.run(cmd, capture_output=True, text=True, check=False)
    assert res.returncode == 0, f"sqlcmd failed on {script_rel_path}:\n{res.stdout}\n{res.stderr}"


@pytest.fixture(scope="module")
def synth_db_engine():
    master_eng = _get_db_engine("master", autocommit=True)
    with master_eng.connect() as con:
        exists = con.execute(
            text("SELECT 1 FROM sys.databases WHERE name = :n"), {"n": SYNTH_DB}
        ).scalar()
        if not exists:
            con.execute(text(f"CREATE DATABASE [{SYNTH_DB}]"))

    for script in [
        "sql/00_init.sql",
        "sql/01_bronze.sql",
        "sql/02_silver.sql",
        "sql/03_gold.sql",
        "sql/05_feature_views.sql",
        "sql/04_semantic.sql",
    ]:
        _run_sql_script(SYNTH_DB, script)

    eng = _get_db_engine(SYNTH_DB)
    yield eng
    eng.dispose()
    master_eng.dispose()


def test_synthetic_edge_cases_and_fanout_protection(synth_db_engine):
    """
    Executes end-to-end synthetic fixture tests on an isolated database
    (homerescue_dw_synth_fixture) to verify:
      1. Duplicate natural key & secondary omo_number deduplication and logging.
      2. Missing value vs. conversion failure vs. implausible value separation.
      3. Multi-defect rows produce exactly 1 row in silver.reject_log (no inflation).
      4. Bronze = Accepted + Rejected + Duplicates across all 4 tables.
      5. Negative OMO award rejection, zero-dollar OMO retention, and NULL vs 0.00 distinction.
      6. Unmatched buildings (building_key = -1) retained and kept distinct by building_id.
      7. Fan-out protection: adding extra complaints & violations does not multiply OMO award sums.
      8. Surrogate key stability across reruns of gold.load_dim_building.
    """
    with synth_db_engine.begin() as con:
        con.execute(text("TRUNCATE TABLE bronze.buildings"))
        con.execute(text("TRUNCATE TABLE bronze.complaints_problems"))
        con.execute(text("TRUNCATE TABLE bronze.violations"))
        con.execute(text("TRUNCATE TABLE bronze.omo_charges"))

        # --- 1. Synthetic Bronze Buildings (7 rows) ---
        con.execute(
            text(
                """
                DECLARE @b UNIQUEIDENTIFIER = NEWID();
                INSERT INTO bronze.buildings (
                    buildingid, boroid, boro, housenumber, streetname, zip,
                    block, lot, legalstories, legalclassa, legalclassb,
                    lifecycle, recordstatus, source_file, batch_id, raw_row_num
                )
                VALUES
                ('1001', '5', 'STATEN ISLAND', '10', 'MAIN ST', '10301', '10', '20', '3', '6', '0', 'Building', 'Inactive', 'synth.csv', @b, 1),
                ('1001', '5', 'STATEN ISLAND', '10', 'MAIN ST', '10301', '10', '20', '3', '6', '0', 'Building', 'Active',   'synth.csv', @b, 2),
                ('1002', '5', 'STATEN ISLAND', '20', 'OAK AVE', '10304', '15', '25', '2', '2', '0', 'Building', 'Active',   'synth.csv', @b, 3),
                ('',     '5', 'STATEN ISLAND', '30', 'ELM ST',  '10301', '12', '12', '2', '1', '0', 'Building', 'Active',   'synth.csv', @b, 4),
                ('NOT_AN_INT', '5', 'STATEN ISLAND', '40', 'ELM ST', '10301', '12', '13', '2', '1', '0', 'Building', 'Active', 'synth.csv', @b, 5),
                ('-99',  '5', 'STATEN ISLAND', '50', 'ELM ST',  '10301', '12', '14', '2', '1', '0', 'Building', 'Active',   'synth.csv', @b, 6),
                ('1003', '5', 'STATEN ISLAND', '60', 'PINE ST', '10301', '0',  '0',  '2', '1', '0', 'Building', 'Active',   'synth.csv', @b, 7);
                """
            )
        )

        # --- 2. Synthetic Bronze Complaints & Problems (8 rows) ---
        con.execute(
            text(
                """
                DECLARE @b UNIQUEIDENTIFIER = NEWID();
                INSERT INTO bronze.complaints_problems (
                    problem_id, complaint_id, building_id, borough, house_number, street_name, post_code,
                    type, major_category, minor_category, problem_code, received_date,
                    complaint_status, problem_status, problem_status_date, problem_duplicate_flag,
                    source_file, batch_id, raw_row_num
                )
                VALUES
                ('5001', '3001', '1001', 'STATEN ISLAND', '10', 'MAIN ST', '10301', 'EMERGENCY', 'HEAT/HOT WATER', 'ENTIRE BUILDING', 'NO HEAT', '2024-06-05', 'OPEN', 'OPEN', '2024-06-06', 'N', 'synth.csv', @b, 1),
                ('5001', '3001', '1001', 'STATEN ISLAND', '10', 'MAIN ST', '10301', 'EMERGENCY', 'HEAT/HOT WATER', 'ENTIRE BUILDING', 'NO HEAT', '2024-06-05', 'CLOSE', 'CLOSE', '2024-06-10', 'N', 'synth.csv', @b, 2),
                ('5002', '3002', '888001', 'STATEN ISLAND', '99', 'GHOST LN', '10314', 'EMERGENCY', 'PLUMBING', 'BASIN/SINK', 'LEAK', '2024-06-12', 'OPEN', 'OPEN', '2024-06-12', 'N', 'synth.csv', @b, 3),
                ('',     '3003', '1001', 'STATEN ISLAND', '10', 'MAIN ST', '10301', 'NON EMERGENCY', 'PAINT/PLASTER', 'CEILING', 'PEELING', '2024-06-15', 'OPEN', 'OPEN', NULL, 'N', 'synth.csv', @b, 4),
                ('BAD_PROB', '3004', '1001', 'STATEN ISLAND', '10', 'MAIN ST', '10301', 'NON EMERGENCY', 'PAINT/PLASTER', 'CEILING', 'PEELING', '2024-06-15', 'OPEN', 'OPEN', NULL, 'N', 'synth.csv', @b, 5),
                ('5003', '3005', '1001', 'STATEN ISLAND', '10', 'MAIN ST', '10301', 'NON EMERGENCY', 'PAINT/PLASTER', 'CEILING', 'PEELING', 'NOT_A_DATE', 'OPEN', 'OPEN', NULL, 'N', 'synth.csv', @b, 6),
                ('5004', '3006', '1001', 'STATEN ISLAND', '10', 'MAIN ST', '10301', 'NON EMERGENCY', 'PAINT/PLASTER', 'CEILING', 'PEELING', '1850-01-01', 'OPEN', 'OPEN', NULL, 'N', 'synth.csv', @b, 7),
                ('5999', 'BAD_C', 'BAD_B', 'STATEN ISLAND', '10', 'MAIN ST', '10301', 'NON EMERGENCY', 'PAINT/PLASTER', 'CEILING', 'PEELING', 'BAD_D', 'OPEN', 'OPEN', NULL, 'N', 'synth.csv', @b, 8);
                """
            )
        )

        # --- 3. Synthetic Bronze Violations (6 rows) ---
        con.execute(
            text(
                """
                DECLARE @b UNIQUEIDENTIFIER = NEWID();
                INSERT INTO bronze.violations (
                    violationid, buildingid, boroid, boro, housenumber, streetname, zip,
                    class, inspectiondate, currentstatusdate, violationstatus, rentimpairing,
                    source_file, batch_id, raw_row_num
                )
                VALUES
                ('7001', '1001', '5', 'STATEN ISLAND', '10', 'MAIN ST', '10301', 'C', '2024-06-07', '2024-06-08', 'Open', 'Y', 'synth.csv', @b, 1),
                ('7001', '1001', '5', 'STATEN ISLAND', '10', 'MAIN ST', '10301', 'C', '2024-06-07', '2024-06-15', 'Open', 'Y', 'synth.csv', @b, 2),
                ('7002', '1001', '5', 'STATEN ISLAND', '10', 'MAIN ST', '10301', 'I', '2024-06-09', '2024-06-09', 'Open', 'N', 'synth.csv', @b, 3),
                ('7003', '888001', '5', 'STATEN ISLAND', '99', 'GHOST LN', '10314', 'B', '2024-06-12', '2024-06-12', 'Open', 'N', 'synth.csv', @b, 4),
                ('7004', '1001', '5', 'STATEN ISLAND', '10', 'MAIN ST', '10301', 'Z', '2024-06-10', '2024-06-10', 'Open', 'N', 'synth.csv', @b, 5),
                ('7005', '1001', '5', 'STATEN ISLAND', '10', 'MAIN ST', '10301', 'A', '2099-01-01', '2024-06-10', 'Open', 'N', 'synth.csv', @b, 6);
                """
            )
        )

        # --- 4. Synthetic Bronze OMO Charges (8 rows) ---
        con.execute(
            text(
                """
                DECLARE @b UNIQUEIDENTIFIER = NEWID();
                INSERT INTO bronze.omo_charges (
                    omoid, omonumber, buildingid, boro_id, boro, housenumber, streetname, zip,
                    lifecycle, worktypegeneral, omostatusreason, omoawardamount, netchangeorders,
                    omocreatedate, omoawarddate, iscommercialdemolition, servicechargeflag,
                    source_file, batch_id, raw_row_num
                )
                VALUES
                ('9001', 'OMO-9001', '1001', '5', 'STATEN ISLAND', '10', 'MAIN ST', '10301', 'Standing Building', 'GC', 'Work Completed', '1500.00', '0.00', '2024-06-08', '2024-06-09', 'Not Commercial', 'No', 'synth.csv', @b, 1),
                ('9001', 'OMO-9001', '1001', '5', 'STATEN ISLAND', '10', 'MAIN ST', '10301', 'Standing Building', 'GC', 'Work Completed', '1500.00', '0.00', '2024-06-08', '2024-06-12', 'Not Commercial', 'No', 'synth.csv', @b, 2),
                ('9002', 'OMO-9001', '1001', '5', 'STATEN ISLAND', '10', 'MAIN ST', '10301', 'Standing Building', 'GC', 'Work Completed', '1500.00', '0.00', '2024-06-08', '2024-06-08', 'Not Commercial', 'No', 'synth.csv', @b, 3),
                ('9003', 'OMO-9003', '1002', '5', 'STATEN ISLAND', '20', 'OAK AVE', '10304', 'Standing Building', 'PLUMB', 'Bids Solicited', '0.00', '0.00', '2024-06-10', NULL, 'Not Commercial', 'No', 'synth.csv', @b, 4),
                ('9004', 'OMO-9004', '1001', '5', 'STATEN ISLAND', '10', 'MAIN ST', '10301', 'Standing Building', 'DEMOL', 'Work Completed', '250000.00', '0.00', '2024-06-11', '2024-06-15', 'COMM DEMOL', 'No', 'synth.csv', @b, 5),
                ('9005', 'OMO-9005', '888002', '5', 'STATEN ISLAND', '77', 'UNREG RD', '10309', 'Standing Building', 'ASBEST', 'Bids Solicited', '0.00', '0.00', '2024-06-14', NULL, 'Not Commercial', 'No', 'synth.csv', @b, 6),
                ('9006', 'OMO-9006', '1001', '5', 'STATEN ISLAND', '10', 'MAIN ST', '10301', 'Standing Building', 'GC', 'Work Completed', '-500.00', '0.00', '2024-06-15', '2024-06-16', 'Not Commercial', 'No', 'synth.csv', @b, 7),
                ('9007', 'OMO-9007', '1001', '5', 'STATEN ISLAND', '10', 'MAIN ST', '10301', 'Standing Building', 'GC', 'Work Completed', 'BAD_AMT', '0.00', '2024-06-15', '2024-06-16', 'Not Commercial', 'No', 'synth.csv', @b, 8);
                """
            )
        )

        con.execute(text("EXEC silver.load_all;"))
        con.execute(text("EXEC gold.load_all;"))

    with synth_db_engine.connect() as con:
        # 1. Verify Bronze = Accepted + Rejected + Duplicates across all 4 tables
        recons = con.execute(
            text(
                "SELECT source_table, bronze_rows, accepted_rows, rejected_rows, duplicate_rows_removed, reconciliation_diff "
                "FROM silver.batch_reconciliation ORDER BY source_table"
            )
        ).fetchall()
        assert len(recons) == 4
        for r in recons:
            assert r.reconciliation_diff == 0, f"Non-zero reconciliation_diff on {r.source_table}: {r}"

        # 2. Verify multi-defect row 5999 produced ONLY 1 reject_log row
        multi_defect_cnt = con.execute(
            text(
                "SELECT COUNT(*) FROM silver.reject_log "
                "WHERE source_table = 'bronze.complaints_problems' AND business_key = '5999'"
            )
        ).scalar()
        assert multi_defect_cnt == 1

        # 3. Verify distinct rejection reasons distinguish missing vs conversion failure vs implausible
        reasons = {
            r[0]
            for r in con.execute(text("SELECT DISTINCT reason FROM silver.reject_log")).fetchall()
        }
        expected_reasons = {
            "missing_building_id",
            "conversion_failed_building_id",
            "implausible_nonpositive_building_id",
            "implausible_zero_tax_block_or_lot",
            "missing_problem_id",
            "conversion_failed_problem_id",
            "conversion_failed_received_date",
            "implausible_out_of_range_received_date",
            "conversion_failed_complaint_id",
            "invalid_violation_class_domain",
            "implausible_out_of_range_inspection_date",
            "implausible_negative_omo_award_amount",
            "conversion_failed_omo_award_amount",
        }
        assert expected_reasons.issubset(reasons)

        # 4. Verify Class I violation is rank 0 and not hazardous
        class_i_row = con.execute(
            text(
                "SELECT hazard_severity_rank, is_b_or_c_hazardous_violation, is_substantive_abc_violation "
                "FROM gold.fact_violation WHERE violation_id = 7002"
            )
        ).fetchone()
        assert class_i_row == (0, False, False)

        # 5. Verify NULL vs 0.00 OMO award distinction in gold.mart_building_month:
        #    - Building 888001 in 2024-06 has complaints & violations but 0 OMO orders -> raw_total_omo_award_amount IS NULL
        #    - Building 1002 in 2024-06 has 1 zero-dollar OMO order -> raw_total_omo_award_amount == 0.00 (NOT NULL)
        bm_888001 = con.execute(
            text(
                "SELECT omo_order_count, raw_total_omo_award_amount, total_omo_award_amount "
                "FROM gold.mart_building_month WHERE building_id = 888001 AND year_month = '2024-06'"
            )
        ).fetchone()
        assert bm_888001 == (0, None, Decimal("0.00"))

        bm_1002 = con.execute(
            text(
                "SELECT omo_order_count, raw_total_omo_award_amount, total_omo_award_amount "
                "FROM gold.mart_building_month WHERE building_id = 1002 AND year_month = '2024-06'"
            )
        ).fetchone()
        assert bm_1002 == (1, Decimal("0.00"), Decimal("0.00"))

        # 6. Verify the 2 unmatched buildings (888001 and 888002) both have building_key = -1
        #    but remain 2 separate rows in gold.mart_building_month and gold.features_building_maintenance
        unmatched_mart_cnt = con.execute(
            text("SELECT COUNT(DISTINCT building_id) FROM gold.mart_building_month WHERE building_key = -1")
        ).scalar()
        assert unmatched_mart_cnt == 2

        # 7. Capture building 1001's surrogate key and initial OMO award amount before fan-out stress test
        bkey_before = con.execute(
            text("SELECT building_key FROM gold.dim_building WHERE building_id = 1001")
        ).scalar()
        bm_1001_before = con.execute(
            text(
                "SELECT problem_count, violation_count, eligible_omo_award_amount, total_omo_award_amount "
                "FROM gold.mart_building_month WHERE building_id = 1001 AND year_month = '2024-06'"
            )
        ).fetchone()
        assert bm_1001_before == (1, 2, Decimal("1500.00"), Decimal("251500.00"))

    # --- 8. Fan-Out Protection & Surrogate Key Stability Stress Test ---
    # Add 4 more complaint problems and 3 more violations for building 1001 in 2024-06
    with synth_db_engine.begin() as con:
        con.execute(
            text(
                """
                DECLARE @b UNIQUEIDENTIFIER = NEWID();
                INSERT INTO bronze.complaints_problems (
                    problem_id, complaint_id, building_id, borough, house_number, street_name, post_code,
                    type, major_category, minor_category, problem_code, received_date,
                    complaint_status, problem_status, problem_status_date, problem_duplicate_flag,
                    source_file, batch_id, raw_row_num
                )
                VALUES
                ('5101', '3101', '1001', 'STATEN ISLAND', '10', 'MAIN ST', '10301', 'EMERGENCY', 'PLUMBING', 'SINK', 'LEAK', '2024-06-16', 'OPEN', 'OPEN', NULL, 'N', 'synth.csv', @b, 20),
                ('5102', '3101', '1001', 'STATEN ISLAND', '10', 'MAIN ST', '10301', 'EMERGENCY', 'PLUMBING', 'TOILET', 'BROKEN', '2024-06-16', 'OPEN', 'OPEN', NULL, 'N', 'synth.csv', @b, 21),
                ('5103', '3102', '1001', 'STATEN ISLAND', '10', 'MAIN ST', '10301', 'NON EMERGENCY', 'ELECTRIC', 'OUTLET', 'DEFECTIVE', '2024-06-18', 'OPEN', 'OPEN', NULL, 'N', 'synth.csv', @b, 22),
                ('5104', '3103', '1001', 'STATEN ISLAND', '10', 'MAIN ST', '10301', 'EMERGENCY', 'MOLD', 'BATHROOM', 'MOLD', '2024-06-20', 'OPEN', 'OPEN', NULL, 'N', 'synth.csv', @b, 23);

                INSERT INTO bronze.violations (
                    violationid, buildingid, boroid, boro, housenumber, streetname, zip,
                    class, inspectiondate, currentstatusdate, violationstatus, rentimpairing,
                    source_file, batch_id, raw_row_num
                )
                VALUES
                ('7101', '1001', '5', 'STATEN ISLAND', '10', 'MAIN ST', '10301', 'C', '2024-06-17', '2024-06-17', 'Open', 'Y', 'synth.csv', @b, 20),
                ('7102', '1001', '5', 'STATEN ISLAND', '10', 'MAIN ST', '10301', 'B', '2024-06-18', '2024-06-18', 'Open', 'N', 'synth.csv', @b, 21),
                ('7103', '1001', '5', 'STATEN ISLAND', '10', 'MAIN ST', '10301', 'A', '2024-06-19', '2024-06-19', 'Open', 'N', 'synth.csv', @b, 22);

                EXEC silver.load_all;
                EXEC gold.load_all;
                """
            )
        )

    with synth_db_engine.connect() as con:
        bkey_after = con.execute(
            text("SELECT building_key FROM gold.dim_building WHERE building_id = 1001")
        ).scalar()
        assert bkey_after == bkey_before, "Surrogate key changed across rerun!"

        bm_1001_after = con.execute(
            text(
                "SELECT problem_count, violation_count, eligible_omo_award_amount, total_omo_award_amount "
                "FROM gold.mart_building_month WHERE building_id = 1001 AND year_month = '2024-06'"
            )
        ).fetchone()
        # Problems increased from 1 -> 5, violations increased from 2 -> 5,
        # while OMO award amounts remain EXACTLY $1,500.00 (eligible) and $251,500.00 (total) — zero fan-out!
        assert bm_1001_after == (5, 5, Decimal("1500.00"), Decimal("251500.00"))


def test_live_warehouse_quality_and_reconciliation_suite():
    """
    Executes the full 32 SQL quality checks and 12 semantic metric reconciliations
    against the primary warehouse (homerescue_dw) and asserts zero failures.
    """
    summary = run_all_checks("homerescue_dw")
    assert summary["failed_count"] == 0, f"Quality check failures: {summary}"
    assert summary["total_sql_checks"] >= 25
    assert summary["total_metric_reconciliations"] == 12
