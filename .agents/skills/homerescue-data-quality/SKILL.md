---
name: homerescue-data-quality
description: Use this skill when profiling NYC Open Data sources, designing or auditing Silver cleaning and rejection rules, writing SQL reconciliation queries in src/quality/checks.sql, or validating domain constraints for Buildings (kj4p-ruqc), Complaints/Problems (ygpa-z7cr), Violations (wvxf-dwi5), and OMO Charges (mdbu-nrqn).
---

# HomeRescue Data Quality & Reconciliation Skill

> **Note:** This skill defines project-specific data quality rules and audit procedures; it does **not** replace running executable checks (`python -m src.quality.run_checks` or `sqlcmd`).

## 1. Project-Specific Data Quality Instructions
1. **Row Conservation & Reconciliation Equation:**
   For every entity loaded from Bronze to Silver, enforce and verify the exact accounting equation:
   $$\text{Bronze Total Rows} = \text{Silver Accepted Rows} + \text{Silver Rejected Rows} + \text{Silver Duplicate Rows Removed}$$
   Write an executable check in `src/quality/checks.sql` for each source table verifying zero unaccounted row loss or inflation.

2. **Missing Values vs. Conversion Failures:**
   - A source column that is empty (`NULL` or `''` after `TRIM`) is a **missing value**.
   - A source column where `NULLIF(TRIM(col), '') IS NOT NULL` but `TRY_CONVERT(target_type, ...)` returns `NULL` is a **conversion failure**.
   - Record distinct rejection reasons in `silver.reject_log` (e.g., `'missing_building_id'` vs. `'invalid_building_id_format'`, `'missing_date'` vs. `'unparseable_date'` vs. `'out_of_range_date'`).

3. **NYC Housing Domain Rules to Enforce:**
   - **Complaints & Problems (`ygpa-z7cr`):** Validate that `problem_id` is the atomic row key and `complaint_id` is the parent key. Never equate `COUNT(*)` with complaint count; verify `COUNT(DISTINCT complaint_id) <= COUNT(DISTINCT problem_id)`.
   - **Violations (`wvxf-dwi5`):** Validate `class` against allowed domain values (`'A'`, `'B'`, `'C'`, `'I'`). Flag or reject unexpected class codes. Ensure downstream severity weights treat Class `C` as highest hazard, `B` as hazardous, `A` as non-hazardous, and `I` as administrative/informational (not above `C`).
   - **OMO Charges (`mdbu-nrqn`):**
     - Profile and filter program/work-type attributes to flag the **eligible emergency/maintenance repair cohort** explicitly rather than assuming all rows are emergency repairs.
     - Do **not** blindly reject negative or zero `OMOAwardAmount` values. Distinguish negative adjustment/reversal records and zero-dollar cancelled/administrative records from invalid non-numeric strings, and document how each is handled in `silver.omo_charge` and Gold aggregations.
   - **Plausible Date Ranges:** In addition to `TRY_CONVERT(DATE, ...)`, reject or quarantine dates earlier than `1900-01-01` or later than the extraction batch date (`CAST(SYSDATETIME() AS DATE)`).
   - **Cross-Source Building Match Rate:** Measure the percentage and row count of Complaints, Violations, and OMO Charges whose normalized `building_id` does not exist in `silver.building`. Route unmatched `building_id` records to the explicit Unmatched/Unknown building dimension member (`building_key = -1`) and report the exact match/unmatched rates in Silver and Gold reports.

## 2. Observable Acceptance Criteria
- Every `-- check: <name>` block in `src/quality/checks.sql` returns **0 bad rows** (`PASS`) when executed via `python -m src.quality.run_checks` or `sqlcmd`.
- Silver and Gold milestone reports include a reconciliation table showing exact counts for: Bronze raw rows, duplicates removed, rejected rows (broken down by `reason`), Silver valid rows, and cross-source matched vs. unmatched `building_id` counts.
- No Gold view or semantic metric performs a many-to-many join across atomic fact tables (`SUM(omo_award_amount)` in Gold matches `SUM(omo_award_amount)` in Silver for the eligible cohort).

## 3. Execution & Evidence Reporting Requirement
Every data quality summary or milestone report must explicitly separate:
1. **Executed Checks:** Exact check names, SQL queries run, execution timestamp, and observed row count (`0 bad rows` or exact failure count).
2. **Checks Not Run / Blocked:** Any planned check that could not be executed in the current session, with its exact blocker documented. Never fabricate check outcomes or row counts.
