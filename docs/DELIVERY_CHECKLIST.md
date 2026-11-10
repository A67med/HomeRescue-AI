# Instructor Delivery & Milestone Checklist — HomeRescue AI

> **Definition of Done:** Every item is marked `[x]` **only** because it has been **implemented, executed, validated, and documented** against SQL Server (`homerescue_dw`, `homerescue_dw_verify`, `homerescue_dw_synth_fixture`, and `homerescue_dw_restore_test`).

---

## 1. Instructor Core Deliverables Checklist

| Deliverable | Target Artifact(s) | Milestone | Status | Completion Evidence / Notes |
|---|---|---|---|---|
| **Source Links & Actual Datasets Used** | [`docs/data_source_register.csv`](file:///E:/PROJECTS/HomeRescue-AI/docs/data_source_register.csv), [`docs/PROJECT_SPEC.md`](file:///E:/PROJECTS/HomeRescue-AI/docs/PROJECT_SPEC.md), `data/raw/manifest.json` | M0–M1 | `[x]` Completed | Verified live Socrata metadata (`kj4p-ruqc`, `ygpa-z7cr`, `wvxf-dwi5`, `mdbu-nrqn`), extracted pilot (`manifest_pilot.json`) and full 2024 Staten Island datasets (`55,734` rows across 4 CSVs with SHA-256 checksums in `data/raw/manifest.json`). |
| **Clear Project Question** | [`docs/PROJECT_SPEC.md`](file:///E:/PROJECTS/HomeRescue-AI/docs/PROJECT_SPEC.md) (Section 1), [`README.md`](file:///E:/PROJECTS/HomeRescue-AI/README.md) | M0 | `[x]` Completed | Documented primary maintenance review priority question and 4 analytical sub-questions, answered empirically in [`sql/06_analytics.sql`](file:///E:/PROJECTS/HomeRescue-AI/sql/06_analytics.sql) and [`docs/GOLD_REPORT.md`](file:///E:/PROJECTS/HomeRescue-AI/docs/GOLD_REPORT.md). |
| **Bronze SQL Script, Populated Objects & Bronze Report** | [`sql/00_init.sql`](file:///E:/PROJECTS/HomeRescue-AI/sql/00_init.sql), [`sql/01_bronze.sql`](file:///E:/PROJECTS/HomeRescue-AI/sql/01_bronze.sql), `bronze.*` tables in `homerescue_dw`, [`docs/BRONZE_REPORT.md`](file:///E:/PROJECTS/HomeRescue-AI/docs/BRONZE_REPORT.md), [`docs/BRONZE_REPORT.pdf`](file:///E:/PROJECTS/HomeRescue-AI/docs/BRONZE_REPORT.pdf) | M2 | `[x]` Completed | `55,734` total rows loaded across `bronze.buildings` (`22,404`), `bronze.complaints_problems` (`14,377`), `bronze.violations` (`18,463`), and `bronze.omo_charges` (`490`); 100% CSV-to-Bronze reconciliation and staging rollback verified. |
| **Silver SQL Script, Populated Objects & Silver Report** | [`sql/02_silver.sql`](file:///E:/PROJECTS/HomeRescue-AI/sql/02_silver.sql), `silver.*` tables & `silver.reject_log` in `homerescue_dw`, [`docs/SILVER_REPORT.md`](file:///E:/PROJECTS/HomeRescue-AI/docs/SILVER_REPORT.md), [`docs/SILVER_REPORT.pdf`](file:///E:/PROJECTS/HomeRescue-AI/docs/SILVER_REPORT.pdf) | M3 | `[x]` Completed | `55,659` accepted rows + `75` rejected rows (`implausible_zero_tax_block_or_lot` in `silver.reject_log`) + `0` duplicates = `55,734` Bronze rows (`reconciliation_diff = 0`). |
| **Gold SQL Script, Populated Objects & Gold Report** | [`sql/03_gold.sql`](file:///E:/PROJECTS/HomeRescue-AI/sql/03_gold.sql), [`sql/04_semantic.sql`](file:///E:/PROJECTS/HomeRescue-AI/sql/04_semantic.sql), [`sql/05_feature_views.sql`](file:///E:/PROJECTS/HomeRescue-AI/sql/05_feature_views.sql), [`sql/06_analytics.sql`](file:///E:/PROJECTS/HomeRescue-AI/sql/06_analytics.sql), [`semantic/metrics.yml`](file:///E:/PROJECTS/HomeRescue-AI/semantic/metrics.yml), [`docs/GOLD_REPORT.md`](file:///E:/PROJECTS/HomeRescue-AI/docs/GOLD_REPORT.md), [`docs/GOLD_REPORT.pdf`](file:///E:/PROJECTS/HomeRescue-AI/docs/GOLD_REPORT.pdf) | M4 | `[x]` Completed | Persistent dimensions (`gold.dim_building` `22,330` rows including `-1` Unknown member; `gold.dim_date` `4,018` rows), 3 atomic facts, 2 grain-aligned summary marts, `12` semantic metrics (`0.0` diff), and 5 business analyses executed. |
| **Reproducible Verification Rebuild, Backup/Restore & Demo Guide** | [`src/run_pipeline.py`](file:///E:/PROJECTS/HomeRescue-AI/src/run_pipeline.py), [`src/quality/verify_m5_rebuild_and_backup.py`](file:///E:/PROJECTS/HomeRescue-AI/src/quality/verify_m5_rebuild_and_backup.py), [`docs/FINAL_REVIEW.md`](file:///E:/PROJECTS/HomeRescue-AI/docs/FINAL_REVIEW.md), [`docs/DEMO_SCRIPT.md`](file:///E:/PROJECTS/HomeRescue-AI/docs/DEMO_SCRIPT.md), [`docs/SUBMISSION_INDEX.md`](file:///E:/PROJECTS/HomeRescue-AI/docs/SUBMISSION_INDEX.md) | M5 | `[x]` Completed | Rebuilt from scratch in `homerescue_dw_verify` (`14.46s`, `0` differences across 25 objects and 6 `EXCEPT` queries), verified idempotent rerun (`0` changed surrogate keys), and verified SQL Server `.bak` backup & restore to `homerescue_dw_restore_test`. |
| **Template Folder & File Organization** | `sql/`, `src/`, `semantic/`, `docs/`, `tests/`, `notebooks/`, `data/raw/`, `data/exports/`, `models/` | M0–M5 | `[x]` Completed | All template folders and numbered SQL scripts (`00_init.sql`–`06_analytics.sql`) preserved and populated. |

---

## 2. Mandatory Data & Architecture Rules Compliance Matrix

| # | Mandatory Rule | Enforced In | Verification Check (`src/quality/checks.sql` / Tests) | Status |
|---|---|---|---|---|
| 1 | Complaint row = `problem_id` within `complaint_id`; keep problem counts separate from distinct complaint counts | `sql/02_silver.sql`, `sql/03_gold.sql`, `semantic/metrics.yml` | `complaint_vs_problem_grain_distinct`, `gold_complaint_vs_problem_sums_match_silver` (`14,377` problems vs. `7,334` distinct complaints) | `[x]` Verified (`PASS`) |
| 2 | Normalize `building_id` in Silver (`buildingid` -> `building_id`) | `sql/02_silver.sql` | `silver_building_id_normalized` (`0` invalid/non-positive `building_id`s across all 4 Silver tables) | `[x]` Verified (`PASS`) |
| 3 | Violation classes include `A`, `B`, `C`, `I`; Class `I` is not a severity level above `C` | `sql/02_silver.sql`, `sql/03_gold.sql`, `sql/04_semantic.sql` | `violation_class_domain_valid` (`2,431` Class `I` records assigned `hazard_weight = 0` and `is_hazardous_class_bc = 0`) | `[x]` Verified (`PASS`) |
| 4 | OMO contains multiple programs/work types; define eligible repair cohort before calling events emergencies | `sql/02_silver.sql`, `sql/03_gold.sql`, `docs/SILVER_REPORT.md` | `omo_eligible_cohort_defined` (`458` eligible residential repair orders = `$983,560.44` vs. `32` excluded orders = `$2,098,049.00`) | `[x]` Verified (`PASS`) |
| 5 | `OMOAwardAmount` is an award amount, not proof of payment or preventive intervention cost | `semantic/metrics.yml`, `docs/*_REPORT.md`, `sql/06_analytics.sql` | Delivery review check & `semantic/metrics.yml` definitions (`total_eligible_omo_award_amount`, `total_all_omo_award_amount`) | `[x]` Verified (`PASS`) |
| 6 | `InvoiceID` alone is not globally unique (`emrz-5p35` optional, deferred) | `AGENTS.md`, `docs/PROJECT_SPEC.md`, `docs/data_source_register.csv` | Deferred scope gate (`emrz-5p35` marked `DEFERRED_OPTIONAL` in `docs/data_source_register.csv`) | `[x]` Verified (`PASS`) |
| 7 | Never join raw complaint, violation, and repair facts together and sum amounts; pre-aggregate to compatible grain first | `sql/03_gold.sql`, `sql/04_semantic.sql`, `sql/06_analytics.sql` | `gold_omo_award_sum_matches_silver`, `gold_violation_counts_match_silver`, `gold_monthly_summary_reconciles_to_building_summary` (`$0.00` / `0` row diff) | `[x]` Verified (`PASS`) |
| 8 | Preserve raw data in Bronze and record extraction time, source, `batch_id`, and file provenance | `sql/01_bronze.sql`, `src/ingest/load_csv.py` | `bronze_provenance_not_null` (`0` NULL provenance values across all `55,734` Bronze rows) | `[x]` Verified (`PASS`) |
| 9 | Distinguish missing values from failed conversions; track rejected and duplicate rows | `sql/02_silver.sql` (`silver.reject_log`, `silver.batch_reconciliation`) | `bronze_equals_silver_plus_rejected_plus_duplicates_*` (4 live checks + synthetic edge-case test in `tests/test_warehouse_validation.py`) | `[x]` Verified (`PASS`) |
| 10 | Validate plausible date ranges in addition to `TRY_CONVERT` syntax success | `sql/02_silver.sql` | `silver_dates_within_plausible_range` (`0` out-of-range dates in Silver; synthetic pre-1900 date rejected in `homerescue_dw_synth_fixture`) | `[x]` Verified (`PASS`) |
| 11 | Do not reject all negative financial fields without field-specific business reasoning | `sql/02_silver.sql`, `docs/SILVER_REPORT.md` | `silver_omo_financial_classification_complete` (`POSITIVE_AWARD`, `ZERO_DOLLAR_ORDER`, `NEGATIVE_CREDIT_ADJUSTMENT` tested in live + synthetic fixture DB) | `[x]` Verified (`PASS`) |
| 12 | Measure unmatched records and apply an explicit retention policy (`building_key = -1`) | `sql/02_silver.sql`, `sql/03_gold.sql` | `gold_fact_no_null_building_key`, `gold_unmatched_facts_preserved_on_minus_one_key` (`58` unmatched events across `4` unregistered `building_id`s retained via `building_key = -1`) | `[x]` Verified (`PASS`) |
| 13 | Use stable dimension keys; never use recalculated `ROW_NUMBER()` view as persistent surrogate key | `sql/03_gold.sql` (`gold.dim_building`, `gold.dim_date` tables) | `gold_dim_building_is_persistent_table_not_view` + M5 idempotency rerun (`0` changed `building_key`s across `22,330` rows) | `[x]` Verified (`PASS`) |
| 14 | Do not claim proven cost savings or trained risk probabilities without evidence | `AGENTS.md`, `docs/*_REPORT.md`, `docs/FINAL_REVIEW.md` | Delivery review check (`.agents/skills/homerescue-delivery-review/SKILL.md`) | `[x]` Verified (`PASS`) |

---

## 3. Milestone Execution Sign-Off

### M0: Project Foundation, Rules & Environment Inspection
- `[x]` Inspect `README.md`, `docs/PROJECT_SPEC.md`, `sql/*.sql`, `src/**`, `semantic/metrics.yml`, and `tests/**`.
- `[x]` Inspect SQL Server availability, version, instance, `sqlcmd`, ODBC Driver 18, Python, and Git; verify SQL Server connection.
- `[x]` Create root [`AGENTS.md`](file:///E:/PROJECTS/HomeRescue-AI/AGENTS.md) with mandatory constraints and definition of done.
- `[x]` Create [`.agents/skills/homerescue-sqlserver/SKILL.md`](file:///E:/PROJECTS/HomeRescue-AI/.agents/skills/homerescue-sqlserver/SKILL.md), [`.agents/skills/homerescue-data-quality/SKILL.md`](file:///E:/PROJECTS/HomeRescue-AI/.agents/skills/homerescue-data-quality/SKILL.md), and [`.agents/skills/homerescue-delivery-review/SKILL.md`](file:///E:/PROJECTS/HomeRescue-AI/.agents/skills/homerescue-delivery-review/SKILL.md).
- `[x]` Update [`docs/PROJECT_SPEC.md`](file:///E:/PROJECTS/HomeRescue-AI/docs/PROJECT_SPEC.md), [`docs/IMPLEMENTATION_PLAN.md`](file:///E:/PROJECTS/HomeRescue-AI/docs/IMPLEMENTATION_PLAN.md), [`docs/DELIVERY_CHECKLIST.md`](file:///E:/PROJECTS/HomeRescue-AI/docs/DELIVERY_CHECKLIST.md), and [`docs/PROGRESS.md`](file:///E:/PROJECTS/HomeRescue-AI/docs/PROGRESS.md).
- `[x]` Align [`.env.example`](file:///E:/PROJECTS/HomeRescue-AI/.env.example), [`.gitignore`](file:///E:/PROJECTS/HomeRescue-AI/.gitignore), and [`src/db.py`](file:///E:/PROJECTS/HomeRescue-AI/src/db.py) with `homerescue_dw` and Git exclusion rules.

### M1: Source Verification, Scope Selection & Reproducible Data Acquisition
- `[x]` Query live Socrata metadata for `kj4p-ruqc`, `ygpa-z7cr`, `wvxf-dwi5`, and `mdbu-nrqn` via [`src/ingest/inspect_sources.py`](file:///E:/PROJECTS/HomeRescue-AI/src/ingest/inspect_sources.py) (saved to `data/exports/source_metadata_summary.json`).
- `[x]` Profile borough and date coverage; select connected Staten Island (`boroid = 5`) 2024 scope (`2024-01-01` to `2024-12-31`).
- `[x]` Acquire pilot (`data/raw/pilot/manifest_pilot.json`) and full 2024 Staten Island datasets to `data/raw/` (`data/raw/manifest.json`: `22,404` buildings, `14,377` complaint problems, `18,463` violations, `490` OMO charges = `55,734` rows with SHA-256 hashes).
- `[x]` Update [`docs/data_source_register.csv`](file:///E:/PROJECTS/HomeRescue-AI/docs/data_source_register.csv) and [`docs/data_dictionary.csv`](file:///E:/PROJECTS/HomeRescue-AI/docs/data_dictionary.csv) (`686` columns across `26` objects).

### M2: Bronze Layer Implementation, Validation & Report
- `[x]` Update and execute [`sql/00_init.sql`](file:///E:/PROJECTS/HomeRescue-AI/sql/00_init.sql) and [`sql/01_bronze.sql`](file:///E:/PROJECTS/HomeRescue-AI/sql/01_bronze.sql) on `homerescue_dw`.
- `[x]` Load all 4 sources into `bronze.*` via [`src/ingest/load_csv.py`](file:///E:/PROJECTS/HomeRescue-AI/src/ingest/load_csv.py) and verify `audit.load_log` entries (including negative staging rollback test `load_id = 9`).
- `[x]` Validate 100% row count match between `data/raw/*.csv` and `bronze.*` tables (`55,734 = 55,734`).
- `[x]` Profile Bronze data quality via [`src/quality/profile_bronze.py`](file:///E:/PROJECTS/HomeRescue-AI/src/quality/profile_bronze.py) and produce [`docs/BRONZE_REPORT.md`](file:///E:/PROJECTS/HomeRescue-AI/docs/BRONZE_REPORT.md) and [`docs/BRONZE_REPORT.pdf`](file:///E:/PROJECTS/HomeRescue-AI/docs/BRONZE_REPORT.pdf).

### M3: Silver Layer Implementation, Validation & Report
- `[x]` Implement and execute [`sql/02_silver.sql`](file:///E:/PROJECTS/HomeRescue-AI/sql/02_silver.sql) and `EXEC silver.load_all;` (`silver.load_building`, `silver.load_complaint_problem`, `silver.load_violation`, `silver.load_omo_charge`).
- `[x]` Verify `Bronze = Silver + Rejected + Duplicates` for all 4 entities (`22,404 = 22,329 + 75 + 0`; `14,377 = 14,377 + 0 + 0`; `18,463 = 18,463 + 0 + 0`; `490 = 490 + 0 + 0`).
- `[x]` Measure unmatched `building_id` rates against `silver.building` (`35` complaint problems `0.24%`, `17` violations `0.09%`, `6` OMO charges `1.22%` across `4` unregistered `building_id`s).
- `[x]` Profile Silver data via [`src/quality/profile_silver.py`](file:///E:/PROJECTS/HomeRescue-AI/src/quality/profile_silver.py) and produce [`docs/SILVER_REPORT.md`](file:///E:/PROJECTS/HomeRescue-AI/docs/SILVER_REPORT.md) and [`docs/SILVER_REPORT.pdf`](file:///E:/PROJECTS/HomeRescue-AI/docs/SILVER_REPORT.pdf).

### M4: Gold & Semantic Layers, Business Metrics, Validation & Report
- `[x]` Implement and execute [`sql/03_gold.sql`](file:///E:/PROJECTS/HomeRescue-AI/sql/03_gold.sql), [`sql/04_semantic.sql`](file:///E:/PROJECTS/HomeRescue-AI/sql/04_semantic.sql), [`sql/05_feature_views.sql`](file:///E:/PROJECTS/HomeRescue-AI/sql/05_feature_views.sql), and [`sql/06_analytics.sql`](file:///E:/PROJECTS/HomeRescue-AI/sql/06_analytics.sql).
- `[x]` Populate [`semantic/metrics.yml`](file:///E:/PROJECTS/HomeRescue-AI/semantic/metrics.yml) (`12` metrics) and run [`src/semantic/sync_metrics.py`](file:///E:/PROJECTS/HomeRescue-AI/src/semantic/sync_metrics.py).
- `[x]` Reconcile every semantic metric against independent Silver validation queries (`12 / 12 PASS`, `0.0` difference).
- `[x]` Execute `pytest` (`3 passed`) and `python -m src.quality.run_checks` (`44 / 44 PASS`, `0` failures) and produce [`docs/GOLD_REPORT.md`](file:///E:/PROJECTS/HomeRescue-AI/docs/GOLD_REPORT.md) and [`docs/GOLD_REPORT.pdf`](file:///E:/PROJECTS/HomeRescue-AI/docs/GOLD_REPORT.pdf).

### M5: Verification Database Rebuild & Final Delivery
- `[x]` Rebuild entire pipeline from scratch in `homerescue_dw_verify` via `python -m src.run_pipeline --target-db homerescue_dw_verify --create-new-db`.
- `[x]` Verify 100% row-count, financial-sum, and `EXCEPT` set parity between `homerescue_dw` and `homerescue_dw_verify`, plus idempotent rerun surrogate-key stability (`0` changed keys) and SQL Server `.bak` backup/restore verification in `homerescue_dw_restore_test`.
- `[x]` Finalize [`README.md`](file:///E:/PROJECTS/HomeRescue-AI/README.md), [`docs/DELIVERY_CHECKLIST.md`](file:///E:/PROJECTS/HomeRescue-AI/docs/DELIVERY_CHECKLIST.md), [`docs/PROGRESS.md`](file:///E:/PROJECTS/HomeRescue-AI/docs/PROGRESS.md), [`docs/FINAL_REVIEW.md`](file:///E:/PROJECTS/HomeRescue-AI/docs/FINAL_REVIEW.md), [`docs/DEMO_SCRIPT.md`](file:///E:/PROJECTS/HomeRescue-AI/docs/DEMO_SCRIPT.md), and [`docs/SUBMISSION_INDEX.md`](file:///E:/PROJECTS/HomeRescue-AI/docs/SUBMISSION_INDEX.md).
