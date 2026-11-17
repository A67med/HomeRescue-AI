# Bronze Layer & Data Acquisition Report (`M1`–`M2`) — HomeRescue AI

## 1. Executive Summary & Coherent Scope Selection

The **HomeRescue AI** Bronze layer ingests four official New York City Department of Housing Preservation and Development (HPD) datasets published on the NYC Open Data (Socrata) portal into the SQL Server database `homerescue_dw` (`bronze` schema).

### Scope Selection Rationale
To ensure that all four datasets form a referentially coherent cohort without arbitrary or independent row sampling, we profiled live Socrata metadata and borough-by-year distributions (`data/exports/validation/m1_scope_profile.json`) across 2023–2025:

| Borough (`boroid`) | Registered Buildings (`kj4p-ruqc`) | 2024 Complaints & Problems (`ygpa-z7cr`) | 2024 Violations (`wvxf-dwi5`) | 2024 OMO Charges (`mdbu-nrqn`) | Total 2024 Cohort Rows |
|---|---:|---:|---:|---:|---:|
| **Staten Island (`5`) — Selected Submission Scope** | **22,404** | **14,377** | **18,463** | **490** | **55,734** |
| Staten Island (`5`) — 2025 Comparison | 22,404 | 13,432 | 18,535 | 401 | 54,772 |
| Manhattan (`1`) — 2024 Comparison | 40,798 | 174,429 | 156,453 | 4,866 | 376,546 |
| Bronx (`2`) — 2024 Comparison | 51,606 | 290,895 | 359,201 | 8,645 | 710,347 |

**Selected Submission Scope:**
- **Geography:** **Staten Island** (`boroid = 5` / `borough = 'STATEN ISLAND'` / `boro_id = 5`).
- **Building Reference Population:** **100% of registered Staten Island HPD buildings** (`22,404` buildings), including buildings with zero complaints, violations, or OMO charges in 2024.
- **Shared Event Time Window:** **Complete Calendar Year 2024** (`2024-01-01T00:00:00.000` through `2024-12-31T23:59:59.999`), filtered by source-appropriate primary event timestamps:
  - Complaints & Problems (`ygpa-z7cr`): `received_date`
  - Housing Maintenance Code Violations (`wvxf-dwi5`): `inspectiondate`
  - Open Market Order (OMO) Charges (`mdbu-nrqn`): `omocreatedate`
- **Connected Pilot Validation First:** Before loading the full 2024 calendar year, we executed and validated a connected 1-month pilot (`2024-01-01` to `2024-01-31` in Staten Island: `22,404` buildings, `1,826` complaint problems, `1,264` violations, `25` OMO charges; evidence saved in `data/raw/pilot/manifest_pilot.json` and `data/exports/validation/m1_pilot_bronze_reconciliation.json`).

---

## 2. Official Sources, Extraction Queries & SHA-256 Checksums

