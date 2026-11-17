/* ============================================================================
   File: sql/03_gold.sql
   Project: HomeRescue AI (Medallion Data Warehouse)
   Layer: Gold (Persistent Star Schema Dimensions, Grain-Explicit Atomic Facts,
          and Grain-Aligned Building-Month Analytical Mart)
   Description:
     Creates persistent dimension tables with stable surrogate keys
     (gold.dim_building, gold.dim_date), atomic fact tables with explicit
     grains (gold.fact_complaint_problem, gold.fact_violation,
     gold.fact_repair_order), and a pre-aggregated building-month summary
     mart (gold.mart_building_month) that prevents many-to-many fan-out joins.
   ============================================================================ */

IF DB_NAME() IN (N'master', N'tempdb', N'model', N'msdb')
    USE [homerescue_dw];
GO

SET NOCOUNT ON;
GO

/* ============================================================================
   1. PERSISTENT DIMENSION: gold.dim_building
      GRAIN: One row per unique normalized building_id (plus building_key = -1
             for unregistered/unmatched building references).
      SURROGATE KEY STABILITY POLICY:
        - building_key is an IDENTITY(1,1) primary key.
        - building_key = -1 is reserved for 'UNKNOWN / UNREGISTERED BUILDING'.
        - Rerunning gold.load_dim_building updates existing rows in place and
          inserts only new building_id values, guaranteeing that existing
          building_id -> building_key mappings never change across reruns.
   ============================================================================ */
IF OBJECT_ID('gold.dim_building', 'U') IS NULL
BEGIN
    CREATE TABLE gold.dim_building (
        building_key            INT             IDENTITY(1,1) NOT NULL,
        building_id             INT             NOT NULL,
        boro_id                 INT             NOT NULL,
        borough_name            VARCHAR(50)     NOT NULL,
        house_number            VARCHAR(100)    NULL,
        low_house_number        VARCHAR(100)    NULL,
        high_house_number       VARCHAR(100)    NULL,
        street_name             VARCHAR(250)    NOT NULL,
        full_street_address     VARCHAR(360)    NOT NULL,
        zip_code                VARCHAR(20)     NOT NULL,
        tax_block               INT             NOT NULL,
        tax_lot                 INT             NOT NULL,
        bin                     VARCHAR(50)     NULL,
        community_board         INT             NULL,
        census_tract            VARCHAR(50)     NULL,
        management_program      VARCHAR(100)    NOT NULL,
        dob_building_class_id   INT             NULL,
        dob_building_class      VARCHAR(150)    NOT NULL,
        legal_stories           INT             NULL,
        legal_class_a_units     INT             NULL,
        legal_class_b_units     INT             NULL,
        total_legal_units       INT             NULL,
        unit_size_tier          VARCHAR(30)     NOT NULL,
        registration_id         INT             NULL,
        lifecycle               VARCHAR(100)    NOT NULL,
        record_status_id        INT             NULL,
        record_status           VARCHAR(100)    NOT NULL,
        is_active_building      BIT             NOT NULL,
        is_registered_building  BIT             NOT NULL,
        DW_create_date          DATETIME2(3)    NOT NULL CONSTRAINT DF_gold_dim_building_create DEFAULT SYSDATETIME(),
        DW_modify_date          DATETIME2(3)    NOT NULL CONSTRAINT DF_gold_dim_building_modify DEFAULT SYSDATETIME(),
        CONSTRAINT PK_gold_dim_building PRIMARY KEY CLUSTERED (building_key),
        CONSTRAINT UQ_gold_dim_building_id UNIQUE (building_id)
    );

    CREATE NONCLUSTERED INDEX IX_gold_dim_building_zip
        ON gold.dim_building (zip_code, community_board, unit_size_tier);
END;
GO

/* ============================================================================
   2. PERSISTENT DIMENSION: gold.dim_date
      GRAIN: One row per calendar date (date_key = YYYYMMDD, plus -1 for
             missing/unknown optional dates).
   ============================================================================ */
IF OBJECT_ID('gold.dim_date', 'U') IS NULL
BEGIN
    CREATE TABLE gold.dim_date (
        date_key                INT             NOT NULL,
        full_date               DATE            NOT NULL,
        year_number             SMALLINT        NOT NULL,
        quarter_number          TINYINT         NOT NULL,
        quarter_label           CHAR(2)         NOT NULL,
        month_number            TINYINT         NOT NULL,
        month_name              VARCHAR(15)     NOT NULL,
        year_month              CHAR(7)         NOT NULL,
        day_of_month            TINYINT         NOT NULL,
        day_of_week_number      TINYINT         NOT NULL,
        day_of_week_name        VARCHAR(15)     NOT NULL,
        is_weekend              BIT             NOT NULL,
        is_study_window         BIT             NOT NULL,
        DW_create_date          DATETIME2(3)    NOT NULL CONSTRAINT DF_gold_dim_date_create DEFAULT SYSDATETIME(),
        CONSTRAINT PK_gold_dim_date PRIMARY KEY CLUSTERED (date_key),
        CONSTRAINT UQ_gold_dim_date_full_date UNIQUE (full_date)
    );

    CREATE NONCLUSTERED INDEX IX_gold_dim_date_year_month
        ON gold.dim_date (year_month, year_number, month_number);
END;
GO

/* ============================================================================
   3. ATOMIC FACT TABLE: gold.fact_complaint_problem
      GRAIN: One row per HPD complaint problem (problem_id).
      DOMAIN RULE: problem_id is the atomic grain; complaint_id is the parent
      complaint identifier and can cover multiple problem_id rows.
   ============================================================================ */
