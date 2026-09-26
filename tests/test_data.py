#!/usr/bin/env python3
"""Data-layer checks for sync and the agent picker.

Uses a temporary home. Does not read or write ~/.config/omarchy/defaults/agent.
"""

from __future__ import annotations

import json
import os
import shlex
import subprocess
import sys
import zipfile
from datetime import date
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
BIN = ROOT / "bin"
PYTHON = sys.executable


def isolate(tmp: Path) -> dict[str, str]:
    env = os.environ.copy()
    home = tmp / "home"
    home.mkdir(parents=True, exist_ok=True)
    env["OHEALTH_HOME"] = str(home)
    env["HOME"] = str(home)
    env["XDG_CONFIG_HOME"] = str(home / ".config")
    env["XDG_CACHE_HOME"] = str(home / ".cache")
    env["XDG_DATA_HOME"] = str(home / ".local" / "share")
    env["XDG_STATE_HOME"] = str(home / ".local" / "state")
    env["OHEALTH_AGENT_FILE"] = str(home / ".config" / "omarchy" / "defaults" / "agent")
    env["PYTHONPATH"] = str(BIN)
    return env


def run(env: dict[str, str], script: str, args: list[str], stdin: str = "") -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [PYTHON, str(BIN / script), *args],
        input=stdin,
        text=True,
        capture_output=True,
        env=env,
        check=False,
    )


def load_index(env: dict[str, str]) -> dict:
    path = Path(env["XDG_CACHE_HOME"]) / "ohealth" / "index.json"
    return json.loads(path.read_text())


def enter_person(env: dict[str, str], name: str = "Alex") -> str:
    added = run(env, "ohealth_sync.py", ["--add-user", name])
    assert added.returncode == 0, added.stderr
    users = json.loads((Path(env["XDG_CACHE_HOME"]) / "ohealth" / "users.json").read_text())
    match = next(item for item in users["users"] if item["name"] == name)
    chosen = run(env, "ohealth_sync.py", ["--user", match["id"]])
    assert chosen.returncode == 0, chosen.stderr
    return match["id"]


def test_sample_is_labeled_and_ranged(tmp: Path) -> None:
    env = isolate(tmp)
    enter_person(env)
    result = run(env, "ohealth_sync.py", ["--sample", "--sample-end", "2026-09-25"])
    assert result.returncode == 0, result.stderr
    index = load_index(env)
    assert index["schema"] == 1
    assert index["labeledSample"] is True
    assert index["source"] == "sample"
    assert "not a record" in index["sourceDetail"].lower() or "Invented" in index["sourceDetail"]
    window = index["ranges"]["7d"]
    assert window["days"][-1] == "2026-09-25"
    assert len(window["days"]) == 7
    steps = next(item for item in window["metrics"] if item["id"] == "steps")
    assert len(steps["series"]) == 7
    sys.path.insert(0, str(BIN))
    from ohealth_sync import sample_value
    expected = [sample_value("steps", 400 - 7 + offset, 400) for offset in range(7)]
    assert steps["series"] == expected
    assert steps["series"][-1] < steps["series"][0] or min(steps["series"]) < 6000
    year = index["ranges"]["365d"]
    assert len(year["days"]) == 365
    hrv = next(item for item in year["metrics"] if item["id"] == "hrv")
    assert any(value is None for value in hrv["series"])
    summary_ids = [tile["id"] for tile in window["summary"]]
    assert summary_ids == ["steps", "sleepHours", "restingHr", "hrv"]
    again = run(env, "ohealth_sync.py", [])
    assert again.returncode == 0, again.stderr
    reloaded = load_index(env)
    assert reloaded["labeledSample"] is True
    assert reloaded["source"] == "sample"
    assert reloaded["ranges"]["7d"]["days"][-1] == "2026-09-25"
    database = Path(env["XDG_CONFIG_HOME"]) / "ohealth" / "ohealth.sqlite"
    assert database.is_file()
    assert database.stat().st_mode & 0o777 == 0o600


