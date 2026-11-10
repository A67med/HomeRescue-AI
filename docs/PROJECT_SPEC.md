# Project Specification: HomeRescue AI

## 1. Problem Statement & Core Project Question

### Domain & Operational Problem
New York City's Department of Housing Preservation and Development (HPD) receives hundreds of thousands of tenant housing complaints, issues housing maintenance code violations, and awards Open Market Orders (OMOs) when landlords fail to address hazardous conditions. Because inspection and enforcement bandwidth is finite, housing analysts and maintenance review teams need an objective, auditable way to prioritize residential buildings that exhibit severe, recurring, or unresolved safety hazards alongside high repair award exposure.

### Primary Project Question
> **Which NYC residential buildings warrant highest priority for maintenance review when combining documented tenant complaint/problem volume, open and hazardous HPD violation indicators (Classes A, B, and C, separated from informational Class I), and eligible Open Market Order (OMO) repair award amounts across a consistent geographic and temporal scope?**

### Sub-Questions Supported by the Warehouse
1. **Hazard Concentration:** Which buildings and neighborhoods (borough / community board / zip code) accumulate the highest density of Class C (immediately hazardous) and Class B (hazardous) violations per residential unit?
2. **Complaint-to-Violation Escalation:** How do distinct tenant complaint counts (`COUNT(DISTINCT complaint_id)`) and individual problem counts (`COUNT(problem_id)`) relate to verified HPD violations at the building-month and building levels?
3. **Repair Award Exposure:** Among buildings with recurring complaints and hazardous violations, what is the total and average `OMOAwardAmount` within the defined eligible repair cohort, and how is award exposure distributed across boroughs and work types?
4. **Data Completeness & Cross-Source Reconciliation:** What proportion of complaint, violation, and OMO charge records match registered buildings in the HPD Buildings master registry (`kj4p-ruqc`), and how many unmatched building references require quarantine or assignment to an unknown building dimension member?

---

## 2. Instructor Requirements vs. Project Recommendations

To maintain strict alignment with course grading criteria while addressing real-world NYC Open Data complexities, this specification distinguishes between **Instructor Template Requirements** and **Project-Specific Recommendations**:

| Area | Instructor Template Requirement | HomeRescue AI Project Specification / Recommendation |
|---|---|---|
| **Database & Schemas** | Single SQL Server database (`project_dw` in starter) containing schemas: `bronze`, `silver`, `gold`, `semantic`, `ml`, `audit`. | Named `homerescue_dw` (configurable via `.env` / `SQLSERVER_DB` so M5 can rebuild in a clean verification database `homerescue_dw_verify`). Preserves all 6 template schemas. |
| **Folder & Script Structure** | Keep `sql/00_init.sql` through `sql/06_analytics.sql`, `src/`, `semantic/metrics.yml`, `docs/`, `tests/`, `notebooks/`, `data/raw/`, `data/exports/`, `models/`. | Preserved exactly. Numbered SQL scripts remain the canonical warehouse definition executed in order. |
| **Bronze Layer** | Raw source data loaded as text (`VARCHAR`/`NVARCHAR`) with `source_file` and `ingested_at` provenance; logged to `audit.load_log`. | Extended to 4 official NYC Open Data sources with explicit `batch_id`, `source_dataset_id`, `source_file`, and `ingested_at` provenance. No silent filtering in Bronze. |
| **Silver Layer** | Typed, standardized, deduplicated tables (`silver.*`) plus `silver.reject_log` recording rejected rows and reasons; transactional load procedures. | Distinguishes missing values (`NULL`/blank) from failed `TRY_CONVERT` conversions, validates plausible date ranges, normalizes `building_id`, preserves duplicate counts for full row conservation (`Bronze = Silver + Rejected + Duplicates`), and applies nuanced rules for negative/zero financial amounts. |
| **Gold Layer & Surrogate Keys** | Starter template shows `gold.dim_entity` as a view using `ROW_NUMBER() OVER (ORDER BY entity_id)` and `gold.fact_event` as a view. | **Template Conflict Resolved:** A recalculated `ROW_NUMBER()` view produces unstable surrogate keys when new entities arrive. We replace view-based surrogate keys with **persistent Gold dimension tables** (`gold.dim_building`, `gold.dim_date`, etc.) containing stable surrogate keys and an explicit `-1` Unknown member, plus pre-aggregated/grain-compatible fact tables and views to prevent fan-out joins across complaints, violations, and OMO charges. |
| **Scope & Phasing** | Template includes starter placeholders for ML (`src/mining/baseline.py`) and AI copilot (`src/assistant/copilot.py`). | **Active Scope (M0–M5):** Warehouse foundation, M1 pilot & full dataset acquisition, M2 Bronze + report, M3 Silver + report, M4 Gold & Semantic metrics + report, M5 clean verification DB rebuild. **Deferred:** ML modeling, dashboards/UI, AI assistant, budget optimization, DuckDB, Parquet, and optional OMO invoices (`emrz-5p35`). |

