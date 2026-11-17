/* ============================================================================
   File: sql/05_feature_views.sql
   Project: HomeRescue AI (Medallion Data Warehouse)
   Layer: Gold Feature Views (Read-Only Descriptive Feature Views)
   Description:
     Defines grain-explicit building-level descriptive feature views across the
     entire Staten Island building population (22,329 registered buildings plus
     4 unregistered event-active buildings = 22,333 total buildings).

   TEMPORAL / SNAPSHOT DISCLOSURE:
     - All event counts cover calendar year 2024 (2024-01-01 through 2024-12-31).
     - Status attributes (such as open_violation_count_2024 and complaint/problem
       status) reflect the extracted source snapshot as of acquisition and are
       designed for descriptive maintenance prioritization, NOT reconstructed
       historical point-in-time ML training labels.
   ============================================================================ */

IF DB_NAME() IN (N'master', N'tempdb', N'model', N'msdb')
    USE [homerescue_dw];
GO

/* ============================================================================
   1. VIEW: gold.features_building_maintenance
      GRAIN: One row per building_id across all 22,333 Staten Island buildings
             (including zero-event buildings and unregistered event buildings).
   ============================================================================ */
CREATE OR ALTER VIEW gold.features_building_maintenance
AS
WITH cp_bldg AS (
    SELECT
        building_id,
        MAX(building_key) AS building_key,
        COUNT(DISTINCT complaint_id) AS distinct_complaint_count_2024,
        COUNT(problem_id) AS problem_count_2024,
        SUM(CASE WHEN is_duplicate_problem_flag = 0 THEN 1 ELSE 0 END) AS non_duplicate_problem_count_2024,
        SUM(CASE WHEN is_emergency_priority = 1 THEN 1 ELSE 0 END) AS emergency_problem_count_2024
    FROM gold.fact_complaint_problem
    GROUP BY building_id
),
viol_bldg AS (
    SELECT
        building_id,
        MAX(building_key) AS building_key,
        COUNT(violation_id) AS violation_count_2024,
        SUM(CASE WHEN violation_class = 'A' THEN 1 ELSE 0 END) AS class_a_violation_count_2024,
        SUM(CASE WHEN violation_class = 'B' THEN 1 ELSE 0 END) AS class_b_violation_count_2024,
        SUM(CASE WHEN violation_class = 'C' THEN 1 ELSE 0 END) AS class_c_violation_count_2024,
        SUM(CASE WHEN violation_class = 'I' THEN 1 ELSE 0 END) AS class_i_violation_count_2024,
        SUM(CASE WHEN is_substantive_abc_violation = 1 THEN 1 ELSE 0 END) AS substantive_abc_violation_count_2024,
        SUM(CASE WHEN is_b_or_c_hazardous_violation = 1 THEN 1 ELSE 0 END) AS hazardous_bc_violation_count_2024,
        SUM(CASE WHEN is_open_violation = 1 THEN 1 ELSE 0 END) AS open_violation_count_2024,
        SUM(CASE WHEN is_open_violation = 1 AND is_b_or_c_hazardous_violation = 1 THEN 1 ELSE 0 END) AS open_hazardous_bc_violation_count_2024,
        SUM(CASE WHEN is_rent_impairing = 1 THEN 1 ELSE 0 END) AS rent_impairing_violation_count_2024,
        SUM(hazard_severity_rank) AS violation_severity_weighted_score_2024
    FROM gold.fact_violation
    GROUP BY building_id
),
ro_bldg AS (
    SELECT
        building_id,
        MAX(building_key) AS building_key,
        COUNT(omo_id) AS omo_order_count_2024,
        SUM(CASE WHEN is_eligible_repair_cohort = 1 THEN 1 ELSE 0 END) AS eligible_repair_order_count_2024,
        SUM(CASE WHEN is_eligible_repair_cohort = 0 THEN 1 ELSE 0 END) AS excluded_omo_order_count_2024,
        SUM(omo_award_amount) AS raw_total_omo_award_amount_2024,
        SUM(eligible_omo_award_amount) AS raw_eligible_omo_award_amount_2024,
        SUM(CASE WHEN is_eligible_repair_cohort = 0 THEN omo_award_amount ELSE 0.00 END) AS excluded_omo_award_amount_2024
    FROM gold.fact_repair_order
    GROUP BY building_id
),
bm_months AS (
    SELECT
        building_id,
        COUNT(DISTINCT year_month) AS active_months_2024
    FROM gold.mart_building_month
    GROUP BY building_id
),
unregistered_buildings AS (
    SELECT DISTINCT
        m.building_id,
        -1 AS building_key,
        CAST(0 AS BIT) AS is_registered_building,
        'STATEN ISLAND' AS borough_name,
        'UNREGISTERED IN HPD BUILDINGS' AS full_street_address,
        'UNKNOWN' AS zip_code,
        CAST(NULL AS INT) AS community_board,
        'UNREGISTERED' AS management_program,
        'UNREGISTERED' AS dob_building_class,
        CAST(NULL AS INT) AS legal_stories,
        CAST(NULL AS INT) AS total_legal_units,
        'UNKNOWN / 0 UNITS' AS unit_size_tier,
        CAST(0 AS BIT) AS is_active_building
    FROM gold.mart_building_month m
    WHERE m.building_key = -1
),
building_spine AS (
    SELECT
        d.building_id,
        d.building_key,
        d.is_registered_building,
        d.borough_name,
        d.full_street_address,
        d.zip_code,
        d.community_board,
        d.management_program,
        d.dob_building_class,
        d.legal_stories,
        d.total_legal_units,
        d.unit_size_tier,
        d.is_active_building
    FROM gold.dim_building d
    WHERE d.building_key <> -1
    UNION ALL
    SELECT
        u.building_id,
        u.building_key,
        u.is_registered_building,
        u.borough_name,
        u.full_street_address,
        u.zip_code,
        u.community_board,
        u.management_program,
        u.dob_building_class,
        u.legal_stories,
        u.total_legal_units,
        u.unit_size_tier,
        u.is_active_building
    FROM unregistered_buildings u
)
SELECT
    b.building_id,
    b.building_key,
    b.is_registered_building,
    b.borough_name,
    b.full_street_address,
    b.zip_code,
    b.community_board,
    b.management_program,
    b.dob_building_class,
    b.legal_stories,
    b.total_legal_units,
    b.unit_size_tier,
    b.is_active_building,
    ISNULL(m.active_months_2024, 0) AS active_months_2024,
    CAST(CASE WHEN ISNULL(m.active_months_2024, 0) > 0 THEN 1 ELSE 0 END AS BIT) AS has_any_2024_activity,
    -- Complaint & Problem metrics
    ISNULL(cp.distinct_complaint_count_2024, 0) AS distinct_complaint_count_2024,
    ISNULL(cp.problem_count_2024, 0) AS problem_count_2024,
    ISNULL(cp.non_duplicate_problem_count_2024, 0) AS non_duplicate_problem_count_2024,
    ISNULL(cp.emergency_problem_count_2024, 0) AS emergency_problem_count_2024,
    CASE
        WHEN b.total_legal_units IS NOT NULL AND b.total_legal_units > 0
        THEN CAST(ISNULL(cp.problem_count_2024, 0) * 1.0 / b.total_legal_units AS DECIMAL(10,4))
        ELSE NULL
    END AS problems_per_legal_unit,
    -- Violation metrics
    ISNULL(v.violation_count_2024, 0) AS violation_count_2024,
    ISNULL(v.class_a_violation_count_2024, 0) AS class_a_violation_count_2024,
    ISNULL(v.class_b_violation_count_2024, 0) AS class_b_violation_count_2024,
    ISNULL(v.class_c_violation_count_2024, 0) AS class_c_violation_count_2024,
    ISNULL(v.class_i_violation_count_2024, 0) AS class_i_violation_count_2024,
    ISNULL(v.substantive_abc_violation_count_2024, 0) AS substantive_abc_violation_count_2024,
    ISNULL(v.hazardous_bc_violation_count_2024, 0) AS hazardous_bc_violation_count_2024,
    ISNULL(v.open_violation_count_2024, 0) AS open_violation_count_2024,
    ISNULL(v.open_hazardous_bc_violation_count_2024, 0) AS open_hazardous_bc_violation_count_2024,
    ISNULL(v.rent_impairing_violation_count_2024, 0) AS rent_impairing_violation_count_2024,
    ISNULL(v.violation_severity_weighted_score_2024, 0) AS violation_severity_weighted_score_2024,
    CASE
        WHEN b.total_legal_units IS NOT NULL AND b.total_legal_units > 0
        THEN CAST(ISNULL(v.hazardous_bc_violation_count_2024, 0) * 1.0 / b.total_legal_units AS DECIMAL(10,4))
        ELSE NULL
    END AS hazardous_violations_per_legal_unit,
    -- OMO Repair Order metrics (preserving NULL vs 0.00 distinction)
    CAST(CASE WHEN ISNULL(ro.omo_order_count_2024, 0) > 0 THEN 1 ELSE 0 END AS BIT) AS has_omo_orders_2024,
    CAST(CASE WHEN ISNULL(ro.eligible_repair_order_count_2024, 0) > 0 THEN 1 ELSE 0 END AS BIT) AS has_eligible_repair_orders_2024,
    ISNULL(ro.omo_order_count_2024, 0) AS omo_order_count_2024,
    ISNULL(ro.eligible_repair_order_count_2024, 0) AS eligible_repair_order_count_2024,
    ISNULL(ro.excluded_omo_order_count_2024, 0) AS excluded_omo_order_count_2024,
    ro.raw_total_omo_award_amount_2024,
    ro.raw_eligible_omo_award_amount_2024,
    ISNULL(ro.raw_total_omo_award_amount_2024, 0.00) AS total_omo_award_amount_2024,
    ISNULL(ro.raw_eligible_omo_award_amount_2024, 0.00) AS eligible_omo_award_amount_2024,
    ISNULL(ro.excluded_omo_award_amount_2024, 0.00) AS excluded_omo_award_amount_2024,
    -- Composite Maintenance Review Priority Score (grounded in documented hazard indicators; Class I weight = 0)
    (
        5 * ISNULL(v.class_c_violation_count_2024, 0)
      + 3 * ISNULL(v.class_b_violation_count_2024, 0)
      + 2 * ISNULL(v.open_violation_count_2024, 0)
      + 4 * ISNULL(v.rent_impairing_violation_count_2024, 0)
      + 1 * ISNULL(cp.emergency_problem_count_2024, 0)
    ) AS maintenance_priority_score,
    CASE
        WHEN (
            5 * ISNULL(v.class_c_violation_count_2024, 0)
          + 3 * ISNULL(v.class_b_violation_count_2024, 0)
          + 2 * ISNULL(v.open_violation_count_2024, 0)
          + 4 * ISNULL(v.rent_impairing_violation_count_2024, 0)
          + 1 * ISNULL(cp.emergency_problem_count_2024, 0)
        ) >= 100 THEN 'TIER 1 - CRITICAL PRIORITY (SCORE >= 100)'
        WHEN (
            5 * ISNULL(v.class_c_violation_count_2024, 0)
          + 3 * ISNULL(v.class_b_violation_count_2024, 0)
          + 2 * ISNULL(v.open_violation_count_2024, 0)
          + 4 * ISNULL(v.rent_impairing_violation_count_2024, 0)
          + 1 * ISNULL(cp.emergency_problem_count_2024, 0)
        ) >= 25 THEN 'TIER 2 - HIGH PRIORITY (SCORE 25-99)'
        WHEN (
            5 * ISNULL(v.class_c_violation_count_2024, 0)
          + 3 * ISNULL(v.class_b_violation_count_2024, 0)
          + 2 * ISNULL(v.open_violation_count_2024, 0)
          + 4 * ISNULL(v.rent_impairing_violation_count_2024, 0)
          + 1 * ISNULL(cp.emergency_problem_count_2024, 0)
        ) >= 1 THEN 'TIER 3 - MODERATE / MONITORED (SCORE 1-24)'
        WHEN ISNULL(m.active_months_2024, 0) > 0 THEN 'TIER 4 - LOW / NON-HAZARDOUS ACTIVITY ONLY (SCORE 0)'
        ELSE 'TIER 5 - ZERO 2024 EVENTS'
    END AS maintenance_priority_tier,
    '2024_ANNUAL_DESCRIPTIVE_SNAPSHOT' AS feature_snapshot_scope
FROM building_spine b
LEFT JOIN bm_months m
    ON b.building_id = m.building_id
LEFT JOIN cp_bldg cp
    ON b.building_id = cp.building_id
LEFT JOIN viol_bldg v
    ON b.building_id = v.building_id
LEFT JOIN ro_bldg ro
    ON b.building_id = ro.building_id;
GO
