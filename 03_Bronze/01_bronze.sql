-- =============================================================================
-- sql/01_bronze.sql
-- HomeRescue AI Data Warehouse — Bronze Layer (Raw Text Tables, Staging & Loads)
--
-- Design Rules Enforced:
-- 1. Every source column is preserved as text (NVARCHAR) with zero silent
--    cleaning, filtering, or type coercion (Mandatory Rule 8).
-- 2. Provenance columns on every Bronze table:
--    - bronze_row_id     (BIGINT IDENTITY primary key for traceable row identity)
--    - raw_row_num       (BIGINT 1-based parsed CSV record number)
--    - source_dataset_id (VARCHAR(50) official Socrata 4x4 identifier)
--    - source_file       (NVARCHAR(500) path of loaded raw CSV file)
--    - batch_id          (UNIQUEIDENTIFIER pipeline execution batch ID)
--    - ingested_at       (DATETIME2 UTC/local ingestion timestamp)
-- 3. Safe Staging & Atomic Swap:
--    Data is first staged into bronze.stg_<entity>. Only after staging succeeds
--    and passes non-empty validation does bronze.load_<entity> open a transaction
--    to refresh bronze.<entity>. A failed staging or load step rolls back and
--    preserves the last valid dataset in bronze.<entity>.
-- 4. Execution Audit:
--    Every load attempt logs start_time, end_time, rows_loaded, status, and
--    message to audit.load_log.
-- =============================================================================

IF DB_NAME() IN (N'master', N'tempdb', N'model', N'msdb')
    USE [homerescue_dw];
GO

-- =============================================================================
-- 1. BUILDINGS (NYC Open Data: kj4p-ruqc) — 23 Raw Columns
-- =============================================================================
DROP VIEW IF EXISTS bronze.v_buildings_load;
DROP TABLE IF EXISTS bronze.stg_buildings;

CREATE TABLE bronze.stg_buildings (
    raw_row_num        BIGINT         NULL,
    buildingid         NVARCHAR(255)  NULL,
    boroid             NVARCHAR(255)  NULL,
    boro               NVARCHAR(255)  NULL,
    housenumber        NVARCHAR(255)  NULL,
    lowhousenumber     NVARCHAR(255)  NULL,
    highhousenumber    NVARCHAR(255)  NULL,
    streetname         NVARCHAR(500)  NULL,
    zip                NVARCHAR(255)  NULL,
    block              NVARCHAR(255)  NULL,
    lot                NVARCHAR(255)  NULL,
    bin                NVARCHAR(255)  NULL,
    communityboard     NVARCHAR(255)  NULL,
    censustract        NVARCHAR(255)  NULL,
    managementprogram  NVARCHAR(255)  NULL,
    dobbuildingclassid NVARCHAR(255)  NULL,
    dobbuildingclass   NVARCHAR(255)  NULL,
    legalstories       NVARCHAR(255)  NULL,
    legalclassa        NVARCHAR(255)  NULL,
    legalclassb        NVARCHAR(255)  NULL,
    registrationid     NVARCHAR(255)  NULL,
    lifecycle          NVARCHAR(255)  NULL,
    recordstatusid     NVARCHAR(255)  NULL,
    recordstatus       NVARCHAR(255)  NULL
);
GO

IF OBJECT_ID(N'bronze.buildings', N'U') IS NULL
BEGIN
    CREATE TABLE bronze.buildings (
        bronze_row_id      BIGINT IDENTITY(1,1) NOT NULL PRIMARY KEY,
        raw_row_num        BIGINT               NOT NULL,
        buildingid         NVARCHAR(255)        NULL,
        boroid             NVARCHAR(255)        NULL,
        boro               NVARCHAR(255)        NULL,
        housenumber        NVARCHAR(255)        NULL,
        lowhousenumber     NVARCHAR(255)        NULL,
        highhousenumber    NVARCHAR(255)        NULL,
        streetname         NVARCHAR(500)        NULL,
        zip                NVARCHAR(255)        NULL,
        block              NVARCHAR(255)        NULL,
        lot                NVARCHAR(255)        NULL,
        bin                NVARCHAR(255)        NULL,
        communityboard     NVARCHAR(255)        NULL,
        censustract        NVARCHAR(255)        NULL,
        managementprogram  NVARCHAR(255)        NULL,
        dobbuildingclassid NVARCHAR(255)        NULL,
        dobbuildingclass   NVARCHAR(255)        NULL,
        legalstories       NVARCHAR(255)        NULL,
        legalclassa        NVARCHAR(255)        NULL,
        legalclassb        NVARCHAR(255)        NULL,
        registrationid     NVARCHAR(255)        NULL,
        lifecycle          NVARCHAR(255)        NULL,
        recordstatusid     NVARCHAR(255)        NULL,
        recordstatus       NVARCHAR(255)        NULL,
        source_dataset_id  VARCHAR(50)          NOT NULL DEFAULT 'kj4p-ruqc',
        source_file        NVARCHAR(500)        NOT NULL,
        batch_id           UNIQUEIDENTIFIER     NOT NULL,
        ingested_at        DATETIME2            NOT NULL DEFAULT SYSDATETIME()
    );
