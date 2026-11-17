/* ============================================================================
   File: sql/04_semantic.sql
   Project: HomeRescue AI (Medallion Data Warehouse)
   Layer: Semantic Layer (Governed Metric Catalog & Business Metric Views)
   Description:
     Creates semantic.metric_catalog (synchronized from semantic/metrics.yml
     via `python -m src.semantic.sync_metrics`) and governed semantic.v_*
     business views with explicit grains and zero fan-out joins.
   ============================================================================ */

IF DB_NAME() IN (N'master', N'tempdb', N'model', N'msdb')
    USE [homerescue_dw];
GO

SET NOCOUNT ON;
GO

/* ============================================================================
   1. GOVERNED METRIC CATALOG TABLE: semantic.metric_catalog
      Populated by: python -m src.semantic.sync_metrics
   ============================================================================ */
IF OBJECT_ID('semantic.metric_catalog', 'U') IS NULL
BEGIN
    CREATE TABLE semantic.metric_catalog (
        metric_name      VARCHAR(100)  NOT NULL PRIMARY KEY,
        label            VARCHAR(200)  NULL,
        definition       VARCHAR(1000) NOT NULL,
        owner            VARCHAR(100)  NULL,
        grain            VARCHAR(200)  NULL,
        sql_expression   VARCHAR(1000) NOT NULL,
        dimensions       VARCHAR(500)  NULL,
        null_policy      VARCHAR(500)  NULL,
        validation_query VARCHAR(2000) NULL,
        updated_at       DATETIME2     NOT NULL DEFAULT SYSDATETIME()
    );
END;
GO

/* ============================================================================
   2. SEMANTIC VIEW: semantic.v_building_priority_ranking
      GRAIN: One row per building_id across all 22,333 Staten Island buildings
             (22,329 registered buildings + 4 unregistered event buildings).
      PURPOSE: Ranks buildings for maintenance review priority based on
               documented safety indicators (Class C/B violations, open
               violations, rent-impairing violations, emergency complaints)
               and identifies high-hazard buildings with zero eligible OMO
               repair orders ('HIGH_HAZARD_UNADDRESSED_BY_OMO').
   ============================================================================ */
CREATE OR ALTER VIEW semantic.v_building_priority_ranking
AS
SELECT
    DENSE_RANK() OVER (
        ORDER BY
            f.maintenance_priority_score DESC,
            f.class_c_violation_count_2024 DESC,
            f.open_hazardous_bc_violation_count_2024 DESC,
            f.emergency_problem_count_2024 DESC,
            f.building_id ASC
    ) AS priority_rank,
    f.building_id,
    f.building_key,
    f.is_registered_building,
    f.full_street_address,
    f.zip_code,
    f.community_board,
    f.management_program,
    f.dob_building_class,
    f.legal_stories,
    f.total_legal_units,
    f.unit_size_tier,
    f.active_months_2024,
    f.has_any_2024_activity,
    f.distinct_complaint_count_2024,
    f.problem_count_2024,
    f.non_duplicate_problem_count_2024,
    f.emergency_problem_count_2024,
    f.problems_per_legal_unit,
    f.violation_count_2024,
    f.class_c_violation_count_2024,
    f.class_b_violation_count_2024,
    f.class_a_violation_count_2024,
    f.class_i_violation_count_2024,
    f.hazardous_bc_violation_count_2024,
    f.open_violation_count_2024,
    f.open_hazardous_bc_violation_count_2024,
    f.rent_impairing_violation_count_2024,
    f.violation_severity_weighted_score_2024,
    f.hazardous_violations_per_legal_unit,
    f.has_omo_orders_2024,
    f.has_eligible_repair_orders_2024,
    f.omo_order_count_2024,
    f.eligible_repair_order_count_2024,
    f.excluded_omo_order_count_2024,
    f.raw_total_omo_award_amount_2024,
    f.raw_eligible_omo_award_amount_2024,
    f.total_omo_award_amount_2024,
    f.eligible_omo_award_amount_2024,
    f.excluded_omo_award_amount_2024,
    f.maintenance_priority_score,
    f.maintenance_priority_tier,
    CASE
        WHEN f.maintenance_priority_score >= 25 AND f.eligible_repair_order_count_2024 = 0
            THEN 'HIGH_HAZARD_UNADDRESSED_BY_OMO'
        WHEN f.maintenance_priority_score >= 25 AND f.eligible_repair_order_count_2024 > 0
            THEN 'HIGH_HAZARD_WITH_ELIGIBLE_OMO'
        WHEN f.maintenance_priority_score BETWEEN 1 AND 24 AND f.eligible_repair_order_count_2024 = 0
            THEN 'MODERATE_HAZARD_UNADDRESSED_BY_OMO'
        WHEN f.maintenance_priority_score BETWEEN 1 AND 24 AND f.eligible_repair_order_count_2024 > 0
            THEN 'MODERATE_HAZARD_WITH_ELIGIBLE_OMO'
        WHEN f.maintenance_priority_score = 0 AND f.eligible_repair_order_count_2024 > 0
            THEN 'LOW_HAZARD_WITH_ELIGIBLE_OMO'
        ELSE 'LOW_OR_ZERO_HAZARD_NO_OMO'
    END AS intervention_gap_status
