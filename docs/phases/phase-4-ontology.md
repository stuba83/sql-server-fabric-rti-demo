# Phase 4 — Fabric Ontology + Operations Agent

**Duration:** ~90–120 minutes | **Prerequisite:** Phase 3 complete, Eventhouse working  
**Feature status:** Fabric Ontology and Operations Agent are in **Public Preview** as of Q1 2026

---

## Overview

Phase 4 creates a **digital representation of the LP Gas Plant** as a graph of interconnected entities exposed to a proactive monitoring agent:

```
GasPlant (1)
 ├── Train A
 │    ├── Separator      ← sensors: pressure, temperature, level, flow
 │    ├── Compressor K100 ← sensors: suction/discharge P, T, RPM, power
 │    ├── Compressor K200 ← sensors: suction/discharge P, T, RPM, power
 │    ├── Compressor K300 ← sensors: suction/discharge P, T, RPM, power
 │    └── Metering        ← sensor: export flow
 └── Train B
      └── ... (same structure)
```

The **Operations Agent** monitors the ontology graph on a schedule, detects anomalies, and sends notifications — it is **not** a chat interface.

> **Implementation notes:**
> - Fabric Ontology (Preview) does **not** support DTDL import — entity types are created directly in the editor.
> - Fabric Ontology does **not** support Eventhouse shortcuts as data sources — only native KQL tables.
> - Ontology entity bindings require a table with **one row per entity instance** (shortcuts pointing at time-series tables result in unbound entities).
> - The approach used here: 5 dimension entity types from `silver_rti` (via SM) + `SensorCurrentState` entity type from a native Eventhouse materialized view + `SensorTelemetry` native table for time series binding.

---

## Step 1 — Prepare Native Eventhouse Tables for Ontology

Fabric Ontology requires **native KQL tables** (not shortcuts/external tables) for data binding. Run the following scripts in your KQL Database query editor (from `eventhouse-schema.kql`):

### 1a — Create SensorTelemetry (native table)

```kql
.create-or-merge table SensorTelemetry (
    reading_id : long,
    sensor_id  : int,
    ts         : datetime,
    value      : real,
    quality    : int
)
```

### 1b — Initial backfill from shortcut

```kql
// Run ONCE to load all available history
.set-or-append SensorTelemetry <|
external_table('SensorReadings')
```

### 1c — Create SensorCurrentState materialized view

```kql
// Auto-maintained by KQL engine — 1 row per sensor_id
.create-or-alter materialized-view with (backfill=true) SensorCurrentState on table SensorTelemetry
{
    SensorTelemetry
    | summarize arg_max(ts, value, quality) by sensor_id
}
```

### 1d — Schedule incremental append (add to pl-watchdog pipeline)

Add a **KQL Script** activity to `pl-watchdog` pointing at your KQL Database:

```kql
.append SensorTelemetry <|
let last_ts = toscalar(SensorTelemetry | summarize max(ts));
external_table('SensorReadings')
| where ts > last_ts
```

---

## Step 2 — Create the Ontology Semantic Model

The SM provides the 5 dimension entity types and DAX measures.

1. Open `silver_rti` → switch to **SQL analytics endpoint** view
2. Toolbar → **New semantic model**
3. Name: `GasPlant_Ontology_SM`
4. Storage mode: **Direct Lake on SQL**
5. Select tables (under `dbo`):

   | Table | Role |
   |---|---|
   | `SensorReadings` | Time series source for DAX measures |
   | `Employees` | Dim — plant personnel |
   | `Shifts` | Dim — shift definitions |
   | `ShiftAssignments` | Dim — employee–shift–unit assignments |
   | `EquipmentSpecs` | Dim — equipment specifications |
   | `OperatingLimits` | Dim — design and trip setpoints |

6. **Confirm**

### Add relationships in SM

