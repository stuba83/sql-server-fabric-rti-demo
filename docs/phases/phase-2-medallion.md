# Phase 2 — Medallion Architecture (Bronze → Silver → Gold)

**Duration:** ~45–60 minutes | **Prerequisite:** Phase 1 complete, Mirroring running

---

## Overview

| Layer | Storage | Contents | Updated by |
|---|---|---|---|
| **Bronze** | Mirrored Database | Raw CDC Delta — exact replica of SQL Server | Fabric Mirroring (auto) |
| **Bronze Lakehouse** | Bronze Lakehouse | OneLake Shortcuts to Mirrored DB tables | You (one-time setup) |
| **Silver** | Silver Lakehouse | Enriched, type-safe, status-annotated readings | Spark Structured Streaming (always-on) |
| **Gold** | Gold Lakehouse | Hourly aggregations, current state, compressor KPIs | Spark batch notebook (scheduled) |

> **Why a Bronze Lakehouse intermediary?**  
> See [ADR-001](../../architecture/decisions/001-lakehouse-intermediary-for-eventhouse-acceleration.md).  
> The Eventhouse Query Acceleration engine requires the shortcut to point at a Lakehouse, not directly at a Mirrored Database.

---

## Step 1 — Create Lakehouses

In your Fabric workspace, create three items:

| Name | Type |
|---|---|
| `bronze_lakehouse` | Lakehouse |
| `silver_lakehouse` | Lakehouse |
| `gold_lakehouse` | Lakehouse |

---

## Step 2 — Add Shortcuts to Bronze Lakehouse (ADR-001 pattern)

Inside `bronze_lakehouse` → **Tables** section → **+ New shortcut**:

For each of these 6 tables, create a OneLake Shortcut pointing at the corresponding table in your Mirrored Database:

| Shortcut name (in Bronze Lakehouse) | Points to (Mirrored Database table) |
|---|---|
| `SensorReadings` | `<MirroredDB>/dbo/SensorReadings` |
| `Alarms` | `<MirroredDB>/dbo/Alarms` |
| `EquipmentStatus` | `<MirroredDB>/dbo/EquipmentStatus` |
| `GasQuality` | `<MirroredDB>/dbo/GasQuality` |
| `ProcessUnits` | `<MirroredDB>/dbo/ProcessUnits` |
| `Sensors` | `<MirroredDB>/dbo/Sensors` |

After adding all shortcuts, you should see 6 tables under `bronze_lakehouse/Tables/`.  
These are **metadata-only shortcuts** — no data is copied, no storage cost.

### Verify
Click on `bronze_lakehouse` → `SensorReadings` → **Preview** — should show live sensor data.

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
In the **Parameters** cell (tagged with `parameters`), verify:
```python
BRONZE_LAKEHOUSE = "bronze_lakehouse"
SILVER_LAKEHOUSE = "silver_lakehouse"
PROCESSING_TIME  = "30 seconds"
```

### Run
1. Click **Run all** — the first few cells load reference tables and set up the stream
2. The last cell starts the streaming query with `query.awaitTermination()` — **the notebook stays running**
3. You should see output like:
   ```
   Streaming query started: <uuid>
   Status: {'message': 'Waiting for data to arrive', 'isDataAvailable': False, 'isTriggerActive': False}
   ```

After ~30 seconds (one trigger interval), Silver `SensorReadings` will start receiving rows.

### Enable Spark Always-On (to keep streaming running)
To prevent the Spark session from expiring:
1. Fabric workspace settings → **Spark compute** → **Session settings**
2. Enable **High Concurrency** mode for the workspace, or
3. Configure the notebook's session settings: keepAliveDuration = `PT2H`

> For a demo, keeping the notebook tab open in the browser is sufficient.

### Verify Silver
In `silver_lakehouse` → Tables → `SensorReadings` → count should grow every 30 seconds.  
The Silver table has additional columns vs Bronze: `tag_id`, `tag_name`, `equipment_name`, `alarm_status`, `deviation_pct`, `ingest_ts`.

---

## Step 4 — Run Gold Aggregation Notebook

### Import notebook
Upload `fabric/notebooks/02-gold-mlv.ipynb` into your Fabric workspace.

### Set parameters
```python
SILVER_LAKEHOUSE = "silver_lakehouse"
GOLD_LAKEHOUSE   = "gold_lakehouse"
LOOKBACK_HOURS   = 72
```

### Run
Click **Run all**. This notebook runs as a **batch job** (not streaming).  
Expected duration: 1–2 minutes.

Output summary:
```
=== Gold Layer Summary ===
  SensorHourlyAgg           1,440 rows    (40 sensors × 36 hours)
  SensorCurrentState           40 rows    (one per sensor)
  CompressorKpiHourly         216 rows    (6 compressors × 36 hours)
```

### Schedule the Gold notebook (optional)
For a live demo, schedule it every 15 minutes:
1. Notebook → **Schedule** → Add schedule → every 15 minutes

---

## Step 5 — Create DirectLake Semantic Model

1. Go to `gold_lakehouse` → top toolbar → **New semantic model**
2. Name: `GasPlant Gold Model`
3. Select tables: `SensorHourlyAgg`, `SensorCurrentState`, `CompressorKpiHourly`
4. Click **Confirm**

The semantic model opens in the Model view. Define relationships:
- `SensorHourlyAgg.sensor_id` → `SensorCurrentState.sensor_id` (Many:1)

Create a test Power BI report:
- Line chart: `SensorHourlyAgg.avg_value` by `SensorHourlyAgg.hour`, filtered to `parameter_type = Pressure`
- Table visual: `SensorCurrentState` with `tag_id`, `value`, `alarm_status`

---

## Phase 2 Complete ✓

**What you have:**
- Bronze Lakehouse with 6 shortcut tables (zero storage cost, live CDC data)
- Silver Lakehouse with enriched, streaming sensor readings (updated every 30 s)
- Gold Lakehouse with hourly aggregations and compressor KPIs
- DirectLake Semantic Model for near-real-time Power BI reports

**Next:** [Phase 3 — Real-Time Intelligence (Eventhouse + KQL)](phase-3-rti.md)
