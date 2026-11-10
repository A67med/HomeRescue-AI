-- =============================================================================
-- src/quality/checks.sql
-- HomeRescue AI Data Warehouse — Automated Quality & Reconciliation Checks
-- Every "-- check: <name>" query MUST return ZERO rows to PASS.
-- Executed via: python -m src.quality.run_checks
-- =============================================================================

-- check: bronze_to_silver_building_conservation
SELECT 'building_conservation_mismatch' AS problem
WHERE (SELECT COUNT_BIG(*) FROM bronze.buildings)
   <> (SELECT COUNT_BIG(*) FROM silver.building)
    + (SELECT COUNT_BIG(*) FROM silver.reject_log WHERE source_table = 'bronze.buildings')
    + (SELECT COUNT_BIG(*) FROM silver.duplicate_log WHERE source_table = 'bronze.buildings');

-- check: bronze_to_silver_complaint_problem_conservation
SELECT 'complaint_problem_conservation_mismatch' AS problem
WHERE (SELECT COUNT_BIG(*) FROM bronze.complaints_problems)
   <> (SELECT COUNT_BIG(*) FROM silver.complaint_problem)
    + (SELECT COUNT_BIG(*) FROM silver.reject_log WHERE source_table = 'bronze.complaints_problems')
    + (SELECT COUNT_BIG(*) FROM silver.duplicate_log WHERE source_table = 'bronze.complaints_problems');

-- check: bronze_to_silver_violation_conservation
SELECT 'violation_conservation_mismatch' AS problem
WHERE (SELECT COUNT_BIG(*) FROM bronze.violations)
   <> (SELECT COUNT_BIG(*) FROM silver.violation)
    + (SELECT COUNT_BIG(*) FROM silver.reject_log WHERE source_table = 'bronze.violations')
    + (SELECT COUNT_BIG(*) FROM silver.duplicate_log WHERE source_table = 'bronze.violations');

-- check: bronze_to_silver_omo_charge_conservation
SELECT 'omo_charge_conservation_mismatch' AS problem
WHERE (SELECT COUNT_BIG(*) FROM bronze.omo_charges)
   <> (SELECT COUNT_BIG(*) FROM silver.omo_charge)
    + (SELECT COUNT_BIG(*) FROM silver.reject_log WHERE source_table = 'bronze.omo_charges')
    + (SELECT COUNT_BIG(*) FROM silver.duplicate_log WHERE source_table = 'bronze.omo_charges');

-- check: silver_batch_reconciliation_zero_diff
SELECT source_table, reconciliation_diff
FROM silver.batch_reconciliation
WHERE reconciliation_diff <> 0;

-- check: silver_reject_log_unique_bronze_row_per_source
SELECT source_table, bronze_row_id, COUNT(*) AS reject_entries
FROM silver.reject_log
GROUP BY source_table, bronze_row_id
HAVING COUNT(*) > 1;

-- check: silver_building_id_unique
SELECT building_id
FROM silver.building
GROUP BY building_id
HAVING COUNT(*) > 1;

-- check: silver_problem_id_unique
SELECT problem_id
FROM silver.complaint_problem
GROUP BY problem_id
HAVING COUNT(*) > 1;

-- check: silver_violation_id_unique
SELECT violation_id
FROM silver.violation
GROUP BY violation_id
HAVING COUNT(*) > 1;

-- check: silver_omo_id_unique
SELECT omo_id
FROM silver.omo_charge
GROUP BY omo_id
HAVING COUNT(*) > 1;

-- check: silver_omo_number_unique
SELECT omo_number
FROM silver.omo_charge
GROUP BY omo_number
HAVING COUNT(*) > 1;

-- check: gold_dim_building_key_unique
SELECT building_key
FROM gold.dim_building
GROUP BY building_key
HAVING COUNT(*) > 1;

-- check: gold_dim_building_id_unique
SELECT building_id
FROM gold.dim_building
GROUP BY building_id
HAVING COUNT(*) > 1;

-- check: gold_dim_date_key_unique
SELECT date_key
FROM gold.dim_date
GROUP BY date_key
HAVING COUNT(*) > 1;

-- check: gold_fact_complaint_problem_unique
SELECT problem_id
FROM gold.fact_complaint_problem
GROUP BY problem_id
HAVING COUNT(*) > 1;

-- check: gold_fact_violation_unique
SELECT violation_id
FROM gold.fact_violation
GROUP BY violation_id
HAVING COUNT(*) > 1;

-- check: gold_fact_repair_order_unique
SELECT omo_id
FROM gold.fact_repair_order
GROUP BY omo_id
HAVING COUNT(*) > 1;

-- check: gold_fact_repair_order_number_unique
SELECT omo_number
FROM gold.fact_repair_order
GROUP BY omo_number
HAVING COUNT(*) > 1;

-- check: gold_mart_building_month_grain_unique
SELECT building_id, year_month
FROM gold.mart_building_month
GROUP BY building_id, year_month
HAVING COUNT(*) > 1;