FROM gold.features_building_maintenance f;
GO

/* ============================================================================
   3. SEMANTIC VIEW: semantic.v_monthly_borough_summary
      GRAIN: One row per calendar month in 2024 (year_month: '2024-01'..'2024-12').
      PURPOSE: Tracks seasonal trajectories of complaints, violations, and
               eligible OMO repair awards across Staten Island without fan-out.
   ============================================================================ */
CREATE OR ALTER VIEW semantic.v_monthly_borough_summary
AS
WITH cp_month AS (
    SELECT
        year_month,
        COUNT(DISTINCT building_id) AS buildings_with_complaints,
        COUNT(DISTINCT complaint_id) AS distinct_complaints,
        COUNT(problem_id) AS total_complaint_problems,
        SUM(CASE WHEN is_emergency_priority = 1 THEN 1 ELSE 0 END) AS emergency_complaint_problems,
        SUM(CASE WHEN is_duplicate_problem_flag = 0 THEN 1 ELSE 0 END) AS non_duplicate_problems
    FROM gold.fact_complaint_problem
    GROUP BY year_month
),
viol_month AS (
    SELECT
        year_month,
        COUNT(DISTINCT building_id) AS buildings_with_violations,
        COUNT(violation_id) AS total_violations,
        SUM(CASE WHEN violation_class = 'C' THEN 1 ELSE 0 END) AS class_c_violations,
        SUM(CASE WHEN violation_class = 'B' THEN 1 ELSE 0 END) AS class_b_violations,
        SUM(CASE WHEN violation_class = 'A' THEN 1 ELSE 0 END) AS class_a_violations,
        SUM(CASE WHEN violation_class = 'I' THEN 1 ELSE 0 END) AS class_i_violations,
        SUM(CASE WHEN is_b_or_c_hazardous_violation = 1 THEN 1 ELSE 0 END) AS hazardous_bc_violations,
        SUM(CASE WHEN is_open_violation = 1 THEN 1 ELSE 0 END) AS open_violations,
        SUM(CASE WHEN is_rent_impairing = 1 THEN 1 ELSE 0 END) AS rent_impairing_violations
    FROM gold.fact_violation
    GROUP BY year_month
),
ro_month AS (
    SELECT
        year_month,
        COUNT(DISTINCT building_id) AS buildings_with_omo_orders,
        COUNT(DISTINCT CASE WHEN is_eligible_repair_cohort = 1 THEN building_id END) AS buildings_with_eligible_repairs,
        COUNT(omo_id) AS total_omo_orders,
        SUM(CASE WHEN is_eligible_repair_cohort = 1 THEN 1 ELSE 0 END) AS eligible_repair_order_count,
        SUM(CASE WHEN is_eligible_repair_cohort = 0 THEN 1 ELSE 0 END) AS excluded_omo_order_count,
        SUM(omo_award_amount) AS total_all_omo_award_amount,
        ISNULL(SUM(eligible_omo_award_amount), 0.00) AS eligible_omo_award_amount,
        CAST(AVG(eligible_omo_award_amount) AS DECIMAL(18,2)) AS avg_eligible_omo_award_amount
    FROM gold.fact_repair_order
    GROUP BY year_month
),
mart_month AS (
    SELECT
        year_month,
        COUNT(DISTINCT building_id) AS total_active_buildings
    FROM gold.mart_building_month
    GROUP BY year_month
),
months_2024 AS (
    SELECT DISTINCT
        year_month,
        year_number,
        quarter_label,
        month_number,
        month_name
    FROM gold.dim_date
    WHERE is_study_window = 1
)
SELECT
    m.year_month,
    m.year_number,
    m.quarter_label,
    m.month_number,
    m.month_name,
    ISNULL(mm.total_active_buildings, 0) AS total_active_buildings,
    ISNULL(cp.buildings_with_complaints, 0) AS buildings_with_complaints,
    ISNULL(cp.distinct_complaints, 0) AS distinct_complaints,
    ISNULL(cp.total_complaint_problems, 0) AS total_complaint_problems,
    ISNULL(cp.emergency_complaint_problems, 0) AS emergency_complaint_problems,
    ISNULL(cp.non_duplicate_problems, 0) AS non_duplicate_problems,
    ISNULL(v.buildings_with_violations, 0) AS buildings_with_violations,
    ISNULL(v.total_violations, 0) AS total_violations,
    ISNULL(v.class_c_violations, 0) AS class_c_violations,
    ISNULL(v.class_b_violations, 0) AS class_b_violations,
    ISNULL(v.class_a_violations, 0) AS class_a_violations,
    ISNULL(v.class_i_violations, 0) AS class_i_violations,
    ISNULL(v.hazardous_bc_violations, 0) AS hazardous_bc_violations,
    ISNULL(v.open_violations, 0) AS open_violations,
    ISNULL(v.rent_impairing_violations, 0) AS rent_impairing_violations,
    ISNULL(ro.buildings_with_omo_orders, 0) AS buildings_with_omo_orders,
    ISNULL(ro.buildings_with_eligible_repairs, 0) AS buildings_with_eligible_repairs,
    ISNULL(ro.total_omo_orders, 0) AS total_omo_orders,
    ISNULL(ro.eligible_repair_order_count, 0) AS eligible_repair_order_count,
    ISNULL(ro.excluded_omo_order_count, 0) AS excluded_omo_order_count,
    ISNULL(ro.total_all_omo_award_amount, 0.00) AS total_all_omo_award_amount,
    ISNULL(ro.eligible_omo_award_amount, 0.00) AS eligible_omo_award_amount,
    ro.avg_eligible_omo_award_amount
