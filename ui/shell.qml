import QtQuick
import Quickshell
import Quickshell.Io

// OHealth: activity, vitals, and trends in one keyboard-driven window.
//
// Data comes from ~/.config/ohealth/ohealth.sqlite, one person at a time.
// Opening the window asks who this session is for, then bin/ohealth-sync
// publishes that person's rows as index.json and status.json under
// ~/.cache/ohealth. Import is the path that reads an Apple Health export.
//
// Keys: tab moves regions, 1-4 pick a range, hjkl or arrows move inside the
// region, enter asks the Omarchy agent, a opens the agent list, r reloads
// the saved database, ? lists every key.
ShellRoot {
  id: root

  Component.onCompleted: {
    Quickshell.inhibitReloadPopup()
    refreshAgents()
    if (sampleRequested) root.sampleOnNextEnter = true
    refreshPeople()
  }

  readonly property bool sampleRequested: Quickshell.env("OHEALTH_SAMPLE") === "1"
  readonly property string homeDir: Quickshell.env("HOME") || ""
  readonly property string configHome: Quickshell.env("XDG_CONFIG_HOME") || (homeDir + "/.config")
  readonly property string stateHome: Quickshell.env("XDG_STATE_HOME") || (homeDir + "/.local/state")
  readonly property string cacheDir: (Quickshell.env("XDG_CACHE_HOME") || (homeDir + "/.cache")) + "/ohealth"
  readonly property string binDir: Quickshell.shellDir + "/../bin"
  readonly property string syncScript: binDir + "/ohealth-sync"
  readonly property string agentScript: binDir + "/ohealth-agent"
  readonly property string defaultDatabase: configHome + "/ohealth/ohealth.sqlite"
  readonly property string databasePath: (status && status.database) ? status.database : defaultDatabase
  readonly property var rangeIds: ["7d", "30d", "90d", "365d", "3y", "5y", "all"]
  readonly property var zones: ["ranges", "metrics", "days", "chat", "agent"]

  property bool sampleMode: false
  property bool exportBusy: false
  property string importDots: "."
  property bool fileMenuOpen: false
  property bool settingsOpen: false
  property bool keysOpen: false
  property var index: null
  property var status: ({ state: "loading", message: "Reading health data…" })
  property var view: ({})
  property var agents: ({})
  property int rangeIndex: 1
  property bool customActive: false
  property int metricIndex: 0
  property int dayIndex: 0
  property int zoneIndex: 1
  property int zoneBeforeChat: 1
  property int agentCursor: 0
  property string pendingAgentId: ""
  property bool placedDay: false
  property bool agentOpen: false
  property string chatScope: "selected"
  property string chatFocusId: ""
  property string gallery: ""
  property bool chatBusy: false
  property var library: ({ xrays: [], blood: [], urine: [] })
  property var chatMessages: []
  property var people: ({ users: [], current: "", currentName: "" })
  property bool sessionEntered: false
  property bool sampleOnNextEnter: false
  property string pendingImport: ""
  property string pendingDelete: ""
  property string pendingDeleteName: ""
  property string colorRaw: ""
  property string themeShellRaw: ""
  property string machineShellRaw: ""

  readonly property string zone: zones[zoneIndex]
  readonly property string screen: {
    var days = (view && view.dayCount) ? view.dayCount : 0
    if (days > 0) return "ready"
    if (status && status.state === "error") return "error"
    if (status && status.state === "empty") return "empty"
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

  function openSettings() {
    fileMenuOpen = false
    if (keysOpen) closeKeys()
    settingsOpen = true
    settingsRaise.ticks = 0
    settingsRaise.start()
  }

  function closeSettings() {
    settingsOpen = false
    settingsRaise.stop()
    placeWindow("OHealth Settings", false)
    keys.forceActiveFocus()
  }

  function openKeys() {
    fileMenuOpen = false
    if (settingsOpen) closeSettings()
    keysOpen = true
    keysRaise.ticks = 0
    keysRaise.start()
  }

  function closeKeys() {
    keysOpen = false
    keysRaise.stop()
    placeWindow("OHealth Keyboard", false)
    keys.forceActiveFocus()
  }

  function chooseDatabase() {
    if (pickDatabase.running || exportBusy) return
    pickDatabase.command = [syncScript, "--select-database"]
    pickDatabase.running = true
  }

  function rebuild() {
    var block = (index && index.ranges) ? index.ranges[rangeIds[rangeIndex]] : null
    view = block || {}
    var metrics = (block && block.metrics) ? block.metrics : []
    if (metricIndex >= metrics.length) metricIndex = Math.max(0, metrics.length - 1)
    var days = (block && block.days) ? block.days : []
    if (dayIndex >= days.length) dayIndex = Math.max(0, days.length - 1)
  }

  function showSavedRange(resetDay) {
    var saved = (index && index.range && index.range.id) ? index.range.id : "30d"
    if (saved === "custom" && index.ranges && index.ranges.custom) {
      customActive = true
      view = index.ranges.custom
      var metrics = view.metrics || []
      if (metricIndex >= metrics.length) metricIndex = Math.max(0, metrics.length - 1)
      var days = view.days || []
      if (resetDay || dayIndex >= days.length) dayIndex = Math.max(0, days.length - 1)
      return
    }
    customActive = false
    var found = rangeIds.indexOf(saved)
    rangeIndex = found >= 0 ? found : 1
    rebuild()
    if (resetDay) {
      var presetDays = (view && view.days) ? view.days : []
      dayIndex = Math.max(0, presetDays.length - 1)
    }
  }

  function persistRange(id, start, end) {
    if (!sessionEntered || rangeProc.running) return
    var args = [syncScript, "--range", id]
    if (id === "custom") args.push("--range-start", start, "--range-end", end)
    rangeProc.command = args
    rangeProc.running = true
  }

  function setRange(index) {
    classifyHold = false
    rangeIndex = Math.max(0, Math.min(rangeIds.length - 1, index))
    customActive = false
    rebuild()
    var days = (view && view.days) ? view.days : []
    dayIndex = Math.max(0, days.length - 1)
    persistRange(rangeIds[rangeIndex], "", "")
  }

  function saveCustomRange(start, end) {
    if (!start || !end) return
    persistRange("custom", start, end)
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

  function focusZone(name) {
    for (var i = 0; i < zones.length; i++) if (zones[i] === name) zoneIndex = i
  }

  function noteChatFocused() {
    if (zone === "chat") return
    zoneBeforeChat = zoneIndex
    focusZone("chat")
  }

  function leaveChatZone() {
    if (zone === "chat") zoneIndex = zoneBeforeChat
  }

  function cycleZone(dir) {
    var next = (zoneIndex + dir + zones.length) % zones.length
    if (zones[next] === "chat" && zone !== "chat") zoneBeforeChat = zoneIndex
    if (zone === "chat" || chatSidebar.editing) chatSidebar.releaseInput()
    zoneIndex = next
    if (zone === "chat") chatSidebar.focusInput()
    else keys.forceActiveFocus()
  }

  function moveInZone(delta) {
    if (zone === "chat") return
    if (zone === "ranges") moveRange(delta)
    else if (zone === "metrics") moveMetric(delta)
    else if (zone === "days") moveDay(delta)
    else moveAgent(delta)
  }

  function jumpEnds(end) {
    if (zone === "chat") return
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
    startSync()
    keys.forceActiveFocus()
  }

  function activePersonName() {
    if (people && people.currentName) return people.currentName
    if (status && status.userName) return status.userName
    return ""
  }

  function refreshPeople() {
    if (usersProc.running) return
    usersProc.command = [syncScript, "--users"]
    usersProc.running = true
  }

  function addPerson(name) {
    var trimmed = String(name || "").trim()
    if (!trimmed || usersProc.running) return
    usersProc.command = [syncScript, "--add-user", trimmed]
    usersProc.running = true
  }

  function askDelete(id, name) {
    if (!id || usersProc.running || pendingDelete) return
    pendingDelete = id
    pendingDeleteName = String(name || "this person")
    personField.focus = false
    keys.forceActiveFocus()
  }

  function confirmDelete() {
    var id = pendingDelete
    pendingDelete = ""
    pendingDeleteName = ""
    if (!id || usersProc.running) return
    usersProc.command = [syncScript, "--delete-user", id]
    usersProc.running = true
  }

  function enterPerson(id) {
    if (!id || personProc.running) return
    var args = [syncScript, "--user", id]
    if (sampleOnNextEnter) {
      sampleMode = true
      sampleOnNextEnter = false
      args.push("--sample")
    }
    personProc.command = args
    personProc.running = true
  }

  function askImport(kind) {
    fileMenuOpen = false
    if (!sessionEntered || !activePersonName()) {
      toast.show("Choose a person first")
      return
    }
    pendingImport = kind
  }

  function confirmImport() {
    var kind = pendingImport
    pendingImport = ""
    if (kind === "export") openExportFile()
    else if (kind === "xray") importRecord("--xray")
    else if (kind === "blood") importRecord("--blood")
    else if (kind === "urine") importRecord("--urine")
  }

  function importPrompt() {
    var name = activePersonName()
    if (pendingImport === "export") return "Save this Apple Health export for " + name + "?"
    if (pendingImport === "xray") return "Save this X-ray for " + name + "?"
    if (pendingImport === "blood") return "Save this blood test for " + name + "?"
    if (pendingImport === "urine") return "Save this urine test for " + name + "?"
    return "Save this file for " + name + "?"
  }

  function startSync() {
    if (sync.running) return false
    sync.command = sampleMode ? [syncScript, "--sample"] : [syncScript]
    status = {
      state: "syncing",
      message: sampleMode ? "Building sample data…" : "Opening saved health data…"
    }
    sync.running = true
    return true
  }

  function finishImport() {
    exportBusy = false
    importDotsTimer.stop()
  }

  function openExportFile() {
    if (pickExport.running || exportBusy) return
    if (sync.running) {
      toast.show("Still opening saved health data")
      return
    }
    exportBusy = true
    importDots = "."
    importDotsTimer.step = 0
    importDotsTimer.start()
    pickExport.command = [syncScript, "--pick"]
    pickExport.running = true
  }

  function refreshAgents() {
    if (agentsProc.running) return
    agentsProc.command = [agentScript, "list"]
    agentsProc.running = true
  }

  function sendChat(text) {
    if (!agents || !agents.selected) {
      openAgents()
      toast.show("Choose an Omarchy agent first")
      return
    }
    if (chatProc.running) return
    var metrics = (view && view.metrics) ? view.metrics : []
    var metric = (metricIndex >= 0 && metricIndex < metrics.length) ? metrics[metricIndex] : null
    var days = (view && view.days) ? view.days : []
    var payload = {
      message: text,
      scope: chatScope,
      focusId: chatFocusId,
      sample: !!(index && index.labeledSample) || sampleMode,
      range: view.label || "",
      metric: metric ? metric.name : "",
      day: dayIndex < days.length ? days[dayIndex] : "",
      dayValue: (metric && metric.seriesText && dayIndex < metric.seriesText.length) ? metric.seriesText[dayIndex] : "",
      trend: metric ? metric.trend : ""
    }
    chatBusy = true
    chatProc.payload = JSON.stringify(payload)
    chatProc.command = [agentScript, "chat"]
    chatProc.running = true
  }

  function importRecord(flag) {
    if (pickRecord.running || exportBusy) return
    if (sync.running) {
      toast.show("Still opening saved health data")
      return
    }
    fileMenuOpen = false
    exportBusy = true
    importDots = "."
    importDotsTimer.step = 0
    importDotsTimer.start()
    pickRecord.command = [syncScript, flag]
    pickRecord.running = true
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

  readonly property var severityColors: (index && index.severity && index.severity.colors)
    ? index.severity.colors
    : ({ severe: "#f7768e", alert: "#ff9e64", mild: "#e0af68", normal: "#9ece6a" })
  readonly property bool classifyAuto: !(index && index.severity) || index.severity.auto !== false
  readonly property bool classifyAll: !!(index && index.severity && index.severity.classifyAll)
  property bool classifyHold: false
  property bool classifyBusy: false
  property bool classifyCancel: false
  property string classifyNext: ""

  function applyIndex(raw) {
    try { index = JSON.parse(raw) } catch (e) { return }
    var first = !placedDay
    showSavedRange(first)
    if (first) {
      var days = (view && view.days) ? view.days : []
      if (days.length > 0) placedDay = true
    }
    classifySoon.restart()
  }

  function missingSelectionPoints() {
    var metrics = (view && view.metrics) ? view.metrics : []
    var metric = (metricIndex >= 0 && metricIndex < metrics.length) ? metrics[metricIndex] : null
    var days = (view && view.days) ? view.days : []
    if (!metric || !metric.series) return []
    var levels = metric.seriesLevel || []
    var points = []
    for (var i = metric.series.length - 1; i >= 0 && points.length < 40; i--) {
      var value = metric.series[i]
      if (value === null || value === undefined) continue
      if (levels[i]) continue
      points.push({ date: days[i], value: value })
    }
    points.reverse()
    return points
  }

  function startSelection(payload) {
    classifyBusy = true
    classifyTimeout.restart()
    classifyProc.mode = "selection"
    classifyProc.payload = payload
    classifyProc.command = [agentScript, "classify"]
    classifyProc.running = true
  }

  function queueClassification() {
    if (!sessionEntered || classifyHold || classifyAll || !classifyAuto) return
    var points = missingSelectionPoints()
    if (!points.length) return
    var metrics = view.metrics
    var metric = metrics[metricIndex]
    var payload = JSON.stringify({
      field: metric.id,
      metric: metric.name,
      unit: metric.unit || "count",
      sample: !!(index && index.labeledSample) || sampleMode,
      points: points
    })
    if (classifyProc.running) {
      if (classifyProc.payload === payload) return
      classifyNext = payload
      classifyCancel = true
      classifyProc.running = false
      return
    }
    startSelection(payload)
  }

  function queueBackground() {
    if (!sessionEntered || classifyBusy || classifyHold || !classifyAll) return
    classifyBusy = true
    classifyProc.mode = "all"
    classifyProc.payload = ""
    classifyProc.command = [agentScript, "classify", "--pending", "--limit", "40"]
    classifyProc.running = true
  }

  function saveSeverity(patch) {
    if (severityProc.running) return
    severityProc.payload = JSON.stringify(patch || {})
    severityProc.command = [syncScript, "--severity-config"]
    severityProc.running = true
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
    id: filesView
    path: root.cacheDir + "/files.json"
    watchChanges: true
    printErrors: false
    onLoaded: {
      try { root.library = JSON.parse(text()) } catch (e) { return }
    }
    onFileChanged: reload()
  }
  FileView {
    id: chatView
    path: root.cacheDir + "/chat.json"
    watchChanges: true
    printErrors: false
    onLoaded: {
      try {
        var parsed = JSON.parse(text())
        root.chatMessages = parsed.messages || []
      } catch (e) { return }
    }
    onFileChanged: reload()
  }
  FileView {
    id: usersFile
    path: root.cacheDir + "/users.json"
    watchChanges: true
    printErrors: false
    onLoaded: {
      try { root.people = JSON.parse(text()) } catch (e) { return }
    }
    onFileChanged: reload()
  }

  Process {
    id: sync
    running: false
    onExited: {
      indexFile.reload()
      statusFile.reload()
      filesView.reload()
      chatView.reload()
      if (root.exportBusy) root.finishImport()
    }
  }
  Process {
    id: chatProc
    running: false
    stdinEnabled: true
    property string payload: ""
    onStarted: write(payload + "\n")
    stdout: StdioCollector {
      onStreamFinished: {
        var msg = {}
        try { msg = JSON.parse(text) } catch (e) {
          toast.show("The agent returned nothing")
          return
        }
        if (!msg.ok) toast.show(msg.error || "The agent did not answer")
        chatView.reload()
      }
    }
    onExited: {
      root.chatBusy = false
      chatView.reload()
    }
  }
  Process {
    id: usersProc
    running: false
    stderr: StdioCollector { id: usersErr }
    onExited: (exitCode) => {
      usersFile.reload()
      if (exitCode !== 0) toast.show(String(usersErr.text || "").trim() || "Could not update people")
      else if (usersProc.command.length > 1 && usersProc.command[1] === "--add-user") personField.text = ""
    }
  }
  Timer {
    id: classifySoon
    interval: 300
    onTriggered: root.queueClassification()
  }
  Timer {
    id: classifyTimeout
    interval: 45000
    onTriggered: {
      if (!classifyProc.running) return
      root.classifyNext = ""
      root.classifyCancel = true
      root.classifyHold = true
      classifyProc.running = false
      toast.show("The agent took too long to classify this chart")
    }
  }
  Timer {
    id: classifyAllTimer
    interval: 800
    repeat: true
    running: root.sessionEntered && root.classifyAll && !root.classifyHold && !root.classifyBusy
    onTriggered: root.queueBackground()
  }
  Process {
    id: classifyProc
    running: false
    stdinEnabled: true
    property string payload: ""
    property string mode: "selection"
    stdout: StdioCollector { id: classifyOut }
    stderr: StdioCollector { id: classifyErr }
    onStarted: if (mode === "selection" && payload) write(payload + "\n")
    onExited: (exitCode) => {
      classifyTimeout.stop()
      root.classifyBusy = false
      if (root.classifyCancel) {
        root.classifyCancel = false
        var next = root.classifyNext
        root.classifyNext = ""
        if (next) root.startSelection(next)
        return
      }
      var msg = {}
      try { msg = JSON.parse(classifyOut.text) } catch (e) { msg = {} }
      if (exitCode !== 0 || msg.ok === false) {
        root.classifyHold = true
        toast.show(String(msg.error || classifyErr.text || "Could not classify this chart").trim())
        return
      }
      classifyAllTimer.interval = msg.done ? 8000 : 500
      indexFile.reload()
    }
  }
  Process {
    id: severityProc
    running: false
    stdinEnabled: true
    property string payload: ""
    stderr: StdioCollector { id: severityErr }
    onStarted: write(payload + "\n")
    onExited: (exitCode) => {
      if (exitCode !== 0) toast.show(String(severityErr.text || "").trim() || "Could not save severity settings")
      else indexFile.reload()
    }
  }
  Process {
    id: rangeProc
    running: false
    stderr: StdioCollector { id: rangeErr }
    onExited: (exitCode) => {
      if (exitCode !== 0) {
        toast.show(String(rangeErr.text || "").trim() || "Could not save that date range")
        board.dragAnchor = -1
        board.dragEnd = -1
        return
      }
      indexFile.reload()
    }
  }
  Process {
    id: personProc
    running: false
    stderr: StdioCollector { id: personErr }
    onExited: (exitCode) => {
      if (exitCode !== 0) {
        toast.show(String(personErr.text || "").trim() || "Could not open that person")
        return
      }
      root.sessionEntered = true
      indexFile.reload()
      statusFile.reload()
      filesView.reload()
      chatView.reload()
      usersFile.reload()
      keys.forceActiveFocus()
    }
  }
  Process {
    id: pickRecord
    running: false
    stderr: StdioCollector { id: recordErr }
    onExited: (exitCode) => {
      root.finishImport()
      if (exitCode === 0) filesView.reload()
      else if (exitCode !== 3) toast.show(String(recordErr.text || "").trim() || "Could not import that file")
    }
  }
  Process {
    id: pickExport
    running: false
    stderr: StdioCollector { id: pickErr }
    onExited: (exitCode) => {
      if (exitCode === 0) {
        root.sampleMode = false
        root.placedDay = false
        if (!root.startSync()) root.finishImport()
      } else {
        root.finishImport()
        if (exitCode !== 3) {
          toast.show(String(pickErr.text || "").trim() || "Could not open the file manager")
          statusFile.reload()
        }
      }
    }
  }
  Process {
    id: pickDatabase
    running: false
    stderr: StdioCollector { id: databaseErr }
    onExited: (exitCode) => {
      if (exitCode === 0) {
        root.placedDay = false
        indexFile.reload()
        statusFile.reload()
      } else if (exitCode !== 3) {
        toast.show(String(databaseErr.text || "").trim() || "Could not choose a database")
        statusFile.reload()
      }
    }
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
    onStarted: write(payload + "\n")
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
  Process {
    id: settingsPlace
    running: false
  }
  Timer {
    id: settingsRaise
    interval: 90
    repeat: true
    property int ticks: 0
    onTriggered: {
      ticks++
      if (ticks > 10 || !root.settingsOpen) {
        stop()
        return
      }
      root.placeWindow("OHealth Settings", true)
    }
  }

  function placeWindow(title, pinOn) {
    var action = pinOn ? "on" : "off"
    var sel = "title:^(" + title + ")$"
    var script = "hyprctl dispatch 'hl.dsp.window.pin({ action = \"" + action + "\", window = \"" + sel + "\" })'"
    if (pinOn) {
      script = "hyprctl dispatch 'hl.dsp.window.float({ action = \"set\", window = \"" + sel + "\" })'; " +
               "hyprctl dispatch 'hl.dsp.window.alter_zorder({ mode = \"top\", window = \"" + sel + "\" })'; " +
               script + "; " +
               "hyprctl dispatch 'hl.dsp.focus({ window = \"" + sel + "\" })'"
    }
    settingsPlace.command = ["sh", "-c", script]
    settingsPlace.running = false
    settingsPlace.running = true
  }

  Timer {
    id: keysRaise
    interval: 90
    repeat: true
    property int ticks: 0
    onTriggered: {
      ticks++
      if (ticks > 10 || !root.keysOpen) {
        stop()
        return
      }
      root.placeWindow("OHealth Keyboard", true)
    }
  }

  Timer {
    id: agentSave
    interval: 180
    onTriggered: if (!root.agentOpen) root.commitAgent(false)
  }

  FloatingWindow {
    id: win
    visible: true
    title: "OHealth"
    implicitWidth: 1500
    implicitHeight: 800
    color: appTheme.background

    Item {
      id: keys
      anchors.fill: parent
      focus: true
      Component.onCompleted: forceActiveFocus()

      Shortcut {
        sequence: "Ctrl+P"
        context: Qt.WindowShortcut
        enabled: root.screen === "empty" || root.sampleMode
        onActivated: root.useSample()
      }

      function itemContains(item, x, y) {
        if (!item || !item.visible) return false
        return item.contains(item.mapFromItem(keys, x, y))
      }

      MouseArea {
        z: 25
        anchors.fill: parent
        enabled: root.sessionEntered && !root.agentOpen && !root.fileMenuOpen && !root.settingsOpen && !root.keysOpen && root.pendingImport === "" && !root.exportBusy
        propagateComposedEvents: true
        onPressed: function(mouse) {
          mouse.accepted = false
          if (keys.itemContains(chatSidebar.composerField, mouse.x, mouse.y)) return
          chatSidebar.releaseInput()
          root.leaveChatZone()
          keys.forceActiveFocus()
        }
      }

      Keys.onPressed: event => {
        if (chatSidebar.editing) return
        var k = event.key
        var t = event.text
        var shift = (event.modifiers & Qt.ShiftModifier) !== 0
        var ctrl = (event.modifiers & Qt.ControlModifier) !== 0
        if (root.exportBusy) {
          event.accepted = true
          return
        }
        if (root.pendingDelete) {
          if (k === Qt.Key_Escape) {
            root.pendingDelete = ""
            root.pendingDeleteName = ""
          } else if (k === Qt.Key_Return || k === Qt.Key_Enter) root.confirmDelete()
          event.accepted = true
          return
        }
        if (root.pendingImport) {
          if (k === Qt.Key_Escape) root.pendingImport = ""
          else if (k === Qt.Key_Return || k === Qt.Key_Enter) root.confirmImport()
          event.accepted = true
          return
        }
        if (!root.sessionEntered) {
          if (personField.activeFocus) return
          if (t === "q") { Qt.quit(); return }
          event.accepted = true
          return
        }
        if (root.fileMenuOpen) {
          if (k === Qt.Key_Escape) root.fileMenuOpen = false
          event.accepted = true
          return
        }
        if (root.settingsOpen) {
          if (k === Qt.Key_Escape) root.closeSettings()
          event.accepted = true
          return
        }
        if (root.keysOpen) {
          if (t === "?" || k === Qt.Key_Escape || t === "q") root.closeKeys()
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
          } else if (t === "?") root.openKeys()
          else return
          event.accepted = true
          return
        }
        if (t === "?") { root.openKeys(); event.accepted = true; return }
        if (t === "a") { root.openAgents(); event.accepted = true; return }
        if (ctrl && (t === "p" || t === "P")) { root.useSample(); event.accepted = true; return }
        if (t === "q") { Qt.quit(); return }
        if (k === Qt.Key_Escape) { Qt.quit(); return }
        if (k === Qt.Key_Tab) { root.cycleZone(shift ? -1 : 1); event.accepted = true; return }
        if (k === Qt.Key_Backtab) { root.cycleZone(-1); event.accepted = true; return }
        if (t >= "1" && t <= "7" && t.length === 1) root.setRange(t.charCodeAt(0) - 49)
        else if (t === "[") root.moveRange(-1)
        else if (t === "]") root.moveRange(1)
        else if (t === "r") { root.sampleMode = false; root.startSync() }
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
        id: menuBar
        z: 20
        anchors.top: parent.top
        anchors.left: parent.left
        anchors.right: parent.right
        height: 30
        color: appTheme.darkerBackground

        Rectangle {
          anchors.bottom: parent.bottom
          width: parent.width
          height: 1
          color: appTheme.lighterBackground
        }

        Rectangle {
          id: fileMenuButton
          x: 6
          anchors.verticalCenter: parent.verticalCenter
          width: fileMenuLabel.implicitWidth + 22
          height: 22
          radius: 4
          color: root.fileMenuOpen || fileMenuArea.containsMouse ? appTheme.selection : "transparent"
          Text {
            id: fileMenuLabel
            anchors.centerIn: parent
            text: "File"
            color: appTheme.brightForeground
            font.family: appTheme.fontFamily
            font.pixelSize: appTheme.fontSize
          }
          MouseArea {
            id: fileMenuArea
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: root.fileMenuOpen = !root.fileMenuOpen
          }
        }
      }

      Rectangle {
        id: header
        anchors.top: menuBar.bottom
        anchors.left: parent.left
        anchors.right: parent.right
        height: 56
        color: appTheme.darkBackground

        Item {
          anchors.left: parent.left
          anchors.leftMargin: 20
          anchors.verticalCenter: parent.verticalCenter
          width: titleRow.implicitWidth
          height: titleRow.implicitHeight
          Row {
            id: titleRow
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
              visible: root.sessionEntered && root.activePersonName().length > 0
              text: root.activePersonName()
              color: appTheme.accent
              font.family: appTheme.fontFamily
              font.pixelSize: appTheme.fontSize
              font.bold: true
              anchors.verticalCenter: parent.verticalCenter
            }
          }
          MouseArea {
            anchors.fill: parent
            enabled: root.sessionEntered
            cursorShape: root.sessionEntered ? Qt.PointingHandCursor : Qt.ArrowCursor
            onClicked: root.sessionEntered = false
          }
        }
        Text {
          anchors.right: parent.right
          anchors.rightMargin: 20
          anchors.verticalCenter: parent.verticalCenter
          width: 420
          horizontalAlignment: Text.AlignRight
          elide: Text.ElideLeft
          text: root.status.message || ""
          color: root.status.state === "error" ? appTheme.red : appTheme.darkForeground
          font.family: appTheme.fontFamily
          font.pixelSize: appTheme.fontSize - 2
        }
      }

      Dashboard {
        id: board
        anchors.top: header.bottom
        anchors.bottom: footer.top
        anchors.left: parent.left
        anchors.right: chatSidebar.left
        theme: appTheme
        view: root.view
        metricIndex: root.metricIndex
        dayIndex: root.dayIndex
        zone: root.zone
        rangeIndex: root.rangeIndex
        customActive: root.customActive
        state: root.screen
        stateMessage: root.status.message || ""
        errorMessage: root.errorMessage
        sample: (root.index && root.index.labeledSample) || root.sampleMode
        agentLabel: root.agentLabel()
        agentInstalled: root.agentIsInstalled()
        gallery: root.gallery
        focusId: root.chatFocusId
        xrays: (root.library && root.library.xrays) ? root.library.xrays : []
        blood: (root.library && root.library.blood) ? root.library.blood : []
        urine: (root.library && root.library.urine) ? root.library.urine : []
        onRangeChosen: index => root.setRange(index)
        onCustomRangeChosen: (start, end) => root.saveCustomRange(start, end)
        severityColors: root.severityColors
        classifying: root.classifyBusy
        onMetricChosen: index => {
          root.classifyHold = false
          root.metricIndex = index
          root.gallery = ""
          classifySoon.restart()
        }
        onDayChosen: index => root.dayIndex = index
        onZoneChosen: name => {
          for (var i = 0; i < root.zones.length; i++) if (root.zones[i] === name) root.zoneIndex = i
        }
        onSectionChosen: name => root.gallery = name
        onDocumentChosen: (id, kind) => root.chatFocusId = id
        onGalleryClosed: root.gallery = ""
      }

      Chat {
        id: chatSidebar
        anchors.top: header.bottom
        anchors.bottom: footer.top
        anchors.right: parent.right
        width: 372
        theme: appTheme
        agentLabel: root.agentLabel()
        busy: root.chatBusy
        scope: root.chatScope
        messages: root.chatMessages
        onSendRequested: text => root.sendChat(text)
        onScopeChosen: name => root.chatScope = name
        onAgentRequested: root.openAgents()
        onInputFocused: root.noteChatFocused()
        onFocusTabbed: dir => root.cycleZone(dir)
        onEditFinished: {
          root.leaveChatZone()
          keys.forceActiveFocus()
        }
      }

      Rectangle {
        id: footer
        anchors.bottom: parent.bottom
        anchors.left: parent.left
        anchors.right: parent.right
        height: 40
        color: appTheme.darkerBackground
        border.width: root.zone === "agent" ? 2 : 0
        border.color: appTheme.accent
        Row {
          anchors.fill: parent
          anchors.leftMargin: 16
          anchors.rightMargin: 16
          spacing: 16
          Item {
            width: agentLaunch.implicitWidth
            height: parent.height
            Row {
              id: agentLaunch
              anchors.verticalCenter: parent.verticalCenter
              spacing: 10
              Text {
                text: "Agent"
                color: root.zone === "agent" ? appTheme.brightForeground : appTheme.foreground
                font.family: appTheme.fontFamily
                font.pixelSize: appTheme.fontSize
                font.bold: root.zone === "agent"
                anchors.verticalCenter: parent.verticalCenter
              }
              Text {
                text: root.agentLabel() + (root.agentIsInstalled() ? "" : "  · not on PATH")
                color: appTheme.accent
                font.family: appTheme.fontFamily
                font.pixelSize: appTheme.fontSize
                font.bold: true
                anchors.verticalCenter: parent.verticalCenter
              }
            }
            MouseArea {
              anchors.fill: parent
              cursorShape: Qt.PointingHandCursor
              onClicked: {
                root.focusZone("agent")
                root.openAgents()
                keys.forceActiveFocus()
              }
            }
          }
          Text {
            anchors.verticalCenter: parent.verticalCenter
            text: "enter ask   a choose   r sync   ? keys"
            color: appTheme.darkForeground
            font.family: appTheme.fontFamily
            font.pixelSize: appTheme.fontSize - 2
          }
        }
      }

      MouseArea {
        z: 10
        anchors.fill: parent
        enabled: root.fileMenuOpen
        onClicked: root.fileMenuOpen = false
      }

      Rectangle {
        id: fileMenu
        property bool importMenuOpen: false
        visible: root.fileMenuOpen
        z: 30
        x: fileMenuButton.x
        y: menuBar.height - 1
        width: Math.max(200, personItem.implicitLabel + 36, importItem.implicitLabel + 44)
        height: fileMenuCol.implicitHeight + 8
        radius: 6
        color: appTheme.darkBackground
        border.color: appTheme.lighterBackground
        border.width: 1
        onVisibleChanged: if (!visible) importMenuOpen = false

        component FileAction: Rectangle {
          id: action
          property string label: ""
          property bool rule: false
          property bool opensMenu: false
          property bool inSubmenu: false
          property int implicitLabel: actionText.implicitWidth
          signal triggered()
          width: parent.width
          height: rule ? 9 : 30
          radius: 4
          color: !rule && (actionArea.containsMouse || (action.opensMenu && fileMenu.importMenuOpen)) ? appTheme.selection : "transparent"
          Rectangle {
            visible: action.rule
            anchors.verticalCenter: parent.verticalCenter
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.leftMargin: 8
            anchors.rightMargin: 8
            height: 1
            color: appTheme.lighterBackground
          }
          Text {
            id: actionText
            visible: !action.rule
            anchors.verticalCenter: parent.verticalCenter
            anchors.left: parent.left
            anchors.leftMargin: 12
            anchors.right: action.opensMenu ? menuArrow.left : parent.right
            anchors.rightMargin: action.opensMenu ? 6 : 12
            text: action.label
            color: appTheme.brightForeground
            font.family: appTheme.fontFamily
            font.pixelSize: appTheme.fontSize
            elide: Text.ElideRight
          }
          Text {
            id: menuArrow
            visible: action.opensMenu
            anchors.verticalCenter: parent.verticalCenter
            anchors.right: parent.right
            anchors.rightMargin: 10
            text: "›"
            color: appTheme.foreground
            font.family: appTheme.fontFamily
            font.pixelSize: appTheme.fontSize + 2
          }
          MouseArea {
            id: actionArea
            anchors.fill: parent
            enabled: !action.rule
            hoverEnabled: true
            cursorShape: action.rule ? Qt.ArrowCursor : Qt.PointingHandCursor
            onEntered: if (!action.inSubmenu) fileMenu.importMenuOpen = action.opensMenu
            onClicked: action.triggered()
          }
        }

        Column {
          id: fileMenuCol
          x: 4
          y: 4
          width: parent.width - 8
          spacing: 2
          FileAction {
            label: "Settings"
            onTriggered: root.openSettings()
          }
          FileAction {
            label: "Keyboard"
            onTriggered: root.openKeys()
          }
          FileAction {
            id: personItem
            label: "Switch person"
            onTriggered: {
              root.fileMenuOpen = false
              root.sessionEntered = false
            }
          }
          FileAction {
            id: importItem
            label: "Import"
            opensMenu: true
            onTriggered: fileMenu.importMenuOpen = true
          }
          FileAction { rule: true }
          FileAction {
            label: "Close"
            onTriggered: Qt.quit()
          }
        }

        Rectangle {
          id: importMenu
          visible: fileMenu.importMenuOpen
          z: 2
          x: parent.width - 6
          y: fileMenuCol.y + importItem.y - 4
          width: Math.max(240, healthImport.implicitLabel + 28)
          height: importMenuCol.implicitHeight + 8
          radius: 6
          color: appTheme.darkBackground
          border.color: appTheme.lighterBackground
          border.width: 1

          Column {
            id: importMenuCol
            x: 4
            y: 4
            width: parent.width - 8
            spacing: 2
            FileAction {
              id: healthImport
              label: "Apple HealthKit Export"
              inSubmenu: true
              onTriggered: root.askImport("export")
            }
            FileAction {
              label: "X-ray"
              inSubmenu: true
              onTriggered: root.askImport("xray")
            }
            FileAction {
              label: "Blood Test"
              inSubmenu: true
              onTriggered: root.askImport("blood")
            }
            FileAction {
              label: "Urine Test"
              inSubmenu: true
              onTriggered: root.askImport("urine")
            }
          }
        }
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
        visible: root.exportBusy
        z: 60
        anchors.fill: parent
        color: Qt.rgba(0, 0, 0, 0.55)
        MouseArea { anchors.fill: parent }

        Timer {
          id: importDotsTimer
          interval: 400
          repeat: true
          running: false
          property int step: 0
          onTriggered: {
            var marks = [".", "..", "..."]
            step = (step + 1) % marks.length
            root.importDots = marks[step]
          }
        }

        Column {
          anchors.centerIn: parent
          spacing: 16

          Item {
            width: 56
            height: 56
            anchors.horizontalCenter: parent.horizontalCenter
            RotationAnimation on rotation {
              from: 0
              to: 360
              duration: 900
              loops: Animation.Infinite
              running: root.exportBusy
            }
            Canvas {
              anchors.fill: parent
              onPaint: {
                var ctx = getContext("2d")
                ctx.clearRect(0, 0, width, height)
                var cx = width / 2
                var cy = height / 2
                var radius = 18
                var end = Math.PI * 1.65
                ctx.strokeStyle = appTheme.accent
                ctx.fillStyle = appTheme.accent
                ctx.lineWidth = 4
                ctx.lineCap = "round"
                ctx.beginPath()
                ctx.arc(cx, cy, radius, 0.35, end)
                ctx.stroke()
                var x = cx + radius * Math.cos(end)
                var y = cy + radius * Math.sin(end)
                var tangent = end + Math.PI / 2
                ctx.beginPath()
                ctx.moveTo(x + 8 * Math.cos(tangent), y + 8 * Math.sin(tangent))
                ctx.lineTo(x + 9 * Math.cos(end), y + 9 * Math.sin(end))
                ctx.lineTo(x - 8 * Math.cos(tangent), y - 8 * Math.sin(tangent))
                ctx.closePath()
                ctx.fill()
              }
              Component.onCompleted: requestPaint()
            }
          }

          Item {
            anchors.horizontalCenter: parent.horizontalCenter
            width: importingLabel.implicitWidth + importingDotsWidth.implicitWidth
            height: importingLabel.implicitHeight
            Text {
              id: importingLabel
              text: "importing"
              color: appTheme.brightForeground
              font.family: appTheme.fontFamily
              font.pixelSize: appTheme.fontSize + 2
            }
            Text {
              id: importingDotsWidth
              visible: false
              text: "..."
              font.family: appTheme.fontFamily
              font.pixelSize: appTheme.fontSize + 2
            }
            Text {
              anchors.left: importingLabel.right
              text: root.importDots
              color: appTheme.brightForeground
              font.family: appTheme.fontFamily
              font.pixelSize: appTheme.fontSize + 2
            }
          }
        }
      }

      Rectangle {
        visible: !root.sessionEntered
        z: 80
        anchors.fill: parent
        color: Qt.rgba(0, 0, 0, 0.45)
        onVisibleChanged: if (visible) personField.forceActiveFocus()

        Rectangle {
          anchors.centerIn: parent
          width: 440
          height: personCol.implicitHeight + 36
          radius: 10
          color: appTheme.darkBackground
          border.width: 1
          border.color: appTheme.lighterBackground

          Column {
            id: personCol
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.top: parent.top
            anchors.margins: 18
            spacing: 12

            Text {
              width: parent.width
              text: "Who is this for?"
              color: appTheme.brightForeground
              font.family: appTheme.fontFamily
              font.pixelSize: 18
              font.bold: true
            }
            Text {
              width: parent.width
              wrapMode: Text.Wrap
              text: "Each person keeps their own health data, X-rays, and lab results in this database."
              color: appTheme.darkForeground
              font.family: appTheme.fontFamily
              font.pixelSize: appTheme.fontSize - 1
            }
            Text {
              visible: !root.people || !root.people.users || root.people.users.length === 0
              width: parent.width
              wrapMode: Text.Wrap
              text: "Add the first person to open the app."
              color: appTheme.foreground
              font.family: appTheme.fontFamily
              font.pixelSize: appTheme.fontSize
            }
            Repeater {
              model: (root.people && root.people.users) ? root.people.users : []
              delegate: Rectangle {
                required property var modelData
                width: personCol.width
                height: 36
                radius: 6
                color: root.people.current === modelData.id ? appTheme.selection : appTheme.darkerBackground
                border.width: 1
                border.color: root.people.current === modelData.id ? appTheme.accent : appTheme.lighterBackground
                MouseArea {
                  anchors.fill: parent
                  cursorShape: Qt.PointingHandCursor
                  enabled: !personProc.running && !usersProc.running
                  onClicked: root.enterPerson(modelData.id)
                }
                Text {
                  anchors.left: parent.left
                  anchors.right: removePerson.left
                  anchors.leftMargin: 12
                  anchors.rightMargin: 8
                  anchors.verticalCenter: parent.verticalCenter
                  text: modelData.name
                  color: appTheme.brightForeground
                  font.family: appTheme.fontFamily
                  font.pixelSize: appTheme.fontSize
                  elide: Text.ElideRight
                }
                Rectangle {
                  id: removePerson
                  z: 1
                  anchors.right: parent.right
                  anchors.rightMargin: 6
                  anchors.verticalCenter: parent.verticalCenter
                  width: 24
                  height: 24
                  radius: 4
                  color: removePersonArea.containsMouse ? appTheme.selection : "transparent"
                  Text {
                    anchors.centerIn: parent
                    text: "−"
                    color: appTheme.red
                    font.family: appTheme.fontFamily
                    font.pixelSize: appTheme.fontSize + 4
                    font.bold: true
                  }
                  MouseArea {
                    id: removePersonArea
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    enabled: !personProc.running && !usersProc.running
                    onClicked: root.askDelete(modelData.id, modelData.name)
                  }
                }
              }
            }
            Row {
              width: parent.width
              spacing: 8
              Rectangle {
                width: parent.width - addPersonButton.width - 8
                height: 36
                radius: 6
                color: appTheme.darkerBackground
                border.width: 1
                border.color: appTheme.lighterBackground
                TextInput {
                  id: personField
                  anchors.fill: parent
                  anchors.margins: 8
                  clip: true
                  color: appTheme.brightForeground
                  font.family: appTheme.fontFamily
                  font.pixelSize: appTheme.fontSize
                  verticalAlignment: TextInput.AlignVCenter
                  selectByMouse: true
                  Keys.onReturnPressed: root.addPerson(text)
                  Keys.onEnterPressed: root.addPerson(text)
                }
              }
              Rectangle {
                id: addPersonButton
                width: 72
                height: 36
                radius: 6
                color: addPersonArea.containsMouse ? Qt.lighter(appTheme.accent, 1.12) : appTheme.accent
                Text {
                  anchors.centerIn: parent
                  text: "Add"
                  color: appTheme.darkerBackground
                  font.family: appTheme.fontFamily
                  font.pixelSize: appTheme.fontSize - 1
                  font.bold: true
                }
                MouseArea {
                  id: addPersonArea
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onClicked: root.addPerson(personField.text)
                }
              }
            }
          }
        }
      }

      Rectangle {
        visible: root.pendingDelete !== ""
        z: 90
        anchors.fill: parent
        color: Qt.rgba(0, 0, 0, 0.45)
        MouseArea { anchors.fill: parent }

        Rectangle {
          z: 1
          anchors.centerIn: parent
          width: 460
          height: deleteCol.implicitHeight + 36
          radius: 10
          color: appTheme.darkBackground
          border.width: 1
          border.color: appTheme.lighterBackground

          Column {
            id: deleteCol
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.top: parent.top
            anchors.margins: 18
            spacing: 16
            Text {
              width: parent.width
              wrapMode: Text.Wrap
              text: "Remove " + root.pendingDeleteName + "?"
              color: appTheme.brightForeground
              font.family: appTheme.fontFamily
              font.pixelSize: appTheme.fontSize + 2
              font.bold: true
            }
            Text {
              width: parent.width
              wrapMode: Text.Wrap
              text: "This deletes their health data, X-rays, lab results, and chat."
              color: appTheme.foreground
              font.family: appTheme.fontFamily
              font.pixelSize: appTheme.fontSize
            }
            Row {
              spacing: 10
              Rectangle {
                width: cancelDeleteLabel.implicitWidth + 28
                height: 34
                radius: 6
                color: cancelDeleteArea.containsMouse ? appTheme.selection : appTheme.darkerBackground
                border.width: 1
                border.color: appTheme.lighterBackground
                Text {
                  id: cancelDeleteLabel
                  anchors.centerIn: parent
                  text: "Cancel"
                  color: appTheme.foreground
                  font.family: appTheme.fontFamily
                  font.pixelSize: appTheme.fontSize
                }
                MouseArea {
                  id: cancelDeleteArea
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onClicked: {
                    root.pendingDelete = ""
                    root.pendingDeleteName = ""
                  }
                }
              }
              Rectangle {
                width: confirmDeleteLabel.implicitWidth + 28
                height: 34
                radius: 6
                color: confirmDeleteArea.containsMouse ? Qt.lighter(appTheme.red, 1.12) : appTheme.red
                Text {
                  id: confirmDeleteLabel
                  anchors.centerIn: parent
                  text: "Remove"
                  color: appTheme.darkerBackground
                  font.family: appTheme.fontFamily
                  font.pixelSize: appTheme.fontSize
                  font.bold: true
                }
                MouseArea {
                  id: confirmDeleteArea
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onClicked: root.confirmDelete()
                }
              }
            }
          }
        }
      }

      Rectangle {
        visible: root.pendingImport !== ""
        z: 70
        anchors.fill: parent
        color: Qt.rgba(0, 0, 0, 0.45)

        Rectangle {
          anchors.centerIn: parent
          width: 460
          height: confirmCol.implicitHeight + 36
          radius: 10
          color: appTheme.darkBackground
          border.width: 1
          border.color: appTheme.lighterBackground

          Column {
            id: confirmCol
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.top: parent.top
            anchors.margins: 18
            spacing: 16
            Text {
              width: parent.width
              wrapMode: Text.Wrap
              text: root.importPrompt()
              color: appTheme.brightForeground
              font.family: appTheme.fontFamily
              font.pixelSize: appTheme.fontSize + 2
              font.bold: true
            }
            Text {
              width: parent.width
              wrapMode: Text.Wrap
              text: "The file is stored for " + root.activePersonName() + " only."
              color: appTheme.foreground
              font.family: appTheme.fontFamily
              font.pixelSize: appTheme.fontSize
            }
            Row {
              spacing: 10
              Rectangle {
                width: cancelImportLabel.implicitWidth + 28
                height: 34
                radius: 6
                color: cancelImportArea.containsMouse ? appTheme.selection : appTheme.darkerBackground
                border.width: 1
                border.color: appTheme.lighterBackground
                Text {
                  id: cancelImportLabel
                  anchors.centerIn: parent
                  text: "Cancel"
                  color: appTheme.foreground
                  font.family: appTheme.fontFamily
                  font.pixelSize: appTheme.fontSize
                }
                MouseArea {
                  id: cancelImportArea
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onClicked: root.pendingImport = ""
                }
              }
              Rectangle {
                width: confirmImportLabel.implicitWidth + 28
                height: 34
                radius: 6
                color: confirmImportArea.containsMouse ? Qt.lighter(appTheme.accent, 1.12) : appTheme.accent
                Text {
                  id: confirmImportLabel
                  anchors.centerIn: parent
                  text: "Import"
                  color: appTheme.darkerBackground
                  font.family: appTheme.fontFamily
                  font.pixelSize: appTheme.fontSize
                  font.bold: true
                }
                MouseArea {
                  id: confirmImportArea
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onClicked: root.confirmImport()
                }
              }
            }
          }
        }
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

  FloatingWindow {
    id: settingsWin
    visible: root.settingsOpen
    title: "OHealth Settings"
    parentWindow: win
    implicitWidth: 560
    implicitHeight: 680
    color: appTheme.background
    onVisibleChanged: if (visible) settingsPanel.forceActiveFocus()
    Settings {
      id: settingsPanel
      anchors.fill: parent
      theme: appTheme
      databasePath: root.databasePath
      colors: root.severityColors
      classifyAuto: root.classifyAuto
      classifyAll: root.classifyAll
      onRequestClose: root.closeSettings()
      onRequestChoose: root.chooseDatabase()
      onColorsChosen: (severe, alert, mild, normal) => root.saveSeverity({
        severe: severe,
        alert: alert,
        mild: mild,
        normal: normal
      })
      onClassifyAutoChosen: enabled => {
        root.classifyHold = false
        root.saveSeverity({ auto: enabled })
      }
      onClassifyAllChosen: enabled => {
        root.classifyHold = false
        classifyAllTimer.interval = 800
        root.saveSeverity({ classifyAll: enabled })
      }
    }
  }

  FloatingWindow {
    id: keysWin
    visible: root.keysOpen
    title: "OHealth Keyboard"
    parentWindow: win
    implicitWidth: 720
    implicitHeight: 640
    color: appTheme.background
    onVisibleChanged: if (visible) keysPanel.forceActiveFocus()
    Help {
      id: keysPanel
      anchors.fill: parent
      theme: appTheme
      onRequestClose: root.closeKeys()
    }
  }
}