def test_apple_export_xml_and_units(tmp: Path) -> None:
    env = isolate(tmp)
    enter_person(env)
    xml = tmp / "export.xml"
    xml.write_text(
        """<?xml version="1.0" encoding="UTF-8"?>
<HealthData locale="en_US">
  <ExportDate value="2026-09-25 12:00:00 -0500"/>
  <Record type="HKQuantityTypeIdentifierStepCount" unit="count" startDate="2026-09-24 08:00:00 -0500" endDate="2026-09-24 09:00:00 -0500" value="1000"/>
  <Record type="HKQuantityTypeIdentifierStepCount" unit="count" startDate="2026-09-24 10:00:00 -0500" endDate="2026-09-24 11:00:00 -0500" value="250"/>
  <Record type="HKQuantityTypeIdentifierDistanceWalkingRunning" unit="mi" startDate="2026-09-24 08:00:00 -0500" endDate="2026-09-24 09:00:00 -0500" value="1"/>
  <Record type="HKQuantityTypeIdentifierOxygenSaturation" unit="%" startDate="2026-09-24 08:00:00 -0500" endDate="2026-09-24 08:01:00 -0500" value="0.97"/>
  <Record type="HKQuantityTypeIdentifierBodyMass" unit="lb" startDate="2026-09-24 07:00:00 -0500" endDate="2026-09-24 07:00:00 -0500" value="180"/>
  <Record type="HKQuantityTypeIdentifierHeartRate" unit="count/min" startDate="2026-09-24 08:00:00 -0500" endDate="2026-09-24 08:00:00 -0500" value="60"/>
  <Record type="HKQuantityTypeIdentifierHeartRate" unit="count/min" startDate="2026-09-24 09:00:00 -0500" endDate="2026-09-24 09:00:00 -0500" value="80"/>
  <Record type="HKCategoryTypeIdentifierSleepAnalysis" unit="hr" startDate="2026-09-24 00:00:00 -0500" endDate="2026-09-24 02:00:00 -0500" value="1"/>
  <Record type="HKCategoryTypeIdentifierSleepAnalysis" unit="hr" startDate="2026-09-24 02:00:00 -0500" endDate="2026-09-24 03:00:00 -0500" value="0"/>
  <Record type="HKQuantityTypeIdentifierStepCount" unit="count" startDate="2026-09-25 08:00:00 -0500" endDate="2026-09-25 09:00:00 -0500" value="4000"/>
</HealthData>
"""
    )
    result = run(env, "ohealth_sync.py", ["--export", str(xml)])
    assert result.returncode == 0, result.stderr
    index = load_index(env)
    assert index["labeledSample"] is False
    assert index["source"] == "apple-health-export"
    assert index["exportedAt"] == "2026-09-25 12:00:00 -0500"
    window = index["ranges"]["7d"]
    assert window["days"] == ["2026-09-24", "2026-09-25"]
    steps = next(item for item in window["metrics"] if item["id"] == "steps")
    assert steps["series"] == [1250, 4000]
    distance = next(item for item in window["metrics"] if item["id"] == "distanceKm")
    assert abs(distance["series"][0] - 1.609344) < 0.001
    spo2 = next(item for item in window["metrics"] if item["id"] == "spo2")
    assert spo2["series"][0] == 97
    weight = next(item for item in window["metrics"] if item["id"] == "weightKg")
    assert abs(weight["series"][0] - 81.6466) < 0.01
    heart = next(item for item in window["metrics"] if item["id"] == "heartRate")
    assert heart["series"][0] == 70
    sleep = next(item for item in window["metrics"] if item["id"] == "sleepHours")
    assert sleep["series"][0] == 2
    assert sleep["series"][1] is None


