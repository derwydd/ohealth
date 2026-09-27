# OHealth

Activity, vitals, and trends in a keyboard-driven window for [Omarchy](https://omarchy.org). The UI is Quickshell QML. It follows the active Omarchy theme and asks Omarchy's chosen system agent about the metric you are looking at.

This is not Apple's Health app. HealthKit stays on the iPhone: Apple does not publish a HealthKit cloud API. The numbers on screen come from a file you export, from the paired OHealth iPhone app on the local network, or from a labeled sample series when you have no data yet.

## Run

```bash
/Users/derwydd/Documents/projects/rsx/repos/ohealth/bin/ohealth
```

That is `quickshell -p` on `ui/shell.qml`. Quickshell has to be on `PATH`. On Omarchy:

```bash
sudo pacman -S quickshell
/Users/derwydd/Documents/projects/rsx/repos/ohealth/bin/ohealth
```

The same command with `--sample` loads invented numbers. The window says they are sample data.

```bash
/Users/derwydd/Documents/projects/rsx/repos/ohealth/bin/ohealth --sample
```

`install.sh` symlinks those commands into `~/.local/bin` and writes a desktop entry. On Omarchy it also enables a user timer that republishes the local database every 30 minutes. It does not need root after `quickshell` itself is installed.

## How health data gets here

1. On the iPhone, open Health, tap your picture, and choose **Export All Health Data**. That produces `export.zip`.
2. Choose it with **File → Import → Apple HealthKit Export**. That reads the file once and stores new records in `~/.config/ohealth/ohealth.sqlite`. Opening the window reads that database. Importing the same file again adds only records that are not already saved.

   Or put `export.zip` in the inbox and run `ohealth-sync --inbox`:

   `~/.local/share/ohealth/inbox`

   `ohealth-sync --export PATH` saves a file the same way.
3. Or turn on **Settings → Listen for an iPhone**. The computer advertises `_ohealth._tcp` and shows a pairing code. The iPhone app enters that code, checks the certificate, and sends new Health samples. Those samples are saved for the person this window has open. The prompt for writing that iPhone app is `docs/ios-companion-prompt.md`.
4. Press `r` to reload the saved database.

A directory of [Health Auto Export](https://www.healthexportapp.com) JSON is accepted too. After an import, the sync script publishes `~/.cache/ohealth/index.json` and `status.json` from the database. The window watches both.

What that covers: steps, active energy, exercise minutes, walking and running distance, sleep, heart rate, resting heart rate, heart-rate variability, blood oxygen, respiratory rate, and weight. Other Health types are ignored.

`ohealth --sample` does not read an export. The index is marked `labeledSample`.

## Theme

Colors come from Omarchy's current theme file:

`~/.local/state/omarchy/current/theme/colors.toml`

That is the file `omarchy-theme-set` publishes and the file iCloud Photos watches. OHealth reloads it when it changes. `shell.toml` beside that theme, and `~/.config/omarchy/shell.toml` after it, supply `[font] base-size` and `[spacing] scale`. The machine file wins, which is the Omarchy rule. Until those files exist, the window uses the Tokyo Night fallback shipped with Omarchy, not a fixed Apple palette.

## Agent

The footer is Omarchy's system agent, not a separate chat.

The catalog is the list in `omarchy-default-agent`: Pi, Oh My Pi, OpenCode, Ori, Claude Code, Codex, Grok, OpenClaw, Antigravity, Hermes, GitHub Copilot, Crush, Cursor CLI, and Muse Code. The saved choice is the file that command reads and writes:

`~/.config/omarchy/defaults/agent`

Choosing one in OHealth writes that file. It does not run `omarchy-default-agent <name>`, because that command also installs the agent and launches it. Press `o` in the picker when `omarchy-agent` is installed to open Omarchy's own menu (`omarchy-agent --pick`, the same command the agents panel uses).

`enter` asks the saved agent about the focused metric. The prompt contains only that slice of the index and, for sample data, says the figures are invented. On Omarchy the question is handed to `omarchy-agent --prompt`. Without that wrapper, OHealth starts the same per-agent command `bin/omarchy-agent` uses. The reply is not shown in this window. It goes to the agent process, and a copy of its output is appended to `~/.cache/ohealth/agent-ask.log`.

## Keys

Press `?` in the window for the same list.

| Key | Action |
|---|---|
| `tab` `shift+tab` | Next region, previous region: ranges, metrics, days, chat, agent |
| `1` `2` `3` `4` `5` `6` `7` | 7 days, 30 days, 90 days, 1 year, 3 years, 5 years, all |
| `[` `]` | Shorter range, longer range |
| `h` `j` `k` `l`, arrows | Move inside the focused region |
| `g` `home` / `G` `end` | First / last in that region |
| `page up` `page down` | Move further |
| `enter` | Ask the Omarchy agent about the focused metric |
| In the agent region, `j` `k` | Change the saved Omarchy default |
| `?` | Open the keyboard reference |
| `a` | Open the full agent list |
| `enter` in the list | Save that agent |
| `o` in the list | Open Omarchy's agent menu, when the shell is installed |
| `r` | Reload the saved health data |
| `ctrl+p` | Preview invented sample data |
| `esc` | Close the keyboard window, the picker, or quit |
| `q` | Quit |

The mouse works everywhere. Nothing requires it.

## Layout

```
bin/ohealth                 quickshell -p ui/shell.qml [--sample]
bin/ohealth-sync            database, import, or sample → index.json
bin/ohealth-agent           list, set, ask the Omarchy default
bin/ohealth_sync.py         Apple Health XML/zip and Health Auto Export JSON
bin/ohealth_agent.py        ~/.config/omarchy/defaults/agent
bin/ohealth_companion.py    local-network pairing and iPhone sample ingest
ui/shell.qml                window, keys, agent, theme watchers
ui/Theme.qml                colors.toml and shell.toml
ui/Dashboard.qml            summary, activity, vitals, trend
ui/Settings.qml             database, severity colors, iPhone sync
ui/AgentPicker.qml          Omarchy's agent list
ui/Help.qml                 key map
systemd/                    optional 30 minute re-index
```

## Tests

```bash
python3 /Users/derwydd/Documents/projects/rsx/repos/ohealth/tests/test_data.py
```

The tests use a temporary home. They do not read your iCloud cookies or your Omarchy agent file.

## What still needs an Apple device

HealthKit can only be read on the iPhone. This app never fetches it from iCloud. Either export the file and import it here, or run the companion app from `docs/ios-companion-prompt.md` on the same network and pair it from Settings.