FROM months_2024 m
LEFT JOIN mart_month mm ON m.year_month = mm.year_month
LEFT JOIN cp_month cp ON m.year_month = cp.year_month
LEFT JOIN viol_month v ON m.year_month = v.year_month
LEFT JOIN ro_month ro ON m.year_month = ro.year_month;
GO

/* ============================================================================
   4. SEMANTIC VIEW: semantic.v_zip_code_maintenance_summary
      GRAIN: One row per Staten Island zip_code (plus UNKNOWN for unregistered).
      PURPOSE: Compares neighborhood-level housing distress, zero-event building
               rates, hazardous violations, and eligible OMO repair awards.
   ============================================================================ */
CREATE OR ALTER VIEW semantic.v_zip_code_maintenance_summary
AS
SELECT
    f.zip_code,
    COUNT(f.building_id) AS total_buildings,
    SUM(CASE WHEN f.has_any_2024_activity = 1 THEN 1 ELSE 0 END) AS active_buildings_2024,
    SUM(CASE WHEN f.has_any_2024_activity = 0 THEN 1 ELSE 0 END) AS zero_event_buildings_2024,
    CAST(SUM(CASE WHEN f.has_any_2024_activity = 1 THEN 1 ELSE 0 END) * 100.0 / NULLIF(COUNT(f.building_id), 0) AS DECIMAL(6,2)) AS active_building_pct,
    SUM(ISNULL(f.total_legal_units, 0)) AS total_legal_units,
    SUM(f.distinct_complaint_count_2024) AS distinct_complaints_by_building,
    SUM(f.problem_count_2024) AS total_complaint_problems,
    SUM(f.emergency_problem_count_2024) AS emergency_complaint_problems,
    SUM(f.violation_count_2024) AS total_violations,
    SUM(f.class_c_violation_count_2024) AS class_c_violations,
    SUM(f.class_b_violation_count_2024) AS class_b_violations,
    SUM(f.class_a_violation_count_2024) AS class_a_violations,
    SUM(f.class_i_violation_count_2024) AS class_i_violations,
    SUM(f.hazardous_bc_violation_count_2024) AS hazardous_bc_violations,
    SUM(f.open_violation_count_2024) AS open_violations,
    SUM(f.rent_impairing_violation_count_2024) AS rent_impairing_violations,
    SUM(CASE WHEN f.maintenance_priority_score >= 25 THEN 1 ELSE 0 END) AS high_or_critical_priority_buildings,
    SUM(CASE WHEN f.maintenance_priority_score >= 25 AND f.eligible_repair_order_count_2024 = 0 THEN 1 ELSE 0 END) AS high_hazard_unaddressed_buildings,
    SUM(f.eligible_repair_order_count_2024) AS eligible_repair_order_count,
    SUM(f.eligible_omo_award_amount_2024) AS eligible_omo_award_amount,
    SUM(f.total_omo_award_amount_2024) AS total_all_omo_award_amount
