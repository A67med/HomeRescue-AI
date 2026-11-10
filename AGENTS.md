# AGENTS.md — HomeRescue AI Project Rules & Operating Contract

## 1. Mission & Scope
**Project:** HomeRescue AI (Data Mining & Data Warehousing Capstone)  
**Objective:** Analyze NYC housing complaints, housing maintenance code violations, and Open Market Order (OMO) repair charges to identify buildings requiring maintenance review priority, grounded in documented safety indicators and repair award amounts.  
**Active Scope (M0–M5):** End-to-end SQL Server medallion data warehouse (`bronze`, `silver`, `gold`, `semantic`, `audit`, `ml`), data quality auditing, semantic business metrics, and reproducible milestone reports.  
**Deferred Scope:** Machine learning models (`src/mining/`), dashboards/UI, AI assistant (`src/assistant/`), budget optimization, DuckDB, Parquet, and optional OMO invoices (`emrz-5p35`) are deferred until after core warehouse delivery (M0–M5).

## 2. Communication, Language & Autonomous Execution Policy
- **All-English Requirement:** All project-authored content—including source code comments, docstrings, identifiers, SQL comments, generated query labels, README, specifications, plans, reports, data dictionaries, source registers, `AGENTS.md`, skills, test descriptions, validation summaries, progress records, git commit messages, and user-facing progress updates / final completion reports—must be written in **English**. Preserve official source data values and metadata verbatim as received.
- **Autonomous Execution (M1–M5):** Proceed autonomously from M1 through M5 without stopping for routine milestone approvals, executing implementation, database scripts, validation checks, and documentation updates continuously while preserving progress and evidence after each milestone.
- **Database Safety:** Never delete or overwrite an existing SQL Server database. If a planned verification or restore-test database name already exists, use a new uniquely named database. Never expose credentials or commit secrets.

## 3. Definition of Done
Every milestone, deliverable, table, procedure, view, and check is complete **only** when it is:
> **implemented, executed, validated, and documented.**

- Never claim a script, query, or check succeeded without actually executing it against the target environment and recording observable outputs.
- Always distinguish **executed checks** (with exact timestamps, row counts, and query outputs) from **unexecuted / blocked checks** (stating the exact blocker).
- Never invent column names, row counts, financial totals, or validation query results.

## 4. Architecture & Configuration Constraints
1. **Single SQL Server Database:** Default target database name is `homerescue_dw` (configurable via `.env` / environment variables so M5 can rebuild in a clean verification database such as `homerescue_dw_verify`).
2. **Required Schemas:** `bronze`, `silver`, `gold`, `semantic`, `audit`, `ml` inside `homerescue_dw`.
3. **Preserve Template Structure:** Keep the instructor's main folder structure (`sql/`, `src/`, `semantic/`, `docs/`, `tests/`, `notebooks/`, `data/raw/`, `data/exports/`, `models/`) and numbered SQL filenames (`sql/00_init.sql` through `sql/06_analytics.sql`).
4. **Division of Responsibilities:**
   - **T-SQL:** All data cleaning, type conversion, standardization, deduplication, rejection logging, dimensional loading, surrogate key management, and analytical aggregations.
   - **Python:** Data acquisition from NYC Open Data, CSV staging, pipeline orchestration, metric catalog sync, and automated validation execution.
5. **Security & Git Hygiene:**
   - `.env.example` must contain placeholder configurations only and **no secrets**.
   - `.gitignore` must exclude `.env`, virtual environments (`.venv/`, `venv/`), raw data (`data/raw/*`), exports (`data/exports/*`), and SQL Server backups/data files (`*.bak`, `*.mdf`, `*.ldf`).

## 5. Mandatory Data & Domain Rules (NYC Housing Datasets)
All SQL scripts, Python utilities, and reports must enforce these 14 mandatory rules:

1. **Complaint vs. Problem Grain (`ygpa-z7cr`):** Each row in the Complaints & Problems dataset represents a `problem_id` nested within a `complaint_id`. Always keep problem counts (`COUNT(problem_id)`) separate from distinct complaint counts (`COUNT(DISTINCT complaint_id)`).
2. **Building Identifier Normalization:** Normalize building identifiers to `building_id` (standardized integer/string business key) in Silver across all sources (some raw sources use `buildingid` or `building_id`).
3. **Violation Class Semantics (`wvxf-dwi5`):** Violation classes include `A` (non-hazardous), `B` (hazardous), `C` (immediately hazardous), and `I` (information/administrative orders). **Class `I` is not a severity level above `C`** and must not be ordinal-encoded above `C`.
4. **OMO Eligible Repair Cohort (`mdbu-nrqn`):** OMO Charges contain multiple programs and work types (e.g., demolition, commercial, routine vs. emergency). Explicitly define and filter the eligible repair cohort before describing events as emergencies.
5. **OMO Award Amount Semantics:** `OMOAwardAmount` represents an awarded contract/order amount—**not** proof of actual disbursement/payment and **not** a preventive intervention cost.
6. **Invoice Key Composite Nature (`emrz-5p35`, deferred):** `InvoiceID` alone is not a globally unique key in OMO Invoices; if used later, composite grain must be profiled first.
7. **No Fan-Out Joins Across Raw Facts:** Never join raw or atomic complaint, violation, and OMO repair facts directly to one another and sum amounts or count rows. Aggregate each fact source to a compatible grain (e.g., `building_id` or `building_id` + `year_month`) before combining across domains.
8. **Bronze Provenance & Raw Fidelity:** Preserve all raw source columns as text (`VARCHAR`/`NVARCHAR`) in Bronze with no silent cleaning, and record extraction timestamp, source identifier, `batch_id`, and `source_file` provenance.
9. **Missing Values vs. Failed Conversions & Reject Tracking:** Explicitly distinguish source `NULL`/empty values from failed type conversions (`TRY_CONVERT` failures where raw text was non-empty). Track every rejected row in `silver.reject_log` with `source_table`, `business_key`, `reason`, and batch metadata, and track duplicate removal counts so `bronze_rows = silver_valid_rows + silver_rejected_rows + silver_duplicate_rows_removed`.
10. **Plausible Date Range Validation:** Validate that converted dates fall within plausible domain ranges (e.g., not pre-1900 sentinel dates or future dates beyond extraction date) in addition to `TRY_CONVERT` syntax success.
11. **Nuanced Financial Value Rules:** Do not blindly reject all negative or zero financial fields (`OMOAwardAmount`, etc.) without field-specific business reasoning (e.g., distinguishing credit adjustments/reversals or zero-dollar cancelled orders from corrupt entries).
12. **Unmatched Record Measurement & Retention Policy:** Measure cross-source unmatched `building_id` rates (e.g., complaints/violations/OMOs referencing a `building_id` absent from `silver.building`) and apply an explicit retention policy (such as an `Unknown / Unregistered Building` dimension member with `building_key = -1` so facts are never silently dropped).
13. **Stable Surrogate Keys:** Use persistent, deterministic or identity-backed dimension tables/keys in Gold (`building_key`, `date_key`, etc.). **Never** use a dynamically recalculated `ROW_NUMBER() OVER (...)` view as a persistent surrogate-key mapping.
14. **Evidence-Based Claims Only:** Do not claim proven maintenance cost savings, causal effects, or trained risk probabilities without appropriate empirical or model evidence.