-- check: complaint_vs_problem_grain_hierarchy
SELECT 'invalid_complaint_problem_hierarchy' AS problem
WHERE (SELECT COUNT(DISTINCT complaint_id) FROM gold.fact_complaint_problem)
    > (SELECT COUNT(DISTINCT problem_id) FROM gold.fact_complaint_problem)
   OR (SELECT COUNT(DISTINCT complaint_id) FROM gold.fact_complaint_problem)
    = (SELECT COUNT(DISTINCT problem_id) FROM gold.fact_complaint_problem);

-- check: violation_class_domain_valid
SELECT violation_id, violation_class
FROM gold.fact_violation
WHERE violation_class NOT IN ('A', 'B', 'C', 'I')
   OR violation_class IS NULL;

-- check: violation_class_i_not_ranked_above_c
SELECT violation_id, violation_class, hazard_severity_rank, is_b_or_c_hazardous_violation
FROM gold.fact_violation
WHERE (violation_class = 'I' AND (hazard_severity_rank <> 0 OR is_b_or_c_hazardous_violation <> 0 OR is_substantive_abc_violation <> 0))
   OR (violation_class = 'C' AND hazard_severity_rank <> 3)
   OR (violation_class = 'B' AND hazard_severity_rank <> 2)
   OR (violation_class = 'A' AND hazard_severity_rank <> 1);

-- check: plausible_date_ranges_all_tables
SELECT 'implausible_dates_found' AS problem
WHERE EXISTS (
    SELECT 1 FROM silver.complaint_problem
    WHERE received_date < '1900-01-01' OR received_date > CAST(SYSDATETIME() AS DATE)
)
OR EXISTS (
    SELECT 1 FROM silver.violation
    WHERE inspection_date < '1900-01-01' OR inspection_date > CAST(SYSDATETIME() AS DATE)
)
OR EXISTS (
    SELECT 1 FROM silver.omo_charge
    WHERE omo_create_date < '1900-01-01' OR omo_create_date > CAST(SYSDATETIME() AS DATE)
);

-- check: omo_no_negative_award_amounts
SELECT omo_id, omo_award_amount
FROM silver.omo_charge
WHERE omo_award_amount < 0 OR omo_award_amount IS NULL;

-- check: omo_eligible_cohort_excludes_demolitions_and_zero_dollar
SELECT omo_id, work_type_general, lifecycle, is_commercial_demolition, omo_status_reason, omo_award_amount
FROM gold.fact_repair_order
WHERE is_eligible_repair_cohort = 1
  AND (
      work_type_general = 'DEMOL'
      OR is_commercial_demolition = 'COMM DEMOL'
      OR lifecycle = 'VACANT LAND'
      OR omo_status_reason IN ('DUPLICATE OMO', 'OMO CANCELLED')
      OR omo_award_amount <= 0
      OR omo_award_date IS NULL
  );

-- check: gold_dim_building_has_unknown_member
SELECT 'missing_unknown_building_member' AS problem
WHERE NOT EXISTS (SELECT 1 FROM gold.dim_building WHERE building_key = -1 AND building_id = -1);

-- check: gold_dim_date_has_unknown_member
SELECT 'missing_unknown_date_member' AS problem
WHERE NOT EXISTS (SELECT 1 FROM gold.dim_date WHERE date_key = -1);

-- check: gold_facts_no_orphan_keys
SELECT 'orphan_keys_found' AS problem
WHERE EXISTS (SELECT 1 FROM gold.fact_complaint_problem WHERE building_key IS NULL OR received_date_key IS NULL OR received_date_key = -1)
   OR EXISTS (SELECT 1 FROM gold.fact_violation WHERE building_key IS NULL OR inspection_date_key IS NULL OR inspection_date_key = -1)
   OR EXISTS (SELECT 1 FROM gold.fact_repair_order WHERE building_key IS NULL OR omo_create_date_key IS NULL OR omo_create_date_key = -1);

-- check: gold_unmatched_buildings_retained_and_distinct
SELECT 'unmatched_buildings_collapsed_or_dropped' AS problem
WHERE (SELECT COUNT(DISTINCT building_id) FROM gold.mart_building_month WHERE building_key = -1) <> 4
   OR (SELECT COUNT(DISTINCT building_id) FROM gold.features_building_maintenance WHERE building_key = -1) <> 4;

-- check: gold_fact_counts_match_silver_counts
SELECT 'fact_count_mismatch' AS problem
WHERE (SELECT COUNT_BIG(*) FROM gold.fact_complaint_problem) <> (SELECT COUNT_BIG(*) FROM silver.complaint_problem)
   OR (SELECT COUNT_BIG(*) FROM gold.fact_violation) <> (SELECT COUNT_BIG(*) FROM silver.violation)
   OR (SELECT COUNT_BIG(*) FROM gold.fact_repair_order) <> (SELECT COUNT_BIG(*) FROM silver.omo_charge);

