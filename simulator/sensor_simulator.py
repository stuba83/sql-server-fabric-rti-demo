"""LP Gas Plant IoT Sensor Simulator

Generates realistic sensor data for a SQL Server CDC → Microsoft Fabric Mirroring demo.
Simulates 40 instrument tags (pressure, temperature, flow, RPM, power, level) across
2 LP Gas processing trains with 3 compressors each.

Usage:
    python sensor_simulator.py [--config config.yaml]

Environment variables:
    SQL_CONN_STR    Full ODBC connection string (required — see config.yaml for examples)

The simulator:
    - Reads sensor catalog from dbo.Sensors on first connect
    - Generates per-sensor values (sinusoidal base + Gaussian noise + random anomalies)
    - Inserts readings to dbo.SensorReadings every interval_seconds (default 5 s)
    - Inserts alarm events to dbo.Alarms when thresholds are exceeded
    - Emits dbo.EquipmentStatus rows periodically (default every 5 min)
    - Emits dbo.GasQuality samples hourly
    - Reconnects automatically on transient SQL errors
    - Handles SIGINT / SIGTERM for graceful shutdown
"""

from __future__ import annotations

import argparse
import logging
import math
import os
import random
import signal
import sys
import time
from datetime import datetime, timezone
from typing import List, Optional, Tuple

import pyodbc
import yaml


# ── Graceful shutdown ─────────────────────────────────────────────────────────

_shutdown_requested = False


def _handle_signal(signum: int, frame: object) -> None:
    global _shutdown_requested
    logging.info("Shutdown signal %d received — stopping simulator.", signum)
    _shutdown_requested = True


signal.signal(signal.SIGINT,  _handle_signal)
signal.signal(signal.SIGTERM, _handle_signal)


# ── Configuration ─────────────────────────────────────────────────────────────

def load_config(path: str) -> dict:
    with open(path, encoding="utf-8") as fh:
        cfg = yaml.safe_load(fh)
    return cfg


# ── Database helpers ──────────────────────────────────────────────────────────

def open_connection(config: dict) -> pyodbc.Connection:
    env_var = config["database"]["env_var"]
    conn_str = os.environ.get(env_var)
    if not conn_str:
        raise EnvironmentError(
            f"Environment variable '{env_var}' is not set.\n"
            "Set it to a valid ODBC connection string before running the simulator.\n"
            "See config.yaml for examples."
        )
    return pyodbc.connect(conn_str, autocommit=False, timeout=30)


def fetch_sensors(conn: pyodbc.Connection) -> List[dict]:
    cur = conn.cursor()
    cur.execute(
        """
        SELECT sensor_id, tag_id, parameter_type, unit_of_measure,
               normal_min, normal_max, alarm_low, alarm_high
        FROM   dbo.Sensors
        WHERE  is_active = 1
        ORDER  BY sensor_id
        """
    )
    cols = [c[0] for c in cur.description]
    return [dict(zip(cols, row)) for row in cur.fetchall()]


def fetch_units(conn: pyodbc.Connection) -> List[dict]:
    cur = conn.cursor()
    cur.execute(
        """
        SELECT unit_id, unit_name, unit_type
        FROM   dbo.ProcessUnits
        WHERE  is_active = 1 AND unit_type IN ('Train', 'Compressor')
        ORDER  BY unit_id
        """
    )
    cols = [c[0] for c in cur.description]
    return [dict(zip(cols, row)) for row in cur.fetchall()]


# ── Per-sensor state machine ──────────────────────────────────────────────────

