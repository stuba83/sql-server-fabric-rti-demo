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

---

## Step 1 — Review DTDL Models

The DTDL (Digital Twins Definition Language) model files are in `fabric/ontology/dtdl/`:

| File | Interface ID | Represents |
|---|---|---|
| `GasPlant.json` | `dtmi:demo:energyrti:GasPlant;1` | Entire plant; contains Trains |
| `Train.json` | `dtmi:demo:energyrti:Train;1` | Processing train; has Compressors and Sensors |
| `Compressor.json` | `dtmi:demo:energyrti:Compressor;1` | Individual compressor; has Sensors |
| `Sensor.json` | `dtmi:demo:energyrti:Sensor;1` | Instrument tag; telemetry = live value |

### Key design points

- **`TimeSeriesId`** properties (`tagId`, `trainId`, `compressorId`, `plantId`) link the ontology node to its time-series data in the Eventhouse
- **Telemetry** fields represent real-time values; **Properties** represent static metadata
- Relationships form the graph edges: `GasPlant.contains → Train`, `Train.hasCompressor → Compressor`, `Compressor.hasSensor → Sensor`

---

## Step 2 — Create Fabric Ontology Item

> **Note:** Fabric Ontology is a Preview feature. Enable it in your Fabric tenant if not already on.  
> Admin Portal → Tenant settings → Ontology (Preview) → Enabled.

1. Fabric workspace → **+ New item** → search for **Ontology**
2. Name: `GasPlant Ontology`
3. The ontology editor opens

### Upload DTDL models

1. In the ontology editor → **Upload models**
2. Upload all 4 files from `fabric/ontology/dtdl/`:
   - `GasPlant.json`
   - `Train.json`
   - `Compressor.json`
   - `Sensor.json`
3. Fabric validates the JSON and shows the interface graph — verify the 4 interfaces and their relationships are visible

---

## Step 3 — Create Twin Instances

Create one twin instance per piece of equipment. This maps ontology interfaces to real asset IDs.

### In the Ontology item → Instance view:

**GasPlant twin:**
- Interface: `dtmi:demo:energyrti:GasPlant;1`
- `plantId`: `LPGP-001`
- `plantName`: `LP Gas Plant`
- `location`: `Point Lisas Industrial Estate`
- `totalTrains`: `2`

**Train twins (2):**
| Twin ID | trainId | trainName | location |
|---|---|---|---|
| `Train_A` | `Train_A` | `Train A` | `North Processing Pad` |
| `Train_B` | `Train_B` | `Train B` | `South Processing Pad` |

**Compressor twins (6):**
| Twin ID | compressorId | compressorName | nominalRpm |
|---|---|---|---|
| `A_K100` | `A-K100` | `Train A – Compressor K100` | `3400` |
| `A_K200` | `A-K200` | `Train A – Compressor K200` | `3400` |
| `A_K300` | `A-K300` | `Train A – Compressor K300` | `3400` |
| `B_K100` | `B-K100` | `Train B – Compressor K100` | `3400` |
| `B_K200` | `B-K200` | `Train B – Compressor K200` | `3400` |
| `B_K300` | `B-K300` | `Train B – Compressor K300` | `3400` |

**Sensor twins (40):** One per row in `dbo.Sensors`.  
Key mapping example:
| Twin ID | tagId | parameterType | unitOfMeasure |
|---|---|---|---|
| `A_K100_PT_001` | `A-K100-PT-001` | `Pressure` | `bar` |
| `A_K100_TT_002` | `A-K100-TT-002` | `Temperature` | `°C` |
| `A_K100_ST_001` | `A-K100-ST-001` | `RPM` | `RPM` |

### Create relationships

Link twins using the defined relationships:
- `LPGP-001 → contains → Train_A`
- `LPGP-001 → contains → Train_B`
- `Train_A → hasCompressor → A_K100` (and K200, K300)
- `Train_B → hasCompressor → B_K100` (and K200, K300)
- `A_K100 → hasSensor → A_K100_PT_001` (etc.)

---

## Step 4 — Connect Telemetry Source (Eventhouse)

In the Ontology item → **Telemetry source** → **+ Add source**:

1. Source type: **KQL Database**
2. Select: `GasPlantKQL` (your Eventhouse KQL Database)
3. Map telemetry:
   - Ontology field: `Sensor.value` → KQL source: `external_table('SensorReadings')` → field: `value`
   - Join key: `Sensor.tagId` ↔ `Sensors.tag_id` ↔ `SensorReadings.sensor_id`

For historical data queries, also add:
4. Source type: **Lakehouse (SQL Endpoint)**
5. Select: `silver_lakehouse` SQL endpoint
6. This enables the Operations Agent to answer questions about historical data

---

## Step 5 — Configure Operations Agent

> The Operations Agent is a generative AI agent that queries the ontology graph and connected data sources using natural language.

1. Fabric workspace → **+ New item → Operations Agent**
2. Name: `Gas Plant Operations Agent`
3. Connect to: `GasPlant Ontology`

### Define agent context instructions

In the agent configuration, add system instructions:

```
You are an operations assistant for an LP Gas processing plant.
The plant has 2 processing trains (Train A and Train B), each with 3 gas compressors (K100, K200, K300).

Key terminology:
- "pressure" refers to bar gauge unless specified
- "flow" refers to MMSCFD (million standard cubic feet per day)
- "K100", "K200", "K300" are compressor identifiers
- Compression ratio is discharge pressure ÷ suction pressure (normal: 2.0–4.0)
- Alarm types: H = High, HH = High-High, L = Low, LL = Low-Low (ISA-18.2)

When asked about current conditions, query live data from the Eventhouse.
When asked about historical trends (more than 1 hour ago), query from the Silver Lakehouse.
Always include the timestamp of the data you are reporting.
```

### Test the agent

Try these sample prompts:
1. "What is the current discharge pressure on Train A compressor K100?"
2. "Are there any active alarms on Train B right now?"
3. "Which compressor has the highest power consumption in the last hour?"
4. "Has the compression ratio on A-K200 been within normal range today?"
5. "What was the average Train A export flow yesterday?"

---

## Phase 4 Complete ✓

**What you have:**
- DTDL ontology models representing the full plant hierarchy (GasPlant → Train → Compressor → Sensor)
- 40+ twin instances linked by relationships in the Fabric Ontology item
- Live telemetry connected from the Eventhouse KQL Database
- Operations Agent answering natural language questions about real-time plant health

**Next:** [Phase 5 — Fabric Data Agent](phase-5-data-agent.md)