| From table | From column | To table | To column | Cardinality |
|---|---|---|---|---|
| `SensorReadings` | `equipment_id` | `EquipmentSpecs` | `equipment_id` | Many:1 |
| `EquipmentSpecs` | `equipment_id` | `OperatingLimits` | `equipment_id` | 1:Many |
| `EquipmentSpecs` | `parent_unit_id` | `ShiftAssignments` | `unit_id` | Many:1 |
| `ShiftAssignments` | `shift_id` | `Shifts` | `id` | Many:1 |
| `ShiftAssignments` | `employee_id` | `Employees` | `id` | Many:1 |

### Add DAX measures

**On `SensorReadings` table:**
```dax
Sensors in Alarm =
CALCULATE(
    DISTINCTCOUNT(SensorReadings[sensor_id]),
    SensorReadings[alarm_status] IN {"ALARM-H", "ALARM-L"}
)

Sensors Out of Range =
CALCULATE(
    DISTINCTCOUNT(SensorReadings[sensor_id]),
    SensorReadings[is_out_of_range] = TRUE()
)
```

**On `Employees` table:**
```dax
Operators on Duty =
CALCULATE(
    COUNTROWS(Employees),
    Employees[role] = "Operator"
)
```

**On `EquipmentSpecs` table:**
```dax
Avg Equipment Age (Years) =
AVERAGEX(
    EquipmentSpecs,
    YEAR(TODAY()) - EquipmentSpecs[year_built]
)
```

---

## Step 3 — Generate Fabric Ontology from Semantic Model

> **Note:** Fabric Ontology is a Preview feature. Enable it first:  
> Admin Portal → Tenant settings → Ontology (Preview) → Enabled.

1. Open `GasPlant_Ontology_SM` semantic model
2. Ribbon → **Generate Ontology**
3. Workspace: your workspace, Name: `GasPlant_Ontology`
4. **Create** — Fabric generates entity types from all 6 SM tables automatically

---

## Step 4 — Configure Entity Types

After generation, configure each entity type:

### SensorReadings — remove from Ontology
- `SensorReadings` is a time-series table — it cannot be used as an entity type (multiple rows per sensor → unbound instances)
- In the Ontology editor: **remove** the `SensorReadings` entity type
- It remains in the SM for DAX measures and SM relationships only

### Employees (rename to `Employee`)
- Entity type key: `id`
- Instance display name: `name`
- Verify properties: `id`, `name`, `role`, `train_assigned`, `shift_preference`, `certifications`

### Shifts (rename to `Shift`)
- Entity type key: `id`
- Instance display name: `name`
- Verify properties: `id`, `name`, `start_hour`, `end_hour`, `days_of_week`

### ShiftAssignments (rename to `ShiftAssignment`)
- Entity type key: `id`
- Verify properties: `id`, `employee_id`, `shift_id`, `unit_id`, `date_start`, `date_end`

### EquipmentSpecs (rename to `Equipment`)
- Entity type key: `equipment_id`
- Verify properties: `equipment_id`, `parent_unit_id`, `manufacturer`, `model`, `year_built`, `nominal_power_kw`, `compressor_type`

### OperatingLimits
- Entity type key: `equipment_id`
  > Composite key (equipment_id + parameter_type) is not supported — use `equipment_id` alone; `parameter_type` is a filterable property.
- Verify properties: `equipment_id`, `parameter_type`, `design_min`, `design_max`, `trip_low`, `trip_high`

### Add Sensor entity type (from Eventhouse)
After configuring the SM-generated types, add a new entity type manually from the Eventhouse:

1. Ontology editor → **+ Add entity type**
2. Data source: your **Eventhouse KQL Database** (not the SM)
3. Table: `SensorCurrentState` (native materialized view)
4. Name: `Sensor`
5. Entity type key: `sensor_id`
6. Verify properties: `sensor_id`, `value`, `quality`, `ts`

