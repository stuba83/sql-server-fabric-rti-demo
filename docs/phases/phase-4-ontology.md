# Phase 4 — Fabric Ontology + Operations Agent

**Duration:** ~60–90 minutes | **Prerequisite:** Phase 3 complete, Eventhouse working  
**Feature status:** Fabric Ontology and Operations Agent are in **Public Preview** as of Q1 2026

---

## Overview

Phase 4 creates a **digital representation of the LP Gas Plant** as a graph of interconnected objects:

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

Each node in the graph exposes **live telemetry** from the Eventhouse KQL Database.  
The **Operations Agent** uses this graph + live data to answer natural language questions about plant health.

> **Implementation note:** Fabric Ontology (Preview) does **not** support DTDL (Digital Twins Definition Language) import.  
> Entity types are created directly inside the Fabric Ontology editor, bound to data sources (Semantic Model or OneLake).  
> The approach used here: generate ontology from a dedicated Semantic Model backed by `silver_rti` MLV tables.

---

## Step 1 — Create the Ontology Semantic Model

The ontology needs a dedicated Semantic Model with DAX measures — separate from the Power BI reporting model.

1. Open `silver_rti` → switch to **SQL analytics endpoint** view
2. Toolbar → **New semantic model**
3. Name: `GasPlant_Ontology_SM`
4. Storage mode: **Direct Lake on SQL**
5. Select tables (under `dbo`):

   | Table | Source |
   |---|---|
   | `SensorCurrentState` | MLV — latest reading per sensor |
   | `SensorHourlyAgg` | MLV — hourly aggregations |
   | `CompressorKpiHourly` | MLV — compressor KPIs |
   | `Employees` | Dim — plant personnel |
   | `Shifts` | Dim — shift definitions |
   | `ShiftAssignments` | Dim — employee–shift–unit assignments |
   | `EquipmentSpecs` | Dim — equipment specifications |
   | `OperatingLimits` | Dim — design and trip setpoints |

6. **Confirm**

### Add DAX measures

In the model editor, add the following measures to enrich the ontology:

**On `SensorCurrentState` table:**
```dax
Sensors in Alarm =
CALCULATE(
    COUNTROWS(SensorCurrentState),
    SensorCurrentState[alarm_status] IN {"ALARM-H", "ALARM-L"}
)

Sensors Out of Range =
CALCULATE(
    COUNTROWS(SensorCurrentState),
    SensorCurrentState[is_out_of_range] = TRUE()
)
```

**On `CompressorKpiHourly` table:**
```dax
Avg Compression Ratio =
DIVIDE(
    AVERAGEX(CompressorKpiHourly, CompressorKpiHourly[avg_discharge_pressure]),
    AVERAGEX(CompressorKpiHourly, CompressorKpiHourly[avg_suction_pressure])
)
```

