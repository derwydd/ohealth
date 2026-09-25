#!/usr/bin/env python3
"""Chooser for Omarchy's system agent, used from the health window.

Omarchy stores the default in ~/.config/omarchy/defaults/agent. That file is
what `omarchy-default-agent` reads and writes. This script lists the same
agents that command accepts, records the choice in that file, and asks the
chosen agent about the health slice on stdin.

`omarchy-default-agent <name>` also installs the agent and then launches it,
so choosing one here writes the file directly instead of exec'ing that
command. Asking prefers `omarchy-agent --prompt`, which is how the shell
starts the default agent with a task. When that wrapper is not installed,
the same per-agent argv from bin/omarchy-agent is used.

    ohealth_agent.py list
    ohealth_agent.py get
    ohealth_agent.py set <id>
    ohealth_agent.py ask [--dry-run]   # JSON health slice on stdin
"""

from __future__ import annotations

import argparse
import json
import os
import shutil
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from ohealth_paths import agent_file, cache_dir  # noqa: E402

# ids, display names, and argv[0] from bin/omarchy-default-agent.
CATALOG = (
    ("pi", "Pi", "pi"),
    ("omp", "Oh My Pi", "omp"),
    ("opencode", "OpenCode", "opencode"),
    ("ori", "Ori", "ori"),
    ("claude", "Claude Code", "claude"),
    ("codex", "Codex", "codex"),
    ("grok", "Grok", "grok"),
    ("openclaw", "OpenClaw", "openclaw"),
    ("agy", "Antigravity", "agy"),
    ("hermes", "Hermes", "hermes"),
    ("copilot", "GitHub Copilot", "copilot"),
    ("crush", "Crush", "crush"),
    ("cursor-agent", "Cursor CLI", "cursor-agent"),
    ("muse", "Muse Code", "muse"),
)

KNOWN = {item[0] for item in CATALOG}


def emit(obj: dict) -> None:
    print(json.dumps(obj), flush=True)


def fail(message: str, **extra) -> None:
    emit({"ok": False, "error": message, **extra})
    sys.exit(1)


def read_selected() -> str:
    path = agent_file()
    if not path.is_file():
        return ""
    line = path.read_text().splitlines()
    return line[0].strip() if line else ""


def command_exists(binary: str) -> bool:
    return shutil.which(binary) is not None


def list_payload() -> dict:
    selected = read_selected()
    agents = []
    for agent_id, name, binary in CATALOG:
        agents.append({
            "id": agent_id,
            "name": name,
            "command": binary,
            "installed": command_exists(binary),
            "selected": agent_id == selected,
        })
    if selected and selected not in KNOWN:
        agents.append({
            "id": selected,
            "name": selected,
            "command": selected,
            "installed": command_exists(selected),
            "selected": True,
        })
    return {
        "ok": True,
        "selected": selected,
        "agentFile": str(agent_file()),
        "omarchySetter": command_exists("omarchy-default-agent"),
        "omarchyLauncher": command_exists("omarchy-agent"),
        "agents": agents,
    }


def cmd_set(agent_id: str) -> None:
    if agent_id not in KNOWN:
        fail(
            f"Unknown agent {agent_id}. Omarchy accepts: " + ", ".join(item[0] for item in CATALOG)
        )
    path = agent_file()
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(agent_id + "\n")
    os.chmod(path, 0o600)
    binary = next(item[2] for item in CATALOG if item[0] == agent_id)
    emit({
        "ok": True,
        "selected": agent_id,
        "installed": command_exists(binary),
        "agentFile": str(path),
        "note": "Wrote the Omarchy default-agent file. omarchy-default-agent reads this path.",
    })


def build_prompt(payload: dict) -> str:
    sample = bool(payload.get("sample"))
    lines = [
        "You are answering from OHealth, an Omarchy window on Apple Health data.",
        "Use only the measurements in this message. Do not invent numbers, ranges, or diagnoses.",
        "Say what changed across the window, what is steady, and stop. This is not medical advice.",
    ]
    if sample:
        lines.append(
            "IMPORTANT: these figures are invented sample data so the window can be previewed. "
            "They are not a record of anyone's health. Say that in the first sentence."
        )
    lines.append("")
    lines.append(f"Range: {payload.get('range') or 'unknown'}")
    lines.append(f"Focus: {payload.get('metric') or 'unknown'}")
    if payload.get("day"):
        lines.append(f"Selected day: {payload.get('day')} = {payload.get('dayValue')}")
    if payload.get("aggregate"):
        lines.append(f"Window aggregate: {payload.get('aggregate')} {payload.get('value')} {payload.get('unit') or ''}".rstrip())
    if payload.get("trend"):
        lines.append(f"Trend already computed: {payload.get('trend')}")
    if payload.get("source"):
        lines.append(f"Source: {payload.get('source')}")
    series = payload.get("series") or []
    days = payload.get("days") or []
    lines.append("")
    lines.append("Daily values (date value):")
    for index, value in enumerate(series):
        day = days[index] if index < len(days) else str(index)
        shown = "—" if value is None else value
        lines.append(f"{day} {shown}")
    return "\n".join(lines).strip() + "\n"


