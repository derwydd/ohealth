# OHealth

Activity, vitals, and trends in a keyboard-driven window for [Omarchy](https://omarchy.org). The UI is Quickshell QML. It follows the active Omarchy theme and asks Omarchy's chosen system agent about the metric you are looking at.

This is not Apple's Health app, and it does not talk to HealthKit. HealthKit is an on-device framework. Apple does not publish a HealthKit cloud API, and the iCloud session used here cannot read health records. The numbers on screen come from a file you export on an iPhone, or from a labeled sample series when you have no export yet.

## Run

```bash
/Users/derwydd/Documents/projects/rsx/repos/ohealth/bin/ohealth
```

That is `quickshell -p` on `ui/shell.qml`. Quickshell has to be on `PATH`. On Omarchy:

```bash
sudo pacman -S quickshell
/Users/derwydd/Documents/projects/rsx/repos/ohealth/bin/ohealth
```

The same command with `--sample` skips sign-in and loads invented numbers. The window says they are sample data.

```bash
/Users/derwydd/Documents/projects/rsx/repos/ohealth/bin/ohealth --sample
```

`install.sh` symlinks those commands into `~/.local/bin`, writes a desktop entry, creates a virtualenv, and tries to `pip install pyicloud` for Apple sign-in. On Omarchy it also enables a user timer that re-reads the inbox every 30 minutes. It does not need root after `quickshell` itself is installed.

## How health data gets here

1. On the iPhone, open Health, tap your picture, and choose **Export All Health Data**. That produces `export.zip`.
2. Put `export.zip` or the `export.xml` inside it in the inbox:

   `~/.local/share/ohealth/inbox`

   Or set `EXPORT=` in `~/.config/ohealth/config` to a file or a directory.
3. Press `r` in the window, or run `ohealth-sync`.

A directory of [Health Auto Export](https://www.healthexportapp.com) JSON is accepted too. The sync script writes `~/.cache/ohealth/index.json` and `status.json`. The window watches both.

What that covers: steps, active energy, exercise minutes, walking and running distance, sleep, heart rate, resting heart rate, heart-rate variability, blood oxygen, respiratory rate, and weight. Other Health types are ignored.

`ohealth --sample` does not read an export and does not call Apple. The index is marked `labeledSample`.

## Apple sign-in

Sign-in matches [Omarchy iCloud Photos](https://github.com/jankeesvw/omarchy-icloud-photos). The window collects the Apple ID, the password, and the six-digit code. `bin/ohealth_helper.py` sends them to pyicloud (or `pyicloud_ipd`, the module icloudpd vendors) on stdin. The password is not written to disk. The session cookies go to `~/.config/icloudpd`, the same jar iCloud Photos and `icloudpd` use, unless `COOKIES=` says otherwise.

That session proves the Apple ID and is there so this app sits on the same auth bridge as iCloud Photos. It is not a HealthKit download. After you are signed in, the window still needs the export in the inbox. If the session expires, the sign-in card comes back. `shift+r` checks the session once.

Current pyicloud refuses the session until Apple's updated terms are accepted. Sign-in passes the library's `accept_terms` flag, the same switch as `icloud auth login --accept-terms`. Older pyicloud builds ignore that flag; if Apple still blocks the account, accept the terms at icloud.com and sign in again.

This checkout already has a `.venv` with pyicloud installed, and the helper scripts use it when it is present. `install.sh` creates that virtualenv if it is missing. If the import fails, the card says sign-in is unavailable. Sample data and a local export still load.

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
| `tab` `shift+tab` | Next region, previous region: ranges, metrics, days, agent |
| `1` `2` `3` `4` | 7 days, 30 days, 90 days, 1 year |
| `[` `]` | Shorter range, longer range |
| `h` `j` `k` `l`, arrows | Move inside the focused region |
| `g` `home` / `G` `end` | First / last in that region |
| `page up` `page down` | Move further |
| `enter` | Ask the Omarchy agent about the focused metric |
| In the agent region, `j` `k` | Change the saved Omarchy default |
| `a` | Open the full agent list |
| `enter` in the list | Save that agent |
| `o` in the list | Open Omarchy's agent menu, when the shell is installed |
| `r` | Read the Health export again |
| `shift+r` | Check the Apple session |
| `ctrl+p` | Preview invented sample data |
| `?` | This list |
| `esc` | Close the list or the key map, or quit |
| `q` | Quit |

On the sign-in card, `tab` moves through the fields, `enter` submits, `esc` quits, and `ctrl+p` opens the sample preview. The mouse works everywhere. Nothing requires it.

## Layout

```
bin/ohealth                 quickshell -p ui/shell.qml [--sample]
bin/ohealth-sync            export or sample → index.json
bin/ohealth-helper          login, status, probe, logout
bin/ohealth-agent           list, set, ask the Omarchy default
bin/ohealth_sync.py         Apple Health XML/zip and Health Auto Export JSON
bin/ohealth_helper.py       pyicloud sign-in, password on stdin only
bin/ohealth_agent.py        ~/.config/omarchy/defaults/agent
ui/shell.qml                window, keys, sign-in, agent, theme watchers
ui/Theme.qml                colors.toml and shell.toml
ui/Login.qml                Apple ID, password, two-factor code
ui/Dashboard.qml            summary, activity, vitals, trend
ui/AgentPicker.qml          Omarchy's agent list
ui/Help.qml                 key map
systemd/                    optional 30 minute re-index
```

`ohealth-helper logout` removes `APPLE_ID` from this app's config and leaves the shared cookie jar in place.

## Tests

```bash
python3 /Users/derwydd/Documents/projects/rsx/repos/ohealth/tests/test_data.py
```

The tests use a temporary home. They do not read your iCloud cookies or your Omarchy agent file.

## What still needs an Apple device

An Apple ID can sign in from this window once pyicloud is installed. The health records themselves still have to be exported on an iPhone (or produced by Health Auto Export) and placed in the inbox. There is no step in this app that fetches HealthKit from iCloud, because that API is not available.
