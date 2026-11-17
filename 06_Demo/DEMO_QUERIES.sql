-- HOME RESCUE AI / LIVE INSTRUCTOR DEMO (verified against exact names in SQL scripts)
-- Run after 01_RUN_PROJECT.bat reports SUCCESS. All counts come from local SQL Server.
USE homerescue_dw;
GO
-- 1. BRONZE - four source tables. Their columns remain raw text with provenance.
SELECT 'bronze.buildings' AS dataset_name, COUNT_BIG(*) AS rows_loaded FROM bronze.buildings
UNION ALL SELECT 'bronze.complaints_problems',COUNT_BIG(*) FROM bronze.complaints_problems
UNION ALL SELECT 'bronze.violations',COUNT_BIG(*) FROM bronze.violations
UNION ALL SELECT 'bronze.omo_charges',COUNT_BIG(*) FROM bronze.omo_charges;
GO
SELECT TOP 3 buildingid, boroid, source_dataset_id, source_file, batch_id, ingested_at
FROM bronze.buildings ORDER BY bronze_row_id;
GO
-- 2. SILVER - conservation and rejection evidence.
SELECT source_table, target_table, bronze_rows, silver_accepted_rows,
       silver_rejected_rows, silver_duplicate_rows_removed, reconciliation_diff
FROM silver.batch_reconciliation ORDER BY source_table;
GO
SELECT reason, COUNT_BIG(*) AS rejected_records
FROM silver.reject_log GROUP BY reason ORDER BY rejected_records DESC;
GO
-- 3. GOLD - star schema objects and grain-safe features.
SELECT 'gold.dim_building' AS object_name,COUNT_BIG(*) AS rows_loaded FROM gold.dim_building
UNION ALL SELECT 'gold.dim_date',COUNT_BIG(*) FROM gold.dim_date
UNION ALL SELECT 'gold.fact_complaint_problem',COUNT_BIG(*) FROM gold.fact_complaint_problem
UNION ALL SELECT 'gold.fact_violation',COUNT_BIG(*) FROM gold.fact_violation
UNION ALL SELECT 'gold.fact_repair_order',COUNT_BIG(*) FROM gold.fact_repair_order
UNION ALL SELECT 'gold.mart_building_month',COUNT_BIG(*) FROM gold.mart_building_month
UNION ALL SELECT 'gold.features_building_maintenance',COUNT_BIG(*) FROM gold.features_building_maintenance;
GO
SELECT TOP 10 priority_rank,building_id,full_street_address,zip_code,
       maintenance_priority_score,class_c_violation_count_2024,
       class_b_violation_count_2024,eligible_repair_order_count_2024,
       intervention_gap_status
FROM semantic.v_building_priority_ranking
ORDER BY priority_rank, building_id;
GO
-- 4. Answer the business question with a summary.
SELECT COUNT_BIG(*) AS all_buildings,
       SUM(CASE WHEN maintenance_priority_score >=25 THEN 1 ELSE 0 END) AS high_hazard_buildings,
       SUM(CASE WHEN maintenance_priority_score >=25 AND eligible_repair_order_count_2024=0
                THEN 1 ELSE 0 END) AS high_hazard_without_eligible_omo,
       SUM(eligible_omo_award_amount_2024) AS eligible_award_usd
FROM gold.features_building_maintenance;
GO
SELECT COUNT(*) AS catalogued_semantic_metrics FROM semantic.metric_catalog;
GO
-- 5. Recent execution audit.
SELECT TOP 15 source_name,target_table,rows_loaded,status,start_time,end_time
FROM audit.load_log ORDER BY load_id DESC;
GO
