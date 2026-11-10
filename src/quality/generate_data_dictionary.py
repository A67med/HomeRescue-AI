from __future__ import annotations

import csv
from pathlib import Path
from sqlalchemy import text
from src.db import get_engine


SOURCE_MAP = {
    "audit.load_log": "Warehouse execution runtime telemetry",
    "bronze.buildings": "NYC Open Data kj4p-ruqc (data/raw/buildings.csv)",
    "bronze.complaints_problems": "NYC Open Data ygpa-z7cr (data/raw/complaints_problems.csv)",
    "bronze.violations": "NYC Open Data wvxf-dwi5 (data/raw/violations.csv)",
    "bronze.omo_charges": "NYC Open Data mdbu-nrqn (data/raw/omo_charges.csv)",
    "silver.building": "bronze.buildings",
    "silver.complaint_problem": "bronze.complaints_problems",
    "silver.violation": "bronze.violations",
    "silver.omo_charge": "bronze.omo_charges",
    "silver.reject_log": "Silver validation & rejection pipeline",
    "silver.duplicate_log": "Silver deduplication pipeline",
    "silver.batch_reconciliation": "Silver row conservation audit",
    "gold.dim_building": "silver.building + unknown member (-1)",
    "gold.dim_date": "Generated calendar spine (2020-01-01..2026-12-31) + unknown (-1)",
    "gold.fact_complaint_problem": "silver.complaint_problem + gold.dim_building + gold.dim_date",
    "gold.fact_violation": "silver.violation + gold.dim_building + gold.dim_date",
    "gold.fact_repair_order": "silver.omo_charge + gold.dim_building + gold.dim_date",
    "gold.mart_building_month": "Pre-aggregated gold.fact_complaint_problem, gold.fact_violation, gold.fact_repair_order",
    "gold.features_building_maintenance": "gold.dim_building + gold.mart_building_month + gold.fact_*",
    "semantic.metric_catalog": "semantic/metrics.yml via src.semantic.sync_metrics",
    "semantic.v_building_priority_ranking": "gold.features_building_maintenance",
    "semantic.v_monthly_borough_summary": "gold.dim_date + gold.fact_* + gold.mart_building_month",
    "semantic.v_zip_code_maintenance_summary": "gold.features_building_maintenance",
    "semantic.v_violation_hazard_breakdown": "gold.fact_violation",
    "semantic.v_omo_repair_cohort_summary": "gold.fact_repair_order",
    "semantic.v_unmatched_building_audit": "gold.features_building_maintenance + silver.*",
}