def test_export_zip_and_empty_inbox(tmp: Path) -> None:
    env = isolate(tmp)
    enter_person(env)
    xml = tmp / "export.xml"
    xml.write_text(
        """<?xml version="1.0" encoding="UTF-8"?>
<HealthData>
  <ExportDate value="2026-09-01 00:00:00 +0000"/>
  <Record type="HKQuantityTypeIdentifierRestingHeartRate" unit="count/min" startDate="2026-09-01 06:00:00 +0000" endDate="2026-09-01 06:00:00 +0000" value="55"/>
</HealthData>
"""
    )
    archive = tmp / "export.zip"
    with zipfile.ZipFile(archive, "w") as zf:
        zf.write(xml, "apple_health_export/export.xml")
    result = run(env, "ohealth_sync.py", ["--export", str(archive)])
    assert result.returncode == 0, result.stderr
    index = load_index(env)
    resting = next(item for item in index["ranges"]["30d"]["metrics"] if item["id"] == "restingHr")
    assert resting["series"] == [55]
    config = (Path(env["XDG_CONFIG_HOME"]) / "ohealth" / "config").read_text()
    assert f"EXPORT={archive}" not in config
    xml.write_text(
        """<?xml version="1.0" encoding="UTF-8"?>
<HealthData>
  <Record type="HKQuantityTypeIdentifierRestingHeartRate" unit="count/min" startDate="2026-09-01 06:00:00 +0000" endDate="2026-09-01 06:00:00 +0000" value="99"/>
</HealthData>
"""
    )
    with zipfile.ZipFile(archive, "w") as zf:
        zf.write(xml, "apple_health_export/export.xml")
    again = run(env, "ohealth_sync.py", [])
    assert again.returncode == 0, again.stderr
    remembered = load_index(env)
    resting = next(item for item in remembered["ranges"]["30d"]["metrics"] if item["id"] == "restingHr")
    assert resting["series"] == [55]
    archive.unlink()
    kept = run(env, "ohealth_sync.py", [])
    assert kept.returncode == 0, kept.stderr
    remembered = load_index(env)
    resting = next(item for item in remembered["ranges"]["30d"]["metrics"] if item["id"] == "restingHr")
    assert resting["series"] == [55]
    database = Path(env["XDG_CONFIG_HOME"]) / "ohealth" / "ohealth.sqlite"
    assert database.is_file()
    status = json.loads((Path(env["XDG_CACHE_HOME"]) / "ohealth" / "status.json").read_text())
    assert status["state"] == "ready"
    assert "local database" in status["message"]

    env2 = isolate(tmp / "empty")
    result = run(env2, "ohealth_sync.py", [])
    assert result.returncode == 0, result.stderr
    status = json.loads((Path(env2["XDG_CACHE_HOME"]) / "ohealth" / "status.json").read_text())
    assert status["state"] == "choose"
    assert "person" in status["message"].lower()
    enter_person(env2, "Blake")
    status = json.loads((Path(env2["XDG_CACHE_HOME"]) / "ohealth" / "status.json").read_text())
    assert status["state"] == "empty"
    assert "HealthKit" in status["message"]
    index = load_index(env2)
    assert index["ranges"]["30d"]["dayCount"] == 0


def test_pick_uses_the_file_the_chooser_prints(tmp: Path) -> None:
    env = isolate(tmp)
    enter_person(env)
    xml = tmp / "export.xml"
    xml.write_text(
        """<?xml version="1.0" encoding="UTF-8"?>
<HealthData>
  <Record type="HKQuantityTypeIdentifierStepCount" unit="count" startDate="2026-09-24 08:00:00 -0500" endDate="2026-09-24 09:00:00 -0500" value="42"/>
</HealthData>
"""
    )
    bindir = tmp / "bin"
    bindir.mkdir()
    chooser = bindir / "omarchy-file-select"
    chooser.write_text("#!/bin/sh\nprintf '%s\\n' " + shlex.quote(str(xml)) + "\n")
    chooser.chmod(0o755)
    env["PATH"] = str(bindir) + os.pathsep + env.get("PATH", "")

    picked = run(env, "ohealth_sync.py", ["--pick"])
    assert picked.returncode == 0, picked.stderr
    index = load_index(env)
    steps = next(item for item in index["ranges"]["7d"]["metrics"] if item["id"] == "steps")
    assert steps["series"] == [42]
    again = run(env, "ohealth_sync.py", [])
    assert again.returncode == 0, again.stderr
    reloaded = load_index(env)
    steps = next(item for item in reloaded["ranges"]["7d"]["metrics"] if item["id"] == "steps")
    assert steps["series"] == [42]

    chooser.write_text("#!/bin/sh\nexit 1\n")
    cancelled = run(env, "ohealth_sync.py", ["--pick"])
    assert cancelled.returncode == 3, cancelled.stderr
    kept = load_index(env)
    steps = next(item for item in kept["ranges"]["7d"]["metrics"] if item["id"] == "steps")
    assert steps["series"] == [42]


