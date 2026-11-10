# Implementation Plan: HomeRescue AI (M0–M5)

## 1. Architectural Overview & Template Reconciliation

HomeRescue AI implements an end-to-end SQL Server Medallion Data Warehouse (`homerescue_dw`) analyzing NYC HPD Buildings (`kj4p-ruqc`), Housing Complaints & Problems (`ygpa-z7cr`), Housing Maintenance Code Violations (`wvxf-dwi5`), and Open Market Order (OMO) Charges (`mdbu-nrqn`).

### Template Conflicts Identified & Resolved
During the M0 template inspection, the following differences between the starter template and HomeRescue AI requirements were identified and resolved in the design:

1. **Database Name (`project_dw` -> `homerescue_dw` configurable):**
   - *Starter Template:* Hardcodes `USE project_dw;` in `sql/00_init.sql` through `sql/06_analytics.sql` and defaults to `project_dw` in `.env.example` and `src/db.py`.
   - *Resolution:* Update `.env.example` and `src/db.py` to default to `homerescue_dw` with support for overriding the target database (`SQLSERVER_DB`), and parameterize/update the SQL scripts in M2–M4 so they run against `homerescue_dw` and can be rebuilt cleanly in a separate verification database (`homerescue_dw_verify`) during M5.
2. **Gold Surrogate Keys (`ROW_NUMBER()` View -> Persistent Tables):**
   - *Starter Template:* `sql/03_gold.sql` defines `gold.dim_entity` as a view using `ROW_NUMBER() OVER (ORDER BY entity_id) AS entity_key`.
   - *Conflict with Mandatory Rule 13:* A view using `ROW_NUMBER()` recalculates surrogate keys whenever new entities are inserted.
   - *Resolution:* In M4 (`sql/03_gold.sql`), implement `gold.dim_building` and `gold.dim_date` as **persistent tables** populated via stored procedures with stable surrogate keys (`building_key`, `date_key`) and an explicit unknown building member (`building_key = -1`) for unmatched records (**Mandatory Rule 12**).
3. **Blanket Negative Financial Rejection (`amount < 0` -> Field-Specific Logic):**
   - *Starter Template:* `sql/02_silver.sql` rejects all rows where `amount < 0`.
   - *Conflict with Mandatory Rule 11:* Real OMO Charge data (`mdbu-nrqn`) can include negative credit adjustments/reversals or zero-dollar cancelled entries that carry legitimate business meaning.
   - *Resolution:* In M3 (`sql/02_silver.sql`), distinguish unparseable financial text (`TRY_CONVERT` failure) from negative adjustments or zero-dollar orders, tagging record types rather than blindly rejecting all non-positive values.
4. **Single-Event Grain vs. Multi-Fact Grain Alignment:**
   - *Starter Template:* Models a single `silver.event` table.
   - *Conflict with Mandatory Rules 1 & 7:* HomeRescue AI integrates 4 datasets with different native grains (building, problem-within-complaint, violation, OMO charge). Joining raw fact tables causes Cartesian fan-out and inflated `SUM(OMOAwardAmount)`.
   - *Resolution:* Maintain separate atomic fact tables/views per source and pre-aggregate each fact stream to the building (`building_key`) or building-month (`building_key`, `year_month`) grain in CTEs before combining them in Gold summary tables and Semantic views.
5. **Missing Value vs. Failed Type Conversion Tracking:**
   - *Starter Template:* Combines missing `event_date` and invalid `event_date` into a single `'invalid event_date'` reason.
   - *Conflict with Mandatory Rule 9:* Must distinguish source `NULL`/blank values from failed `TRY_CONVERT` conversions on non-empty strings, and validate plausible date bounds (**Mandatory Rule 10**).
   - *Resolution:* In M3 (`sql/02_silver.sql`), evaluate `NULLIF(TRIM(col), '') IS NULL` separately from `TRY_CONVERT(...) IS NULL` and date range bounds (`< '1900-01-01'` or `> CAST(SYSDATETIME() AS DATE)`).

---

## 2. Detailed Milestone Plan (M0–M5)

Every milestone follows the strict Definition of Done: **implemented, executed, validated, and documented.**

---

### Milestone M0: Project Foundation, Environment Inspection & Governance
**Objective:** Inspect the local environment and starter template, identify conflicts and prerequisites, establish project rules and local agent skills, and document the complete implementation plan.

