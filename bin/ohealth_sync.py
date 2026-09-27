#!/usr/bin/env python3
"""Build the health index the Quickshell window watches.

HealthKit has no cloud API. This script never pretends to fetch one.
An import reads an export once and stores the days in:

  ~/.config/ohealth/ohealth.sqlite

Opening the app, and running this script with no file arguments, reads
that database. It does not open the export again.

Accepted imports are Apple's "Export All Health Data" zip/XML, and JSON
written by Health Auto Export. --sample writes an invented series and
marks it labeledSample so the window can say so.

The window still watches a view of that database (atomic, mode 0600):

  ~/.cache/ohealth/index.json
  ~/.cache/ohealth/status.json
"""

from __future__ import annotations

import argparse
import hashlib
import json
import math
import os
import shutil
import sqlite3
import subprocess
import sys
import threading
import time
import uuid
import zipfile
import xml.etree.ElementTree as ET
from datetime import date, datetime, timedelta, timezone
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from ohealth_paths import (  # noqa: E402
    cache_dir,
    db_path,
    ensure_layout,
    inbox_dir,
    index_path,
    read_config,
    status_path,
    xray_dir,
    document_dir,
    files_path,
    chat_path,
    users_path,
)

RANGES = (
    ("7d", "7 days", 7),
    ("30d", "30 days", 30),
    ("90d", "90 days", 90),
    ("365d", "1 year", 365),
    ("3y", "3 years", 365 * 3),
    ("5y", "5 years", 365 * 5),
    ("all", "All", 0),
)

# Apple Health export quantity identifiers → day field.
SUM_FIELDS = {
    "HKQuantityTypeIdentifierStepCount": "steps",
    "HKQuantityTypeIdentifierActiveEnergyBurned": "activeKcal",
    "HKQuantityTypeIdentifierAppleExerciseTime": "exerciseMin",
    "HKQuantityTypeIdentifierDistanceWalkingRunning": "distanceKm",
}
AVG_FIELDS = {
    "HKQuantityTypeIdentifierHeartRate": "heartRate",
    "HKQuantityTypeIdentifierRestingHeartRate": "restingHr",
    "HKQuantityTypeIdentifierHeartRateVariabilitySDNN": "hrv",
    "HKQuantityTypeIdentifierOxygenSaturation": "spo2",
    "HKQuantityTypeIdentifierRespiratoryRate": "respiratory",
}
LAST_FIELDS = {
    "HKQuantityTypeIdentifierBodyMass": "weightKg",
}
ASLEEP = {1, 3, 4, 5}  # unspecified, core, deep, REM — not in-bed, not awake

# Health Auto Export metric names → day field.
HAE_SUM = {
    "step_count": "steps",
    "steps": "steps",
    "active_energy": "activeKcal",
    "active_energy_burned": "activeKcal",
    "apple_exercise_time": "exerciseMin",
    "exercise_time": "exerciseMin",
    "walking_running_distance": "distanceKm",
    "distance_walking_running": "distanceKm",
}
HAE_AVG = {
    "heart_rate": "heartRate",
    "resting_heart_rate": "restingHr",
    "heart_rate_variability": "hrv",
    "heart_rate_variability_sdnn": "hrv",
    "blood_oxygen_saturation": "spo2",
    "oxygen_saturation": "spo2",
    "respiratory_rate": "respiratory",
}
HAE_LAST = {
    "body_mass": "weightKg",
    "weight": "weightKg",
    "weight_body_mass": "weightKg",
}

METRICS = (
    {"id": "steps", "group": "activity", "name": "Steps", "unit": "count", "kind": "avg", "favorable": "up", "digits": 0},
    {"id": "activeKcal", "group": "activity", "name": "Active energy", "unit": "kcal", "kind": "avg", "favorable": "up", "digits": 0},
    {"id": "exerciseMin", "group": "activity", "name": "Exercise", "unit": "min", "kind": "avg", "favorable": "up", "digits": 0},
    {"id": "distanceKm", "group": "activity", "name": "Walking + running", "unit": "km", "kind": "avg", "favorable": "up", "digits": 1},
    {"id": "sleepHours", "group": "activity", "name": "Sleep", "unit": "h", "kind": "avg", "favorable": "band", "band": (7.0, 9.0), "digits": 1},
    {"id": "restingHr", "group": "vitals", "name": "Resting heart rate", "unit": "bpm", "kind": "avg", "favorable": "down", "digits": 0},
    {"id": "heartRate", "group": "vitals", "name": "Heart rate", "unit": "bpm", "kind": "avg", "favorable": "band", "band": (55.0, 100.0), "digits": 0},
    {"id": "hrv", "group": "vitals", "name": "Heart rate variability", "unit": "ms", "kind": "avg", "favorable": "up", "digits": 0},
    {"id": "spo2", "group": "vitals", "name": "Blood oxygen", "unit": "%", "kind": "avg", "favorable": "band", "band": (95.0, 100.0), "digits": 0},
    {"id": "respiratory", "group": "vitals", "name": "Respiratory rate", "unit": "/min", "kind": "avg", "favorable": "band", "band": (12.0, 20.0), "digits": 0},
    {"id": "weightKg", "group": "vitals", "name": "Weight", "unit": "kg", "kind": "last", "favorable": "flat", "digits": 1},
)

SUMMARY_IDS = ("steps", "sleepHours", "restingHr", "hrv")
DAY_FIELDS = tuple(spec["id"] for spec in METRICS)


def now_iso() -> str:
    return datetime.now(timezone.utc).replace(microsecond=0).isoformat()