-- check: gold_mart_counts_match_gold_facts
SELECT 'mart_count_mismatch' AS problem
WHERE (SELECT SUM(problem_count) FROM gold.mart_building_month) <> (SELECT COUNT_BIG(*) FROM gold.fact_complaint_problem)
   OR (SELECT SUM(violation_count) FROM gold.mart_building_month) <> (SELECT COUNT_BIG(*) FROM gold.fact_violation)
   OR (SELECT SUM(omo_order_count) FROM gold.mart_building_month) <> (SELECT COUNT_BIG(*) FROM gold.fact_repair_order)
   OR (SELECT SUM(eligible_repair_order_count) FROM gold.mart_building_month) <> (SELECT SUM(CASE WHEN is_eligible_repair_cohort = 1 THEN 1 ELSE 0 END) FROM gold.fact_repair_order);

-- check: gold_mart_financial_totals_match_silver_no_fanout
SELECT 'financial_fanout_or_mismatch' AS problem
WHERE (SELECT SUM(total_omo_award_amount) FROM gold.mart_building_month) <> (SELECT SUM(omo_award_amount) FROM silver.omo_charge)
   OR (SELECT SUM(eligible_omo_award_amount) FROM gold.mart_building_month) <> (SELECT SUM(omo_award_amount) FROM silver.omo_charge WHERE is_eligible_repair_cohort = 1)
   OR (SELECT SUM(total_omo_award_amount_2024) FROM gold.features_building_maintenance) <> (SELECT SUM(omo_award_amount) FROM silver.omo_charge)
   OR (SELECT SUM(eligible_omo_award_amount_2024) FROM gold.features_building_maintenance) <> (SELECT SUM(omo_award_amount) FROM silver.omo_charge WHERE is_eligible_repair_cohort = 1);

-- check: gold_mart_null_vs_zero_omo_award_distinction
SELECT building_id, year_month, omo_order_count, raw_total_omo_award_amount, total_omo_award_amount
FROM gold.mart_building_month
WHERE (omo_order_count = 0 AND raw_total_omo_award_amount IS NOT NULL)
   OR (omo_order_count > 0 AND raw_total_omo_award_amount IS NULL)
   OR (eligible_repair_order_count = 0 AND raw_eligible_omo_award_amount IS NOT NULL)
   OR (eligible_repair_order_count > 0 AND raw_eligible_omo_award_amount IS NULL);

-- check: semantic_metric_catalog_populated
SELECT 'metric_catalog_incomplete' AS problem
WHERE (SELECT COUNT(*) FROM semantic.metric_catalog) < 12
   OR EXISTS (
       SELECT 1 FROM semantic.metric_catalog
       WHERE NULLIF(TRIM(metric_name), '') IS NULL
          OR NULLIF(TRIM(definition), '') IS NULL
          OR NULLIF(TRIM(sql_expression), '') IS NULL
          OR NULLIF(TRIM(validation_query), '') IS NULL
   );

-- check: audit_load_log_all_tables_have_matching_success_load
WITH expected_tables AS (
    SELECT 'bronze.buildings' AS target_table, (SELECT COUNT_BIG(*) FROM bronze.buildings) AS actual_rows UNION ALL
    SELECT 'bronze.complaints_problems', (SELECT COUNT_BIG(*) FROM bronze.complaints_problems) UNION ALL
    SELECT 'bronze.violations', (SELECT COUNT_BIG(*) FROM bronze.violations) UNION ALL
    SELECT 'bronze.omo_charges', (SELECT COUNT_BIG(*) FROM bronze.omo_charges) UNION ALL
    SELECT 'silver.building', (SELECT COUNT_BIG(*) FROM silver.building) UNION ALL
    SELECT 'silver.complaint_problem', (SELECT COUNT_BIG(*) FROM silver.complaint_problem) UNION ALL
    SELECT 'silver.violation', (SELECT COUNT_BIG(*) FROM silver.violation) UNION ALL
    SELECT 'silver.omo_charge', (SELECT COUNT_BIG(*) FROM silver.omo_charge) UNION ALL
    SELECT 'gold.dim_building', (SELECT COUNT_BIG(*) FROM gold.dim_building) UNION ALL
    SELECT 'gold.dim_date', (SELECT COUNT_BIG(*) FROM gold.dim_date) UNION ALL
    SELECT 'gold.fact_complaint_problem', (SELECT COUNT_BIG(*) FROM gold.fact_complaint_problem) UNION ALL
    SELECT 'gold.fact_violation', (SELECT COUNT_BIG(*) FROM gold.fact_violation) UNION ALL
    SELECT 'gold.fact_repair_order', (SELECT COUNT_BIG(*) FROM gold.fact_repair_order) UNION ALL
    SELECT 'gold.mart_building_month', (SELECT COUNT_BIG(*) FROM gold.mart_building_month)
),
latest_success AS (
    SELECT
        target_table,
        rows_loaded,
        ROW_NUMBER() OVER (PARTITION BY target_table ORDER BY load_id DESC) AS rn
    FROM audit.load_log
    WHERE status = 'SUCCESS'
)
SELECT e.target_table, e.actual_rows, s.rows_loaded
FROM expected_tables e
LEFT JOIN latest_success s
    ON e.target_table = s.target_table AND s.rn = 1
WHERE s.rows_loaded IS NULL OR s.rows_loaded <= 0 OR s.rows_loaded <> e.actual_rows;