def test_chooser_window_is_the_new_file_dialog(tmp: Path) -> None:
    sys.path.insert(0, str(BIN))
    import ohealth_sync

    before = {"0x1", "0x2"}
    clients = [
        {"address": "0x1", "title": "OHealth", "class": "org.quickshell"},
        {"address": "0x2", "title": "Notes", "class": "io.github.lgse.Strata"},
        {"address": "0x3", "title": "Choose a file", "class": "io.github.lgse.Strata.FileChooser"},
    ]
    found = ohealth_sync.chooser_client(clients, before, "Open Apple Health export")
    assert found is not None and found["address"] == "0x3"
    titled = dict(clients[2], title="Open Apple Health export", **{"class": "gtk"})
    assert ohealth_sync.chooser_client([clients[0], titled], before, "Open Apple Health export")["address"] == "0x3"
    assert ohealth_sync.chooser_client(clients, {"0x1", "0x2", "0x3"}, "Open Apple Health export") is None
    app = ohealth_sync.app_window(clients)
    assert app is not None and app["address"] == "0x1"


def test_health_auto_export_json(tmp: Path) -> None:
    env = isolate(tmp)
    enter_person(env)
    payload = {
        "data": {
            "metrics": [
                {
                    "name": "step_count",
                    "units": "count",
                    "data": [
                        {"qty": 1500, "date": "2026-09-20 00:00:00 -0500"},
                        {"qty": 2500, "date": "2026-09-21 00:00:00 -0500"},
                    ],
                },
                {
                    "name": "sleep_analysis",
                    "units": "hr",
                    "data": [{"date": "2026-09-20 00:00:00 -0500", "totalSleep": 7.5}],
                },
            ]
        }
    }
    path = tmp / "HealthAutoExport.json"
    path.write_text(json.dumps(payload))
    result = run(env, "ohealth_sync.py", ["--export", str(path)])
    assert result.returncode == 0, result.stderr
    index = load_index(env)
    assert index["source"] == "health-auto-export"
    steps = next(item for item in index["ranges"]["7d"]["metrics"] if item["id"] == "steps")
    assert steps["series"] == [1500, 2500]
    sleep = next(item for item in index["ranges"]["7d"]["metrics"] if item["id"] == "sleepHours")
    assert sleep["series"][0] == 7.5


