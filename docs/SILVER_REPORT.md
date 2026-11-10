# Silver Layer & Data Quality Reconciliation Report (`M3`) — HomeRescue AI

## 1. Executive Summary

The **HomeRescue AI** Silver layer (`sql/02_silver.sql`) transforms the four raw text Bronze tables (`55,734` rows) into strongly typed, standardized, and deduplicated relational tables in the `silver` schema (`silver.building`, `silver.complaint_problem`, `silver.violation`, `silver.omo_charge`) accompanied by three lineage and audit tables (`silver.reject_log`, `silver.duplicate_log`, `silver.batch_reconciliation`).

All transformations execute inside explicit `XACT_ABORT ON` transactions via `EXEC silver.load_all;` and enforce every mandatory NYC Housing domain rule.

---

## 2. Bronze-to-Silver Row Conservation & Cross-Source Building Match Summary

For every source table and execution batch, row accounting is **exhaustive and mutually exclusive**:
$$\text{Bronze Rows} = \text{Silver Accepted Rows} + \text{Silver Rejected Rows} + \text{Silver Duplicate Rows Removed}$$

Observed execution outputs from `silver.batch_reconciliation` (`data/exports/validation/m3_silver_profile_homerescue_dw.json`):

| Source Table (`bronze.*`) | Target Table (`silver.*`) | Natural Key | Bronze Rows | Accepted Rows | Rejected Rows | Duplicates Removed | Reconciliation Diff | Matched Building Rows (`%`) | Unmatched Building Rows (`%`) | Status |
|---|---|---|---:|---:|---:|---:|---:|---:|---:|---|
| `bronze.buildings` | `silver.building` | `building_id` (`INT`) | 22,404 | **22,329** | **75** | 0 | **0** | 22,329 (`100.0000%`) | 0 (`0.0000%`) | **PASS** |
| `bronze.complaints_problems` | `silver.complaint_problem` | `problem_id` (`BIGINT`) | 14,377 | **14,377** | **0** | 0 | **0** | 14,342 (`99.7566%`) | 35 (`0.2434%`) | **PASS** |
| `bronze.violations` | `silver.violation` | `violation_id` (`BIGINT`) | 18,463 | **18,463** | **0** | 0 | **0** | 18,446 (`99.9079%`) | 17 (`0.0921%`) | **PASS** |
| `bronze.omo_charges` | `silver.omo_charge` | `omo_id` (`BIGINT`) + unique `omo_number` (`VARCHAR`) | 490 | **490** | **0** | 0 | **0** | 484 (`98.7755%`) | 6 (`1.2245%`) | **PASS** |
| **Total** | — | — | **55,734** | **55,659** | **75** | **0** | **0** | **55,601 (`99.8958%`)** | **58 (`0.1042%`)** | **PASS** |

---

## 3. Field-Specific Acceptance, Rejection & Deduplication Rules

### 3.1 Missing vs. Failed Conversion vs. Implausible Value Distinction (Mandatory Rules 9 & 10)
Each Silver load procedure evaluates validation rules in a deterministic single-reason `CASE WHEN` priority hierarchy so that a rejected Bronze record produces **exactly one** row in `silver.reject_log` (preventing multi-rule failures from inflating rejected row counts):

1. **Missing Value (`missing_<field>`):** `NULLIF(TRIM(raw_col), '') IS NULL` on a required key, date, or parcel identifier.
2. **Conversion Failure (`conversion_failed_<field>`):** `NULLIF(TRIM(raw_col), '') IS NOT NULL` AND `TRY_CONVERT(target_type, ...)` returns `NULL`.
3. **Implausible / Out-of-Domain Value (`implausible_<field>` / `invalid_<field>`):**
   - Keys (`building_id`, `problem_id`, `complaint_id`, `violation_id`, `omo_id`) `<= 0`.
   - Dates (`received_date`, `inspection_date`, `omo_create_date`) `< '1900-01-01'` or `> CAST(SYSDATETIME() AS DATE)`.
   - Building tax parcel (`tax_block <= 0 OR tax_lot <= 0`) or placeholder street address (`street_name IN ('0', '00')`).
   - Negative building stories/unit counts (`legal_stories < 0`, `legal_class_a_units < 0`) or negative initial OMO award amount (`omo_award_amount < 0`).
   - Violation `class` outside `('A', 'B', 'C', 'I')`.

