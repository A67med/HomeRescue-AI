-- =============================================================================
-- sql/02_silver.sql
-- HomeRescue AI Data Warehouse — Silver Layer (Cleaned, Typed, Deduplicated)
--
-- Mandatory Domain & Quality Rules Enforced:
-- 1. Complaint vs. Problem Grain (Rule 1): silver.complaint_problem is keyed by
--    problem_id (BIGINT) while preserving parent complaint_id (BIGINT) separately.
-- 2. Building ID Normalization (Rule 2): buildingid / building_id normalized to
--    building_id (INT) across all four Silver tables.
-- 3. Violation Class Semantics (Rule 3): Classes A, B, C are hazard tiers
--    (severity rank 1, 2, 3) and Class I is an informational/administrative order
--    (is_hazardous_violation = 0, hazard_severity_rank = 0; never ranked above C).
-- 4. OMO Eligible Repair Cohort (Rule 4): Explicitly classifies OMO records by
--    work_type_general, lifecycle, is_commercial_demolition, omo_status_reason,
--    and omo_award_amount into is_eligible_repair_cohort (0/1) and
--    repair_cohort_category instead of labeling all OMOs as emergency repairs.
-- 5. Text Preservation for Codes: omo_number and zip_code/post_code are stored
--    as VARCHAR text so leading zeros and alphanumeric prefixes are never stripped.
-- 6. Missing vs. Conversion Failure vs. Implausible Value Separation (Rules 9 & 10):
--    Distinguishes NULL/blank strings from TRY_CONVERT syntax failures and
--    out-of-range dates (< 1900-01-01 or > current date) or negative awards.
-- 7. Exhaustive & Mutually Exclusive Row Conservation (Rule 9):
--    For every source table:
--      Bronze Rows = Silver Accepted Rows + Silver Rejected Rows + Duplicate Rows Removed
--    One rejected Bronze row produces at most one row in silver.reject_log.
-- 8. Unmatched Building Retention & Measurement (Rule 12):
--    Valid event rows referencing a building_id absent from silver.building are
--    retained in Silver with is_registered_building = 0 and quantified in
--    silver.batch_reconciliation.
-- =============================================================================

IF DB_NAME() IN (N'master', N'tempdb', N'model', N'msdb')
    USE [homerescue_dw];
GO

-- =============================================================================
-- 0. SHARED SILVER AUDIT & LINEAGE TABLES
-- =============================================================================
IF OBJECT_ID(N'silver.reject_log', N'U') IS NULL
BEGIN
    CREATE TABLE silver.reject_log (
        reject_id      BIGINT IDENTITY(1,1) NOT NULL PRIMARY KEY,
        source_table   VARCHAR(100)         NOT NULL,
        bronze_row_id  BIGINT               NOT NULL,
        raw_row_num    BIGINT               NOT NULL,
        business_key   NVARCHAR(255)        NULL,
        reason         VARCHAR(150)         NOT NULL,
        raw_summary    NVARCHAR(1000)       NULL,
        batch_id       UNIQUEIDENTIFIER     NOT NULL,
        DW_create_date DATETIME2            NOT NULL DEFAULT SYSDATETIME()
    );
END;
GO

IF OBJECT_ID(N'silver.duplicate_log', N'U') IS NULL
BEGIN
    CREATE TABLE silver.duplicate_log (
        duplicate_id          BIGINT IDENTITY(1,1) NOT NULL PRIMARY KEY,
        source_table          VARCHAR(100)         NOT NULL,
        business_key          NVARCHAR(255)        NOT NULL,
        kept_bronze_row_id    BIGINT               NOT NULL,
        removed_bronze_row_id BIGINT               NOT NULL,
        removed_raw_row_num   BIGINT               NOT NULL,
        resolution_rule       VARCHAR(250)         NOT NULL,
        batch_id              UNIQUEIDENTIFIER     NOT NULL,
        DW_create_date        DATETIME2            NOT NULL DEFAULT SYSDATETIME()
    );
END;
GO

IF OBJECT_ID(N'silver.batch_reconciliation', N'U') IS NULL
BEGIN
    CREATE TABLE silver.batch_reconciliation (
        recon_id                BIGINT IDENTITY(1,1) NOT NULL PRIMARY KEY,
        source_table            VARCHAR(100)         NOT NULL,
        silver_table            VARCHAR(100)         NOT NULL,
        batch_id                UNIQUEIDENTIFIER     NOT NULL,
        bronze_rows             BIGINT               NOT NULL,
        accepted_rows           BIGINT               NOT NULL,
        rejected_rows           BIGINT               NOT NULL,
        duplicate_rows_removed  BIGINT               NOT NULL,
        reconciliation_diff     BIGINT               NOT NULL,
        matched_building_rows   BIGINT               NOT NULL,
        unmatched_building_rows BIGINT               NOT NULL,
        DW_create_date          DATETIME2            NOT NULL DEFAULT SYSDATETIME()
    );
END;
GO

-- =============================================================================
-- 1. SILVER.BUILDING (Natural Key: building_id)
-- =============================================================================
DROP TABLE IF EXISTS silver.building;
CREATE TABLE silver.building (
    building_id           INT              NOT NULL PRIMARY KEY,
    boro_id               INT              NOT NULL,
    borough_name          VARCHAR(50)      NOT NULL,
    house_number          VARCHAR(100)     NULL,
    low_house_number      VARCHAR(100)     NULL,
    high_house_number     VARCHAR(100)     NULL,
    street_name           VARCHAR(250)     NOT NULL,
    zip_code              VARCHAR(20)      NULL,
    tax_block             INT              NOT NULL,
    tax_lot               INT              NOT NULL,
    bin                   VARCHAR(50)      NULL,
    community_board       INT              NULL,
    census_tract          VARCHAR(50)      NULL,
    management_program    VARCHAR(100)     NULL,
    dob_building_class_id INT              NULL,
    dob_building_class    VARCHAR(150)     NULL,
    legal_stories         INT              NULL,
    legal_class_a_units   INT              NULL,
    legal_class_b_units   INT              NULL,
    registration_id       INT              NULL,
    lifecycle             VARCHAR(100)     NULL,
    record_status_id      INT              NULL,
    record_status         VARCHAR(100)     NULL,
    is_active_building    BIT              NOT NULL,
    bronze_row_id         BIGINT           NOT NULL,
    raw_row_num           BIGINT           NOT NULL,
    source_batch_id       UNIQUEIDENTIFIER NOT NULL,
    DW_create_date        DATETIME2        NOT NULL DEFAULT SYSDATETIME()
);
GO

