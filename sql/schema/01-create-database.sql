-- =============================================================================
-- 01-create-database.sql
-- Create the LP Gas Plant demonstration database
--
-- Run as: sysadmin or dbcreator on the SQL Server instance
-- =============================================================================

USE master;
GO

IF NOT EXISTS (SELECT name FROM sys.databases WHERE name = N'GasPlantDB')
BEGIN
    CREATE DATABASE GasPlantDB
        ON PRIMARY
        (
            NAME     = GasPlantDB_data,
            FILENAME = 'D:\data\GasPlantDB.mdf',
            SIZE     = 512  MB,
            MAXSIZE  = 10   GB,
            FILEGROWTH = 256 MB
        )
        LOG ON
        (
            NAME     = GasPlantDB_log,
            FILENAME = 'D:\data\GasPlantDB.ldf',
            SIZE     = 256  MB,
            MAXSIZE  = 2    GB,
            FILEGROWTH = 128 MB
        );
    PRINT 'Database GasPlantDB created on D:\data\.';
END
ELSE
BEGIN
    PRINT 'Database GasPlantDB already exists — skipping creation.';
END
GO

-- Full recovery model is required for CDC
ALTER DATABASE GasPlantDB SET RECOVERY FULL;
GO

-- Allow snapshot isolation — improves read concurrency without blocking CDC
ALTER DATABASE GasPlantDB SET READ_COMMITTED_SNAPSHOT ON;
GO

-- Verify
SELECT
    name,
    recovery_model_desc,
    is_read_committed_snapshot_on,
    is_cdc_enabled
FROM sys.databases
WHERE name = N'GasPlantDB';
GO
