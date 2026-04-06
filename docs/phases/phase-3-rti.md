# Phase 3 — Real-Time Intelligence (Eventhouse + KQL + RTI Dashboard)

**Duration:** ~45 minutes | **Prerequisite:** Phase 2 complete, Bronze Lakehouse shortcuts working

---

## Overview

| Component | Purpose |
|---|---|
| **Eventhouse** | Container for one or more KQL Databases |
| **KQL Database** | Query engine over OneLake shortcuts — supports Query Acceleration |
| **External Tables** | Delta table shortcuts registered as KQL external tables |
| **RTI Dashboard** | Auto-refreshing visualisation tiles backed by KQL queries |

> **Key constraint — ADR-001:** Eventhouse shortcuts must point at the **Bronze Lakehouse**, not directly at the Mirrored Database. See [ADR-001](../../architecture/decisions/001-lakehouse-intermediary-for-eventhouse-acceleration.md) for the full explanation.

---

## Step 1 — Create Eventhouse and KQL Database

1. Fabric workspace → **+ New item → Eventhouse**
2. Name: `GasPlantEventhouse`
3. Fabric automatically creates a KQL Database inside with the same name — rename it to `GasPlantKQL` if desired

---

## Step 2 — Register External Tables

### Get your Bronze Lakehouse IDs

1. Open `bronze_lakehouse` → **Settings** (gear icon on the lakehouse item) or look at the URL:
   ```
   https://app.fabric.microsoft.com/groups/<workspace-id>/lakehouses/<lakehouse-id>
   ```
2. Note: `workspace-id` and `lakehouse-id` (both GUIDs)

### Edit the schema script

Open `fabric/kql/eventhouse-schema.kql` in a text editor and replace all occurrences of:
- `<your-workspace-id>` → your actual workspace GUID
- `<your-bronze-lakehouse-id>` → your actual Bronze Lakehouse GUID

The ABFS path format is:
```
abfss://<workspace-id>@onelake.dfs.fabric.microsoft.com/<lakehouse-id>/Tables/<TableName>
```

### Run the schema script in Fabric

1. Open `GasPlantKQL` database → **Explore your data** (query editor opens)
2. Paste the entire contents of `fabric/kql/eventhouse-schema.kql`
3. Run (Shift+Enter or click Run)
4. Verify: 6 external tables created — `SensorReadings`, `Alarms`, `EquipmentStatus`, `GasQuality`, `Sensors`, `ProcessUnits`

### Quick test

```kql
external_table('SensorReadings')
| take 5
```

Should return rows. If empty, the simulator hasn't run yet — start it.

---

## Step 3 — Verify Query Acceleration

Run a filtered query that benefits from partition pruning:

```kql
external_table('SensorReadings')
| where ts >= ago(1h)
| count
```

In the query results panel → click **Query plan** (or look for the acceleration badge).  
Look for: **"Shortcut Accelerated Query"** — this confirms ADR-001 is working correctly.

If you see `catalog is uninitialized` — your shortcut is pointing directly at the Mirrored Database. Go back and verify the Bronze Lakehouse intermediary is in place.

---

## Step 4 — Run Demo KQL Queries

Import and run the queries from `fabric/kql/sensor-queries.kql`.  
Copy-paste each section into the KQL editor to test:

| Query | Expected result |
|---|---|
| Query 1 — Latest readings | 40 rows, one per sensor with `alarm_status` |
| Query 2 — Time series 2h | Line chart data for all pressure sensors |
| Query 4 — Active alarms | Active unacknowledged alarms |
| Query 9 — Compression ratio | Ratio per compressor (normal: 2.0–4.0) |
| Query 10 — Rate of change | Sensors with pressure rising > 0.5 bar/min |

---

## Step 5 — Create RTI Dashboard

1. Fabric workspace → **+ New item → Real-Time Dashboard**
2. Name: `LP Gas Plant Operations`
3. Click **Add data source** → Select `GasPlantKQL` (KQL Database)

### Add Tile 1 — Current Sensor Status Table

- Tile type: **Table**
- Query (from `sensor-queries.kql` Query 1):
  ```kql
  external_table('SensorReadings')
  | summarize arg_max(ts, value, quality) by sensor_id
  | join kind=inner (external_table('Sensors') | project sensor_id, tag_id, tag_name, parameter_type, unit_of_measure, normal_min, normal_max, alarm_low, alarm_high, equipment_id) on sensor_id
  | join kind=inner (external_table('ProcessUnits') | project unit_id, unit_name) on $left.equipment_id == $right.unit_id
  | extend status = case(isnotnull(alarm_high) and value > alarm_high, "ALARM-H", isnotnull(alarm_low) and value < alarm_low, "ALARM-L", value > normal_max, "HIGH", value < normal_min, "LOW", "NORMAL")
  | project unit_name, tag_id, tag_name, value=round(value,2), unit_of_measure, status, last_updated=ts
  | order by unit_name asc
  ```
- Conditional formatting: status column → color `ALARM-H` = red, `HIGH` = yellow, `NORMAL` = green

### Add Tile 2 — Discharge Pressure Time Series

- Tile type: **Line chart**
- Query (pressure sensors last 2h):
  ```kql
  external_table('SensorReadings')
  | where ts >= ago(2h) and ts <= now()
  | join kind=inner (external_table('Sensors') | where parameter_type == "Pressure") on sensor_id
  | summarize avg_value = avg(value) by bin(ts, 1m), tag_id
  | order by ts asc
  ```
- X-axis: `ts` | Y-axis: `avg_value` | Series: `tag_id`

### Add Tile 3 — Active Alarm Count (KPI Card)

- Tile type: **Stat**
- Query:
  ```kql
  external_table('Alarms')
  | where alarm_time >= ago(24h) and acknowledged == false
  | count
  ```

### Add Tile 4 — Train Export Flow (MMSCFD)

- Tile type: **Line chart**
- Query (from Query 6 in sensor-queries.kql)

### Add Tile 5 — Gas Quality (Methane %)

- Tile type: **Line chart**
- Query (from Query 8 in sensor-queries.kql)

### Set Dashboard Auto-Refresh

- Dashboard settings → **Auto-refresh** → Enable → Interval: **30 seconds**

---

## Step 6 — Add Activator Alert (Optional but Recommended)

Connect Fabric Activator to the Eventhouse for real-time alerting:

1. In the RTI Dashboard → select the alarm tile → **Set alert**
2. Condition: alarm count > 0
3. Action: Send Teams message / Email / Power Automate flow
4. This demonstrates end-to-end operational alerting without writing any code

---

## Phase 3 Complete ✓

**What you have:**
- Eventhouse KQL Database with 6 external tables (Query Acceleration confirmed)
- 10 KQL queries covering: current state, time series, anomaly detection, compression ratio, rate-of-change
- RTI Dashboard auto-refreshing every 30 seconds with live sensor data

**Next:** [Phase 4 — DTDL Ontology + Operations Agent](phase-4-ontology.md)