IF OBJECT_ID('gold.fact_complaint_problem', 'U') IS NULL
BEGIN
    CREATE TABLE gold.fact_complaint_problem (
        problem_id                  BIGINT           NOT NULL,
        complaint_id                BIGINT           NOT NULL,
        building_key                INT              NOT NULL,
        building_id                 INT              NOT NULL,
        received_date_key           INT              NOT NULL,
        status_date_key             INT              NOT NULL,
        received_date               DATE             NOT NULL,
        year_month                  CHAR(7)          NOT NULL,
        unit_type                   VARCHAR(100)     NULL,
        space_type                  VARCHAR(100)     NULL,
        urgency_type                VARCHAR(100)     NOT NULL,
        is_emergency_priority       BIT              NOT NULL,
        major_category              VARCHAR(200)     NULL,
        minor_category              VARCHAR(200)     NULL,
        problem_code                VARCHAR(200)     NULL,
        complaint_status            VARCHAR(50)      NULL,
        problem_status              VARCHAR(50)      NULL,
        is_duplicate_problem_flag   BIT              NOT NULL,
        is_registered_building      BIT              NOT NULL,
        bronze_row_id               BIGINT           NOT NULL,
        source_batch_id             UNIQUEIDENTIFIER NOT NULL,
        DW_create_date              DATETIME2(3)     NOT NULL CONSTRAINT DF_gold_fact_cp_create DEFAULT SYSDATETIME(),
        CONSTRAINT PK_gold_fact_complaint_problem PRIMARY KEY CLUSTERED (problem_id),
        CONSTRAINT FK_gold_fact_cp_building FOREIGN KEY (building_key) REFERENCES gold.dim_building (building_key),
        CONSTRAINT FK_gold_fact_cp_rec_date FOREIGN KEY (received_date_key) REFERENCES gold.dim_date (date_key),
        CONSTRAINT FK_gold_fact_cp_stat_date FOREIGN KEY (status_date_key) REFERENCES gold.dim_date (date_key)
    );

    CREATE NONCLUSTERED INDEX IX_gold_fact_cp_building_month
        ON gold.fact_complaint_problem (building_id, year_month)
        INCLUDE (complaint_id, urgency_type, is_emergency_priority, is_duplicate_problem_flag);

    CREATE NONCLUSTERED INDEX IX_gold_fact_cp_building_key
        ON gold.fact_complaint_problem (building_key, received_date_key);
END;
GO

/* ============================================================================
   4. ATOMIC FACT TABLE: gold.fact_violation
      GRAIN: One row per HPD housing maintenance code violation (violation_id).
      DOMAIN RULE: Violation classes are A (non-hazardous, rank 1),
      B (hazardous, rank 2), C (immediately hazardous, rank 3), and
      I (informational/administrative order, rank 0 - never ranked above C).
   ============================================================================ */
IF OBJECT_ID('gold.fact_violation', 'U') IS NULL
BEGIN
    CREATE TABLE gold.fact_violation (
        violation_id                    BIGINT           NOT NULL,
        building_key                    INT              NOT NULL,
        building_id                     INT              NOT NULL,
        inspection_date_key             INT              NOT NULL,
        nov_issued_date_key             INT              NOT NULL,
        current_status_date_key         INT              NOT NULL,
        inspection_date                 DATE             NOT NULL,
        year_month                      CHAR(7)          NOT NULL,
        violation_class                 CHAR(1)          NOT NULL,
        hazard_class_category           VARCHAR(60)      NOT NULL,
        is_substantive_abc_violation    BIT              NOT NULL,
        is_b_or_c_hazardous_violation   BIT              NOT NULL,
        is_immediately_hazardous        BIT              NOT NULL,
        hazard_severity_rank            INT              NOT NULL,
        is_open_violation               BIT              NOT NULL,
        is_rent_impairing               BIT              NOT NULL,
        violation_status                VARCHAR(30)      NOT NULL,
        current_status                  VARCHAR(150)     NULL,
        nov_type                        VARCHAR(50)      NULL,
        is_registered_building          BIT              NOT NULL,
        bronze_row_id                   BIGINT           NOT NULL,
        source_batch_id                 UNIQUEIDENTIFIER NOT NULL,
        DW_create_date                  DATETIME2(3)     NOT NULL CONSTRAINT DF_gold_fact_viol_create DEFAULT SYSDATETIME(),
        CONSTRAINT PK_gold_fact_violation PRIMARY KEY CLUSTERED (violation_id),
        CONSTRAINT FK_gold_fact_viol_building FOREIGN KEY (building_key) REFERENCES gold.dim_building (building_key),
        CONSTRAINT FK_gold_fact_viol_insp_date FOREIGN KEY (inspection_date_key) REFERENCES gold.dim_date (date_key),
        CONSTRAINT FK_gold_fact_viol_nov_date FOREIGN KEY (nov_issued_date_key) REFERENCES gold.dim_date (date_key),
        CONSTRAINT FK_gold_fact_viol_stat_date FOREIGN KEY (current_status_date_key) REFERENCES gold.dim_date (date_key)
    );

    CREATE NONCLUSTERED INDEX IX_gold_fact_viol_building_month
        ON gold.fact_violation (building_id, year_month)
        INCLUDE (violation_class, is_substantive_abc_violation, is_b_or_c_hazardous_violation, is_immediately_hazardous, is_open_violation, is_rent_impairing, hazard_severity_rank);

    CREATE NONCLUSTERED INDEX IX_gold_fact_viol_building_key
        ON gold.fact_violation (building_key, inspection_date_key);
END;
GO

/* ============================================================================
   5. ATOMIC FACT TABLE: gold.fact_repair_order
      GRAIN: One row per HPD Open Market Order charge (omo_id / omo_number).
      DOMAIN RULES:
        - omo_award_amount represents awarded contract/order amount, NOT paid
          disbursement and NOT preventive cost savings.
        - is_eligible_repair_cohort = 1 filters out commercial/structural
          demolitions, administrative duplicate OMOs, and un-awarded/cancelled
          orders ($0 with NULL omo_award_date).
   ============================================================================ */
IF OBJECT_ID('gold.fact_repair_order', 'U') IS NULL
BEGIN
    CREATE TABLE gold.fact_repair_order (
        omo_id                      BIGINT           NOT NULL,
        omo_number                  VARCHAR(50)      NOT NULL,
        building_key                INT              NOT NULL,
        building_id                 INT              NOT NULL,
        omo_create_date_key         INT              NOT NULL,
        omo_award_date_key          INT              NOT NULL,
        omo_create_date             DATE             NOT NULL,
        omo_award_date              DATE             NULL,
        year_month                  CHAR(7)          NOT NULL,
        lifecycle                   VARCHAR(50)      NULL,
        work_type_general           VARCHAR(50)      NULL,
        omo_status_reason           VARCHAR(200)     NULL,
        service_charge_flag         VARCHAR(20)      NULL,
        has_service_charge          BIT              NOT NULL,
        is_commercial_demolition    VARCHAR(50)      NULL,
        is_eligible_repair_cohort   BIT              NOT NULL,
        repair_cohort_category      VARCHAR(100)     NOT NULL,
        financial_value_status      VARCHAR(50)      NOT NULL,
        omo_award_amount            DECIMAL(18,2)    NOT NULL,
        eligible_omo_award_amount   DECIMAL(18,2)    NULL,
        net_change_orders           DECIMAL(18,2)    NULL,
        is_registered_building      BIT              NOT NULL,
        bronze_row_id               BIGINT           NOT NULL,
        source_batch_id             UNIQUEIDENTIFIER NOT NULL,
        DW_create_date              DATETIME2(3)     NOT NULL CONSTRAINT DF_gold_fact_ro_create DEFAULT SYSDATETIME(),
        CONSTRAINT PK_gold_fact_repair_order PRIMARY KEY CLUSTERED (omo_id),
        CONSTRAINT UQ_gold_fact_repair_order_number UNIQUE (omo_number),
        CONSTRAINT FK_gold_fact_ro_building FOREIGN KEY (building_key) REFERENCES gold.dim_building (building_key),
        CONSTRAINT FK_gold_fact_ro_create_date FOREIGN KEY (omo_create_date_key) REFERENCES gold.dim_date (date_key),
        CONSTRAINT FK_gold_fact_ro_award_date FOREIGN KEY (omo_award_date_key) REFERENCES gold.dim_date (date_key)
    );

    CREATE NONCLUSTERED INDEX IX_gold_fact_ro_building_month
        ON gold.fact_repair_order (building_id, year_month)
        INCLUDE (is_eligible_repair_cohort, omo_award_amount, eligible_omo_award_amount, financial_value_status);

    CREATE NONCLUSTERED INDEX IX_gold_fact_ro_building_key
        ON gold.fact_repair_order (building_key, omo_create_date_key);