FROM gold.features_building_maintenance f
GROUP BY f.zip_code;
GO

/* ============================================================================
   5. SEMANTIC VIEW: semantic.v_violation_hazard_breakdown
      GRAIN: One row per violation_class ('C', 'B', 'A', 'I').
      PURPOSE: Summarizes violation severity tiers while keeping administrative
               Class I orders separate from hazard severity ranks 1..3.
   ============================================================================ */
CREATE OR ALTER VIEW semantic.v_violation_hazard_breakdown
AS
SELECT
    v.violation_class,
    v.hazard_class_category,
    v.hazard_severity_rank,
    v.is_substantive_abc_violation,
    v.is_b_or_c_hazardous_violation,
    v.is_immediately_hazardous,
    COUNT(v.violation_id) AS total_violations,
    CAST(COUNT(v.violation_id) * 100.0 / NULLIF(SUM(COUNT(v.violation_id)) OVER (), 0) AS DECIMAL(6,2)) AS share_of_total_violations_pct,
    COUNT(DISTINCT v.building_id) AS distinct_buildings_affected,
    SUM(CASE WHEN v.is_open_violation = 1 THEN 1 ELSE 0 END) AS open_violations,
    SUM(CASE WHEN v.is_open_violation = 0 THEN 1 ELSE 0 END) AS closed_violations,
    CAST(SUM(CASE WHEN v.is_open_violation = 1 THEN 1 ELSE 0 END) * 100.0 / NULLIF(COUNT(v.violation_id), 0) AS DECIMAL(6,2)) AS open_violation_rate_pct,
    SUM(CASE WHEN v.is_rent_impairing = 1 THEN 1 ELSE 0 END) AS rent_impairing_violations,
    SUM(CASE WHEN v.is_registered_building = 1 THEN 1 ELSE 0 END) AS registered_building_violations,
    SUM(CASE WHEN v.is_registered_building = 0 THEN 1 ELSE 0 END) AS unregistered_building_violations