END;
GO

CREATE OR ALTER VIEW bronze.v_buildings_load AS
SELECT
    buildingid, boroid, boro, housenumber, lowhousenumber,
    highhousenumber, streetname, zip, block, lot, bin,
    communityboard, censustract, managementprogram,
    dobbuildingclassid, dobbuildingclass, legalstories,
    legalclassa, legalclassb, registrationid, lifecycle,
    recordstatusid, recordstatus
FROM bronze.stg_buildings;
GO

CREATE OR ALTER PROCEDURE bronze.load_buildings
    @file_path  NVARCHAR(500),
    @batch_id   UNIQUEIDENTIFIER = NULL,
    @use_staged BIT = 0
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @batch      UNIQUEIDENTIFIER = ISNULL(@batch_id, NEWID()),
            @start      DATETIME2        = SYSDATETIME(),
            @staged_cnt BIGINT           = 0,
            @rows       BIGINT           = 0,
            @sql        NVARCHAR(MAX);

    BEGIN TRY
        IF @use_staged = 0
        BEGIN
            TRUNCATE TABLE bronze.stg_buildings;
            SET @sql = N'BULK INSERT bronze.v_buildings_load FROM '''
                     + REPLACE(@file_path, N'''', N'''''')
                     + N''' WITH (FIRSTROW = 2, FORMAT = ''CSV'', FIELDQUOTE = ''"'', FIELDTERMINATOR = '','', CODEPAGE = ''65001'', TABLOCK);';
            EXEC sp_executesql @sql;
        END;

        SELECT @staged_cnt = COUNT_BIG(*) FROM bronze.stg_buildings;
        IF @staged_cnt = 0
            THROW 50001, 'Staging table bronze.stg_buildings is empty; aborting load to preserve existing bronze.buildings data.', 1;

        BEGIN TRAN;
            TRUNCATE TABLE bronze.buildings;

            INSERT INTO bronze.buildings (
                raw_row_num,
                buildingid, boroid, boro, housenumber, lowhousenumber,
                highhousenumber, streetname, zip, block, lot, bin,
                communityboard, censustract, managementprogram,
                dobbuildingclassid, dobbuildingclass, legalstories,
                legalclassa, legalclassb, registrationid, lifecycle,
                recordstatusid, recordstatus,
                source_dataset_id, source_file, batch_id, ingested_at
            )
            SELECT
                ISNULL(raw_row_num, ROW_NUMBER() OVER (ORDER BY (SELECT NULL))),
                buildingid, boroid, boro, housenumber, lowhousenumber,
                highhousenumber, streetname, zip, block, lot, bin,
                communityboard, censustract, managementprogram,
                dobbuildingclassid, dobbuildingclass, legalstories,
                legalclassa, legalclassb, registrationid, lifecycle,
                recordstatusid, recordstatus,
                'kj4p-ruqc', @file_path, @batch, @start
            FROM bronze.stg_buildings
            ORDER BY ISNULL(raw_row_num, 0);

            SELECT @rows = COUNT_BIG(*) FROM bronze.buildings;
        COMMIT TRAN;

        TRUNCATE TABLE bronze.stg_buildings;

        INSERT INTO audit.load_log (batch_id, source_name, target_table, start_time, end_time, rows_loaded, status, message)
        VALUES (@batch, 'kj4p-ruqc:buildings', 'bronze.buildings', @start, SYSDATETIME(), @rows, 'SUCCESS', 'Bronze buildings loaded via safe staging swap');
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRAN;
        INSERT INTO audit.load_log (batch_id, source_name, target_table, start_time, end_time, rows_loaded, status, message)
        VALUES (@batch, 'kj4p-ruqc:buildings', 'bronze.buildings', @start, SYSDATETIME(), NULL, 'FAILED', ERROR_MESSAGE());
        THROW;
    END CATCH
END;
GO

-- =============================================================================
-- 2. COMPLAINTS & PROBLEMS (NYC Open Data: ygpa-z7cr) — 33 Raw Columns
-- =============================================================================
DROP VIEW IF EXISTS bronze.v_complaints_problems_load;
DROP TABLE IF EXISTS bronze.stg_complaints_problems;

CREATE TABLE bronze.stg_complaints_problems (
    raw_row_num              BIGINT         NULL,
    received_date            NVARCHAR(255)  NULL,
    problem_id               NVARCHAR(255)  NULL,
    complaint_id             NVARCHAR(255)  NULL,
    building_id              NVARCHAR(255)  NULL,
    borough                  NVARCHAR(255)  NULL,
    house_number             NVARCHAR(255)  NULL,
    street_name              NVARCHAR(500)  NULL,
    post_code                NVARCHAR(255)  NULL,
    block                    NVARCHAR(255)  NULL,
    lot                      NVARCHAR(255)  NULL,
    apartment                NVARCHAR(255)  NULL,
    community_board          NVARCHAR(255)  NULL,
    unit_type                NVARCHAR(255)  NULL,
    space_type               NVARCHAR(255)  NULL,
    type                     NVARCHAR(255)  NULL,
    major_category           NVARCHAR(500)  NULL,
    minor_category           NVARCHAR(500)  NULL,
    problem_code             NVARCHAR(500)  NULL,
    complaint_status         NVARCHAR(255)  NULL,
    complaint_status_date    NVARCHAR(255)  NULL,
    problem_status           NVARCHAR(255)  NULL,
    problem_status_date      NVARCHAR(255)  NULL,
    status_description       NVARCHAR(MAX)  NULL,
    problem_duplicate_flag   NVARCHAR(255)  NULL,
    complaint_anonymous_flag NVARCHAR(255)  NULL,
    unique_key               NVARCHAR(255)  NULL,
    latitude                 NVARCHAR(255)  NULL,
    longitude                NVARCHAR(255)  NULL,
    council_district         NVARCHAR(255)  NULL,
    census_tract             NVARCHAR(255)  NULL,
    bin                      NVARCHAR(255)  NULL,
    bbl                      NVARCHAR(255)  NULL,
    nta                      NVARCHAR(500)  NULL
);
GO

IF OBJECT_ID(N'bronze.complaints_problems', N'U') IS NULL
BEGIN
    CREATE TABLE bronze.complaints_problems (
        bronze_row_id            BIGINT IDENTITY(1,1) NOT NULL PRIMARY KEY,
        raw_row_num              BIGINT               NOT NULL,
        received_date            NVARCHAR(255)        NULL,
        problem_id               NVARCHAR(255)        NULL,
        complaint_id             NVARCHAR(255)        NULL,
        building_id              NVARCHAR(255)        NULL,
        borough                  NVARCHAR(255)        NULL,
        house_number             NVARCHAR(255)        NULL,
        street_name              NVARCHAR(500)        NULL,
        post_code                NVARCHAR(255)        NULL,
        block                    NVARCHAR(255)        NULL,
        lot                      NVARCHAR(255)        NULL,
        apartment                NVARCHAR(255)        NULL,
        community_board          NVARCHAR(255)        NULL,
        unit_type                NVARCHAR(255)        NULL,
        space_type               NVARCHAR(255)        NULL,
        type                     NVARCHAR(255)        NULL,
        major_category           NVARCHAR(500)        NULL,
        minor_category           NVARCHAR(500)        NULL,
        problem_code             NVARCHAR(500)        NULL,
        complaint_status         NVARCHAR(255)        NULL,
        complaint_status_date    NVARCHAR(255)        NULL,
        problem_status           NVARCHAR(255)        NULL,
        problem_status_date      NVARCHAR(255)        NULL,
        status_description       NVARCHAR(MAX)        NULL,
        problem_duplicate_flag   NVARCHAR(255)        NULL,
        complaint_anonymous_flag NVARCHAR(255)        NULL,
        unique_key               NVARCHAR(255)        NULL,
        latitude                 NVARCHAR(255)        NULL,
        longitude                NVARCHAR(255)        NULL,
        council_district         NVARCHAR(255)        NULL,
        census_tract             NVARCHAR(255)        NULL,
        bin                      NVARCHAR(255)        NULL,
        bbl                      NVARCHAR(255)        NULL,
        nta                      NVARCHAR(500)        NULL,
        source_dataset_id        VARCHAR(50)          NOT NULL DEFAULT 'ygpa-z7cr',
        source_file              NVARCHAR(500)        NOT NULL,
        batch_id                 UNIQUEIDENTIFIER     NOT NULL,
        ingested_at              DATETIME2            NOT NULL DEFAULT SYSDATETIME()
    );
END;
GO

CREATE OR ALTER VIEW bronze.v_complaints_problems_load AS
SELECT
    received_date, problem_id, complaint_id, building_id,
    borough, house_number, street_name, post_code, block,
    lot, apartment, community_board, unit_type, space_type,
    type, major_category, minor_category, problem_code,
    complaint_status, complaint_status_date, problem_status,
    problem_status_date, status_description,
    problem_duplicate_flag, complaint_anonymous_flag, unique_key,
    latitude, longitude, council_district, census_tract,
    bin, bbl, nta
FROM bronze.stg_complaints_problems;
GO

CREATE OR ALTER PROCEDURE bronze.load_complaints_problems
    @file_path  NVARCHAR(500),
    @batch_id   UNIQUEIDENTIFIER = NULL,
    @use_staged BIT = 0
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @batch      UNIQUEIDENTIFIER = ISNULL(@batch_id, NEWID()),
            @start      DATETIME2        = SYSDATETIME(),
            @staged_cnt BIGINT           = 0,
            @rows       BIGINT           = 0,
            @sql        NVARCHAR(MAX);

    BEGIN TRY
        IF @use_staged = 0
        BEGIN
            TRUNCATE TABLE bronze.stg_complaints_problems;
            SET @sql = N'BULK INSERT bronze.v_complaints_problems_load FROM '''
                     + REPLACE(@file_path, N'''', N'''''')
                     + N''' WITH (FIRSTROW = 2, FORMAT = ''CSV'', FIELDQUOTE = ''"'', FIELDTERMINATOR = '','', CODEPAGE = ''65001'', TABLOCK);';
            EXEC sp_executesql @sql;
        END;

        SELECT @staged_cnt = COUNT_BIG(*) FROM bronze.stg_complaints_problems;
        IF @staged_cnt = 0
            THROW 50002, 'Staging table bronze.stg_complaints_problems is empty; aborting load to preserve existing bronze.complaints_problems data.', 1;

        BEGIN TRAN;
            TRUNCATE TABLE bronze.complaints_problems;

            INSERT INTO bronze.complaints_problems (
                raw_row_num,
                received_date, problem_id, complaint_id, building_id,
                borough, house_number, street_name, post_code, block,
                lot, apartment, community_board, unit_type, space_type,
                type, major_category, minor_category, problem_code,
                complaint_status, complaint_status_date, problem_status,
                problem_status_date, status_description,
                problem_duplicate_flag, complaint_anonymous_flag, unique_key,
                latitude, longitude, council_district, census_tract,
                bin, bbl, nta,
                source_dataset_id, source_file, batch_id, ingested_at
            )
            SELECT
                ISNULL(raw_row_num, ROW_NUMBER() OVER (ORDER BY (SELECT NULL))),
                received_date, problem_id, complaint_id, building_id,
                borough, house_number, street_name, post_code, block,
                lot, apartment, community_board, unit_type, space_type,
                type, major_category, minor_category, problem_code,
                complaint_status, complaint_status_date, problem_status,
                problem_status_date, status_description,
                problem_duplicate_flag, complaint_anonymous_flag, unique_key,
                latitude, longitude, council_district, census_tract,
                bin, bbl, nta,
                'ygpa-z7cr', @file_path, @batch, @start
            FROM bronze.stg_complaints_problems
            ORDER BY ISNULL(raw_row_num, 0);

            SELECT @rows = COUNT_BIG(*) FROM bronze.complaints_problems;
        COMMIT TRAN;

        TRUNCATE TABLE bronze.stg_complaints_problems;

        INSERT INTO audit.load_log (batch_id, source_name, target_table, start_time, end_time, rows_loaded, status, message)
        VALUES (@batch, 'ygpa-z7cr:complaints_problems', 'bronze.complaints_problems', @start, SYSDATETIME(), @rows, 'SUCCESS', 'Bronze complaints_problems loaded via safe staging swap');
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRAN;
        INSERT INTO audit.load_log (batch_id, source_name, target_table, start_time, end_time, rows_loaded, status, message)
        VALUES (@batch, 'ygpa-z7cr:complaints_problems', 'bronze.complaints_problems', @start, SYSDATETIME(), NULL, 'FAILED', ERROR_MESSAGE());
        THROW;
    END CATCH
END;
GO

-- =============================================================================
-- 3. VIOLATIONS (NYC Open Data: wvxf-dwi5) — 41 Raw Columns
-- =============================================================================
DROP VIEW IF EXISTS bronze.v_violations_load;
DROP TABLE IF EXISTS bronze.stg_violations;

CREATE TABLE bronze.stg_violations (
    raw_row_num           BIGINT         NULL,
    violationid           NVARCHAR(255)  NULL,
    buildingid            NVARCHAR(255)  NULL,
    registrationid        NVARCHAR(255)  NULL,
    boroid                NVARCHAR(255)  NULL,
    boro                  NVARCHAR(255)  NULL,
    housenumber           NVARCHAR(255)  NULL,
    lowhousenumber        NVARCHAR(255)  NULL,
    highhousenumber       NVARCHAR(255)  NULL,
    streetname            NVARCHAR(500)  NULL,
    streetcode            NVARCHAR(255)  NULL,
    zip                   NVARCHAR(255)  NULL,
    apartment             NVARCHAR(255)  NULL,
    story                 NVARCHAR(255)  NULL,
    block                 NVARCHAR(255)  NULL,
    lot                   NVARCHAR(255)  NULL,
    class                 NVARCHAR(255)  NULL,
    inspectiondate        NVARCHAR(255)  NULL,
    approveddate          NVARCHAR(255)  NULL,
    originalcertifybydate NVARCHAR(255)  NULL,
    originalcorrectbydate NVARCHAR(255)  NULL,
    newcertifybydate      NVARCHAR(255)  NULL,
    newcorrectbydate      NVARCHAR(255)  NULL,
    certifieddate         NVARCHAR(255)  NULL,
    ordernumber           NVARCHAR(255)  NULL,
    novid                 NVARCHAR(255)  NULL,
    novdescription        NVARCHAR(MAX)  NULL,
    novissueddate         NVARCHAR(255)  NULL,
    currentstatusid       NVARCHAR(255)  NULL,
    currentstatus         NVARCHAR(500)  NULL,
    currentstatusdate     NVARCHAR(255)  NULL,
    novtype               NVARCHAR(255)  NULL,
    violationstatus       NVARCHAR(255)  NULL,
    rentimpairing         NVARCHAR(255)  NULL,
    latitude              NVARCHAR(255)  NULL,
    longitude             NVARCHAR(255)  NULL,
    communityboard        NVARCHAR(255)  NULL,
    councildistrict       NVARCHAR(255)  NULL,
    censustract           NVARCHAR(255)  NULL,
    bin                   NVARCHAR(255)  NULL,
    bbl                   NVARCHAR(255)  NULL,
    nta                   NVARCHAR(500)  NULL
);
GO

IF OBJECT_ID(N'bronze.violations', N'U') IS NULL
BEGIN
    CREATE TABLE bronze.violations (
        bronze_row_id         BIGINT IDENTITY(1,1) NOT NULL PRIMARY KEY,
        raw_row_num           BIGINT               NOT NULL,
        violationid           NVARCHAR(255)        NULL,
        buildingid            NVARCHAR(255)        NULL,
        registrationid        NVARCHAR(255)        NULL,
        boroid                NVARCHAR(255)        NULL,
        boro                  NVARCHAR(255)        NULL,
        housenumber           NVARCHAR(255)        NULL,
        lowhousenumber        NVARCHAR(255)        NULL,
        highhousenumber       NVARCHAR(255)        NULL,
        streetname            NVARCHAR(500)        NULL,
        streetcode            NVARCHAR(255)        NULL,
        zip                   NVARCHAR(255)        NULL,
        apartment             NVARCHAR(255)        NULL,
        story                 NVARCHAR(255)        NULL,
        block                 NVARCHAR(255)        NULL,
        lot                   NVARCHAR(255)        NULL,
        class                 NVARCHAR(255)        NULL,
        inspectiondate        NVARCHAR(255)        NULL,
        approveddate          NVARCHAR(255)        NULL,
        originalcertifybydate NVARCHAR(255)        NULL,
        originalcorrectbydate NVARCHAR(255)        NULL,
        newcertifybydate      NVARCHAR(255)        NULL,
        newcorrectbydate      NVARCHAR(255)        NULL,
        certifieddate         NVARCHAR(255)        NULL,
        ordernumber           NVARCHAR(255)        NULL,
        novid                 NVARCHAR(255)        NULL,
        novdescription        NVARCHAR(MAX)        NULL,
        novissueddate         NVARCHAR(255)        NULL,
        currentstatusid       NVARCHAR(255)        NULL,
        currentstatus         NVARCHAR(500)        NULL,
        currentstatusdate     NVARCHAR(255)        NULL,
        novtype               NVARCHAR(255)        NULL,
        violationstatus       NVARCHAR(255)        NULL,
        rentimpairing         NVARCHAR(255)        NULL,
        latitude              NVARCHAR(255)        NULL,
        longitude             NVARCHAR(255)        NULL,
        communityboard        NVARCHAR(255)        NULL,
        councildistrict       NVARCHAR(255)        NULL,
        censustract           NVARCHAR(255)        NULL,
        bin                   NVARCHAR(255)        NULL,
        bbl                   NVARCHAR(255)        NULL,
        nta                   NVARCHAR(500)        NULL,
        source_dataset_id     VARCHAR(50)          NOT NULL DEFAULT 'wvxf-dwi5',
        source_file           NVARCHAR(500)        NOT NULL,
        batch_id              UNIQUEIDENTIFIER     NOT NULL,
        ingested_at           DATETIME2            NOT NULL DEFAULT SYSDATETIME()
    );
END;
GO

CREATE OR ALTER VIEW bronze.v_violations_load AS
SELECT
    violationid, buildingid, registrationid, boroid, boro,
    housenumber, lowhousenumber, highhousenumber, streetname,
    streetcode, zip, apartment, story, block, lot, class,
    inspectiondate, approveddate, originalcertifybydate,
    originalcorrectbydate, newcertifybydate, newcorrectbydate,
    certifieddate, ordernumber, novid, novdescription,
    novissueddate, currentstatusid, currentstatus,
    currentstatusdate, novtype, violationstatus, rentimpairing,
    latitude, longitude, communityboard, councildistrict,
    censustract, bin, bbl, nta
FROM bronze.stg_violations;
GO

CREATE OR ALTER PROCEDURE bronze.load_violations
    @file_path  NVARCHAR(500),
    @batch_id   UNIQUEIDENTIFIER = NULL,
    @use_staged BIT = 0
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @batch      UNIQUEIDENTIFIER = ISNULL(@batch_id, NEWID()),
            @start      DATETIME2        = SYSDATETIME(),
            @staged_cnt BIGINT           = 0,
            @rows       BIGINT           = 0,
            @sql        NVARCHAR(MAX);

    BEGIN TRY
        IF @use_staged = 0
        BEGIN
            TRUNCATE TABLE bronze.stg_violations;
            SET @sql = N'BULK INSERT bronze.v_violations_load FROM '''
                     + REPLACE(@file_path, N'''', N'''''')
                     + N''' WITH (FIRSTROW = 2, FORMAT = ''CSV'', FIELDQUOTE = ''"'', FIELDTERMINATOR = '','', CODEPAGE = ''65001'', TABLOCK);';
            EXEC sp_executesql @sql;
        END;

        SELECT @staged_cnt = COUNT_BIG(*) FROM bronze.stg_violations;
        IF @staged_cnt = 0
            THROW 50003, 'Staging table bronze.stg_violations is empty; aborting load to preserve existing bronze.violations data.', 1;

        BEGIN TRAN;
            TRUNCATE TABLE bronze.violations;

            INSERT INTO bronze.violations (
                raw_row_num,
                violationid, buildingid, registrationid, boroid, boro,
                housenumber, lowhousenumber, highhousenumber, streetname,
                streetcode, zip, apartment, story, block, lot, class,
                inspectiondate, approveddate, originalcertifybydate,
                originalcorrectbydate, newcertifybydate, newcorrectbydate,
                certifieddate, ordernumber, novid, novdescription,
                novissueddate, currentstatusid, currentstatus,
                currentstatusdate, novtype, violationstatus, rentimpairing,
                latitude, longitude, communityboard, councildistrict,
                censustract, bin, bbl, nta,
                source_dataset_id, source_file, batch_id, ingested_at
            )
            SELECT
                ISNULL(raw_row_num, ROW_NUMBER() OVER (ORDER BY (SELECT NULL))),
                violationid, buildingid, registrationid, boroid, boro,
                housenumber, lowhousenumber, highhousenumber, streetname,
                streetcode, zip, apartment, story, block, lot, class,
                inspectiondate, approveddate, originalcertifybydate,
                originalcorrectbydate, newcertifybydate, newcorrectbydate,
                certifieddate, ordernumber, novid, novdescription,
                novissueddate, currentstatusid, currentstatus,
                currentstatusdate, novtype, violationstatus, rentimpairing,
                latitude, longitude, communityboard, councildistrict,
                censustract, bin, bbl, nta,
                'wvxf-dwi5', @file_path, @batch, @start
            FROM bronze.stg_violations
            ORDER BY ISNULL(raw_row_num, 0);

            SELECT @rows = COUNT_BIG(*) FROM bronze.violations;
        COMMIT TRAN;

        TRUNCATE TABLE bronze.stg_violations;

        INSERT INTO audit.load_log (batch_id, source_name, target_table, start_time, end_time, rows_loaded, status, message)
        VALUES (@batch, 'wvxf-dwi5:violations', 'bronze.violations', @start, SYSDATETIME(), @rows, 'SUCCESS', 'Bronze violations loaded via safe staging swap');
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRAN;
        INSERT INTO audit.load_log (batch_id, source_name, target_table, start_time, end_time, rows_loaded, status, message)
        VALUES (@batch, 'wvxf-dwi5:violations', 'bronze.violations', @start, SYSDATETIME(), NULL, 'FAILED', ERROR_MESSAGE());
        THROW;
    END CATCH
END;
GO

-- =============================================================================
-- 4. OPEN MARKET ORDER (OMO) CHARGES (NYC Open Data: mdbu-nrqn) — 32 Raw Columns
-- =============================================================================
DROP VIEW IF EXISTS bronze.v_omo_charges_load;
DROP TABLE IF EXISTS bronze.stg_omo_charges;

CREATE TABLE bronze.stg_omo_charges (
    raw_row_num            BIGINT         NULL,
    omoid                  NVARCHAR(255)  NULL,
    omonumber              NVARCHAR(255)  NULL,
    buildingid             NVARCHAR(255)  NULL,
    boro_id                NVARCHAR(255)  NULL,
    boro                   NVARCHAR(255)  NULL,
    housenumber            NVARCHAR(255)  NULL,
    streetname             NVARCHAR(500)  NULL,
    apartment              NVARCHAR(255)  NULL,
    zip                    NVARCHAR(255)  NULL,
    block                  NVARCHAR(255)  NULL,
    lot                    NVARCHAR(255)  NULL,
    lifecycle              NVARCHAR(255)  NULL,
    worktypegeneral        NVARCHAR(255)  NULL,
    omostatusreason        NVARCHAR(500)  NULL,
    omoawardamount         NVARCHAR(255)  NULL,
    omocreatedate          NVARCHAR(255)  NULL,
    netchangeorders        NVARCHAR(255)  NULL,
    omoawarddate           NVARCHAR(255)  NULL,
    isaep                  NVARCHAR(255)  NULL,
    iscommercialdemolition NVARCHAR(255)  NULL,
    servicechargeflag      NVARCHAR(255)  NULL,
    femaeventid            NVARCHAR(255)  NULL,
    femaevent              NVARCHAR(500)  NULL,
    omodescription         NVARCHAR(MAX)  NULL,
    latitude               NVARCHAR(255)  NULL,
    longitude              NVARCHAR(255)  NULL,
    community_board        NVARCHAR(255)  NULL,
    council_district       NVARCHAR(255)  NULL,
    census_tract           NVARCHAR(255)  NULL,
    bin                    NVARCHAR(255)  NULL,
    bbl                    NVARCHAR(255)  NULL,
    nta                    NVARCHAR(500)  NULL
);
GO

IF OBJECT_ID(N'bronze.omo_charges', N'U') IS NULL
BEGIN
    CREATE TABLE bronze.omo_charges (
        bronze_row_id          BIGINT IDENTITY(1,1) NOT NULL PRIMARY KEY,
        raw_row_num            BIGINT               NOT NULL,
        omoid                  NVARCHAR(255)        NULL,
        omonumber              NVARCHAR(255)        NULL,
        buildingid             NVARCHAR(255)        NULL,
        boro_id                NVARCHAR(255)        NULL,
        boro                   NVARCHAR(255)        NULL,
        housenumber            NVARCHAR(255)        NULL,
        streetname             NVARCHAR(500)        NULL,
        apartment              NVARCHAR(255)        NULL,
        zip                    NVARCHAR(255)        NULL,
        block                  NVARCHAR(255)        NULL,
        lot                    NVARCHAR(255)        NULL,
        lifecycle              NVARCHAR(255)        NULL,
        worktypegeneral        NVARCHAR(255)        NULL,
        omostatusreason        NVARCHAR(500)        NULL,
        omoawardamount         NVARCHAR(255)        NULL,
        omocreatedate          NVARCHAR(255)        NULL,
        netchangeorders        NVARCHAR(255)        NULL,
        omoawarddate           NVARCHAR(255)        NULL,
        isaep                  NVARCHAR(255)        NULL,
        iscommercialdemolition NVARCHAR(255)        NULL,
        servicechargeflag      NVARCHAR(255)        NULL,
        femaeventid            NVARCHAR(255)        NULL,
        femaevent              NVARCHAR(500)        NULL,
        omodescription         NVARCHAR(MAX)        NULL,
        latitude               NVARCHAR(255)        NULL,
        longitude              NVARCHAR(255)        NULL,
        community_board        NVARCHAR(255)        NULL,
        council_district       NVARCHAR(255)        NULL,
        census_tract           NVARCHAR(255)        NULL,
        bin                    NVARCHAR(255)        NULL,
        bbl                    NVARCHAR(255)        NULL,
        nta                    NVARCHAR(500)        NULL,
        source_dataset_id      VARCHAR(50)          NOT NULL DEFAULT 'mdbu-nrqn',
        source_file            NVARCHAR(500)        NOT NULL,
        batch_id               UNIQUEIDENTIFIER     NOT NULL,
        ingested_at            DATETIME2            NOT NULL DEFAULT SYSDATETIME()
    );
END;
GO

CREATE OR ALTER VIEW bronze.v_omo_charges_load AS
SELECT
    omoid, omonumber, buildingid, boro_id, boro,
    housenumber, streetname, apartment, zip, block, lot,
    lifecycle, worktypegeneral, omostatusreason,
    omoawardamount, omocreatedate, netchangeorders,
    omoawarddate, isaep, iscommercialdemolition,
    servicechargeflag, femaeventid, femaevent, omodescription,
    latitude, longitude, community_board, council_district,
    census_tract, bin, bbl, nta
FROM bronze.stg_omo_charges;
GO

CREATE OR ALTER PROCEDURE bronze.load_omo_charges
    @file_path  NVARCHAR(500),
    @batch_id   UNIQUEIDENTIFIER = NULL,
    @use_staged BIT = 0
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @batch      UNIQUEIDENTIFIER = ISNULL(@batch_id, NEWID()),
            @start      DATETIME2        = SYSDATETIME(),
            @staged_cnt BIGINT           = 0,
            @rows       BIGINT           = 0,
            @sql        NVARCHAR(MAX);

    BEGIN TRY
        IF @use_staged = 0
        BEGIN
            TRUNCATE TABLE bronze.stg_omo_charges;
            SET @sql = N'BULK INSERT bronze.v_omo_charges_load FROM '''
                     + REPLACE(@file_path, N'''', N'''''')
                     + N''' WITH (FIRSTROW = 2, FORMAT = ''CSV'', FIELDQUOTE = ''"'', FIELDTERMINATOR = '','', CODEPAGE = ''65001'', TABLOCK);';
            EXEC sp_executesql @sql;
        END;

        SELECT @staged_cnt = COUNT_BIG(*) FROM bronze.stg_omo_charges;
        IF @staged_cnt = 0
            THROW 50004, 'Staging table bronze.stg_omo_charges is empty; aborting load to preserve existing bronze.omo_charges data.', 1;

        BEGIN TRAN;
            TRUNCATE TABLE bronze.omo_charges;

            INSERT INTO bronze.omo_charges (
                raw_row_num,
                omoid, omonumber, buildingid, boro_id, boro,
                housenumber, streetname, apartment, zip, block, lot,
                lifecycle, worktypegeneral, omostatusreason,
                omoawardamount, omocreatedate, netchangeorders,
                omoawarddate, isaep, iscommercialdemolition,
                servicechargeflag, femaeventid, femaevent, omodescription,
                latitude, longitude, community_board, council_district,
                census_tract, bin, bbl, nta,
                source_dataset_id, source_file, batch_id, ingested_at
            )
            SELECT
                ISNULL(raw_row_num, ROW_NUMBER() OVER (ORDER BY (SELECT NULL))),
                omoid, omonumber, buildingid, boro_id, boro,
                housenumber, streetname, apartment, zip, block, lot,
                lifecycle, worktypegeneral, omostatusreason,
                omoawardamount, omocreatedate, netchangeorders,
                omoawarddate, isaep, iscommercialdemolition,
                servicechargeflag, femaeventid, femaevent, omodescription,
                latitude, longitude, community_board, council_district,
                census_tract, bin, bbl, nta,
                'mdbu-nrqn', @file_path, @batch, @start
            FROM bronze.stg_omo_charges
            ORDER BY ISNULL(raw_row_num, 0);

            SELECT @rows = COUNT_BIG(*) FROM bronze.omo_charges;
        COMMIT TRAN;

        TRUNCATE TABLE bronze.stg_omo_charges;

        INSERT INTO audit.load_log (batch_id, source_name, target_table, start_time, end_time, rows_loaded, status, message)
        VALUES (@batch, 'mdbu-nrqn:omo_charges', 'bronze.omo_charges', @start, SYSDATETIME(), @rows, 'SUCCESS', 'Bronze omo_charges loaded via safe staging swap');
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRAN;
        INSERT INTO audit.load_log (batch_id, source_name, target_table, start_time, end_time, rows_loaded, status, message)
        VALUES (@batch, 'mdbu-nrqn:omo_charges', 'bronze.omo_charges', @start, SYSDATETIME(), NULL, 'FAILED', ERROR_MESSAGE());
        THROW;
    END CATCH
END;
GO
