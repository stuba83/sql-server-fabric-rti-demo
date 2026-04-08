# Phase 2 — Medallion Architecture (Bronze → Silver → Gold)

**Duration:** ~45–60 minutes | **Prerequisite:** Phase 1 complete, Mirroring running

---

## Overview

| Layer | Storage | Contents | Updated by |
|---|---|---|---|
| **Bronze** | Mirrored Database | Raw CDC Delta — exact replica of SQL Server | Fabric Mirroring (auto) |
| **Bronze** | `bronze_rti` Lakehouse | OneLake Shortcuts to Mirrored DB tables | You (one-time setup) |
| **Silver** | `silver_rti` Lakehouse | Enriched, type-safe, status-annotated readings | Spark Structured Streaming (always-on) |
| **Gold** | `silver_rti` (MLVs) | Hourly aggregations, current state, compressor KPIs | Fabric Materialized Lake Views (scheduled) |
| **Silver (dims)** | `silver_rti` | Operational dimension tables (Employees, Shifts, EquipmentSpecs, OperatingLimits…) | PySpark seed notebook (one-time) |

> **Why a Bronze Lakehouse intermediary?**  
> See [ADR-001](../../architecture/decisions/001-lakehouse-intermediary-for-eventhouse-acceleration.md).  
> The Eventhouse Query Acceleration engine requires the shortcut to point at a Lakehouse, not directly at a Mirrored Database.

---

## Step 1 — Create Lakehouses

In your Fabric workspace, create **two** items:

| Name | Type |
|---|---|
| `bronze_rti` | Lakehouse |
| `silver_rti` | Lakehouse |

> **Gold layer:** Implemented as native **Materialized Lake Views (MLVs)** inside `silver_rti`. No separate Gold Lakehouse is needed — MLVs are SQL views that materialize on a schedule and expose via the SQL Analytics Endpoint.

---

## Step 2 — Add Shortcuts to Bronze Lakehouse (ADR-001 pattern)

Inside `bronze_rti` → **Tables** section → **+ New shortcut**:

For each of these 6 tables, create a OneLake Shortcut pointing at the corresponding table in your Mirrored Database:

| Shortcut name (in bronze_rti) | Points to (Mirrored Database table) |
|---|---|
| `SensorReadings` | `<MirroredDB>/dbo/SensorReadings` |
| `Alarms` | `<MirroredDB>/dbo/Alarms` |
| `EquipmentStatus` | `<MirroredDB>/dbo/EquipmentStatus` |
| `GasQuality` | `<MirroredDB>/dbo/GasQuality` |
| `ProcessUnits` | `<MirroredDB>/dbo/ProcessUnits` |
| `Sensors` | `<MirroredDB>/dbo/Sensors` |

After adding all shortcuts, you should see 6 tables under `bronze_rti/Tables/`.

### Verify
Click on `bronze_rti` → `SensorReadings` → **Preview** — should show live sensor data.

---

## Step 3 — Run Silver Streaming Notebook

### Import notebook
1. Fabric workspace → **+ New item → Import notebook**
2. Upload `fabric/notebooks/01-silver-streaming.ipynb`

### Attach to bronze_lakehouse
In the notebook, the default lakehouse context should be set. If prompted:
- Top toolbar → **Add lakehouse** → select `bronze_lakehouse` as default
- The notebook resolves paths via `mssparkutils.lakehouse.getProperties()`

### Set parameters
In the **Parameters** cell, set:
```python
BRONZE_LAKEHOUSE = "bronze_rti"
SILVER_LAKEHOUSE = "silver_rti"
PROCESSING_TIME  = "30 seconds"
```

### Run
1. Click **Run all** — the first few cells load reference tables and set up the stream
2. The last cell starts the streaming query and a **60-second monitor loop** (runs 24h, non-blocking)
3. You should see output like:
   ```
   Streaming query started: <uuid>
   [    0s] Waiting for data to arrive            | last batch rows: 0
   [   60s] Processing new data                   | last batch rows: 480
   ```

### Register the table in the Hive metastore (required for MLVs)
The streaming write (`writeStream.start(abfs_path)`) drops Delta files to OneLake but does **not** register the table in the Spark catalog. Without this step, Materialized Lake Views cannot resolve `SensorReadings` by name.

