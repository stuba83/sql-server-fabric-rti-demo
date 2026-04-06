-- =============================================================================
-- 02-create-tables.sql
-- LP Gas Plant schema — ProcessUnits, Sensors, and 4 CDC-tracked tables
--
-- Run AFTER 01-create-database.sql
-- Run BEFORE 03-seed-static-data.sql and infrastructure/scripts/01-enable-cdc.sql
-- =============================================================================

USE GasPlantDB;
GO

-- =============================================================================
-- STATIC REFERENCE TABLES
-- (not tracked by CDC — rarely change; high cardinality lookups)
-- =============================================================================

-- Plant equipment hierarchy: Plant → Train → Compressor / Separator / Meter
CREATE TABLE dbo.ProcessUnits (
    unit_id        INT           NOT NULL IDENTITY(1,1),
    unit_name      NVARCHAR(100) NOT NULL,
    unit_type      NVARCHAR(50)  NOT NULL,      -- Plant | Train | Compressor | Separator | Meter
    parent_unit_id INT           NULL,           -- NULL = top-level plant
    location       NVARCHAR(150) NULL,
    commissioned   DATE          NULL,
    is_active      BIT           NOT NULL CONSTRAINT DF_ProcessUnits_IsActive DEFAULT 1,
    CONSTRAINT PK_ProcessUnits
        PRIMARY KEY CLUSTERED (unit_id),
    CONSTRAINT FK_ProcessUnits_Parent
        FOREIGN KEY (parent_unit_id) REFERENCES dbo.ProcessUnits (unit_id)
);
GO

-- Sensor / instrument tag catalog
CREATE TABLE dbo.Sensors (
    sensor_id       INT           NOT NULL IDENTITY(1,1),
    tag_id          NVARCHAR(50)  NOT NULL,       -- e.g. "A-K100-PT-001"
    tag_name        NVARCHAR(200) NOT NULL,        -- Human-readable description
    equipment_id    INT           NOT NULL,
    parameter_type  NVARCHAR(50)  NOT NULL,        -- Pressure | Temperature | Flow | RPM | Power | Level
    unit_of_measure NVARCHAR(30)  NOT NULL,        -- bar | °C | MMSCFD | RPM | kW | %
    normal_min      FLOAT         NOT NULL,        -- Lower bound of normal operating range
    normal_max      FLOAT         NOT NULL,        -- Upper bound of normal operating range
    alarm_low       FLOAT         NULL,            -- Low alarm setpoint (ISA-18.2 L)
    alarm_high      FLOAT         NULL,            -- High alarm setpoint (ISA-18.2 H)
    is_active       BIT           NOT NULL CONSTRAINT DF_Sensors_IsActive DEFAULT 1,
    CONSTRAINT PK_Sensors
        PRIMARY KEY CLUSTERED (sensor_id),
    CONSTRAINT UQ_Sensors_TagId
        UNIQUE (tag_id),
    CONSTRAINT FK_Sensors_ProcessUnits
        FOREIGN KEY (equipment_id) REFERENCES dbo.ProcessUnits (unit_id)
);
GO

-- =============================================================================
-- CDC-TRACKED TABLES
-- These four tables are replicated via Fabric Mirroring (CDC).
-- All must have explicit primary keys for CDC to work correctly.
-- =============================================================================

-- High-frequency sensor telemetry — the main streaming table
-- The Python simulator inserts one row per sensor per interval (default 5 s).
CREATE TABLE dbo.SensorReadings (
    reading_id  BIGINT          NOT NULL IDENTITY(1,1),
    sensor_id   INT             NOT NULL,
    ts          DATETIME2(3)    NOT NULL,    -- UTC; 3ms precision matches OPC UA
    value       FLOAT           NOT NULL,
    quality     TINYINT         NOT NULL     -- 192 = OPC UA Good, 64 = Uncertain
                CONSTRAINT DF_SensorReadings_Quality DEFAULT 192,
    CONSTRAINT PK_SensorReadings
        PRIMARY KEY CLUSTERED (reading_id),
    CONSTRAINT FK_SensorReadings_Sensors
        FOREIGN KEY (sensor_id) REFERENCES dbo.Sensors (sensor_id)
);
CREATE INDEX IX_SensorReadings_SensorId_Ts
    ON dbo.SensorReadings (sensor_id, ts DESC)
    INCLUDE (value, quality);