CREATE OR ALTER PROCEDURE silver.load_building
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @batch      UNIQUEIDENTIFIER = NEWID(),
            @start      DATETIME2        = SYSDATETIME(),
            @bronze_cnt BIGINT           = 0,
            @accept_cnt BIGINT           = 0,
            @reject_cnt BIGINT           = 0,
            @dup_cnt    BIGINT           = 0;

    BEGIN TRY
        SELECT @bronze_cnt = COUNT_BIG(*) FROM bronze.buildings;

        -- Stage & classify natural key before transaction
        SELECT
            b.*,
            NULLIF(TRIM(b.buildingid), '') AS clean_buildingid_str,
            TRY_CONVERT(INT, NULLIF(TRIM(b.buildingid), '')) AS parsed_building_id,
            CASE
                WHEN NULLIF(TRIM(b.buildingid), '') IS NULL THEN 'missing_building_id'
                WHEN TRY_CONVERT(INT, NULLIF(TRIM(b.buildingid), '')) IS NULL THEN 'conversion_failed_building_id'
                WHEN TRY_CONVERT(INT, NULLIF(TRIM(b.buildingid), '')) <= 0 THEN 'implausible_nonpositive_building_id'
                ELSE NULL
            END AS key_reject_reason
        INTO #bldg_stage
        FROM bronze.buildings b
        OPTION (MAXDOP 1);

        SELECT
            s.*,
            ROW_NUMBER() OVER (
                PARTITION BY s.parsed_building_id
                ORDER BY
                    CASE WHEN UPPER(ISNULL(TRIM(s.recordstatus), '')) = 'ACTIVE' THEN 1 ELSE 2 END ASC,
                    s.raw_row_num DESC,
                    s.bronze_row_id DESC
            ) AS rn,
            FIRST_VALUE(s.bronze_row_id) OVER (
                PARTITION BY s.parsed_building_id
                ORDER BY
                    CASE WHEN UPPER(ISNULL(TRIM(s.recordstatus), '')) = 'ACTIVE' THEN 1 ELSE 2 END ASC,
                    s.raw_row_num DESC,
                    s.bronze_row_id DESC
            ) AS kept_bronze_row_id
        INTO #bldg_dedup
        FROM #bldg_stage s
        WHERE s.key_reject_reason IS NULL
        OPTION (MAXDOP 1);

        SELECT
            d.bronze_row_id,
            d.raw_row_num,
            d.batch_id AS source_batch_id,
            d.parsed_building_id AS building_id,
            TRY_CONVERT(INT, NULLIF(TRIM(d.boroid), '')) AS boro_id,
            UPPER(ISNULL(NULLIF(TRIM(d.boro), ''), 'STATEN ISLAND')) AS borough_name,
            NULLIF(TRIM(d.housenumber), '') AS house_number,
            NULLIF(TRIM(d.lowhousenumber), '') AS low_house_number,
            NULLIF(TRIM(d.highhousenumber), '') AS high_house_number,
            NULLIF(TRIM(d.streetname), '') AS street_name,
            NULLIF(TRIM(d.zip), '') AS zip_code,
            TRY_CONVERT(INT, NULLIF(TRIM(d.block), '')) AS tax_block,
            TRY_CONVERT(INT, NULLIF(TRIM(d.lot), '')) AS tax_lot,
            NULLIF(TRIM(d.bin), '') AS bin,
            TRY_CONVERT(INT, NULLIF(TRIM(d.communityboard), '')) AS community_board,
            NULLIF(TRIM(d.censustract), '') AS census_tract,
            NULLIF(TRIM(d.managementprogram), '') AS management_program,
            TRY_CONVERT(INT, NULLIF(TRIM(d.dobbuildingclassid), '')) AS dob_building_class_id,
            NULLIF(TRIM(d.dobbuildingclass), '') AS dob_building_class,
            TRY_CONVERT(INT, NULLIF(TRIM(d.legalstories), '')) AS legal_stories,
            TRY_CONVERT(INT, NULLIF(TRIM(d.legalclassa), '')) AS legal_class_a_units,
            TRY_CONVERT(INT, NULLIF(TRIM(d.legalclassb), '')) AS legal_class_b_units,
            TRY_CONVERT(INT, NULLIF(TRIM(d.registrationid), '')) AS registration_id,
            NULLIF(TRIM(d.lifecycle), '') AS lifecycle,
            TRY_CONVERT(INT, NULLIF(TRIM(d.recordstatusid), '')) AS record_status_id,
            NULLIF(TRIM(d.recordstatus), '') AS record_status,
            CASE
                WHEN UPPER(ISNULL(TRIM(d.recordstatus), '')) = 'ACTIVE'
                 AND UPPER(ISNULL(TRIM(d.lifecycle), '')) = 'BUILDING'
                THEN CAST(1 AS BIT)
                ELSE CAST(0 AS BIT)
            END AS is_active_building,
            CASE
                WHEN NULLIF(TRIM(d.boroid), '') IS NULL THEN 'missing_boro_id'
                WHEN TRY_CONVERT(INT, NULLIF(TRIM(d.boroid), '')) IS NULL THEN 'conversion_failed_boro_id'
                WHEN TRY_CONVERT(INT, NULLIF(TRIM(d.boroid), '')) NOT BETWEEN 1 AND 5 THEN 'implausible_boro_id_range'
                WHEN NULLIF(TRIM(d.block), '') IS NULL OR NULLIF(TRIM(d.lot), '') IS NULL THEN 'missing_tax_block_or_lot'
                WHEN TRY_CONVERT(INT, NULLIF(TRIM(d.block), '')) IS NULL OR TRY_CONVERT(INT, NULLIF(TRIM(d.lot), '')) IS NULL THEN 'conversion_failed_tax_block_or_lot'
                WHEN TRY_CONVERT(INT, NULLIF(TRIM(d.block), '')) <= 0 OR TRY_CONVERT(INT, NULLIF(TRIM(d.lot), '')) <= 0 THEN 'implausible_zero_tax_block_or_lot'
                WHEN NULLIF(TRIM(d.streetname), '') IS NULL OR TRIM(d.streetname) IN ('0', '00') THEN 'invalid_or_missing_street_name'
                WHEN NULLIF(TRIM(d.legalclassa), '') IS NOT NULL AND TRY_CONVERT(INT, NULLIF(TRIM(d.legalclassa), '')) IS NULL THEN 'conversion_failed_legalclassa'
                WHEN TRY_CONVERT(INT, NULLIF(TRIM(d.legalclassa), '')) < 0 THEN 'implausible_negative_legalclassa'
                WHEN NULLIF(TRIM(d.legalstories), '') IS NOT NULL AND TRY_CONVERT(INT, NULLIF(TRIM(d.legalstories), '')) IS NULL THEN 'conversion_failed_legalstories'
                WHEN TRY_CONVERT(INT, NULLIF(TRIM(d.legalstories), '')) < 0 THEN 'implausible_negative_legalstories'
                ELSE NULL
            END AS attr_reject_reason
        INTO #bldg_typed
        FROM #bldg_dedup d
        WHERE d.rn = 1
        OPTION (MAXDOP 1);

        BEGIN TRAN;

        DELETE FROM silver.reject_log WHERE source_table = 'bronze.buildings';
        DELETE FROM silver.duplicate_log WHERE source_table = 'bronze.buildings';
        DELETE FROM silver.batch_reconciliation WHERE source_table = 'bronze.buildings';
        TRUNCATE TABLE silver.building;

        INSERT INTO silver.reject_log (source_table, bronze_row_id, raw_row_num, business_key, reason, raw_summary, batch_id)
        SELECT
            'bronze.buildings',
            bronze_row_id,
            raw_row_num,
            clean_buildingid_str,
            key_reject_reason,
            CONCAT(N'buildingid=', ISNULL(buildingid, N'NULL'), N', street=', ISNULL(streetname, N'NULL')),
            @batch
        FROM #bldg_stage
        WHERE key_reject_reason IS NOT NULL
        OPTION (MAXDOP 1);

        INSERT INTO silver.duplicate_log (
            source_table, business_key, kept_bronze_row_id, removed_bronze_row_id,
            removed_raw_row_num, resolution_rule, batch_id
        )
        SELECT
            'bronze.buildings',
            CAST(parsed_building_id AS NVARCHAR(255)),
            kept_bronze_row_id,
            bronze_row_id,
            raw_row_num,
            'Keep Active recordstatus first, then latest raw_row_num / bronze_row_id',
            @batch
        FROM #bldg_dedup
        WHERE rn > 1
        OPTION (MAXDOP 1);

        INSERT INTO silver.reject_log (source_table, bronze_row_id, raw_row_num, business_key, reason, raw_summary, batch_id)
        SELECT
            'bronze.buildings',
            bronze_row_id,
            raw_row_num,
            CAST(building_id AS NVARCHAR(255)),
            attr_reject_reason,
            CONCAT(N'block=', ISNULL(CAST(tax_block AS NVARCHAR(50)), N'NULL'),
                   N', lot=', ISNULL(CAST(tax_lot AS NVARCHAR(50)), N'NULL'),
                   N', street=', ISNULL(street_name, N'NULL'),
                   N', lifecycle=', ISNULL(lifecycle, N'NULL')),
            @batch
        FROM #bldg_typed
        WHERE attr_reject_reason IS NOT NULL
        OPTION (MAXDOP 1);

        INSERT INTO silver.building (
            building_id, boro_id, borough_name, house_number, low_house_number,
            high_house_number, street_name, zip_code, tax_block, tax_lot, bin,
            community_board, census_tract, management_program,
            dob_building_class_id, dob_building_class, legal_stories,
            legal_class_a_units, legal_class_b_units, registration_id,
            lifecycle, record_status_id, record_status, is_active_building,
            bronze_row_id, raw_row_num, source_batch_id
        )
        SELECT
            building_id, boro_id, borough_name, house_number, low_house_number,
            high_house_number, street_name, zip_code, tax_block, tax_lot, bin,
            community_board, census_tract, management_program,
            dob_building_class_id, dob_building_class, legal_stories,
            legal_class_a_units, legal_class_b_units, registration_id,
            lifecycle, record_status_id, record_status, is_active_building,
            bronze_row_id, raw_row_num, source_batch_id
        FROM #bldg_typed
        WHERE attr_reject_reason IS NULL
        OPTION (MAXDOP 1);

        SELECT @accept_cnt = COUNT_BIG(*) FROM silver.building;
        SELECT @reject_cnt = COUNT_BIG(*) FROM silver.reject_log WHERE source_table = 'bronze.buildings';
        SELECT @dup_cnt    = COUNT_BIG(*) FROM silver.duplicate_log WHERE source_table = 'bronze.buildings';

        INSERT INTO silver.batch_reconciliation (
            source_table, silver_table, batch_id, bronze_rows, accepted_rows,
            rejected_rows, duplicate_rows_removed, reconciliation_diff,
            matched_building_rows, unmatched_building_rows
        )
        VALUES (
            'bronze.buildings', 'silver.building', @batch, @bronze_cnt, @accept_cnt,
            @reject_cnt, @dup_cnt, @bronze_cnt - (@accept_cnt + @reject_cnt + @dup_cnt),
            @accept_cnt, 0
        );

        COMMIT TRAN;

        INSERT INTO audit.load_log (batch_id, source_name, target_table, start_time, end_time, rows_loaded, status, message)
        VALUES (@batch, 'bronze.buildings', 'silver.building', @start, SYSDATETIME(), @accept_cnt, 'SUCCESS',
                CONCAT('Silver building load complete: accepted=', @accept_cnt, ', rejected=', @reject_cnt, ', duplicates=', @dup_cnt));
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRAN;
        INSERT INTO audit.load_log (batch_id, source_name, target_table, start_time, end_time, rows_loaded, status, message)
        VALUES (@batch, 'bronze.buildings', 'silver.building', @start, SYSDATETIME(), NULL, 'FAILED', ERROR_MESSAGE());
        THROW;
    END CATCH
END;
GO

