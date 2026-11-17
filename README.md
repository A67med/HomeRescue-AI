> **EVALUATION / 2026-11-13:** This README contains numbers from the teammate's older SQL Server run, which have NOT been re-verified on the recipient computer. For the current prepared package, first read `00_START_HERE_AR.txt` and `EVALUATION_STATUS.md`, then execute `01_RUN_PROJECT.bat` to acquire complete source data, populate the local DB, validate and generate current reports. The incomplete 2026-11-12 full CSV exports are documented in `01_Sources_and_Datasets/SOURCE_AUDIT.md`.

# HomeRescue AI — NYC Housing Maintenance Priority Data Warehouse

> **Data Mining & Data Warehousing Capstone (M0–M5 Complete)**  
> End-to-end SQL Server Medallion Data Warehouse (`bronze`, `silver`, `gold`, `semantic`, `audit`, `ml`) integrating official NYC Open Data HPD Buildings, Housing Maintenance Code Complaints & Problems, Violations, and Open Market Order (OMO) Charges.

---

## 1. Mission & Primary Business Question

New York City's Department of Housing Preservation and Development (HPD) receives hundreds of thousands of tenant complaints, issues housing maintenance code violations, and awards Open Market Orders (OMOs) when landlords fail to remediate hazardous conditions. Because inspection and emergency-repair resources are finite, housing enforcement teams require an auditable, grain-safe data warehouse to rank residential buildings by maintenance urgency and identify high-hazard properties lacking city-contracted repair intervention.

### Primary Business Question
> **Which Staten Island (`boroid = 5`) residential buildings warrant highest priority for maintenance review in calendar year 2024 (`2024-01-01` to `2024-12-31`) when combining documented tenant complaint and problem volume (`ygpa-z7cr`), open and hazardous HPD violation indicators (`wvxf-dwi5` Classes A, B, and C, separated from informational Class I), and eligible Open Market Order repair award amounts (`mdbu-nrqn`) across the complete HPD building registry (`kj4p-ruqc`)?**

---

## 2. Architecture & Medallion Schemas

`NYC Open Data Socrata API -> Raw CSVs + SHA-256 Manifest -> Bronze -> Silver -> Gold -> Semantic Layer -> Analytical Queries & Feature Views`

Every layer is implemented as a **SQL Server schema** inside a single configurable database (`homerescue_dw` by default; verified via clean rebuild in `homerescue_dw_verify`, isolated synthetic testing in `homerescue_dw_synth_fixture`, and backup/restore verification in `homerescue_dw_restore_test`):

| Schema | Purpose | Key Database Objects |
|---|---|---|
| `bronze` | Raw source data preserved 100% as `NVARCHAR` text with `bronze_row_id`, `source_dataset_id`, `source_file`, `batch_id`, and `ingested_at` provenance | `bronze.buildings` (`22,404`), `bronze.complaints_problems` (`14,377`), `bronze.violations` (`18,463`), `bronze.omo_charges` (`490`), `bronze.staging_*`, `bronze.v_load_*` |
| `silver` | Cleaned, typed, standardized, and deduplicated entities with granular rejection tracking (`silver.reject_log`) and batch reconciliation (`silver.batch_reconciliation`) | `silver.building` (`22,329`), `silver.complaint_problem` (`14,377`), `silver.violation` (`18,463`), `silver.omo_charge` (`490`), `silver.reject_log` (`75`), `silver.batch_reconciliation` (`4`) |
| `gold` | Persistent star schema dimensions (`building_key = -1` unknown member, `date_key`), atomic facts, pre-aggregated multi-fact marts, and ML feature views | `gold.dim_building` (`22,330`), `gold.dim_date` (`4,018`), `gold.fact_complaint_problem` (`14,377`), `gold.fact_violation` (`18,463`), `gold.fact_omo_charge` (`490`), `gold.fact_building_maintenance` (`22,333`), `gold.fact_building_monthly` (`267,996`), `gold.features_building_priority` (`22,333`) |
| `semantic` | Governed business metric catalog synced from `semantic/metrics.yml` (`12` metrics) and analytical views | `semantic.metric_catalog` (`12`), `semantic.v_building_priority_ranking` (`22,333`), `semantic.v_borough_zip_hazard_summary` (`13`), `semantic.v_monthly_event_trends` (`12`), `semantic.v_omo_cohort_accounting` (`5`) |
| `audit` | Pipeline execution log recording one row per load procedure / ingestion run | `audit.load_log` |
| `ml` | Reserved schema for downstream model outputs written back to SQL (deferred post-M5) | Consumes `gold.features_building_priority` |

---

## 3. Official Data Sources & 2024 Staten Island Scope

