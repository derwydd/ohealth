import QtQuick

// Omarchy theme tokens. colors.toml is the same file Omarchy iCloud Photos
// watches (~/.local/state/omarchy/current/theme/colors.toml). shell.toml
// contributes the type size and spacing scale; a machine-level
// ~/.config/omarchy/shell.toml wins, matching omarchy-theme-set.
// Tokyo Night is only the fallback until those files load.
QtObject {
  id: root

  property color background: "#1a1b26"
  property color darkBackground: "#13141c"
  property color darkerBackground: "#0e0e14"
  property color lighterBackground: "#24283b"
  property color foreground: "#a9b1d6"
  property color darkForeground: "#565f89"
  property color brightForeground: "#c0caf5"
  property color accent: "#7aa2f7"
  property color selection: "#292e42"
  property color muted: "#414868"
  property color red: "#f7768e"
  property color yellow: "#e0af68"
  property color green: "#9ece6a"
  property color cyan: "#449dab"
  property color orange: "#eb927b"

  property string fontFamily: "CaskaydiaMono Nerd Font"
  property int fontSize: 13
  property real spaceScale: 1

  function resetDefaults() {
    background = "#1a1b26"
    darkBackground = "#13141c"
    darkerBackground = "#0e0e14"
    lighterBackground = "#24283b"
    foreground = "#a9b1d6"
    darkForeground = "#565f89"
    brightForeground = "#c0caf5"
    accent = "#7aa2f7"
    selection = "#292e42"
    muted = "#414868"
    red = "#f7768e"
    yellow = "#e0af68"
    green = "#9ece6a"
    cyan = "#449dab"
    orange = "#eb927b"
    fontFamily = "CaskaydiaMono Nerd Font"
    fontSize = 13
    spaceScale = 1
  }

  function space(px) {
    return Math.max(1, Math.round(px * spaceScale))
  }

  function tone(name) {
    if (name === "good") return green
    if (name === "warn") return yellow
    if (name === "flat") return foreground
    return darkForeground
  }

  function applyColors(raw) {
    var lines = String(raw || "").split("\n")
    var c = {}
    for (var i = 0; i < lines.length; i++) {
      var m = lines[i].match(/^\s*([A-Za-z0-9_]+)\s*=\s*["']?(#[0-9A-Fa-f]{6})/)
      if (m) c[m[1]] = m[2]
    }
    if (c.background) background = c.background
    if (c.dark_background) darkBackground = c.dark_background
    if (c.darker_background) darkerBackground = c.darker_background
    if (c.lighter_background) lighterBackground = c.lighter_background
    if (c.foreground) foreground = c.foreground
    if (c.dark_foreground) darkForeground = c.dark_foreground
    if (c.bright_foreground) brightForeground = c.bright_foreground
    if (c.accent) accent = c.accent
    if (c.selection) selection = c.selection
    if (c.muted) muted = c.muted
    if (c.red) red = c.red
    if (c.yellow) yellow = c.yellow
    if (c.green) green = c.green
    if (c.cyan) cyan = c.cyan
    if (c.orange) orange = c.orange
  }

  function applyShell(raw) {
    var lines = String(raw || "").split("\n")
    var section = ""
    for (var i = 0; i < lines.length; i++) {
      var sec = lines[i].match(/^\s*\[([A-Za-z0-9_-]+)\]/)
      if (sec) {
        section = sec[1]
        continue
      }
      var m = lines[i].match(/^\s*([A-Za-z0-9_-]+)\s*=\s*["']?([^"'\n#]+)/)
      if (!m) continue
      var key = m[1]
      var val = m[2].trim()
      if (section === "font" && key === "base-size") {
        var n = parseFloat(val)
        if (n > 0) fontSize = Math.round(n) + 1
      }
      if (section === "font" && (key === "family" || key === "family-name")) {
        var family = val.replace(/^["']|["']$/g, "")
        if (family.length > 0) fontFamily = family
      }
      if (section === "spacing" && key === "scale") {
        var s = parseFloat(val)
        if (s > 0) spaceScale = s
      }
    }
  }
}