END;
GO

/* ============================================================================
   6. GRAIN-ALIGNED ANALYTICAL MART: gold.mart_building_month
      GRAIN: One row per active (building_id, year_month) across 2024.
      FAN-OUT PREVENTION POLICY:
        - Each atomic fact table (fact_complaint_problem, fact_violation,
          fact_repair_order) is aggregated independently to (building_id,
          year_month) before joining to the (building_id, year_month) spine.
        - Primary key includes natural building_id so the 4 unmatched buildings
          sharing building_key = -1 never collapse into a single row.
        - Preserves both raw nullable financial sums (NULL when a building-month
          has no repair orders, vs. 0.00 when only zero-dollar orders exist)
          and zero-coalesced financial totals for additive rollups.
   ============================================================================ */
IF OBJECT_ID('gold.mart_building_month', 'U') IS NULL
BEGIN
    CREATE TABLE gold.mart_building_month (
        building_id                         INT             NOT NULL,
        year_month                          CHAR(7)         NOT NULL,
        building_key                        INT             NOT NULL,
        month_start_date_key                INT             NOT NULL,
        is_registered_building              BIT             NOT NULL,
        -- Complaint & Problem metrics
        complaint_count                     INT             NOT NULL,
        problem_count                       INT             NOT NULL,
        emergency_problem_count             INT             NOT NULL,
        non_emergency_problem_count         INT             NOT NULL,
        duplicate_problem_count             INT             NOT NULL,
        -- Violation metrics
        violation_count                     INT             NOT NULL,
        class_a_violation_count             INT             NOT NULL,
        class_b_violation_count             INT             NOT NULL,
        class_c_violation_count             INT             NOT NULL,
        class_i_violation_count             INT             NOT NULL,
        substantive_abc_violation_count     INT             NOT NULL,
        hazardous_bc_violation_count        INT             NOT NULL,
        open_violation_count                INT             NOT NULL,
        rent_impairing_violation_count      INT             NOT NULL,
        violation_severity_weighted_score   INT             NOT NULL,
        -- OMO Repair Order metrics
        has_omo_orders                      BIT             NOT NULL,
        has_eligible_repair_orders          BIT             NOT NULL,
        omo_order_count                     INT             NOT NULL,
        eligible_repair_order_count         INT             NOT NULL,
        excluded_omo_order_count            INT             NOT NULL,
        zero_dollar_omo_order_count         INT             NOT NULL,
        raw_total_omo_award_amount          DECIMAL(18,2)   NULL,
        raw_eligible_omo_award_amount       DECIMAL(18,2)   NULL,
        total_omo_award_amount              DECIMAL(18,2)   NOT NULL,
        eligible_omo_award_amount           DECIMAL(18,2)   NOT NULL,
        excluded_omo_award_amount           DECIMAL(18,2)   NOT NULL,
        DW_create_date                      DATETIME2(3)    NOT NULL CONSTRAINT DF_gold_mart_bm_create DEFAULT SYSDATETIME(),
        CONSTRAINT PK_gold_mart_building_month PRIMARY KEY CLUSTERED (building_id, year_month),
        CONSTRAINT FK_gold_mart_bm_building FOREIGN KEY (building_key) REFERENCES gold.dim_building (building_key),
        CONSTRAINT FK_gold_mart_bm_date FOREIGN KEY (month_start_date_key) REFERENCES gold.dim_date (date_key)
    );

    CREATE NONCLUSTERED INDEX IX_gold_mart_bm_building_key
        ON gold.mart_building_month (building_key, year_month);

    CREATE NONCLUSTERED INDEX IX_gold_mart_bm_year_month
        ON gold.mart_building_month (year_month)
        INCLUDE (complaint_count, problem_count, violation_count, hazardous_bc_violation_count, eligible_repair_order_count, eligible_omo_award_amount);
END;
GO

/* ============================================================================
   7. PROCEDURE: gold.load_dim_building
      Preserves existing surrogate keys (building_key) across reruns.
   ============================================================================ */
