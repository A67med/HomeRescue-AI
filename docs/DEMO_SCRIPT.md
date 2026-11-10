# Live Demonstration Guide (5–10 Minutes) — HomeRescue AI

> **Purpose:** Step-by-step live walkthrough for the instructor evaluation demonstrating source provenance, Bronze-to-Silver-to-Gold reconciliation, persistent dimensional modeling, governed semantic metrics, the 5 business analyses, and automated validation.

---

## Step 1: Show Dataset Provenance & Source Register (1 Minute)

1. Open [`docs/data_source_register.csv`](file:///E:/PROJECTS/HomeRescue-AI/docs/data_source_register.csv) and `data/raw/manifest.json` to show the 4 official NYC Open Data Socrata endpoints (`kj4p-ruqc`, `ygpa-z7cr`, `wvxf-dwi5`, `mdbu-nrqn`), exact query filters (`Staten Island`, `2024-01-01` to `2024-12-31`), extracted row counts (`55,734` total rows), and SHA-256 checksums.
2. Run a quick check in PowerShell from `E:\PROJECTS\HomeRescue-AI`:
   ```powershell
   Get-Content data\raw\manifest.json | Select-Object -First 35
   ```

---

## Step 2: Demonstrate Bronze & Silver Row Conservation in SQL Server (2 Minutes)

Execute the following query in SSMS or via `sqlcmd`:
```powershell
sqlcmd -S localhost -E -C -d homerescue_dw -W -s " | " -Q "
SELECT source_table, target_table, bronze_rows, silver_accepted_rows,
       silver_rejected_rows, silver_duplicate_rows_removed, reconciliation_diff
FROM silver.batch_reconciliation
ORDER BY recon_id;
"
```

### Expected Output & Talking Points
- `bronze.buildings` (`22,404`) = `silver.building` (`22,329`) + `75` rejected (`implausible_zero_tax_block_or_lot` in `silver.reject_log`) + `0` duplicates (`reconciliation_diff = 0`).
- `bronze.complaints_problems` (`14,377`), `bronze.violations` (`18,463`), and `bronze.omo_charges` (`490`) reconcile with `0` difference (`55,734 = 55,659 + 75 + 0`).
- Show [`docs/BRONZE_REPORT.pdf`](file:///E:/PROJECTS/HomeRescue-AI/docs/BRONZE_REPORT.pdf) and [`docs/SILVER_REPORT.pdf`](file:///E:/PROJECTS/HomeRescue-AI/docs/SILVER_REPORT.pdf) for visual charts of the Bronze and Silver layers.

---

## Step 3: Showcase Gold Star Schema & Grain-Safe Multi-Fact Design (2 Minutes)

Execute the following query to verify persistent surrogate keys (`building_key = -1` for unmatched buildings) and zero fan-out across Complaints, Violations, and OMO Charges:
```powershell
sqlcmd -S localhost -E -C -d homerescue_dw -W -s " | " -Q "
SELECT
    COUNT(*) AS total_building_spine,
    SUM(CASE WHEN building_key = -1 THEN 1 ELSE 0 END) AS unregistered_buildings_on_minus_one,
    SUM(distinct_complaint_count) AS total_distinct_complaints,
    SUM(total_problem_count) AS total_problems,
    SUM(total_violation_count) AS total_violations,
    SUM(class_b_violation_count + class_c_violation_count) AS class_bc_violations,
    SUM(eligible_omo_count) AS eligible_omos,
    SUM(eligible_omo_award_amount) AS eligible_omo_award_usd
FROM gold.fact_building_maintenance;
"
```

### Expected Output & Talking Points
- `total_building_spine = 22,333` (`22,329` registered buildings + `4` unregistered `building_id`s mapped to `building_key = -1` so zero events are dropped).
- `total_distinct_complaints = 7,334` kept strictly separate from `total_problems = 14,377` (**Mandatory Rule 1**).
- `eligible_omo_award_usd = $983,560.44` matches `SELECT SUM(omo_award_amount) FROM silver.omo_charge WHERE is_eligible_repair_cohort = 1` to the exact cent (**Mandatory Rule 7: Zero Fan-Out**).

---

## Step 4: Showcase Semantic Metrics & Top Priority Findings (2 Minutes)

Execute the Intervention Gap summary and Top 10 Priority Buildings query from the Semantic layer:
```powershell
sqlcmd -S localhost -E -C -d homerescue_dw -W -s " | " -Q "
SELECT TOP 10
    priority_rank, building_id, street_address, zip_code, total_legal_units,
    distinct_complaint_count AS complaints, total_problem_count AS problems,
    class_c_violation_count AS class_c, class_b_violation_count AS class_b,
    eligible_omo_count AS elig_omos, eligible_omo_award_amount AS elig_omo_usd,
    maintenance_priority_score AS score, omo_intervention_gap_flag
FROM semantic.v_building_priority_ranking
ORDER BY priority_rank;
"
```

### Expected Output & Talking Points
- **Rank #1 Overall:** `185 PARK HILL AVENUE` (`building_id = 812537`, `ZIP 10304`, `150` units) — `score = 3,699` (`357` Class C, `442` Class B, `31` eligible OMOs = `$43,348.25`).
- **Rank #9 Overall (#1 Unaddressed High-Hazard Building):** `55 BOWEN STREET` (`building_id = 767602`, `ZIP 10304`, `156` units) — `score = 631` (`64` Class C, `55` Class B, `0` OMO orders -> `HIGH_HAZARD_UNADDRESSED_BY_OMO`).
-Across Staten Island, **`476` high-hazard buildings (`2.13%` of buildings) generate `92.09%` (`12,030 / 13,063`) of all Class B & C violations**, and **`339` of those `476` high-hazard buildings received `$0.00` in OMO repair orders**.
- Open [`docs/GOLD_REPORT.pdf`](file:///E:/PROJECTS/HomeRescue-AI/docs/GOLD_REPORT.pdf) to show the 2-page visual executive summary.

---

## Step 5: Run Automated Validation Suite & Pytest (2 Minutes)

Run the automated quality checks (`32` SQL checks + `12` semantic metric reconciliations = `44` checks) and `pytest` suite (`3` test modules including isolated synthetic edge-case fixtures):
```powershell
& "C:\Users\Ahmed\anaconda3\python.exe" -m src.quality.run_checks
& "C:\Users\Ahmed\anaconda3\python.exe" -m pytest -v
```

### Expected Output
- `run_checks`: `SQL Quality Checks: 32/32 PASS (0 failed)` and `Semantic Metric Reconciliations: 12/12 PASS (0 failed)`.
- `pytest -v`: `3 passed` in under 3 seconds.
- Optional: Show `data/exports/validation/m5_verification_and_backup_evidence.json` to demonstrate that the entire pipeline was rebuilt from scratch in `homerescue_dw_verify` (`14.46s`, `0` differences across 25 objects) and backed up/restored to `homerescue_dw_restore_test`.
