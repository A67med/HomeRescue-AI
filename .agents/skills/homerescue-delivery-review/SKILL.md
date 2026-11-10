---
name: homerescue-delivery-review
description: Use this skill before completing any milestone (M0 through M5) or preparing instructor deliverables (Bronze, Silver, Gold reports, SQL scripts, and final verification database rebuild) to verify alignment with template requirements, mandatory domain rules, and the project definition of done.
---

# HomeRescue Milestone & Delivery Review Skill

> **Note:** This skill structures milestone readiness reviews; it does **not** replace executing the pipeline and validation suite on SQL Server.

## 1. Practical Review Instructions
Before marking any milestone (`M0`–`M5`) complete or submitting an instructor deliverable, audit the workspace against these five gates:

1. **Template & Repository Hygiene Gate:**
   - Main template folders (`sql/`, `src/`, `semantic/`, `docs/`, `tests/`, `notebooks/`, `data/raw/`, `data/exports/`, `models/`) and numbered SQL filenames (`00_init.sql` to `06_analytics.sql`) are intact.
   - `.env.example` contains zero secrets; `.env`, `.venv/`, `data/raw/*`, `data/exports/*`, and `*.bak`/`*.mdf`/`*.ldf` are ignored by Git.
   - Deferred components (ML models, dashboards/UI, AI assistant, budget optimization, DuckDB, Parquet, optional OMO invoices `emrz-5p35`) have not crept into the active milestone scope unless explicitly scheduled.

2. **Definition of Done Gate (`implemented, executed, validated, and documented`):**
   - **Implemented:** Code/SQL files exist at their documented paths with no `[BRACKETS]` or `TODO` placeholders remaining for the active milestone.
   - **Executed:** Scripts and procedures were actually run against SQL Server (`homerescue_dw` or verification DB in M5) and logged in `audit.load_log`.
   - **Validated:** Automated checks (`src/quality/run_checks.py`, `pytest`, reconciliation queries) were run and outputs captured.
   - **Documented:** `docs/PROGRESS.md`, `docs/DELIVERY_CHECKLIST.md`, `docs/data_dictionary.csv`, `docs/data_source_register.csv`, and the layer report (`docs/BRONZE_REPORT.md`, `docs/SILVER_REPORT.md`, or `docs/GOLD_REPORT.md`) reflect actual observed numbers.

3. **Domain & Analytical Integrity Gate:**
   - Complaint counts (`COUNT(DISTINCT complaint_id)`) and problem counts (`COUNT(problem_id)`) are clearly distinguished.
   - Class `I` violations are separated from hazard classes `A`, `B`, and `C`.
   - `OMOAwardAmount` is described strictly as an award amount for the defined repair cohort, never as proof of payment or proven preventive savings.
   - No query joins unaggregated complaints, violations, and OMO charges directly.
   - Gold dimensions use persistent surrogate keys, not recalculated `ROW_NUMBER()` views.

4. **Language & Communication Gate:**
   - All project-authored content—including code, SQL identifiers and comments, schema documentation, markdown artifacts, reports, git commit messages, and user progress updates/completion reports—must be written in clear technical **English** (zero Arabic characters in project-authored text).
   - Preserve official source data and metadata exactly as received.

## 2. Observable Acceptance Criteria
- Every deliverable listed for the current milestone in `docs/IMPLEMENTATION_PLAN.md` and `docs/DELIVERY_CHECKLIST.md` has its file path, execution log reference, and validation result recorded in `docs/PROGRESS.md`.
- Zero unverified numbers, invented column names, or placeholder strings remain in completed milestone reports.
- For M5 specifically, the entire SQL and Python pipeline runs cleanly from scratch against a fresh verification database (e.g., `homerescue_dw_verify`) and reproduces identical row counts and metric totals.

## 3. Execution & Evidence Reporting Requirement
Every milestone sign-off review must include an explicit verification matrix separating:
1. **Executed Checks (Verified with Evidence):** Check name, command/query executed, target database, and exact output.
2. **Checks Not Run (Pending / Blocked):** Check name, reason not run, and exact manual or prerequisite step needed to unblock execution.
