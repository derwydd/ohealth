#!/usr/bin/env python3
"""Data-layer checks for sync, Apple-helper status, and the agent picker.

Uses a temporary home. Does not read or write the real iCloud cookie jar
or ~/.config/omarchy/defaults/agent.
"""

from __future__ import annotations

import json
import os
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


def test_sample_is_labeled_and_ranged(tmp: Path) -> None:
    env = isolate(tmp)
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
    status = json.loads((Path(env["XDG_CACHE_HOME"]) / "ohealth" / "status.json").read_text())
    assert status["state"] == "ready"
    assert status["labeledSample"] is True


def test_apple_export_xml_and_units(tmp: Path) -> None:
    env = isolate(tmp)
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

    env2 = isolate(tmp / "empty")
    result = run(env2, "ohealth_sync.py", [])
    assert result.returncode == 0, result.stderr
    status = json.loads((Path(env2["XDG_CACHE_HOME"]) / "ohealth" / "status.json").read_text())
    assert status["state"] == "empty"
    assert "HealthKit" in status["message"]
    index = load_index(env2)
    assert index["ranges"]["30d"]["dayCount"] == 0


def test_health_auto_export_json(tmp: Path) -> None:
    env = isolate(tmp)
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


def test_missing_export_is_an_error(tmp: Path) -> None:
    env = isolate(tmp)
    result = run(env, "ohealth_sync.py", ["--export", str(tmp / "nope.zip")])
    assert result.returncode == 1
    status = json.loads((Path(env["XDG_CACHE_HOME"]) / "ohealth" / "status.json").read_text())
    assert status["state"] == "error"
    assert "does not exist" in status["message"]


def test_helper_status_logout_and_missing_pyicloud(tmp: Path) -> None:
    env = isolate(tmp)
    status = run(env, "ohealth_helper.py", ["status"])
    assert status.returncode == 0, status.stderr
    body = json.loads(status.stdout)
    assert body["signedIn"] is False
    assert body["backend"] in {"missing", "pyicloud", "pyicloud_ipd"}
    login = run(env, "ohealth_helper.py", ["login", "--username", "person@icloud.com", "--save-config"], stdin="secret\n")
    # Without pyicloud this is a clean error and the password is not in the config.
    if body["backend"] == "missing":
        assert login.returncode != 0
        message = json.loads(login.stdout)
        assert message["ok"] is False
        assert "pyicloud" in message["error"]
        config = (Path(env["XDG_CONFIG_HOME"]) / "ohealth" / "config").read_text()
        assert "secret" not in config
        assert not any(line.strip().startswith("APPLE_ID=") for line in config.splitlines())
    else:
        # A live sign-in is not attempted here beyond what the library does with a fake password.
        # Either Apple rejects it or the library errors. The password must not land in config
        # unless ok is true, which a fake password must not achieve.
        config = (Path(env["XDG_CONFIG_HOME"]) / "ohealth" / "config").read_text()
        assert "secret" not in config

    # Writing an id and logging out removes only that line.
    sys.path.insert(0, str(BIN))
    for key, value in env.items():
        if key.startswith(("OHEALTH", "XDG", "HOME")):
            os.environ[key] = value
    import importlib
    import ohealth_paths
    importlib.reload(ohealth_paths)
    ohealth_paths.write_apple_id("person@icloud.com")
    assert ohealth_paths.read_config()["APPLE_ID"] == "person@icloud.com"
    logged_out = run(env, "ohealth_helper.py", ["logout"])
    assert logged_out.returncode == 0, logged_out.stderr
    importlib.reload(ohealth_paths)
    assert "APPLE_ID" not in ohealth_paths.read_config()
    note = json.loads(logged_out.stdout)
    assert note["cookiesKept"] is True


def test_connect_passes_accept_terms_when_supported(tmp: Path) -> None:
    env = isolate(tmp)
    for key, value in env.items():
        if key.startswith(("OHEALTH", "XDG", "HOME")):
            os.environ[key] = value
    sys.path.insert(0, str(BIN))
    import importlib
    import ohealth_helper
    importlib.reload(ohealth_helper)

    seen: dict = {}

    class Current:
        def __init__(self, username, password=None, cookie_directory=None, accept_terms=False):
            seen["current"] = {
                "username": username,
                "password": password,
                "cookie_directory": cookie_directory,
                "accept_terms": accept_terms,
            }

    class Vendored:
        def __init__(self, domain, username, password_fn, cookie_directory=None):
            seen["vendored"] = {
                "domain": domain,
                "username": username,
                "password": password_fn(),
                "cookie_directory": cookie_directory,
            }

    class Ancient:
        def __init__(self, username, password=None):
            seen["ancient"] = {"username": username, "password": password}

    cookies = tmp / "cookies"
    ohealth_helper.connect("pyicloud", Current, "person@icloud.com", lambda: "secret", str(cookies))
    assert seen["current"]["accept_terms"] is True
    assert seen["current"]["cookie_directory"] == str(cookies)
    assert seen["current"]["password"] == "secret"
    assert cookies.is_dir()

    ohealth_helper.connect("pyicloud_ipd", Vendored, "person@icloud.com", lambda: "secret", str(cookies))
    assert seen["vendored"]["domain"] == "com"
    assert seen["vendored"]["cookie_directory"] == str(cookies)
    assert "accept_terms" not in seen["vendored"]

    ohealth_helper.connect("pyicloud", Ancient, "person@icloud.com", lambda: "secret", str(cookies))
    assert seen["ancient"]["password"] == "secret"

    terms = type("PyiCloudAcceptTermsException", (Exception,), {})
    assert ohealth_helper.needs_terms(terms("Could not get terms version"))
    assert ohealth_helper.needs_terms(
        Exception("You must accept the updated terms of service to continue.")
    )
    assert not ohealth_helper.needs_terms(Exception("wrong code"))


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
        test_health_auto_export_json,
        test_missing_export_is_an_error,
        test_helper_status_logout_and_missing_pyicloud,
        test_connect_passes_accept_terms_when_supported,
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