def test_reimport_adds_new_records_without_duplicating(tmp: Path) -> None:
    env = isolate(tmp)
    enter_person(env)
    first = tmp / "first.xml"
    first.write_text(
        """<?xml version="1.0" encoding="UTF-8"?>
<HealthData>
  <Record type="HKQuantityTypeIdentifierStepCount" unit="count" startDate="2026-09-24 08:00:00 -0500" endDate="2026-09-24 09:00:00 -0500" value="1000"/>
  <Record type="HKQuantityTypeIdentifierStepCount" unit="count" startDate="2026-09-24 10:00:00 -0500" endDate="2026-09-24 11:00:00 -0500" value="250"/>
</HealthData>
"""
    )
    assert run(env, "ohealth_sync.py", ["--export", str(first)]).returncode == 0
    repeat = run(env, "ohealth_sync.py", ["--export", str(first)])
    assert repeat.returncode == 0, repeat.stderr
    index = load_index(env)
    steps = next(item for item in index["ranges"]["7d"]["metrics"] if item["id"] == "steps")
    assert steps["series"] == [1250]

    second = tmp / "second.xml"
    second.write_text(
        """<?xml version="1.0" encoding="UTF-8"?>
<HealthData>
  <Record type="HKQuantityTypeIdentifierStepCount" unit="count" startDate="2026-09-24 08:00:00 -0500" endDate="2026-09-24 09:00:00 -0500" value="1000"/>
  <Record type="HKQuantityTypeIdentifierStepCount" unit="count" startDate="2026-09-25 08:00:00 -0500" endDate="2026-09-25 09:00:00 -0500" value="4000"/>
  <Record type="HKQuantityTypeIdentifierHeartRate" unit="count/min" startDate="2026-09-24 08:00:00 -0500" endDate="2026-09-24 08:00:00 -0500" value="60"/>
</HealthData>
"""
    )
    merged = run(env, "ohealth_sync.py", ["--export", str(second)])
    assert merged.returncode == 0, merged.stderr
    index = load_index(env)
    window = index["ranges"]["7d"]
    assert window["days"] == ["2026-09-24", "2026-09-25"]
    steps = next(item for item in window["metrics"] if item["id"] == "steps")
    assert steps["series"] == [1250, 4000]
    heart = next(item for item in window["metrics"] if item["id"] == "heartRate")
    assert heart["series"][0] == 60
    plain = run(env, "ohealth_sync.py", [])
    assert plain.returncode == 0, plain.stderr
    index = load_index(env)
    steps = next(item for item in index["ranges"]["7d"]["metrics"] if item["id"] == "steps")
    assert steps["series"] == [1250, 4000]


def test_database_selection_is_stored(tmp: Path) -> None:
    env = isolate(tmp)
    enter_person(env)
    first = tmp / "first.xml"
    first.write_text(
        """<?xml version="1.0" encoding="UTF-8"?>
<HealthData>
  <Record type="HKQuantityTypeIdentifierStepCount" unit="count" startDate="2026-09-24 08:00:00 -0500" endDate="2026-09-24 09:00:00 -0500" value="11"/>
</HealthData>
"""
    )
    assert run(env, "ohealth_sync.py", ["--export", str(first)]).returncode == 0
    catalog = Path(env["XDG_CONFIG_HOME"]) / "ohealth" / "ohealth.sqlite"
    import sqlite3
    saved = sqlite3.connect(catalog).execute("SELECT value FROM meta WHERE key = 'database'").fetchone()[0]
    assert Path(saved) == catalog

    other = tmp / "other.sqlite"
    second = tmp / "second.xml"
    second.write_text(
        """<?xml version="1.0" encoding="UTF-8"?>
<HealthData>
  <Record type="HKQuantityTypeIdentifierStepCount" unit="count" startDate="2026-09-24 08:00:00 -0500" endDate="2026-09-24 09:00:00 -0500" value="88"/>
</HealthData>
"""
    )
    added = run(env, "ohealth_sync.py", ["--database", str(other), "--add-user", "Alex"])
    assert added.returncode == 0, added.stderr
    other_people = json.loads((Path(env["XDG_CACHE_HOME"]) / "ohealth" / "users.json").read_text())
    other_id = next(item["id"] for item in other_people["users"] if item["name"] == "Alex")
    switched = run(env, "ohealth_sync.py", ["--user", other_id, "--export", str(second)])
    assert switched.returncode == 0, switched.stderr
    saved = sqlite3.connect(catalog).execute("SELECT value FROM meta WHERE key = 'database'").fetchone()[0]
    assert Path(saved) == other.resolve()
    index = load_index(env)
    steps = next(item for item in index["ranges"]["7d"]["metrics"] if item["id"] == "steps")
    assert steps["series"] == [88]
    status = json.loads((Path(env["XDG_CACHE_HOME"]) / "ohealth" / "status.json").read_text())
    assert status["database"] == str(other.resolve())

    back = run(env, "ohealth_sync.py", ["--database", str(catalog)])
    assert back.returncode == 0, back.stderr
    index = load_index(env)
    steps = next(item for item in index["ranges"]["7d"]["metrics"] if item["id"] == "steps")
    assert steps["series"] == [11]
    saved = sqlite3.connect(catalog).execute("SELECT value FROM meta WHERE key = 'database'").fetchone()[0]
    assert Path(saved) == catalog.resolve()