Run cell 8 ("Register table in Hive metastore") once after the first micro-batch:
```python
spark.sql(f"""
    CREATE TABLE IF NOT EXISTS SensorReadings
    USING DELTA
    LOCATION '{silver_path}/Tables/SensorReadings'
""")
```
After running, `SensorReadings` will appear under `dbo` in the SQL Analytics Endpoint.

### Enable Spark Always-On (to keep streaming running)
To prevent the Spark session from expiring:
1. Fabric workspace settings → **Spark compute** → **Session settings**
2. Enable **High Concurrency** mode for the workspace, or
3. Configure the notebook's session settings: keepAliveDuration = `PT2H`

> For a demo, keeping the notebook tab open in the browser is sufficient.

### Verify Silver
In `silver_rti` → Tables → `SensorReadings` → count should grow every 30 seconds.

---

## Step 4 — Create Gold Layer via Materialized Lake Views (MLVs)

Instead of a batch notebook, the Gold layer is implemented as **native Fabric Materialized Lake Views** inside `silver_rti`. MLVs are SQL views that automatically pre-compute and store results on a configurable schedule.

### Create MLV notebook
1. In `silver_rti` → **Manage materialized lake views** (or from the workspace: **+ New item → Notebook**)
2. Set the notebook language to **Spark SQL**
3. Create one cell per MLV:

**SensorCurrentState** — latest reading per sensor:
```sql
CREATE MATERIALIZED LAKE VIEW SensorCurrentState AS
SELECT sr.*
FROM SensorReadings sr
INNER JOIN (
    SELECT sensor_id, MAX(ts) AS max_ts
    FROM SensorReadings
    GROUP BY sensor_id
) latest ON sr.sensor_id = latest.sensor_id AND sr.ts = latest.max_ts
```

**SensorHourlyAgg** — hourly aggregations per sensor:
```sql
CREATE MATERIALIZED LAKE VIEW SensorHourlyAgg AS
SELECT
    sensor_id, tag_id, tag_name, parameter_type, unit_of_measure,
    equipment_id, equipment_name,
    DATE_TRUNC('hour', ts)  AS hour_ts,
    AVG(value)              AS avg_value,
    MIN(value)              AS min_value,
    MAX(value)              AS max_value,
    STDDEV(value)           AS stddev_value,
    COUNT(*)                AS reading_count,
    SUM(CASE WHEN alarm_status IN ('ALARM-H','ALARM-L') THEN 1 ELSE 0 END) AS alarm_count
FROM SensorReadings
GROUP BY sensor_id, tag_id, tag_name, parameter_type, unit_of_measure,
         equipment_id, equipment_name, DATE_TRUNC('hour', ts)
```

**CompressorKpiHourly** — compressor KPIs by hour:
```sql
CREATE MATERIALIZED LAKE VIEW CompressorKpiHourly AS
SELECT
    equipment_id, equipment_name,
    DATE_TRUNC('hour', ts)                                          AS hour_ts,
    AVG(CASE WHEN tag_id LIKE '%-PT-1' THEN value END)              AS avg_suction_pressure,
    AVG(CASE WHEN tag_id LIKE '%-PT-2' THEN value END)              AS avg_discharge_pressure,
    AVG(CASE WHEN tag_id LIKE '%-TT-1' THEN value END)              AS avg_suction_temp,
    AVG(CASE WHEN tag_id LIKE '%-TT-2' THEN value END)              AS avg_discharge_temp,
    AVG(CASE WHEN tag_id LIKE '%-ST'   THEN value END)              AS avg_speed_rpm,
    AVG(CASE WHEN tag_id LIKE '%-KW'   THEN value END)              AS avg_power_kw
FROM SensorReadings
WHERE equipment_type = 'Compressor'
GROUP BY equipment_id, equipment_name, DATE_TRUNC('hour', ts)
```

4. Run all cells. The first run materializes all three views.

### Schedule MLV refresh
From `silver_rti` → **Manage materialized lake views** → **Schedules** → **+ New schedule**:
- Select: Refresh all materialized lake views
- Repeat: **Hourly**, every 1 hour
- Click **Apply**

### Verify
`silver_rti` → Tables → you should see `CompressorKpiHourly`, `SensorCurrentState`, `SensorHourlyAgg` listed as **Materialized lake view** items under `dbo`.

The MLV graph (Manage materialized lake views) should show:
```
dbo.sensorreadings → dbo.compressorkpihourly
                  → dbo.sensorcurrentstate
                  → dbo.sensorhourlyagg
```

