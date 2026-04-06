-- =============================================================================
-- 03-seed-static-data.sql
-- Seed ProcessUnits and Sensors reference data
-- LP Gas Plant — 2 Trains, 6 Compressors, 2 Separators, 2 Metering stations
-- 40 sensor tags (pressure, temperature, flow, RPM, power, level)
--
-- Run AFTER 02-create-tables.sql
-- =============================================================================

USE GasPlantDB;
GO

SET NOCOUNT ON;

-- =============================================================================
-- PROCESS UNITS
-- Hierarchy: Plant (1) → Train A (2) → Equipment 3-7
--                       → Train B (8) → Equipment 9-13
-- =============================================================================

SET IDENTITY_INSERT dbo.ProcessUnits ON;

INSERT INTO dbo.ProcessUnits
    (unit_id, unit_name,                unit_type,    parent_unit_id, location,               commissioned,  is_active)
VALUES
    -- Plant root
    (1,  'LP Gas Plant',                'Plant',       NULL, 'Point Lisas Industrial Estate', '2001-01-15',  1),

    -- Train A and its equipment
    (2,  'Train A',                     'Train',          1, 'North Processing Pad',          '2001-03-01',  1),
    (3,  'Train A – Gas Separator',     'Separator',      2, 'North Pad – A-V100',            '2001-03-01',  1),
    (4,  'Train A – Compressor K100',   'Compressor',     2, 'North Pad – A-K100',            '2001-03-01',  1),
    (5,  'Train A – Compressor K200',   'Compressor',     2, 'North Pad – A-K200',            '2002-06-15',  1),
    (6,  'Train A – Compressor K300',   'Compressor',     2, 'North Pad – A-K300',            '2005-09-01',  1),
    (7,  'Train A – Export Metering',   'Meter',          2, 'North Pad – A-FT001',           '2001-03-01',  1),

    -- Train B and its equipment
    (8,  'Train B',                     'Train',          1, 'South Processing Pad',          '2003-07-01',  1),
    (9,  'Train B – Gas Separator',     'Separator',      8, 'South Pad – B-V100',            '2003-07-01',  1),
    (10, 'Train B – Compressor K100',   'Compressor',     8, 'South Pad – B-K100',            '2003-07-01',  1),
    (11, 'Train B – Compressor K200',   'Compressor',     8, 'South Pad – B-K200',            '2004-02-20',  1),
    (12, 'Train B – Compressor K300',   'Compressor',     8, 'South Pad – B-K300',            '2007-11-10',  1),
    (13, 'Train B – Export Metering',   'Meter',          8, 'South Pad – B-FT001',           '2003-07-01',  1);

SET IDENTITY_INSERT dbo.ProcessUnits OFF;
GO

-- =============================================================================
-- SENSOR TAGS — 40 tags
-- Naming convention: <Train>-<Equipment>-<Parameter>-<Sequence>
--   e.g. A-K100-PT-001 = Train A, Compressor K100, Pressure Transmitter #1
-- =============================================================================

SET IDENTITY_INSERT dbo.Sensors ON;

INSERT INTO dbo.Sensors
    (sensor_id, tag_id,           tag_name,                                        equipment_id, parameter_type, unit_of_measure, normal_min, normal_max, alarm_low, alarm_high)