- **Files Created / Updated:**
  - `AGENTS.md`
  - `.agents/skills/homerescue-sqlserver/SKILL.md`
  - `.agents/skills/homerescue-data-quality/SKILL.md`
  - `.agents/skills/homerescue-delivery-review/SKILL.md`
  - `docs/PROJECT_SPEC.md`
  - `docs/IMPLEMENTATION_PLAN.md`
  - `docs/DELIVERY_CHECKLIST.md`
  - `docs/PROGRESS.md`
  - `.env.example`, `.gitignore`, `src/db.py` (aligned with `homerescue_dw` configurable connection and Git hygiene rules)
- **Dependencies:**
  - Existing workspace template files (`README.md`, `sql/*.sql`, `src/**`, `docs/**`).
  - Read-only inspection of local OS, SQL Server, ODBC drivers, Python, and Git.
- **Acceptance Checks:**
  1. All 8 required M0 output files exist and contain zero placeholder `[BRACKETS]`.
  2. All 14 mandatory data rules and the definition of done (`implemented, executed, validated, and documented`) are codified in `AGENTS.md` and `docs/PROJECT_SPEC.md`.
  3. Each of the 3 local skills contains valid YAML frontmatter (`name`, `description`), project-specific instructions, observable acceptance criteria, and the executed-vs-unexecuted check reporting requirement.
  4. Environment inspection accurately reports SQL Server version/instance, `sqlcmd`, ODBC Driver 18, Python status, and Git status without exposing credentials.
- **Completion Evidence:**
  - File verification and read-only SQL Server connection test output recorded in `docs/PROGRESS.md`.

---

### Milestone M1: Source Verification, Cohesive Scope Selection & Reproducible Data Acquisition
**Objective:** Query live NYC Open Data Socrata metadata and coverage profiles for the 4 official sources, select a cohesive pilot scope (one borough + one complete time window) so buildings, complaints/problems, violations, and OMO charges link together, and download reproducible real CSV datasets to `data/raw/`.

- **Files Created / Updated:**
  - `src/ingest/fetch_nyc_opendata.py` (parameterized Socrata API acquisition & profiling utility with batch provenance manifest)
  - `docs/data_source_register.csv` (updated with verified live metadata, exact column lists, native grains, and access timestamps)
  - `docs/data_dictionary.csv` (updated with actual source columns verified from live metadata)
  - `data/raw/buildings.csv`, `data/raw/complaints_problems.csv`, `data/raw/violations.csv`, `data/raw/omo_charges.csv`, `data/raw/manifest.json` (git-ignored raw data files)
  - `docs/PROGRESS.md` and `docs/DELIVERY_CHECKLIST.md`
- **Dependencies:**
  - M0 completed.
  - Python virtual environment `.venv` configured with `requirements.txt` packages (`pandas`, `pyyaml`, `python-dotenv`, `sqlalchemy`, `pyodbc`, `pytest`) and outbound HTTPS access to `data.cityofnewyork.us`.
- **Acceptance Checks:**
  1. Live column names and Socrata metadata verified for `kj4p-ruqc`, `ygpa-z7cr`, `wvxf-dwi5`, and `mdbu-nrqn`.
  2. Selected pilot scope (borough + start/end dates) is documented with empirical coverage counts showing cross-source `building_id` overlap (zero independent random row sampling).
  3. Extracted CSV files exist in `data/raw/` with SHA-256 checksums, exact row counts, extraction timestamps, and query filters recorded in `data/raw/manifest.json` and `docs/data_source_register.csv`.
- **Completion Evidence:**
  - Live metadata output, pilot coverage query results, file row counts, and SHA-256 hashes logged in `docs/PROGRESS.md`.

---

### Milestone M2: Bronze Layer Implementation, Execution, Validation & Report
**Objective:** Create the `homerescue_dw` database and schemas (`sql/00_init.sql`), implement raw text Bronze tables, load views, and stored procedures (`sql/01_bronze.sql`) matching the exact verified columns of the 4 official datasets plus provenance columns, load the real datasets into Bronze, validate row conservation against the raw CSV files, and produce `docs/BRONZE_REPORT.md`.

