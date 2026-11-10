-- Each check should return ZERO rows. Start every check with "-- check: name".

-- check: silver_event_id_unique
SELECT event_id FROM silver.event GROUP BY event_id HAVING COUNT(*) > 1;

-- check: silver_no_negative_amounts
SELECT event_id FROM silver.event WHERE amount < 0;

-- check: fact_no_orphan_entity_keys
SELECT event_id FROM gold.fact_event WHERE entity_key IS NULL;

-- check: gold_total_matches_silver_total
SELECT 'mismatch' AS problem
WHERE (SELECT SUM(amount) FROM gold.fact_event) <> (SELECT SUM(amount) FROM silver.event);

-- check: bronze_equals_silver_plus_rejected_plus_duplicates
SELECT 'mismatch' AS problem
WHERE (SELECT COUNT(*) FROM bronze.source_a)
   <> (SELECT COUNT(*) FROM silver.event)
    + (SELECT COUNT(*) FROM silver.reject_log)
    + (SELECT COUNT(NULLIF(TRIM(event_id), '')) - COUNT(DISTINCT NULLIF(TRIM(event_id), '')) FROM bronze.source_a);
