# Instructor Delivery & Milestone Checklist — HomeRescue AI

> **Definition of Done:** Every item is marked `[x]` **only** when it is **implemented, executed, validated, and documented**. Unexecuted checks must be listed explicitly as pending/blocked until run against SQL Server.

---

## 1. Instructor Core Deliverables Checklist

| Deliverable | Target Artifact(s) | Milestone | Status | Completion Evidence / Notes |
|---|---|---|---|---|
| **Source Links & Actual Datasets Used** | `docs/data_source_register.csv`, `docs/PROJECT_SPEC.md`, `data/raw/manifest.json` | M0 (spec) / M1 (live data) | `[ ]` In Progress (M1) | Official 4 NYC Open Data links documented in `docs/PROJECT_SPEC.md`; live Socrata metadata & CSV extraction scheduled in M1. |
| **Clear Project Question** | `docs/PROJECT_SPEC.md` (Section 1) | M0 | `[x]` Completed | Documented primary maintenance priority question and 4 analytical sub-questions in `docs/PROJECT_SPEC.md`. |
| **Bronze SQL Script, Populated Objects & Bronze Report** | `sql/00_init.sql`, `sql/01_bronze.sql`, `bronze.*` tables in `homerescue_dw`, `docs/BRONZE_REPORT.md` | M2 | `[ ]` Pending | Scheduled for M2. |
| **Silver SQL Script, Populated Objects & Silver Report** | `sql/02_silver.sql`, `silver.*` tables & `silver.reject_log` in `homerescue_dw`, `docs/SILVER_REPORT.md` | M3 | `[ ]` Pending | Scheduled for M3. |
| **Gold SQL Script, Populated Objects & Gold Report** | `sql/03_gold.sql`, `sql/04_semantic.sql`, `sql/05_feature_views.sql`, `sql/06_analytics.sql`, `gold.*` & `semantic.*` in `homerescue_dw`, `docs/GOLD_REPORT.md` | M4 | `[ ]` Pending | Scheduled for M4. |
| **Template Folder & File Organization** | `sql/`, `src/`, `semantic/`, `docs/`, `tests/`, `notebooks/`, `data/raw/`, `data/exports/`, `models/` | M0–M5 | `[x]` Verified in M0 | All template folders and numbered SQL scripts (`00_init.sql`–`06_analytics.sql`) preserved. |

---

## 2. Mandatory Data & Architecture Rules Compliance Matrix

| # | Mandatory Rule | Enforced In | Verification Check (`src/quality/checks.sql` / Tests) | Status |
|---|---|---|---|---|
| 1 | Complaint row = `problem_id` within `complaint_id`; keep problem counts separate from distinct complaint counts | `sql/02_silver.sql`, `sql/03_gold.sql`, `semantic/metrics.yml` | `check: complaint_vs_problem_grain_distinct` | Specified (M0); Executable check in M3/M4 |
| 2 | Normalize `building_id` in Silver (`buildingid` -> `building_id`) | `sql/02_silver.sql` | `check: silver_building_id_normalized` | Specified (M0); Executable check in M3 |
| 3 | Violation classes include `A`, `B`, `C`, `I`; Class `I` is not a severity level above `C` | `sql/02_silver.sql`, `sql/03_gold.sql`, `sql/04_semantic.sql` | `check: violation_class_domain_valid` | Specified (M0); Executable check in M3/M4 |
| 4 | OMO contains multiple programs/work types; define eligible repair cohort before calling events emergencies | `sql/02_silver.sql`, `sql/03_gold.sql`, `docs/SILVER_REPORT.md` | `check: omo_eligible_cohort_defined` | Specified (M0); Executable check in M3 |
| 5 | `OMOAwardAmount` is an award amount, not proof of payment or preventive intervention cost | `semantic/metrics.yml`, `docs/*_REPORT.md` | Delivery review check (`.agents/skills/homerescue-delivery-review/SKILL.md`) | Specified (M0); Enforced in M3/M4 |
| 6 | `InvoiceID` alone is not globally unique (`emrz-5p35` optional, deferred) | `AGENTS.md`, `docs/PROJECT_SPEC.md` | Deferred scope gate | `[x]` Documented & Deferred |
| 7 | Never join raw complaint, violation, and repair facts together and sum amounts; pre-aggregate to compatible grain first | `sql/03_gold.sql`, `sql/04_semantic.sql`, `sql/06_analytics.sql` | `check: gold_omo_award_sum_matches_silver` | Specified (M0); Executable check in M4 |
| 8 | Preserve raw data in Bronze and record extraction time, source, `batch_id`, and file provenance | `sql/01_bronze.sql`, `src/ingest/load_csv.py` | `check: bronze_provenance_not_null` | Specified (M0); Executable check in M2 |
| 9 | Distinguish missing values from failed conversions; track rejected and duplicate rows | `sql/02_silver.sql` (`silver.reject_log`) | `check: bronze_equals_silver_plus_rejected_plus_duplicates_*` | Specified (M0); Executable check in M3 |
| 10 | Validate plausible date ranges in addition to `TRY_CONVERT` syntax success | `sql/02_silver.sql` | `check: silver_dates_within_plausible_range` | Specified (M0); Executable check in M3 |
| 11 | Do not reject all negative financial fields without field-specific business reasoning | `sql/02_silver.sql`, `docs/SILVER_REPORT.md` | `check: silver_omo_financial_classification_complete` | Specified (M0); Executable check in M3 |
| 12 | Measure unmatched records and apply an explicit retention policy (`building_key = -1`) | `sql/02_silver.sql`, `sql/03_gold.sql` | `check: gold_fact_no_null_building_key` | Specified (M0); Executable check in M3/M4 |
| 13 | Use stable dimension keys; never use recalculated `ROW_NUMBER()` view as persistent surrogate key | `sql/03_gold.sql` (`gold.dim_building`, `gold.dim_date` tables) | `check: gold_dim_building_key_stability` | Specified (M0); Executable check in M4 |
| 14 | Do not claim proven cost savings or trained risk probabilities without evidence | `AGENTS.md`, `docs/*_REPORT.md` | Delivery review check | `[x]` Codified in M0 |