All four active datasets were extracted via the official NYC Open Data Socrata v2.1 API (`https://data.cityofnewyork.us/resource/<id>.csv`) for **Staten Island (`boroid = 5` / `STATEN ISLAND`)** across full calendar year **2024 (`2024-01-01` to `2024-12-31`)**:

| Source ID | Dataset Name | Socrata ID | Official URL | Bronze Rows | Silver Accepted | Silver Rejected | Silver Dupes |
|---|---|---|---|---:|---:|---:|---:|
| `NYC-HPD-BLDG` | HPD Buildings | `kj4p-ruqc` | https://data.cityofnewyork.us/d/kj4p-ruqc | `22,404` | `22,329` | `75` | `0` |
| `NYC-HPD-COMP` | HPD Complaints and Problems | `ygpa-z7cr` | https://data.cityofnewyork.us/d/ygpa-z7cr | `14,377` | `14,377` | `0` | `0` |
| `NYC-HPD-VIOL` | HPD Housing Maintenance Code Violations | `wvxf-dwi5` | https://data.cityofnewyork.us/d/wvxf-dwi5 | `18,463` | `18,463` | `0` | `0` |
| `NYC-HPD-OMO` | HPD Open Market Order (OMO) Charges | `mdbu-nrqn` | https://data.cityofnewyork.us/d/mdbu-nrqn | `490` | `490` | `0` | `0` |
| **Total** | **Connected 2024 Staten Island Scope** | **4 Sources** | — | **`55,734`** | **`55,659`** | **`75`** | **`0`** |

*Note:* Optional OMO Invoices (`emrz-5p35`) are explicitly deferred (`InvoiceID` is not globally unique on its own).

---

## 4. Repository Structure

```text
sql/
  00_init.sql              Database creation (homerescue_dw), schemas, and audit.load_log
  01_bronze.sql            Bronze raw tables, staging tables, load views, and load procedures
  02_silver.sql            Silver typed tables, reject_log, batch_reconciliation, and load_all
  03_gold.sql              Persistent Gold dimensions, atomic facts, grain-aligned marts, and load_all
  04_semantic.sql          semantic.metric_catalog and 4 governed semantic.v_* views
  05_feature_views.sql     gold.features_building_priority (grain: 1 row per building_id)
  06_analytics.sql         5 grain-annotated business analyses (CTEs, window functions, Pareto)
semantic/
  metrics.yml              12 governed business metrics with SQL definitions and validation queries
src/
  db.py                    Configurable SQLAlchemy engine factory (supports target_db overrides)
  run_pipeline.py          End-to-end deterministic SQL + Python warehouse build orchestrator
  ingest/                  Socrata metadata inspection, resilient extraction, and Bronze CSV loader
  quality/                 32 SQL checks + 12 metric reconciliations, profiling, and PDF generators
  semantic/                sync_metrics.py (populates semantic.metric_catalog from metrics.yml)
docs/
  PROJECT_SPEC.md          Problem statement, source contract, and architecture specification
  IMPLEMENTATION_PLAN.md   Milestone plan and template conflict resolutions
  BRONZE_REPORT.md / .pdf  M2 Bronze ingestion, reconciliation, and profiling report
  SILVER_REPORT.md / .pdf  M3 Silver cleaning, rejection, and domain rule verification report
  GOLD_REPORT.md / .pdf    M4 Gold dimensional model, semantic metrics, and 5 business analyses
  FINAL_REVIEW.md          M5 comprehensive compliance audit and verification sign-off
  DEMO_SCRIPT.md           5-to-10 minute live instructor demonstration guide
  SUBMISSION_INDEX.md      Master index mapping every deliverable, script, table, and report
  DELIVERY_CHECKLIST.md    Completed milestone and mandatory-rule sign-off matrix
  PROGRESS.md              Chronological M0–M5 execution log with exact timestamps and outputs
  data_source_register.csv Verified live Socrata metadata and SHA-256 extraction provenance
  data_dictionary.csv      686 documented columns across all 26 Bronze, Silver, Gold, Semantic & Audit objects
tests/
  test_metrics_yaml.py         Validates semantic/metrics.yml structure and required fields
  test_warehouse_validation.py Isolated synthetic fixture tests + live warehouse validation suite
```

---

## 5. Quick Start & Reproducible Execution

### Prerequisites
- **SQL Server:** Microsoft SQL Server 2019 / 2022 / 2025 (verified on `SQL Server 2025 Standard Developer Edition 17.0.1145.4` on `localhost` default instance with Windows Authentication).
- **ODBC Driver & CLI:** `ODBC Driver 18 for SQL Server` and `sqlcmd.exe`.
- **Python:** Python 3.11+ (`Python 3.12.7` at `C:\Users\Ahmed\anaconda3\python.exe` with `requirements.txt` installed).

