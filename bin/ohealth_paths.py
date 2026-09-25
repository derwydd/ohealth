"""Paths and config shared by the OHealth data layer.

Layout matches Omarchy iCloud Photos: a sourced config under
~/.config/ohealth, a cache of JSON the window watches, and an inbox for
files the sync reads. The Apple session directory defaults to
~/.config/icloudpd, the same cookie jar that app uses.
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
# APPLE_ID is written by the sign-in card. The password is never stored.
# COOKIES is the iCloud session jar. It defaults to the same directory
# Omarchy iCloud Photos uses (~/.config/icloudpd) so one Apple sign-in
# can be shared. Health records do not come from this session.
COOKIES=$HOME/.config/icloudpd
# EXPORT=
# Optional file or directory: Apple Health export.zip / export.xml, or
# Health Auto Export JSON. When unset, sync reads the inbox:
#   ~/.local/share/ohealth/inbox
"""


def ensure_layout() -> None:
    for path in (config_dir(), cache_dir(), inbox_dir()):
        path.mkdir(parents=True, exist_ok=True)
        os.chmod(path, 0o700)
    if not config_path().exists():
        config_path().write_text(DEFAULT_CONFIG)
        os.chmod(config_path(), 0o600)


def read_config() -> dict[str, str]:
    cfg: dict[str, str] = {
        "COOKIES": str(home() / ".config" / "icloudpd"),
    }
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


def write_apple_id(apple_id: str) -> None:
    """Set APPLE_ID, keeping every other line."""
    ensure_layout()
    path = config_path()
    lines = path.read_text().splitlines() if path.exists() else DEFAULT_CONFIG.splitlines()
    out: list[str] = []
    done = False
    for line in lines:
        if line.strip().startswith("APPLE_ID="):
            out.append(f"APPLE_ID={apple_id}")
            done = True
        else:
            out.append(line)
    if not done:
        out.append(f"APPLE_ID={apple_id}")
    path.write_text("\n".join(out) + "\n")
    os.chmod(path, 0o600)


def clear_apple_id() -> None:
    path = config_path()
    if not path.exists():
        return
    kept = [line for line in path.read_text().splitlines() if not line.strip().startswith("APPLE_ID=")]
    path.write_text("\n".join(kept) + "\n")
    os.chmod(path, 0o600)