-- =============================================================================
-- 2. SILVER.COMPLAINT_PROBLEM (Natural Key: problem_id; Parent: complaint_id)
-- =============================================================================
IF OBJECT_ID(N'silver.complaint_problem', N'U') IS NULL
BEGIN
    CREATE TABLE silver.complaint_problem (
        problem_id                BIGINT           NOT NULL PRIMARY KEY,
        complaint_id              BIGINT           NOT NULL,
        building_id               INT              NOT NULL,
        borough_name              VARCHAR(50)      NOT NULL,
        house_number              VARCHAR(100)     NULL,
        street_name               VARCHAR(250)     NULL,
        post_code                 VARCHAR(20)      NULL,
        tax_block                 INT              NULL,
        tax_lot                   INT              NULL,
        apartment                 VARCHAR(50)      NULL,
        community_board           INT              NULL,
        unit_type                 VARCHAR(100)     NULL,
        space_type                VARCHAR(100)     NULL,
        urgency_type              VARCHAR(100)     NULL,
        major_category            VARCHAR(200)     NULL,
        minor_category            VARCHAR(200)     NULL,
        problem_code              VARCHAR(200)     NULL,
        received_date             DATE             NOT NULL,
        complaint_status          VARCHAR(50)      NULL,
        complaint_status_date     DATE             NULL,
        problem_status            VARCHAR(50)      NULL,
        problem_status_date       DATE             NULL,
        status_description        NVARCHAR(MAX)    NULL,
        problem_duplicate_flag    CHAR(1)          NULL,
        is_duplicate_problem_flag BIT              NOT NULL,
        complaint_anonymous_flag  CHAR(1)          NULL,
        sr_unique_key             VARCHAR(50)      NULL,
        latitude                  DECIMAL(10,6)    NULL,
        longitude                 DECIMAL(10,6)    NULL,
        bin                       VARCHAR(20)      NULL,
        bbl                       VARCHAR(20)      NULL,
        nta                       VARCHAR(200)     NULL,
        is_registered_building    BIT              NOT NULL,
        bronze_row_id             BIGINT           NOT NULL,
        raw_row_num               BIGINT           NOT NULL,
        source_batch_id           UNIQUEIDENTIFIER NOT NULL,
        DW_create_date            DATETIME2        NOT NULL DEFAULT SYSDATETIME()
    );
END;
GO

CREATE OR ALTER PROCEDURE silver.load_complaint_problem
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @batch         UNIQUEIDENTIFIER = NEWID(),
            @start         DATETIME2        = SYSDATETIME(),
            @bronze_cnt    BIGINT           = 0,
            @accept_cnt    BIGINT           = 0,
            @reject_cnt    BIGINT           = 0,
            @dup_cnt       BIGINT           = 0,
            @matched_cnt   BIGINT           = 0,
            @unmatched_cnt BIGINT           = 0;

    BEGIN TRY
        SELECT @bronze_cnt = COUNT_BIG(*) FROM bronze.complaints_problems;

        SELECT
            c.*,
            NULLIF(TRIM(c.problem_id), '') AS clean_problem_id_str,
            TRY_CONVERT(BIGINT, NULLIF(TRIM(c.problem_id), '')) AS parsed_problem_id,
            CASE
                WHEN NULLIF(TRIM(c.problem_id), '') IS NULL THEN 'missing_problem_id'
                WHEN TRY_CONVERT(BIGINT, NULLIF(TRIM(c.problem_id), '')) IS NULL THEN 'conversion_failed_problem_id'
                WHEN TRY_CONVERT(BIGINT, NULLIF(TRIM(c.problem_id), '')) <= 0 THEN 'implausible_nonpositive_problem_id'
                ELSE NULL
            END AS key_reject_reason
        INTO #comp_stage
        FROM bronze.complaints_problems c
        OPTION (MAXDOP 1);

        SELECT
            s.*,
            ROW_NUMBER() OVER (
                PARTITION BY s.parsed_problem_id
                ORDER BY
                    TRY_CONVERT(DATETIME2, REPLACE(NULLIF(TRIM(s.problem_status_date), ''), '/', '-')) DESC,
                    TRY_CONVERT(DATETIME2, REPLACE(NULLIF(TRIM(s.complaint_status_date), ''), '/', '-')) DESC,
                    s.raw_row_num DESC,
                    s.bronze_row_id DESC
            ) AS rn,
            FIRST_VALUE(s.bronze_row_id) OVER (
                PARTITION BY s.parsed_problem_id
                ORDER BY
                    TRY_CONVERT(DATETIME2, REPLACE(NULLIF(TRIM(s.problem_status_date), ''), '/', '-')) DESC,
                    TRY_CONVERT(DATETIME2, REPLACE(NULLIF(TRIM(s.complaint_status_date), ''), '/', '-')) DESC,
                    s.raw_row_num DESC,
                    s.bronze_row_id DESC
            ) AS kept_bronze_row_id
        INTO #comp_dedup
        FROM #comp_stage s
        WHERE s.key_reject_reason IS NULL
        OPTION (MAXDOP 1);

        SELECT
            d.bronze_row_id,
            d.raw_row_num,
            d.batch_id AS source_batch_id,
            d.parsed_problem_id AS problem_id,
            TRY_CONVERT(BIGINT, NULLIF(TRIM(d.complaint_id), '')) AS complaint_id,
            TRY_CONVERT(INT, NULLIF(TRIM(d.building_id), '')) AS building_id,
            UPPER(ISNULL(NULLIF(TRIM(d.borough), ''), 'STATEN ISLAND')) AS borough_name,
            NULLIF(TRIM(d.house_number), '') AS house_number,
            NULLIF(TRIM(d.street_name), '') AS street_name,
            NULLIF(TRIM(d.post_code), '') AS post_code,
            TRY_CONVERT(INT, NULLIF(TRIM(d.block), '')) AS tax_block,
            TRY_CONVERT(INT, NULLIF(TRIM(d.lot), '')) AS tax_lot,
            NULLIF(TRIM(d.apartment), '') AS apartment,
            TRY_CONVERT(INT, NULLIF(TRIM(d.community_board), '')) AS community_board,
            UPPER(NULLIF(TRIM(d.unit_type), '')) AS unit_type,
            UPPER(NULLIF(TRIM(d.space_type), '')) AS space_type,
            UPPER(NULLIF(TRIM(d.type), '')) AS urgency_type,
            UPPER(NULLIF(TRIM(d.major_category), '')) AS major_category,
            UPPER(NULLIF(TRIM(d.minor_category), '')) AS minor_category,
            UPPER(NULLIF(TRIM(d.problem_code), '')) AS problem_code,
            CAST(TRY_CONVERT(DATETIME2, REPLACE(NULLIF(TRIM(d.received_date), ''), '/', '-')) AS DATE) AS received_date,
            UPPER(NULLIF(TRIM(d.complaint_status), '')) AS complaint_status,
            CAST(TRY_CONVERT(DATETIME2, REPLACE(NULLIF(TRIM(d.complaint_status_date), ''), '/', '-')) AS DATE) AS complaint_status_date,
            UPPER(NULLIF(TRIM(d.problem_status), '')) AS problem_status,
            CAST(TRY_CONVERT(DATETIME2, REPLACE(NULLIF(TRIM(d.problem_status_date), ''), '/', '-')) AS DATE) AS problem_status_date,
            NULLIF(TRIM(d.status_description), '') AS status_description,
            LEFT(UPPER(NULLIF(TRIM(d.problem_duplicate_flag), '')), 1) AS problem_duplicate_flag,
            CASE WHEN UPPER(NULLIF(TRIM(d.problem_duplicate_flag), '')) = 'Y' THEN CAST(1 AS BIT) ELSE CAST(0 AS BIT) END AS is_duplicate_problem_flag,
            LEFT(UPPER(NULLIF(TRIM(d.complaint_anonymous_flag), '')), 1) AS complaint_anonymous_flag,
            NULLIF(TRIM(d.unique_key), '') AS sr_unique_key,
            TRY_CONVERT(DECIMAL(10,6), NULLIF(TRIM(d.latitude), '')) AS latitude,
            TRY_CONVERT(DECIMAL(10,6), NULLIF(TRIM(d.longitude), '')) AS longitude,
            NULLIF(TRIM(d.bin), '') AS bin,
            NULLIF(TRIM(d.bbl), '') AS bbl,
            NULLIF(TRIM(d.nta), '') AS nta,
            CASE
                WHEN NULLIF(TRIM(d.complaint_id), '') IS NULL THEN 'missing_complaint_id'
                WHEN TRY_CONVERT(BIGINT, NULLIF(TRIM(d.complaint_id), '')) IS NULL THEN 'conversion_failed_complaint_id'
                WHEN TRY_CONVERT(BIGINT, NULLIF(TRIM(d.complaint_id), '')) <= 0 THEN 'implausible_nonpositive_complaint_id'
                WHEN NULLIF(TRIM(d.building_id), '') IS NULL THEN 'missing_building_id'
                WHEN TRY_CONVERT(INT, NULLIF(TRIM(d.building_id), '')) IS NULL THEN 'conversion_failed_building_id'
                WHEN TRY_CONVERT(INT, NULLIF(TRIM(d.building_id), '')) <= 0 THEN 'implausible_nonpositive_building_id'
                WHEN NULLIF(TRIM(d.received_date), '') IS NULL THEN 'missing_received_date'
                WHEN TRY_CONVERT(DATETIME2, REPLACE(NULLIF(TRIM(d.received_date), ''), '/', '-')) IS NULL THEN 'conversion_failed_received_date'
                WHEN CAST(TRY_CONVERT(DATETIME2, REPLACE(NULLIF(TRIM(d.received_date), ''), '/', '-')) AS DATE) < '1900-01-01'
                  OR CAST(TRY_CONVERT(DATETIME2, REPLACE(NULLIF(TRIM(d.received_date), ''), '/', '-')) AS DATE) > CAST(SYSDATETIME() AS DATE)
                  THEN 'implausible_out_of_range_received_date'
                WHEN NULLIF(TRIM(d.complaint_status_date), '') IS NOT NULL
                 AND TRY_CONVERT(DATETIME2, REPLACE(NULLIF(TRIM(d.complaint_status_date), ''), '/', '-')) IS NULL
                  THEN 'conversion_failed_complaint_status_date'
                WHEN NULLIF(TRIM(d.problem_status_date), '') IS NOT NULL
                 AND TRY_CONVERT(DATETIME2, REPLACE(NULLIF(TRIM(d.problem_status_date), ''), '/', '-')) IS NULL
                  THEN 'conversion_failed_problem_status_date'
                ELSE NULL
            END AS attr_reject_reason
        INTO #comp_typed
        FROM #comp_dedup d
        WHERE d.rn = 1
        OPTION (MAXDOP 1);

        BEGIN TRAN;

        DELETE FROM silver.reject_log WHERE source_table = 'bronze.complaints_problems';
        DELETE FROM silver.duplicate_log WHERE source_table = 'bronze.complaints_problems';
        DELETE FROM silver.batch_reconciliation WHERE source_table = 'bronze.complaints_problems';
        TRUNCATE TABLE silver.complaint_problem;

        INSERT INTO silver.reject_log (source_table, bronze_row_id, raw_row_num, business_key, reason, raw_summary, batch_id)
        SELECT
            'bronze.complaints_problems',
            bronze_row_id,
            raw_row_num,
            clean_problem_id_str,
            key_reject_reason,
            CONCAT(N'problem_id=', ISNULL(problem_id, N'NULL'), N', complaint_id=', ISNULL(complaint_id, N'NULL')),
            @batch
        FROM #comp_stage
        WHERE key_reject_reason IS NOT NULL
        OPTION (MAXDOP 1);

        INSERT INTO silver.duplicate_log (
            source_table, business_key, kept_bronze_row_id, removed_bronze_row_id,
            removed_raw_row_num, resolution_rule, batch_id
        )
        SELECT
            'bronze.complaints_problems',
            CAST(parsed_problem_id AS NVARCHAR(255)),
            kept_bronze_row_id,
            bronze_row_id,
            raw_row_num,
            'Keep latest problem_status_date / complaint_status_date, then latest raw_row_num',
            @batch
        FROM #comp_dedup
        WHERE rn > 1
        OPTION (MAXDOP 1);

        INSERT INTO silver.reject_log (source_table, bronze_row_id, raw_row_num, business_key, reason, raw_summary, batch_id)
        SELECT
            'bronze.complaints_problems',
            bronze_row_id,
            raw_row_num,
            CAST(problem_id AS NVARCHAR(255)),
            attr_reject_reason,
            CONCAT(N'complaint_id=', ISNULL(CAST(complaint_id AS NVARCHAR(50)), N'NULL'),
                   N', building_id=', ISNULL(CAST(building_id AS NVARCHAR(50)), N'NULL'),
                   N', received_date=', ISNULL(CAST(received_date AS NVARCHAR(50)), N'NULL')),
            @batch
        FROM #comp_typed
        WHERE attr_reject_reason IS NOT NULL
        OPTION (MAXDOP 1);

        INSERT INTO silver.complaint_problem (
            problem_id, complaint_id, building_id, borough_name, house_number,
            street_name, post_code, tax_block, tax_lot, apartment, community_board,
            unit_type, space_type, urgency_type, major_category, minor_category,
            problem_code, received_date, complaint_status, complaint_status_date,
            problem_status, problem_status_date, status_description,
            problem_duplicate_flag, is_duplicate_problem_flag,
            complaint_anonymous_flag, sr_unique_key, latitude, longitude,
            bin, bbl, nta, is_registered_building,
            bronze_row_id, raw_row_num, source_batch_id
        )
        SELECT
            t.problem_id, t.complaint_id, t.building_id, t.borough_name, t.house_number,
            t.street_name, t.post_code, t.tax_block, t.tax_lot, t.apartment, t.community_board,
            t.unit_type, t.space_type, t.urgency_type, t.major_category, t.minor_category,
            t.problem_code, t.received_date, t.complaint_status, t.complaint_status_date,
            t.problem_status, t.problem_status_date, t.status_description,
            t.problem_duplicate_flag, t.is_duplicate_problem_flag,
            t.complaint_anonymous_flag, t.sr_unique_key, t.latitude, t.longitude,
            t.bin, t.bbl, t.nta,
            CASE WHEN b.building_id IS NOT NULL THEN CAST(1 AS BIT) ELSE CAST(0 AS BIT) END AS is_registered_building,
            t.bronze_row_id, t.raw_row_num, t.source_batch_id
        FROM #comp_typed t
        LEFT JOIN silver.building b ON t.building_id = b.building_id
        WHERE t.attr_reject_reason IS NULL
        OPTION (MAXDOP 1);

        SELECT @accept_cnt    = COUNT_BIG(*) FROM silver.complaint_problem;
        SELECT @reject_cnt    = COUNT_BIG(*) FROM silver.reject_log WHERE source_table = 'bronze.complaints_problems';
        SELECT @dup_cnt       = COUNT_BIG(*) FROM silver.duplicate_log WHERE source_table = 'bronze.complaints_problems';
        SELECT @matched_cnt   = ISNULL(SUM(CASE WHEN is_registered_building = 1 THEN 1 ELSE 0 END), 0),
               @unmatched_cnt = ISNULL(SUM(CASE WHEN is_registered_building = 0 THEN 1 ELSE 0 END), 0)
        FROM silver.complaint_problem;

        INSERT INTO silver.batch_reconciliation (
            source_table, silver_table, batch_id, bronze_rows, accepted_rows,
            rejected_rows, duplicate_rows_removed, reconciliation_diff,
            matched_building_rows, unmatched_building_rows
        )
        VALUES (
            'bronze.complaints_problems', 'silver.complaint_problem', @batch, @bronze_cnt, @accept_cnt,
            @reject_cnt, @dup_cnt, @bronze_cnt - (@accept_cnt + @reject_cnt + @dup_cnt),
            @matched_cnt, @unmatched_cnt
        );

        COMMIT TRAN;

        INSERT INTO audit.load_log (batch_id, source_name, target_table, start_time, end_time, rows_loaded, status, message)
        VALUES (@batch, 'bronze.complaints_problems', 'silver.complaint_problem', @start, SYSDATETIME(), @accept_cnt, 'SUCCESS',
                CONCAT('Silver complaint_problem load complete: accepted=', @accept_cnt, ', rejected=', @reject_cnt, ', duplicates=', @dup_cnt));
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRAN;
        INSERT INTO audit.load_log (batch_id, source_name, target_table, start_time, end_time, rows_loaded, status, message)
        VALUES (@batch, 'bronze.complaints_problems', 'silver.complaint_problem', @start, SYSDATETIME(), NULL, 'FAILED', ERROR_MESSAGE());
        THROW;
    END CATCH
