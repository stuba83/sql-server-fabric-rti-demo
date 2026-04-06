# Phase 5 — Fabric Data Agent

**Duration:** ~30 minutes | **Prerequisite:** Phases 2 and 3 complete (Silver + Eventhouse)  
**Feature status:** Fabric Data Agent is **Generally Available** as of Q1 2026

---

## Overview

The **Fabric Data Agent** is a conversational AI agent that can query multiple Fabric data sources simultaneously using natural language. Unlike the Operations Agent (Phase 4, which works through the ontology graph), the Data Agent queries data sources directly via SQL/KQL and synthesises answers.

**Multi-source query capability for this demo:**

| Source | What it answers |
|---|---|
| `GasPlantKQL` (Eventhouse) | Real-time questions: current values, last-N-minutes trends, active alarms |
| `silver_lakehouse` (SQL Endpoint) | Historical analysis: day/week trends, event correlation |
| `gold_lakehouse` (SQL Endpoint) | KPI summaries: hourly aggregations, compressor performance |

---

## Step 1 — Create Fabric Data Agent

1. Fabric workspace → **+ New item → Data agent**
2. Name: `Gas Plant Data Agent`
3. The agent configuration screen opens

---

## Step 2 — Add Data Sources

### Source 1 — Eventhouse KQL Database (real-time)

1. Click **+ Add data source**
2. Select type: **KQL Database**
3. Select: `GasPlantEventhouse > GasPlantKQL`
4. Tables to expose: **select all** (the external tables registered in Phase 3)
5. Click **Add**

### Source 2 — Silver Lakehouse SQL Endpoint (historical)

1. Click **+ Add data source**
2. Select type: **Lakehouse**
3. Select: `silver_lakehouse`
4. Tables: `SensorReadings` (enriched Silver version)
5. Click **Add**

### Source 3 — Gold Lakehouse SQL Endpoint (KPI summaries)

1. Click **+ Add data source**
2. Select type: **Lakehouse**
3. Select: `gold_lakehouse`
4. Tables: `SensorHourlyAgg`, `SensorCurrentState`, `CompressorKpiHourly`
5. Click **Add**

---

## Step 3 — Configure Agent Instructions

In the agent **Instructions** panel, add the following context:

```
You are an AI assistant for an LP Gas plant operations team.

## Data Sources
- GasPlantKQL (Eventhouse): Use for real-time data, current readings, and events within the last few hours. Tables: SensorReadings (live sensor values), Alarms, EquipmentStatus.
- silver_lakehouse: Use for enriched historical sensor data with equipment names and alarm status already computed. Use for queries spanning hours to days. Table: SensorReadings.
- gold_lakehouse: Use for pre-aggregated hourly KPIs. Tables: SensorHourlyAgg (per-sensor hourly stats), SensorCurrentState (current snapshot), CompressorKpiHourly (compressor health metrics).

## Domain Knowledge
- Plant: 2 processing trains (Train A = North Pad, Train B = South Pad)
- Each train has 3 compressors: K100, K200, K300
- Tag naming: <Train>-<Equipment>-<Parameter>-<Sequence>  (e.g. A-K100-PT-001 = Train A, K100, Pressure Transmitter #1)
- Parameter types: Pressure (bar), Temperature (°C), Flow (MMSCFD), RPM, Power (kW), Level (%)
- Compression ratio = discharge pressure ÷ suction pressure; normal range 2.0–4.0
- Alarm types follow ISA-18.2: H = High, HH = High-High, L = Low, LL = Low-Low
- Quality code 192 = Good (OPC UA), 64 = Uncertain

## Answering guidelines
- Always include timestamps / time windows in your answers
- For "current" questions: use Eventhouse KQL first (fresher data)
- For trend questions: use silver_lakehouse for raw trends, gold_lakehouse for hourly summaries
- When multiple sensors are relevant, list them all with their current values
- If a value is outside the normal range, explicitly flag it
```

---

## Step 4 — Verify Agent Capabilities

Use the built-in chat panel in the agent configuration to test these prompts:

### Real-time queries (Eventhouse)
1. "What is the current discharge pressure on all compressors?"
2. "Are there any active unacknowledged alarms right now?"
3. "What is Train B's current export flow in MMSCFD?"
4. "Which sensor has the highest deviation from normal right now?"

### Historical analysis (Silver)
5. "What was the average discharge temperature on Train A K100 yesterday?"
6. "How many alarm events occurred on Train B in the last 24 hours?"
7. "Show me the trend of separator liquid level on Train A over the last 6 hours."

### KPI summaries (Gold)
8. "Which compressor had the highest average power consumption in the last hour?"
9. "What is the compression ratio for each compressor right now?"
10. "Compare the hourly average discharge pressure of K100 on Train A vs Train B over the past 12 hours."

### Cross-source synthesis (advanced)
11. "Is there any correlation between the recent alarm spike on K200 and its compression ratio trend?"
12. "Summarize the overall health of Train A in the last hour."

---

## Step 5 — Publish Agent (Optional)

Make the agent available to other users:

1. Agent configuration → **Publish**
2. Choose audience: workspace members, or specific users
3. Users can access it from: `app.fabric.microsoft.com` → your workspace → Data Agents

### Integration options
- **Teams**: Install the Fabric app in Teams → mention the agent in any channel
- **Copilot Studio**: Import as a custom GPT action with the Agent API endpoint
- **Power Apps**: Embed agent chat in a custom operations app

---

## Demo Scenario: Full End-to-End Walkthrough

Once all 5 phases are complete, here is a suggested demo narrative:

1. **Show the simulator running** — terminal window on VM with tick output
2. **Show Mirroring** — Fabric Mirrored Database with live row counts updating
3. **Show RTI Dashboard** — live pressure and temperature charts auto-refreshing every 30s
4. **Trigger an anomaly** — stop the simulator, modify `anomaly_probability: 0.5` in `config.yaml`, restart → dashboard shows alarm spikes
5. **Show Data Agent** — ask "What alarms are currently active and which compressor is affected?"
6. **Show Operations Agent** — ask "Is Train A operating within normal parameters?"
7. **Show Gold KPI report** — Power BI report with DirectLake compressor hourly KPIs

---

## Phase 5 Complete ✓

**What you have:**
- Fabric Data Agent querying 3 sources: Eventhouse (real-time) + Silver (historical) + Gold (KPIs)
- Natural language access to all LP Gas plant data
- Full end-to-end demo from SQL Server simulator → Mirroring → Medallion → RTI Dashboard → Ontology → AI Agent

## Full Architecture Summary

```
Azure VM
  Python Simulator → SQL Server 2022 (CDC, 40 tags, 5 s interval)
        ↓ VNet Data Gateway (gateway-subnet/10.0.2.0/24)
Fabric Mirrored DB (Bronze CDC Delta, ~15–30 s latency)
        ↓ OneLake Shortcut (ADR-001)
Bronze Lakehouse (meta-only intermediary)
        ↓ OneLake Shortcut               ↓ OneLake Shortcut
Silver (Spark Streaming, 30 s)      Eventhouse KQL DB
        ↓ Batch notebook (15 min)         ↓ KQL queries
Gold MLV (hourly KPIs)              RTI Dashboard (30 s auto-refresh)
        ↓ DirectLake                      ↓ Telemetry
Power BI NRT Reports           Fabric Ontology (DTDL graph)
                                          ↓
                               Operations Agent (natural language)
                                          ↗ ↗
                               Fabric Data Agent (multi-source AI)
```