VALUES
    -- ── TRAIN A – Gas Separator (unit_id = 3) ────────────────────────────────
    ( 1, 'A-SEP-PT-001', 'Train A Separator Inlet Pressure',        3, 'Pressure',    'bar',      30.0,  60.0,  25.0,  65.0),
    ( 2, 'A-SEP-TT-001', 'Train A Separator Inlet Temperature',     3, 'Temperature', '°C',       10.0,  45.0,   5.0,  50.0),
    ( 3, 'A-SEP-LT-001', 'Train A Separator Liquid Level',          3, 'Level',       '%',        20.0,  80.0,  10.0,  90.0),
    ( 4, 'A-SEP-FT-001', 'Train A Separator Gas Outlet Flow',       3, 'Flow',        'MMSCFD',    1.5,   4.0,   1.0,   4.5),

    -- ── TRAIN A – Compressor K100 (unit_id = 4) ──────────────────────────────
    ( 5, 'A-K100-PT-001', 'Train A K100 Suction Pressure',          4, 'Pressure',    'bar',      20.0,  35.0,  15.0,  40.0),
    ( 6, 'A-K100-PT-002', 'Train A K100 Discharge Pressure',        4, 'Pressure',    'bar',      60.0,  80.0,  55.0,  87.0),
    ( 7, 'A-K100-TT-001', 'Train A K100 Suction Temperature',       4, 'Temperature', '°C',       15.0,  40.0,  10.0,  50.0),
    ( 8, 'A-K100-TT-002', 'Train A K100 Discharge Temperature',     4, 'Temperature', '°C',       60.0, 110.0,  55.0, 120.0),
    ( 9, 'A-K100-ST-001', 'Train A K100 Shaft Speed',               4, 'RPM',         'RPM',    3200.0,3600.0,2800.0,3800.0),
    (10, 'A-K100-KW-001', 'Train A K100 Power Consumption',         4, 'Power',       'kW',     2500.0,4000.0,2000.0,4500.0),

    -- ── TRAIN A – Compressor K200 (unit_id = 5) ──────────────────────────────
    (11, 'A-K200-PT-001', 'Train A K200 Suction Pressure',          5, 'Pressure',    'bar',      20.0,  35.0,  15.0,  40.0),
    (12, 'A-K200-PT-002', 'Train A K200 Discharge Pressure',        5, 'Pressure',    'bar',      60.0,  80.0,  55.0,  87.0),
    (13, 'A-K200-TT-002', 'Train A K200 Discharge Temperature',     5, 'Temperature', '°C',       60.0, 110.0,  55.0, 120.0),
    (14, 'A-K200-ST-001', 'Train A K200 Shaft Speed',               5, 'RPM',         'RPM',    3200.0,3600.0,2800.0,3800.0),
    (15, 'A-K200-KW-001', 'Train A K200 Power Consumption',         5, 'Power',       'kW',     2500.0,4000.0,2000.0,4500.0),

    -- ── TRAIN A – Compressor K300 (unit_id = 6) ──────────────────────────────
    (16, 'A-K300-PT-001', 'Train A K300 Suction Pressure',          6, 'Pressure',    'bar',      20.0,  35.0,  15.0,  40.0),
    (17, 'A-K300-PT-002', 'Train A K300 Discharge Pressure',        6, 'Pressure',    'bar',      60.0,  80.0,  55.0,  87.0),
    (18, 'A-K300-TT-002', 'Train A K300 Discharge Temperature',     6, 'Temperature', '°C',       60.0, 110.0,  55.0, 120.0),
    (19, 'A-K300-ST-001', 'Train A K300 Shaft Speed',               6, 'RPM',         'RPM',    3200.0,3600.0,2800.0,3800.0),
    (20, 'A-K300-KW-001', 'Train A K300 Power Consumption',         6, 'Power',       'kW',     2500.0,4000.0,2000.0,4500.0),

    -- ── TRAIN A – Export Metering (unit_id = 7) ──────────────────────────────
    (21, 'A-FT-001',      'Train A Export Gas Flow',                7, 'Flow',        'MMSCFD',    2.0,   5.0,   1.5,   5.5),

    -- ── TRAIN B – Gas Separator (unit_id = 9) ────────────────────────────────
    (22, 'B-SEP-PT-001', 'Train B Separator Inlet Pressure',        9, 'Pressure',    'bar',      30.0,  60.0,  25.0,  65.0),
    (23, 'B-SEP-TT-001', 'Train B Separator Inlet Temperature',     9, 'Temperature', '°C',       10.0,  45.0,   5.0,  50.0),
    (24, 'B-SEP-LT-001', 'Train B Separator Liquid Level',          9, 'Level',       '%',        20.0,  80.0,  10.0,  90.0),
    (25, 'B-SEP-FT-001', 'Train B Separator Gas Outlet Flow',       9, 'Flow',        'MMSCFD',    1.5,   4.0,   1.0,   4.5),

    -- ── TRAIN B – Compressor K100 (unit_id = 10) ─────────────────────────────
    (26, 'B-K100-PT-001', 'Train B K100 Suction Pressure',         10, 'Pressure',    'bar',      20.0,  35.0,  15.0,  40.0),
    (27, 'B-K100-PT-002', 'Train B K100 Discharge Pressure',       10, 'Pressure',    'bar',      60.0,  80.0,  55.0,  87.0),
    (28, 'B-K100-TT-001', 'Train B K100 Suction Temperature',      10, 'Temperature', '°C',       15.0,  40.0,  10.0,  50.0),
    (29, 'B-K100-TT-002', 'Train B K100 Discharge Temperature',    10, 'Temperature', '°C',       60.0, 110.0,  55.0, 120.0),
    (30, 'B-K100-ST-001', 'Train B K100 Shaft Speed',              10, 'RPM',         'RPM',    3200.0,3600.0,2800.0,3800.0),
    (31, 'B-K100-KW-001', 'Train B K100 Power Consumption',        10, 'Power',       'kW',     2500.0,4000.0,2000.0,4500.0),

    -- ── TRAIN B – Compressor K200 (unit_id = 11) ─────────────────────────────
    (32, 'B-K200-PT-001', 'Train B K200 Suction Pressure',         11, 'Pressure',    'bar',      20.0,  35.0,  15.0,  40.0),
    (33, 'B-K200-PT-002', 'Train B K200 Discharge Pressure',       11, 'Pressure',    'bar',      60.0,  80.0,  55.0,  87.0),
    (34, 'B-K200-TT-002', 'Train B K200 Discharge Temperature',    11, 'Temperature', '°C',       60.0, 110.0,  55.0, 120.0),
    (35, 'B-K200-ST-001', 'Train B K200 Shaft Speed',              11, 'RPM',         'RPM',    3200.0,3600.0,2800.0,3800.0),
    (36, 'B-K200-KW-001', 'Train B K200 Power Consumption',        11, 'Power',       'kW',     2500.0,4000.0,2000.0,4500.0),

    -- ── TRAIN B – Compressor K300 (unit_id = 12) ─────────────────────────────
    (37, 'B-K300-PT-001', 'Train B K300 Suction Pressure',         12, 'Pressure',    'bar',      20.0,  35.0,  15.0,  40.0),
    (38, 'B-K300-PT-002', 'Train B K300 Discharge Pressure',       12, 'Pressure',    'bar',      60.0,  80.0,  55.0,  87.0),
    (39, 'B-K300-ST-001', 'Train B K300 Shaft Speed',              12, 'RPM',         'RPM',    3200.0,3600.0,2800.0,3800.0),
    (40, 'B-K300-KW-001', 'Train B K300 Power Consumption',        12, 'Power',       'kW',     2500.0,4000.0,2000.0,4500.0);

SET IDENTITY_INSERT dbo.Sensors OFF;
GO

PRINT 'Seed data inserted: 13 process units, 40 sensor tags.';
GO

-- Quick verification
SELECT unit_type, COUNT(*) AS unit_count FROM dbo.ProcessUnits GROUP BY unit_type;
SELECT parameter_type, COUNT(*) AS tag_count FROM dbo.Sensors GROUP BY parameter_type ORDER BY tag_count DESC;
GO