CREATE OR ALTER PROCEDURE gold.load_dim_building
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @batch       UNIQUEIDENTIFIER = NEWID(),
            @start       DATETIME2        = SYSDATETIME(),
            @rows_loaded BIGINT           = 0;

    BEGIN TRY
        BEGIN TRAN;

        -- 1. Ensure the explicit Unknown / Unregistered Building member (building_key = -1) exists
        IF NOT EXISTS (SELECT 1 FROM gold.dim_building WHERE building_key = -1)
        BEGIN
            SET IDENTITY_INSERT gold.dim_building ON;

            INSERT INTO gold.dim_building (
                building_key, building_id, boro_id, borough_name,
                house_number, low_house_number, high_house_number,
                street_name, full_street_address, zip_code,
                tax_block, tax_lot, bin, community_board, census_tract,
                management_program, dob_building_class_id, dob_building_class,
                legal_stories, legal_class_a_units, legal_class_b_units,
                total_legal_units, unit_size_tier, registration_id,
                lifecycle, record_status_id, record_status,
                is_active_building, is_registered_building
            )
            VALUES (
                -1, -1, 5, 'STATEN ISLAND',
                NULL, NULL, NULL,
                'UNKNOWN / UNREGISTERED BUILDING', 'UNKNOWN / UNREGISTERED BUILDING', 'UNKNOWN',
                -1, -1, 'UNKNOWN', NULL, NULL,
                'UNKNOWN', NULL, 'UNKNOWN',
                NULL, NULL, NULL,
                NULL, 'UNKNOWN / 0 UNITS', NULL,
                'UNREGISTERED', NULL, 'UNREGISTERED_IN_HPD_BUILDINGS',
                0, 0
            );

            SET IDENTITY_INSERT gold.dim_building OFF;
        END;

        -- 2. Update attributes on existing registered buildings without altering building_key
        UPDATE d
        SET d.boro_id                 = s.boro_id,
            d.borough_name            = s.borough_name,
            d.house_number            = s.house_number,
            d.low_house_number        = s.low_house_number,
            d.high_house_number       = s.high_house_number,
            d.street_name             = s.street_name,
            d.full_street_address     = LTRIM(RTRIM(CONCAT(ISNULL(s.house_number, ''), ' ', s.street_name))),
            d.zip_code                = ISNULL(s.zip_code, 'UNKNOWN'),
            d.tax_block               = s.tax_block,
            d.tax_lot                 = s.tax_lot,
            d.bin                     = s.bin,
            d.community_board         = s.community_board,
            d.census_tract            = s.census_tract,
            d.management_program      = ISNULL(s.management_program, 'UNKNOWN'),
            d.dob_building_class_id   = s.dob_building_class_id,
            d.dob_building_class      = ISNULL(s.dob_building_class, 'UNKNOWN'),
            d.legal_stories           = s.legal_stories,
            d.legal_class_a_units     = s.legal_class_a_units,
            d.legal_class_b_units     = s.legal_class_b_units,
            d.total_legal_units       = CASE
                                            WHEN s.legal_class_a_units IS NULL AND s.legal_class_b_units IS NULL THEN NULL
                                            ELSE ISNULL(s.legal_class_a_units, 0) + ISNULL(s.legal_class_b_units, 0)
                                        END,
            d.unit_size_tier          = CASE
                                            WHEN (ISNULL(s.legal_class_a_units, 0) + ISNULL(s.legal_class_b_units, 0)) <= 0 THEN 'UNKNOWN / 0 UNITS'
                                            WHEN (ISNULL(s.legal_class_a_units, 0) + ISNULL(s.legal_class_b_units, 0)) BETWEEN 1 AND 2 THEN '1-2 UNITS (SMALL)'
                                            WHEN (ISNULL(s.legal_class_a_units, 0) + ISNULL(s.legal_class_b_units, 0)) BETWEEN 3 AND 5 THEN '3-5 UNITS'
                                            WHEN (ISNULL(s.legal_class_a_units, 0) + ISNULL(s.legal_class_b_units, 0)) BETWEEN 6 AND 19 THEN '6-19 UNITS'
                                            WHEN (ISNULL(s.legal_class_a_units, 0) + ISNULL(s.legal_class_b_units, 0)) BETWEEN 20 AND 99 THEN '20-99 UNITS'
                                            ELSE '100+ UNITS'
                                        END,
            d.registration_id         = s.registration_id,
            d.lifecycle               = ISNULL(s.lifecycle, 'UNKNOWN'),
            d.record_status_id        = s.record_status_id,
            d.record_status           = ISNULL(s.record_status, 'UNKNOWN'),
            d.is_active_building      = s.is_active_building,
            d.is_registered_building  = 1,
            d.DW_modify_date          = SYSDATETIME()
        FROM gold.dim_building d
        INNER JOIN silver.building s
            ON d.building_id = s.building_id;

        -- 3. Insert only newly discovered building_id rows in deterministic order
        INSERT INTO gold.dim_building (
            building_id, boro_id, borough_name,
            house_number, low_house_number, high_house_number,
            street_name, full_street_address, zip_code,
            tax_block, tax_lot, bin, community_board, census_tract,
            management_program, dob_building_class_id, dob_building_class,
            legal_stories, legal_class_a_units, legal_class_b_units,
            total_legal_units, unit_size_tier, registration_id,
            lifecycle, record_status_id, record_status,
            is_active_building, is_registered_building
        )
        SELECT
            s.building_id,
            s.boro_id,
            s.borough_name,
            s.house_number,
            s.low_house_number,
            s.high_house_number,
            s.street_name,
            LTRIM(RTRIM(CONCAT(ISNULL(s.house_number, ''), ' ', s.street_name))),
            ISNULL(s.zip_code, 'UNKNOWN'),
            s.tax_block,
            s.tax_lot,
            s.bin,
            s.community_board,
            s.census_tract,
            ISNULL(s.management_program, 'UNKNOWN'),
            s.dob_building_class_id,
            ISNULL(s.dob_building_class, 'UNKNOWN'),
            s.legal_stories,
            s.legal_class_a_units,
            s.legal_class_b_units,
            CASE
                WHEN s.legal_class_a_units IS NULL AND s.legal_class_b_units IS NULL THEN NULL
                ELSE ISNULL(s.legal_class_a_units, 0) + ISNULL(s.legal_class_b_units, 0)
            END,
            CASE
                WHEN (ISNULL(s.legal_class_a_units, 0) + ISNULL(s.legal_class_b_units, 0)) <= 0 THEN 'UNKNOWN / 0 UNITS'
                WHEN (ISNULL(s.legal_class_a_units, 0) + ISNULL(s.legal_class_b_units, 0)) BETWEEN 1 AND 2 THEN '1-2 UNITS (SMALL)'
                WHEN (ISNULL(s.legal_class_a_units, 0) + ISNULL(s.legal_class_b_units, 0)) BETWEEN 3 AND 5 THEN '3-5 UNITS'
                WHEN (ISNULL(s.legal_class_a_units, 0) + ISNULL(s.legal_class_b_units, 0)) BETWEEN 6 AND 19 THEN '6-19 UNITS'
                WHEN (ISNULL(s.legal_class_a_units, 0) + ISNULL(s.legal_class_b_units, 0)) BETWEEN 20 AND 99 THEN '20-99 UNITS'
                ELSE '100+ UNITS'
            END,
            s.registration_id,
            ISNULL(s.lifecycle, 'UNKNOWN'),
            s.record_status_id,
            ISNULL(s.record_status, 'UNKNOWN'),
            s.is_active_building,
            1
        FROM silver.building s
        WHERE NOT EXISTS (
            SELECT 1 FROM gold.dim_building d WHERE d.building_id = s.building_id
        )
        ORDER BY s.building_id
        OPTION (MAXDOP 1);

        SELECT @rows_loaded = COUNT_BIG(*) FROM gold.dim_building;

        COMMIT TRAN;

        INSERT INTO audit.load_log (batch_id, source_name, target_table, start_time, end_time, rows_loaded, status, message)
        VALUES (@batch, 'silver.building', 'gold.dim_building', @start, SYSDATETIME(), @rows_loaded, 'SUCCESS',
                CONCAT('Gold dim_building load complete (including building_key = -1): total_rows=', @rows_loaded));
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRAN;
        INSERT INTO audit.load_log (batch_id, source_name, target_table, start_time, end_time, rows_loaded, status, message)
        VALUES (@batch, 'silver.building', 'gold.dim_building', @start, SYSDATETIME(), NULL, 'FAILED', ERROR_MESSAGE());
        THROW;
    END CATCH