END;
GO

-- =============================================================================
-- 3. SILVER.VIOLATION (Natural Key: violation_id)
-- =============================================================================
IF OBJECT_ID(N'silver.violation', N'U') IS NULL
BEGIN
    CREATE TABLE silver.violation (
        violation_id              BIGINT           NOT NULL PRIMARY KEY,
        building_id               INT              NOT NULL,
        registration_id           INT              NULL,
        boro_id                   INT              NULL,
        borough_name              VARCHAR(50)      NOT NULL,
        house_number              VARCHAR(100)     NULL,
        street_name               VARCHAR(250)     NULL,
        zip_code                  VARCHAR(20)      NULL,
        apartment                 VARCHAR(50)      NULL,
        story                     VARCHAR(50)      NULL,
        tax_block                 INT              NULL,
        tax_lot                   INT              NULL,
        violation_class           CHAR(1)          NOT NULL,
        is_hazardous_violation    BIT              NOT NULL,
        hazard_class_category     VARCHAR(60)      NOT NULL,
        hazard_severity_rank      INT              NOT NULL,
        inspection_date           DATE             NOT NULL,
        approved_date             DATE             NULL,
        original_certify_by_date  DATE             NULL,
        original_correct_by_date  DATE             NULL,
        new_certify_by_date       DATE             NULL,
        new_correct_by_date       DATE             NULL,
        certified_date            DATE             NULL,
        order_number              VARCHAR(50)      NULL,
        nov_id                    BIGINT           NULL,
        nov_description           NVARCHAR(MAX)    NULL,
        nov_issued_date           DATE             NULL,
        current_status_id         INT              NULL,
        current_status            VARCHAR(150)     NULL,
        current_status_date       DATE             NULL,
        nov_type                  VARCHAR(50)      NULL,
        violation_status          VARCHAR(30)      NOT NULL,
        is_open_violation         BIT              NOT NULL,
        rent_impairing_flag       CHAR(1)          NULL,
        is_rent_impairing         BIT              NOT NULL,
        latitude                  DECIMAL(10,6)    NULL,
        longitude                 DECIMAL(10,6)    NULL,
        community_board           INT              NULL,
        bin                       VARCHAR(20)      NULL,
        bbl                       VARCHAR(20)      NULL,
        nta                       VARCHAR(200)     NULL,
        is_registered_building    BIT              NOT NULL,
        bronze_row_id             BIGINT           NOT NULL,
        raw_row_num               BIGINT           NOT NULL,
        source_batch_id           UNIQUEIDENTIFIER NOT NULL,
        DW_create_date            DATETIME2        NOT NULL DEFAULT SYSDATETIME()
    );