**On `SensorHourlyAgg` table:**
```dax
Alarm Rate Last Hour =
CALCULATE(
    SUMX(SensorHourlyAgg, SensorHourlyAgg[alarm_count]),
    TOPN(1, VALUES(SensorHourlyAgg[hour]), SensorHourlyAgg[hour], DESC)
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

## Step 2 — Generate Fabric Ontology from Semantic Model

> **Note:** Fabric Ontology is a Preview feature. Enable it first:  
> Admin Portal → Tenant settings → Ontology (Preview) → Enabled.

1. Open `GasPlant_Ontology_SM` semantic model
2. Ribbon → **Generate Ontology**
3. Workspace: your workspace, Name: `GasPlant_Ontology`
4. **Create** — Fabric generates entity types from all 8 tables automatically

---

## Step 3 — Configure Entity Types

After generation, the ontology editor shows 8 entity types. Configure each:

### SensorCurrentState (rename to `Sensor`)
- Entity type key: `sensor_id`
- Instance display name: `tag_name`
- Verify properties: `sensor_id`, `tag_id`, `tag_name`, `parameter_type`, `value`, `alarm_status`, `is_out_of_range`, `equipment_name`

### SensorHourlyAgg
- Entity type key: `sensor_id`
  > `hour` column (timestamp type) cannot be used as key — Fabric only accepts string/integer keys
- Verify properties include: `avg_value`, `min_value`, `max_value`, `alarm_count`, `reading_count`, `hour`

### CompressorKpiHourly (rename to `Compressor`)
- Entity type key: `equipment_id`
- Instance display name: `equipment_name`
- Verify properties: `equipment_id`, `equipment_name`, `avg_suction_pressure`, `avg_discharge_pressure`, `avg_speed_rpm`, `avg_power_kw`

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
- Verify properties: `equipment_id`, `manufacturer`, `model`, `year_built`, `nominal_power_kw`, `compressor_type`

### OperatingLimits
- Entity type key: `equipment_id`
  > If composite key (equipment_id + parameter_type) is needed, use `equipment_id` alone and treat `parameter_type` as a filterable property.
- Verify properties: `equipment_id`, `parameter_type`, `design_min`, `design_max`, `trip_low`, `trip_high`

---

## Step 4 — Configure Relationships

Add or verify the relationships between entity types:

| Relationship name | From entity | From column | To entity | To column |
|---|---|---|---|---|
| `hasSensorHistory` | `Sensor` | `sensor_id` | `SensorHourlyAgg` | `sensor_id` |
| `assignedToShift` | `ShiftAssignment` | `shift_id` | `Shift` | `id` |
| `assignedToEmployee` | `ShiftAssignment` | `employee_id` | `Employee` | `id` |
| `hasOperatingLimits` | `Equipment` | `equipment_id` | `OperatingLimits` | `equipment_id` |

To add each relationship:
1. Ribbon → **Add relationship**
2. Fill in the From/To entity and column as shown above
3. **Save**

---

## Step 5 — Configure Operations Agent

> The Operations Agent is a generative AI agent that queries the ontology graph using natural language.

1. Fabric workspace → **+ New item → Operations Agent**
2. Name: `Gas Plant Operations Agent`
3. Connect to: `GasPlant_Ontology`

### Define agent context instructions

```
You are an operations assistant for an LP Gas processing plant.
The plant has 2 processing trains (Train A and Train B), each with 3 gas compressors (K100, K200, K300).

Key terminology:
- "pressure" refers to bar gauge unless specified
- "flow" refers to MMSCFD (million standard cubic feet per day)
- "K100", "K200", "K300" are compressor identifiers
- Compression ratio is discharge pressure ÷ suction pressure (normal: 2.0–4.0)
- Alarm types: H = High, HH = High-High, L = Low, LL = Low-Low (ISA-18.2)

When asked about current conditions, use SensorCurrentState data.
When asked about historical trends, use SensorHourlyAgg data.
Always include the timestamp of the data you are reporting.
```

### Test the agent

Try these sample prompts:
1. "What is the current discharge pressure on Train A compressor K100?"
2. "Are there any active alarms right now?"
3. "Which compressor has the highest power consumption in the last hour?"
4. "Has the compression ratio on A-K200 been within normal range today?"
5. "What was the average Train A export flow yesterday?"

---

## Phase 4 Complete ✓

**What you have:**
- `GasPlant_Ontology_SM` semantic model with DAX measures over 8 Silver tables (3 MLVs + 5 dimension tables)
- `GasPlant_Ontology` with 8 entity types (`Sensor`, `SensorHourlyAgg`, `Compressor`, `Employee`, `Shift`, `ShiftAssignment`, `Equipment`, `OperatingLimits`) bound to live Silver data
- Operations Agent answering natural language questions about plant health, personnel, and equipment

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| Ontology binding fails on MLV tables | MLVs registered as external tables (not managed) | Use Direct Lake on SQL storage mode in the semantic model |
| `hour` column not available as entity key | Timestamp type not supported as key | Use `sensor_id` alone as key; `hour` remains a filterable property |
| DTDL import not available | Fabric Ontology (Preview) does not support DTDL | Create entity types manually in the editor or generate from semantic model |
| Generate Ontology button not visible | Ontology Preview not enabled in tenant | Admin Portal → Tenant settings → Ontology (Preview) → Enabled |

**Next:** [Phase 5 — Fabric Data Agent](phase-5-data-agent.md)
