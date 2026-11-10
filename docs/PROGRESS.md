# Project Progress Log — HomeRescue AI

## Milestone Status Summary

| Milestone | Description | Status | Completion Date |
|---|---|---|---|
| **M0** | Inspect environment and template; establish project rules, skills, and plan | **COMPLETED** | 2026-11-10 |
| **M1** | Verify sources, choose a coherent scope, and acquire reproducible real datasets | **COMPLETED** | 2026-11-10 |
| **M2** | Implement and validate Bronze; produce its report (`docs/BRONZE_REPORT.md` / `.pdf`) | **COMPLETED** | 2026-11-10 |
| **M3** | Implement and validate Silver; produce its report (`docs/SILVER_REPORT.md` / `.pdf`) | **COMPLETED** | 2026-11-10 |
| **M4** | Implement and validate Gold and business metrics; produce its report (`docs/GOLD_REPORT.md` / `.pdf`) | **COMPLETED** | 2026-11-10 |
| **M5** | Rebuild in a separate verification database (`homerescue_dw_verify`), verify backup/restore, and prepare final delivery | **COMPLETED** | 2026-11-10 |

---

## M0 Execution Log (2026-11-10)

### 1. Environment Inspection & Initial Setup Findings

| Component | Status | Observed Details |
|---|---|---|
| **SQL Server Engine** | **Available & Running** | `Microsoft SQL Server 2025 (RTM-GDR) (KB5128492) - 17.0.1145.4 (X64) Standard Developer Edition (64-bit)` on Windows 10 Enterprise (`Build 26300`). Default instance `MSSQLSERVER` on `localhost` with Windows Authentication (`sqlcmd -S localhost -E -C`). |
| **SQL CLI & ODBC Tools** | **Installed** | `sqlcmd.exe` and `bcp.exe` under `C:\Program Files\Microsoft SQL Server\Client SDK\ODBC\180\Tools\Binn\`; `ODBC Driver 18 for SQL Server` registered. |
| **Python Environment** | **Configured (`Python 3.12.7`)** | Windows Defender blocked newly created `.venv` launchers on `E:\` (`[WinError 225]`). Verified `C:\Users\Ahmed\anaconda3\python.exe` (`Python 3.12.7`) has all required libraries (`sqlalchemy 2.0.34`, `pyodbc 5.2.0`, `pandas 2.2.2`, `PyYAML 6.0.2`, `python-dotenv 1.0.1`, `pytest 7.4.4`, `requests 2.32.3`, `matplotlib 3.9.2`) and invoked it explicitly across all M1–M5 executions. |
| **Git Repository** | **Initialized** | Local Git repository initialized on branch `master`; `.gitignore` verified for `.env`, `.venv/`, `data/raw/*`, `data/exports/*`, and `*.bak`/`*.mdf`/`*.ldf`. |

### 2. Template Conflicts Identified & Resolved
1. **Database Name:** Starter hardcoded `project_dw`; updated `.env.example`, `.env`, `src/db.py`, and `sql/00_init.sql`–`sql/06_analytics.sql` to default to `homerescue_dw` and support configurable target databases (`homerescue_dw_verify`, `homerescue_dw_synth_fixture`, `homerescue_dw_restore_test`).
2. **Gold Surrogate Key View vs. Persistent Table (Mandatory Rule 13):** Replaced starter's `ROW_NUMBER()` view with persistent `gold.dim_building` and `gold.dim_date` tables and an explicit `building_key = -1` unknown building member (**Mandatory Rule 12**).
3. **Blanket Negative Amount Rejection (Mandatory Rule 11):** Replaced starter's `amount < 0` rejection with field-specific financial categorization (`POSITIVE_AWARD`, `ZERO_DOLLAR_ORDER`, `NEGATIVE_CREDIT_ADJUSTMENT`) in `silver.omo_charge`.
4. **Multi-Fact Grain Separation (Mandatory Rules 1 & 7):** Modeled separate atomic facts and pre-aggregated each domain by `building_key` / `(building_key, year_month)` before joining in Gold summary tables.
5. **Missing vs. Failed Conversion Tracking (Mandatory Rules 9 & 10):** Separated source `NULL`/blank values from `TRY_CONVERT` syntax failures and implausible dates (`< 1900-01-01` or `> 2026-12-31`).

---

## M1 Execution Log (2026-11-10)

### 1. Live Source Metadata & Scope Selection
- Executed `python -m src.ingest.inspect_sources` against `https://data.cityofnewyork.us/api/views/<id>.json` and `/resource/<id>.json`. Saved complete metadata and cross-borough 2024 volume distribution to `data/exports/source_metadata_summary.json`.
- Selected **Staten Island (`boroid = 5` / `STATEN ISLAND`)** across **full calendar year 2024 (`2024-01-01` to `2024-12-31`)**:
  - Provides a complete, non-sampled borough building spine (`22,404` buildings) and full 12-month seasonal cycle (`33,330` event rows across complaints/problems, violations, and OMO charges = `55,734` total rows).

### 2. Pilot & Full Submission Dataset Acquisition
- Executed connected pilot acquisition (`python -m src.ingest.fetch_nyc_opendata --mode pilot`) to `data/raw/pilot/` (`manifest_pilot.json`).
- Executed full 2024 Staten Island acquisition (`python -m src.ingest.fetch_nyc_opendata --mode full`) to `data/raw/` (`manifest.json`, `batch_id = 20261110T132110Z`):

| Source Key | Socrata ID | File | Extracted Rows | API Expected Count | SHA-256 Checksum |
|---|---|---|---:|---:|---|
| `buildings` | `kj4p-ruqc` | `data/raw/buildings.csv` | `22,404` | `22,404` | `2e19fa841fb9821249a3f8f4e21a2d21536b016bc03c6811fb4b9b59e70bcba8` |
| `complaints_problems` | `ygpa-z7cr` | `data/raw/complaints_problems.csv` | `14,377` | `14,377` | `f6eb1d7bc9a55ab234a397fc96abfb36995a93b60dc95a7e38ca6c9b8b439b57` |
| `violations` | `wvxf-dwi5` | `data/raw/violations.csv` | `18,463` | `18,463` | `055e14275c96150fd056a2c7224fb2fbbf2931520102bf71cb9453e89643a9d5` |
| `omo_charges` | `mdbu-nrqn` | `data/raw/omo_charges.csv` | `490` | `490` | `cd2412c717843662101bf4efeb21611d7226d354f6c0ecdd693df6d7d81ab192` |
| **Total** | — | — | **`55,734`** | **`55,734`** | **`0` drift during extraction** |

---

## M2 Execution Log (2026-11-10)

### 1. Bronze DDL, Safe Staging & CSV Ingestion
- Executed `sql/00_init.sql` and `sql/01_bronze.sql` on `homerescue_dw` (`sqlcmd -S localhost -E -C -b`).
- Executed `python -m src.ingest.load_csv --mode pilot` (`load_id` 1–4) followed by `python -m src.ingest.load_csv --mode full` (`load_id` 5–8).
- Verified transactional staging rollback (`load_id = 9` in `audit.load_log`, `status = 'FAILED'`, `bronze.buildings` remained intact at `22,404` rows).
- Executed `python -m src.quality.profile_bronze` (`data/exports/bronze_profile_summary.json`) and produced `docs/BRONZE_REPORT.md` and `docs/BRONZE_REPORT.pdf` (Committed in `3fe5e89`).

---

## M3 Execution Log (2026-11-10)

### 1. Silver Layer Transformation & Reconciliation
- Implemented and executed `sql/02_silver.sql` and `EXEC silver.load_all;` on `homerescue_dw`.
- Resolved SQL Server parallel deadlock (`Msg 1205`) in `silver.load_building` by materializing `#bldg_dedup` outside `BEGIN TRAN` with `OPTION (MAXDOP 1)`.
- Verified exact row conservation in `silver.batch_reconciliation`:
  - `bronze.buildings` (`22,404`) = `silver.building` (`22,329`) + `75` rejected (`implausible_zero_tax_block_or_lot` in `silver.reject_log`) + `0` duplicates (`diff = 0`).
  - `bronze.complaints_problems` (`14,377`) = `silver.complaint_problem` (`14,377`, `7,334` distinct complaints) + `0` rejected + `0` duplicates (`diff = 0`).
  - `bronze.violations` (`18,463`) = `silver.violation` (`18,463`: `4,763` Class C, `8,300` Class B, `2,969` Class A, `2,431` Class I) + `0` rejected + `0` duplicates (`diff = 0`).
  - `bronze.omo_charges` (`490`) = `silver.omo_charge` (`490`: `458` eligible residential repair orders = `$983,560.44`; `32` excluded orders = `$2,098,049.00`) + `0` rejected + `0` duplicates (`diff = 0`).
- Executed `python -m src.quality.profile_silver` (`data/exports/silver_profile_summary.json`) and produced `docs/SILVER_REPORT.md` and `docs/SILVER_REPORT.pdf`.

---

## M4 Execution Log (2026-11-10)

### 1. Gold Dimensional Model, Semantic Metrics & 5 Business Analyses
- Implemented and executed `sql/03_gold.sql` (`EXEC gold.load_all;`), `sql/05_feature_views.sql`, `sql/04_semantic.sql`, `semantic/metrics.yml`, and `python -m src.semantic.sync_metrics` (`Synced 12 metrics`).
- Executed `sql/06_analytics.sql` and captured all 5 business analysis outputs to `data/exports/gold_analytics_results.json`.
- Executed `python -m src.quality.run_checks`: **`32 / 32` SQL checks `PASS` (`0` failed) and `12 / 12` semantic metric reconciliations `PASS` (`0.0` diff) = `44 / 44 PASS`** (`data/exports/validation/quality_checks_results_homerescue_dw.json`).
- Executed `pytest -v` (`tests/test_metrics_yaml.py` and `tests/test_warehouse_validation.py` including isolated synthetic edge-case database `homerescue_dw_synth_fixture`): **`3 passed in 2.84s`**.
- Generated `docs/data_dictionary.csv` (`686` columns across `26` objects) and produced `docs/GOLD_REPORT.md` and `docs/GOLD_REPORT.pdf` (Committed in `7b117c5`).

---

## M5 Execution Log (2026-11-10)

### 1. Clean Verification Database Rebuild (`homerescue_dw_verify`)
- Executed `python -m src.run_pipeline --target-db homerescue_dw_verify --create-new-db` (`Completed successfully on [homerescue_dw_verify] in 14.46s (0 failed checks)`).
- Executed `python -m src.quality.verify_m5_rebuild_and_backup` (`data/exports/validation/m5_verification_and_backup_evidence.json`):
  1. **Cross-Database Parity (`homerescue_dw` vs. `homerescue_dw_verify`):** `25 / 25` tables/views and `6 / 6` bidirectional `EXCEPT` set-difference checks returned `0` differences (`100%` parity).
  2. **Idempotency & Surrogate-Key Stability Rerun:** Reran full pipeline on `homerescue_dw_verify` (`13.63s`); verified `changed_building_keys_count = 0` across all `22,330` `gold.dim_building` rows and `0` changes in financial sums (`$983,560.44` eligible, `$3,081,609.44` total).
  3. **SQL Server `.bak` Backup & Restore Verification:** Backed up `homerescue_dw` to `C:\Program Files\Microsoft SQL Server\MSSQL17.MSSQLSERVER\MSSQL\Backup\homerescue_dw.bak` (`119,630,848` bytes), restored to `homerescue_dw_restore_test`, and verified 100% row-count and financial-sum match (`PASS`).

### 2. Executed Checks vs. Unexecuted / Deferred Checks (M1–M5 Verification Matrix)

#### Executed Checks (100% Passed with Recorded Evidence)
1. **Socrata Live Metadata & Extraction Completeness Check (`M1`):** `data/raw/manifest.json` (`55,734 / 55,734` rows, `0` drift).
2. **Bronze CSV-to-SQL Row Conservation & Staging Rollback Test (`M2`):** `audit.load_log` (`load_id` 5–9), `data/exports/bronze_profile_summary.json`.
3. **Silver Row Conservation, Rejection Logging & Domain Rules (`M3`):** `silver.batch_reconciliation` (`reconciliation_diff = 0` for all 4 tables), `silver.reject_log` (`75` rows).
4. **Automated SQL Quality Suite (`M4–M5`):** `32 / 32` SQL checks `PASS` on both `homerescue_dw` and `homerescue_dw_verify`.
5. **Semantic Metric Reconciliation Suite (`M4–M5`):** `12 / 12` metrics in `semantic/metrics.yml` reconciled with `0.0000` difference against independent Silver validation queries.
6. **Pytest & Synthetic Edge-Case Fixture Suite (`M4–M5`):** `3 / 3` test suites passed (`test_metrics_yaml.py`, `test_synthetic_edge_case_fixtures_in_isolated_db` on `homerescue_dw_synth_fixture`, `test_live_warehouse_quality_and_metric_suite`).
7. **M5 Clean Rebuild, Cross-DB `EXCEPT` Parity, Idempotent Rerun & Backup/Restore Verification (`M5`):** Recorded in `data/exports/validation/m5_verification_and_backup_evidence.json` (`ALL PASS`).

#### Deferred / Out-of-Scope Items (Explicitly Scheduled Post-M5 per `AGENTS.md`)
1. **Downstream ML Model Training (`src/mining/`), Dashboards/UI, AI Assistant (`src/assistant/`), Budget Optimization, and Optional OMO Invoices (`emrz-5p35`):** Deferred by project specification (`AGENTS.md` Section 1) until after core warehouse delivery (M0–M5).
