# Project Progress Log — HomeRescue AI

## Milestone Status Summary

| Milestone | Description | Status | Completion Date |
|---|---|---|---|
| **M0** | Inspect environment and template; establish project rules, skills, and plan | **COMPLETED** | 2026-11-10 |
| **M1** | Verify sources, choose a coherent scope, and acquire reproducible real datasets | Pending | — |
| **M2** | Implement and validate Bronze; produce its report (`docs/BRONZE_REPORT.md`) | Pending | — |
| **M3** | Implement and validate Silver; produce its report (`docs/SILVER_REPORT.md`) | Pending | — |
| **M4** | Implement and validate Gold and business metrics; produce its report (`docs/GOLD_REPORT.md`) | Pending | — |
| **M5** | Rebuild in a separate verification database and prepare the final delivery | Pending | — |

---

## M0 Execution Log (2026-11-10)

### 1. Environment Inspection Findings

| Component | Status | Observed Details |
|---|---|---|
| **SQL Server Engine** | **Available & Running** | `Microsoft SQL Server 2025 (RTM-GDR) (KB5128492) - 17.0.1145.4 (X64) Standard Developer Edition (64-bit)` on Windows 10 Enterprise (`Build 26300`). |
| **SQL Server Instances** | **2 Instances Running** | Default instance `MSSQLSERVER` (`SERVER=localhost`, server name `Ahmed`, `Status=Running`, `StartType=Automatic`) and named instance `MSSQL$SQLEXPRESS` (`Status=Running`, `StartType=Automatic`). |
| **Read-Only Connection Test** | **Succeeded** | Executed via `sqlcmd -S localhost -E -C` using Windows Authentication. Current databases on `localhost`: `master`, `model`, `msdb`, `tempdb` (`homerescue_dw` is not created yet, as expected prior to M2). |
| **SQL CLI Execution Tool** | **Installed** | `sqlcmd.exe` and `bcp.exe` installed under `C:\Program Files\Microsoft SQL Server\Client SDK\ODBC\180\Tools\Binn\` (and `170`). |
| **ODBC Drivers** | **Installed** | Both `ODBC Driver 18 for SQL Server` and `ODBC Driver 17 for SQL Server` are registered in `HKLM\SOFTWARE\ODBC\ODBCINST.INI\ODBC Drivers`. |
| **Python Interpreter** | **Installed (Needs `.venv` + Packages)** | `Python 3.14.3` at `C:\Users\Ahmed\AppData\Local\Python\bin` (and `C:\Users\Ahmed\anaconda3` present on disk). `.venv` does not exist yet in the workspace, and `requirements.txt` packages (`sqlalchemy`, `pyodbc`, `pandas`, `pyyaml`, `python-dotenv`, `pytest`) are not yet installed in the active environment. |
| **Git** | **Installed (Repo Not Initialized)** | `git version 2.56.0.windows.4` (`C:\Program Files\Git\cmd\git.exe`). Note: `E:\PROJECTS\HomeRescue-AI` does not yet have a `.git` directory (`git status` returns `fatal: not a git repository`). |
| **Local `.env` File** | **Not Created Yet** | `.env` is absent; `.env.example` is updated to point to `homerescue_dw` with zero secrets. |

---

### 2. Template Inspection & Identified Conflicts

All existing template files (`README.md`, `docs/PROJECT_SPEC.md`, `docs/data_dictionary.csv`, `docs/data_source_register.csv`, `docs/naming_conventions.md`, `sql/00_init.sql`–`sql/06_analytics.sql`, `src/**`, `semantic/metrics.yml`, `tests/**`, `notebooks/00_smoke_test.ipynb`) were inspected. Key conflicts between the starter sample code and HomeRescue AI requirements:

1. **Database Name:** Starter uses `project_dw`; HomeRescue AI requires `homerescue_dw` and configurable target database support for M5 verification rebuilds. Updated `.env.example` and `src/db.py` in M0; SQL scripts will be updated in M2–M4.
2. **Gold Surrogate Key View vs. Persistent Table (Mandatory Rule 13):** `sql/03_gold.sql` uses `CREATE OR ALTER VIEW gold.dim_entity AS SELECT ROW_NUMBER() OVER (...)`. This violates Mandatory Rule 13 and will be replaced in M4 with persistent dimension tables (`gold.dim_building`, `gold.dim_date`) with stable surrogate keys and an explicit `-1` Unknown building row (**Mandatory Rule 12**).
3. **Blanket Negative Amount Rejection (Mandatory Rule 11):** `sql/02_silver.sql` rejects all rows with `amount < 0` and `src/quality/checks.sql` flags `amount < 0`. For OMO Charges (`mdbu-nrqn`), negative or zero amounts may represent credit adjustments/reversals or cancelled orders and must be handled via field-specific business rules in M3.
4. **Single-Table Sample vs. Multi-Fact Grain Separation (Mandatory Rules 1 & 7):** Starter models one `silver.event` table. HomeRescue AI integrates 4 sources where Complaints contain nested Problems (`problem_id` inside `complaint_id`) and raw facts cannot be joined directly without fan-out.
5. **Missing vs. Failed Conversion Tracking (Mandatory Rules 9 & 10):** Starter merges missing dates and unparseable dates into `'invalid event_date'`. M3 will separate missing values from `TRY_CONVERT` failures and out-of-range dates.

---

### 3. M0 Files Created or Updated

- Created [`AGENTS.md`](file:///E:/PROJECTS/HomeRescue-AI/AGENTS.md)
- Created [`.agents/skills/homerescue-sqlserver/SKILL.md`](file:///E:/PROJECTS/HomeRescue-AI/.agents/skills/homerescue-sqlserver/SKILL.md)
- Created [`.agents/skills/homerescue-data-quality/SKILL.md`](file:///E:/PROJECTS/HomeRescue-AI/.agents/skills/homerescue-data-quality/SKILL.md)
- Created [`.agents/skills/homerescue-delivery-review/SKILL.md`](file:///E:/PROJECTS/HomeRescue-AI/.agents/skills/homerescue-delivery-review/SKILL.md)
- Updated [`docs/PROJECT_SPEC.md`](file:///E:/PROJECTS/HomeRescue-AI/docs/PROJECT_SPEC.md)
- Created [`docs/IMPLEMENTATION_PLAN.md`](file:///E:/PROJECTS/HomeRescue-AI/docs/IMPLEMENTATION_PLAN.md)
- Created [`docs/DELIVERY_CHECKLIST.md`](file:///E:/PROJECTS/HomeRescue-AI/docs/DELIVERY_CHECKLIST.md)
- Created [`docs/PROGRESS.md`](file:///E:/PROJECTS/HomeRescue-AI/docs/PROGRESS.md)
- Updated [`.env.example`](file:///E:/PROJECTS/HomeRescue-AI/.env.example), [`.gitignore`](file:///E:/PROJECTS/HomeRescue-AI/.gitignore), and [`src/db.py`](file:///E:/PROJECTS/HomeRescue-AI/src/db.py)

---

### 4. Executed Checks vs. Checks Not Run (M0 Verification Matrix)

#### Executed Checks
1. **Workspace & Template File Inventory:** Executed via `Get-ChildItem -Recurse` and `read_file` across all 26 starter files. Verified folder structure and SQL script numbering (`00_init.sql`–`06_analytics.sql`).
2. **ODBC Driver & SQL Server Registry Inspection:** Executed `Get-ItemProperty` on `HKLM:\SOFTWARE\ODBC\ODBCINST.INI\ODBC Drivers` and `HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\Instance Names\SQL`. Confirmed `ODBC Driver 18 for SQL Server` is installed and instances `MSSQLSERVER` and `SQLEXPRESS` exist.
3. **Read-Only SQL Server Connection & Version Check:** Executed `sqlcmd -S localhost -E -C -Q "SELECT @@VERSION, @@SERVERNAME, DB_NAME(); SELECT name FROM sys.databases ORDER BY name;"`. Verified `SQL Server 2025 (17.0.1145.4)` is running and accepts Windows Authentication connections.
4. **Python & Git Binary Check:** Verified `Python 3.14.3`, `C:\Users\Ahmed\anaconda3`, and `git version 2.56.0.windows.4`.

#### Checks Not Run in M0 (By Design / Pending Prerequisites)
1. **Python Package Import & `pytest` Execution:** Not run because `.venv` has not been created or populated yet (M0 rules prohibit installing software during M0).
2. **Database Creation & SQL Pipeline Execution (`sql/00_init.sql`–`sql/06_analytics.sql`):** Not run in M0; scheduled for M2–M4 after M1 verifies live NYC Open Data column schemas.
3. **Live NYC Open Data Metadata & Dataset Download:** Not run in M0; scheduled for M1.