END;
GO

CREATE OR ALTER PROCEDURE silver.load_violation
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @batch         UNIQUEIDENTIFIER = NEWID(),
            @start         DATETIME2        = SYSDATETIME(),
            @bronze_cnt    BIGINT           = 0,
            @accept_cnt    BIGINT           = 0,
            @reject_cnt    BIGINT           = 0,
            @dup_cnt       BIGINT           = 0,
            @matched_cnt   BIGINT           = 0,
            @unmatched_cnt BIGINT           = 0;

    BEGIN TRY
        SELECT @bronze_cnt = COUNT_BIG(*) FROM bronze.violations;

        SELECT
            v.*,
            NULLIF(TRIM(v.violationid), '') AS clean_violationid_str,
            TRY_CONVERT(BIGINT, NULLIF(TRIM(v.violationid), '')) AS parsed_violation_id,
            CASE
                WHEN NULLIF(TRIM(v.violationid), '') IS NULL THEN 'missing_violation_id'
                WHEN TRY_CONVERT(BIGINT, NULLIF(TRIM(v.violationid), '')) IS NULL THEN 'conversion_failed_violation_id'
                WHEN TRY_CONVERT(BIGINT, NULLIF(TRIM(v.violationid), '')) <= 0 THEN 'implausible_nonpositive_violation_id'
                ELSE NULL
            END AS key_reject_reason
        INTO #viol_stage
        FROM bronze.violations v
        OPTION (MAXDOP 1);

        SELECT
            s.*,
            ROW_NUMBER() OVER (
                PARTITION BY s.parsed_violation_id
                ORDER BY
                    TRY_CONVERT(DATETIME2, REPLACE(NULLIF(TRIM(s.currentstatusdate), ''), '/', '-')) DESC,
                    s.raw_row_num DESC,
                    s.bronze_row_id DESC
            ) AS rn,
            FIRST_VALUE(s.bronze_row_id) OVER (
                PARTITION BY s.parsed_violation_id
                ORDER BY
                    TRY_CONVERT(DATETIME2, REPLACE(NULLIF(TRIM(s.currentstatusdate), ''), '/', '-')) DESC,
                    s.raw_row_num DESC,
                    s.bronze_row_id DESC
            ) AS kept_bronze_row_id
        INTO #viol_dedup
        FROM #viol_stage s
        WHERE s.key_reject_reason IS NULL
        OPTION (MAXDOP 1);

        SELECT
            d.bronze_row_id,
            d.raw_row_num,
            d.batch_id AS source_batch_id,
            d.parsed_violation_id AS violation_id,
            TRY_CONVERT(INT, NULLIF(TRIM(d.buildingid), '')) AS building_id,
            TRY_CONVERT(INT, NULLIF(TRIM(d.registrationid), '')) AS registration_id,
            TRY_CONVERT(INT, NULLIF(TRIM(d.boroid), '')) AS boro_id,
            UPPER(ISNULL(NULLIF(TRIM(d.boro), ''), 'STATEN ISLAND')) AS borough_name,
            NULLIF(TRIM(d.housenumber), '') AS house_number,
            NULLIF(TRIM(d.streetname), '') AS street_name,
            NULLIF(TRIM(d.zip), '') AS zip_code,
            NULLIF(TRIM(d.apartment), '') AS apartment,
            NULLIF(TRIM(d.story), '') AS story,
            TRY_CONVERT(INT, NULLIF(TRIM(d.block), '')) AS tax_block,
            TRY_CONVERT(INT, NULLIF(TRIM(d.lot), '')) AS tax_lot,
            LEFT(UPPER(NULLIF(TRIM(d.class), '')), 1) AS violation_class,
            CASE
                WHEN UPPER(NULLIF(TRIM(d.class), '')) IN ('A', 'B', 'C') THEN CAST(1 AS BIT)
                ELSE CAST(0 AS BIT)
            END AS is_hazardous_violation,
            CASE UPPER(NULLIF(TRIM(d.class), ''))
                WHEN 'A' THEN 'Class A - Non-Hazardous'
                WHEN 'B' THEN 'Class B - Hazardous'
                WHEN 'C' THEN 'Class C - Immediately Hazardous'
                WHEN 'I' THEN 'Class I - Informational/Administrative Order'
                ELSE 'Unknown'
            END AS hazard_class_category,
            CASE UPPER(NULLIF(TRIM(d.class), ''))
                WHEN 'A' THEN 1
                WHEN 'B' THEN 2
                WHEN 'C' THEN 3
                WHEN 'I' THEN 0   -- Class I is administrative/informational, never ranked above C
                ELSE 0
            END AS hazard_severity_rank,
            CAST(TRY_CONVERT(DATETIME2, REPLACE(NULLIF(TRIM(d.inspectiondate), ''), '/', '-')) AS DATE) AS inspection_date,
            CAST(TRY_CONVERT(DATETIME2, REPLACE(NULLIF(TRIM(d.approveddate), ''), '/', '-')) AS DATE) AS approved_date,
            CAST(TRY_CONVERT(DATETIME2, REPLACE(NULLIF(TRIM(d.originalcertifybydate), ''), '/', '-')) AS DATE) AS original_certify_by_date,
            CAST(TRY_CONVERT(DATETIME2, REPLACE(NULLIF(TRIM(d.originalcorrectbydate), ''), '/', '-')) AS DATE) AS original_correct_by_date,
            CAST(TRY_CONVERT(DATETIME2, REPLACE(NULLIF(TRIM(d.newcertifybydate), ''), '/', '-')) AS DATE) AS new_certify_by_date,
            CAST(TRY_CONVERT(DATETIME2, REPLACE(NULLIF(TRIM(d.newcorrectbydate), ''), '/', '-')) AS DATE) AS new_correct_by_date,
            CAST(TRY_CONVERT(DATETIME2, REPLACE(NULLIF(TRIM(d.certifieddate), ''), '/', '-')) AS DATE) AS certified_date,
            NULLIF(TRIM(d.ordernumber), '') AS order_number,
            TRY_CONVERT(BIGINT, NULLIF(TRIM(d.novid), '')) AS nov_id,
            NULLIF(TRIM(d.novdescription), '') AS nov_description,
            CAST(TRY_CONVERT(DATETIME2, REPLACE(NULLIF(TRIM(d.novissueddate), ''), '/', '-')) AS DATE) AS nov_issued_date,
            TRY_CONVERT(INT, NULLIF(TRIM(d.currentstatusid), '')) AS current_status_id,
            UPPER(NULLIF(TRIM(d.currentstatus), '')) AS current_status,
            CAST(TRY_CONVERT(DATETIME2, REPLACE(NULLIF(TRIM(d.currentstatusdate), ''), '/', '-')) AS DATE) AS current_status_date,
            UPPER(NULLIF(TRIM(d.novtype), '')) AS nov_type,
            UPPER(ISNULL(NULLIF(TRIM(d.violationstatus), ''), 'UNKNOWN')) AS violation_status,
            CASE WHEN UPPER(NULLIF(TRIM(d.violationstatus), '')) = 'OPEN' THEN CAST(1 AS BIT) ELSE CAST(0 AS BIT) END AS is_open_violation,
            LEFT(UPPER(NULLIF(TRIM(d.rentimpairing), '')), 1) AS rent_impairing_flag,
            CASE WHEN UPPER(NULLIF(TRIM(d.rentimpairing), '')) = 'Y' THEN CAST(1 AS BIT) ELSE CAST(0 AS BIT) END AS is_rent_impairing,
            TRY_CONVERT(DECIMAL(10,6), NULLIF(TRIM(d.latitude), '')) AS latitude,
            TRY_CONVERT(DECIMAL(10,6), NULLIF(TRIM(d.longitude), '')) AS longitude,
            TRY_CONVERT(INT, NULLIF(TRIM(d.communityboard), '')) AS community_board,
            NULLIF(TRIM(d.bin), '') AS bin,
            NULLIF(TRIM(d.bbl), '') AS bbl,
            NULLIF(TRIM(d.nta), '') AS nta,
            CASE
                WHEN NULLIF(TRIM(d.buildingid), '') IS NULL THEN 'missing_building_id'
                WHEN TRY_CONVERT(INT, NULLIF(TRIM(d.buildingid), '')) IS NULL THEN 'conversion_failed_building_id'
                WHEN TRY_CONVERT(INT, NULLIF(TRIM(d.buildingid), '')) <= 0 THEN 'implausible_nonpositive_building_id'
                WHEN NULLIF(TRIM(d.class), '') IS NULL THEN 'missing_violation_class'
                WHEN UPPER(NULLIF(TRIM(d.class), '')) NOT IN ('A', 'B', 'C', 'I') THEN 'invalid_violation_class_domain'
                WHEN NULLIF(TRIM(d.inspectiondate), '') IS NULL THEN 'missing_inspection_date'
                WHEN TRY_CONVERT(DATETIME2, REPLACE(NULLIF(TRIM(d.inspectiondate), ''), '/', '-')) IS NULL THEN 'conversion_failed_inspection_date'
                WHEN CAST(TRY_CONVERT(DATETIME2, REPLACE(NULLIF(TRIM(d.inspectiondate), ''), '/', '-')) AS DATE) < '1900-01-01'
                  OR CAST(TRY_CONVERT(DATETIME2, REPLACE(NULLIF(TRIM(d.inspectiondate), ''), '/', '-')) AS DATE) > CAST(SYSDATETIME() AS DATE)
                  THEN 'implausible_out_of_range_inspection_date'
                WHEN NULLIF(TRIM(d.approveddate), '') IS NOT NULL
                 AND TRY_CONVERT(DATETIME2, REPLACE(NULLIF(TRIM(d.approveddate), ''), '/', '-')) IS NULL
                  THEN 'conversion_failed_approved_date'
                WHEN NULLIF(TRIM(d.novissueddate), '') IS NOT NULL
                 AND TRY_CONVERT(DATETIME2, REPLACE(NULLIF(TRIM(d.novissueddate), ''), '/', '-')) IS NULL
                  THEN 'conversion_failed_nov_issued_date'
                WHEN NULLIF(TRIM(d.certifieddate), '') IS NOT NULL
                 AND TRY_CONVERT(DATETIME2, REPLACE(NULLIF(TRIM(d.certifieddate), ''), '/', '-')) IS NULL
                  THEN 'conversion_failed_certified_date'
                WHEN NULLIF(TRIM(d.currentstatusdate), '') IS NOT NULL
                 AND TRY_CONVERT(DATETIME2, REPLACE(NULLIF(TRIM(d.currentstatusdate), ''), '/', '-')) IS NULL
                  THEN 'conversion_failed_current_status_date'
                ELSE NULL
            END AS attr_reject_reason
        INTO #viol_typed
        FROM #viol_dedup d
        WHERE d.rn = 1
        OPTION (MAXDOP 1);

        BEGIN TRAN;

        DELETE FROM silver.reject_log WHERE source_table = 'bronze.violations';
        DELETE FROM silver.duplicate_log WHERE source_table = 'bronze.violations';
        DELETE FROM silver.batch_reconciliation WHERE source_table = 'bronze.violations';
        TRUNCATE TABLE silver.violation;

        INSERT INTO silver.reject_log (source_table, bronze_row_id, raw_row_num, business_key, reason, raw_summary, batch_id)
        SELECT
            'bronze.violations',
            bronze_row_id,
            raw_row_num,
            clean_violationid_str,
            key_reject_reason,
            CONCAT(N'violationid=', ISNULL(violationid, N'NULL'), N', buildingid=', ISNULL(buildingid, N'NULL')),
            @batch
        FROM #viol_stage
        WHERE key_reject_reason IS NOT NULL
        OPTION (MAXDOP 1);

        INSERT INTO silver.duplicate_log (
            source_table, business_key, kept_bronze_row_id, removed_bronze_row_id,
            removed_raw_row_num, resolution_rule, batch_id
        )
        SELECT
            'bronze.violations',
            CAST(parsed_violation_id AS NVARCHAR(255)),
            kept_bronze_row_id,
            bronze_row_id,
            raw_row_num,
            'Keep latest currentstatusdate, then latest raw_row_num',
            @batch
        FROM #viol_dedup
        WHERE rn > 1
        OPTION (MAXDOP 1);

        INSERT INTO silver.reject_log (source_table, bronze_row_id, raw_row_num, business_key, reason, raw_summary, batch_id)
        SELECT
            'bronze.violations',
            bronze_row_id,
            raw_row_num,
            CAST(violation_id AS NVARCHAR(255)),
            attr_reject_reason,
            CONCAT(N'building_id=', ISNULL(CAST(building_id AS NVARCHAR(50)), N'NULL'),
                   N', class=', ISNULL(violation_class, N'NULL'),
                   N', inspection_date=', ISNULL(CAST(inspection_date AS NVARCHAR(50)), N'NULL')),
            @batch
        FROM #viol_typed
        WHERE attr_reject_reason IS NOT NULL
        OPTION (MAXDOP 1);

        INSERT INTO silver.violation (
            violation_id, building_id, registration_id, boro_id, borough_name,
            house_number, street_name, zip_code, apartment, story, tax_block, tax_lot,
            violation_class, is_hazardous_violation, hazard_class_category, hazard_severity_rank,
            inspection_date, approved_date, original_certify_by_date, original_correct_by_date,
            new_certify_by_date, new_correct_by_date, certified_date, order_number, nov_id,
            nov_description, nov_issued_date, current_status_id, current_status,
            current_status_date, nov_type, violation_status, is_open_violation,
            rent_impairing_flag, is_rent_impairing, latitude, longitude, community_board,
            bin, bbl, nta, is_registered_building,
            bronze_row_id, raw_row_num, source_batch_id
        )
        SELECT
            t.violation_id, t.building_id, t.registration_id, t.boro_id, t.borough_name,
            t.house_number, t.street_name, t.zip_code, t.apartment, t.story, t.tax_block, t.tax_lot,
            t.violation_class, t.is_hazardous_violation, t.hazard_class_category, t.hazard_severity_rank,
            t.inspection_date, t.approved_date, t.original_certify_by_date, t.original_correct_by_date,
            t.new_certify_by_date, t.new_correct_by_date, t.certified_date, t.order_number, t.nov_id,
            t.nov_description, t.nov_issued_date, t.current_status_id, t.current_status,
            t.current_status_date, t.nov_type, t.violation_status, t.is_open_violation,
            t.rent_impairing_flag, t.is_rent_impairing, t.latitude, t.longitude, t.community_board,
            t.bin, t.bbl, t.nta,
            CASE WHEN b.building_id IS NOT NULL THEN CAST(1 AS BIT) ELSE CAST(0 AS BIT) END AS is_registered_building,
            t.bronze_row_id, t.raw_row_num, t.source_batch_id
        FROM #viol_typed t
        LEFT JOIN silver.building b ON t.building_id = b.building_id
        WHERE t.attr_reject_reason IS NULL
        OPTION (MAXDOP 1);

        SELECT @accept_cnt    = COUNT_BIG(*) FROM silver.violation;
        SELECT @reject_cnt    = COUNT_BIG(*) FROM silver.reject_log WHERE source_table = 'bronze.violations';
        SELECT @dup_cnt       = COUNT_BIG(*) FROM silver.duplicate_log WHERE source_table = 'bronze.violations';
        SELECT @matched_cnt   = ISNULL(SUM(CASE WHEN is_registered_building = 1 THEN 1 ELSE 0 END), 0),
               @unmatched_cnt = ISNULL(SUM(CASE WHEN is_registered_building = 0 THEN 1 ELSE 0 END), 0)
        FROM silver.violation;

        INSERT INTO silver.batch_reconciliation (
            source_table, silver_table, batch_id, bronze_rows, accepted_rows,
            rejected_rows, duplicate_rows_removed, reconciliation_diff,
            matched_building_rows, unmatched_building_rows
        )
        VALUES (
            'bronze.violations', 'silver.violation', @batch, @bronze_cnt, @accept_cnt,
            @reject_cnt, @dup_cnt, @bronze_cnt - (@accept_cnt + @reject_cnt + @dup_cnt),
            @matched_cnt, @unmatched_cnt
        );

        COMMIT TRAN;

        INSERT INTO audit.load_log (batch_id, source_name, target_table, start_time, end_time, rows_loaded, status, message)
        VALUES (@batch, 'bronze.violations', 'silver.violation', @start, SYSDATETIME(), @accept_cnt, 'SUCCESS',
                CONCAT('Silver violation load complete: accepted=', @accept_cnt, ', rejected=', @reject_cnt, ', duplicates=', @dup_cnt));
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRAN;
        INSERT INTO audit.load_log (batch_id, source_name, target_table, start_time, end_time, rows_loaded, status, message)
        VALUES (@batch, 'bronze.violations', 'silver.violation', @start, SYSDATETIME(), NULL, 'FAILED', ERROR_MESSAGE());
        THROW;
    END CATCH