class SensorState:
    """Maintains continuous signal state across simulation ticks.

    Signal model:
        value = midpoint
               + sinusoidal_component (slow cycle ~5 min)
               + random_walk_drift    (bounded)
               + gaussian_noise       (±2 % of range)
               [+ anomaly_spike       (when in_alarm == True)]
    """

    def __init__(self, sensor: dict) -> None:
        self.sensor = sensor
        lo, hi = sensor["normal_min"], sensor["normal_max"]
        mid = (lo + hi) / 2.0
        spread = (hi - lo) * 0.3
        self.value = mid + random.uniform(-spread, spread)
        self.phase = random.uniform(0.0, 2.0 * math.pi)
        self.drift = 0.0
        self.in_alarm = False
        self.alarm_ticks_left = 0

    def tick(self, tick_index: int, config: dict) -> Tuple[float, bool]:
        """Return (reading_value, is_anomaly) for the current tick."""
        s = self.sensor
        lo, hi = s["normal_min"], s["normal_max"]
        mid      = (lo + hi) / 2.0
        half_rng = (hi - lo) / 2.0

        # Sinusoidal component — one full cycle every ~5 minutes at 5 s interval
        period = 60  # ticks
        sine = math.sin(2.0 * math.pi * tick_index / period + self.phase) * half_rng * 0.35

        # Bounded random walk drift (±15 % of half-range)
        self.drift += random.gauss(0.0, half_rng * 0.005)
        self.drift  = max(-half_rng * 0.15, min(half_rng * 0.15, self.drift))

        # Gaussian noise (±2 % of range)
        noise = random.gauss(0.0, half_rng * 0.02)

        value = mid + sine + self.drift + noise
        is_anomaly = False

        anomaly_prob  = config["simulation"]["anomaly_probability"]
        alarm_persist = config["simulation"]["alarm_persist_intervals"]

        if not self.in_alarm and random.random() < anomaly_prob:
            # Spike toward or beyond alarm_high threshold
            ah = s.get("alarm_high") or hi * 1.2
            value = random.uniform(hi * 1.05, max(hi * 1.05 + 1, ah * 0.97))
            is_anomaly = True
            self.in_alarm = True
            self.alarm_ticks_left = max(1, alarm_persist)

        elif self.in_alarm:
            # Sustain near the alarm threshold with noise
            ah = s.get("alarm_high") or hi * 1.2
            value = ah * random.uniform(0.91, 0.97)
            self.alarm_ticks_left -= 1
            if self.alarm_ticks_left <= 0:
                self.in_alarm = False

        # Hard clamp to physically plausible range (50 % outside alarm bounds)
        phys_lo = (s.get("alarm_low")  or lo * 0.5) * 0.5
        phys_hi = (s.get("alarm_high") or hi * 1.5) * 1.5
        value = max(phys_lo, min(phys_hi, value))

        self.value = round(value, 3)
        return self.value, is_anomaly


def opc_quality(is_anomaly: bool) -> int:
    """OPC UA quality code: 192 = Good, 64 = Uncertain."""
    return 64 if is_anomaly else 192


# ── Batch inserts ─────────────────────────────────────────────────────────────

ReadingRow = Tuple[int, datetime, float, int]  # sensor_id, ts, value, quality
AlarmRow   = Tuple[int, str, float, datetime]  # sensor_id, alarm_type, alarm_value, alarm_time


def insert_readings(cursor: pyodbc.Cursor, rows: List[ReadingRow]) -> None:
    cursor.executemany(
        "INSERT INTO dbo.SensorReadings (sensor_id, ts, value, quality) VALUES (?,?,?,?)",
        rows,
    )


def insert_alarms(cursor: pyodbc.Cursor, rows: List[AlarmRow]) -> None:
    cursor.executemany(
        "INSERT INTO dbo.Alarms (sensor_id, alarm_type, alarm_value, alarm_time) VALUES (?,?,?,?)",
        rows,
    )


def insert_equipment_status(
    cursor: pyodbc.Cursor, unit_id: int, status: str, now: datetime
) -> None:
    cursor.execute(
        "INSERT INTO dbo.EquipmentStatus (unit_id, status, event_time) VALUES (?,?,?)",
        (unit_id, status, now),
    )


def insert_gas_quality(
    cursor: pyodbc.Cursor, unit_id: int, cfg: dict, now: datetime
) -> None:
    gq = cfg["gas_quality"]
    cursor.execute(
        """
        INSERT INTO dbo.GasQuality
            (unit_id, sample_time, methane_pct, ethane_pct, propane_pct,
             butane_pct, nitrogen_pct, co2_pct, h2s_ppm, gross_btu, specific_gravity)
        VALUES (?,?,?,?,?,?,?,?,?,?,?)
        """,
        (
            unit_id,
            now,
            round(gq["base_methane_pct"] + random.gauss(0, 0.30), 3),
            round(gq["base_ethane_pct"]  + random.gauss(0, 0.10), 3),
            round(gq["base_propane_pct"] + random.gauss(0, 0.05), 3),
            round(0.80                   + random.gauss(0, 0.04), 3),   # butane
            round(0.50                   + random.gauss(0, 0.03), 3),   # nitrogen
            round(0.20                   + random.gauss(0, 0.02), 3),   # CO2
            round(gq["base_h2s_ppm"]     + random.gauss(0, 0.20), 3),
            round(gq["base_gross_btu"]   + random.gauss(0, 5.00), 1),
            round(0.5880                 + random.gauss(0, 0.002), 4),  # specific gravity
        ),
    )


# ── Main loop ─────────────────────────────────────────────────────────────────