def argv_for(agent_id: str, prompt: str) -> list[str]:
    """Match bin/omarchy-agent. Prefer the Omarchy wrapper when it exists."""
    if command_exists("omarchy-agent"):
        return ["omarchy-agent", "--prompt", prompt]
    commands = {
        "opencode": ["opencode", "--auto", "--prompt", prompt],
        "agy": ["agy", "--dangerously-skip-permissions", "--prompt-interactive", prompt],
        "copilot": ["copilot", "--allow-all", "--interactive", prompt],
        "crush": ["crush", "run", prompt],
        "claude": ["claude", "--permission-mode", "auto", "--", prompt],
        "grok": ["grok", "--permission-mode", "bypassPermissions", "--", prompt],
        "openclaw": ["openclaw", "--message", prompt],
        "codex": ["codex", "--approve-for-me", "--", prompt],
        "cursor-agent": ["cursor-agent", "--yolo", "--trust", "agent", "--", prompt],
        "hermes": ["hermes", "chat", "--yolo", "--tui", f"--query={prompt}"],
        "muse": ["muse", "--approval-mode", "never", "--", prompt],
        "omp": ["omp", "--auto-approve", "--", prompt],
        "ori": ["ori", "code", "--interactive", "--prompt", prompt],
        "pi": ["pi", prompt],
    }
    if agent_id not in commands:
        fail(f"Unsupported default agent: {agent_id}")
    return commands[agent_id]


def cmd_ask(dry_run: bool) -> None:
    raw = sys.stdin.read()
    try:
        payload = json.loads(raw) if raw.strip() else {}
    except json.JSONDecodeError as exc:
        fail(f"The health slice was not JSON: {exc}")
    selected = read_selected()
    if not selected:
        fail("No Omarchy agent is chosen. Pick one in OHealth, or run omarchy-default-agent.")
    prompt = build_prompt(payload)
    argv = argv_for(selected, prompt)
    log_path = cache_dir() / "agent-ask.log"
    binary = argv[0]
    installed = command_exists(binary)
    result = {
        "ok": True,
        "agent": selected,
        "argv0": binary,
        "installed": installed,
        "viaOmarchy": binary == "omarchy-agent",
        "log": str(log_path),
        "prompt": prompt,
    }
    if dry_run:
        result["dryRun"] = True
        result["argv"] = argv
        emit(result)
        return
    if not installed:
        name = selected
        fail(
            f"{name} is not installed. The choice is saved in {agent_file()}. "
            "On Omarchy, `omarchy default agent " + selected + "` installs it and then launches it."
        )
    cache_dir().mkdir(parents=True, exist_ok=True)
    log = log_path.open("ab")
    try:
        proc = subprocess.Popen(
            argv,
            stdin=subprocess.DEVNULL,
            stdout=log,
            stderr=subprocess.STDOUT,
            start_new_session=True,
        )
    finally:
        log.close()
    emit({
        "ok": True,
        "agent": selected,
        "pid": proc.pid,
        "log": str(log_path),
        "viaOmarchy": binary == "omarchy-agent",
    })


def main() -> None:
    parser = argparse.ArgumentParser(description="OHealth Omarchy agent picker")
    sub = parser.add_subparsers(dest="cmd", required=True)
    sub.add_parser("list")
    sub.add_parser("get")
    set_cmd = sub.add_parser("set")
    set_cmd.add_argument("agent_id")
    ask = sub.add_parser("ask")
    ask.add_argument("--dry-run", action="store_true")
    args = parser.parse_args()
    if args.cmd == "list":
        emit(list_payload())
    elif args.cmd == "get":
        emit({"ok": True, "selected": read_selected(), "agentFile": str(agent_file())})
    elif args.cmd == "set":
        cmd_set(args.agent_id)
    else:
        cmd_ask(args.dry_run)


if __name__ == "__main__":
    main()
