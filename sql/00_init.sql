-- =============================================================================
-- sql/00_init.sql
-- HomeRescue AI Data Warehouse — Database, Schemas & Audit Log Initialization
-- Compatible with SQL Server 2017+ (verified on SQL Server 2025).
--
-- Database Targeting Behavior:
-- 1. If executed while connected to a system database (master, tempdb, model, msdb),
--    creates [homerescue_dw] if it does not already exist and switches context to it.
-- 2. If executed while connected directly to a specific target database
--    (e.g., via `sqlcmd -d homerescue_dw_verify`), initializes all schemas and
--    audit tables inside that active database without switching back to homerescue_dw.
-- =============================================================================

IF DB_NAME() IN (N'master', N'tempdb', N'model', N'msdb')
BEGIN
    IF DB_ID(N'homerescue_dw') IS NULL
        EXEC(N'CREATE DATABASE [homerescue_dw];');
END;
GO

IF DB_NAME() IN (N'master', N'tempdb', N'model', N'msdb')
    USE [homerescue_dw];
GO

IF SCHEMA_ID(N'bronze')   IS NULL EXEC(N'CREATE SCHEMA bronze');
IF SCHEMA_ID(N'silver')   IS NULL EXEC(N'CREATE SCHEMA silver');
IF SCHEMA_ID(N'gold')     IS NULL EXEC(N'CREATE SCHEMA gold');
IF SCHEMA_ID(N'semantic') IS NULL EXEC(N'CREATE SCHEMA semantic');
IF SCHEMA_ID(N'ml')       IS NULL EXEC(N'CREATE SCHEMA ml');
IF SCHEMA_ID(N'audit')    IS NULL EXEC(N'CREATE SCHEMA audit');
GO

-- One row per pipeline execution step, written by every Bronze, Silver, and Gold load procedure.
IF OBJECT_ID(N'audit.load_log', N'U') IS NULL
BEGIN
    CREATE TABLE audit.load_log (
        load_id      BIGINT IDENTITY(1,1) NOT NULL PRIMARY KEY,
        batch_id     UNIQUEIDENTIFIER     NOT NULL,
        source_name  VARCHAR(100)         NOT NULL,
        target_table VARCHAR(200)         NOT NULL,
        start_time   DATETIME2            NOT NULL,
        end_time     DATETIME2            NULL,
        rows_loaded  BIGINT               NULL,
        status       VARCHAR(20)          NOT NULL,
        message      VARCHAR(4000)        NULL
    );
END;
GO