def run(config: dict) -> None:
    sim_cfg = config["simulation"]
    eq_cfg  = config["equipment_status"]
    interval       = sim_cfg["interval_seconds"]
    eq_interval    = eq_cfg["update_interval_seconds"]
    gq_interval    = config["gas_quality"]["sample_interval_seconds"]

    conn    = open_connection(config)
    logging.info("Connected to SQL Server.")

    sensors = fetch_sensors(conn)
    units   = fetch_units(conn)
    if not sensors:
        logging.error(
            "No active sensors found in dbo.Sensors. "
            "Run sql/schema/03-seed-static-data.sql first."
        )
        conn.close()
        sys.exit(1)

    logging.info(
        "Loaded %d sensors and %d process units. Starting simulation (interval=%ds).",
        len(sensors), len(units), interval,
    )

    states      = {s["sensor_id"]: SensorState(s) for s in sensors}
    train_units = [u for u in units if u["unit_type"] == "Train"]

    tick             = 0
    eq_ticks_period  = max(1, eq_interval  // interval)
    gq_ticks_period  = max(1, gq_interval  // interval)
    last_eq_tick     = -eq_ticks_period   # trigger status insert on first tick
    last_gq_tick     = -gq_ticks_period

    while not _shutdown_requested:
        t0  = time.monotonic()
        now = datetime.now(timezone.utc)
        cur = conn.cursor()

        try:
            readings: List[ReadingRow] = []
            alarms:   List[AlarmRow]   = []

            for s in sensors:
                sid   = s["sensor_id"]
                value, is_anomaly = states[sid].tick(tick, config)
                quality = opc_quality(is_anomaly)
                readings.append((sid, now, value, quality))

                # Raise alarms for threshold breaches
                ah = s.get("alarm_high")
                al = s.get("alarm_low")
                if ah is not None and value > ah:
                    alarms.append((sid, "H", value, now))
                elif al is not None and value < al:
                    alarms.append((sid, "L", value, now))

            insert_readings(cur, readings)

            if alarms:
                insert_alarms(cur, alarms)

            # Equipment status (periodic)
            if tick - last_eq_tick >= eq_ticks_period:
                for u in units:
                    status = (
                        "Fault"
                        if random.random() < eq_cfg["fault_probability"]
                        else "Running"
                    )
                    insert_equipment_status(cur, u["unit_id"], status, now)
                last_eq_tick = tick

            # Gas quality (hourly)
            if tick - last_gq_tick >= gq_ticks_period:
                for tu in train_units:
                    insert_gas_quality(cur, tu["unit_id"], config, now)
                last_gq_tick = tick
                logging.info("Gas quality samples inserted at tick %d.", tick)

            conn.commit()
            logging.info(
                "tick=%d | readings=%d alarms=%d | %.3fs",
                tick, len(readings), len(alarms), time.monotonic() - t0,
            )

        except pyodbc.Error as exc:
            logging.error("DB error at tick %d: %s — attempting reconnect.", tick, exc)
            try:
                conn.rollback()
            except Exception:
                pass
            time.sleep(5.0)
            try:
                conn    = open_connection(config)
                sensors = fetch_sensors(conn)
                units   = fetch_units(conn)
                states  = {s["sensor_id"]: SensorState(s) for s in sensors}
                train_units = [u for u in units if u["unit_type"] == "Train"]
                logging.info("Reconnected to SQL Server.")
            except Exception as exc2:
                logging.error("Reconnect failed: %s", exc2)
            tick += 1
            continue

        tick += 1
        elapsed = time.monotonic() - t0
        time.sleep(max(0.0, interval - elapsed))

    logging.info("Simulator stopped cleanly after %d ticks.", tick)
    try:
        conn.close()
    except Exception:
        pass


# ── Entry point ───────────────────────────────────────────────────────────────

def main() -> None:
    parser = argparse.ArgumentParser(
        description="LP Gas Plant IoT Sensor Simulator — SQL Server CDC demo."
    )
    parser.add_argument(
        "--config",
        default="config.yaml",
        help="Path to YAML configuration file (default: %(default)s)",
    )
    args = parser.parse_args()

    cfg       = load_config(args.config)
    log_level = getattr(
        logging,
        cfg.get("logging", {}).get("level", "INFO").upper(),
        logging.INFO,
    )
    logging.basicConfig(
        level=log_level,
        format="%(asctime)s [%(levelname)-8s] %(message)s",
        datefmt="%Y-%m-%dT%H:%M:%S",
    )
    run(cfg)


if __name__ == "__main__":
    main()
