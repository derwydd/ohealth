#!/usr/bin/env python3
"""Build the health index the Quickshell window watches.

HealthKit has no cloud API. This script never pretends to fetch one.
It reads, in order:

  1. --export PATH, or EXPORT= in ~/.config/ohealth/config
  2. ~/.local/share/ohealth/inbox  (export.zip, export.xml, or JSON)

Accepted inputs are Apple's "Export All Health Data" zip/XML, and JSON
written by Health Auto Export. --sample writes an invented series and
marks it labeledSample so the window can say so.

Output (atomic, mode 0600):

  ~/.cache/ohealth/index.json
  ~/.cache/ohealth/status.json
"""

from __future__ import annotations

import argparse
import json
import math
import os
import sys
import zipfile
import xml.etree.ElementTree as ET
from datetime import date, datetime, timedelta, timezone
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from ohealth_paths import (  # noqa: E402
    cache_dir,
    ensure_layout,
    inbox_dir,
    index_path,
    read_config,
    status_path,
)

RANGES = (
    ("7d", "7 days", 7),
    ("30d", "30 days", 30),
    ("90d", "90 days", 90),
    ("365d", "1 year", 365),
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
    write_json(status_path(), body)


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


def rows_from_buckets(buckets: dict[str, DayBucket]) -> list[dict]:
    return [buckets[day].as_dict(day) for day in sorted(buckets)]


def bucket_for(buckets: dict[str, DayBucket], day: str) -> DayBucket:
    found = buckets.get(day)
    if found is None:
        found = DayBucket()
        buckets[day] = found
    return found


def parse_export_xml(path: Path) -> tuple[list[dict], str | None]:
    buckets: dict[str, DayBucket] = {}
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
        start = parse_apple_dt(elem.attrib.get("startDate", ""))
        end = parse_apple_dt(elem.attrib.get("endDate", "")) or start
        if start is None:
            root.clear()
            continue
        if kind == "HKCategoryTypeIdentifierSleepAnalysis":
            try:
                category = int(float(elem.attrib.get("value", "nan")))
            except ValueError:
                category = -1
            if category in ASLEEP and end is not None:
                hours = (end - start).total_seconds() / 3600.0
                # Cap a single fragment at 16h so a bad timestamp cannot dominate.
                if 0 < hours <= 16:
                    bucket_for(buckets, day_key(start)).add_sleep(hours)
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
        value = convert_quantity(field, raw, elem.attrib.get("unit", ""))
        bucket = bucket_for(buckets, day_key(start))
        if kind in SUM_FIELDS:
            bucket.add_sum(field, value)
        elif kind in AVG_FIELDS:
            bucket.add_avg(field, value)
        else:
            bucket.add_last(field, end or start, value)
        root.clear()
    return rows_from_buckets(buckets), exported_at


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


def parse_health_auto_json(path: Path) -> list[dict]:
    payload = json.loads(path.read_text())
    metrics = []
    if isinstance(payload, dict):
        data = payload.get("data")
        if isinstance(data, dict) and isinstance(data.get("metrics"), list):
            metrics = data["metrics"]
        elif isinstance(payload.get("metrics"), list):
            metrics = payload["metrics"]
    buckets: dict[str, DayBucket] = {}
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
            when = parse_apple_dt(str(point.get("date") or point.get("start") or point.get("startDate") or ""))
            if when is None:
                continue
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
                # Health Auto Export reports sleep in hours.
                bucket_for(buckets, day_key(when)).add_sleep(qty)
                continue
            qty = _hae_qty(point)
            if qty is None or field is None:
                continue
            value = convert_quantity(field, qty, units)
            bucket = bucket_for(buckets, day_key(when))
            if name in HAE_SUM:
                bucket.add_sum(field, value)
            elif name in HAE_AVG:
                bucket.add_avg(field, value)
            else:
                end = parse_apple_dt(str(point.get("end") or point.get("endDate") or "")) or when
                bucket.add_last(field, end, value)
    return rows_from_buckets(buckets)


def parse_health_auto_dir(path: Path) -> list[dict]:
    merged: dict[str, dict] = {}
    files = sorted(path.glob("*.json"))
    for file in files:
        for row in parse_health_auto_json(file):
            day = row["date"]
            slot = merged.setdefault(day, {"date": day})
            for key, value in row.items():
                if key == "date":
                    continue
                # Later files in name order win for last-style fields; sums add
                # only when the day was not already present for that field.
                if key not in slot:
                    slot[key] = value
    return [merged[day] for day in sorted(merged)]


def load_export(path: Path) -> tuple[list[dict], str, str | None]:
    if path.is_dir():
        zip_files = sorted(path.glob("*.zip"), key=lambda item: item.stat().st_mtime, reverse=True)
        xml_files = sorted(path.glob("*.xml"), key=lambda item: item.stat().st_mtime, reverse=True)
        if zip_files:
            return load_export(zip_files[0])
        if xml_files:
            return load_export(xml_files[0])
        rows = parse_health_auto_dir(path)
        return rows, "health-auto-export", None
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
        rows, exported = parse_export_xml(extracted)
        return rows, "apple-health-export", exported
    if path.suffix.lower() == ".json":
        return parse_health_auto_json(path), "health-auto-export", None
    rows, exported = parse_export_xml(path)
    return rows, "apple-health-export", exported


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


def build_range(rows: list[dict], range_id: str, label: str, length: int) -> dict:
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
        numeric = []
        for row in current:
            value = row.get(field)
            if isinstance(value, (int, float)) and not isinstance(value, bool):
                number = float(value)
                series.append(number)
                series_text.append(fmt_number(number, digits))
                numeric.append(number)
            else:
                series.append(None)
                series_text.append("—")
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


def build_index(rows: list[dict], source: str, source_detail: str, labeled_sample: bool, exported_at: str | None, apple_id: str) -> dict:
    # Keep a year plus the previous window so 365d can still compare.
    trimmed = rows[-800:]
    return {
        "schema": 1,
        "labeledSample": labeled_sample,
        "source": source,
        "sourceDetail": source_detail,
        "builtAt": now_iso(),
        "exportedAt": exported_at,
        "appleId": apple_id,
        "ranges": {range_id: build_range(trimmed, range_id, label, length) for range_id, label, length in RANGES},
    }


def empty_index(apple_id: str, detail: str) -> dict:
    return build_index([], "none", detail, False, None, apple_id)


def run(sample: bool, export: str | None, sample_end: str | None) -> int:
    ensure_layout()
    cfg = read_config()
    apple_id = cfg.get("APPLE_ID", "")
    write_status("syncing", "Reading health data…", labeledSample=sample)
    try:
        if sample:
            end = date.fromisoformat(sample_end) if sample_end else date.today()
            rows = build_sample_rows(400, end)
            index = build_index(
                rows,
                "sample",
                "Invented preview series so the window can be used before an Apple Health export is available. Not a record of anyone's health.",
                True,
                None,
                apple_id,
            )
            write_json(index_path(), index)
            write_status("ready", "Sample data. These numbers are invented.", labeledSample=True, source="sample")
            return 0
        path = find_input(export or cfg.get("EXPORT") or None)
        if path is None:
            detail = (
                "No Health export in the inbox. Apple does not offer a HealthKit cloud API. "
                "Export All Health Data on the iPhone and put export.zip in the inbox."
            )
            write_json(index_path(), empty_index(apple_id, detail))
            write_status("empty", detail, source="none")
            return 0
        rows, source, exported_at = load_export(path)
        if not rows:
            detail = f"Read {path.name}, but it had none of the activity or vitals OHealth charts."
            write_json(index_path(), empty_index(apple_id, detail))
            write_status("empty", detail, source=source)
            return 0
        detail = str(path)
        index = build_index(rows, source, detail, False, exported_at, apple_id)
        write_json(index_path(), index)
        write_status(
            "ready",
            f"Indexed {len(rows)} days from {path.name}.",
            labeledSample=False,
            source=source,
        )
        return 0
    except Exception as exc:  # noqa: BLE001 — surface a single error string to the window
        message = str(exc) or exc.__class__.__name__
        write_status("error", message)
        print(message, file=sys.stderr)
        return 1


def main() -> None:
    parser = argparse.ArgumentParser(description="Build the OHealth index")
    parser.add_argument("--sample", action="store_true", help="write invented, labeled sample data")
    parser.add_argument("--export", help="export.zip, export.xml, JSON, or a directory of them")
    parser.add_argument("--sample-end", help="ISO date the sample series ends on (tests)")
    args = parser.parse_args()
    sys.exit(run(args.sample, args.export, args.sample_end))


if __name__ == "__main__":
    main()