END;
GO

/* ============================================================================
   8. PROCEDURE: gold.load_dim_date
      Populates unknown date member (-1) and calendar spine 2020-01-01..2026-12-31.
   ============================================================================ */
CREATE OR ALTER PROCEDURE gold.load_dim_date
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @batch       UNIQUEIDENTIFIER = NEWID(),
            @start       DATETIME2        = SYSDATETIME(),
            @rows_loaded BIGINT           = 0;

    BEGIN TRY
        BEGIN TRAN;

        IF NOT EXISTS (SELECT 1 FROM gold.dim_date WHERE date_key = -1)
        BEGIN
            INSERT INTO gold.dim_date (
                date_key, full_date, year_number, quarter_number, quarter_label,
                month_number, month_name, year_month, day_of_month,
                day_of_week_number, day_of_week_name, is_weekend, is_study_window
            )
            VALUES (
                -1, '1900-01-01', 1900, 1, 'NA',
                1, 'UNKNOWN', 'UNKNOWN', 1,
                1, 'UNKNOWN', 0, 0
            );
        END;

        ;WITH date_spine AS (
            SELECT CAST('2020-01-01' AS DATE) AS dt
            UNION ALL
            SELECT DATEADD(DAY, 1, dt)
            FROM date_spine
            WHERE dt < CAST('2026-12-31' AS DATE)
        )
        INSERT INTO gold.dim_date (
            date_key, full_date, year_number, quarter_number, quarter_label,
            month_number, month_name, year_month, day_of_month,
            day_of_week_number, day_of_week_name, is_weekend, is_study_window
        )
        SELECT
            CONVERT(INT, CONVERT(CHAR(8), s.dt, 112)) AS date_key,
            s.dt AS full_date,
            YEAR(s.dt) AS year_number,
            DATEPART(QUARTER, s.dt) AS quarter_number,
            CONCAT('Q', DATEPART(QUARTER, s.dt)) AS quarter_label,
            MONTH(s.dt) AS month_number,
            DATENAME(MONTH, s.dt) AS month_name,
            CONVERT(CHAR(7), s.dt, 126) AS year_month,
            DAY(s.dt) AS day_of_month,
            DATEPART(WEEKDAY, s.dt) AS day_of_week_number,
            DATENAME(WEEKDAY, s.dt) AS day_of_week_name,
            CASE WHEN DATENAME(WEEKDAY, s.dt) IN ('Saturday', 'Sunday') THEN 1 ELSE 0 END AS is_weekend,
            CASE WHEN s.dt >= '2024-01-01' AND s.dt <= '2024-12-31' THEN 1 ELSE 0 END AS is_study_window
        FROM date_spine s
        WHERE NOT EXISTS (
            SELECT 1 FROM gold.dim_date d WHERE d.full_date = s.dt
        )
        OPTION (MAXRECURSION 3000, MAXDOP 1);

        SELECT @rows_loaded = COUNT_BIG(*) FROM gold.dim_date;

        COMMIT TRAN;

        INSERT INTO audit.load_log (batch_id, source_name, target_table, start_time, end_time, rows_loaded, status, message)
        VALUES (@batch, 'calendar_spine_2020_2026', 'gold.dim_date', @start, SYSDATETIME(), @rows_loaded, 'SUCCESS',
                CONCAT('Gold dim_date load complete: total_rows=', @rows_loaded));
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRAN;
        INSERT INTO audit.load_log (batch_id, source_name, target_table, start_time, end_time, rows_loaded, status, message)
        VALUES (@batch, 'calendar_spine_2020_2026', 'gold.dim_date', @start, SYSDATETIME(), NULL, 'FAILED', ERROR_MESSAGE());
        THROW;
    END CATCH
END;
GO

/* ============================================================================
   9. PROCEDURE: gold.load_fact_complaint_problem
      GRAIN: One row per problem_id.
   ============================================================================ */
CREATE OR ALTER PROCEDURE gold.load_fact_complaint_problem
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @batch       UNIQUEIDENTIFIER = NEWID(),
            @start       DATETIME2        = SYSDATETIME(),
            @rows_loaded BIGINT           = 0;

    BEGIN TRY
        IF OBJECT_ID('tempdb..#fact_cp') IS NOT NULL DROP TABLE #fact_cp;

        SELECT
            cp.problem_id,
            cp.complaint_id,
            ISNULL(b.building_key, -1) AS building_key,
            cp.building_id,
            ISNULL(dr.date_key, -1) AS received_date_key,
            ISNULL(ds.date_key, -1) AS status_date_key,
            cp.received_date,
            CONVERT(CHAR(7), cp.received_date, 126) AS year_month,
            cp.unit_type,
            cp.space_type,
            ISNULL(cp.urgency_type, 'UNKNOWN') AS urgency_type,
            CASE WHEN cp.urgency_type IN ('IMMEDIATE EMERGENCY', 'EMERGENCY') THEN CAST(1 AS BIT) ELSE CAST(0 AS BIT) END AS is_emergency_priority,
            cp.major_category,
            cp.minor_category,
            cp.problem_code,
            cp.complaint_status,
            cp.problem_status,
            cp.is_duplicate_problem_flag,
            cp.is_registered_building,
            cp.bronze_row_id,
            cp.source_batch_id
        INTO #fact_cp
        FROM silver.complaint_problem cp
        LEFT JOIN gold.dim_building b
            ON cp.building_id = b.building_id
        LEFT JOIN gold.dim_date dr
            ON cp.received_date = dr.full_date
        LEFT JOIN gold.dim_date ds
            ON cp.problem_status_date = ds.full_date
        OPTION (MAXDOP 1);

        BEGIN TRAN;

        TRUNCATE TABLE gold.fact_complaint_problem;

        INSERT INTO gold.fact_complaint_problem (
            problem_id, complaint_id, building_key, building_id,
            received_date_key, status_date_key, received_date, year_month,
            unit_type, space_type, urgency_type, is_emergency_priority,
            major_category, minor_category, problem_code, complaint_status,
            problem_status, is_duplicate_problem_flag, is_registered_building,
            bronze_row_id, source_batch_id
        )
        SELECT
            problem_id, complaint_id, building_key, building_id,
            received_date_key, status_date_key, received_date, year_month,
            unit_type, space_type, urgency_type, is_emergency_priority,
            major_category, minor_category, problem_code, complaint_status,
            problem_status, is_duplicate_problem_flag, is_registered_building,
            bronze_row_id, source_batch_id
        FROM #fact_cp
        OPTION (MAXDOP 1);

        SET @rows_loaded = @@ROWCOUNT;

        COMMIT TRAN;

        INSERT INTO audit.load_log (batch_id, source_name, target_table, start_time, end_time, rows_loaded, status, message)
        VALUES (@batch, 'silver.complaint_problem', 'gold.fact_complaint_problem', @start, SYSDATETIME(), @rows_loaded, 'SUCCESS',
                CONCAT('Gold fact_complaint_problem load complete: rows_loaded=', @rows_loaded));
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRAN;
        INSERT INTO audit.load_log (batch_id, source_name, target_table, start_time, end_time, rows_loaded, status, message)
        VALUES (@batch, 'silver.complaint_problem', 'gold.fact_complaint_problem', @start, SYSDATETIME(), NULL, 'FAILED', ERROR_MESSAGE());
        THROW;
    END CATCH