FROM gold.fact_violation v
GROUP BY
    v.violation_class,
    v.hazard_class_category,
    v.hazard_severity_rank,
    v.is_substantive_abc_violation,
    v.is_b_or_c_hazardous_violation,
    v.is_immediately_hazardous;
GO

/* ============================================================================
   6. SEMANTIC VIEW: semantic.v_omo_repair_cohort_summary
      GRAIN: One row per (is_eligible_repair_cohort, repair_cohort_category,
             work_type_general, financial_value_status).
      PURPOSE: Audits OMO repair cohort filtering and quantifies the $2.10M
               demolition distortion separated from eligible residential repairs.
   ============================================================================ */
CREATE OR ALTER VIEW semantic.v_omo_repair_cohort_summary
AS
SELECT
    ro.is_eligible_repair_cohort,
    ro.repair_cohort_category,
    ISNULL(ro.work_type_general, 'UNKNOWN') AS work_type_general,
    ro.financial_value_status,
    COUNT(ro.omo_id) AS omo_order_count,
    COUNT(DISTINCT ro.building_id) AS distinct_buildings,
    SUM(ro.omo_award_amount) AS total_omo_award_amount,
    CAST(SUM(ro.omo_award_amount) * 100.0 / NULLIF(SUM(SUM(ro.omo_award_amount)) OVER (), 0) AS DECIMAL(6,2)) AS share_of_total_award_pct,
    CAST(AVG(ro.omo_award_amount) AS DECIMAL(18,2)) AS avg_omo_award_amount,
    MIN(ro.omo_award_amount) AS min_omo_award_amount,
    MAX(ro.omo_award_amount) AS max_omo_award_amount,
    SUM(ISNULL(ro.net_change_orders, 0.00)) AS total_net_change_orders
FROM gold.fact_repair_order ro
GROUP BY
    ro.is_eligible_repair_cohort,
    ro.repair_cohort_category,
    ISNULL(ro.work_type_general, 'UNKNOWN'),
    ro.financial_value_status;
GO

/* ============================================================================
   7. SEMANTIC VIEW: semantic.v_unmatched_building_audit
      GRAIN: One row per unregistered building_id (building_key = -1).
      PURPOSE: Audits the 4 unmatched building_id records retained via
               building_key = -1 and proves they do not collapse together.
   ============================================================================ */
CREATE OR ALTER VIEW semantic.v_unmatched_building_audit
AS
SELECT
    f.building_id,
    f.building_key,
    f.is_registered_building,
    COALESCE(
        (SELECT TOP 1 CONCAT(ISNULL(house_number, ''), ' ', ISNULL(street_name, '')) FROM silver.complaint_problem cp WHERE cp.building_id = f.building_id),
        (SELECT TOP 1 CONCAT(ISNULL(house_number, ''), ' ', ISNULL(street_name, '')) FROM silver.omo_charge o WHERE o.building_id = f.building_id),
        'UNKNOWN ADDRESS'
    ) AS source_reported_address,
    COALESCE(
        (SELECT TOP 1 post_code FROM silver.complaint_problem cp WHERE cp.building_id = f.building_id),
        (SELECT TOP 1 zip_code FROM silver.omo_charge o WHERE o.building_id = f.building_id),
        'UNKNOWN'
    ) AS source_reported_zip,
    f.active_months_2024,
    f.distinct_complaint_count_2024,
    f.problem_count_2024,
    f.emergency_problem_count_2024,
    f.violation_count_2024,
    f.class_c_violation_count_2024,
    f.class_b_violation_count_2024,
    f.class_a_violation_count_2024,
    f.open_violation_count_2024,
    f.omo_order_count_2024,
    f.eligible_repair_order_count_2024,
    f.raw_total_omo_award_amount_2024,
    f.raw_eligible_omo_award_amount_2024,
    f.total_omo_award_amount_2024,
    f.eligible_omo_award_amount_2024,
    f.maintenance_priority_score,
    f.maintenance_priority_tier
FROM gold.features_building_maintenance f
WHERE f.is_registered_building = 0;
GO
