"""Paths and config shared by the OHealth data layer.

A sourced config under ~/.config/ohealth, a cache of JSON the window
watches, and an inbox for files the sync reads.
"""

from __future__ import annotations

import os
from pathlib import Path


def home() -> Path:
    return Path(os.environ.get("OHEALTH_HOME", str(Path.home())))


def config_dir() -> Path:
    base = os.environ.get("XDG_CONFIG_HOME", str(home() / ".config"))
    return Path(base) / "ohealth"


def cache_dir() -> Path:
    base = os.environ.get("XDG_CACHE_HOME", str(home() / ".cache"))
    return Path(base) / "ohealth"


def data_dir() -> Path:
    base = os.environ.get("XDG_DATA_HOME", str(home() / ".local" / "share"))
    return Path(base) / "ohealth"


def inbox_dir() -> Path:
    return data_dir() / "inbox"


def config_path() -> Path:
    return config_dir() / "config"


def db_path() -> Path:
    return config_dir() / "ohealth.sqlite"


def xray_dir() -> Path:
    return config_dir() / "xrays"


def document_dir() -> Path:
    return config_dir() / "documents"


def files_path() -> Path:
    return cache_dir() / "files.json"


def chat_path() -> Path:
    return cache_dir() / "chat.json"


def users_path() -> Path:
    return cache_dir() / "users.json"


def index_path() -> Path:
    return cache_dir() / "index.json"


def status_path() -> Path:
    return cache_dir() / "status.json"


def agent_file() -> Path:
    override = os.environ.get("OHEALTH_AGENT_FILE")
    if override:
        return Path(override)
    return home() / ".config" / "omarchy" / "defaults" / "agent"


def theme_state_dir() -> Path:
    base = os.environ.get("XDG_STATE_HOME", str(home() / ".local" / "state"))
    return Path(base) / "omarchy" / "current"


DEFAULT_CONFIG = """# OHealth configuration. Sourced conceptually as KEY=VALUE lines.
# EXPORT=
# Optional file or directory: Apple Health export.zip / export.xml, or
# Health Auto Export JSON. When unset, sync reads the inbox:
#   ~/.local/share/ohealth/inbox
"""


def ensure_layout() -> None:
    for path in (config_dir(), cache_dir(), inbox_dir(), xray_dir(), document_dir()):
        path.mkdir(parents=True, exist_ok=True)
        os.chmod(path, 0o700)
    if not config_path().exists():
        config_path().write_text(DEFAULT_CONFIG)
        os.chmod(config_path(), 0o600)


def read_config() -> dict[str, str]:
    cfg: dict[str, str] = {}
    path = config_path()
    if not path.exists():
        return cfg
    for line in path.read_text().splitlines():
        stripped = line.strip()
        if not stripped or stripped.startswith("#") or "=" not in stripped:
            continue
        key, value = stripped.split("=", 1)
        cfg[key.strip()] = os.path.expandvars(value.strip().strip('"').strip("'"))
    return cfg


def write_export(path: str) -> None:
    """Remember the Health export the window opened, keeping every other line."""
    ensure_layout()
    config = config_path()
    lines = config.read_text().splitlines() if config.exists() else DEFAULT_CONFIG.splitlines()
    out: list[str] = []
    done = False
    for line in lines:
        if line.strip().startswith("EXPORT="):
            out.append(f"EXPORT={path}")
            done = True
        else:
            out.append(line)
    if not done:
        out.append(f"EXPORT={path}")
    config.write_text("\n".join(out) + "\n")
    os.chmod(config, 0o600)


