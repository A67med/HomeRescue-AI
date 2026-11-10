/* ============================================================================
   File: sql/06_analytics.sql
   Project: HomeRescue AI (Medallion Data Warehouse)
   Layer: Business Analytics (Five Core Business Analyses)
   Description:
     Executes five documented, grain-explicit analytical queries against the
     Gold and Semantic layers to answer HomeRescue AI's primary business
     question:
       "Which Staten Island buildings exhibit the highest concentration of
        documented housing maintenance distress (emergency complaint problems,
        Class B/C hazardous violations, open violations, and rent-impairing
        conditions) during 2024, how do HPD Open Market Order (OMO) eligible
        residential repair awards align with those documented hazards across
        buildings, neighborhoods, and seasons, and which high-hazard buildings
        remain unaddressed by eligible OMO repair orders?"
   ============================================================================ */

IF DB_NAME() IN (N'master', N'tempdb', N'model', N'msdb')
    USE [homerescue_dw];
GO

SET NOCOUNT ON;
GO

/* ============================================================================
   ANALYSIS Q1A: Intervention Gap Summary Across Building Priority Tiers
   BUSINESS QUESTION: How many Staten Island buildings fall into each hazard
     priority and OMO intervention status category, and how many high-hazard
     buildings (Priority Score >= 25) had zero eligible OMO repair orders in 2024?
   GRAIN: One row per intervention_gap_status category.
   ============================================================================ */
SELECT
    intervention_gap_status,
    COUNT(building_id) AS building_count,
    CAST(COUNT(building_id) * 100.0 / SUM(COUNT(building_id)) OVER () AS DECIMAL(6,2)) AS share_of_all_buildings_pct,
    SUM(distinct_complaint_count_2024) AS total_complaints,
    SUM(problem_count_2024) AS total_problems,
    SUM(emergency_problem_count_2024) AS emergency_problems,
    SUM(violation_count_2024) AS total_violations,
    SUM(class_c_violation_count_2024) AS class_c_violations,
    SUM(class_b_violation_count_2024) AS class_b_violations,
    SUM(hazardous_bc_violation_count_2024) AS hazardous_bc_violations,
    SUM(open_violation_count_2024) AS open_violations,
    SUM(rent_impairing_violation_count_2024) AS rent_impairing_violations,
    SUM(eligible_repair_order_count_2024) AS eligible_omo_orders,
    SUM(eligible_omo_award_amount_2024) AS eligible_omo_award_amount
FROM semantic.v_building_priority_ranking
GROUP BY intervention_gap_status
ORDER BY
    SUM(hazardous_bc_violation_count_2024) DESC,
    building_count DESC;
GO

/* ============================================================================
   ANALYSIS Q1B: Top 15 Priority Buildings for Maintenance Review in Staten Island
   BUSINESS QUESTION: Which specific Staten Island buildings rank highest on
     documented maintenance hazard indicators in 2024, and what is each
     building's OMO repair order award status?
   GRAIN: One row per building (building_id) for the Top 15 ranked buildings.
   ============================================================================ */
SELECT TOP 15
    priority_rank,
    building_id,
    building_key,
    is_registered_building,
    full_street_address,
    zip_code,
    total_legal_units,
    unit_size_tier,
    active_months_2024,
    distinct_complaint_count_2024,
    problem_count_2024,
    emergency_problem_count_2024,
    violation_count_2024,
    class_c_violation_count_2024,
    class_b_violation_count_2024,
    open_violation_count_2024,
    rent_impairing_violation_count_2024,
    eligible_repair_order_count_2024,
    raw_eligible_omo_award_amount_2024,
    eligible_omo_award_amount_2024,
    maintenance_priority_score,
    intervention_gap_status
FROM semantic.v_building_priority_ranking
ORDER BY priority_rank ASC, building_id ASC;
GO

/* ============================================================================
   ANALYSIS Q2A: Neighborhood (ZIP Code) Concentration of Distress & Repair Awards
   BUSINESS QUESTION: Which Staten Island ZIP codes experience the highest
     concentration of complaints, Class B/C hazardous violations, unaddressed
     high-hazard buildings, and eligible OMO repair awards relative to their
     total building stock (including zero-event buildings)?
   GRAIN: One row per Staten Island zip_code.
   ============================================================================ */
SELECT
    zip_code,
    total_buildings,
    active_buildings_2024,
    zero_event_buildings_2024,
    active_building_pct,
    total_legal_units,
    total_complaint_problems,
    emergency_complaint_problems,
    total_violations,
    class_c_violations,
    class_b_violations,
    hazardous_bc_violations,
    open_violations,
    rent_impairing_violations,
    high_or_critical_priority_buildings,
    high_hazard_unaddressed_buildings,
    eligible_repair_order_count,
    eligible_omo_award_amount,
    total_all_omo_award_amount
FROM semantic.v_zip_code_maintenance_summary
ORDER BY hazardous_bc_violations DESC, total_complaint_problems DESC;
GO

/* ============================================================================
   ANALYSIS Q2B: Building Unit-Size Tier Stratification
   BUSINESS QUESTION: How do complaint rates, hazardous violation rates, and
     eligible OMO repair awards scale across building unit-size tiers?
   GRAIN: One row per unit_size_tier.
   ============================================================================ */