def test_xrays_and_labs_are_in_the_database_for_the_agent(tmp: Path) -> None:
    env = isolate(tmp)
    enter_person(env, "Alex")
    image = tmp / "chest.png"
    image.write_bytes(b"\x89PNG\r\n\x1a\nnot-really")
    blood = tmp / "cbc.pdf"
    blood.write_text("hemoglobin 14")
    urine = tmp / "ua.pdf"
    urine.write_text("negative")
    assert run(env, "ohealth_sync.py", ["--xray", "--file", str(image)]).returncode == 0
    assert run(env, "ohealth_sync.py", ["--blood", "--file", str(blood)]).returncode == 0
    assert run(env, "ohealth_sync.py", ["--urine", "--file", str(urine)]).returncode == 0

    import sqlite3
    config = Path(env["XDG_CONFIG_HOME"]) / "ohealth"
    database = config / "ohealth.sqlite"
    rows = sqlite3.connect(database).execute("SELECT kind, name, path FROM files ORDER BY kind").fetchall()
    assert {row[0] for row in rows} == {"blood", "urine", "xray"}
    originals = {"chest.png": image, "cbc.pdf": blood, "ua.pdf": urine}
    for _kind, name, stored in rows:
        path = Path(stored)
        assert path.is_file()
        assert config in path.parents
        assert path.read_bytes() == originals[name].read_bytes()
    listed = json.loads((Path(env["XDG_CACHE_HOME"]) / "ohealth" / "files.json").read_text())
    assert listed["xrays"][0]["name"] == "chest.png"
    assert listed["blood"][0]["name"] == "cbc.pdf"
    assert listed["urine"][0]["name"] == "ua.pdf"

    chosen = run(env, "ohealth_agent.py", ["set", "grok"])
    assert chosen.returncode == 0, chosen.stderr
    asked = run(
        env,
        "ohealth_agent.py",
        ["chat", "--dry-run"],
        stdin=json.dumps({
            "message": "Review the selected chest X-ray and compare it with my steps.",
            "scope": "selected",
            "focusId": listed["xrays"][0]["id"],
            "metric": "Steps",
            "range": "7 days",
            "day": "2026-09-24",
            "dayValue": "1000",
        }),
    )
    assert asked.returncode == 0, asked.stderr
    assert "grok" == json.loads(asked.stdout)["argv"][0]
    assert "--prompt-file" in json.loads(asked.stdout)["argv"]
    assert "--output-format" in json.loads(asked.stdout)["argv"]
    prompt = json.loads(asked.stdout)["prompt"]
    assert str(database) in prompt
    assert "Read that database" in prompt
    assert "Alex" in prompt
    assert "user_id" in prompt
    assert "chest.png" in prompt
    assert "Review the selected chest X-ray" in prompt
    assert "selected " in prompt
    whole = run(
        env,
        "ohealth_agent.py",
        ["chat", "--dry-run"],
        stdin=json.dumps({"message": "Summarize every stored day.", "scope": "all"}),
    )
    assert whole.returncode == 0, whole.stderr
    assert "whole database" in json.loads(whole.stdout)["prompt"]