---

## 3. Milestone Execution Sign-Off

### M0: Project Foundation, Rules & Environment Inspection
- `[x]` Inspect `README.md`, `docs/PROJECT_SPEC.md`, `sql/*.sql`, `src/**`, `semantic/metrics.yml`, and `tests/**`.
- `[x]` Inspect SQL Server availability, version, instance, `sqlcmd`, ODBC Driver 18, Python, and Git; attempt read-only SQL Server connection.
- `[x]` Create root [`AGENTS.md`](file:///E:/PROJECTS/HomeRescue-AI/AGENTS.md) with mandatory constraints and definition of done.
- `[x]` Create [`.agents/skills/homerescue-sqlserver/SKILL.md`](file:///E:/PROJECTS/HomeRescue-AI/.agents/skills/homerescue-sqlserver/SKILL.md).
- `[x]` Create [`.agents/skills/homerescue-data-quality/SKILL.md`](file:///E:/PROJECTS/HomeRescue-AI/.agents/skills/homerescue-data-quality/SKILL.md).
- `[x]` Create [`.agents/skills/homerescue-delivery-review/SKILL.md`](file:///E:/PROJECTS/HomeRescue-AI/.agents/skills/homerescue-delivery-review/SKILL.md).
- `[x]` Update [`docs/PROJECT_SPEC.md`](file:///E:/PROJECTS/HomeRescue-AI/docs/PROJECT_SPEC.md).
- `[x]` Create [`docs/IMPLEMENTATION_PLAN.md`](file:///E:/PROJECTS/HomeRescue-AI/docs/IMPLEMENTATION_PLAN.md).
- `[x]` Create [`docs/DELIVERY_CHECKLIST.md`](file:///E:/PROJECTS/HomeRescue-AI/docs/DELIVERY_CHECKLIST.md).
- `[x]` Create [`docs/PROGRESS.md`](file:///E:/PROJECTS/HomeRescue-AI/docs/PROGRESS.md).
- `[x]` Align [`.env.example`](file:///E:/PROJECTS/HomeRescue-AI/.env.example), [`.gitignore`](file:///E:/PROJECTS/HomeRescue-AI/.gitignore), and [`src/db.py`](file:///E:/PROJECTS/HomeRescue-AI/src/db.py) with `homerescue_dw` and Git exclusion rules.

### M1: Source Verification, Scope Selection & Reproducible Data Acquisition
- `[ ]` Query live Socrata metadata for `kj4p-ruqc`, `ygpa-z7cr`, `wvxf-dwi5`, and `mdbu-nrqn`.
- `[ ]` Profile borough and date coverage; select connected pilot borough and time window.
- `[ ]` Acquire real datasets to `data/raw/` with `manifest.json` (row counts, SHA-256 checksums, extraction timestamps).
- `[ ]` Update `docs/data_source_register.csv` and `docs/data_dictionary.csv` with actual column names.

### M2: Bronze Layer Implementation, Validation & Report
- `[ ]` Update and execute `sql/00_init.sql` and `sql/01_bronze.sql` on `homerescue_dw`.
- `[ ]` Load all 4 sources into `bronze.*` and verify `audit.load_log` entries.
- `[ ]` Validate 100% row count match between `data/raw/*.csv` and `bronze.*` tables.
- `[ ]` Profile Bronze data quality and produce `docs/BRONZE_REPORT.md`.

### M3: Silver Layer Implementation, Validation & Report
- `[ ]` Implement and execute `sql/02_silver.sql` and `EXEC silver.load_*` procedures.
- `[ ]` Verify `Bronze = Silver + Rejected + Duplicates` for all 4 entities.
- `[ ]` Measure unmatched `building_id` rates against `silver.building`.
- `[ ]` Execute `python -m src.quality.run_checks` (`0` failures) and produce `docs/SILVER_REPORT.md`.

### M4: Gold & Semantic Layers, Business Metrics, Validation & Report
- `[ ]` Implement and execute `sql/03_gold.sql`, `sql/04_semantic.sql`, `sql/05_feature_views.sql`, and `sql/06_analytics.sql`.
- `[ ]` Populate `semantic/metrics.yml` and run `python -m src.semantic.sync_metrics`.
- `[ ]` Reconcile every semantic metric against independent Silver validation queries.
- `[ ]` Execute `pytest` and `python -m src.quality.run_checks` (`0` failures) and produce `docs/GOLD_REPORT.md`.

### M5: Verification Database Rebuild & Final Delivery
- `[ ]` Rebuild entire pipeline from scratch in `homerescue_dw_verify`.
- `[ ]` Verify 100% row-count and metric parity between `homerescue_dw` and `homerescue_dw_verify`.
- `[ ]` Finalize `README.md`, `docs/DELIVERY_CHECKLIST.md`, and `docs/PROGRESS.md`.