END;
GO

-- =============================================================================
-- 4. SILVER.OMO_CHARGE (Natural Key: omo_id, Unique Secondary Key: omo_number)
-- =============================================================================
IF OBJECT_ID(N'silver.omo_charge', N'U') IS NULL
BEGIN
    CREATE TABLE silver.omo_charge (
        omo_id                    BIGINT           NOT NULL PRIMARY KEY,
        omo_number                VARCHAR(50)      NOT NULL UNIQUE,
        building_id               INT              NOT NULL,
        boro_id                   INT              NULL,
        borough_name              VARCHAR(50)      NOT NULL,
        house_number              VARCHAR(100)     NULL,
        street_name               VARCHAR(250)     NULL,
        apartment                 VARCHAR(50)      NULL,
        zip_code                  VARCHAR(20)      NULL,
        tax_block                 INT              NULL,
        tax_lot                   INT              NULL,
        lifecycle                 VARCHAR(50)      NULL,
        work_type_general         VARCHAR(50)      NULL,
        omo_status_reason         VARCHAR(200)     NULL,
        omo_award_amount          DECIMAL(18,2)    NULL,
        net_change_orders         DECIMAL(18,2)    NULL,
        financial_value_status    VARCHAR(50)      NOT NULL,
        omo_create_date           DATE             NOT NULL,
        omo_award_date            DATE             NULL,
        is_aep_flag               VARCHAR(20)      NULL,
        is_commercial_demolition  VARCHAR(50)      NULL,
        service_charge_flag       VARCHAR(20)      NULL,
        has_service_charge        BIT              NOT NULL,
        fema_event_id             INT              NULL,
        fema_event                VARCHAR(200)     NULL,
        omo_description           NVARCHAR(MAX)    NULL,
        latitude                  DECIMAL(10,6)    NULL,
        longitude                 DECIMAL(10,6)    NULL,
        community_board           INT              NULL,
        bin                       VARCHAR(20)      NULL,
        bbl                       VARCHAR(20)      NULL,
        nta                       VARCHAR(200)     NULL,
        is_eligible_repair_cohort BIT              NOT NULL,
        repair_cohort_category    VARCHAR(100)     NOT NULL,
        is_registered_building    BIT              NOT NULL,
        bronze_row_id             BIGINT           NOT NULL,
        raw_row_num               BIGINT           NOT NULL,
        source_batch_id           UNIQUEIDENTIFIER NOT NULL,
        DW_create_date            DATETIME2        NOT NULL DEFAULT SYSDATETIME()
    );