def test_people_keep_separate_records(tmp: Path) -> None:
    env = isolate(tmp)
    alex = enter_person(env, "Alex")
    image = tmp / "chest.png"
    image.write_bytes(b"\x89PNG\r\n\x1a\nnot-really")
    alex_xml = tmp / "alex.xml"
    alex_xml.write_text(
        """<?xml version="1.0" encoding="UTF-8"?>
<HealthData>
  <Record type="HKQuantityTypeIdentifierStepCount" unit="count" startDate="2026-09-24 08:00:00 -0500" endDate="2026-09-24 09:00:00 -0500" value="11"/>
</HealthData>
"""
    )
    assert run(env, "ohealth_sync.py", ["--export", str(alex_xml)]).returncode == 0
    assert run(env, "ohealth_sync.py", ["--xray", "--file", str(image)]).returncode == 0
    blake_added = run(env, "ohealth_sync.py", ["--add-user", "Blake"])
    assert blake_added.returncode == 0, blake_added.stderr
    people = json.loads((Path(env["XDG_CACHE_HOME"]) / "ohealth" / "users.json").read_text())
    blake = next(item["id"] for item in people["users"] if item["name"] == "Blake")
    blake_xml = tmp / "blake.xml"
    blake_xml.write_text(
        """<?xml version="1.0" encoding="UTF-8"?>
<HealthData>
  <Record type="HKQuantityTypeIdentifierStepCount" unit="count" startDate="2026-09-24 08:00:00 -0500" endDate="2026-09-24 09:00:00 -0500" value="88"/>
</HealthData>
"""
    )
    opened = run(env, "ohealth_sync.py", ["--user", blake, "--export", str(blake_xml)])
    assert opened.returncode == 0, opened.stderr
    index = load_index(env)
    steps = next(item for item in index["ranges"]["7d"]["metrics"] if item["id"] == "steps")
    assert steps["series"] == [88]
    files = json.loads((Path(env["XDG_CACHE_HOME"]) / "ohealth" / "files.json").read_text())
    assert files["xrays"] == []
    back = run(env, "ohealth_sync.py", ["--user", alex])
    assert back.returncode == 0, back.stderr
    index = load_index(env)
    steps = next(item for item in index["ranges"]["7d"]["metrics"] if item["id"] == "steps")
    assert steps["series"] == [11]
    files = json.loads((Path(env["XDG_CACHE_HOME"]) / "ohealth" / "files.json").read_text())
    assert files["xrays"][0]["name"] == "chest.png"


def test_existing_rows_become_a_person(tmp: Path) -> None:
    env = isolate(tmp)
    sys.path.insert(0, str(BIN))
    from ohealth_sync import DAY_FIELDS

    database = Path(env["XDG_CONFIG_HOME"]) / "ohealth" / "ohealth.sqlite"
    database.parent.mkdir(parents=True)
    import sqlite3
    conn = sqlite3.connect(database)
    columns = ", ".join(f"{name} REAL" for name in DAY_FIELDS)
    conn.execute(f"CREATE TABLE days (date TEXT PRIMARY KEY, {columns})")
    conn.execute("INSERT INTO days (date, steps) VALUES ('2026-09-24', 17)")
    conn.execute("CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT NOT NULL)")
    conn.execute("INSERT INTO meta (key, value) VALUES ('stored', '1')")
    conn.commit()
    conn.close()
    listed = run(env, "ohealth_sync.py", ["--users"])
    assert listed.returncode == 0, listed.stderr
    people = json.loads((Path(env["XDG_CACHE_HOME"]) / "ohealth" / "users.json").read_text())
    assert people["current"] == ""
    assert people["users"][0]["name"] == "Existing"
    opened = run(env, "ohealth_sync.py", ["--user", people["users"][0]["id"]])
    assert opened.returncode == 0, opened.stderr
    index = load_index(env)
    steps = next(item for item in index["ranges"]["7d"]["metrics"] if item["id"] == "steps")
    assert steps["series"] == [17]


def test_import_requires_a_person(tmp: Path) -> None:
    env = isolate(tmp)
    xml = tmp / "export.xml"
    xml.write_text(
        """<?xml version="1.0" encoding="UTF-8"?>
<HealthData>
  <Record type="HKQuantityTypeIdentifierStepCount" unit="count" startDate="2026-09-24 08:00:00 -0500" endDate="2026-09-24 09:00:00 -0500" value="1"/>
</HealthData>
"""
    )
    result = run(env, "ohealth_sync.py", ["--export", str(xml)])
    assert result.returncode == 1
    assert "person" in result.stderr.lower()