- **Files Created / Updated:**
  - `sql/00_init.sql` (creates `homerescue_dw`, schemas `bronze`, `silver`, `gold`, `semantic`, `audit`, `ml`, and `audit.load_log`)
  - `sql/01_bronze.sql` (`bronze.buildings`, `bronze.complaints_problems`, `bronze.violations`, `bronze.omo_charges`, load views, and load procedures)
  - `src/ingest/load_csv.py` (updated to load all 4 Bronze tables with batch provenance and `audit.load_log` tracking)
  - `src/quality/checks.sql` (Bronze row-count and provenance completeness checks)
  - `docs/BRONZE_REPORT.md` (instructor deliverable)
  - `docs/PROGRESS.md` and `docs/DELIVERY_CHECKLIST.md`
- **Dependencies:**
  - M1 completed (real CSV files in `data/raw/`).
  - SQL Server instance (`localhost`) accessible via `sqlcmd` and `pyodbc`.
- **Acceptance Checks:**
  1. `sql/00_init.sql` and `sql/01_bronze.sql` execute cleanly on `homerescue_dw` with zero errors.
  2. All 4 Bronze tables are populated; `COUNT(*)` in each Bronze table equals the exact data row count in its corresponding `data/raw/*.csv` file.
  3. Provenance columns (`source_dataset_id`, `source_file`, `batch_id`, `ingested_at`) are 100% populated (`0` NULLs).
  4. `audit.load_log` records `SUCCESS` rows with matching `rows_loaded` for all 4 sources.
  5. Bronze profiling queries executed to measure raw duplicate keys, missing values, unparseable dates/numbers, violation class distribution (`A`, `B`, `C`, `I`), and OMO work-type/program distribution to inform Silver rules.
- **Completion Evidence:**
  - `audit.load_log` query output, Bronze row count reconciliation table, profiling query outputs, and `docs/BRONZE_REPORT.md`.

---

### Milestone M3: Silver Layer Implementation, Execution, Validation & Report
**Objective:** Implement typed, standardized, and deduplicated Silver tables and transactional transformation procedures (`sql/02_silver.sql`), enforce all mandatory domain and data quality rules, track rejected rows in `silver.reject_log` with granular reasons, verify 100% row conservation (`Bronze = Silver + Rejected + Duplicates`), and produce `docs/SILVER_REPORT.md`.

- **Files Created / Updated:**
  - `sql/02_silver.sql` (`silver.building`, `silver.complaint_problem`, `silver.violation`, `silver.omo_charge`, `silver.reject_log`, `silver.batch_reconciliation`, and `silver.load_all` / per-entity procedures)
  - `src/quality/checks.sql` and `src/quality/run_checks.py` (expanded with Silver uniqueness, conversion vs. missingness, date bounds, violation class domain, OMO cohort, and row-conservation checks)
  - `docs/data_dictionary.csv` (updated with Silver columns, types, and quality rules)
  - `docs/SILVER_REPORT.md` (instructor deliverable)
  - `docs/PROGRESS.md` and `docs/DELIVERY_CHECKLIST.md`
- **Dependencies:**
  - M2 completed and Bronze profiling results documented.
- **Acceptance Checks:**
  1. `sql/02_silver.sql` and all `EXEC silver.load_*` procedures execute cleanly inside transactions and log `SUCCESS` to `audit.load_log`.
  2. `building_id` is normalized consistently across `silver.building`, `silver.complaint_problem`, `silver.violation`, and `silver.omo_charge` (**Mandatory Rule 2**).
  3. Missing values (`NULL`/empty) are distinguished from failed `TRY_CONVERT` conversions and out-of-range dates in `silver.reject_log` (**Mandatory Rules 9 & 10**).
  4. Violation classes `A`, `B`, `C`, and `I` are preserved accurately with Class `I` separated from hazard tiers (**Mandatory Rule 3**).
  5. OMO eligible repair cohort flag is populated and negative/zero `omo_award_amount` records are handled with explicit field-specific logic (**Mandatory Rules 4, 5 & 11**).
  6. Exact row conservation holds for every table: `Bronze Rows = Silver Valid Rows + Silver Rejected Rows + Duplicates Removed`.
  7. Cross-source unmatched `building_id` counts and percentages against `silver.building` are measured and documented (**Mandatory Rule 12**).
  8. `python -m src.quality.run_checks` exits with code `0` (`PASS` on all Silver checks).
- **Completion Evidence:**
  - `run_checks.py` output (`0` failed checks), `silver.reject_log` breakdown by table and reason, row-conservation query output, and `docs/SILVER_REPORT.md`.

---