### Option A: One-Command Full Warehouse Build & Validation
1. Copy `.env.example` to `.env` if not already present (uses Windows Authentication on `localhost`, default database `homerescue_dw`).
2. Run the end-to-end pipeline orchestrator:
   ```powershell
   & "C:\Users\Ahmed\anaconda3\python.exe" -m src.run_pipeline --target-db homerescue_dw --create-new-db
   ```
   This single command executes `sql/00_init.sql` through `sql/05_feature_views.sql`, loads all 4 CSVs from `data/raw/` into Bronze, executes `EXEC silver.load_all;` and `EXEC gold.load_all;`, syncs all 12 metrics into `semantic.metric_catalog`, executes `sql/06_analytics.sql`, and runs all 44 automated validation checks (`32` SQL checks + `12` semantic metric reconciliations).

### Option B: Clean Verification Database Rebuild & Backup/Restore Verification (M5)
To rebuild the entire warehouse from scratch in a separate verification database (`homerescue_dw_verify`), verify 100% parity against `homerescue_dw`, verify surrogate-key idempotency across reruns, and test full SQL Server `BACKUP DATABASE` / `RESTORE DATABASE`:
```powershell
& "C:\Users\Ahmed\anaconda3\python.exe" -m src.run_pipeline --target-db homerescue_dw_verify --create-new-db
& "C:\Users\Ahmed\anaconda3\python.exe" -m src.quality.verify_m5_rebuild_and_backup
```

### Option C: Run Automated Quality Checks & Pytest Suite
```powershell
& "C:\Users\Ahmed\anaconda3\python.exe" -m src.quality.run_checks
& "C:\Users\Ahmed\anaconda3\python.exe" -m pytest -v
```
- **Expected `run_checks` result:** `32 / 32` SQL checks `PASS` (`0` violations) and `12 / 12` semantic metrics `PASS` (`0.0` diff) = **`44 / 44 PASS`**.
- **Expected `pytest` result:** `3 passed` (YAML schema validation, isolated synthetic edge-case fixture database `homerescue_dw_synth_fixture` verifying duplicate removal, negative financial adjustments, invalid dates, and unmatched buildings, plus live warehouse reconciliation).

---

## 6. Key Analytical Findings (Staten Island 2024)

1. **Extreme Hazard Concentration:** Out of `22,333` buildings on the Staten Island spine (`22,329` registered + `4` unregistered `building_id`s retained via `building_key = -1`), **`18,150` buildings (`81.27%`) had zero 2024 events**, while **`476` high-hazard buildings (`2.13%` of all buildings, `maintenance_priority_score >= 25`) accounted for `92.09%` (`12,030` of `13,063`) of all Class B & C hazardous violations**.
2. **OMO Intervention Gap (`339` Unaddressed High-Hazard Buildings):** Among the `476` high-hazard buildings, `137` received `376` eligible OMO repair orders (`$751,413.00`), whereas **`339` high-hazard buildings received zero eligible OMO repair orders (`$0.00`)** despite accumulating **`4,343` Class B/C violations (`1,382` Class C, `2,961` Class B), `2,376` open violations, `203` rent-impairing violations, and `3,211` emergency complaint problems**.
3. **Top Priority Buildings:**
   - **Rank #1 Overall:** `185 PARK HILL AVENUE` (`building_id = 812537`, `ZIP 10304`, `150` units) — `maintenance_priority_score = 3,699` (`357` Class C, `442` Class B, `481` complaint problems across `217` distinct complaints, `31` eligible OMOs = `$43,348.25`).
   - **Rank #1 Unaddressed High-Hazard Building (Rank #9 Overall):** `55 BOWEN STREET` (`building_id = 767602`, `ZIP 10304`, `156` units) — `maintenance_priority_score = 631` (`64` Class C, `55` Class B, `25` rent-impairing violations, and **`0` OMO orders**).
4. **Eligible Repair Cohort vs. Demolitions:** Filtering out `32` non-eligible demolition and administrative OMO records (`$2,098,049.00`, including `$1,945,127.00` across `7` full-demolition orders) prevents a **3.13x distortion** of residential maintenance award totals (`$983,560.44` across `458` eligible orders).

---

## 7. Academic Integrity & Evidence Policy
All datasets, Socrata queries, SHA-256 hashes, SQL transformations, and validation outputs are preserved in `docs/` and `data/exports/validation/`. Every reported number is directly reproducible from SQL Server and traceable back to official NYC Open Data sources.