COLUMN_DEFINITIONS = {
    "building_key": ("Persistent surrogate key for building dimension (-1 for unregistered/unmatched buildings)", "NOT NULL; PK/FK to gold.dim_building; immutable across reruns"),
    "building_id": ("Normalized NYC HPD building business identifier (INT)", "NOT NULL; > 0 for registered buildings (-1 on unknown dimension row)"),
    "buildingid": ("Raw building identifier text as received from NYC Open Data", "Raw text preserved in Bronze; parsed to INT > 0 in Silver"),
    "problem_id": ("Atomic HPD complaint problem identifier (natural key of complaint problems)", "NOT NULL; unique BIGINT > 0"),
    "complaint_id": ("Parent HPD complaint identifier grouping one or more problem_id rows", "NOT NULL; BIGINT > 0; COUNT(DISTINCT complaint_id) <= COUNT(problem_id)"),
    "violation_id": ("Atomic HPD Housing Maintenance Code violation identifier", "NOT NULL; unique BIGINT > 0"),
    "violationid": ("Raw HPD violation identifier text as received from NYC Open Data", "Raw text preserved in Bronze; parsed to BIGINT > 0 in Silver"),
    "omo_id": ("Atomic Open Market Order identifier (natural primary key of repair orders)", "NOT NULL; unique BIGINT > 0"),
    "omoid": ("Raw Open Market Order identifier text as received from NYC Open Data", "Raw text preserved in Bronze; parsed to BIGINT > 0 in Silver"),
    "omo_number": ("Alphanumeric HPD Open Market Order number preserved as text", "NOT NULL; unique VARCHAR; never cast to integer"),
    "omonumber": ("Raw Open Market Order number text as received from NYC Open Data", "Raw text preserved in Bronze; unique in Silver/Gold"),
    "date_key": ("Integer calendar date surrogate key (YYYYMMDD, or -1 for unknown/missing optional date)", "NOT NULL; PK/FK to gold.dim_date"),
    "received_date": ("Date HPD received the complaint problem", "NOT NULL; plausible range 1900-01-01..current date"),
    "inspection_date": ("Date HPD inspected the building for the violation", "NOT NULL; plausible range 1900-01-01..current date"),
    "omo_create_date": ("Date the Open Market Order was created by HPD", "NOT NULL; plausible range 1900-01-01..current date"),
    "omo_award_date": ("Date the Open Market Order contract was awarded (NULL if un-awarded/cancelled)", "Optional DATE; NULL on zero-dollar un-awarded orders"),
    "violation_class": ("NYC Housing Maintenance Code violation class: A (non-hazardous), B (hazardous), C (immediately hazardous), I (informational/administrative order)", "NOT NULL; domain IN ('A','B','C','I')"),
    "hazard_severity_rank": ("Ordinal hazard severity rank: C=3, B=2, A=1, I=0 (Class I is never ranked above C)", "NOT NULL; domain IN (0,1,2,3)"),
    "is_eligible_repair_cohort": ("Flag (1/0) indicating whether the OMO order belongs to the eligible residential building repair cohort (excluding demolitions, duplicates, and un-awarded $0 orders)", "NOT NULL BIT (0 or 1)"),
    "repair_cohort_category": ("Explicit cohort classification explaining inclusion or exclusion reason for OMO orders", "NOT NULL VARCHAR"),
    "financial_value_status": ("Classification of OMOAwardAmount (positive_award vs zero_dollar_un_awarded_or_cancelled)", "NOT NULL VARCHAR"),
    "omo_award_amount": ("Awarded contract/order dollar amount (OMOAwardAmount); represents contract award, not paid invoice disbursement or preventive savings", "DECIMAL(18,2) >= 0.00"),
    "eligible_omo_award_amount": ("Awarded contract dollar amount restricted to eligible residential building repair orders (is_eligible_repair_cohort = 1)", "DECIMAL(18,2); reconciled with zero fan-out"),
    "raw_total_omo_award_amount": ("Nullable sum of OMO award amounts in a building-month (NULL when 0 OMO orders exist, 0.00 when only $0 orders exist)", "Nullable DECIMAL(18,2) preserving NULL vs 0.00"),
    "raw_eligible_omo_award_amount": ("Nullable sum of eligible OMO repair award amounts (NULL when 0 eligible repair orders exist)", "Nullable DECIMAL(18,2) preserving NULL vs 0.00"),
    "is_registered_building": ("Flag (1/0) indicating whether building_id exists in silver.building (1=registered, 0=unregistered retained via building_key=-1)", "NOT NULL BIT"),
    "maintenance_priority_score": ("Composite hazard priority score: 5*Class_C + 3*Class_B + 2*Open_Violations + 4*Rent_Impairing + 1*Emergency_Problems (Class I weight = 0)", "Deterministic non-negative integer score"),
    "maintenance_priority_tier": ("Priority tier (Tier 1 Critical >=100, Tier 2 High 25-99, Tier 3 Moderate 1-24, Tier 4 Low/Non-Hazardous 0, Tier 5 Zero 2024 Events)", "NOT NULL VARCHAR"),
    "intervention_gap_status": ("Cross-classification of building hazard priority tier vs presence of eligible 2024 OMO repair orders", "NOT NULL VARCHAR"),
}