### Add time series binding to Sensor
1. Select the `Sensor` entity type
2. **+ Add time series binding**
3. Data source: Eventhouse KQL Database
4. Table: `SensorTelemetry`
5. Entity ID column: `sensor_id`
6. Timestamp column: `ts`
7. Value column: `value`

---

## Step 5 — Configure Relationships

| Relationship name | From entity | From column | To entity | To column |
|---|---|---|---|---|
| `assignedToShift` | `ShiftAssignment` | `shift_id` | `Shift` | `id` |
| `assignedToEmployee` | `ShiftAssignment` | `employee_id` | `Employee` | `id` |
| `hasOperatingLimits` | `Equipment` | `equipment_id` | `OperatingLimits` | `equipment_id` |
| `belongsToUnit` | `Equipment` | `parent_unit_id` | `ShiftAssignment` | `unit_id` |

To add each relationship:
1. Ribbon → **Add relationship**
2. Fill in the From/To entity and column
3. **Save**

---

## Step 6 — Configure Operations Agent

> The Operations Agent is a **proactive monitoring agent** — it evaluates conditions on a schedule and sends notifications. It is not a chat interface.

1. Fabric workspace → **+ New item → Operations Agent**
2. Name: `Gas Plant Operations Agent`
3. Connect to: `GasPlant_Ontology`

### Define monitoring conditions

Configure conditions that trigger notifications:

| Condition name | Entity | Property | Threshold | Notification |
|---|---|---|---|---|
| High alarm count | `Sensor` | `quality` | `> 0 where alarm_status = ALARM-H` | Email / Teams |
| Equipment out of limits | `Sensor` | `value` | exceeds `OperatingLimits.trip_high` | Email / Teams |
| No active shift assignment | `ShiftAssignment` | `date_end` | null or past | Email |

### Agent context description

```
LP Gas plant monitoring agent. Plant has 2 trains (A and B), each with:
- 1 separator, 3 compressors (K100/K200/K300), 1 metering station
- Alarm types: H=High, HH=High-High, L=Low, LL=Low-Low (ISA-18.2)
- Normal compression ratio: 2.0–4.0 (discharge P ÷ suction P)
- Pressures in bar gauge, flow in MMSCFD
```

---

## Phase 4 Complete ✓

**What you have:**
- `GasPlant_Ontology_SM` — Direct Lake SM over `silver_rti`: `SensorReadings` (for DAX) + 5 dimension tables + 5 relationships
- `SensorTelemetry` — native KQL table in Eventhouse, incremental append via `pl-watchdog`
- `SensorCurrentState` — materialized view (auto-maintained), 1 row per sensor
- `GasPlant_Ontology` — 6 entity types: `Sensor` (Eventhouse), `Equipment`, `Employee`, `Shift`, `ShiftAssignment`, `OperatingLimits` (SM); `Sensor` with time series binding to `SensorTelemetry`
- `Gas Plant Operations Agent` — proactive anomaly monitor connected to the ontology

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| Entity instances show as unbound | Data source table has multiple rows per key (time series) | Remove from Ontology; use a materialized view with `arg_max` aggregation instead |
| Ontology binding fails on Eventhouse shortcuts | Shortcuts (external tables) not supported as Ontology data sources | Create native tables and ingest data from shortcuts using `.set-or-append` |
| Materialized view cannot be created on external table | KQL MV only supports native tables as source | Create native `SensorTelemetry` first, then create MV on top of it |
| `parent_unit_id` not visible in SM | SQL endpoint schema cache stale after `overwriteSchema` | Remove and re-add the table in the SM editor to force schema re-read |
| `hour` column not available as entity key | Timestamp type not supported as Ontology key | Use an integer/string column as key; keep `hour` as a filterable property |
| Generate Ontology button not visible | Ontology Preview not enabled in tenant | Admin Portal → Tenant settings → Ontology (Preview) → Enabled |

**Next:** [Phase 5 — Fabric Data Agent](phase-5-data-agent.md)