def test_missing_export_is_an_error(tmp: Path) -> None:
    env = isolate(tmp)
    result = run(env, "ohealth_sync.py", ["--export", str(tmp / "nope.zip")])
    assert result.returncode == 1
    status = json.loads((Path(env["XDG_CACHE_HOME"]) / "ohealth" / "status.json").read_text())
    assert status["state"] == "error"
    assert "does not exist" in status["message"]


def test_agent_picker_writes_omarchy_file(tmp: Path) -> None:
    env = isolate(tmp)
    listed = run(env, "ohealth_agent.py", ["list"])
    assert listed.returncode == 0, listed.stderr
    body = json.loads(listed.stdout)
    assert body["selected"] == ""
    ids = [item["id"] for item in body["agents"]]
    assert ids[:3] == ["pi", "omp", "opencode"]
    assert "grok" in ids and "cursor-agent" in ids
    assert body["agentFile"].endswith("/.config/omarchy/defaults/agent")
    grok = next(item for item in body["agents"] if item["id"] == "grok")
    # On this machine grok is installed; the assertion is about the flag existing.
    assert "installed" in grok

    bad = run(env, "ohealth_agent.py", ["set", "not-an-agent"])
    assert bad.returncode != 0

    chosen = run(env, "ohealth_agent.py", ["set", "grok"])
    assert chosen.returncode == 0, chosen.stderr
    saved = Path(env["OHEALTH_AGENT_FILE"]).read_text().strip()
    assert saved == "grok"
    again = json.loads(run(env, "ohealth_agent.py", ["get"]).stdout)
    assert again["selected"] == "grok"

    ask = run(
        env,
        "ohealth_agent.py",
        ["ask", "--dry-run"],
        stdin=json.dumps({
            "sample": True,
            "range": "7 days",
            "metric": "Resting heart rate",
            "day": "2026-09-25",
            "dayValue": "62 bpm",
            "aggregate": "Daily average",
            "value": "60",
            "unit": "bpm",
            "trend": "Daily average 60 bpm, 4% above the previous 7 days.",
            "source": "sample",
            "days": ["2026-09-24", "2026-09-25"],
            "series": [58, 62],
        }),
    )
    assert ask.returncode == 0, ask.stderr
    payload = json.loads(ask.stdout)
    assert payload["dryRun"] is True
    assert payload["agent"] == "grok"
    assert payload["argv"][0] in {"grok", "omarchy-agent"}
    assert "invented sample data" in payload["prompt"].lower() or "Invented" in payload["prompt"] or "sample data" in payload["prompt"]
    assert "58" in payload["prompt"] and "62" in payload["prompt"]
    assert "not medical advice" in payload["prompt"].lower() or "Do not invent" in payload["prompt"]
    # Dry-run must not start a process; no pid.
    assert "pid" not in payload


def main() -> None:
    import tempfile
    tests = [
        test_sample_is_labeled_and_ranged,
        test_apple_export_xml_and_units,
        test_export_zip_and_empty_inbox,
        test_pick_uses_the_file_the_chooser_prints,
        test_chooser_window_is_the_new_file_dialog,
        test_health_auto_export_json,
        test_reimport_adds_new_records_without_duplicating,
        test_database_selection_is_stored,
        test_xrays_and_labs_are_in_the_database_for_the_agent,
        test_people_keep_separate_records,
        test_existing_rows_become_a_person,
        test_import_requires_a_person,
        test_missing_export_is_an_error,
        test_agent_picker_writes_omarchy_file,
    ]
    failed = 0
    with tempfile.TemporaryDirectory(prefix="ohealth-test-") as raw:
        root = Path(raw)
        for test in tests:
            try:
                test(root / test.__name__)
            except Exception as exc:  # noqa: BLE001
                failed += 1
                print(f"FAIL {test.__name__}: {exc}", file=sys.stderr)
            else:
                print(f"ok   {test.__name__}")
    if failed:
        sys.exit(1)
    print(f"{len(tests)} passed")


if __name__ == "__main__":
    main()
