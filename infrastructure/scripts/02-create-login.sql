-- =============================================================================
-- 02-create-login.sql
-- Create SQL Server login and user for Fabric Mirroring
--
-- IMPORTANT: Change the password before running in any shared environment.
--            Use a strong password: min 12 chars, upper+lower+digit+symbol.
--
-- The login needs:
--   - db_datareader          → read all tables
--   - SELECT on cdc schema   → read CDC change tables
--   - VIEW DATABASE STATE     → CDC metadata inspection
--   - EXECUTE on CDC procs    → Fabric connector CDC introspection
-- =============================================================================

USE master;
GO

-- Create the SQL Server login
-- Replace password with a strong value; ideally inject at deploy time.
IF NOT EXISTS (SELECT 1 FROM sys.server_principals WHERE name = N'FabricMirrorLogin')
BEGIN
    CREATE LOGIN FabricMirrorLogin
        WITH PASSWORD         = 'Ch@ngeM3!2026#Fabric',
             CHECK_POLICY     = ON,
             CHECK_EXPIRATION = OFF;
    PRINT 'Login FabricMirrorLogin created.';
END
ELSE
BEGIN
    PRINT 'Login FabricMirrorLogin already exists — skipping creation.';
END
GO

USE GasPlantDB;
GO

-- Create database user mapped to the login
IF NOT EXISTS (SELECT 1 FROM sys.database_principals WHERE name = N'FabricMirrorUser')
BEGIN
    CREATE USER FabricMirrorUser FOR LOGIN FabricMirrorLogin;
    PRINT 'User FabricMirrorUser created.';
END
GO

-- Read access to all user tables
ALTER ROLE db_datareader ADD MEMBER FabricMirrorUser;
GO

-- CDC change table access (cdc schema)
GRANT SELECT ON SCHEMA::cdc TO FabricMirrorUser;
GO

-- Required for Fabric Mirroring connector to inspect CDC state
GRANT VIEW DATABASE STATE TO FabricMirrorUser;
GO

-- CDC stored procedure access (used by Fabric connector during setup)
GRANT EXECUTE ON sys.sp_cdc_get_captured_columns       TO FabricMirrorUser;
GRANT EXECUTE ON sys.sp_cdc_help_change_data_capture   TO FabricMirrorUser;
GO

-- Verify permissions
SELECT
    dp.name               AS principal_name,
    dp.type_desc          AS principal_type,
    o.name                AS object_name,
    p.permission_name,
    p.state_desc          AS grant_state
FROM sys.database_permissions p
JOIN sys.database_principals dp ON p.grantee_principal_id = dp.principal_id
LEFT JOIN sys.objects o         ON p.major_id = o.object_id
WHERE dp.name = N'FabricMirrorUser'
ORDER BY p.permission_name;
GO

PRINT '---';
PRINT 'FabricMirrorLogin setup complete.';
PRINT 'Use these credentials in Fabric Mirroring source configuration:';
PRINT '  Login   : FabricMirrorLogin';
PRINT '  Database: GasPlantDB';
PRINT 'IMPORTANT: Change the password before sharing or deploying to any environment.';
GO
