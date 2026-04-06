-- =============================================================================
-- 01-enable-cdc.sql
-- Enable Change Data Capture on GasPlantDB for Fabric Mirroring
--
-- Prerequisites:
--   1. Run as a member of sysadmin or db_owner
--   2. SQL Server Agent must be running (required for CDC capture jobs)
--   3. Database must be in FULL recovery model (set in 01-create-database.sql)
--
-- Run this AFTER 02-create-tables.sql
-- =============================================================================

USE GasPlantDB;
GO

-- Enable CDC at the database level
EXEC sys.sp_cdc_enable_db;
GO

PRINT 'CDC enabled at database level.';
GO

-- =============================================================================
-- Enable CDC on each table that Fabric Mirroring will replicate
-- net_changes = 1 enables net-change functions (INSERT/UPDATE/DELETE tracking)
-- =============================================================================

-- SensorReadings — high-frequency telemetry (primary CDC table)
EXEC sys.sp_cdc_enable_table
    @source_schema       = N'dbo',
    @source_name         = N'SensorReadings',
    @role_name           = NULL,
    @supports_net_changes = 1;
GO
PRINT 'CDC enabled on dbo.SensorReadings.';

-- EquipmentStatus — equipment on/off state events
EXEC sys.sp_cdc_enable_table
    @source_schema       = N'dbo',
    @source_name         = N'EquipmentStatus',
    @role_name           = NULL,
    @supports_net_changes = 1;
GO
PRINT 'CDC enabled on dbo.EquipmentStatus.';

-- Alarms — threshold breach events
EXEC sys.sp_cdc_enable_table
    @source_schema       = N'dbo',
    @source_name         = N'Alarms',
    @role_name           = NULL,
    @supports_net_changes = 1;
GO
PRINT 'CDC enabled on dbo.Alarms.';

-- GasQuality — hourly composition samples
EXEC sys.sp_cdc_enable_table
    @source_schema       = N'dbo',
    @source_name         = N'GasQuality',
    @role_name           = NULL,
    @supports_net_changes = 1;
GO
PRINT 'CDC enabled on dbo.GasQuality.';

-- =============================================================================
-- Verify CDC status
-- =============================================================================

-- Database-level CDC status
SELECT
    name                AS database_name,
    is_cdc_enabled,
    recovery_model_desc AS recovery_model
FROM sys.databases
WHERE name = DB_NAME();
GO

-- Table-level CDC status
SELECT
    s.name  AS schema_name,
    t.name  AS table_name,
    t.is_tracked_by_cdc
FROM sys.tables t
JOIN sys.schemas s ON t.schema_id = s.schema_id
WHERE t.is_tracked_by_cdc = 1
ORDER BY t.name;
GO

-- CDC capture jobs (should show 2 jobs: capture + cleanup)
EXEC sys.sp_cdc_help_jobs;
GO
