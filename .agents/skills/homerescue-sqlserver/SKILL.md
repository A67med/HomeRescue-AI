---
name: homerescue-sqlserver
description: Use this skill when writing, refactoring, or executing T-SQL scripts (sql/00_init.sql through sql/06_analytics.sql) or Python SQL Server ingestion/orchestration utilities for the HomeRescue AI data warehouse (homerescue_dw). Trigger whenever creating schemas, Bronze tables/views/BULK INSERT or staging procedures, Silver cleaning/rejection procedures, Gold persistent dimensions and grain-aligned facts, or semantic metric views.
---

# HomeRescue SQL Server Engineering Skill

> **Note:** This skill guides workflow and T-SQL conventions; it does **not** replace executable validation against SQL Server.

## 1. Project-Specific SQL Server Conventions
1. **Database & Schemas:**
   - Target database defaults to `homerescue_dw` (and must support rebuilding in a separate verification database such as `homerescue_dw_verify` during M5 via `sqlcmd -v DB_NAME=...` or configurable connection settings).
   - Maintain the six required schemas: `bronze`, `silver`, `gold`, `semantic`, `audit`, and `ml`.
   - Preserve the instructor template's numbered SQL script filenames:
     - `sql/00_init.sql`: Database, schemas, and `audit.load_log`.
     - `sql/01_bronze.sql`: Raw text tables, load views, and Bronze load stored procedures for Buildings (`kj4p-ruqc`), Complaints & Problems (`ygpa-z7cr`), Violations (`wvxf-dwi5`), and OMO Charges (`mdbu-nrqn`).
     - `sql/02_silver.sql`: Typed/cleaned tables, `silver.reject_log`, and transactional `silver.load_*` stored procedures.
     - `sql/03_gold.sql`: Persistent dimension tables (`gold.dim_building`, `gold.dim_date`, etc.) with stable surrogate keys and grain-explicit fact tables/views.
     - `sql/04_semantic.sql`: `semantic.metric_catalog` and governed `semantic.v_*` business metric views.
     - `sql/05_feature_views.sql`: Read-only feature views (`gold.features_*`) for downstream analysis.
     - `sql/06_analytics.sql`: Documented analytical queries answering the project's business questions with explicit result grain comments.

2. **Layer Implementation Rules:**
   - **Bronze (`bronze.*`):**
     - Store every source column as text (`VARCHAR`/`NVARCHAR`) with zero silent filtering or type coercion.
     - Include provenance columns on every Bronze table: `source_system`, `source_dataset_id`, `source_file`, `batch_id`, and `ingested_at`.
     - Log every load execution (start time, end time, row count, status, error message) to `audit.load_log`.
   - **Silver (`silver.*`):**
     - Use `SET NOCOUNT ON; SET XACT_ABORT ON;` and explicit transactions (`BEGIN TRAN ... COMMIT` with `TRY/CATCH` rollback and failure logging to `audit.load_log`).
     - Standardize building identifiers to `building_id` across all tables.
     - Distinguish source `NULL`/blank values from failed `TRY_CONVERT` conversions on non-empty strings.
     - Log all rejected rows to `silver.reject_log` with `source_table`, `business_key`, `reason`, `raw_payload_summary`, `batch_id`, and `DW_create_date`.
   - **Gold (`gold.*`):**
     - **Never** use a dynamically recalculated `ROW_NUMBER() OVER (...)` view for persistent surrogate keys. Persist dimension tables (e.g., `gold.dim_building`, `gold.dim_date`) with stable surrogate keys (`building_key`, `date_key`) and include an explicit unknown/unmatched member (`building_key = -1`) to retain facts whose `building_id` is absent from `silver.building`.
     - State the exact grain in a header comment before every fact and view definition.
     - **Never** join atomic complaint/problem rows, violation rows, and OMO charge rows directly to one another. Pre-aggregate each fact stream to a compatible grain (`building_key` or `building_key` + `year_month`) before combining across sources.

## 2. Observable Acceptance Criteria
- Every `sql/0*.sql` script executes cleanly via `sqlcmd` or SSMS with exit code `0` and is idempotent (can be re-run without error or duplicate corruption).
- `audit.load_log` contains a `SUCCESS` entry with non-null `rows_loaded` for every executed Bronze, Silver, and Gold load procedure.
- Surrogate keys in `gold.dim_*` remain identical across repeated executions of the load pipeline on the same source data.
- Every fact table/view and analytical query includes an explicit `-- GRAIN:` comment matching its actual primary/unique key.

## 3. Execution & Evidence Reporting Requirement
When reporting progress or reviewing SQL changes, always separate checks into two explicit categories:
1. **Executed Checks:** Commands and SQL queries actually run against the SQL Server instance, accompanied by exact command lines, execution timestamps, and returned row counts/values.
2. **Checks Not Run / Blocked:** Any script or validation query that was written but not executed, along with the exact reason (e.g., database not yet initialized, missing dataset file, or awaiting user action). Never report an unexecuted script as verified.
