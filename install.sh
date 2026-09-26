#!/bin/bash
# Link OHealth into ~/.local and, on Omarchy, enable the user timer.
# Re-run after a pull. Nothing here needs root except the package hint.
set -euo pipefail
here="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
config="${XDG_CONFIG_HOME:-$HOME/.config}"

if ! command -v quickshell >/dev/null 2>&1; then
  echo "quickshell is not on PATH. On Omarchy: sudo pacman -S quickshell" >&2
  echo "The files are still linked so the command is ready once it is installed." >&2
fi

if ! command -v python3 >/dev/null 2>&1; then
  echo "python3 is required for sync and the agent picker" >&2
  exit 1
fi

mkdir -p "$HOME/.local/bin" "$HOME/.local/share/applications" "$config/ohealth" \
  "${XDG_DATA_HOME:-$HOME/.local/share}/ohealth/inbox"

ln -sfn "$here/bin/ohealth" "$HOME/.local/bin/ohealth"
ln -sfn "$here/bin/ohealth-sync" "$HOME/.local/bin/ohealth-sync"
ln -sfn "$here/bin/ohealth-agent" "$HOME/.local/bin/ohealth-agent"
rm -f "$HOME/.local/bin/ohealth-helper"

if [[ ! -f "$config/ohealth/config" ]]; then
  python3 - <<PY
import os, sys
sys.path.insert(0, "$here/bin")
os.environ.setdefault("XDG_CONFIG_HOME", "$config")
from ohealth_paths import ensure_layout
ensure_layout()
PY
  echo "Start ohealth, or run ohealth --sample for invented numbers."
fi

cp "$here/ohealth.desktop" "$HOME/.local/share/applications/ohealth.desktop"

if command -v systemctl >/dev/null 2>&1 && [[ "$(uname)" != "Darwin" ]]; then
  mkdir -p "$config/systemd/user"
  ln -sfn "$here/systemd/ohealth-sync.service" "$config/systemd/user/ohealth-sync.service"
  ln -sfn "$here/systemd/ohealth-sync.timer" "$config/systemd/user/ohealth-sync.timer"
  systemctl --user daemon-reload || true
  systemctl --user enable --now ohealth-sync.timer || true
fi

echo "linked. run: $here/bin/ohealth"
echo "sample:     $here/bin/ohealth --sample"