SELECT
    unit_size_tier,
    COUNT(building_id) AS total_buildings,
    SUM(CASE WHEN has_any_2024_activity = 1 THEN 1 ELSE 0 END) AS active_buildings,
    SUM(CASE WHEN has_any_2024_activity = 0 THEN 1 ELSE 0 END) AS zero_event_buildings,
    CAST(SUM(CASE WHEN has_any_2024_activity = 1 THEN 1 ELSE 0 END) * 100.0 / NULLIF(COUNT(building_id), 0) AS DECIMAL(6,2)) AS active_building_pct,
    SUM(ISNULL(total_legal_units, 0)) AS total_legal_units,
    SUM(problem_count_2024) AS total_problems,
    SUM(emergency_problem_count_2024) AS emergency_problems,
    SUM(hazardous_bc_violation_count_2024) AS hazardous_bc_violations,
    SUM(open_violation_count_2024) AS open_violations,
    SUM(eligible_repair_order_count_2024) AS eligible_omo_orders,
    SUM(eligible_omo_award_amount_2024) AS eligible_omo_award_amount
FROM gold.features_building_maintenance
GROUP BY unit_size_tier
ORDER BY hazardous_bc_violations DESC;
GO

/* ============================================================================
   ANALYSIS Q3: Monthly & Seasonal Trajectory Across 2024
   BUSINESS QUESTION: How do complaint problems, emergency problems, hazardous
     violations, and eligible OMO repair awards fluctuate month by month across
     2024, and how does heating-season volume compare with summer months?
   GRAIN: One row per calendar month (year_month: '2024-01' through '2024-12').
   ============================================================================ */
SELECT
    year_month,
    quarter_label,
    month_name,
    total_active_buildings,
    buildings_with_complaints,
    distinct_complaints,
    total_complaint_problems,
    emergency_complaint_problems,
    buildings_with_violations,
    total_violations,
    class_c_violations,
    class_b_violations,
    hazardous_bc_violations,
    open_violations,
    buildings_with_eligible_repairs,
    eligible_repair_order_count,
    eligible_omo_award_amount,
    avg_eligible_omo_award_amount,
    total_all_omo_award_amount
FROM semantic.v_monthly_borough_summary
ORDER BY year_month ASC;
GO

/* ============================================================================
   ANALYSIS Q4: Violation Class Severity & Open Backlog Breakdown
   BUSINESS QUESTION: What share of Staten Island's 18,463 violations in 2024
     belong to Class C (Immediately Hazardous), Class B (Hazardous), Class A
     (Non-Hazardous), and Class I (Administrative Orders), and what are their
     respective open-backlog and rent-impairing rates?
   GRAIN: One row per violation_class ('C', 'B', 'A', 'I').
   ============================================================================ */
SELECT
    violation_class,
    hazard_class_category,
    hazard_severity_rank,
    is_substantive_abc_violation,
    is_b_or_c_hazardous_violation,
    total_violations,
    share_of_total_violations_pct,
    distinct_buildings_affected,
    open_violations,
    closed_violations,
    open_violation_rate_pct,
    rent_impairing_violations,
    registered_building_violations,
    unregistered_building_violations
FROM semantic.v_violation_hazard_breakdown
ORDER BY
    CASE violation_class
        WHEN 'C' THEN 1
        WHEN 'B' THEN 2
        WHEN 'A' THEN 3
        WHEN 'I' THEN 4
        ELSE 5
    END;
GO

/* ============================================================================
   ANALYSIS Q5A: OMO Repair Cohort Filtering & Demolition Distortion Audit
   BUSINESS QUESTION: How do OMO contract award amounts break down across
     eligible residential building repair work types versus excluded commercial
     and structural demolitions, duplicate orders, and zero-dollar orders?
   GRAIN: One row per (is_eligible_repair_cohort, repair_cohort_category,
          work_type_general, financial_value_status).
   ============================================================================ */
SELECT
    is_eligible_repair_cohort,
    repair_cohort_category,
    work_type_general,
    financial_value_status,
    omo_order_count,
    distinct_buildings,
    total_omo_award_amount,
    share_of_total_award_pct,
    avg_omo_award_amount,
    min_omo_award_amount,
    max_omo_award_amount,
    total_net_change_orders
FROM semantic.v_omo_repair_cohort_summary
ORDER BY
    is_eligible_repair_cohort DESC,
    total_omo_award_amount DESC,
    omo_order_count DESC;
GO

/* ============================================================================
   ANALYSIS Q5B: Unregistered / Unmatched Building Lineage Audit (building_key = -1)
   BUSINESS QUESTION: Which specific unregistered building_id values appear in
     2024 Staten Island complaints, violations, or OMO repair orders, and what
     are their exact event counts and award amounts?
   GRAIN: One row per unregistered building_id (4 rows).
   ============================================================================ */
SELECT
    building_id,
    building_key,
    source_reported_address,
    source_reported_zip,
    active_months_2024,
    distinct_complaint_count_2024,
    problem_count_2024,
    emergency_problem_count_2024,
    violation_count_2024,
    class_c_violation_count_2024,
    class_b_violation_count_2024,
    class_a_violation_count_2024,
    open_violation_count_2024,
    omo_order_count_2024,
    eligible_repair_order_count_2024,
    raw_total_omo_award_amount_2024,
    raw_eligible_omo_award_amount_2024,
    total_omo_award_amount_2024,
    eligible_omo_award_amount_2024,
    maintenance_priority_score,
    maintenance_priority_tier
FROM semantic.v_unmatched_building_audit
ORDER BY maintenance_priority_score DESC, building_id ASC;
GO