### 3.2 Observed Rejections in `silver.reject_log`
In the real Staten Island 2024 dataset, **75 rows** in `bronze.buildings` (`raw_row_num` between `16849` and `19984`, e.g., `building_id` `815249`, `815398`, `872121`, `906298`) were rejected into `silver.reject_log` with `reason = 'implausible_zero_tax_block_or_lot'` because their source tax parcel fields are `block = 0, lot = 0`. None of those 75 rejected building rows are referenced by any 2024 complaint, violation, or OMO charge record.

### 3.3 Deterministic Deduplication & Conflict Resolution (`silver.duplicate_log`)
- **`silver.building`:** Partitioned by `building_id`, ordered by `CASE WHEN recordstatus = 'ACTIVE' THEN 1 ELSE 2 END ASC, raw_row_num DESC, bronze_row_id DESC`.
- **`silver.complaint_problem`:** Partitioned by `problem_id`, ordered by `problem_status_date DESC, complaint_status_date DESC, raw_row_num DESC, bronze_row_id DESC`.
- **`silver.violation`:** Partitioned by `violation_id`, ordered by `currentstatusdate DESC, raw_row_num DESC, bronze_row_id DESC`.
- **`silver.omo_charge`:** Partitioned by `omo_id`, ordered by `omoawarddate DESC, omocreatedate DESC, raw_row_num DESC, bronze_row_id DESC`, plus secondary uniqueness verification on `omo_number`.
- **Observed Duplicates:** `0` duplicate natural keys exist in the live Staten Island 2024 Socrata extract. In addition, `silver.complaint_problem` preserves HPD's domain-level `problem_duplicate_flag` (`is_duplicate_problem_flag = 1` on `930` rows, `0` on `13,447` rows) so downstream metrics can report both total reported problems (`14,377`) and non-duplicate problems (`13,447`).

---

## 4. Domain Rules & Cohort Classifications in Silver

### 4.1 Complaint vs. Problem Grain Separation (`silver.complaint_problem` — Mandatory Rule 1)
- **Total Accepted Problem Rows (`COUNT(problem_id)`):** `14,377`
- **Distinct Parent Complaints (`COUNT(DISTINCT complaint_id)`):** `7,334`
- **Distinct Buildings with Complaints:** `1,755` (`1,754` registered in `silver.building` + `1` unregistered building `912070`).

### 4.2 Violation Class Semantics (`silver.violation` — Mandatory Rule 3)
`silver.violation` separates hazardous Housing Maintenance Code classes (`A`, `B`, `C`) from administrative/informational Class `I` orders (`is_hazardous_violation = 0`, `hazard_severity_rank = 0`):

| `violation_class` | `hazard_class_category` | `hazard_severity_rank` | `is_hazardous_violation` | Total Violations | Open Violations | Closed Violations | Rent-Impairing (`Y`) | Registered Building Rows | Unregistered Building Rows |
|---|---|---:|---|---:|---:|---:|---:|---:|---:|
| **`C`** | `Class C - Immediately Hazardous` | `3` | `1` (`True`) | **4,763** | 896 | 3,867 | 271 | 4,756 | 7 |
| **`B`** | `Class B - Hazardous` | `2` | `1` (`True`) | **8,300** | 2,709 | 5,591 | 442 | 8,292 | 8 |
| **`A`** | `Class A - Non-Hazardous` | `1` | `1` (`True`) | **2,969** | 847 | 2,122 | 8 | 2,967 | 2 |
| **`I`** | `Class I - Informational/Administrative Order` | `0` | `0` (`False`) | **2,431** | 1,258 | 1,173 | 0 | 2,431 | 0 |
| **Total** | — | — | — | **18,463** | **5,710** | **12,753** | **721** | **18,446** | **17** |

### 4.3 OMO Financial Rules & Eligible Repair Cohort (`silver.omo_charge` — Mandatory Rules 4, 5 & 11)
Instead of treating all `490` OMO records (`$3,081,609.44`) as residential emergency repairs or blindly rejecting zero-dollar records, `silver.omo_charge` retains all `490` valid orders and classifies each row by `financial_value_status`, `is_eligible_repair_cohort`, and `repair_cohort_category`:

