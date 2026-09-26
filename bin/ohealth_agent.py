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
import re
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


def read_payload(what: str) -> dict:
    """One JSON line. The window writes the line and leaves the pipe open."""
    raw = sys.stdin.readline()
    try:
        return json.loads(raw) if raw.strip() else {}
    except json.JSONDecodeError as exc:
        fail(f"The {what} was not JSON: {exc}")


def cmd_ask(dry_run: bool) -> None:
    payload = read_payload("health slice")
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


def reply_argv(agent_id: str, prompt_path: Path, prompt: str) -> list[str]:
    """Run one turn and print the answer on stdout.

    omarchy-agent without --inline opens a terminal, so the sidebar never
    sees the reply. Headless flags keep the answer in this process.
    """
    if agent_id == "grok":
        return [
            "grok",
            "--prompt-file",
            str(prompt_path),
            "--permission-mode",
            "bypassPermissions",
            "--output-format",
            "plain",
        ]
    if agent_id == "claude":
        return ["claude", "-p", "--permission-mode", "auto", "--", prompt]
    if command_exists("omarchy-agent"):
        return ["omarchy-agent", "--inline", "--prompt", prompt]
    return argv_for(agent_id, prompt)


def build_chat_prompt(payload: dict, agent_id: str, scope: str) -> str:
    """Tell the agent where the database is and to read it for this message."""
    from ohealth_sync import DAY_FIELDS, current_person, list_files, load_chat, selected_db_path

    database = str(selected_db_path())
    user_id, user_name = current_person()
    lines = [
        "You are answering in OHealth. This is not medical advice.",
        "Do not invent measurements, image findings, or lab values.",
        "",
        f"The health database is sqlite at:\n  {database}",
        f"The current person is {user_name} (user_id {user_id}).",
        "Read that database yourself to answer the user's instruction.",
        "Only read rows with that user_id. Do not read anyone else's days, samples, files, or chat.",
        "You can query it with sqlite3. Tables:",
        "  users(id, name, created_at)",
        f"  days(user_id, date, {', '.join(DAY_FIELDS)})",
        "  samples(user_id, id, day, field, op, value, at)",
        "  files(id, user_id, kind, name, path, added_at)",
        "kind is xray, blood, or urine. Open the file at path when the user asks you to review an X-ray or a lab result.",
        "",
    ]
    if payload.get("sample"):
        lines.append(
            "IMPORTANT: the numbers in this database are invented sample data. "
            "They are not a record of anyone's health. Say that in the first sentence."
        )
        lines.append("")
    if scope == "all":
        lines.append("Scope: this person's whole database. Do not stop at the day on screen, and do not read another user_id.")
    else:
        lines.append("Scope: start with the selection below, then read the database if the instruction needs more.")
        if payload.get("range"):
            lines.append(f"Range: {payload.get('range')}")
        if payload.get("metric"):
            lines.append(f"Metric: {payload.get('metric')}")
        if payload.get("day"):
            lines.append(f"Selected day: {payload.get('day')} = {payload.get('dayValue') or '—'}")
        if payload.get("trend"):
            lines.append(f"Trend already computed: {payload.get('trend')}")
    focus = payload.get("focusId") or ""
    files = list_files()
    lines.append("")
    lines.append("Files referenced by the database:")
    if not files:
        lines.append("  (none imported)")
    for item in files:
        mark = "  selected " if item["id"] == focus else "  "
        lines.append(f"{mark}{item['kind']}: {item['name']} -> {item['path']}")
    history = load_chat(8)
    if history:
        lines.append("")
        lines.append("Recent conversation:")
        for turn in history:
            who = "User" if turn["role"] == "user" else turn.get("agent") or "Agent"
            lines.append(f"{who}: {turn['body']}")
    lines.append("")
    lines.append("Instruction:")
    lines.append(str(payload.get("message") or "").strip())
    lines.append("")
    lines.append(f"Reply as {agent_id}. Quote the database or the file when you use a number or a finding.")
    return "\n".join(lines).strip() + "\n"


def cmd_chat(dry_run: bool) -> None:
    from ohealth_sync import add_chat_message, current_person

    if not current_person()[0]:
        fail("Choose a person in OHealth before asking.")
    payload = read_payload("message")
    message = str(payload.get("message") or "").strip()
    if not message:
        fail("Write a message first.")
    selected = read_selected()
    if not selected:
        fail("No Omarchy agent is chosen. Pick one in OHealth, or run omarchy-default-agent.")
    scope = "all" if payload.get("scope") == "all" else "selected"
    if not dry_run:
        add_chat_message("user", message, selected, scope)
    prompt = build_chat_prompt(payload, selected, scope)
    prompt_path = cache_dir() / "chat-prompt.txt"
    cache_dir().mkdir(parents=True, exist_ok=True)
    prompt_path.write_text(prompt, encoding="utf-8")
    os.chmod(prompt_path, 0o600)
    argv = reply_argv(selected, prompt_path, prompt)
    if dry_run:
        emit({
            "ok": True,
            "dryRun": True,
            "agent": selected,
            "argv": argv,
            "prompt": prompt,
        })
        return
    binary = argv[0]
    if not command_exists(binary):
        fail(
            f"{selected} is not installed. The choice is saved in {agent_file()}. "
            "On Omarchy, `omarchy default agent " + selected + "` installs it and then launches it."
        )
    log_path = cache_dir() / "agent-ask.log"
    from ohealth_paths import home
    proc = subprocess.run(
        argv,
        stdin=subprocess.DEVNULL,
        capture_output=True,
        text=True,
        cwd=str(home()),
    )
    reply = (proc.stdout or "").strip()
    if not reply:
        reply = (proc.stderr or "").strip() or f"The agent exited ({proc.returncode}) without a reply."
    reply = re.sub(r"\x1b\[[0-9;?]*[ -/]*[@-~]", "", reply).strip()
    if len(reply) > 20000:
        reply = reply[:20000] + "\n…"
    add_chat_message("agent", reply, selected, scope)
    with log_path.open("a", encoding="utf-8") as log:
        log.write(f"\n--- {selected} ---\n{reply}\n")
    emit({
        "ok": True,
        "agent": selected,
        "reply": reply,
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
    chat = sub.add_parser("chat")
    chat.add_argument("--dry-run", action="store_true")
    args = parser.parse_args()
    if args.cmd == "list":
        emit(list_payload())
    elif args.cmd == "get":
        emit({"ok": True, "selected": read_selected(), "agentFile": str(agent_file())})
    elif args.cmd == "set":
        cmd_set(args.agent_id)
    elif args.cmd == "chat":
        cmd_chat(args.dry_run)
    else:
        cmd_ask(args.dry_run)


if __name__ == "__main__":
    main()