END;
GO

/* ============================================================================
   10. PROCEDURE: gold.load_fact_violation
       GRAIN: One row per violation_id.
   ============================================================================ */
CREATE OR ALTER PROCEDURE gold.load_fact_violation
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @batch       UNIQUEIDENTIFIER = NEWID(),
            @start       DATETIME2        = SYSDATETIME(),
            @rows_loaded BIGINT           = 0;

    BEGIN TRY
        IF OBJECT_ID('tempdb..#fact_viol') IS NOT NULL DROP TABLE #fact_viol;

        SELECT
            v.violation_id,
            ISNULL(b.building_key, -1) AS building_key,
            v.building_id,
            ISNULL(di.date_key, -1) AS inspection_date_key,
            ISNULL(dn.date_key, -1) AS nov_issued_date_key,
            ISNULL(dc.date_key, -1) AS current_status_date_key,
            v.inspection_date,
            CONVERT(CHAR(7), v.inspection_date, 126) AS year_month,
            v.violation_class,
            v.hazard_class_category,
            v.is_hazardous_violation AS is_substantive_abc_violation,
            CASE WHEN v.violation_class IN ('B', 'C') THEN CAST(1 AS BIT) ELSE CAST(0 AS BIT) END AS is_b_or_c_hazardous_violation,
            CASE WHEN v.violation_class = 'C' THEN CAST(1 AS BIT) ELSE CAST(0 AS BIT) END AS is_immediately_hazardous,
            v.hazard_severity_rank,
            v.is_open_violation,
            v.is_rent_impairing,
            v.violation_status,
            v.current_status,
            v.nov_type,
            v.is_registered_building,
            v.bronze_row_id,
            v.source_batch_id
        INTO #fact_viol
        FROM silver.violation v
        LEFT JOIN gold.dim_building b
            ON v.building_id = b.building_id
        LEFT JOIN gold.dim_date di
            ON v.inspection_date = di.full_date
        LEFT JOIN gold.dim_date dn
            ON v.nov_issued_date = dn.full_date
        LEFT JOIN gold.dim_date dc
            ON v.current_status_date = dc.full_date
        OPTION (MAXDOP 1);

        BEGIN TRAN;

        TRUNCATE TABLE gold.fact_violation;

        INSERT INTO gold.fact_violation (
            violation_id, building_key, building_id,
            inspection_date_key, nov_issued_date_key, current_status_date_key,
            inspection_date, year_month, violation_class, hazard_class_category,
            is_substantive_abc_violation, is_b_or_c_hazardous_violation,
            is_immediately_hazardous, hazard_severity_rank,
            is_open_violation, is_rent_impairing, violation_status,
            current_status, nov_type, is_registered_building,
            bronze_row_id, source_batch_id
        )
        SELECT
            violation_id, building_key, building_id,
            inspection_date_key, nov_issued_date_key, current_status_date_key,
            inspection_date, year_month, violation_class, hazard_class_category,
            is_substantive_abc_violation, is_b_or_c_hazardous_violation,
            is_immediately_hazardous, hazard_severity_rank,
            is_open_violation, is_rent_impairing, violation_status,
            current_status, nov_type, is_registered_building,
            bronze_row_id, source_batch_id
        FROM #fact_viol
        OPTION (MAXDOP 1);

        SET @rows_loaded = @@ROWCOUNT;

        COMMIT TRAN;

        INSERT INTO audit.load_log (batch_id, source_name, target_table, start_time, end_time, rows_loaded, status, message)
        VALUES (@batch, 'silver.violation', 'gold.fact_violation', @start, SYSDATETIME(), @rows_loaded, 'SUCCESS',
                CONCAT('Gold fact_violation load complete: rows_loaded=', @rows_loaded));
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRAN;
        INSERT INTO audit.load_log (batch_id, source_name, target_table, start_time, end_time, rows_loaded, status, message)
        VALUES (@batch, 'silver.violation', 'gold.fact_violation', @start, SYSDATETIME(), NULL, 'FAILED', ERROR_MESSAGE());
        THROW;
    END CATCH
END;
GO

/* ============================================================================
   11. PROCEDURE: gold.load_fact_repair_order
       GRAIN: One row per omo_id (with unique omo_number).
   ============================================================================ */