> ⚠️ **MLV source error (`MLV_SOURCE_ENTITY_NOT_FOUND`):** If the CREATE fails with this error, it means `SensorReadings` is not registered in the Hive metastore yet. Run the table registration cell in `01-silver-streaming.ipynb` first (see Step 3 above).

---

## Step 5 — Create Semantic Model

1. Open `silver_rti` → switch to **SQL analytics endpoint** view (top-right dropdown)
2. Toolbar → **New semantic model**
3. Name: `GasPlant Silver Model`
4. Storage mode: **Direct Lake on SQL** (not "Direct Lake on OneLake" — MLVs are not accessible via the OneLake path directly)
5. Select tables under `dbo`: `CompressorKpiHourly`, `SensorCurrentState`, `SensorHourlyAgg`
6. Click **Confirm**

In the Model view, define relationships:
- `SensorHourlyAgg.sensor_id` → `SensorCurrentState.sensor_id` (Many:1)

Create a Power BI report:
- Use **Copilot** in the report editor to auto-generate pages based on the model
- Or manually add: line chart of `SensorHourlyAgg.avg_value` by `hour_ts`, table of `SensorCurrentState`

> ⚠️ If the semantic model refresh fails with "source tables do not exist or access was denied", verify you selected **Direct Lake on SQL** (not OneLake) and that the MLVs completed at least one successful run.

---

## Step 6 — Seed Operational Dimension Tables in Silver

The Silver layer also holds **static operational dimension tables** that provide human and equipment context for the ontology and the Operations Agent. These are managed Delta tables written directly into `silver_rti` — no CDC or Mirroring needed.

### Tables created

| Table | Contents |
|---|---|
| `Employees` | Operator, supervisor, and maintenance personnel assigned to the plant |
| `Shifts` | Day (06:00–18:00), Night (18:00–06:00), and Swing shift definitions |
| `ShiftAssignments` | Which employee covers which process unit during which shift period |
| `EquipmentSpecs` | Manufacturer, model, year built, and nominal power for each piece of equipment |
| `OperatingLimits` | Design min/max and trip setpoints for each parameter type per equipment |

### Import and run
1. Fabric workspace → **+ New item → Import notebook**
2. Upload `fabric/notebooks/03-seed-dimension-tables.ipynb`
3. Attach `silver_rti` as the default lakehouse
4. **Run all** — each cell writes one managed Delta table to `silver_rti`

### Verify
`silver_rti` → **Tables** → you should see `Employees`, `Shifts`, `ShiftAssignments`, `EquipmentSpecs`, `OperatingLimits` listed as managed Delta tables under `dbo`.

> These are **one-time seed tables**. Re-run the notebook with `mode("overwrite")` to update data. No streaming or scheduled refresh is required.

---

## Phase 2 Complete ✓

**What you have:**
- `bronze_rti` Lakehouse with 6 shortcut tables (zero storage cost, live CDC data)
- `silver_rti` Lakehouse with enriched, streaming sensor readings (updated every 30 s)
- 3 Materialized Lake Views refreshed hourly: `SensorCurrentState`, `SensorHourlyAgg`, `CompressorKpiHourly`
- 5 operational dimension tables in `silver_rti`: `Employees`, `Shifts`, `ShiftAssignments`, `EquipmentSpecs`, `OperatingLimits`
- DirectLake (SQL) Semantic Model for near-real-time Power BI reports

---

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| MLV error `MLV_SOURCE_ENTITY_NOT_FOUND` | `SensorReadings` not in Hive metastore | Run `CREATE TABLE IF NOT EXISTS SensorReadings USING DELTA LOCATION ...` (cell 8 of streaming notebook) |
| `SensorReadings` appears as "Unidentified" in explorer | Table registered as external via `CREATE TABLE ... LOCATION` | Cosmetic only — table is fully functional under `dbo` in SQL Endpoint |
| Semantic model refresh fails ("source tables do not exist") | Wrong storage mode selected | Re-create semantic model with **Direct Lake on SQL** (not OneLake) |
| MLV creation fails with syntax error | Cell in Spark SQL mode | Ensure the MLV notebook cells are set to **Spark SQL**, not PySpark |
| No rows in Silver after streaming starts | Checkpoint inconsistency from prior run | Delete checkpoint + table files, restart kernel: `mssparkutils.fs.rm(silver_path + '/Files/checkpoints/...', recurse=True)` |

**Next:** [Phase 3 — Real-Time Intelligence (Eventhouse + KQL)](phase-3-rti.md)