### Milestone M4: Gold & Semantic Layers, Business Metrics, Validation & Report
**Objective:** Implement persistent Gold dimensions (`gold.dim_building` with `-1` Unknown member, `gold.dim_date`) with stable surrogate keys, grain-explicit atomic and pre-aggregated building/building-month maintenance facts (`sql/03_gold.sql`), semantic metric definitions (`semantic/metrics.yml`, `sql/04_semantic.sql`), feature views (`sql/05_feature_views.sql`), and analytical priority queries (`sql/06_analytics.sql`); validate all metrics independently; and produce `docs/GOLD_REPORT.md`.

- **Files Created / Updated:**
  - `sql/03_gold.sql` (persistent `gold.dim_building`, `gold.dim_date`, atomic facts, and pre-aggregated `gold.fact_building_maintenance` / `gold.fact_building_monthly` + `gold.load_all` procedure)
  - `sql/04_semantic.sql` (`semantic.metric_catalog` and `semantic.v_*` views)
  - `sql/05_feature_views.sql` (`gold.features_building_priority`)
  - `sql/06_analytics.sql` (business questions answered with explicit result grain comments)
  - `semantic/metrics.yml` (governed business metrics with independent `validation_query` SQL)
  - `src/quality/checks.sql` (Gold surrogate key stability, zero orphan foreign keys, no fan-out sum reconciliation, and semantic metric reconciliation checks)
  - `docs/data_dictionary.csv` (updated with Gold and Semantic objects)
  - `docs/GOLD_REPORT.md` (instructor deliverable)
  - `docs/PROGRESS.md` and `docs/DELIVERY_CHECKLIST.md`
- **Dependencies:**
  - M3 completed and validated.
- **Acceptance Checks:**
  1. `gold.dim_building` and `gold.dim_date` are persistent tables with stable surrogate keys (`building_key`, `date_key`), not recalculated `ROW_NUMBER()` views (**Mandatory Rule 13**). Re-running `EXEC gold.load_all` preserves existing `building_key` assignments.
  2. Unmatched `building_id` records map to `building_key = -1` (`Unknown / Unregistered Building`) so zero valid Silver facts are silently dropped in Gold (**Mandatory Rule 12**).
  3. Complaint counts (`COUNT(DISTINCT complaint_id)`) and problem counts (`COUNT(problem_id)`) are modeled as separate measures (**Mandatory Rule 1**).
  4. Multi-source building summary tables/views aggregate complaints, violations, and OMO charges separately before joining on `building_key` (**Mandatory Rule 7**).
  5. `SUM(omo_award_amount)` and violation/complaint counts in Gold and Semantic views match independent Silver validation queries to the exact cent/row.
  6. `pytest` (`tests/test_metrics_yaml.py`) and `python -m src.quality.run_checks` both pass with exit code `0`.
- **Completion Evidence:**
  - Gold & Semantic execution logs, independent metric validation query comparisons, `run_checks.py` and `pytest` outputs, and `docs/GOLD_REPORT.md`.

---

### Milestone M5: Clean Verification Database Rebuild & Final Delivery Package
**Objective:** Prove end-to-end reproducibility by executing the complete SQL and Python pipeline from scratch against a brand-new verification database (`homerescue_dw_verify`), comparing all row counts, reject counts, and semantic metric totals against `homerescue_dw`, and finalizing all instructor deliverables.

- **Files Created / Updated:**
  - `README.md` (finalized project documentation replacing all starter `[BRACKETS]`)
  - `tests/test_reconciliation.py` (automated end-to-end test suite)
  - `docs/DELIVERY_CHECKLIST.md` and `docs/PROGRESS.md` (final sign-off with verification DB evidence)
- **Dependencies:**
  - M0–M4 completed.
- **Acceptance Checks:**
  1. Fresh execution of `00_init.sql` through `06_analytics.sql`, Bronze ingestion, Silver loads, Gold loads, `sync_metrics.py`, and `run_checks.py` on `homerescue_dw_verify` completes with zero errors.
  2. Cross-database comparison between `homerescue_dw` and `homerescue_dw_verify` shows 100% identical row counts and metric totals across Bronze, Silver, Gold, and Semantic objects.
  3. All instructor deliverables (source links & register, project question, Bronze/Silver/Gold SQL scripts, populated DB objects, Bronze/Silver/Gold reports) are complete and verified against `.agents/skills/homerescue-delivery-review/SKILL.md`.
- **Completion Evidence:**
  - Cross-database parity query output, full `pytest` and `run_checks.py` logs, and completed `docs/DELIVERY_CHECKLIST.md`.