CREATE OR ALTER PROCEDURE gold.load_fact_repair_order
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @batch       UNIQUEIDENTIFIER = NEWID(),
            @start       DATETIME2        = SYSDATETIME(),
            @rows_loaded BIGINT           = 0;

    BEGIN TRY
        IF OBJECT_ID('tempdb..#fact_ro') IS NOT NULL DROP TABLE #fact_ro;

        SELECT
            o.omo_id,
            o.omo_number,
            ISNULL(b.building_key, -1) AS building_key,
            o.building_id,
            ISNULL(dc.date_key, -1) AS omo_create_date_key,
            ISNULL(da.date_key, -1) AS omo_award_date_key,
            o.omo_create_date,
            o.omo_award_date,
            CONVERT(CHAR(7), o.omo_create_date, 126) AS year_month,
            o.lifecycle,
            o.work_type_general,
            o.omo_status_reason,
            o.service_charge_flag,
            o.has_service_charge,
            o.is_commercial_demolition,
            o.is_eligible_repair_cohort,
            o.repair_cohort_category,
            o.financial_value_status,
            ISNULL(o.omo_award_amount, 0.00) AS omo_award_amount,
            CASE WHEN o.is_eligible_repair_cohort = 1 THEN o.omo_award_amount ELSE NULL END AS eligible_omo_award_amount,
            o.net_change_orders,
            o.is_registered_building,
            o.bronze_row_id,
            o.source_batch_id
        INTO #fact_ro
        FROM silver.omo_charge o
        LEFT JOIN gold.dim_building b
            ON o.building_id = b.building_id
        LEFT JOIN gold.dim_date dc
            ON o.omo_create_date = dc.full_date
        LEFT JOIN gold.dim_date da
            ON o.omo_award_date = da.full_date
        OPTION (MAXDOP 1);

        BEGIN TRAN;

        TRUNCATE TABLE gold.fact_repair_order;

        INSERT INTO gold.fact_repair_order (
            omo_id, omo_number, building_key, building_id,
            omo_create_date_key, omo_award_date_key, omo_create_date, omo_award_date,
            year_month, lifecycle, work_type_general, omo_status_reason,
            service_charge_flag, has_service_charge, is_commercial_demolition,
            is_eligible_repair_cohort, repair_cohort_category, financial_value_status,
            omo_award_amount, eligible_omo_award_amount, net_change_orders,
            is_registered_building, bronze_row_id, source_batch_id
        )
        SELECT
            omo_id, omo_number, building_key, building_id,
            omo_create_date_key, omo_award_date_key, omo_create_date, omo_award_date,
            year_month, lifecycle, work_type_general, omo_status_reason,
            service_charge_flag, has_service_charge, is_commercial_demolition,
            is_eligible_repair_cohort, repair_cohort_category, financial_value_status,
            omo_award_amount, eligible_omo_award_amount, net_change_orders,
            is_registered_building, bronze_row_id, source_batch_id
        FROM #fact_ro
        OPTION (MAXDOP 1);

        SET @rows_loaded = @@ROWCOUNT;

        COMMIT TRAN;

        INSERT INTO audit.load_log (batch_id, source_name, target_table, start_time, end_time, rows_loaded, status, message)
        VALUES (@batch, 'silver.omo_charge', 'gold.fact_repair_order', @start, SYSDATETIME(), @rows_loaded, 'SUCCESS',
                CONCAT('Gold fact_repair_order load complete: rows_loaded=', @rows_loaded));
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRAN;
        INSERT INTO audit.load_log (batch_id, source_name, target_table, start_time, end_time, rows_loaded, status, message)
        VALUES (@batch, 'silver.omo_charge', 'gold.fact_repair_order', @start, SYSDATETIME(), NULL, 'FAILED', ERROR_MESSAGE());
        THROW;
    END CATCH
END;
GO

/* ============================================================================
   12. PROCEDURE: gold.load_mart_building_month
       GRAIN: One row per active (building_id, year_month) in 2024.
       Aggregates each domain independently before joining to prevent fan-out.
   ============================================================================ */