| `is_eligible_repair_cohort` | `repair_cohort_category` | `financial_value_status` | Orders (`COUNT`) | Distinct Buildings | Total `omo_award_amount` | Average `omo_award_amount` | Min Award | Max Award |
|---|---|---|---:|---:|---:|---:|---:|---:|
| **`1` (`True`)** | **`Eligible Residential Building Repair Order`** | `positive_award` | **458** | **204** | **\$983,560.44** | **\$2,147.51** | \$1.00 | \$28,180.00 |
| `0` (`False`) | `Excluded - Un-Awarded Zero-Dollar Order` | `zero_dollar_un_awarded_or_cancelled` | 15 | 11 | \$0.00 | \$0.00 | \$0.00 | \$0.00 |
| `0` (`False`) | `Excluded - Structural Demolition or Vacant Land` | `positive_award` | 6 | 5 | \$1,529,697.00 | \$254,949.50 | \$180,955.00 | \$404,145.00 |
| `0` (`False`) | `Excluded - Cancelled or Duplicate Administrative Order` | `zero_dollar_un_awarded_or_cancelled` | 5 | 4 | \$0.00 | \$0.00 | \$0.00 | \$0.00 |
| `0` (`False`) | `Excluded - Commercial Demolition` | `positive_award` | 3 | 1 | \$568,102.00 | \$189,367.33 | \$10,085.00 | \$545,989.00 |
| `0` (`False`) | `Excluded - Structural Demolition or Vacant Land` | `zero_dollar_un_awarded_or_cancelled` | 2 | 2 | \$0.00 | \$0.00 | \$0.00 | \$0.00 |
| `0` (`False`) | `Excluded - Cancelled or Duplicate Administrative Order` | `positive_award` | 1 | 1 | \$250.00 | \$250.00 | \$250.00 | \$250.00 |
| **Total All OMOs** | — | — | **490** | **213** | **\$3,081,609.44** | **\$6,288.99** | **\$0.00** | **\$545,989.00** |

**Key Domain Insight:** Just `9` commercial and structural demolition orders account for **`$2,097,799.00` (`68.07%`)** of raw OMO award dollars in Staten Island in 2024. Separating the **`458` eligible residential building repair orders (`$983,560.44`)** prevents demolition projects from distorting residential maintenance priority rankings.

### 4.4 Cross-Source Unmatched Building Policy (Mandatory Rule 12)
Across the three event tables, **`58` event rows** reference **`4` distinct `building_id` values** that are absent from `silver.building`:
1. `building_id = 912070` (`460N BRIELLE AVENUE, ZIP 10314`): `35` complaint problems (`21` distinct complaints), `17` violations (`7` Class C, `8` Class B, `2` Class A), and `1` eligible GC OMO charge (`\$2,420.00`, `omo_id = 5497329`, `omo_number = 'EP12921'`).
2. `building_id = 1012831` (`281 JOHNSTON TERRACE, ZIP 10309`): `3` un-awarded `$0.00` OMO records (`ASBEST`, `DEMOL`, `GC`).
3. `building_id = 748099` (`6663 HYLAN BOULEVARD, ZIP 10309`): `1` un-awarded `$0.00` `Vacant Land` `DEMOL` OMO record.
4. `building_id = 888686` (`251 SOMMER AVENUE, ZIP 10314`): `1` un-awarded `$0.00` `ASBEST` OMO record.

All `58` rows are retained in Silver with `is_registered_building = 0` and mapped in Gold (`M4`) to the persistent unknown dimension member `building_key = -1` while keeping their natural `building_id` distinct in facts and `gold.mart_building_month`.

---

## 5. Executed Checks vs. Checks Not Run (M3 Verification Matrix)

### Executed Checks
1. **Silver DDL & Stored Procedure Creation:** Executed `sqlcmd -S localhost -E -C -b -d homerescue_dw -i sql/02_silver.sql` (`PASS`, exit code `0`).
2. **Silver Pipeline Execution (`EXEC silver.load_all`):** Executed against `homerescue_dw`; verified `SUCCESS` entries in `audit.load_log` and `reconciliation_diff = 0` across all 4 sources in `silver.batch_reconciliation` (`PASS`).
3. **Silver Empirical Profile Export:** Executed `python -m src.quality.profile_silver` (`data/exports/validation/m3_silver_profile_homerescue_dw.json`) (`PASS`).

### Checks Scheduled Next (M4)
- Full SQL quality check suite (`src/quality/checks.sql` via `python -m src.quality.run_checks`) and isolated synthetic fixture tests (`pytest`) will be executed in M4 once Gold and Semantic objects are created.