GO

-- Equipment on/off state change events
CREATE TABLE dbo.EquipmentStatus (
    event_id    INT             NOT NULL IDENTITY(1,1),
    unit_id     INT             NOT NULL,
    status      NVARCHAR(20)    NOT NULL,   -- Running | Stopped | Fault | Maintenance
    event_time  DATETIME2(3)    NOT NULL
                CONSTRAINT DF_EquipmentStatus_EventTime DEFAULT SYSDATETIME(),
    operator_id NVARCHAR(50)    NULL,       -- Operator who initiated the change
    notes       NVARCHAR(500)   NULL,
    CONSTRAINT PK_EquipmentStatus
        PRIMARY KEY CLUSTERED (event_id),
    CONSTRAINT FK_EquipmentStatus_ProcessUnits
        FOREIGN KEY (unit_id) REFERENCES dbo.ProcessUnits (unit_id)
);
GO

-- Threshold breach alarm events (ISA-18.2 naming: HH, H, L, LL)
CREATE TABLE dbo.Alarms (
    alarm_id        INT             NOT NULL IDENTITY(1,1),
    sensor_id       INT             NOT NULL,
    alarm_type      NVARCHAR(5)     NOT NULL,    -- HH | H | L | LL
    alarm_value     FLOAT           NOT NULL,     -- The value that triggered the alarm
    alarm_time      DATETIME2(3)    NOT NULL
                    CONSTRAINT DF_Alarms_AlarmTime DEFAULT SYSDATETIME(),
    acknowledged    BIT             NOT NULL
                    CONSTRAINT DF_Alarms_Acknowledged DEFAULT 0,
    ack_time        DATETIME2(3)    NULL,
    ack_by          NVARCHAR(50)    NULL,
    CONSTRAINT PK_Alarms
        PRIMARY KEY CLUSTERED (alarm_id),
    CONSTRAINT FK_Alarms_Sensors
        FOREIGN KEY (sensor_id) REFERENCES dbo.Sensors (sensor_id)
);
GO

-- Hourly gas composition samples from chromatograph / composition analyzer
CREATE TABLE dbo.GasQuality (
    sample_id        INT             NOT NULL IDENTITY(1,1),
    unit_id          INT             NOT NULL,
    sample_time      DATETIME2(0)    NOT NULL,   -- Truncated to the hour
    methane_pct      FLOAT           NOT NULL,   -- CH4 %
    ethane_pct       FLOAT           NOT NULL,   -- C2H6 %
    propane_pct      FLOAT           NOT NULL,   -- C3H8 %
    butane_pct       FLOAT           NULL,       -- C4 %
    nitrogen_pct     FLOAT           NULL,       -- N2 %
    co2_pct          FLOAT           NULL,       -- CO2 %
    h2s_ppm          FLOAT           NULL,       -- H2S ppm (sour gas indicator)
    gross_btu        FLOAT           NULL,       -- Gross heating value BTU/scf
    specific_gravity FLOAT           NULL,       -- Gas specific gravity (air = 1.0)
    CONSTRAINT PK_GasQuality
        PRIMARY KEY CLUSTERED (sample_id),
    CONSTRAINT FK_GasQuality_ProcessUnits
        FOREIGN KEY (unit_id) REFERENCES dbo.ProcessUnits (unit_id)
);
GO

PRINT 'Schema created: ProcessUnits, Sensors, SensorReadings, EquipmentStatus, Alarms, GasQuality.';
GO