def generate_dictionary() -> int:
    engine = get_engine()
    query = text(
        """
        SELECT
            s.name AS schema_name,
            o.name AS object_name,
            o.type_desc AS object_type,
            c.column_id,
            c.name AS column_name,
            UPPER(t.name) + CASE
                WHEN t.name IN ('varchar', 'nvarchar', 'char', 'nchar')
                    THEN '(' + CASE WHEN c.max_length = -1 THEN 'MAX'
                                    WHEN t.name IN ('nvarchar', 'nchar') THEN CAST(c.max_length / 2 AS VARCHAR(10))
                                    ELSE CAST(c.max_length AS VARCHAR(10)) END + ')'
                WHEN t.name IN ('decimal', 'numeric')
                    THEN '(' + CAST(c.precision AS VARCHAR(10)) + ',' + CAST(c.scale AS VARCHAR(10)) + ')'
                ELSE ''
            END AS data_type,
            c.is_nullable
        FROM sys.objects o
        INNER JOIN sys.schemas s ON o.schema_id = s.schema_id
        INNER JOIN sys.columns c ON o.object_id = c.object_id
        INNER JOIN sys.types t ON c.user_type_id = t.user_type_id
        WHERE s.name IN ('audit', 'bronze', 'silver', 'gold', 'semantic')
          AND o.type IN ('U', 'V')
          AND o.name NOT LIKE 'stg_%'
          AND o.name NOT LIKE 'v_%_load'
        ORDER BY
            CASE s.name
                WHEN 'audit' THEN 1
                WHEN 'bronze' THEN 2
                WHEN 'silver' THEN 3
                WHEN 'gold' THEN 4
                WHEN 'semantic' THEN 5
                ELSE 6
            END,
            o.name,
            c.column_id;
        """
    )

    rows_out = []
    with engine.connect() as con:
        db_rows = con.execute(query).fetchall()
        for r in db_rows:
            schema_name = r.schema_name
            obj_name = r.object_name
            col_name = r.column_name
            dtype = r.data_type
            nullable = "yes" if r.is_nullable else "no"
            full_table = f"{schema_name}.{obj_name}"
            source = SOURCE_MAP.get(full_table, f"{schema_name} layer transformation")

            if col_name in COLUMN_DEFINITIONS:
                defn, qrule = COLUMN_DEFINITIONS[col_name]
            elif schema_name == "bronze":
                if col_name in ("bronze_row_id", "raw_row_num", "source_dataset_id", "source_file", "batch_id", "ingested_at"):
                    defn = f"Bronze ingestion provenance and lineage column ({col_name})"
                    qrule = "NOT NULL; populated during Bronze staging load"
                else:
                    defn = f"Raw source attribute '{col_name}' preserved verbatim as text from {source}"
                    qrule = "none (raw text fidelity preserved in Bronze)"
            elif schema_name == "silver":
                defn = f"Cleaned and standardized Silver attribute '{col_name}' in {full_table}"
                qrule = "Typed via TRY_CONVERT and domain-validated in Silver" if nullable == "yes" else "Required NOT NULL; validated in Silver"
            elif schema_name == "gold":
                defn = f"Analytical Gold dimension/fact/mart attribute '{col_name}' in {full_table}"
                qrule = "Grain-aligned and reconciled against Silver"
            else:
                defn = f"Governed semantic layer attribute or metric '{col_name}' in {full_table}"
                qrule = "Reconciled against semantic.metric_catalog and Silver validation queries"

            rows_out.append(
                {
                    "layer": schema_name,
                    "table": full_table,
                    "column": col_name,
                    "data_type": dtype,
                    "definition": defn,
                    "source": source,
                    "pii_flag": "no",
                    "nullable": nullable,
                    "quality_rule": qrule,
                }
            )

    out_path = Path("docs/data_dictionary.csv")
    with out_path.open("w", newline="", encoding="utf-8") as f:
        writer = csv.DictWriter(
            f,
            fieldnames=["layer", "table", "column", "data_type", "definition", "source", "pii_flag", "nullable", "quality_rule"],
        )
        writer.writeheader()
        writer.writerows(rows_out)

    print(f"Generated docs/data_dictionary.csv with {len(rows_out)} documented columns across {len(SOURCE_MAP)} objects.")
    return len(rows_out)


if __name__ == "__main__":
    generate_dictionary()