All datasets were acquired via [`src/ingest/fetch_nyc_opendata.py`](file:///E:/PROJECTS/HomeRescue-AI/src/ingest/fetch_nyc_opendata.py) using deterministic primary-key ordering (`$order`), explicit column lists preserving official Socrata column order (`$select`), bounded retries with exponential backoff, and pre-/post-extraction Socrata count checks (`data/raw/manifest.json`).

| Source ID | Bronze Table | Socrata ID & Portal URL | Deterministic `$order` | Exact Socrata `$where` Filter | File Size (Bytes) | SHA-256 Checksum (`data/raw/*.csv`) |
|---|---|---|---|---|---:|---|
| `NYC-HPD-BLDG` | `bronze.buildings` | [`kj4p-ruqc`](https://data.cityofnewyork.us/d/kj4p-ruqc) | `buildingid ASC` | `boroid = 5` | 2,819,724 | `047d9fea63553669a8b4e8922afe6899fad90ac3776455a4d514aacf1dbe06c2` |
| `NYC-HPD-COMP` | `bronze.complaints_problems` | [`ygpa-z7cr`](https://data.cityofnewyork.us/d/ygpa-z7cr) | `problem_id ASC` | `borough = 'STATEN ISLAND' AND received_date >= '2024-01-01T00:00:00.000' AND received_date <= '2024-12-31T23:59:59.999'` | 8,469,349 | `9c9ee7ae2c992a555cb4234b4611b62cfc0091f16b7ed30f5eea7dab5ebac4aa` |
| `NYC-HPD-VIOL` | `bronze.violations` | [`wvxf-dwi5`](https://data.cityofnewyork.us/d/wvxf-dwi5) | `violationid ASC` | `boroid = 5 AND inspectiondate >= '2024-01-01T00:00:00.000' AND inspectiondate <= '2024-12-31T23:59:59.999'` | 10,686,038 | `2ad337d7513af9cf5cbe353ad6b6297dbb07576c1d1ffc7477e0a43589022054` |
| `NYC-HPD-OMO` | `bronze.omo_charges` | [`mdbu-nrqn`](https://data.cityofnewyork.us/d/mdbu-nrqn) | `omoid ASC` | `boro_id = 5 AND omocreatedate >= '2024-01-01T00:00:00.000' AND omocreatedate <= '2024-12-31T23:59:59.999'` | 194,170 | `109fd02086d810a5c54f184c1b292cd83b67200a490d1fd19fb86d89d8486b54` |

---

## 3. Source-to-Bronze Reconciliation & Provenance Completeness

Each file was parsed using Python's RFC-4180 `csv.reader` (rather than physical line count, to properly handle quoted commas and descriptions) and loaded into SQL Server via [`src/ingest/load_csv.py`](file:///E:/PROJECTS/HomeRescue-AI/src/ingest/load_csv.py) and the stored procedures in [`sql/01_bronze.sql`](file:///E:/PROJECTS/HomeRescue-AI/sql/01_bronze.sql).

| Bronze Table | Source Columns | Pre-Extraction API Count | Post-Extraction API Count | Live Drift During Fetch | CSV Physical Lines | Parsed CSV Data Rows | Loaded `bronze.*` Rows | Null Provenance Rows | Status |
|---|---:|---:|---:|---|---:|---:|---:|---:|---|
| `bronze.buildings` | 23 | 22,404 | 22,404 | `false` (`0`) | 22,405 | **22,404** | **22,404** | 0 | **PASS** |
| `bronze.complaints_problems` | 33 | 14,377 | 14,377 | `false` (`0`) | 14,378 | **14,377** | **14,377** | 0 | **PASS** |
| `bronze.violations` | 41 | 18,463 | 18,463 | `false` (`0`) | 18,464 | **18,463** | **18,463** | 0 | **PASS** |
| `bronze.omo_charges` | 32 | 490 | 490 | `false` (`0`) | 491 | **490** | **490** | 0 | **PASS** |
| **Total** | **129** | **55,734** | **55,734** | **0** | **55,738** | **55,734** | **55,734** | **0** | **PASS** |

---

## 4. Bronze Architecture, Provenance & Safe Staging Verification

### Raw Fidelity & Traceability Columns
Every Bronze table in [`sql/01_bronze.sql`](file:///E:/PROJECTS/HomeRescue-AI/sql/01_bronze.sql) stores all source fields as `NVARCHAR` text without silent truncation or type conversion, plus six technical/provenance columns:
- `bronze_row_id BIGINT IDENTITY(1,1) PRIMARY KEY`: Immutable database surrogate row identifier.
- `raw_row_num BIGINT NOT NULL`: 1-based parsed CSV record position (`1..N`) from the source file.
- `source_dataset_id VARCHAR(50) NOT NULL`: Socrata 4x4 dataset identifier (`kj4p-ruqc`, `ygpa-z7cr`, `wvxf-dwi5`, `mdbu-nrqn`).
- `source_file NVARCHAR(500) NOT NULL`: Resolved path of the ingested CSV file.
- `batch_id UNIQUEIDENTIFIER NOT NULL`: Execution batch identifier linking to `audit.load_log`.
- `ingested_at DATETIME2 NOT NULL`: Timestamp when the row was committed to Bronze.

### Safe Staging Swap & Rollback Verification
Each Bronze load procedure (`bronze.load_buildings`, `bronze.load_complaints_problems`, `bronze.load_violations`, `bronze.load_omo_charges`) stages incoming data into `bronze.stg_<entity>` first and validates `@staged_cnt > 0` **before** opening a transaction to truncate and reload `bronze.<entity>`.

To verify that a failed load preserves the last valid dataset:
1. After loading `22,404` rows into `bronze.buildings` (`load_id = 5`), we truncated `bronze.stg_buildings` and executed `EXEC bronze.load_buildings @file_path = N'deliberate_empty_stage_test.csv', @use_staged = 1`.
2. The procedure raised error `50001` (`Staging table bronze.stg_buildings is empty; aborting load to preserve existing bronze.buildings data.`), logged `status = 'FAILED'` in `audit.load_log` (`load_id = 9`), and left all **`22,404` rows** in `bronze.buildings` completely intact.

### Observed `audit.load_log` Entries (`homerescue_dw`)

| `load_id` | `batch_id` | `source_name` | `target_table` | `rows_loaded` | `status` | `message` |
|---:|---|---|---|---:|---|---|
| 1 | `F862C9A9-926B-4DE7-BDB2-1B53C9DE448B` | `kj4p-ruqc:buildings` | `bronze.buildings` | 22,404 | `SUCCESS` | Bronze buildings loaded via safe staging swap (Pilot) |
| 2 | `F862C9A9-926B-4DE7-BDB2-1B53C9DE448B` | `ygpa-z7cr:complaints_problems` | `bronze.complaints_problems` | 1,826 | `SUCCESS` | Bronze complaints_problems loaded via safe staging swap (Pilot) |
| 3 | `F862C9A9-926B-4DE7-BDB2-1B53C9DE448B` | `wvxf-dwi5:violations` | `bronze.violations` | 1,264 | `SUCCESS` | Bronze violations loaded via safe staging swap (Pilot) |
| 4 | `F862C9A9-926B-4DE7-BDB2-1B53C9DE448B` | `mdbu-nrqn:omo_charges` | `bronze.omo_charges` | 25 | `SUCCESS` | Bronze omo_charges loaded via safe staging swap (Pilot) |
| 5 | `2C58437F-93E9-4F5E-ADEA-4697C294E30F` | `kj4p-ruqc:buildings` | `bronze.buildings` | 22,404 | `SUCCESS` | Bronze buildings loaded via safe staging swap (Full 2024) |
| 6 | `2C58437F-93E9-4F5E-ADEA-4697C294E30F` | `ygpa-z7cr:complaints_problems` | `bronze.complaints_problems` | 14,377 | `SUCCESS` | Bronze complaints_problems loaded via safe staging swap (Full 2024) |
| 7 | `2C58437F-93E9-4F5E-ADEA-4697C294E30F` | `wvxf-dwi5:violations` | `bronze.violations` | 18,463 | `SUCCESS` | Bronze violations loaded via safe staging swap (Full 2024) |
| 8 | `2C58437F-93E9-4F5E-ADEA-4697C294E30F` | `mdbu-nrqn:omo_charges` | `bronze.omo_charges` | 490 | `SUCCESS` | Bronze omo_charges loaded via safe staging swap (Full 2024) |
| 9 | `F1807742-1A13-424D-A960-F6592218816B` | `kj4p-ruqc:buildings` | `bronze.buildings` | `NULL` | `FAILED` | Staging table bronze.stg_buildings is empty; aborting load to preserve existing bronze.buildings data. |

---

## 5. Empirical Bronze Profiling Findings (Informing M3 Silver Rules)

All profiling queries were executed against `homerescue_dw` via [`src/quality/profile_bronze.py`](file:///E:/PROJECTS/HomeRescue-AI/src/quality/profile_bronze.py) (`data/exports/validation/m2_bronze_profile_homerescue_dw.json`).

### 5.1 Buildings (`bronze.buildings` — 22,404 rows)
- **Natural Key (`buildingid`):** `0` missing, `0` unparseable integers, `0` duplicates (`22,404` distinct `buildingid` values).
- **Missing Optional Attributes:** `zip` is missing in `34` rows; `bin` is missing in `592` rows; `legalclassa` (Class A apartment count) is missing in `895` rows; `legalstories` is missing in `867` rows (`0` invalid or negative numeric strings).
- **Structural / Lifecycle Anomalies Identified for Silver Policy:**
  - `75` rows have `block = 0` or `lot = 0` (including `1` row with placeholder `housenumber = '0'`).
  - Lifecycle/status breakdown includes `20,658` Active Pvt Buildings, `721` Inactive Pvt Buildings, `503` Demolished buildings (`489` PVT + `14` Central Mgt), `233` Land parcels, `75` Pending buildings, `44` UnderConstruction, and `18` Planned records.
  - **Silver Implication:** In `silver.building`, reject rows with invalid/placeholder tax parcel or street address (`block <= 0 OR lot <= 0 OR housenumber IN ('0', '00')`, which rejects the `75` invalid parcel/address records into `silver.reject_log` with explicit reasons while retaining all valid building records and tracking `is_active_building` / `lifecycle`).

### 5.2 Complaints & Problems (`bronze.complaints_problems` — 14,377 rows)
- **Grain Verification (Mandatory Rule 1):** `14,377` distinct `problem_id` rows nested within `7,334` distinct `complaint_id` records (`1.96` problems per complaint). `0` missing or unparseable keys; `0` duplicate `problem_id` rows.
- **Dates:** `received_date` spans `2024-01-01` to `2024-12-31` (`0` missing, `0` unparseable, `0` out-of-range). `complaint_status_date` and `problem_status_date` also have `0` missing and `0` unparseable values.
- **Duplicate Problem Reports (`problem_duplicate_flag`):**
  - `13,447` rows have `problem_duplicate_flag = 'N'`.
  - `930` rows (`910` `EMERGENCY` and `20` `IMMEDIATE EMERGENCY`) have `problem_duplicate_flag = 'Y'` (flagged by HPD as duplicate problem submissions).
  - **Silver Implication:** Preserve `problem_duplicate_flag` as an explicit boolean/flag attribute (`is_duplicate_problem_flag`) in `silver.complaint_problem` so analysts can evaluate both total reported problems (`14,377`) and non-duplicate problems (`13,447`), while checking `problem_id` uniqueness.

### 5.3 Housing Maintenance Code Violations (`bronze.violations` — 18,463 rows)
- **Natural Key (`violationid`):** `18,463` distinct `violationid` rows (`0` missing, `0` unparseable, `0` duplicates).
- **Violation Class Distribution (Mandatory Rule 3):**
  - **Class `A` (Non-Hazardous):** `2,969` rows (`847` Open, `2,122` Close; `8` Rent-Impairing).
  - **Class `B` (Hazardous):** `8,300` rows (`2,709` Open, `5,591` Close; `442` Rent-Impairing).
  - **Class `C` (Immediately Hazardous):** `4,763` rows (`896` Open, `3,867` Close; `271` Rent-Impairing).
  - **Class `I` (Informational / Administrative Orders):** `2,431` rows (`1,258` Open, `1,173` Close; `0` Rent-Impairing, and all `2,431` have `novissueddate IS NULL` because Class `I` orders do not generate a Notice of Violation).
  - `0` missing or unexpected class codes.

### 5.4 Open Market Order (OMO) Charges (`bronze.omo_charges` — 490 rows)
- **Natural Keys (`omoid` & `omonumber`):** `490` distinct `omoid` values and `490` distinct `omonumber` values (`0` missing, `0` duplicates on either key).
- **Financial Values (Mandatory Rules 5 & 11):**
  - `omoawardamount`: `0` missing, `0` unparseable, `0` negative, **`22` zero-dollar rows (`$0.00`)**, and **`468` positive rows** (`$1.00` to `$545,989.00`), totaling **`$3,081,609.44`**.
  - `netchangeorders`: `490` rows all equal `$0.00` (`0` missing, `0` unparseable).
  - Inspection of the `22` zero-dollar (`$0.00`) OMO rows reveals that all `22` also have `omoawarddate IS NULL` and represent un-awarded/cancelled/administrative orders (`5` `Duplicate OMO`, `4` `landlord Restored Service`, `1` `For Field Visits Only - Cancelled`, `5` `Other`, and `7` `NULL` status reason including `1` `Vacant Land` demolition).
  - Furthermore, `1` positive-dollar OMO row (`omoid = 5481589` / `worktypegeneral = 'GC'`, `$250.00`, `servicechargeflag = 'True'`) has `omostatusreason = 'Duplicate OMO'`.
- **Work Types & Eligible Repair Cohort (Mandatory Rule 4):**
  - Work types include `GC` (`344` rows, `$668,865.50`), `PLUMB` (`26` rows, `$160,520.00`), `DELEAD` (`34` rows, `$119,932.90`), `ASBEST` (`22` rows, `$33,948.70`), `UTIL` (`32` rows, `$734.34`), `DEMOL` (`9` rows, `$2,075,686.00`—including `1` commercial demolition `$545,989.00` and `1` vacant land demolition `$0.00`), `HEAT` (`4` rows, `$32,980.00`), `STOPAG` (`3` rows, `$4,910.00`), `ELEC` (`2` rows, `$1,595.00`), `ELEV` (`2` rows, `$0.00`), and `EXTERM` (`1` row, `$1,500.00`).
  - **Silver Implication:** In `silver.omo_charge`, we classify financial status (`positive_award` vs. `zero_dollar_un_awarded_or_cancelled`) and explicitly define `is_eligible_repair_cohort = 1` as residential building maintenance/repair orders where:
    1. `ISNULL(iscommercialdemolition, '') <> 'COMM DEMOL'` (excludes commercial demolitions),
    2. `worktypegeneral <> 'DEMOL'` and `lifecycle = 'Standing Building'` (excludes structural demolitions and vacant land),
    3. `ISNULL(omostatusreason, '') NOT IN ('Duplicate OMO', 'For Field Visits Only - Cancelled')`, and
    4. `omo_award_amount > 0`.

### 5.5 Cross-Source Unmatched `building_id` Discovery (Mandatory Rule 12)
Comparing normalized `building_id` across the event tables against `bronze.buildings` (`22,404` buildings):
- `bronze.complaints_problems`: `14,342` matched (`99.76%`), **`35` unmatched rows (`0.24%`)**—all 35 rows belong to `building_id = 912070` (`460N BRIELLE AVENUE, ZIP 10314, Block 955, Lot 75`).
- `bronze.violations`: `18,446` matched (`99.91%`), **`17` unmatched rows (`0.09%`)**—all 17 rows also belong to `building_id = 912070` (`460N BRIELLE AVENUE`).
- `bronze.omo_charges`: `484` matched (`98.78%`), **`6` unmatched rows (`1.22%`)** across `4` distinct `building_id` values: `1012831` (`281 JOHNSTON TERRACE`, 3 rows), `748099` (`6663 HYLAN BOULEVARD`, 1 row), `888686` (`251 SOMMER AVENUE`, 1 row), and `912070` (`460N BRIELLE AVENUE`, 1 row).

---

## 6. Executed Checks vs. Checks Not Run (M1–M2 Verification Matrix)

### Executed Checks
1. **Live Socrata Metadata Verification:** Executed `python -m src.ingest.inspect_sources` at `2026-11-10T13:46:29Z`; saved column schemas and metadata to `data/exports/validation/m1_live_source_metadata.json` (`PASS`).
2. **Borough & Calendar-Year Coverage Profile:** Executed `python -m src.ingest.inspect_sources --profile-only` at `2026-11-10T13:52:32Z`; saved results to `data/exports/validation/m1_scope_profile.json` (`PASS`).
3. **Connected Pilot & Full 2024 Dataset Acquisition:** Executed `python -m src.ingest.fetch_nyc_opendata` for pilot (`2024-01-01`..`2024-01-31`) and submission scope (`2024-01-01`..`2024-12-31`); verified `pre_extraction_source_count == post_extraction_source_count == csv_parsed_row_count` across all 4 files (`PASS`).
4. **Database & Bronze Schema Initialization:** Executed `sqlcmd -S localhost -E -C -b -i sql/00_init.sql` and `sqlcmd -S localhost -E -C -b -d homerescue_dw -i sql/01_bronze.sql` (`PASS`, exit code `0`).
5. **Bronze Data Loading & Row Reconciliation:** Executed `python -m src.ingest.load_csv --data-dir data/raw`; verified `55,734` total rows loaded across the 4 Bronze tables matching parsed CSV counts (`PASS`).
6. **Bronze Empirical Profiling & Safe Staging Rollback Test:** Executed `python -m src.quality.profile_bronze`; verified `0` null provenance rows and confirmed empty-staging load failure rolls back cleanly while preserving all `22,404` rows in `bronze.buildings` (`PASS`).

### Checks Not Run in M1–M2
- **Silver, Gold, and Semantic Quality Checks:** Scheduled for M3 and M4 immediately following this milestone.
