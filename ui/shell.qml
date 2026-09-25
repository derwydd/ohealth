import QtQuick
import QtQuick.Controls.Basic
import Quickshell
import Quickshell.Io

// OHealth: activity, vitals, and trends in one keyboard-driven window.
//
// Data comes from bin/ohealth-sync, which writes index.json and status.json
// under ~/.cache/ohealth. Sign-in is bin/ohealth-helper (pyicloud, same cookie
// jar as Omarchy iCloud Photos). The agent row reads and writes
// ~/.config/omarchy/defaults/agent.
//
// Keys: tab moves regions, 1-4 pick a range, hjkl or arrows move inside the
// region, enter asks the Omarchy agent, a opens the agent list, r syncs,
// shift+r checks the Apple session, ? lists every key.
ShellRoot {
  id: root

  Component.onCompleted: {
    Quickshell.inhibitReloadPopup()
    refreshAgents()
    if (sampleRequested) useSample()
  }

  readonly property bool sampleRequested: Quickshell.env("OHEALTH_SAMPLE") === "1"
  readonly property string homeDir: Quickshell.env("HOME") || ""
  readonly property string configHome: Quickshell.env("XDG_CONFIG_HOME") || (homeDir + "/.config")
  readonly property string stateHome: Quickshell.env("XDG_STATE_HOME") || (homeDir + "/.local/state")
  readonly property string cacheDir: (Quickshell.env("XDG_CACHE_HOME") || (homeDir + "/.cache")) + "/ohealth"
  readonly property string binDir: Quickshell.shellDir + "/../bin"
  readonly property string syncScript: binDir + "/ohealth-sync"
  readonly property string helperScript: binDir + "/ohealth-helper"
  readonly property string agentScript: binDir + "/ohealth-agent"
  readonly property string configPath: configHome + "/ohealth/config"
  readonly property var rangeIds: ["7d", "30d", "90d", "365d"]
  readonly property var zones: ["ranges", "metrics", "days", "agent"]

  property bool sampleMode: false
  property bool configLoaded: false
  property bool booted: false
  property string appleId: ""
  property string session: ""
  property string sessionNote: ""
  property string themeName: ""
  property var index: null
  property var status: ({ state: "loading", message: "Reading health data…" })
  property var view: ({})
  property var agents: ({})
  property int rangeIndex: 1
  property int metricIndex: 0
  property int dayIndex: 0
  property int zoneIndex: 1
  property int agentCursor: 0
  property string pendingAgentId: ""
  property bool placedDay: false
  property bool helpOpen: false
  property bool agentOpen: false
  property string colorRaw: ""
  property string themeShellRaw: ""
  property string machineShellRaw: ""

  readonly property bool needLogin: !sampleMode && configLoaded && (appleId === "" || session === "auth-required")
  readonly property string zone: zones[zoneIndex]
  readonly property string screen: {
    var days = (view && view.dayCount) ? view.dayCount : 0
    if (days > 0) return "ready"
    if (status && status.state === "error") return "error"
    if (status && status.state === "syncing") return "loading"
    if (configLoaded && !needLogin) return "empty"
    return "loading"
  }
  readonly property string errorMessage: (status && status.state === "error") ? (status.message || "") : ""

  Theme { id: appTheme }

  function reapplyTheme() {
    appTheme.resetDefaults()
    appTheme.applyColors(colorRaw)
    appTheme.applyShell(themeShellRaw)
    appTheme.applyShell(machineShellRaw)
  }

  function parseAppleId(raw) {
    var m = String(raw || "").match(/^\s*APPLE_ID=["']?([^"'\n]+)/m)
    return m ? m[1].trim() : ""
  }

  function rebuild() {
    var block = (index && index.ranges) ? index.ranges[rangeIds[rangeIndex]] : null
    view = block || {}
    var metrics = (block && block.metrics) ? block.metrics : []
    if (metricIndex >= metrics.length) metricIndex = Math.max(0, metrics.length - 1)
    var days = (block && block.days) ? block.days : []
    if (dayIndex >= days.length) dayIndex = Math.max(0, days.length - 1)
  }

  function setRange(index) {
    rangeIndex = Math.max(0, Math.min(rangeIds.length - 1, index))
    rebuild()
    var days = (view && view.days) ? view.days : []
    dayIndex = Math.max(0, days.length - 1)
  }

  function moveRange(delta) { setRange(rangeIndex + delta) }

  function moveMetric(delta) {
    var metrics = (view && view.metrics) ? view.metrics : []
    if (!metrics.length) return
    metricIndex = Math.max(0, Math.min(metrics.length - 1, metricIndex + delta))
  }

  function moveDay(delta) {
    var days = (view && view.days) ? view.days : []
    if (!days.length) return
    dayIndex = Math.max(0, Math.min(days.length - 1, dayIndex + delta))
  }

  function agentItems() {
    return (agents && agents.agents) ? agents.agents : []
  }

  function syncAgentCursor() {
    var list = agentItems()
    var selected = (agents && agents.selected) ? agents.selected : ""
    for (var i = 0; i < list.length; i++) {
      if (list[i].id === selected) {
        agentCursor = i
        return
      }
    }
  }

  function agentLabel() {
    var list = agentItems()
    if (zone === "agent" && agentCursor >= 0 && agentCursor < list.length)
      return list[agentCursor].name
    var selected = (agents && agents.selected) ? agents.selected : ""
    if (!selected) return "No agent chosen"
    for (var i = 0; i < list.length; i++) if (list[i].id === selected) return list[i].name
    return selected
  }

  function agentIsInstalled() {
    var list = agentItems()
    var id = ""
    if (zone === "agent" && agentCursor >= 0 && agentCursor < list.length) id = list[agentCursor].id
    else id = (agents && agents.selected) ? agents.selected : ""
    for (var i = 0; i < list.length; i++) if (list[i].id === id) return !!list[i].installed
    return false
  }

  function cycleZone(dir) {
    zoneIndex = (zoneIndex + dir + zones.length) % zones.length
  }

  function moveInZone(delta) {
    if (zone === "ranges") moveRange(delta)
    else if (zone === "metrics") moveMetric(delta)
    else if (zone === "days") moveDay(delta)
    else moveAgent(delta)
  }

  function jumpEnds(end) {
    if (zone === "ranges") setRange(end ? rangeIds.length - 1 : 0)
    else if (zone === "metrics") {
      var metrics = (view && view.metrics) ? view.metrics : []
      metricIndex = end ? Math.max(0, metrics.length - 1) : 0
    } else if (zone === "days") {
      var days = (view && view.days) ? view.days : []
      dayIndex = end ? Math.max(0, days.length - 1) : 0
    } else {
      var list = agentItems()
      agentCursor = end ? Math.max(0, list.length - 1) : 0
      agentSave.restart()
    }
  }

  function moveAgent(delta) {
    var list = agentItems()
    if (!list.length) {
      openAgents()
      return
    }
    agentCursor = (agentCursor + delta + list.length) % list.length
    agentSave.restart()
  }

  function commitAgent(closePicker) {
    var list = agentItems()
    if (agentCursor < 0 || agentCursor >= list.length) return
    if (closePicker) agentOpen = false
    var id = list[agentCursor].id
    if (agents && agents.selected === id) return
    pendingAgentId = id
    if (setAgent.running) return
    setAgent.command = [agentScript, "set", id]
    setAgent.running = true
  }

  function openAgents() {
    agentSave.stop()
    syncAgentCursor()
    agentOpen = true
    refreshAgents()
  }

  function useSample() {
    sampleMode = true
    session = ""
    booted = true
    startSync()
    keys.forceActiveFocus()
  }

  function startSync() {
    if (sync.running) return
    sync.command = sampleMode ? [syncScript, "--sample"] : [syncScript]
    status = {
      state: "syncing",
      message: sampleMode ? "Building sample data…" : "Reading health data…"
    }
    sync.running = true
  }

  function startProbe() {
    if (probe.running || appleId === "") return
    probe.command = [helperScript, "probe"]
    probe.running = true
  }

  function refreshAgents() {
    if (agentsProc.running) return
    agentsProc.command = [agentScript, "list"]
    agentsProc.running = true
  }

  function startLogin(username, password) {
    login.password = password
    login.command = [helperScript, "login", "--username", username, "--save-config"]
    login.running = true
  }

  function loginLine(line) {
    var msg = null
    try { msg = JSON.parse(String(line).trim()) } catch (e) { return }
    if (msg.step === "2fa") {
      loginCard.busy = false
      loginCard.step = "code"
    } else if (msg.ok) {
      loginCard.busy = false
      loginCard.reset()
      appleId = msg.username
      session = "ok"
      sessionNote = "Signed in"
      sampleMode = false
      toast.show("Signed in as " + msg.username)
      keys.forceActiveFocus()
      startSync()
    } else if (msg.error) {
      loginCard.busy = false
      loginCard.error = msg.error
      if (loginCard.step === "code") loginCard.step = "credentials"
    }
  }

  function probeLine(line) {
    var msg = null
    try { msg = JSON.parse(String(line).trim()) } catch (e) { return }
    if (msg.ok) {
      session = "ok"
      sessionNote = "Apple session ok"
    } else {
      sessionNote = msg.error || "Apple session check failed"
      if (sessionNote.indexOf("expired") >= 0) session = "auth-required"
      else session = "error"
      if (session === "auth-required") toast.show(sessionNote)
    }
  }

  function ask() {
    if (!agents || !agents.selected) {
      openAgents()
      toast.show("Choose an Omarchy agent first")
      return
    }
    var metrics = (view && view.metrics) ? view.metrics : []
    if (metricIndex < 0 || metricIndex >= metrics.length) {
      toast.show("Nothing to ask about yet")
      return
    }
    var metric = metrics[metricIndex]
    var days = (view && view.days) ? view.days : []
    var payload = {
      sample: !!(index && index.labeledSample) || sampleMode,
      range: view.label || "",
      metric: metric.name,
      day: dayIndex < days.length ? days[dayIndex] : "",
      dayValue: (metric.seriesText && dayIndex < metric.seriesText.length) ? metric.seriesText[dayIndex] : "",
      aggregate: metric.aggregate,
      value: metric.value,
      unit: metric.unit,
      trend: metric.trend,
      source: index ? index.sourceDetail : "",
      days: days,
      series: metric.series || []
    }
    askProc.payload = JSON.stringify(payload)
    if (askProc.running) return
    askProc.command = [agentScript, "ask"]
    askProc.running = true
  }

  function applyIndex(raw) {
    try { index = JSON.parse(raw) } catch (e) { return }
    rebuild()
    if (!placedDay) {
      var days = (view && view.days) ? view.days : []
      if (days.length > 0) {
        dayIndex = days.length - 1
        placedDay = true
      }
    }
  }

  FileView {
    path: root.stateHome + "/omarchy/current/theme/colors.toml"
    watchChanges: true
    printErrors: false
    onLoaded: { root.colorRaw = text(); root.reapplyTheme() }
    onFileChanged: reload()
  }
  FileView {
    path: root.stateHome + "/omarchy/current/theme/shell.toml"
    watchChanges: true
    printErrors: false
    onLoaded: { root.themeShellRaw = text(); root.reapplyTheme() }
    onFileChanged: reload()
  }
  FileView {
    path: root.configHome + "/omarchy/shell.toml"
    watchChanges: true
    printErrors: false
    onLoaded: { root.machineShellRaw = text(); root.reapplyTheme() }
    onFileChanged: reload()
  }
  FileView {
    path: root.stateHome + "/omarchy/current/theme.name"
    watchChanges: true
    printErrors: false
    onLoaded: root.themeName = String(text() || "").trim().replace(/-/g, " ")
    onFileChanged: reload()
  }
  FileView {
    id: indexFile
    path: root.cacheDir + "/index.json"
    watchChanges: true
    printErrors: false
    onLoaded: root.applyIndex(text())
    onFileChanged: reload()
  }
  FileView {
    id: statusFile
    path: root.cacheDir + "/status.json"
    watchChanges: true
    printErrors: false
    onLoaded: { try { root.status = JSON.parse(text()) } catch (e) {} }
    onFileChanged: reload()
  }
  FileView {
    id: configFile
    path: root.configPath
    watchChanges: true
    printErrors: false
    onLoaded: {
      root.appleId = root.parseAppleId(text())
      root.configLoaded = true
      if (root.sampleRequested || root.sampleMode) return
      if (root.appleId !== "" && !root.booted) {
        root.booted = true
        root.startSync()
        root.startProbe()
      }
    }
    onLoadFailed: root.configLoaded = true
    onFileChanged: reload()
  }

  Process {
    id: login
    running: false
    stdinEnabled: true
    property string password: ""
    onStarted: { write(password + "\n"); password = "" }
    stdout: SplitParser { onRead: data => root.loginLine(data) }
    onExited: {
      if (loginCard.busy) {
        loginCard.busy = false
        if (loginCard.error === "") loginCard.error = "The sign-in helper stopped without an answer"
      }
    }
  }
  Process {
    id: sync
    running: false
    onExited: { indexFile.reload(); statusFile.reload() }
  }
  Process {
    id: probe
    running: false
    stdout: SplitParser { onRead: data => root.probeLine(data) }
  }
  Process {
    id: agentsProc
    running: false
    stdout: StdioCollector {
      onStreamFinished: {
        try { root.agents = JSON.parse(text) } catch (e) { return }
        root.syncAgentCursor()
      }
    }
  }
  Process {
    id: setAgent
    running: false
    stdout: StdioCollector {
      onStreamFinished: {
        var msg = {}
        try { msg = JSON.parse(text) } catch (e) { return }
        if (msg.ok) toast.show("Omarchy agent set to " + msg.selected)
        else toast.show(msg.error || "Could not set the agent")
        root.refreshAgents()
      }
    }
  }
  Process {
    id: askProc
    running: false
    stdinEnabled: true
    property string payload: ""
    onStarted: write(payload)
    stdout: StdioCollector {
      onStreamFinished: {
        var msg = {}
        try { msg = JSON.parse(text) } catch (e) {
          toast.show("The agent helper returned nothing")
          return
        }
        if (msg.ok) toast.show("Asked " + msg.agent + ". The reply is logging to " + msg.log)
        else toast.show(msg.error || "Could not ask the agent")
      }
    }
  }
  Process { id: omarchyPick }

  Timer {
    id: agentSave
    interval: 180
    onTriggered: if (!root.agentOpen) root.commitAgent(false)
  }

  FloatingWindow {
    id: win
    visible: true
    title: "OHealth"
    implicitWidth: 1180
    implicitHeight: 800
    color: appTheme.background

    Item {
      id: keys
      anchors.fill: parent
      focus: true
      Component.onCompleted: forceActiveFocus()

      Shortcut {
        sequence: "Esc"
        context: Qt.WindowShortcut
        enabled: root.needLogin && !root.helpOpen
        onActivated: Qt.quit()
      }
      Shortcut {
        sequence: "Ctrl+P"
        context: Qt.WindowShortcut
        enabled: root.needLogin || root.screen === "empty" || root.sampleMode
        onActivated: root.useSample()
      }

      Keys.onPressed: event => {
        var k = event.key
        var t = event.text
        var shift = (event.modifiers & Qt.ShiftModifier) !== 0
        var ctrl = (event.modifiers & Qt.ControlModifier) !== 0
        if (root.needLogin) return
        if (root.helpOpen) {
          if (t === "?" || k === Qt.Key_Escape || t === "q") root.helpOpen = false
          event.accepted = true
          return
        }
        if (root.agentOpen) {
          var list = root.agentItems()
          if (k === Qt.Key_Escape) root.agentOpen = false
          else if (t === "q") Qt.quit()
          else if (k === Qt.Key_Down || k === Qt.Key_J || t === "j") root.agentCursor = Math.min(Math.max(0, list.length - 1), root.agentCursor + 1)
          else if (k === Qt.Key_Up || k === Qt.Key_K || t === "k") root.agentCursor = Math.max(0, root.agentCursor - 1)
          else if (k === Qt.Key_Home || t === "g") root.agentCursor = 0
          else if (k === Qt.Key_End || t === "G") root.agentCursor = Math.max(0, list.length - 1)
          else if (k === Qt.Key_Return || k === Qt.Key_Enter) root.commitAgent(true)
          else if (t === "o" && root.agents && root.agents.omarchyLauncher) {
            omarchyPick.command = ["omarchy-agent", "--pick"]
            omarchyPick.running = true
          } else if (t === "?") root.helpOpen = true
          else return
          event.accepted = true
          return
        }
        if (t === "?") { root.helpOpen = true; event.accepted = true; return }
        if (t === "a") { root.openAgents(); event.accepted = true; return }
        if (ctrl && (t === "p" || t === "P")) { root.useSample(); event.accepted = true; return }
        if (t === "q") { Qt.quit(); return }
        if (k === Qt.Key_Escape) { Qt.quit(); return }
        if (k === Qt.Key_Tab) { root.cycleZone(shift ? -1 : 1); event.accepted = true; return }
        if (k === Qt.Key_Backtab) { root.cycleZone(-1); event.accepted = true; return }
        if (t === "1") root.setRange(0)
        else if (t === "2") root.setRange(1)
        else if (t === "3") root.setRange(2)
        else if (t === "4") root.setRange(3)
        else if (t === "[") root.moveRange(-1)
        else if (t === "]") root.moveRange(1)
        else if (t === "r") { root.sampleMode = false; root.startSync() }
        else if (t === "R") root.startProbe()
        else if (k === Qt.Key_Return || k === Qt.Key_Enter) root.ask()
        else if (t === "g" || k === Qt.Key_Home) root.jumpEnds(false)
        else if (t === "G" || k === Qt.Key_End) root.jumpEnds(true)
        else if (k === Qt.Key_Left || k === Qt.Key_H || t === "h") root.moveInZone(-1)
        else if (k === Qt.Key_Right || k === Qt.Key_L || t === "l") root.moveInZone(1)
        else if (k === Qt.Key_Down || k === Qt.Key_J || t === "j") root.moveInZone(1)
        else if (k === Qt.Key_Up || k === Qt.Key_K || t === "k") root.moveInZone(-1)
        else if (k === Qt.Key_PageDown) root.moveInZone(root.zone === "days" ? 14 : 4)
        else if (k === Qt.Key_PageUp) root.moveInZone(root.zone === "days" ? -14 : -4)
        else return
        event.accepted = true
      }

      Rectangle {
        id: header
        anchors.top: parent.top
        anchors.left: parent.left
        anchors.right: parent.right
        height: 56
        color: appTheme.darkBackground
        visible: !root.needLogin

        Row {
          anchors.left: parent.left
          anchors.leftMargin: 20
          anchors.verticalCenter: parent.verticalCenter
          spacing: 14
          Text {
            text: "OHealth"
            color: appTheme.brightForeground
            font.family: appTheme.fontFamily
            font.pixelSize: 18
            font.bold: true
            anchors.verticalCenter: parent.verticalCenter
          }
          Text {
            text: root.appleId !== "" ? root.appleId : (root.sampleMode ? "Not signed in" : "")
            color: appTheme.darkForeground
            font.family: appTheme.fontFamily
            font.pixelSize: appTheme.fontSize
            anchors.verticalCenter: parent.verticalCenter
          }
        }
        Column {
          anchors.right: parent.right
          anchors.rightMargin: 20
          anchors.verticalCenter: parent.verticalCenter
          spacing: 2
          Text {
            anchors.right: parent.right
            text: root.themeName.length > 0 ? root.themeName : "theme fallback"
            color: appTheme.accent
            font.family: appTheme.fontFamily
            font.pixelSize: appTheme.fontSize - 1
          }
          Text {
            anchors.right: parent.right
            width: 420
            horizontalAlignment: Text.AlignRight
            elide: Text.ElideLeft
            text: root.sessionNote.length > 0 ? root.sessionNote : (root.status.message || "")
            color: root.status.state === "error" ? appTheme.red : appTheme.darkForeground
            font.family: appTheme.fontFamily
            font.pixelSize: appTheme.fontSize - 2
          }
        }
      }

      Dashboard {
        id: board
        anchors.top: header.bottom
        anchors.bottom: footer.top
        anchors.left: parent.left
        anchors.right: parent.right
        visible: !root.needLogin
        theme: appTheme
        view: root.view
        metricIndex: root.metricIndex
        dayIndex: root.dayIndex
        zone: root.zone
        rangeIndex: root.rangeIndex
        state: root.screen
        stateMessage: root.status.message || ""
        errorMessage: root.errorMessage
        sample: (root.index && root.index.labeledSample) || root.sampleMode
        agentLabel: root.agentLabel()
        agentInstalled: root.agentIsInstalled()
        onRangeChosen: index => root.setRange(index)
        onMetricChosen: index => root.metricIndex = index
        onDayChosen: index => root.dayIndex = index
        onZoneChosen: name => {
          for (var i = 0; i < root.zones.length; i++) if (root.zones[i] === name) root.zoneIndex = i
        }
      }

      Rectangle {
        id: footer
        anchors.bottom: parent.bottom
        anchors.left: parent.left
        anchors.right: parent.right
        height: 40
        visible: !root.needLogin
        color: appTheme.darkerBackground
        border.width: root.zone === "agent" ? 2 : 0
        border.color: appTheme.accent
        Row {
          anchors.fill: parent
          anchors.leftMargin: 16
          anchors.rightMargin: 16
          spacing: 16
          Text {
            anchors.verticalCenter: parent.verticalCenter
            text: "Agent  " + root.agentLabel() + (root.agentIsInstalled() ? "" : "  · not on PATH")
            color: root.zone === "agent" ? appTheme.brightForeground : appTheme.foreground
            font.family: appTheme.fontFamily
            font.pixelSize: appTheme.fontSize
            font.bold: root.zone === "agent"
          }
          Text {
            anchors.verticalCenter: parent.verticalCenter
            text: "enter ask   a choose   r sync   ? keys"
            color: appTheme.darkForeground
            font.family: appTheme.fontFamily
            font.pixelSize: appTheme.fontSize - 2
          }
        }
        MouseArea {
          anchors.fill: parent
          onClicked: root.zoneIndex = 3
        }
      }

      Login {
        id: loginCard
        anchors.fill: parent
        visible: root.needLogin
        theme: appTheme
        username: root.appleId
        onSubmitCredentials: (username, password) => root.startLogin(username, password)
        onSubmitCode: code => login.write(code + "\n")
        onPreviewSample: root.useSample()
      }

      Help {
        anchors.fill: parent
        visible: root.helpOpen
        theme: appTheme
        onRequestClose: root.helpOpen = false
      }

      AgentPicker {
        anchors.fill: parent
        visible: root.agentOpen
        theme: appTheme
        agents: root.agentItems()
        cursor: root.agentCursor
        selectedId: (root.agents && root.agents.selected) ? root.agents.selected : ""
        omarchyLauncher: !!(root.agents && root.agents.omarchyLauncher)
        onRequestClose: root.agentOpen = false
        onCursorMoved: index => root.agentCursor = index
        onCommitRequested: root.commitAgent(true)
      }

      Rectangle {
        id: toast
        property string message: ""
        function show(text) {
          message = text || ""
          opacity = message.length > 0 ? 1 : 0
          hideTimer.restart()
        }
        opacity: 0
        visible: opacity > 0
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.bottom: footer.top
        anchors.bottomMargin: 12
        width: Math.min(parent.width - 40, toastText.implicitWidth + 28)
        height: toastText.implicitHeight + 16
        radius: 8
        color: appTheme.lighterBackground
        border.color: appTheme.accent
        border.width: 1
        Text {
          id: toastText
          anchors.centerIn: parent
          width: Math.min(win.width - 80, 640)
          wrapMode: Text.Wrap
          horizontalAlignment: Text.AlignHCenter
          text: toast.message
          color: appTheme.brightForeground
          font.family: appTheme.fontFamily
          font.pixelSize: appTheme.fontSize - 1
        }
        Behavior on opacity { NumberAnimation { duration: 120 } }
        Timer {
          id: hideTimer
          interval: 4600
          onTriggered: toast.opacity = 0
        }
      }
    }
  }
}
