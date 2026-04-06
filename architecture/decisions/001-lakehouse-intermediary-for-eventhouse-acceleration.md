# ADR-001 — Lakehouse Intermediary for Eventhouse Query Acceleration

| Attribute | Value |
|---|---|
| **Status** | Accepted |
| **Date** | March 2026 |
| **Validated by** | Personal PAYG Fabric environment |
| **Affects** | Phase 3 — Eventhouse (KQL) setup |

---

## Context

When building a Real-Time Intelligence (RTI) solution on Microsoft Fabric using SQL Server CDC Mirroring as the data source, the natural path is:

```
SQL Server (CDC) → Fabric Mirrored Database (Bronze Delta) → Eventhouse (KQL Database)
```

Eventhouse supports **OneLake Shortcuts** so that KQL external tables can query Delta Parquet files without copying data. Fabric also ships a **Query Acceleration** engine for shortcuts that enables predicate pushdown and partition pruning — significantly speeding up KQL queries over large Delta tables.

The question is: **where should the Eventhouse shortcut point?**

### Option A — Direct Eventhouse → Mirrored Database shortcut (naive path)

```
Eventhouse KQL DB  →  OneLake Shortcut  →  Mirrored Database table (Delta)
```

### Option B — Eventhouse → Bronze Lakehouse → Mirrored Database (intermediary)

```
Eventhouse KQL DB  →  OneLake Shortcut  →  Bronze Lakehouse  →  OneLake Shortcut  →  Mirrored Database table (Delta)
```

---

## Problem

**Option A fails silently for Query Acceleration.**

When an Eventhouse OneLake Shortcut is created that points **directly** at a Mirrored Database Delta table, the KQL queries execute but:

1. The Query Acceleration engine returns a **401 Unauthorized** when attempting to read `_delta_log/_last_checkpoint`.
2. The query plan shows `catalog is uninitialized` — partition pruning and predicate pushdown are **not applied**.
3. Queries run in full-scan mode: all data files are read regardless of filters.

### Root cause

The Fabric Query Acceleration engine uses a different authentication code path than the standard query engine. The Mirrored Database OneLake path does not resolve identity correctly for the acceleration engine's service principal, leading to a 401 on `_delta_log` access.

This is a known limitation as of Q1 2026. The standard query engine works fine; only acceleration is affected.

---

## Decision

**Use Option B: always use a Bronze Lakehouse as an intermediary.**

1. Create a **Bronze Lakehouse** item in the Fabric workspace.
2. Add OneLake Shortcuts inside the Bronze Lakehouse pointing to each Mirrored Database table.
3. Create Eventhouse OneLake Shortcuts pointing to the **Bronze Lakehouse** tables — not to the Mirrored Database directly.

```
Eventhouse
  └── external_table('SensorReadings')
        └── OneLake Shortcut → bronze_lakehouse/Tables/SensorReadings
              └── OneLake Shortcut → MirroredDB/dbo/SensorReadings (Delta)
```

This adds exactly **one extra metadata hop** — no data is copied, no storage cost is incurred. Shortcuts are resolved at query time.

---

## Validation

| Test | Shortcut path | Query Acceleration result |
|---|---|---|
| ✅ Pass | Eventhouse → Bronze Lakehouse → Mirrored DB | **"Shortcut Accelerated Query"** badge shown, 100% completion, predicate pushdown applied |
| ❌ Fail | Eventhouse → Mirrored DB (direct) | 401 on `_delta_log`, `catalog is uninitialized`, full scan |

---

## Consequences

| | |
|---|---|
| ✅ Query Acceleration fully enabled | Predicate pushdown + partition pruning confirmed working via query plan inspection |
| ✅ Zero CU overhead | Shortcuts are metadata-only; Lakehouse intermediary has no storage cost for shortcuts |
| ✅ Fast setup | ~5 minutes to create Bronze Lakehouse and add shortcuts |
| ✅ No data duplication | All three layers (Mirrored DB, Bronze Lakehouse, Eventhouse) point at the same underlying Delta Parquet files in OneLake |
| ⚠ Extra indirection | Two shortcut hops instead of one — minimal operational impact |
| ⚠ May become unnecessary | Microsoft may fix the direct-shortcut 401 in a future Fabric release. Monitor [Fabric release notes](https://learn.microsoft.com/en-us/fabric/release-notes) and validate periodically |

---

## Implementation Checklist

- [ ] Create `bronze_lakehouse` Lakehouse item in Fabric workspace
- [ ] For each Mirrored DB table to expose: add a OneLake Shortcut inside `bronze_lakehouse/Tables/`
- [ ] Run `fabric/kql/eventhouse-schema.kql` — all `.create-or-alter external table` declarations point at the Bronze Lakehouse paths
- [ ] Verify Query Acceleration: run a filtered KQL query (e.g., `where ts >= ago(1h)`) and check the query plan for the **"Shortcut Accelerated Query"** badge in the Fabric query editor