END;
GO

CREATE OR ALTER PROCEDURE silver.load_omo_charge
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @batch         UNIQUEIDENTIFIER = NEWID(),
            @start         DATETIME2        = SYSDATETIME(),
            @bronze_cnt    BIGINT           = 0,
            @accept_cnt    BIGINT           = 0,
            @reject_cnt    BIGINT           = 0,
            @dup_cnt       BIGINT           = 0,
            @matched_cnt   BIGINT           = 0,
            @unmatched_cnt BIGINT           = 0;

    BEGIN TRY
        SELECT @bronze_cnt = COUNT_BIG(*) FROM bronze.omo_charges;

        SELECT
            o.*,
            NULLIF(TRIM(o.omoid), '') AS clean_omoid_str,
            TRY_CONVERT(BIGINT, NULLIF(TRIM(o.omoid), '')) AS parsed_omo_id,
            CASE
                WHEN NULLIF(TRIM(o.omoid), '') IS NULL THEN 'missing_omo_id'
                WHEN TRY_CONVERT(BIGINT, NULLIF(TRIM(o.omoid), '')) IS NULL THEN 'conversion_failed_omo_id'
                WHEN TRY_CONVERT(BIGINT, NULLIF(TRIM(o.omoid), '')) <= 0 THEN 'implausible_nonpositive_omo_id'
                ELSE NULL
            END AS key_reject_reason
        INTO #omo_stage
        FROM bronze.omo_charges o
        OPTION (MAXDOP 1);

        SELECT
            s.*,
            ROW_NUMBER() OVER (
                PARTITION BY s.parsed_omo_id
                ORDER BY
                    TRY_CONVERT(DATETIME2, REPLACE(NULLIF(TRIM(s.omoawarddate), ''), '/', '-')) DESC,
                    TRY_CONVERT(DATETIME2, REPLACE(NULLIF(TRIM(s.omocreatedate), ''), '/', '-')) DESC,
                    s.raw_row_num DESC,
                    s.bronze_row_id DESC
            ) AS rn,
            FIRST_VALUE(s.bronze_row_id) OVER (
                PARTITION BY s.parsed_omo_id
                ORDER BY
                    TRY_CONVERT(DATETIME2, REPLACE(NULLIF(TRIM(s.omoawarddate), ''), '/', '-')) DESC,
                    TRY_CONVERT(DATETIME2, REPLACE(NULLIF(TRIM(s.omocreatedate), ''), '/', '-')) DESC,
                    s.raw_row_num DESC,
                    s.bronze_row_id DESC
            ) AS kept_bronze_row_id
        INTO #omo_dedup
        FROM #omo_stage s
        WHERE s.key_reject_reason IS NULL
        OPTION (MAXDOP 1);

        WITH omo_num_ranked AS (
            SELECT
                d.*,
                ROW_NUMBER() OVER (
                    PARTITION BY UPPER(NULLIF(TRIM(d.omonumber), ''))
                    ORDER BY d.parsed_omo_id DESC
                ) AS omo_num_rn
            FROM #omo_dedup d
            WHERE d.rn = 1
        )
        SELECT
            d.bronze_row_id,
            d.raw_row_num,
            d.batch_id AS source_batch_id,
            d.parsed_omo_id AS omo_id,
            UPPER(NULLIF(TRIM(d.omonumber), '')) AS omo_number,
            TRY_CONVERT(INT, NULLIF(TRIM(d.buildingid), '')) AS building_id,
            TRY_CONVERT(INT, NULLIF(TRIM(d.boro_id), '')) AS boro_id,
            UPPER(ISNULL(NULLIF(TRIM(d.boro), ''), 'STATEN ISLAND')) AS borough_name,
            NULLIF(TRIM(d.housenumber), '') AS house_number,
            NULLIF(TRIM(d.streetname), '') AS street_name,
            NULLIF(TRIM(d.apartment), '') AS apartment,
            NULLIF(TRIM(d.zip), '') AS zip_code,
            TRY_CONVERT(INT, NULLIF(TRIM(d.block), '')) AS tax_block,
            TRY_CONVERT(INT, NULLIF(TRIM(d.lot), '')) AS tax_lot,
            NULLIF(TRIM(d.lifecycle), '') AS lifecycle,
            UPPER(NULLIF(TRIM(d.worktypegeneral), '')) AS work_type_general,
            NULLIF(TRIM(d.omostatusreason), '') AS omo_status_reason,
            TRY_CONVERT(DECIMAL(18,2), REPLACE(NULLIF(TRIM(d.omoawardamount), ''), ',', '')) AS omo_award_amount,
            TRY_CONVERT(DECIMAL(18,2), REPLACE(NULLIF(TRIM(d.netchangeorders), ''), ',', '')) AS net_change_orders,
            CASE
                WHEN NULLIF(TRIM(d.omoawardamount), '') IS NULL THEN 'missing_amount'
                WHEN TRY_CONVERT(DECIMAL(18,2), REPLACE(NULLIF(TRIM(d.omoawardamount), ''), ',', '')) = 0 THEN 'zero_dollar_un_awarded_or_cancelled'
                WHEN TRY_CONVERT(DECIMAL(18,2), REPLACE(NULLIF(TRIM(d.omoawardamount), ''), ',', '')) > 0 THEN 'positive_award'
                ELSE 'negative_or_invalid'
            END AS financial_value_status,
            CAST(TRY_CONVERT(DATETIME2, REPLACE(NULLIF(TRIM(d.omocreatedate), ''), '/', '-')) AS DATE) AS omo_create_date,
            CAST(TRY_CONVERT(DATETIME2, REPLACE(NULLIF(TRIM(d.omoawarddate), ''), '/', '-')) AS DATE) AS omo_award_date,
            UPPER(NULLIF(TRIM(d.isaep), '')) AS is_aep_flag,
            UPPER(NULLIF(TRIM(d.iscommercialdemolition), '')) AS is_commercial_demolition,
            NULLIF(TRIM(d.servicechargeflag), '') AS service_charge_flag,
            CASE WHEN UPPER(NULLIF(TRIM(d.servicechargeflag), '')) = 'TRUE' THEN CAST(1 AS BIT) ELSE CAST(0 AS BIT) END AS has_service_charge,
            TRY_CONVERT(INT, NULLIF(TRIM(d.femaeventid), '')) AS fema_event_id,
            NULLIF(TRIM(d.femaevent), '') AS fema_event,
            NULLIF(TRIM(d.omodescription), '') AS omo_description,
            TRY_CONVERT(DECIMAL(10,6), NULLIF(TRIM(d.latitude), '')) AS latitude,
            TRY_CONVERT(DECIMAL(10,6), NULLIF(TRIM(d.longitude), '')) AS longitude,
            TRY_CONVERT(INT, NULLIF(TRIM(d.community_board), '')) AS community_board,
            NULLIF(TRIM(d.bin), '') AS bin,
            NULLIF(TRIM(d.bbl), '') AS bbl,
            NULLIF(TRIM(d.nta), '') AS nta,
            CASE
                WHEN UPPER(ISNULL(NULLIF(TRIM(d.iscommercialdemolition), ''), '')) = 'COMM DEMOL' THEN CAST(0 AS BIT)
                WHEN UPPER(ISNULL(NULLIF(TRIM(d.worktypegeneral), ''), '')) = 'DEMOL'
                  OR UPPER(ISNULL(NULLIF(TRIM(d.lifecycle), ''), '')) <> 'STANDING BUILDING' THEN CAST(0 AS BIT)
                WHEN UPPER(ISNULL(NULLIF(TRIM(d.omostatusreason), ''), '')) IN ('DUPLICATE OMO', 'FOR FIELD VISITS ONLY - CANCELLED') THEN CAST(0 AS BIT)
                WHEN ISNULL(TRY_CONVERT(DECIMAL(18,2), REPLACE(NULLIF(TRIM(d.omoawardamount), ''), ',', '')), 0) <= 0 THEN CAST(0 AS BIT)
                ELSE CAST(1 AS BIT)
            END AS is_eligible_repair_cohort,
            CASE
                WHEN UPPER(ISNULL(NULLIF(TRIM(d.iscommercialdemolition), ''), '')) = 'COMM DEMOL'
                    THEN 'Excluded - Commercial Demolition'
                WHEN UPPER(ISNULL(NULLIF(TRIM(d.worktypegeneral), ''), '')) = 'DEMOL'
                  OR UPPER(ISNULL(NULLIF(TRIM(d.lifecycle), ''), '')) <> 'STANDING BUILDING'
                    THEN 'Excluded - Structural Demolition or Vacant Land'
                WHEN UPPER(ISNULL(NULLIF(TRIM(d.omostatusreason), ''), '')) IN ('DUPLICATE OMO', 'FOR FIELD VISITS ONLY - CANCELLED')
                    THEN 'Excluded - Cancelled or Duplicate Administrative Order'
                WHEN ISNULL(TRY_CONVERT(DECIMAL(18,2), REPLACE(NULLIF(TRIM(d.omoawardamount), ''), ',', '')), 0) <= 0
                    THEN 'Excluded - Un-Awarded Zero-Dollar Order'
                ELSE 'Eligible Residential Building Repair Order'
            END AS repair_cohort_category,
            CASE
                WHEN NULLIF(TRIM(d.omonumber), '') IS NULL THEN 'missing_omo_number'
                WHEN d.omo_num_rn > 1 THEN 'duplicate_omo_number_across_omo_id'
                WHEN NULLIF(TRIM(d.buildingid), '') IS NULL THEN 'missing_building_id'
                WHEN TRY_CONVERT(INT, NULLIF(TRIM(d.buildingid), '')) IS NULL THEN 'conversion_failed_building_id'
                WHEN TRY_CONVERT(INT, NULLIF(TRIM(d.buildingid), '')) <= 0 THEN 'implausible_nonpositive_building_id'
                WHEN NULLIF(TRIM(d.omocreatedate), '') IS NULL THEN 'missing_omo_create_date'
                WHEN TRY_CONVERT(DATETIME2, REPLACE(NULLIF(TRIM(d.omocreatedate), ''), '/', '-')) IS NULL THEN 'conversion_failed_omo_create_date'
                WHEN CAST(TRY_CONVERT(DATETIME2, REPLACE(NULLIF(TRIM(d.omocreatedate), ''), '/', '-')) AS DATE) < '1900-01-01'
                  OR CAST(TRY_CONVERT(DATETIME2, REPLACE(NULLIF(TRIM(d.omocreatedate), ''), '/', '-')) AS DATE) > CAST(SYSDATETIME() AS DATE)
                  THEN 'implausible_out_of_range_omo_create_date'
                WHEN NULLIF(TRIM(d.omoawarddate), '') IS NOT NULL
                 AND TRY_CONVERT(DATETIME2, REPLACE(NULLIF(TRIM(d.omoawarddate), ''), '/', '-')) IS NULL
                  THEN 'conversion_failed_omo_award_date'
                WHEN NULLIF(TRIM(d.omoawardamount), '') IS NOT NULL
                 AND TRY_CONVERT(DECIMAL(18,2), REPLACE(NULLIF(TRIM(d.omoawardamount), ''), ',', '')) IS NULL
                  THEN 'conversion_failed_omo_award_amount'
                WHEN TRY_CONVERT(DECIMAL(18,2), REPLACE(NULLIF(TRIM(d.omoawardamount), ''), ',', '')) < 0
                  THEN 'implausible_negative_omo_award_amount'
                WHEN NULLIF(TRIM(d.netchangeorders), '') IS NOT NULL
                 AND TRY_CONVERT(DECIMAL(18,2), REPLACE(NULLIF(TRIM(d.netchangeorders), ''), ',', '')) IS NULL
                  THEN 'conversion_failed_net_change_orders'
                ELSE NULL
            END AS attr_reject_reason
        INTO #omo_typed
        FROM omo_num_ranked d
        OPTION (MAXDOP 1);

        BEGIN TRAN;

        DELETE FROM silver.reject_log WHERE source_table = 'bronze.omo_charges';
        DELETE FROM silver.duplicate_log WHERE source_table = 'bronze.omo_charges';
        DELETE FROM silver.batch_reconciliation WHERE source_table = 'bronze.omo_charges';
        TRUNCATE TABLE silver.omo_charge;

        INSERT INTO silver.reject_log (source_table, bronze_row_id, raw_row_num, business_key, reason, raw_summary, batch_id)
        SELECT
            'bronze.omo_charges',
            bronze_row_id,
            raw_row_num,
            clean_omoid_str,
            key_reject_reason,
            CONCAT(N'omoid=', ISNULL(omoid, N'NULL'), N', omonumber=', ISNULL(omonumber, N'NULL')),
            @batch
        FROM #omo_stage
        WHERE key_reject_reason IS NOT NULL
        OPTION (MAXDOP 1);

        INSERT INTO silver.duplicate_log (
            source_table, business_key, kept_bronze_row_id, removed_bronze_row_id,
            removed_raw_row_num, resolution_rule, batch_id
        )
        SELECT
            'bronze.omo_charges',
            CAST(parsed_omo_id AS NVARCHAR(255)),
            kept_bronze_row_id,
            bronze_row_id,
            raw_row_num,
            'Keep latest omoawarddate / omocreatedate, then latest raw_row_num',
            @batch
        FROM #omo_dedup
        WHERE rn > 1
        OPTION (MAXDOP 1);

        INSERT INTO silver.reject_log (source_table, bronze_row_id, raw_row_num, business_key, reason, raw_summary, batch_id)
        SELECT
            'bronze.omo_charges',
            bronze_row_id,
            raw_row_num,
            CAST(omo_id AS NVARCHAR(255)),
            attr_reject_reason,
            CONCAT(N'omo_number=', ISNULL(omo_number, N'NULL'),
                   N', building_id=', ISNULL(CAST(building_id AS NVARCHAR(50)), N'NULL'),
                   N', omo_award_amount=', ISNULL(CAST(omo_award_amount AS NVARCHAR(50)), N'NULL')),
            @batch
        FROM #omo_typed
        WHERE attr_reject_reason IS NOT NULL
        OPTION (MAXDOP 1);

        INSERT INTO silver.omo_charge (
            omo_id, omo_number, building_id, boro_id, borough_name,
            house_number, street_name, apartment, zip_code, tax_block, tax_lot,
            lifecycle, work_type_general, omo_status_reason,
            omo_award_amount, net_change_orders, financial_value_status,
            omo_create_date, omo_award_date, is_aep_flag, is_commercial_demolition,
            service_charge_flag, has_service_charge, fema_event_id, fema_event,
            omo_description, latitude, longitude, community_board,
            bin, bbl, nta, is_eligible_repair_cohort, repair_cohort_category,
            is_registered_building, bronze_row_id, raw_row_num, source_batch_id
        )
        SELECT
            t.omo_id, t.omo_number, t.building_id, t.boro_id, t.borough_name,
            t.house_number, t.street_name, t.apartment, t.zip_code, t.tax_block, t.tax_lot,
            t.lifecycle, t.work_type_general, t.omo_status_reason,
            t.omo_award_amount, t.net_change_orders, t.financial_value_status,
            t.omo_create_date, t.omo_award_date, t.is_aep_flag, t.is_commercial_demolition,
            t.service_charge_flag, t.has_service_charge, t.fema_event_id, t.fema_event,
            t.omo_description, t.latitude, t.longitude, t.community_board,
            t.bin, t.bbl, t.nta, t.is_eligible_repair_cohort, t.repair_cohort_category,
            CASE WHEN b.building_id IS NOT NULL THEN CAST(1 AS BIT) ELSE CAST(0 AS BIT) END AS is_registered_building,
            t.bronze_row_id, t.raw_row_num, t.source_batch_id
        FROM #omo_typed t
        LEFT JOIN silver.building b ON t.building_id = b.building_id
        WHERE t.attr_reject_reason IS NULL
        OPTION (MAXDOP 1);

        SELECT @accept_cnt    = COUNT_BIG(*) FROM silver.omo_charge;
        SELECT @reject_cnt    = COUNT_BIG(*) FROM silver.reject_log WHERE source_table = 'bronze.omo_charges';
        SELECT @dup_cnt       = COUNT_BIG(*) FROM silver.duplicate_log WHERE source_table = 'bronze.omo_charges';
        SELECT @matched_cnt   = ISNULL(SUM(CASE WHEN is_registered_building = 1 THEN 1 ELSE 0 END), 0),
               @unmatched_cnt = ISNULL(SUM(CASE WHEN is_registered_building = 0 THEN 1 ELSE 0 END), 0)
        FROM silver.omo_charge;

        INSERT INTO silver.batch_reconciliation (
            source_table, silver_table, batch_id, bronze_rows, accepted_rows,
            rejected_rows, duplicate_rows_removed, reconciliation_diff,
            matched_building_rows, unmatched_building_rows
        )
        VALUES (
            'bronze.omo_charges', 'silver.omo_charge', @batch, @bronze_cnt, @accept_cnt,
            @reject_cnt, @dup_cnt, @bronze_cnt - (@accept_cnt + @reject_cnt + @dup_cnt),
            @matched_cnt, @unmatched_cnt
        );

        COMMIT TRAN;

        INSERT INTO audit.load_log (batch_id, source_name, target_table, start_time, end_time, rows_loaded, status, message)
        VALUES (@batch, 'bronze.omo_charges', 'silver.omo_charge', @start, SYSDATETIME(), @accept_cnt, 'SUCCESS',
                CONCAT('Silver omo_charge load complete: accepted=', @accept_cnt, ', rejected=', @reject_cnt, ', duplicates=', @dup_cnt));
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRAN;
        INSERT INTO audit.load_log (batch_id, source_name, target_table, start_time, end_time, rows_loaded, status, message)
        VALUES (@batch, 'bronze.omo_charges', 'silver.omo_charge', @start, SYSDATETIME(), NULL, 'FAILED', ERROR_MESSAGE());
        THROW;
    END CATCH
END;
GO

-- =============================================================================
-- 5. MASTER SILVER ORCHESTRATION PROCEDURE (silver.load_all)
-- =============================================================================
CREATE OR ALTER PROCEDURE silver.load_all
AS
BEGIN
    SET NOCOUNT ON;
    EXEC silver.load_building;
    EXEC silver.load_complaint_problem;
    EXEC silver.load_violation;
    EXEC silver.load_omo_charge;
END;
GO