CREATE OR ALTER PROCEDURE gold.load_mart_building_month
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @batch       UNIQUEIDENTIFIER = NEWID(),
            @start       DATETIME2        = SYSDATETIME(),
            @rows_loaded BIGINT           = 0;

    BEGIN TRY
        IF OBJECT_ID('tempdb..#mart_bm') IS NOT NULL DROP TABLE #mart_bm;

        ;WITH cp_monthly AS (
            SELECT
                building_id,
                year_month,
                MAX(building_key) AS building_key,
                MAX(CAST(is_registered_building AS TINYINT)) AS is_registered_building,
                COUNT(DISTINCT complaint_id) AS complaint_count,
                COUNT(problem_id) AS problem_count,
                SUM(CASE WHEN is_emergency_priority = 1 THEN 1 ELSE 0 END) AS emergency_problem_count,
                SUM(CASE WHEN is_emergency_priority = 0 THEN 1 ELSE 0 END) AS non_emergency_problem_count,
                SUM(CASE WHEN is_duplicate_problem_flag = 1 THEN 1 ELSE 0 END) AS duplicate_problem_count
            FROM gold.fact_complaint_problem
            GROUP BY building_id, year_month
        ),
        viol_monthly AS (
            SELECT
                building_id,
                year_month,
                MAX(building_key) AS building_key,
                MAX(CAST(is_registered_building AS TINYINT)) AS is_registered_building,
                COUNT(violation_id) AS violation_count,
                SUM(CASE WHEN violation_class = 'A' THEN 1 ELSE 0 END) AS class_a_violation_count,
                SUM(CASE WHEN violation_class = 'B' THEN 1 ELSE 0 END) AS class_b_violation_count,
                SUM(CASE WHEN violation_class = 'C' THEN 1 ELSE 0 END) AS class_c_violation_count,
                SUM(CASE WHEN violation_class = 'I' THEN 1 ELSE 0 END) AS class_i_violation_count,
                SUM(CASE WHEN is_substantive_abc_violation = 1 THEN 1 ELSE 0 END) AS substantive_abc_violation_count,
                SUM(CASE WHEN is_b_or_c_hazardous_violation = 1 THEN 1 ELSE 0 END) AS hazardous_bc_violation_count,
                SUM(CASE WHEN is_open_violation = 1 THEN 1 ELSE 0 END) AS open_violation_count,
                SUM(CASE WHEN is_rent_impairing = 1 THEN 1 ELSE 0 END) AS rent_impairing_violation_count,
                SUM(hazard_severity_rank) AS violation_severity_weighted_score
            FROM gold.fact_violation
            GROUP BY building_id, year_month
        ),
        ro_monthly AS (
            SELECT
                building_id,
                year_month,
                MAX(building_key) AS building_key,
                MAX(CAST(is_registered_building AS TINYINT)) AS is_registered_building,
                COUNT(omo_id) AS omo_order_count,
                SUM(CASE WHEN is_eligible_repair_cohort = 1 THEN 1 ELSE 0 END) AS eligible_repair_order_count,
                SUM(CASE WHEN is_eligible_repair_cohort = 0 THEN 1 ELSE 0 END) AS excluded_omo_order_count,
                SUM(CASE WHEN omo_award_amount = 0 THEN 1 ELSE 0 END) AS zero_dollar_omo_order_count,
                SUM(omo_award_amount) AS raw_total_omo_award_amount,
                SUM(eligible_omo_award_amount) AS raw_eligible_omo_award_amount,
                SUM(CASE WHEN is_eligible_repair_cohort = 0 THEN omo_award_amount ELSE 0.00 END) AS excluded_omo_award_amount
            FROM gold.fact_repair_order
            GROUP BY building_id, year_month
        ),
        active_spine AS (
            SELECT building_id, year_month, building_key, is_registered_building FROM cp_monthly
            UNION
            SELECT building_id, year_month, building_key, is_registered_building FROM viol_monthly
            UNION
            SELECT building_id, year_month, building_key, is_registered_building FROM ro_monthly
        )
        SELECT
            s.building_id,
            s.year_month,
            s.building_key,
            CONVERT(INT, REPLACE(CONCAT(s.year_month, '-01'), '-', '')) AS month_start_date_key,
            CAST(s.is_registered_building AS BIT) AS is_registered_building,
            -- Complaint metrics
            ISNULL(cp.complaint_count, 0) AS complaint_count,
            ISNULL(cp.problem_count, 0) AS problem_count,
            ISNULL(cp.emergency_problem_count, 0) AS emergency_problem_count,
            ISNULL(cp.non_emergency_problem_count, 0) AS non_emergency_problem_count,
            ISNULL(cp.duplicate_problem_count, 0) AS duplicate_problem_count,
            -- Violation metrics
            ISNULL(v.violation_count, 0) AS violation_count,
            ISNULL(v.class_a_violation_count, 0) AS class_a_violation_count,
            ISNULL(v.class_b_violation_count, 0) AS class_b_violation_count,
            ISNULL(v.class_c_violation_count, 0) AS class_c_violation_count,
            ISNULL(v.class_i_violation_count, 0) AS class_i_violation_count,
            ISNULL(v.substantive_abc_violation_count, 0) AS substantive_abc_violation_count,
            ISNULL(v.hazardous_bc_violation_count, 0) AS hazardous_bc_violation_count,
            ISNULL(v.open_violation_count, 0) AS open_violation_count,
            ISNULL(v.rent_impairing_violation_count, 0) AS rent_impairing_violation_count,
            ISNULL(v.violation_severity_weighted_score, 0) AS violation_severity_weighted_score,
            -- OMO Repair Order metrics (preserving NULL vs 0.00 distinction)
            CAST(CASE WHEN ISNULL(ro.omo_order_count, 0) > 0 THEN 1 ELSE 0 END AS BIT) AS has_omo_orders,
            CAST(CASE WHEN ISNULL(ro.eligible_repair_order_count, 0) > 0 THEN 1 ELSE 0 END AS BIT) AS has_eligible_repair_orders,
            ISNULL(ro.omo_order_count, 0) AS omo_order_count,
            ISNULL(ro.eligible_repair_order_count, 0) AS eligible_repair_order_count,
            ISNULL(ro.excluded_omo_order_count, 0) AS excluded_omo_order_count,
            ISNULL(ro.zero_dollar_omo_order_count, 0) AS zero_dollar_omo_order_count,
            ro.raw_total_omo_award_amount,
            ro.raw_eligible_omo_award_amount,
            ISNULL(ro.raw_total_omo_award_amount, 0.00) AS total_omo_award_amount,
            ISNULL(ro.raw_eligible_omo_award_amount, 0.00) AS eligible_omo_award_amount,
            ISNULL(ro.excluded_omo_award_amount, 0.00) AS excluded_omo_award_amount
        INTO #mart_bm
        FROM active_spine s
        LEFT JOIN cp_monthly cp
            ON s.building_id = cp.building_id AND s.year_month = cp.year_month
        LEFT JOIN viol_monthly v
            ON s.building_id = v.building_id AND s.year_month = v.year_month
        LEFT JOIN ro_monthly ro
            ON s.building_id = ro.building_id AND s.year_month = ro.year_month
        OPTION (MAXDOP 1);

        BEGIN TRAN;

        TRUNCATE TABLE gold.mart_building_month;

        INSERT INTO gold.mart_building_month (
            building_id, year_month, building_key, month_start_date_key, is_registered_building,
            complaint_count, problem_count, emergency_problem_count, non_emergency_problem_count, duplicate_problem_count,
            violation_count, class_a_violation_count, class_b_violation_count, class_c_violation_count, class_i_violation_count,
            substantive_abc_violation_count, hazardous_bc_violation_count, open_violation_count,
            rent_impairing_violation_count, violation_severity_weighted_score,
            has_omo_orders, has_eligible_repair_orders, omo_order_count, eligible_repair_order_count,
            excluded_omo_order_count, zero_dollar_omo_order_count,
            raw_total_omo_award_amount, raw_eligible_omo_award_amount,
            total_omo_award_amount, eligible_omo_award_amount, excluded_omo_award_amount
        )
        SELECT
            building_id, year_month, building_key, month_start_date_key, is_registered_building,
            complaint_count, problem_count, emergency_problem_count, non_emergency_problem_count, duplicate_problem_count,
            violation_count, class_a_violation_count, class_b_violation_count, class_c_violation_count, class_i_violation_count,
            substantive_abc_violation_count, hazardous_bc_violation_count, open_violation_count,
            rent_impairing_violation_count, violation_severity_weighted_score,
            has_omo_orders, has_eligible_repair_orders, omo_order_count, eligible_repair_order_count,
            excluded_omo_order_count, zero_dollar_omo_order_count,
            raw_total_omo_award_amount, raw_eligible_omo_award_amount,
            total_omo_award_amount, eligible_omo_award_amount, excluded_omo_award_amount
        FROM #mart_bm
        OPTION (MAXDOP 1);

        SET @rows_loaded = @@ROWCOUNT;

        COMMIT TRAN;

        INSERT INTO audit.load_log (batch_id, source_name, target_table, start_time, end_time, rows_loaded, status, message)
        VALUES (@batch, 'gold.fact_*', 'gold.mart_building_month', @start, SYSDATETIME(), @rows_loaded, 'SUCCESS',
                CONCAT('Gold mart_building_month load complete: rows_loaded=', @rows_loaded));
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRAN;
        INSERT INTO audit.load_log (batch_id, source_name, target_table, start_time, end_time, rows_loaded, status, message)
        VALUES (@batch, 'gold.fact_*', 'gold.mart_building_month', @start, SYSDATETIME(), NULL, 'FAILED', ERROR_MESSAGE());
        THROW;
    END CATCH
END;
GO

/* ============================================================================
   13. MASTER ORCHESTRATION PROCEDURE: gold.load_all
   ============================================================================ */
CREATE OR ALTER PROCEDURE gold.load_all
AS
BEGIN
    SET NOCOUNT ON;
    EXEC gold.load_dim_building;
    EXEC gold.load_dim_date;
    EXEC gold.load_fact_complaint_problem;
    EXEC gold.load_fact_violation;
    EXEC gold.load_fact_repair_order;
    EXEC gold.load_mart_building_month;
END;
GO