def write_json(path: Path, payload: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(path.suffix + ".tmp")
    tmp.write_text(json.dumps(payload, indent=2) + "\n")
    os.chmod(tmp, 0o600)
    tmp.replace(path)


def write_status(state: str, message: str, **extra) -> None:
    body = {"state": state, "message": message, "at": now_iso(), **extra}
    if "database" not in body:
        body["database"] = str(selected_db_path())
    if "user" not in body:
        try:
            uid, name = current_person()
        except Exception:
            uid, name = "", ""
        body["user"] = uid
        body["userName"] = name
    write_json(status_path(), body)


def _open_sqlite(path: Path) -> sqlite3.Connection:
    path.parent.mkdir(parents=True, exist_ok=True)
    os.chmod(path.parent, 0o700)
    conn = sqlite3.connect(path)
    conn.row_factory = sqlite3.Row
    conn.execute("PRAGMA journal_mode=DELETE")
    return conn


USER_META_KEYS = (
    "stored",
    "source",
    "sourceDetail",
    "labeledSample",
    "exportedAt",
    "appleId",
    "rangeId",
    "rangeStart",
    "rangeEnd",
)


def _table_exists(conn: sqlite3.Connection, name: str) -> bool:
    row = conn.execute(
        "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ?",
        (name,),
    ).fetchone()
    return row is not None


def _columns(conn: sqlite3.Connection, name: str) -> list[str]:
    if not _table_exists(conn, name):
        return []
    return [row["name"] for row in conn.execute(f"PRAGMA table_info({name})")]


def _create_tables(conn: sqlite3.Connection) -> None:
    columns = ", ".join(f"{name} REAL" for name in DAY_FIELDS)
    conn.execute(
        "CREATE TABLE IF NOT EXISTS days ("
        "user_id TEXT NOT NULL, date TEXT NOT NULL, "
        f"{columns}, PRIMARY KEY (user_id, date))"
    )
    conn.execute("CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT NOT NULL)")
    conn.execute(
        """
        CREATE TABLE IF NOT EXISTS users (
          id TEXT PRIMARY KEY,
          name TEXT NOT NULL,
          created_at TEXT NOT NULL
        )
        """
    )
    conn.execute(
        """
        CREATE TABLE IF NOT EXISTS user_meta (
          user_id TEXT NOT NULL,
          key TEXT NOT NULL,
          value TEXT NOT NULL,
          PRIMARY KEY (user_id, key)
        )
        """
    )
    conn.execute(
        """
        CREATE TABLE IF NOT EXISTS samples (
          user_id TEXT NOT NULL,
          id TEXT NOT NULL,
          day TEXT NOT NULL,
          field TEXT NOT NULL,
          op TEXT NOT NULL,
          value REAL NOT NULL,
          at TEXT NOT NULL,
          PRIMARY KEY (user_id, id)
        )
        """
    )
    conn.execute("CREATE INDEX IF NOT EXISTS samples_user_day ON samples(user_id, day)")
    conn.execute(
        """
        CREATE TABLE IF NOT EXISTS files (
          id TEXT PRIMARY KEY,
          user_id TEXT NOT NULL,
          kind TEXT NOT NULL,
          name TEXT NOT NULL,
          path TEXT NOT NULL,
          added_at TEXT NOT NULL
        )
        """
    )
    conn.execute("CREATE INDEX IF NOT EXISTS files_user ON files(user_id)")
    conn.execute(
        """
        CREATE TABLE IF NOT EXISTS chat (
          id INTEGER PRIMARY KEY,
          user_id TEXT NOT NULL,
          role TEXT NOT NULL,
          agent TEXT NOT NULL,
          scope TEXT NOT NULL,
          body TEXT NOT NULL,
          at TEXT NOT NULL
        )
        """
    )
    conn.execute("CREATE INDEX IF NOT EXISTS chat_user ON chat(user_id)")
    conn.execute(
        """
        CREATE TABLE IF NOT EXISTS severity (
          user_id TEXT NOT NULL,
          field TEXT NOT NULL,
          date TEXT NOT NULL,
          value TEXT NOT NULL,
          level TEXT NOT NULL,
          PRIMARY KEY (user_id, field, date)
        )
        """
    )


def _needs_owner(conn: sqlite3.Connection) -> bool:
    for table in ("days", "samples", "files", "chat"):
        if _table_exists(conn, table) and conn.execute(f"SELECT 1 FROM {table} LIMIT 1").fetchone():
            return True
    if _table_exists(conn, "meta"):
        stored = conn.execute("SELECT value FROM meta WHERE key = 'stored'").fetchone()
        if stored is not None and stored["value"] == "1":
            return True
    return False


def _legacy_owner(conn: sqlite3.Connection) -> str:
    """Attach rows saved before people existed to one person."""
    row = conn.execute("SELECT id FROM users LIMIT 1").fetchone()
    if row:
        return row["id"]
    apple = conn.execute("SELECT value FROM meta WHERE key = 'appleId'").fetchone() if _table_exists(conn, "meta") else None
    name = (apple["value"] if apple else "").strip() or "Existing"
    uid = uuid.uuid4().hex
    conn.execute(
        "INSERT INTO users (id, name, created_at) VALUES (?, ?, ?)",
        (uid, name, now_iso()),
    )
    if _table_exists(conn, "meta"):
        saved = {record["key"]: record["value"] for record in conn.execute("SELECT key, value FROM meta")}
        for key in USER_META_KEYS:
            if key in saved:
                conn.execute(
                    "INSERT INTO user_meta (user_id, key, value) VALUES (?, ?, ?)",
                    (uid, key, saved[key]),
                )
    return uid


def _rebuild_days(conn: sqlite3.Connection, owner: str) -> None:
    columns = ", ".join(f"{name} REAL" for name in DAY_FIELDS)
    listed = ", ".join(DAY_FIELDS)
    conn.execute(
        "CREATE TABLE days_next ("
        "user_id TEXT NOT NULL, date TEXT NOT NULL, "
        f"{columns}, PRIMARY KEY (user_id, date))"
    )
    conn.execute(
        f"INSERT INTO days_next (user_id, date, {listed}) SELECT ?, date, {listed} FROM days",
        (owner,),
    )
    conn.execute("DROP TABLE days")
    conn.execute("ALTER TABLE days_next RENAME TO days")


def _rebuild_samples(conn: sqlite3.Connection, owner: str) -> None:
    conn.execute("DROP INDEX IF EXISTS samples_day")
    conn.execute(
        """
        CREATE TABLE samples_next (
          user_id TEXT NOT NULL,
          id TEXT NOT NULL,
          day TEXT NOT NULL,
          field TEXT NOT NULL,
          op TEXT NOT NULL,
          value REAL NOT NULL,
          at TEXT NOT NULL,
          PRIMARY KEY (user_id, id)
        )
        """
    )
    conn.execute(
        """
        INSERT INTO samples_next (user_id, id, day, field, op, value, at)
        SELECT ?, id, day, field, op, value, at FROM samples
        """,
        (owner,),
    )
    conn.execute("DROP TABLE samples")
    conn.execute("ALTER TABLE samples_next RENAME TO samples")


def _claim_column(conn: sqlite3.Connection, table: str, owner: str) -> None:
    if "user_id" in _columns(conn, table):
        return
    conn.execute(f"ALTER TABLE {table} ADD COLUMN user_id TEXT NOT NULL DEFAULT ''")
    conn.execute(f"UPDATE {table} SET user_id = ? WHERE user_id = ''", (owner,))


def _ensure_schema(conn: sqlite3.Connection) -> None:
    legacy_days = _table_exists(conn, "days") and "user_id" not in _columns(conn, "days")
    legacy_samples = _table_exists(conn, "samples") and "user_id" not in _columns(conn, "samples")
    legacy_files = _table_exists(conn, "files") and "user_id" not in _columns(conn, "files")
    legacy_chat = _table_exists(conn, "chat") and "user_id" not in _columns(conn, "chat")
    conn.execute("CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT NOT NULL)")
    conn.execute(
        """
        CREATE TABLE IF NOT EXISTS users (
          id TEXT PRIMARY KEY,
          name TEXT NOT NULL,
          created_at TEXT NOT NULL
        )
        """
    )
    conn.execute(
        """
        CREATE TABLE IF NOT EXISTS user_meta (
          user_id TEXT NOT NULL,
          key TEXT NOT NULL,
          value TEXT NOT NULL,
          PRIMARY KEY (user_id, key)
        )
        """
    )
    owner = _legacy_owner(conn) if (legacy_days or legacy_samples or legacy_files or legacy_chat) and _needs_owner(conn) else ""
    if legacy_days:
        if owner:
            _rebuild_days(conn, owner)
        else:
            conn.execute("DROP TABLE days")
    if legacy_samples:
        if owner:
            _rebuild_samples(conn, owner)
        else:
            conn.execute("DROP INDEX IF EXISTS samples_day")
            conn.execute("DROP TABLE samples")
    if legacy_files:
        if owner:
            _claim_column(conn, "files", owner)
        else:
            conn.execute("DROP TABLE files")
    if legacy_chat:
        if owner:
            _claim_column(conn, "chat", owner)
        else:
            conn.execute("DROP TABLE chat")
    _create_tables(conn)
    conn.commit()


def selected_db_path() -> Path:
    """The database the window reads. The choice is stored in the OHealth database."""
    catalog = db_path()
    conn = _open_sqlite(catalog)
    try:
        conn.execute("CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT NOT NULL)")
        row = conn.execute("SELECT value FROM meta WHERE key = 'database'").fetchone()
        chosen = (row["value"] if row else "").strip()
        if not chosen:
            chosen = str(catalog)
            conn.execute(
                "INSERT INTO meta (key, value) VALUES ('database', ?) "
                "ON CONFLICT(key) DO UPDATE SET value = excluded.value",
                (chosen,),
            )
            conn.commit()
    finally:
        conn.close()
    os.chmod(catalog, 0o600)
    return Path(chosen)


def set_selected_database(path: Path) -> None:
    chosen = Path(os.path.expanduser(str(path))).resolve()
    if chosen.suffix.lower() not in {".sqlite", ".db"}:
        raise ValueError("Choose a database file ending in .sqlite")
    chosen.parent.mkdir(parents=True, exist_ok=True)
    catalog = db_path()
    conn = _open_sqlite(catalog)
    try:
        conn.execute("CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT NOT NULL)")
        conn.execute(
            "INSERT INTO meta (key, value) VALUES ('database', ?) "
            "ON CONFLICT(key) DO UPDATE SET value = excluded.value",
            (str(chosen),),
        )
        conn.commit()
    finally:
        conn.close()
    os.chmod(catalog, 0o600)
    health = connect_db()
    health.close()


def connect_db() -> sqlite3.Connection:
    """Local health store. One file, mode 0600, no leftover WAL sidecar."""
    path = selected_db_path()
    conn = _open_sqlite(path)
    _ensure_schema(conn)
    os.chmod(path, 0o600)
    return conn


def current_user_row(conn: sqlite3.Connection) -> sqlite3.Row | None:
    row = conn.execute("SELECT value FROM meta WHERE key = 'user'").fetchone()
    uid = (row["value"] if row else "").strip()
    if not uid:
        return None
    return conn.execute("SELECT id, name FROM users WHERE id = ?", (uid,)).fetchone()


def current_person() -> tuple[str, str]:
    conn = connect_db()
    try:
        row = current_user_row(conn)
        if row is None:
            return "", ""
        return row["id"], row["name"]
    finally:
        conn.close()


def require_user(conn: sqlite3.Connection) -> sqlite3.Row:
    row = current_user_row(conn)
    if row is None:
        raise ValueError("Choose a person before importing.")
    return row


def save_user_meta(conn: sqlite3.Connection, user_id: str, meta: dict[str, str]) -> None:
    for key, value in meta.items():
        conn.execute(
            "INSERT INTO user_meta (user_id, key, value) VALUES (?, ?, ?) "
            "ON CONFLICT(user_id, key) DO UPDATE SET value = excluded.value",
            (user_id, key, value),
        )


def list_users() -> list[dict]:
    conn = connect_db()
    try:
        return [
            {"id": row["id"], "name": row["name"]}
            for row in conn.execute("SELECT id, name FROM users ORDER BY name COLLATE NOCASE, created_at")
        ]
    finally:
        conn.close()


def publish_users() -> None:
    conn = connect_db()
    try:
        people = [
            {"id": row["id"], "name": row["name"]}
            for row in conn.execute("SELECT id, name FROM users ORDER BY name COLLATE NOCASE, created_at")
        ]
        person = current_user_row(conn)
    finally:
        conn.close()
    write_json(users_path(), {
        "users": people,
        "current": person["id"] if person else "",
        "currentName": person["name"] if person else "",
    })


def add_user(name: str) -> dict:
    cleaned = " ".join(name.split())
    if not cleaned:
        raise ValueError("Enter a name.")
    conn = connect_db()
    try:
        taken = conn.execute(
            "SELECT name FROM users WHERE lower(name) = lower(?)",
            (cleaned,),
        ).fetchone()
        if taken:
            raise ValueError(f"{taken['name']} is already in this database.")
        uid = uuid.uuid4().hex
        conn.execute(
            "INSERT INTO users (id, name, created_at) VALUES (?, ?, ?)",
            (uid, cleaned, now_iso()),
        )
        conn.commit()
    finally:
        conn.close()
    publish_users()
    return {"id": uid, "name": cleaned}


def _path_is_inside(path: Path, root: Path) -> bool:
    try:
        path.resolve().relative_to(root.resolve())
    except (OSError, ValueError):
        return False
    return True


def _remove_person_files(user_id: str, paths: list[str]) -> None:
    if not user_id or user_id in {".", ".."} or "/" in user_id or "\\" in user_id:
        return
    roots = (xray_dir(), document_dir())
    for raw in paths:
        candidate = Path(raw)
        if any(_path_is_inside(candidate, root) for root in roots) and candidate.is_file():
            candidate.unlink()
    for folder in (xray_dir() / user_id, document_dir() / user_id):
        if folder.is_dir():
            shutil.rmtree(folder)


def delete_user(user_id: str) -> bool:
    """Remove one person, their health rows, chat, and imported files.

    Returns True when that person was the one the database was opened as.
    """
    conn = connect_db()
    paths: list[str] = []
    was_current = False
    uid = ""
    try:
        row = conn.execute("SELECT id FROM users WHERE id = ?", (user_id.strip(),)).fetchone()
        if row is None:
            raise ValueError("That person is not in this database.")
        uid = row["id"]
        paths = [item["path"] for item in conn.execute("SELECT path FROM files WHERE user_id = ?", (uid,))]
        current = current_user_row(conn)
        was_current = current is not None and current["id"] == uid
        for table in ("days", "samples", "user_meta", "files", "chat", "severity"):
            conn.execute(f"DELETE FROM {table} WHERE user_id = ?", (uid,))
        conn.execute("DELETE FROM users WHERE id = ?", (uid,))
        if was_current:
            conn.execute("DELETE FROM meta WHERE key = 'user'")
        conn.commit()
    finally:
        conn.close()
    _remove_person_files(uid, paths)
    publish_users()
    return was_current


def set_current_user(user_id: str) -> None:
    conn = connect_db()
    try:
        row = conn.execute("SELECT id, name FROM users WHERE id = ?", (user_id,)).fetchone()
        if row is None:
            raise ValueError("That person is not in this database.")
        save_meta(conn, {"user": row["id"]})
        conn.commit()
    finally:
        conn.close()
    publish_users()


def store_days(
    rows: list[dict],
    *,
    source: str,
    source_detail: str,
    labeled_sample: bool,
    exported_at: str | None,
    apple_id: str,
) -> None:
    """Replace this person's saved days with this import."""
    conn = connect_db()
    names = ", ".join(["user_id", "date", *DAY_FIELDS])
    marks = ", ".join("?" for _ in range(2 + len(DAY_FIELDS)))
    meta = {
        "stored": "1",
        "source": source,
        "sourceDetail": source_detail,
        "labeledSample": "1" if labeled_sample else "0",
        "exportedAt": exported_at or "",
        "appleId": apple_id or "",
    }
    try:
        with conn:
            person = require_user(conn)
            conn.execute("DELETE FROM days WHERE user_id = ?", (person["id"],))
            conn.execute("DELETE FROM samples WHERE user_id = ?", (person["id"],))
            for row in rows:
                values: list = [person["id"], row["date"]]
                for field in DAY_FIELDS:
                    value = row.get(field)
                    values.append(None if value is None else float(value))
                conn.execute(f"INSERT INTO days ({names}) VALUES ({marks})", values)
            save_user_meta(conn, person["id"], meta)
    finally:
        conn.close()


def load_days() -> tuple[list[dict], dict[str, str]]:
    conn = connect_db()
    try:
        meta = {
            row["key"]: row["value"]
            for row in conn.execute("SELECT key, value FROM meta")
            if row["key"] not in USER_META_KEYS
        }
        person = current_user_row(conn)
        if person is None:
            meta["user"] = ""
            meta["userName"] = ""
            return [], meta
        meta["user"] = person["id"]
        meta["userName"] = person["name"]
        for row in conn.execute("SELECT key, value FROM user_meta WHERE user_id = ?", (person["id"],)):
            meta[row["key"]] = row["value"]
        rows: list[dict] = []
        query = "SELECT date, " + ", ".join(DAY_FIELDS) + " FROM days WHERE user_id = ? ORDER BY date"
        for record in conn.execute(query, (person["id"],)):
            row: dict = {"date": record["date"]}
            for field in DAY_FIELDS:
                value = record[field]
                if value is not None:
                    row[field] = float(value)
            rows.append(row)
        return rows, meta
    finally:
        conn.close()


def parse_apple_dt(value: str) -> datetime | None:
    value = (value or "").strip()
    for fmt in ("%Y-%m-%d %H:%M:%S %z", "%Y-%m-%d %H:%M:%S"):
        try:
            return datetime.strptime(value, fmt)
        except ValueError:
            continue
    return None


def day_key(when: datetime) -> str:
    return when.date().isoformat()


def convert_quantity(field: str, value: float, unit: str) -> float:
    unit = (unit or "").lower()
    if field == "distanceKm" and unit in {"mi", "mile", "miles"}:
        return value * 1.609344
    if field == "weightKg" and unit in {"lb", "lbs", "pound", "pounds"}:
        return value * 0.45359237
    if field == "spo2" and value <= 1.5:
        return value * 100.0
    if field == "activeKcal" and unit in {"kj", "kilojoule", "kilojoules"}:
        return value / 4.184
    return value


class DayBucket:
    def __init__(self) -> None:
        self.sums: dict[str, float] = {}
        self.avg_sum: dict[str, float] = {}
        self.avg_n: dict[str, int] = {}
        self.last: dict[str, tuple[datetime, float]] = {}
        self.sleep_hours = 0.0
        self.sleep_n = 0

    def add_sum(self, field: str, value: float) -> None:
        self.sums[field] = self.sums.get(field, 0.0) + value

    def add_avg(self, field: str, value: float) -> None:
        self.avg_sum[field] = self.avg_sum.get(field, 0.0) + value
        self.avg_n[field] = self.avg_n.get(field, 0) + 1

    def add_last(self, field: str, when: datetime, value: float) -> None:
        prev = self.last.get(field)
        if prev is None or when >= prev[0]:
            self.last[field] = (when, value)

    def add_sleep(self, hours: float) -> None:
        if hours <= 0:
            return
        self.sleep_hours += hours
        self.sleep_n += 1

    def as_dict(self, day: str) -> dict:
        row: dict = {"date": day}
        for field, total in self.sums.items():
            row[field] = round(total, 3)
        for field, total in self.avg_sum.items():
            n = self.avg_n.get(field, 0)
            if n:
                row[field] = round(total / n, 3)
        for field, (_when, value) in self.last.items():
            row[field] = round(value, 3)
        if self.sleep_n:
            row["sleepHours"] = round(self.sleep_hours, 3)
        return row


def sample_id(op: str, field: str, start: str, end: str, unit: str) -> str:
    """Same health record, even when a later export repeats it."""
    raw = f"{op}|{field}|{start}|{end}|{unit}"
    return hashlib.sha1(raw.encode()).hexdigest()


def emit_sample(emit, op: str, field: str, start: str, end: str, unit: str, day: str, value: float, at: datetime) -> None:
    emit({
        "id": sample_id(op, field, start, end, unit),
        "day": day,
        "field": field,
        "op": op,
        "value": value,
        "at": at.isoformat(),
    })


def parse_export_xml(path: Path, emit) -> str | None:
    exported_at = None
    context = ET.iterparse(path, events=("start", "end"))
    _event, root = next(context)
    for event, elem in context:
        if event != "end":
            continue
        tag = elem.tag
        if tag == "ExportDate":
            exported_at = elem.attrib.get("value")
            root.clear()
            continue
        if tag != "Record":
            continue
        kind = elem.attrib.get("type", "")
        start_raw = elem.attrib.get("startDate", "")
        end_raw = elem.attrib.get("endDate", "") or start_raw
        start = parse_apple_dt(start_raw)
        end = parse_apple_dt(end_raw) or start
        if start is None:
            root.clear()
            continue
        unit = elem.attrib.get("unit", "")
        if kind == "HKCategoryTypeIdentifierSleepAnalysis":
            try:
                category = int(float(elem.attrib.get("value", "nan")))
            except ValueError:
                category = -1
            if category in ASLEEP and end is not None:
                hours = (end - start).total_seconds() / 3600.0
                # Cap a single fragment at 16h so a bad timestamp cannot dominate.
                if 0 < hours <= 16:
                    emit_sample(emit, "sleep", "sleepHours", start_raw, end_raw, unit, day_key(start), hours, end)
            root.clear()
            continue
        field = SUM_FIELDS.get(kind) or AVG_FIELDS.get(kind) or LAST_FIELDS.get(kind)
        if field is None:
            root.clear()
            continue
        try:
            raw = float(elem.attrib.get("value", "nan"))
        except ValueError:
            root.clear()
            continue
        if math.isnan(raw):
            root.clear()
            continue
        value = convert_quantity(field, raw, unit)
        when = end or start
        if kind in SUM_FIELDS:
            op = "sum"
        elif kind in AVG_FIELDS:
            op = "avg"
        else:
            op = "last"
        emit_sample(emit, op, field, start_raw, end_raw, unit, day_key(start), value, when)
        root.clear()
    return exported_at


def _hae_points(metric: dict) -> list[dict]:
    data = metric.get("data")
    if isinstance(data, list):
        return [point for point in data if isinstance(point, dict)]
    return []


def _hae_qty(point: dict) -> float | None:
    for key in ("qty", "value", "Avg", "avg", "totalSleep", "asleep"):
        if key in point and point[key] is not None:
            try:
                return float(point[key])
            except (TypeError, ValueError):
                return None
    return None


def parse_health_auto_json(path: Path, emit) -> None:
    payload = json.loads(path.read_text())
    metrics = []
    if isinstance(payload, dict):
        data = payload.get("data")
        if isinstance(data, dict) and isinstance(data.get("metrics"), list):
            metrics = data["metrics"]
        elif isinstance(payload.get("metrics"), list):
            metrics = payload["metrics"]
    for metric in metrics:
        if not isinstance(metric, dict):
            continue
        name = str(metric.get("name") or metric.get("metric") or "").strip().lower()
        units = str(metric.get("units") or metric.get("unit") or "")
        field = HAE_SUM.get(name) or HAE_AVG.get(name) or HAE_LAST.get(name)
        sleep = name in {"sleep_analysis", "sleep"}
        if field is None and not sleep:
            continue
        for point in _hae_points(metric):
            raw_when = str(point.get("date") or point.get("start") or point.get("startDate") or "")
            when = parse_apple_dt(raw_when)
            if when is None:
                continue
            raw_end = str(point.get("end") or point.get("endDate") or raw_when)
            if sleep:
                qty = None
                for key in ("totalSleep", "asleep", "qty", "value"):
                    if point.get(key) is not None:
                        try:
                            qty = float(point[key])
                        except (TypeError, ValueError):
                            qty = None
                        break
                if qty is None:
                    continue
                emit_sample(emit, "sleep", "sleepHours", raw_when, raw_end, units, day_key(when), qty, when)
                continue
            qty = _hae_qty(point)
            if qty is None or field is None:
                continue
            value = convert_quantity(field, qty, units)
            end = parse_apple_dt(raw_end) or when
            if name in HAE_SUM:
                op = "sum"
            elif name in HAE_AVG:
                op = "avg"
            else:
                op = "last"
            emit_sample(emit, op, field, raw_when, raw_end, units, day_key(when), value, end)


def parse_health_auto_dir(path: Path, emit) -> None:
    for file in sorted(path.glob("*.json")):
        parse_health_auto_json(file, emit)


def load_export(path: Path, emit) -> tuple[str, str | None]:
    if path.is_dir():
        zip_files = sorted(path.glob("*.zip"), key=lambda item: item.stat().st_mtime, reverse=True)
        xml_files = sorted(path.glob("*.xml"), key=lambda item: item.stat().st_mtime, reverse=True)
        if zip_files:
            return load_export(zip_files[0], emit)
        if xml_files:
            return load_export(xml_files[0], emit)
        parse_health_auto_dir(path, emit)
        return "health-auto-export", None
    if path.suffix.lower() == ".zip" or zipfile.is_zipfile(path):
        with zipfile.ZipFile(path) as archive:
            names = [name for name in archive.namelist() if name.endswith("export.xml") or name.endswith(".xml")]
            if not names:
                raise ValueError(f"no XML inside {path}")
            names.sort(key=lambda name: (0 if name.endswith("export.xml") else 1, len(name)))
            cache_dir().mkdir(parents=True, exist_ok=True)
            extracted = cache_dir() / "export.xml"
            with archive.open(names[0]) as src, extracted.open("wb") as dst:
                dst.write(src.read())
            os.chmod(extracted, 0o600)
        try:
            exported = parse_export_xml(extracted, emit)
        finally:
            extracted.unlink(missing_ok=True)
        return "apple-health-export", exported
    if path.suffix.lower() == ".json":
        parse_health_auto_json(path, emit)
        return "health-auto-export", None
    exported = parse_export_xml(path, emit)
    return "apple-health-export", exported


def find_input(export: str | None) -> Path | None:
    if export:
        path = Path(os.path.expanduser(export)).expanduser()
        if path.exists():
            return path
        raise FileNotFoundError(f"EXPORT path does not exist: {path}")
    inbox = inbox_dir()
    if not inbox.exists():
        return None
    candidates = []
    for pattern in ("export.zip", "export.xml", "*.zip", "*.xml", "*.json"):
        candidates.extend(inbox.glob(pattern))
    files = [item for item in candidates if item.is_file()]
    if not files:
        return None
    files.sort(key=lambda item: item.stat().st_mtime, reverse=True)
    # Prefer a real Apple export over a stray JSON when both are present.
    for suffix in (".zip", ".xml", ".json"):
        for item in files:
            if item.suffix.lower() == suffix:
                return item
    return files[0]


def sample_value(field: str, index: int, total: int) -> float | None:
    """Invented, deterministic series. index 0 is the oldest day."""
    if field == "hrv" and index % 11 == 0:
        return None
    recent = index >= total - 10
    wave = math.sin(index / 8.0)
    weekend = (index % 7) in (5, 6)
    if field == "steps":
        value = 7600 + 1400 * wave + (-1800 if weekend else 400) + (-2200 if recent else 0)
        return float(max(800, round(value)))
    if field == "activeKcal":
        return float(max(80, round(value_from_steps(sample_value("steps", index, total) or 0))))
    if field == "exerciseMin":
        steps = sample_value("steps", index, total) or 0
        return float(max(0, round(steps / 280)))
    if field == "distanceKm":
        steps = sample_value("steps", index, total) or 0
        return round(steps * 0.00075, 3)
    if field == "sleepHours":
        value = 7.3 + 0.35 * wave + (0.7 if weekend else 0) + (-0.6 if recent else 0)
        return round(max(4.0, min(9.5, value)), 2)
    if field == "restingHr":
        value = 57 + 2.2 * math.sin(index / 14.0) + (4 if recent else 0)
        return float(round(value))
    if field == "heartRate":
        rest = sample_value("restingHr", index, total) or 60
        return float(round(rest + 14 + 4 * wave))
    if field == "hrv":
        value = 46 - 3 * math.sin(index / 10.0) - (8 if recent else 0)
        return float(max(12, round(value)))
    if field == "spo2":
        return float(97 if weekend else 98)
    if field == "respiratory":
        return float(14 if not recent else 15)
    if field == "weightKg":
        if index % 3 != 0:
            return None
        return round(78.4 - index * 0.004, 2)
    return None


def value_from_steps(steps: float) -> float:
    return steps / 22.0


def build_sample_rows(days: int = 400, end: date | None = None) -> list[dict]:
    end = end or date.today()
    start = end - timedelta(days=days - 1)
    rows = []
    fields = [spec["id"] for spec in METRICS]
    for index in range(days):
        current = start + timedelta(days=index)
        row: dict = {"date": current.isoformat()}
        for field in fields:
            value = sample_value(field, index, days)
            if value is not None:
                row[field] = value
        rows.append(row)
    return rows


def fmt_number(value: float | None, digits: int) -> str:
    if value is None:
        return "—"
    if digits <= 0:
        return f"{int(round(value)):,}"
    return f"{value:,.{digits}f}"


def fmt_pct(delta: float | None) -> str:
    if delta is None or math.isnan(delta):
        return "—"
    rounded = int(round(delta))
    if rounded == 0:
        return "0%"
    if rounded > 0:
        return f"+{rounded}%"
    return f"−{abs(rounded)}%"


def aggregate(rows: list[dict], field: str, kind: str) -> float | None:
    values = []
    for row in rows:
        value = row.get(field)
        if isinstance(value, (int, float)) and not isinstance(value, bool):
            values.append(float(value))
    if not values:
        return None
    if kind == "last":
        return values[-1]
    return sum(values) / len(values)


SEVERITY_LEVELS = ("severe", "alert", "mild", "normal")
DEFAULT_SEVERITY_COLORS = {
    "severe": "#f7768e",
    "alert": "#ff9e64",
    "mild": "#e0af68",
    "normal": "#9ece6a",
}
_SEVERITY_COLOR_KEYS = {
    "severe": "severitySevere",
    "alert": "severityAlert",
    "mild": "severityMild",
    "normal": "severityNormal",
}


def severity_value_key(value: float) -> str:
    return f"{float(value):.4f}"


def normalize_hex(color: str) -> str:
    text = str(color or "").strip()
    if len(text) == 4 and text.startswith("#"):
        text = "#" + "".join(ch * 2 for ch in text[1:])
    if len(text) != 7 or not text.startswith("#") or any(ch not in "0123456789abcdefABCDEF" for ch in text[1:]):
        raise ValueError("Use a color like #f7768e.")
    return text.lower()


def severity_settings() -> dict:
    """Palette and classification switches. Missing keys use the defaults."""
    conn = connect_db()
    try:
        stored = {
            row["key"]: row["value"]
            for row in conn.execute(
                "SELECT key, value FROM meta WHERE key IN ('severitySevere', 'severityAlert', 'severityMild', 'severityNormal', 'severityAuto', 'severityAll')"
            )
        }
    finally:
        conn.close()
    colors = {}
    for level, key in _SEVERITY_COLOR_KEYS.items():
        raw = stored.get(key) or ""
        try:
            colors[level] = normalize_hex(raw) if raw else DEFAULT_SEVERITY_COLORS[level]
        except ValueError:
            colors[level] = DEFAULT_SEVERITY_COLORS[level]
    return {
        "colors": colors,
        "auto": stored.get("severityAuto", "1") != "0",
        "classifyAll": stored.get("severityAll", "0") == "1",
    }


def apply_severity_config(patch: dict) -> dict:
    current = severity_settings()
    colors = dict(current["colors"])
    incoming = patch.get("colors") if isinstance(patch.get("colors"), dict) else patch
    for level in SEVERITY_LEVELS:
        if level in incoming and incoming[level]:
            colors[level] = normalize_hex(incoming[level])
    auto = current["auto"] if "auto" not in patch else bool(patch["auto"])
    classify_all = current["classifyAll"] if "classifyAll" not in patch else bool(patch["classifyAll"])
    conn = connect_db()
    try:
        rows = [(key, colors[level]) for level, key in _SEVERITY_COLOR_KEYS.items()]
        rows.append(("severityAuto", "1" if auto else "0"))
        rows.append(("severityAll", "1" if classify_all else "0"))
        conn.executemany(
            "INSERT INTO meta (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
            rows,
        )
        conn.commit()
    finally:
        conn.close()
    return severity_settings()


def load_severity_map(user_id: str) -> dict[tuple[str, str], tuple[str, str]]:
    if not user_id:
        return {}
    conn = connect_db()
    try:
        rows = conn.execute(
            "SELECT field, date, value, level FROM severity WHERE user_id = ?",
            (user_id,),
        )
        return {(row["field"], row["date"]): (row["value"], row["level"]) for row in rows}
    finally:
        conn.close()


def save_severity(user_id: str, field: str, items: list[dict]) -> int:
    if field not in DAY_FIELDS:
        raise ValueError("Unknown health metric.")
    saved = 0
    conn = connect_db()
    try:
        for item in items:
            level = str(item.get("level") or "").strip().lower()
            if level not in SEVERITY_LEVELS:
                continue
            day = str(item.get("date") or "").strip()
            if not day:
                continue
            try:
                key = severity_value_key(float(item["value"]))
            except (TypeError, ValueError):
                continue
            conn.execute(
                "INSERT INTO severity (user_id, field, date, value, level) VALUES (?, ?, ?, ?, ?) "
                "ON CONFLICT(user_id, field, date) DO UPDATE SET value = excluded.value, level = excluded.level",
                (user_id, field, day, key, level),
            )
            saved += 1
        conn.commit()
    finally:
        conn.close()
    return saved


def next_unclassified(limit: int = 40) -> dict | None:
    """The next stored days the agent has not classified for the current person."""
    conn = connect_db()
    try:
        person = current_user_row(conn)
    finally:
        conn.close()
    if person is None:
        return None
    stored = load_severity_map(person["id"])
    rows, _meta = load_days()
    names = {spec["id"]: spec for spec in METRICS}
    pending: dict[str, list[dict]] = {spec["id"]: [] for spec in METRICS}
    for row in reversed(rows):
        for spec in METRICS:
            field = spec["id"]
            value = row.get(field)
            if not isinstance(value, (int, float)) or isinstance(value, bool):
                continue
            key = severity_value_key(float(value))
            previous = stored.get((field, row["date"]))
            if previous and previous[0] == key:
                continue
            pending[field].append({"date": row["date"], "value": float(value)})
    for spec in METRICS:
        points = pending[spec["id"]][: max(1, limit)]
        if not points:
            continue
        unit = "" if spec["unit"] == "count" else spec["unit"]
        return {
            "field": spec["id"],
            "metric": names[spec["id"]]["name"],
            "unit": unit or "count",
            "points": points,
        }
    return None


def republish_current() -> None:
    """Rewrite index.json from sqlite, including stored severity colors."""
    apple_id = read_config().get("APPLE_ID", "")
    uid, _name = current_person()
    if not uid:
        return
    rows, meta = load_days()
    if meta.get("stored") != "1":
        detail = meta.get("sourceDetail") or EMPTY_DETAIL
        write_json(index_path(), empty_index(apple_id, detail))
        write_status("empty", detail, source=meta.get("source") or "none")
        publish_library()
        return
    publish_saved(rows, meta, apple_id)


def tone_for(delta: float | None, favorable: str, avg: float | None, band: tuple[float, float] | None) -> str:
    if favorable == "band" and avg is not None and band is not None:
        return "good" if band[0] <= avg <= band[1] else "warn"
    if delta is None:
        return "none"
    if favorable == "flat" or abs(delta) < 1:
        return "flat"
    if favorable == "up":
        return "good" if delta > 0 else "warn"
    if favorable == "down":
        return "good" if delta < 0 else "warn"
    return "flat"


def trend_sentence(name: str, aggregate_label: str, value_text: str, unit: str, delta: float | None, window: str) -> str:
    unit_bit = f" {unit}" if unit and unit not in {"count"} else ""
    head = f"{aggregate_label} {value_text}{unit_bit}"
    if delta is None:
        return f"{head}. There aren't enough earlier days to compare."
    rounded = int(round(delta))
    if rounded == 0:
        return f"{head}, level with the previous {window}."
    direction = "above" if rounded > 0 else "below"
    return f"{head}, {abs(rounded)}% {direction} the previous {window}."


def build_range(
    rows: list[dict],
    range_id: str,
    label: str,
    length: int,
    levels: dict[tuple[str, str], tuple[str, str]] | None = None,
) -> dict:
    if length <= 0:
        current = list(rows)
        previous: list[dict] = []
    else:
        current = rows[-length:] if len(rows) > length else list(rows)
        if len(rows) > length:
            previous = rows[-(length * 2):-length]
        else:
            previous = []
    if len(previous) < max(3, length // 5):
        previous = []
    metrics = []
    by_id = {}
    for spec in METRICS:
        field = spec["id"]
        kind = spec["kind"]
        digits = spec["digits"]
        curr = aggregate(current, field, kind)
        prev = aggregate(previous, field, kind) if previous else None
        delta = None
        if curr is not None and prev not in (None, 0):
            delta = (curr - prev) / abs(prev) * 100.0
        series = []
        series_text = []
        series_level = []
        numeric = []
        for row in current:
            value = row.get(field)
            if isinstance(value, (int, float)) and not isinstance(value, bool):
                number = float(value)
                series.append(number)
                series_text.append(fmt_number(number, digits))
                numeric.append(number)
                stored = (levels or {}).get((field, row["date"]))
                if stored and stored[0] == severity_value_key(number):
                    series_level.append(stored[1])
                else:
                    series_level.append(None)
            else:
                series.append(None)
                series_text.append("—")
                series_level.append(None)
        series_max = max(numeric) if numeric else 0
        agg_label = "Latest" if kind == "last" else "Daily average"
        value_text = fmt_number(curr, digits)
        unit = "" if spec["unit"] == "count" else spec["unit"]
        metric = {
            "id": field,
            "group": spec["group"],
            "name": spec["name"],
            "unit": unit,
            "aggregate": agg_label,
            "value": value_text,
            "delta": fmt_pct(delta),
            "tone": tone_for(delta, spec["favorable"], curr, spec.get("band")),
            "trend": trend_sentence(spec["name"], agg_label, value_text, unit, delta, label),
            "minText": fmt_number(min(numeric) if numeric else None, digits),
            "maxText": fmt_number(max(numeric) if numeric else None, digits),
            "avgText": fmt_number(curr, digits),
            "seriesMax": series_max,
            "series": series,
            "seriesText": series_text,
            "seriesLevel": series_level,
        }
        metrics.append(metric)
        by_id[field] = metric
    summary = []
    for field in SUMMARY_IDS:
        metric = by_id[field]
        unit = "per day" if metric["aggregate"] == "Daily average" else "latest"
        summary.append({
            "id": field,
            "label": metric["name"],
            "value": metric["value"],
            "unit": unit,
            "delta": metric["delta"],
            "tone": metric["tone"],
        })
    return {
        "id": range_id,
        "label": label,
        "dayCount": len(current),
        "days": [row["date"] for row in current],
        "summary": summary,
        "metrics": metrics,
    }


CHOOSER_TITLE = "Open Apple Health export"


def hypr_clients() -> list[dict] | None:
    try:
        raw = subprocess.check_output(["hyprctl", "clients", "-j"], text=True, timeout=1)
    except (OSError, subprocess.SubprocessError):
        return None
    try:
        parsed = json.loads(raw)
    except json.JSONDecodeError:
        return None
    return parsed if isinstance(parsed, list) else None


def hypr_dispatch(expression: str) -> None:
    try:
        subprocess.run(
            ["hyprctl", "dispatch", expression],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            timeout=1,
            check=False,
        )
    except (OSError, subprocess.SubprocessError):
        return


def chooser_client(clients: list[dict], before: set[str], title: str) -> dict | None:
    """The file dialog that appeared for this open, not a window already on screen."""
    fallback = None
    for client in clients:
        address = client.get("address") or ""
        if not address or address in before:
            continue
        klass = client.get("class") or ""
        if title in (client.get("title") or ""):
            return client
        if fallback is None and ("FileChooser" in klass or "Strata" in klass):
            fallback = client
    return fallback


def app_window(clients: list[dict]) -> dict | None:
    for client in clients:
        if client.get("title") == "OHealth" and client.get("class") == "org.quickshell":
            return client
    return None


def _raise_chooser(before: set[str], stop: threading.Event, app_address: str, app_was_pinned: bool, unpinned: threading.Event, title: str) -> None:
    """Keep the new file dialog above OHealth until the user finishes with it.

    OHealth floats, and a pinned float stays above other windows. The dialog
    has to float too, sit at the top of that stack, and take focus.
    """
    raised_until = 0.0
    while not stop.is_set():
        clients = hypr_clients()
        if clients is None:
            stop.wait(0.05)
            continue
        target = chooser_client(clients, before, title)
        if target is None:
            stop.wait(0.05)
            continue
        selector = "address:" + target["address"]
        if raised_until == 0.0:
            raised_until = time.monotonic() + 1.5
            if app_was_pinned and app_address:
                hypr_dispatch(f'hl.dsp.window.pin({{ action = "off", window = "address:{app_address}" }})')
                unpinned.set()
        if time.monotonic() < raised_until:
            hypr_dispatch(f'hl.dsp.window.float({{ action = "set", window = "{selector}" }})')
            hypr_dispatch(f'hl.dsp.window.alter_zorder({{ mode = "top", window = "{selector}" }})')
            hypr_dispatch(f'hl.dsp.focus({{ window = "{selector}" }})')
        stop.wait(0.1)


def choose_file(title: str, extensions: str) -> str | None:
    """Open the desktop file manager and return the file it was given.

    omarchy-file-select asks the portal file chooser, which opens the default
    file manager. Nothing picked is not an error. On Hyprland the dialog is
    raised in front of the OHealth window, which otherwise floats above it.
    """
    clients = hypr_clients() or []
    before = {client.get("address") or "" for client in clients}
    app = app_window(clients)
    app_address = (app or {}).get("address") or ""
    app_was_pinned = bool((app or {}).get("pinned"))
    stop = threading.Event()
    unpinned = threading.Event()
    raiser = threading.Thread(
        target=_raise_chooser,
        args=(before, stop, app_address, app_was_pinned, unpinned, title),
        daemon=True,
    )
    raiser.start()
    try:
        result = subprocess.run(
            ["omarchy-file-select", "--title", title, "--extensions", extensions],
            text=True,
            capture_output=True,
            check=False,
        )
    except FileNotFoundError as exc:
        raise RuntimeError(
            "The file manager is not available. omarchy-file-select is not on PATH."
        ) from exc
    finally:
        stop.set()
        raiser.join(timeout=2)
        if app_address:
            if unpinned.is_set():
                hypr_dispatch(f'hl.dsp.window.pin({{ action = "on", window = "address:{app_address}" }})')
            hypr_dispatch(f'hl.dsp.focus({{ window = "address:{app_address}" }})')
    if result.returncode == 1:
        return None
    if result.returncode != 0:
        message = result.stderr.strip() or "Could not open the file manager"
        raise RuntimeError(message)
    lines = [line.strip() for line in result.stdout.splitlines() if line.strip()]
    return lines[0] if lines else None


def choose_export() -> str | None:
    return choose_file(CHOOSER_TITLE, "zip xml json")


def choose_database() -> str | None:
    return choose_file("Choose OHealth database", "sqlite db")


def active_range() -> tuple[str, str, str]:
    """This person's saved window. Preset ids match RANGES; custom uses calendar dates."""
    known = {item[0] for item in RANGES}
    conn = connect_db()
    try:
        person = current_user_row(conn)
        if person is None:
            return "30d", "", ""
        saved = {
            row["key"]: row["value"]
            for row in conn.execute(
                "SELECT key, value FROM user_meta WHERE user_id = ? AND key IN ('rangeId', 'rangeStart', 'rangeEnd')",
                (person["id"],),
            )
        }
    finally:
        conn.close()
    range_id = saved.get("rangeId") or "30d"
    start = (saved.get("rangeStart") or "").strip()
    end = (saved.get("rangeEnd") or "").strip()
    if range_id == "custom" and start and end:
        return "custom", start, end
    if range_id not in known:
        range_id = "30d"
    return range_id, "", ""


def set_saved_range(range_id: str, start: str | None, end: str | None) -> None:
    known = {item[0] for item in RANGES}
    if range_id != "custom" and range_id not in known:
        raise ValueError("Unknown date range.")
    conn = connect_db()
    try:
        person = require_user(conn)
        if range_id == "custom":
            if not start or not end:
                raise ValueError("A custom range needs a start and an end date.")
            try:
                start_day = date.fromisoformat(start).isoformat()
                end_day = date.fromisoformat(end).isoformat()
            except ValueError as exc:
                raise ValueError("Use dates like 2026-09-01.") from exc
            if start_day > end_day:
                start_day, end_day = end_day, start_day
            save_user_meta(conn, person["id"], {
                "rangeId": "custom",
                "rangeStart": start_day,
                "rangeEnd": end_day,
            })
        else:
            save_user_meta(conn, person["id"], {
                "rangeId": range_id,
                "rangeStart": "",
                "rangeEnd": "",
            })
        conn.commit()
    finally:
        conn.close()


def build_custom_range(
    rows: list[dict],
    start: str,
    end: str,
    levels: dict[tuple[str, str], tuple[str, str]] | None = None,
) -> dict:
    current = [row for row in rows if start <= row["date"] <= end]
    span = len(current)
    if span == 0:
        block = build_range([], "custom", "Custom", 1, levels)
    else:
        before = [row for row in rows if row["date"] < start]
        block = build_range(before[-span:] + current, "custom", "Custom", span, levels)
    block["start"] = start
    block["end"] = end
    return block


def build_index(rows: list[dict], source: str, source_detail: str, labeled_sample: bool, exported_at: str | None, apple_id: str) -> dict:
    range_id, start, end = active_range()
    uid, _name = current_person()
    levels = load_severity_map(uid)
    ranges = {item_id: build_range(rows, item_id, label, length, levels) for item_id, label, length in RANGES}
    if range_id == "custom":
        ranges["custom"] = build_custom_range(rows, start, end, levels)
    return {
        "schema": 1,
        "labeledSample": labeled_sample,
        "source": source,
        "sourceDetail": source_detail,
        "builtAt": now_iso(),
        "exportedAt": exported_at,
        "appleId": apple_id,
        "range": {"id": range_id, "start": start, "end": end},
        "severity": severity_settings(),
        "ranges": ranges,
    }


def empty_index(apple_id: str, detail: str) -> dict:
    return build_index([], "none", detail, False, None, apple_id)


EMPTY_DETAIL = (
    "No Health export yet. Use File → Import from Apple HealthKit Export to choose "
    "the export.zip from the iPhone Health app. Apple does not offer a HealthKit "
    "cloud API. A file in the inbox works too."
)


def publish_library() -> None:
    """Write this person's file list and chat. Rows stay in sqlite."""
    conn = connect_db()
    try:
        person = current_user_row(conn)
        uid = person["id"] if person else ""
        files = {"xrays": [], "blood": [], "urine": []}
        bucket = {"xray": "xrays", "blood": "blood", "urine": "urine"}
        messages = []
        if uid:
            for row in conn.execute(
                "SELECT id, kind, name, path, added_at FROM files WHERE user_id = ? ORDER BY added_at",
                (uid,),
            ):
                key = bucket.get(row["kind"])
                if key is None:
                    continue
                files[key].append({
                    "id": row["id"],
                    "kind": row["kind"],
                    "name": row["name"],
                    "path": row["path"],
                    "addedAt": row["added_at"],
                })
            for row in conn.execute(
                "SELECT id, role, agent, scope, body, at FROM chat WHERE user_id = ? ORDER BY id",
                (uid,),
            ):
                messages.append({
                    "id": row["id"],
                    "role": row["role"],
                    "agent": row["agent"],
                    "scope": row["scope"],
                    "body": row["body"],
                    "at": row["at"],
                })
    finally:
        conn.close()
    write_json(files_path(), files)
    write_json(chat_path(), {"messages": messages})
    publish_users()


def list_files() -> list[dict]:
    conn = connect_db()
    try:
        person = current_user_row(conn)
        if person is None:
            return []
        return [
            {"id": row["id"], "kind": row["kind"], "name": row["name"], "path": row["path"], "addedAt": row["added_at"]}
            for row in conn.execute(
                "SELECT id, kind, name, path, added_at FROM files WHERE user_id = ? ORDER BY added_at",
                (person["id"],),
            )
        ]
    finally:
        conn.close()


def load_chat(limit: int = 12) -> list[dict]:
    conn = connect_db()
    try:
        person = current_user_row(conn)
        if person is None:
            return []
        rows = list(conn.execute(
            "SELECT role, agent, scope, body FROM chat WHERE user_id = ? ORDER BY id DESC LIMIT ?",
            (person["id"], limit),
        ))
    finally:
        conn.close()
    rows.reverse()
    return [{"role": row["role"], "agent": row["agent"], "scope": row["scope"], "body": row["body"]} for row in rows]


def add_chat_message(role: str, body: str, agent: str, scope: str) -> None:
    conn = connect_db()
    try:
        person = require_user(conn)
        conn.execute(
            "INSERT INTO chat (user_id, role, agent, scope, body, at) VALUES (?, ?, ?, ?, ?, ?)",
            (person["id"], role, agent, scope, body, now_iso()),
        )
        conn.commit()
    finally:
        conn.close()
    publish_library()


def _unlink_owned_file(path: str) -> None:
    candidate = Path(path)
    roots = (xray_dir(), document_dir())
    if any(_path_is_inside(candidate, root) for root in roots) and candidate.is_file():
        candidate.unlink()


def delete_record(record_id: str) -> str:
    """Remove one imported X-ray or lab file for the current person."""
    conn = connect_db()
    path = ""
    name = ""
    try:
        person = require_user(conn)
        row = conn.execute(
            "SELECT id, name, path FROM files WHERE id = ? AND user_id = ?",
            (record_id.strip(), person["id"]),
        ).fetchone()
        if row is None:
            raise ValueError("That file is not in this database.")
        path = row["path"]
        name = row["name"]
        conn.execute("DELETE FROM files WHERE id = ? AND user_id = ?", (row["id"], person["id"]))
        conn.commit()
    finally:
        conn.close()
    _unlink_owned_file(path)
    publish_library()
    return name


COMPANION_OPS = {
    "steps": "sum",
    "activeKcal": "sum",
    "exerciseMin": "sum",
    "distanceKm": "sum",
    "sleepHours": "sleep",
    "restingHr": "avg",
    "heartRate": "avg",
    "hrv": "avg",
    "spo2": "avg",
    "respiratory": "avg",
    "weightKg": "last",
}
COMPANION_BATCH = 2000


def _companion_sample(sample: dict) -> dict | None:
    if not isinstance(sample, dict):
        return None
    field = str(sample.get("field") or "").strip()
    op = COMPANION_OPS.get(field)
    if op is None or str(sample.get("op") or "").strip() != op:
        return None
    day = str(sample.get("day") or "").strip()
    if len(day) != 10 or day[4] != "-" or day[7] != "-":
        return None
    try:
        datetime.fromisoformat(day)
    except ValueError:
        return None
    try:
        value = float(sample.get("value"))
    except (TypeError, ValueError):
        return None
    if not math.isfinite(value):
        return None
    unit = str(sample.get("unit") or "").strip().lower()
    if field == "sleepHours" and unit in {"s", "sec", "second", "seconds"}:
        value = value / 3600.0
    elif field == "exerciseMin" and unit in {"s", "sec", "second", "seconds"}:
        value = value / 60.0
    else:
        value = convert_quantity(field, value, unit)
    if not math.isfinite(value):
        return None
    at = str(sample.get("at") or "").strip()
    sid = str(sample.get("id") or "").strip()
    if not sid or len(sid) > 80:
        sid = sample_id(op, field, day, at or day, unit or field)
    return {"id": sid, "day": day, "field": field, "op": op, "value": value, "at": at}


def ingest_companion_samples(samples: list) -> dict:
    """Store samples from the paired iPhone and rebuild the days they touch.

    Invented sample rows are removed the first time a real sample arrives.
    An Apple export already in the database is kept and merged.
    """
    if not isinstance(samples, list):
        raise ValueError("Samples must be a list.")
    if len(samples) > COMPANION_BATCH:
        raise ValueError(f"Send at most {COMPANION_BATCH} samples at a time.")
    cleaned = [item for item in (_companion_sample(sample) for sample in samples) if item]
    if not cleaned:
        return {"saved": 0, "days": 0}
    conn = connect_db()
    touched: set[str] = set()
    try:
        person = require_user(conn)
        uid = person["id"]
        labeled = conn.execute(
            "SELECT value FROM user_meta WHERE user_id = ? AND key = 'labeledSample'",
            (uid,),
        ).fetchone()
        if labeled is not None and labeled["value"] == "1":
            conn.execute("DELETE FROM days WHERE user_id = ?", (uid,))
            conn.execute("DELETE FROM samples WHERE user_id = ?", (uid,))
        for item in cleaned:
            previous = conn.execute(
                "SELECT day FROM samples WHERE user_id = ? AND id = ?",
                (uid, item["id"]),
            ).fetchone()
            if previous is not None and previous["day"]:
                touched.add(previous["day"])
            touched.add(item["day"])
            conn.execute(
                "INSERT INTO samples (user_id, id, day, field, op, value, at) VALUES (?, ?, ?, ?, ?, ?, ?) "
                "ON CONFLICT(user_id, id) DO UPDATE SET "
                "day = excluded.day, field = excluded.field, op = excluded.op, "
                "value = excluded.value, at = excluded.at",
                (uid, item["id"], item["day"], item["field"], item["op"], item["value"], item["at"]),
            )
        for day in touched:
            refresh_day(conn, uid, day)
        source = conn.execute(
            "SELECT value FROM user_meta WHERE user_id = ? AND key = 'source'",
            (uid,),
        ).fetchone()
        meta = {"stored": "1", "labeledSample": "0"}
        if source is None or source["value"] in {"", "sample", "none"}:
            meta["source"] = "companion"
            meta["sourceDetail"] = "Synced from the paired iPhone."
        save_user_meta(conn, uid, meta)
        conn.commit()
    finally:
        conn.close()
    republish_current()
    return {"saved": len(cleaned), "days": len(touched)}


def import_record(kind: str, source: Path) -> dict:
    """Copy an X-ray or lab file into the config directory and record its path."""
    if kind not in {"xray", "blood", "urine"}:
        raise ValueError(f"Unknown record kind: {kind}")
    source = Path(source)
    if not source.is_file():
        raise FileNotFoundError(f"File does not exist: {source}")
    conn = connect_db()
    try:
        person = require_user(conn)
        folder = (xray_dir() if kind == "xray" else document_dir()) / person["id"]
        folder.mkdir(parents=True, exist_ok=True)
        os.chmod(folder, 0o700)
        safe = "".join(ch if ch.isalnum() or ch in ".-_" else "_" for ch in source.name) or "file"
        dest = folder / f"{uuid.uuid4().hex[:12]}-{safe}"
        shutil.copyfile(source, dest)
        os.chmod(dest, 0o600)
        record_id = uuid.uuid4().hex
        added = now_iso()
        conn.execute(
            "INSERT INTO files (id, user_id, kind, name, path, added_at) VALUES (?, ?, ?, ?, ?, ?)",
            (record_id, person["id"], kind, source.name, str(dest), added),
        )
        conn.commit()
    finally:
        conn.close()
    publish_library()
    return {"id": record_id, "kind": kind, "name": source.name, "path": str(dest), "addedAt": added}


def refresh_day(conn: sqlite3.Connection, user_id: str, day: str) -> None:
    """Rebuild one person's day from every saved sample so repeats are not added twice."""
    bucket = DayBucket()
    found = False
    for record in conn.execute(
        "SELECT field, op, value, at FROM samples WHERE user_id = ? AND day = ?",
        (user_id, day),
    ):
        found = True
        field = record["field"]
        value = float(record["value"])
        op = record["op"]
        if op == "sum":
            bucket.add_sum(field, value)
        elif op == "avg":
            bucket.add_avg(field, value)
        elif op == "sleep":
            bucket.add_sleep(value)
        else:
            when = datetime.fromisoformat(record["at"]) if record["at"] else datetime.min
            bucket.add_last(field, when, value)
    if not found:
        conn.execute("DELETE FROM days WHERE user_id = ? AND date = ?", (user_id, day))
        return
    row = bucket.as_dict(day)
    names = ", ".join(["user_id", "date", *DAY_FIELDS])
    marks = ", ".join("?" for _ in range(2 + len(DAY_FIELDS)))
    assignments = ", ".join(f"{field}=excluded.{field}" for field in DAY_FIELDS)
    values: list = [user_id, row["date"]]
    for field in DAY_FIELDS:
        item = row.get(field)
        values.append(None if item is None else float(item))
    conn.execute(
        f"INSERT INTO days ({names}) VALUES ({marks}) ON CONFLICT(user_id, date) DO UPDATE SET {assignments}",
        values,
    )


def save_meta(conn: sqlite3.Connection, meta: dict[str, str]) -> None:
    for key, value in meta.items():
        conn.execute(
            "INSERT INTO meta (key, value) VALUES (?, ?) "
            "ON CONFLICT(key) DO UPDATE SET value = excluded.value",
            (key, value),
        )


def merge_export(path: Path) -> tuple[str, str | None]:
    """Save samples that are new or changed, then rebuild only those days."""
    conn = connect_db()
    try:
        person = require_user(conn)
        uid = person["id"]
        labeled = conn.execute(
            "SELECT value FROM user_meta WHERE user_id = ? AND key = 'labeledSample'",
            (uid,),
        ).fetchone()
        if labeled is not None and labeled["value"] == "1":
            conn.execute("DELETE FROM days WHERE user_id = ?", (uid,))
            conn.execute("DELETE FROM samples WHERE user_id = ?", (uid,))
        conn.execute("DROP TABLE IF EXISTS incoming")
        conn.execute(
            """
            CREATE TEMP TABLE incoming (
              id TEXT PRIMARY KEY,
              day TEXT NOT NULL,
              field TEXT NOT NULL,
              op TEXT NOT NULL,
              value REAL NOT NULL,
              at TEXT NOT NULL
            )
            """
        )
        batch: list[tuple] = []

        def flush() -> None:
            if not batch:
                return
            conn.executemany(
                "INSERT OR REPLACE INTO incoming (id, day, field, op, value, at) VALUES (?,?,?,?,?,?)",
                batch,
            )
            batch.clear()

        def emit(sample: dict) -> None:
            batch.append((
                sample["id"],
                sample["day"],
                sample["field"],
                sample["op"],
                float(sample["value"]),
                sample.get("at") or "",
            ))
            if len(batch) >= 4000:
                flush()

        source, exported_at = load_export(path, emit)
        flush()
        touched: set[str] = set()
        changed = conn.execute(
            """
            SELECT i.day AS new_day, s.day AS old_day
            FROM incoming i
            LEFT JOIN samples s ON s.user_id = ? AND s.id = i.id
            WHERE s.id IS NULL
               OR s.value != i.value
               OR s.day != i.day
               OR s.field != i.field
               OR s.op != i.op
               OR s.at != i.at
            """,
            (uid,),
        )
        for record in changed:
            touched.add(record["new_day"])
            if record["old_day"]:
                touched.add(record["old_day"])
        conn.execute(
            """
            INSERT INTO samples (user_id, id, day, field, op, value, at)
            SELECT ?, id, day, field, op, value, at FROM incoming
            WHERE true
            ON CONFLICT(user_id, id) DO UPDATE SET
              day = excluded.day,
              field = excluded.field,
              op = excluded.op,
              value = excluded.value,
              at = excluded.at
            """,
            (uid,),
        )
        for day in touched:
            refresh_day(conn, uid, day)
        conn.execute("DROP TABLE IF EXISTS incoming")
        conn.commit()
        return source, exported_at
    finally:
        conn.close()


def publish_saved(rows: list[dict], meta: dict[str, str], apple_id: str) -> int:
    source = meta.get("source") or "none"
    detail = meta.get("sourceDetail") or ""
    labeled = meta.get("labeledSample") == "1"
    exported_at = meta.get("exportedAt") or None
    saved_apple = meta.get("appleId") or apple_id
    if not rows:
        message = detail or "No saved health data."
        write_json(index_path(), empty_index(saved_apple, message))
        write_status("empty", message, labeledSample=labeled, source=source)
        publish_library()
        return 0
    index = build_index(rows, source, detail, labeled, exported_at, saved_apple)
    write_json(index_path(), index)
    if labeled:
        message = "Sample data. These numbers are invented."
    else:
        message = f"Opened {len(rows)} days from the local database."
    write_status("ready", message, labeledSample=labeled, source=source)
    publish_library()
    return 0


def import_path(path: Path, apple_id: str) -> int:
    source, exported_at = merge_export(path)
    uid, _name = current_person()
    rows, _meta = load_days()
    detail = "" if rows else "That file had none of the activity or vitals OHealth charts."
    conn = connect_db()
    try:
        save_user_meta(conn, uid, {
            "stored": "1",
            "source": source,
            "sourceDetail": detail,
            "labeledSample": "0",
            "exportedAt": exported_at or "",
            "appleId": apple_id or "",
        })
        conn.commit()
    finally:
        conn.close()
    if not rows:
        write_json(index_path(), empty_index(apple_id, detail))
        write_status("empty", detail, source=source)
        publish_library()
        return 0
    rows, meta = load_days()
    return publish_saved(rows, meta, apple_id)


def run(
    sample: bool,
    export: str | None,
    sample_end: str | None,
    pick: bool = False,
    inbox: bool = False,
    select_database: bool = False,
    database: str | None = None,
    record_kind: str | None = None,
    record_file: str | None = None,
    add_person: str | None = None,
    select_person: str | None = None,
    list_people: bool = False,
    delete_person: str | None = None,
    range_id: str | None = None,
    range_start: str | None = None,
    range_end: str | None = None,
    severity_config: bool = False,
    save_severity_rows: bool = False,
    severity_next: bool = False,
    severity_limit: int = 40,
    delete_file: str | None = None,
) -> int:
    ensure_layout()
    if record_kind:
        titles = {"xray": "Import X-ray", "blood": "Import blood test", "urine": "Import urine test"}
        if record_kind not in titles:
            print(f"Unknown record kind: {record_kind}", file=sys.stderr)
            return 1
        if not record_file:
            extensions = "png jpg jpeg webp tif tiff gif" if record_kind == "xray" else "pdf png jpg jpeg webp tif tiff txt"
            try:
                record_file = choose_file(titles[record_kind], extensions)
            except RuntimeError as exc:
                write_status("error", str(exc))
                print(exc, file=sys.stderr)
                return 1
            if not record_file:
                return 3
    if select_database:
        try:
            database = choose_database()
        except RuntimeError as exc:
            write_status("error", str(exc))
            print(exc, file=sys.stderr)
            return 1
        if not database:
            return 3
    if pick:
        try:
            export = choose_export()
        except RuntimeError as exc:
            write_status("error", str(exc))
            print(exc, file=sys.stderr)
            return 1
        if not export:
            return 3
    cfg = read_config()
    apple_id = cfg.get("APPLE_ID", "")
    try:
        if severity_config or save_severity_rows:
            raw = sys.stdin.readline()
            patch = json.loads(raw) if raw.strip() else {}
            if severity_config:
                apply_severity_config(patch)
            else:
                uid, _name = current_person()
                if not uid:
                    raise ValueError("Choose a person before classifying.")
                save_severity(uid, str(patch.get("field") or ""), list(patch.get("items") or []))
            republish_current()
            return 0
        if severity_next:
            batch = next_unclassified(severity_limit)
            print(json.dumps({"ok": True, "done": batch is None, "batch": batch}), flush=True)
            return 0
        if delete_file:
            delete_record(delete_file)
            return 0
        if database:
            set_selected_database(Path(database))
        if add_person:
            add_user(add_person)
        if delete_person:
            removed_current = delete_user(delete_person)
            if removed_current:
                message = "Choose a person to open this database."
                write_json(index_path(), empty_index(apple_id, message))
                write_status("choose", message, source="none")
                publish_library()
        if select_person:
            set_current_user(select_person)
        if range_id:
            set_saved_range(range_id, range_start, range_end)
        if (list_people or add_person or delete_person) and not select_person and not sample and not export and not inbox and not record_kind and not range_id:
            if list_people and not add_person and not delete_person:
                publish_users()
            return 0
        if record_kind:
            saved = import_record(record_kind, Path(record_file or ""))
            write_status("ready", f"Saved {saved['name']}.", source="files")
            return 0
        if sample:
            end = date.fromisoformat(sample_end) if sample_end else date.today()
            rows = build_sample_rows(400, end)
            detail = (
                "Invented preview series so the window can be used before an Apple Health "
                "export is available. Not a record of anyone's health."
            )
            store_days(
                rows,
                source="sample",
                source_detail=detail,
                labeled_sample=True,
                exported_at=None,
                apple_id=apple_id,
            )
            index = build_index(rows, "sample", detail, True, None, apple_id)
            write_json(index_path(), index)
            write_status("ready", "Sample data. These numbers are invented.", labeledSample=True, source="sample")
            publish_library()
            return 0
        if export or inbox:
            write_status("syncing", "Importing…", labeledSample=False)
            if export:
                path = find_input(export)
            else:
                path = find_input(None)
            if path is None:
                write_json(index_path(), empty_index(apple_id, EMPTY_DETAIL))
                write_status("empty", EMPTY_DETAIL, source="none")
                publish_library()
                return 0
            return import_path(path, apple_id)
        write_status("syncing", "Opening saved health data…", labeledSample=False)
        rows, meta = load_days()
        if not meta.get("user"):
            message = "Choose a person to open this database."
            write_json(index_path(), empty_index(apple_id, message))
            write_status("choose", message, source="none")
            publish_library()
            return 0
        if meta.get("stored") != "1":
            write_json(index_path(), empty_index(apple_id, EMPTY_DETAIL))
            write_status("empty", EMPTY_DETAIL, source="none")
            publish_library()
            return 0
        return publish_saved(rows, meta, apple_id)
    except Exception as exc:  # noqa: BLE001 — surface a single error string to the window
        message = str(exc) or exc.__class__.__name__
        write_status("error", message)
        print(message, file=sys.stderr)
        return 1


def main() -> None:
    parser = argparse.ArgumentParser(description="Build the OHealth index")
    parser.add_argument("--sample", action="store_true", help="write invented, labeled sample data")
    parser.add_argument("--export", help="read this export once and save it in the local database")
    parser.add_argument("--inbox", action="store_true", help="read the inbox once and save it in the local database")
    parser.add_argument("--pick", action="store_true", help="choose an export with the file manager, then save it")
    parser.add_argument("--select-database", action="store_true", help="choose the sqlite database, then open it")
    parser.add_argument("--database", help="save this database path in the OHealth database and open it")
    parser.add_argument("--xray", action="store_true", help="import an X-ray into the database")
    parser.add_argument("--blood", action="store_true", help="import a blood test into the database")
    parser.add_argument("--urine", action="store_true", help="import a urine test into the database")
    parser.add_argument("--file", help="file to import with --xray, --blood, or --urine")
    parser.add_argument("--sample-end", help="ISO date the sample series ends on (tests)")
    parser.add_argument("--users", action="store_true", help="write the people in this database")
    parser.add_argument("--add-user", help="add a person to this database")
    parser.add_argument("--delete-user", help="remove this person and their health data, files, and chat")
    parser.add_argument("--delete-file", help="remove this imported X-ray or lab file")
    parser.add_argument("--user", help="open the database as this person")
    parser.add_argument("--range", help="save this person's date range: 7d, 30d, 90d, 365d, 3y, 5y, all, or custom")
    parser.add_argument("--range-start", help="custom range start date")
    parser.add_argument("--range-end", help="custom range end date")
    parser.add_argument("--severity-config", action="store_true", help="save severity colors and switches from a JSON line on stdin")
    parser.add_argument("--save-severity", action="store_true", help="store classifications from a JSON line on stdin")
    parser.add_argument("--severity-next", action="store_true", help="print the next unclassified batch as JSON")
    parser.add_argument("--limit", type=int, default=40, help="how many days --severity-next returns")
    args = parser.parse_args()
    kind = "xray" if args.xray else "blood" if args.blood else "urine" if args.urine else None
    sys.exit(run(
        args.sample,
        args.export,
        args.sample_end,
        args.pick,
        args.inbox,
        args.select_database,
        args.database,
        kind,
        args.file,
        args.add_user,
        args.user,
        args.users,
        args.delete_user,
        args.range,
        args.range_start,
        args.range_end,
        args.severity_config,
        args.save_severity,
        args.severity_next,
        args.limit,
        args.delete_file,
    ))


if __name__ == "__main__":
    main()