---

## 3. Official Data Sources & Source Contract

Every dataset must be registered in [`docs/data_source_register.csv`](file:///E:/PROJECTS/HomeRescue-AI/docs/data_source_register.csv) and verified against live Socrata API metadata during **M1** before finalizing Bronze column definitions. Column names, row counts, and data types must never be invented.

| Source ID | Dataset Name | Official NYC Open Data URL | Socrata 4x4 ID | Role in Warehouse | Native Grain & Key Notes (to verify against live metadata in M1) |
|---|---|---|---|---|---|
| `NYC-HPD-BLDG` | Buildings | https://data.cityofnewyork.us/d/kj4p-ruqc | `kj4p-ruqc` | Core Building Master (`bronze.buildings` -> `silver.building` -> `gold.dim_building`) | One row per registered building record (`buildingid` / `building_id`). Provides borough, block, lot, BIN, BBL, address, unit counts, and building attributes. |
| `NYC-HPD-COMP` | Housing Maintenance Code Complaints and Problems | https://data.cityofnewyork.us/d/ygpa-z7cr | `ygpa-z7cr` | Tenant Complaints & Problems (`bronze.complaints_problems` -> `silver.complaint_problem`) | **Mandatory Rule 1:** One row per `problem_id` nested within a `complaint_id`. Problem counts (`COUNT(problem_id)`) must be kept distinct from complaint counts (`COUNT(DISTINCT complaint_id)`). |
| `NYC-HPD-VIOL` | Housing Maintenance Code Violations | https://data.cityofnewyork.us/d/wvxf-dwi5 | `wvxf-dwi5` | Official Code Violations (`bronze.violations` -> `silver.violation`) | One row per HPD violation (`violationid`). **Mandatory Rule 3:** Violation classes include `A`, `B`, `C`, and `I`. Class `I` is informational/administrative, **not** a hazard severity level above `C`. |
| `NYC-HPD-OMO` | Open Market Order (OMO) Charges | https://data.cityofnewyork.us/d/mdbu-nrqn | `mdbu-nrqn` | Repair Orders & Award Amounts (`bronze.omo_charges` -> `silver.omo_charge`) | One row per OMO charge/order record. **Mandatory Rules 4 & 5:** Contains multiple programs and work types; eligible repair cohort must be explicitly defined. `OMOAwardAmount` is an awarded order amount, not proof of payment or preventive cost savings. |
| `NYC-HPD-INV` *(Deferred)* | Open Market Order (OMO) Invoices | https://data.cityofnewyork.us/d/emrz-5p35 | `emrz-5p35` | Optional / Deferred | **Mandatory Rule 6:** Deferred from M0–M5 core warehouse scope. If integrated in a future milestone, note that `InvoiceID` alone is not globally unique. |

### Acquisition Strategy (M1 Pilot -> Expansion)
- **Connected Pilot Scope First:** In M1, after inspecting live Socrata metadata and date/borough distributions, we will select **one borough** and **one complete, contiguous time window** so that Buildings, Complaints/Problems, Violations, and OMO Charges form a referentially connected cohort.
- **No Unrelated Random Sampling:** We will never sample independent random rows from each dataset, as doing so destroys cross-source `building_id` joinability.
- **Scale Expansion:** Once the pilot cohort passes end-to-end validation, the scope can be expanded reproducibly using the same parameterized acquisition scripts.

---

## 4. Target Entities & Medallion Layer Architecture

### Target Entities
1. **Building (`building`):** Physical/registered HPD building attributes, geography (borough, zip, BIN, BBL, community board), and residential unit counts.
2. **Complaint & Problem (`complaint_problem`):** Tenant-reported complaints (`complaint_id`) and their constituent problem items (`problem_id`), status, and timestamps.
3. **Violation (`violation`):** HPD inspection violations (`violation_id`), hazard class (`A`, `B`, `C`, `I`), inspection/approved/certified dates, and current status.
4. **OMO Charge (`omo_charge`):** Open Market Order records (`omo_number` / charge identifier), program/work type, eligible repair cohort flag, award/creation dates, and `omo_award_amount`.

### Layer Specifications
- **Bronze (`bronze.*`):**
  - Exact text representation (`VARCHAR`/`NVARCHAR`) of each extracted CSV file.
  - Mandatory provenance columns: `source_dataset_id`, `source_file`, `batch_id`, `ingested_at`.
  - No silent filtering, deduplication, or type conversion.
- **Silver (`silver.*`):**
  - Standardized column names (`lowercase_snake_case`), including normalized `building_id` across all tables (**Mandatory Rule 2**).
  - Explicit separation of source missing values (`NULL`/empty) vs. failed type conversions (`TRY_CONVERT` failure on non-empty text) (**Mandatory Rule 9**).
  - Plausible date range checks (rejecting sentinel dates `< 1900-01-01` or future dates beyond extraction date) (**Mandatory Rule 10**).
  - Field-specific financial validation for `OMOAwardAmount`—documenting and categorizing zero or negative adjustments rather than blindly rejecting all non-positive values (**Mandatory Rule 11**).
  - All rejected records written to `silver.reject_log` with `source_table`, `business_key`, `reason`, and `batch_id`.
  - Full row conservation verified: `Bronze Rows = Silver Valid Rows + Silver Rejected Rows + Duplicates Removed`.
- **Gold (`gold.*`):**
  - **Persistent Dimensions (**Mandatory Rule 13**):**
    - `gold.dim_building`: Persistent table with stable surrogate key `building_key`, natural key `building_id`, and an explicit `-1` Unknown/Unmatched building row so facts with unmatched `building_id` values are retained and measured (**Mandatory Rule 12**).
    - `gold.dim_date`: Persistent calendar dimension (`date_key` in `YYYYMMDD` integer format).
    - Additional conformed role/category attributes (e.g., violation class, OMO work type/program cohort).
  - **Atomic & Aggregated Facts (**Mandatory Rule 7**):**
    - Atomic facts (`gold.fact_complaint_problem`, `gold.fact_violation`, `gold.fact_omo_charge`) each declare their exact grain.
    - Cross-domain summary fact/mart (`gold.fact_building_maintenance_summary` or `gold.fact_building_monthly_summary`) pre-aggregates each atomic fact to the common `building_key` (or `building_key` + `year_month`) grain **before** combining them. Raw complaint, violation, and OMO tables are **never** joined directly to one another.
- **Semantic (`semantic.*`):**
  - `semantic.metric_catalog` populated from `semantic/metrics.yml` via `python -m src.semantic.sync_metrics`.
  - Governed SQL views (`semantic.v_*`) exposing priority indicators, violation hazard counts (`A`, `B`, `C` vs. `I`), distinct complaint vs. problem counts, and eligible OMO award totals with independent validation queries.

---

## 5. Mandatory Data Rules Checklist

1. **Complaint vs. Problem Grain:** Keep `COUNT(problem_id)` separate from `COUNT(DISTINCT complaint_id)`.
2. **Building ID Normalization:** Standardize `buildingid` / `building_id` to `building_id` in Silver.
3. **Violation Class Semantics:** Treat Classes `A`, `B`, `C` as hazard tiers and Class `I` as informational/administrative (never ranked above `C`).
4. **OMO Eligible Cohort Definition:** Define and filter the eligible repair cohort across OMO programs/work types before labeling events as emergency repairs.
5. **Award Amount Interpretation:** Describe `OMOAwardAmount` strictly as an award amount, not proof of disbursement or preventive cost savings.
6. **Invoice Key Awareness:** Recognize `InvoiceID` (`emrz-5p35`, deferred) is not globally unique on its own.
7. **Grain-First Multi-Fact Combining:** Never join atomic complaint, violation, and OMO rows directly; aggregate each to a shared building or building-period grain first.
8. **Bronze Provenance:** Store raw text plus extraction timestamp, source identifier, `batch_id`, and file path.
9. **Missing vs. Failed Conversion & Accounting:** Distinguish `NULL`s from conversion errors and verify `Bronze = Silver + Rejected + Duplicates`.
10. **Plausible Date Validation:** Check both valid date parsing and domain-plausible date bounds.
11. **Nuanced Financial Validation:** Evaluate negative/zero financial values using domain logic rather than a blanket `amount < 0` rejection.
12. **Unmatched Building Tracking:** Measure unmatched `building_id` rates across sources and retain unmatched facts via an explicit `-1` dimension key policy.
13. **Persistent Surrogate Keys:** Use persistent dimension tables with stable surrogate keys instead of recalculated `ROW_NUMBER()` views.
14. **Evidence-Grounded Reporting:** Make no claims of proven cost savings or trained predictive risk probabilities without empirical evidence.

---

## 6. SQL & Testing Requirements

### Required SQL Capabilities Demonstrated Across `sql/00_init.sql`–`sql/06_analytics.sql`
- Multi-source integration via pre-aggregated CTEs (`WITH ...`)
- Window functions (`ROW_NUMBER()`, `DENSE_RANK()`, rolling/cumulative summaries)
- Conditional aggregation (`SUM(CASE WHEN ... END)`, `COUNT(DISTINCT CASE WHEN ... END)`)
- Transactional error handling (`TRY...CATCH`, `XACT_ABORT`, `audit.load_log`)
- Data quality & reconciliation queries (`src/quality/checks.sql`)
- Persistent dimensional loading and semantic metric views (`semantic.v_*`)

### Automated Validation Suite
- **YAML Schema Test:** `pytest tests/test_metrics_yaml.py` validates `semantic/metrics.yml`.
- **SQL Quality & Reconciliation Checks:** `python -m src.quality.run_checks` executes `src/quality/checks.sql` and verifies 0 failing rows across uniqueness, non-null keys, domain values, date bounds, Bronze-to-Silver row conservation, and Silver-to-Gold metric reconciliation.

---

## 7. Project Milestones (M0–M5)

- **M0:** Inspect environment and template; establish project rules, skills, and comprehensive plan.
- **M1:** Verify live NYC Open Data metadata, select a connected pilot scope (borough + time window), and acquire reproducible real datasets.
- **M2:** Implement, execute, and validate the Bronze layer (`sql/00_init.sql`, `sql/01_bronze.sql`, ingestion scripts); produce `docs/BRONZE_REPORT.md`.
- **M3:** Implement, execute, and validate the Silver layer (`sql/02_silver.sql`, quality checks); produce `docs/SILVER_REPORT.md`.
- **M4:** Implement, execute, and validate the Gold & Semantic layers (`sql/03_gold.sql`, `sql/04_semantic.sql`, `sql/05_feature_views.sql`, `sql/06_analytics.sql`, `semantic/metrics.yml`); produce `docs/GOLD_REPORT.md`.
- **M5:** Rebuild the entire warehouse from scratch in a separate verification database (`homerescue_dw_verify`), verify end-to-end reproducibility, and package final instructor deliverables.
