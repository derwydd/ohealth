import QtQuick

// Navigation, the overview cards, and one card page per metric or document.
// The shell owns the keyboard. Clicks only repeat those moves.
Item {
  id: root

  required property var theme
  property var view: ({})
  property int metricIndex: 0
  property int dayIndex: 0
  property string zone: "metrics"
  property int rangeIndex: 1
  property bool customActive: false
  property int dragAnchor: -1
  property int dragEnd: -1
  property var rangeLabels: ["7 days", "30 days", "90 days", "1 year", "3 years", "5 years", "All"]
  property string state: "loading"
  property string stateMessage: ""
  property string errorMessage: ""
  property bool sample: false
  property string agentLabel: "No agent chosen"
  property bool agentInstalled: false
  property string gallery: ""
  property bool overview: true
  property var xrays: []
  property var blood: []
  property var urine: []
  property string focusId: ""
  property var severityColors: ({})
  property bool classifying: false

  signal rangeChosen(int index)
  signal customRangeChosen(string start, string end)
  signal overviewChosen()
  signal metricChosen(int index)
  signal dayChosen(int index)
  signal zoneChosen(string name)
  signal sectionChosen(string name)
  signal documentChosen(string id, string kind)
  signal fileDeleteChosen(string id, string name)
  signal galleryClosed()

  readonly property var metrics: (view && view.metrics) ? view.metrics : []
  readonly property var summary: (view && view.summary) ? view.summary : []
  readonly property var days: (view && view.days) ? view.days : []
  readonly property var metric: (metricIndex >= 0 && metricIndex < metrics.length) ? metrics[metricIndex] : null
  readonly property var series: (metric && metric.series) ? metric.series : []
  readonly property bool hasDays: days.length > 0 && metrics.length > 0
  readonly property string page: gallery !== "" ? "gallery" : (overview ? "overview" : "metric")
  readonly property color metricTint: metric ? metricColor(metric.id) : theme.accent

  function alpha(c, a) { return Qt.rgba(c.r, c.g, c.b, a) }

  function metricColor(id) {
    if (id === "steps") return theme.blue
    if (id === "activeKcal") return theme.orange
    if (id === "exerciseMin") return theme.green
    if (id === "distanceKm") return theme.brightCyan
    if (id === "sleepHours") return theme.magenta
    if (id === "restingHr") return theme.red
    if (id === "heartRate") return Qt.lighter(theme.red, 1.12)
    if (id === "hrv") return theme.cyan
    if (id === "spo2") return theme.brightCyan
    if (id === "respiratory") return theme.brightGreen
    if (id === "weightKg") return theme.yellow
    return theme.accent
  }

  function levelColor(level) {
    var colors = severityColors || {}
    if (level && colors[level]) return colors[level]
    return theme.muted
  }

  function digitsFor(id) {
    return (id === "distanceKm" || id === "sleepHours" || id === "weightKg") ? 1 : 0
  }

  function goalFor(id) {
    if (id === "steps") return 10000
    if (id === "activeKcal") return 500
    if (id === "exerciseMin") return 30
    if (id === "sleepHours") return 8
    if (id === "distanceKm") return 5
    return 0
  }

  function fmt(value, digits) {
    if (value === null || value === undefined || !isFinite(Number(value))) return "—"
    var n = Number(value)
    var text = digits > 0 ? n.toFixed(digits) : String(Math.round(n))
    var parts = text.split(".")
    parts[0] = parts[0].replace(/\B(?=(\d{3})+(?!\d))/g, ",")
    return parts.join(".")
  }

  function metricById(id) {
    for (var i = 0; i < metrics.length; i++) if (metrics[i].id === id) return metrics[i]
    return null
  }

  function metricIndexOf(id) {
    for (var i = 0; i < metrics.length; i++) if (metrics[i].id === id) return i
    return -1
  }

  function numbers(m, from) {
    var out = []
    var list = (m && m.series) ? m.series : []
    for (var i = Math.max(0, from || 0); i < list.length; i++) {
      var v = list[i]
      if (v !== null && v !== undefined && isFinite(Number(v))) out.push(Number(v))
    }
    return out
  }

  function mean(list) {
    if (!list.length) return null
    var total = 0
    for (var i = 0; i < list.length; i++) total += list[i]
    return total / list.length
  }

  function avgOf(id) { return mean(numbers(metricById(id), 0)) }

  function lastOf(id) {
    var m = metricById(id)
    var list = (m && m.series) ? m.series : []
    for (var i = list.length - 1; i >= 0; i--) if (list[i] !== null && list[i] !== undefined) return Number(list[i])
    return null
  }

  function tail(id, n) {
    var m = metricById(id)
    var list = (m && m.series) ? m.series : []
    return list.slice(Math.max(0, list.length - n))
  }

  function levelCounts(m) {
    var out = { normal: 0, mild: 0, alert: 0, severe: 0, total: 0 }
    var levels = (m && m.seriesLevel) ? m.seriesLevel : []
    for (var i = 0; i < levels.length; i++) {
      var l = levels[i]
      if (l && out[l] !== undefined) {
        out[l] += 1
        out.total += 1
      }
    }
    return out
  }

  function allLevelCounts() {
    var out = { normal: 0, mild: 0, alert: 0, severe: 0, total: 0 }
    for (var i = 0; i < metrics.length; i++) {
      var c = levelCounts(metrics[i])
      out.normal += c.normal
      out.mild += c.mild
      out.alert += c.alert
      out.severe += c.severe
      out.total += c.total
    }
    return out
  }

  function flaggedMetrics() {
    var rows = []
    for (var i = 0; i < metrics.length; i++) {
      var c = levelCounts(metrics[i])
      var weight = c.severe * 3 + c.alert * 2 + c.mild
      if (weight > 0) rows.push({ index: i, name: metrics[i].name, id: metrics[i].id, severe: c.severe, alert: c.alert, mild: c.mild, weight: weight })
    }
    rows.sort(function(a, b) { return b.weight - a.weight })
    return rows.slice(0, 3)
  }

  function score() {
    var counts = allLevelCounts()
    if (counts.total > 0) return { value: counts.normal / counts.total, label: "days in range" }
    var good = 0
    var rated = 0
    for (var i = 0; i < metrics.length; i++) {
      var tone = metrics[i].tone
      if (tone === "good" || tone === "flat") { good += 1; rated += 1 }
      else if (tone === "warn") rated += 1
    }
    if (rated === 0) return { value: 0, label: "no trend yet" }
    return { value: good / rated, label: "metrics on track" }
  }

  function toneColor(tone) {
    if (tone === "good") return theme.green
    if (tone === "warn") return theme.orange
    if (tone === "flat") return theme.foreground
    return theme.darkForeground
  }

  function dayName(iso) {
    if (!iso) return ""
    var p = String(iso).split("-")
    if (p.length < 3) return String(iso)
    var dt = new Date(Number(p[0]), Number(p[1]) - 1, Number(p[2]))
    var names = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
    var months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
    return names[dt.getDay()] + " " + dt.getDate() + " " + months[dt.getMonth()]
  }

  function weekday(iso) {
    var p = String(iso || "").split("-")
    if (p.length < 3) return ""
    var dt = new Date(Number(p[0]), Number(p[1]) - 1, Number(p[2]))
    return ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"][dt.getDay()]
  }

  function dateNumber(iso) {
    var p = String(iso || "").split("-")
    return p.length < 3 ? "" : String(Number(p[2]))
  }

  function rangeSpan() {
    if (!view) return ""
    var start = view.start || (days.length ? days[0] : "")
    var end = view.end || (days.length ? days[days.length - 1] : "")
    if (!start || !end) return view.label || ""
    return (view.label || "") + "  ·  " + dayName(start) + " – " + dayName(end)
  }

  function dayAt(x, width) {
    var n = series.length
    if (n === 0 || width <= 0) return -1
    var index = Math.floor(x / (width / n))
    return Math.max(0, Math.min(n - 1, index))
  }

  function formatAxis(value) {
    var n = Number(value)
    if (!isFinite(n)) return ""
    var negative = n < 0
    n = Math.abs(n)
    var text = (n >= 100 || Math.abs(n - Math.round(n)) < 0.05) ? String(Math.round(n)) : n.toFixed(1)
    var parts = text.split(".")
    parts[0] = parts[0].replace(/\B(?=(\d{3})+(?!\d))/g, ",")
    return (negative ? "−" : "") + parts.join(".")
  }

  function axisScale(maxV) {
    var max = Number(maxV)
    if (!(max > 0)) return { ceiling: 1, ticks: [0] }
    var rough = max / 4
    var mag = Math.pow(10, Math.floor(Math.log10(rough)))
    if (!isFinite(mag) || mag <= 0) mag = 1
    var residual = rough / mag
    var nice = residual <= 1 ? 1 : residual <= 2 ? 2 : residual <= 5 ? 5 : 10
    var step = nice * mag
    var ceiling = Math.ceil((max / step) - 1e-9) * step
    if (!(ceiling >= max)) ceiling += step
    var ticks = []
    for (var v = 0, guard = 0; v <= ceiling + step * 0.001 && guard < 8; v += step, guard++)
      ticks.push(Math.round(v * 1000) / 1000)
    return { ceiling: ticks.length ? ticks[ticks.length - 1] : ceiling, ticks: ticks }
  }

  function openMetric(id) {
    var i = metricIndexOf(id)
    if (i < 0) return
    zoneChosen("metrics")
    metricChosen(i)
  }

  onViewChanged: {
    dragAnchor = -1
    dragEnd = -1
  }

  // Navigation
  Rectangle {
    id: nav
    anchors.top: parent.top
    anchors.bottom: parent.bottom
    anchors.left: parent.left
    anchors.margins: 14
    anchors.rightMargin: 0
    width: 236
    radius: 18
    color: Qt.tint(theme.darkerBackground, root.alpha(theme.accent, 0.04))
    border.width: root.zone === "metrics" ? 2 : 1
    border.color: root.zone === "metrics" ? theme.accent : root.alpha(theme.accent, 0.18)

    Flickable {
      anchors.top: parent.top
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.bottom: scoreCard.top
      anchors.margins: 10
      anchors.bottomMargin: 10
      contentHeight: navCol.implicitHeight
      clip: true
      boundsBehavior: Flickable.StopAtBounds

      Column {
        id: navCol
        width: parent.width
        spacing: 3

        Rectangle {
          id: dashPill
          width: navCol.width
          height: 40
          radius: 12
          readonly property bool active: root.page === "overview"
          border.width: active ? 1 : 0
          border.color: root.alpha(theme.accent, 0.6)
          gradient: Gradient {
            orientation: Gradient.Horizontal
            GradientStop { position: 0.0; color: dashPill.active ? root.alpha(theme.accent, 0.38) : "transparent" }
            GradientStop { position: 1.0; color: dashPill.active ? root.alpha(theme.magenta, 0.16) : "transparent" }
          }
          Row {
            anchors.verticalCenter: parent.verticalCenter
            anchors.left: parent.left
            anchors.leftMargin: 12
            spacing: 10
            Ring {
              width: 18
              height: 18
              anchors.verticalCenter: parent.verticalCenter
              value: 0.72
              thickness: 3
              color: theme.accent
              color2: theme.brightCyan
              track: root.alpha(theme.accent, 0.2)
            }
            Text {
              anchors.verticalCenter: parent.verticalCenter
              text: "Dashboard"
              color: theme.brightForeground
              font.family: theme.fontFamily
              font.pixelSize: theme.fontSize + 1
              font.bold: true
            }
          }
          MouseArea {
            anchors.fill: parent
            cursorShape: Qt.PointingHandCursor
            onClicked: {
              root.zoneChosen("metrics")
              root.overviewChosen()
            }
          }
        }

        Repeater {
          model: root.metrics
          delegate: Column {
            required property var modelData
            required property int index
            width: navCol.width
            spacing: 2

            Text {
              visible: index === 0 || root.metrics[index - 1].group !== modelData.group
              text: modelData.group === "vitals" ? "VITALS" : "ACTIVITY"
              color: theme.darkForeground
              font.family: theme.fontFamily
              font.pixelSize: theme.fontSize - 3
              font.bold: true
              font.letterSpacing: 1.2
              topPadding: 12
              bottomPadding: 2
              leftPadding: 22
            }

            Rectangle {
              readonly property bool active: root.page === "metric" && index === root.metricIndex
              readonly property color tint: root.metricColor(modelData.id)
              x: 10
              width: navCol.width - 10
              height: 32
              radius: 10
              color: active ? root.alpha(tint, 0.20) : (rowArea.containsMouse ? root.alpha(theme.selection, 0.8) : "transparent")
              border.width: active ? 1 : 0
              border.color: root.alpha(tint, 0.7)
              Rectangle {
                id: navDot
                anchors.left: parent.left
                anchors.leftMargin: 10
                anchors.verticalCenter: parent.verticalCenter
                width: 9
                height: 9
                radius: 5
                color: parent.tint
              }
              Text {
                anchors.left: navDot.right
                anchors.leftMargin: 10
                anchors.right: deltaChip.left
                anchors.rightMargin: 6
                anchors.verticalCenter: parent.verticalCenter
                text: modelData.name
                elide: Text.ElideRight
                color: parent.active ? theme.brightForeground : theme.foreground
                font.family: theme.fontFamily
                font.pixelSize: theme.fontSize - 1
                font.bold: parent.active
              }
              Rectangle {
                id: deltaChip
                anchors.right: parent.right
                anchors.rightMargin: 8
                anchors.verticalCenter: parent.verticalCenter
                width: deltaText.implicitWidth + 12
                height: 18
                radius: 9
                visible: modelData.delta !== "—"
                color: root.alpha(root.toneColor(modelData.tone), 0.16)
                Text {
                  id: deltaText
                  anchors.centerIn: parent
                  text: modelData.delta
                  color: root.toneColor(modelData.tone)
                  font.family: theme.fontFamily
                  font.pixelSize: theme.fontSize - 3
                  font.bold: true
                }
              }
              MouseArea {
                id: rowArea
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: {
                  root.zoneChosen("metrics")
                  root.metricChosen(index)
                }
              }
            }
          }
        }

        Text {
          text: "DOCUMENTS"
          color: theme.darkForeground
          font.family: theme.fontFamily
          font.pixelSize: theme.fontSize - 3
          font.bold: true
          font.letterSpacing: 1.2
          topPadding: 12
          bottomPadding: 2
          leftPadding: 22
        }

        Repeater {
          model: [
            { id: "xrays", label: "X-Rays", tint: "cyan" },
            { id: "labs", label: "Blood and Urine Tests", tint: "magenta" }
          ]
          delegate: Rectangle {
            required property var modelData
            readonly property bool active: root.gallery === modelData.id
            readonly property color tint: modelData.tint === "cyan" ? theme.brightCyan : theme.magenta
            x: 10
            width: navCol.width - 10
            height: 32
            radius: 10
            color: active ? root.alpha(tint, 0.20) : (docArea.containsMouse ? root.alpha(theme.selection, 0.8) : "transparent")
            border.width: active ? 1 : 0
            border.color: root.alpha(tint, 0.7)
            Rectangle {
              id: docDot
              anchors.left: parent.left
              anchors.leftMargin: 10
              anchors.verticalCenter: parent.verticalCenter
              width: 9
              height: 9
              radius: 2
              color: parent.tint
            }
            Text {
              anchors.left: docDot.right
              anchors.leftMargin: 10
              anchors.right: parent.right
              anchors.rightMargin: 8
              anchors.verticalCenter: parent.verticalCenter
              text: modelData.label
              elide: Text.ElideRight
              color: parent.active ? theme.brightForeground : theme.foreground
              font.family: theme.fontFamily
              font.pixelSize: theme.fontSize - 1
              font.bold: parent.active
            }
            MouseArea {
              id: docArea
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onClicked: root.sectionChosen(modelData.id)
            }
          }
        }
      }
    }

    Card {
      id: scoreCard
      theme: root.theme
      tint: theme.brightCyan
      glow: true
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.bottom: parent.bottom
      anchors.margins: 10
      height: 150
      title: "Health score"
      readonly property var result: root.score()
      Row {
        anchors.fill: parent
        spacing: 12
        Ring {
          width: 86
          height: 86
          anchors.verticalCenter: parent.verticalCenter
          value: scoreCard.result.value
          thickness: 9
          color: theme.brightCyan
          color2: theme.green
          track: root.alpha(theme.brightCyan, 0.14)
          label: root.hasDays ? Math.round(scoreCard.result.value * 100) + "%" : "—"
          fontFamily: theme.fontFamily
          fontSize: 18
          textColor: theme.brightForeground
        }
        Column {
          anchors.verticalCenter: parent.verticalCenter
          width: parent.width - 98
          spacing: 4
          Text {
            width: parent.width
            wrapMode: Text.Wrap
            text: scoreCard.result.label
            color: theme.foreground
            font.family: theme.fontFamily
            font.pixelSize: theme.fontSize - 1
          }
          Text {
            width: parent.width
            wrapMode: Text.Wrap
            text: root.view && root.view.label ? root.view.label : ""
            color: theme.darkForeground
            font.family: theme.fontFamily
            font.pixelSize: theme.fontSize - 2
          }
        }
      }
    }
  }

  // Main area
  Item {
    id: main
    anchors.top: parent.top
    anchors.bottom: parent.bottom
    anchors.left: nav.right
    anchors.right: parent.right
    anchors.margins: 14

    Row {
      id: toolbar
      anchors.top: parent.top
      anchors.left: parent.left
      spacing: 10
      height: 34

      Rectangle {
        height: 34
        width: rangeRow.implicitWidth + 8
        radius: 17
        color: theme.darkerBackground
        border.width: root.zone === "ranges" ? 2 : 1
        border.color: root.zone === "ranges" ? theme.accent : root.alpha(theme.accent, 0.18)
        Row {
          id: rangeRow
          anchors.centerIn: parent
          spacing: 2
          Repeater {
            model: root.rangeLabels
            delegate: Rectangle {
              id: rangeChip
              required property string modelData
              required property int index
              readonly property bool active: !root.customActive && index === root.rangeIndex
              width: chipText.implicitWidth + 22
              height: 26
              radius: 13
              gradient: Gradient {
                orientation: Gradient.Horizontal
                GradientStop { position: 0.0; color: rangeChip.active ? theme.accent : "transparent" }
                GradientStop { position: 1.0; color: rangeChip.active ? theme.magenta : "transparent" }
              }
              Text {
                id: chipText
                anchors.centerIn: parent
                text: rangeChip.modelData
                color: rangeChip.active ? theme.darkerBackground : theme.foreground
                font.family: theme.fontFamily
                font.pixelSize: theme.fontSize - 1
                font.bold: rangeChip.active
              }
              MouseArea {
                anchors.fill: parent
                cursorShape: Qt.PointingHandCursor
                onClicked: {
                  root.zoneChosen("ranges")
                  root.rangeChosen(index)
                }
              }
            }
          }
          Rectangle {
            visible: root.customActive
            width: customText.implicitWidth + 22
            height: 26
            radius: 13
            gradient: Gradient {
              orientation: Gradient.Horizontal
              GradientStop { position: 0.0; color: theme.accent }
              GradientStop { position: 1.0; color: theme.magenta }
            }
            Text {
              id: customText
              anchors.centerIn: parent
              text: "Custom"
              color: theme.darkerBackground
              font.family: theme.fontFamily
              font.pixelSize: theme.fontSize - 1
              font.bold: true
            }
          }
        }
      }

      Rectangle {
        visible: root.classifying
        height: 34
        width: liveRow.implicitWidth + 24
        radius: 17
        color: root.alpha(theme.green, 0.14)
        border.width: 1
        border.color: root.alpha(theme.green, 0.5)
        Row {
          id: liveRow
          anchors.centerIn: parent
          spacing: 8
          Rectangle {
            width: 8
            height: 8
            radius: 4
            color: theme.green
            anchors.verticalCenter: parent.verticalCenter
            SequentialAnimation on opacity {
              running: root.classifying
              loops: Animation.Infinite
              NumberAnimation { from: 1; to: 0.25; duration: 600 }
              NumberAnimation { from: 0.25; to: 1; duration: 600 }
            }
          }
          Text {
            text: "Agent classifying"
            color: theme.green
            font.family: theme.fontFamily
            font.pixelSize: theme.fontSize - 1
            anchors.verticalCenter: parent.verticalCenter
          }
        }
      }
    }

    Column {
      id: notices
      anchors.top: toolbar.bottom
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.topMargin: (root.sample || root.errorMessage.length > 0) ? 10 : 0
      spacing: 8

      Rectangle {
        visible: root.sample
        width: parent.width
        height: sampleText.implicitHeight + 16
        radius: 12
        color: root.alpha(theme.yellow, 0.10)
        border.color: root.alpha(theme.yellow, 0.6)
        border.width: 1
        Text {
          id: sampleText
          x: 12
          y: 8
          width: parent.width - 24
          wrapMode: Text.Wrap
          text: "Sample data. These numbers are invented so the window can be used before an Apple Health export is here. They are not a record of anyone's health."
          color: theme.yellow
          font.family: theme.fontFamily
          font.pixelSize: theme.fontSize - 1
        }
      }

      Rectangle {
        visible: root.errorMessage.length > 0
        width: parent.width
        height: errorText.implicitHeight + 16
        radius: 12
        color: root.alpha(theme.red, 0.10)
        border.color: root.alpha(theme.red, 0.6)
        border.width: 1
        Text {
          id: errorText
          x: 12
          y: 8
          width: parent.width - 24
          wrapMode: Text.Wrap
          text: root.errorMessage
          color: theme.red
          font.family: theme.fontFamily
          font.pixelSize: theme.fontSize - 1
        }
      }
    }

    Item {
      id: stage
      anchors.top: notices.bottom
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.bottom: parent.bottom
      anchors.topMargin: 12

      // Nothing to draw yet
      Card {
        visible: root.page !== "gallery" && !root.hasDays
        theme: root.theme
        tint: root.state === "error" ? theme.red : theme.accent
        glow: true
        anchors.centerIn: parent
        width: Math.min(parent.width, 520)
        height: 180
        Column {
          anchors.centerIn: parent
          width: parent.width
          spacing: 12
          Ring {
            anchors.horizontalCenter: parent.horizontalCenter
            width: 58
            height: 58
            value: root.state === "loading" ? 0.3 : 0
            thickness: 6
            color: theme.accent
            color2: theme.magenta
            track: root.alpha(theme.accent, 0.16)
            RotationAnimation on rotation {
              running: root.state === "loading"
              from: 0
              to: 360
              duration: 1100
              loops: Animation.Infinite
            }
          }
          Text {
            width: parent.width
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.Wrap
            text: {
              if (root.state === "loading") return "Opening saved health data…"
              if (root.state === "empty") return root.stateMessage.length > 0 ? root.stateMessage : "No days to chart yet."
              if (root.state === "error") return root.stateMessage.length > 0 ? root.stateMessage : "The last read failed before any days were indexed."
              return root.stateMessage
            }
            color: root.state === "error" ? theme.red : theme.foreground
            font.family: theme.fontFamily
            font.pixelSize: theme.fontSize
          }
        }
      }

      // Documents
      Card {
        visible: root.page === "gallery"
        anchors.fill: parent
        theme: root.theme
        tint: root.gallery === "xrays" ? theme.brightCyan : theme.magenta
        pad: 4
        Gallery {
          anchors.fill: parent
          theme: root.theme
          title: root.gallery === "xrays" ? "X-Rays" : "Blood and Urine Tests"
          files: root.gallery === "xrays" ? root.xrays : root.blood.concat(root.urine)
          focusId: root.focusId
          onFocusChosen: (id, kind) => root.documentChosen(id, kind)
          onDeleteChosen: (id, name) => root.fileDeleteChosen(id, name)
          onCloseRequested: root.galleryClosed()
        }
      }

      // Overview
      Flickable {
        id: overviewPage
        visible: root.page === "overview" && root.hasDays
        anchors.fill: parent
        contentWidth: width
        contentHeight: overviewCol.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds

        Column {
          id: overviewCol
          width: overviewPage.width
          spacing: 12
          readonly property real gap: 12
          readonly property real third: (width - gap * 2) / 3

          Row {
            spacing: overviewCol.gap

            // Hero
            Card {
              id: hero
              theme: root.theme
              tint: theme.accent
              glow: true
              width: overviewCol.third * 2 + overviewCol.gap
              height: 184
              Row {
                anchors.fill: parent
                spacing: 16
                Column {
                  width: parent.width * 0.58
                  spacing: 6
                  Row {
                    spacing: 6
                    Repeater {
                      model: ["Activity", "Sleep", "Vitals"]
                      delegate: Rectangle {
                        required property string modelData
                        required property int index
                        readonly property color tint: index === 0 ? theme.blue : index === 1 ? theme.magenta : theme.red
                        width: pillText.implicitWidth + 18
                        height: 20
                        radius: 10
                        color: root.alpha(tint, 0.18)
                        border.width: 1
                        border.color: root.alpha(tint, 0.55)
                        Text {
                          id: pillText
                          anchors.centerIn: parent
                          text: modelData
                          color: parent.tint
                          font.family: theme.fontFamily
                          font.pixelSize: theme.fontSize - 3
                          font.bold: true
                        }
                      }
                    }
                  }
                  Text {
                    width: parent.width
                    elide: Text.ElideRight
                    text: (root.view && root.view.label ? root.view.label : "Health") + " at a glance"
                    color: theme.brightForeground
                    font.family: theme.fontFamily
                    font.pixelSize: theme.fontSize + 9
                    font.bold: true
                  }
                  Text {
                    width: parent.width
                    elide: Text.ElideRight
                    text: root.rangeSpan()
                    color: theme.foreground
                    font.family: theme.fontFamily
                    font.pixelSize: theme.fontSize - 1
                  }
                  Item { width: 1; height: 4 }
                  Row {
                    spacing: 8
                    Repeater {
                      model: root.summary
                      delegate: Rectangle {
                        id: sumTile
                        required property var modelData
                        readonly property color tint: root.metricColor(modelData.id)
                        width: (hero.width * 0.58 - 24 - 32) / 4
                        height: 58
                        radius: 12
                        color: root.alpha(theme.darkerBackground, 0.7)
                        border.width: 1
                        border.color: root.alpha(tint, 0.4)
                        Column {
                          anchors.fill: parent
                          anchors.margins: 8
                          spacing: 1
                          Row {
                            spacing: 5
                            Rectangle { width: 6; height: 6; radius: 3; color: sumTile.tint; anchors.verticalCenter: parent.verticalCenter }
                            Text {
                              text: sumTile.modelData.label
                              width: sumTile.width - 28
                              elide: Text.ElideRight
                              color: theme.darkForeground
                              font.family: theme.fontFamily
                              font.pixelSize: theme.fontSize - 3
                            }
                          }
                          Text {
                            text: modelData.value
                            color: theme.brightForeground
                            font.family: theme.fontFamily
                            font.pixelSize: theme.fontSize + 2
                            font.bold: true
                          }
                          Text {
                            text: modelData.delta
                            color: root.toneColor(modelData.tone)
                            font.family: theme.fontFamily
                            font.pixelSize: theme.fontSize - 3
                            font.bold: true
                          }
                        }
                        MouseArea {
                          anchors.fill: parent
                          cursorShape: Qt.PointingHandCursor
                          onClicked: root.openMetric(modelData.id)
                        }
                      }
                    }
                  }
                }
                Rectangle {
                  width: parent.width * 0.42 - 16
                  height: parent.height
                  radius: 14
                  color: root.alpha(theme.darkerBackground, 0.6)
                  border.width: 1
                  border.color: root.alpha(theme.red, 0.3)
                  Text {
                    id: heartTitle
                    x: 12
                    y: 10
                    text: "Heart trend"
                    color: theme.foreground
                    font.family: theme.fontFamily
                    font.pixelSize: theme.fontSize - 2
                    font.bold: true
                  }
                  Text {
                    anchors.right: parent.right
                    anchors.rightMargin: 12
                    y: 10
                    text: root.fmt(root.lastOf("heartRate"), 0) + " bpm"
                    color: theme.red
                    font.family: theme.fontFamily
                    font.pixelSize: theme.fontSize - 1
                    font.bold: true
                  }
                  Spark {
                    anchors.top: heartTitle.bottom
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.bottom: heartFoot.top
                    anchors.margins: 10
                    values: root.tail("heartRate", 30)
                    color: theme.red
                    color2: theme.magenta
                    fromZero: false
                    lineWidth: 2.5
                  }
                  Text {
                    id: heartFoot
                    anchors.bottom: parent.bottom
                    anchors.left: parent.left
                    anchors.margins: 10
                    text: "Avg " + root.fmt(root.avgOf("heartRate"), 0) + "   Resting " + root.fmt(root.avgOf("restingHr"), 0)
                    color: theme.darkForeground
                    font.family: theme.fontFamily
                    font.pixelSize: theme.fontSize - 2
                  }
                  MouseArea {
                    anchors.fill: parent
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.openMetric("heartRate")
                  }
                }
              }
            }

            // Goals
            Card {
              theme: root.theme
              tint: theme.green
              width: overviewCol.third
              height: 184
              title: "Daily goals"
              caption: "average per day"
              Row {
                anchors.fill: parent
                spacing: 12
                Ring {
                  id: stepRing
                  width: Math.min(110, parent.height)
                  height: width
                  anchors.verticalCenter: parent.verticalCenter
                  readonly property real avg: root.avgOf("steps") || 0
                  value: avg / 10000
                  thickness: 11
                  color: theme.green
                  color2: theme.brightCyan
                  track: root.alpha(theme.green, 0.14)
                  label: Math.round(Math.min(9.99, avg / 10000) * 100) + "%"
                  sublabel: "10k steps"
                  fontFamily: theme.fontFamily
                  fontSize: 20
                  textColor: theme.brightForeground
                  subColor: theme.darkForeground
                  MouseArea {
                    anchors.fill: parent
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.openMetric("steps")
                  }
                }
                Column {
                  anchors.verticalCenter: parent.verticalCenter
                  width: parent.width - stepRing.width - 12
                  spacing: 10
                  Repeater {
                    model: ["sleepHours", "exerciseMin", "activeKcal"]
                    delegate: Column {
                      id: goalRow
                      required property string modelData
                      readonly property color tint: root.metricColor(modelData)
                      readonly property real avg: root.avgOf(modelData) || 0
                      readonly property real goal: root.goalFor(modelData)
                      width: parent.width
                      spacing: 3
                      Row {
                        width: goalRow.width
                        Text {
                          width: goalRow.width * 0.55
                          elide: Text.ElideRight
                          text: root.metricById(goalRow.modelData) ? root.metricById(goalRow.modelData).name : goalRow.modelData
                          color: theme.darkForeground
                          font.family: theme.fontFamily
                          font.pixelSize: theme.fontSize - 3
                        }
                        Text {
                          width: goalRow.width * 0.45
                          horizontalAlignment: Text.AlignRight
                          text: root.fmt(goalRow.avg, root.digitsFor(goalRow.modelData)) + " / " + root.fmt(goalRow.goal, 0)
                          color: theme.brightForeground
                          font.family: theme.fontFamily
                          font.pixelSize: theme.fontSize - 2
                          font.bold: true
                        }
                      }
                      Rectangle {
                        width: goalRow.width
                        height: 6
                        radius: 3
                        color: root.alpha(goalRow.tint, 0.16)
                        Rectangle {
                          height: parent.height
                          radius: 3
                          width: goalRow.width * Math.max(0, Math.min(1, goalRow.goal > 0 ? goalRow.avg / goalRow.goal : 0))
                          gradient: Gradient {
                            orientation: Gradient.Horizontal
                            GradientStop { position: 0.0; color: root.alpha(goalRow.tint, 0.6) }
                            GradientStop { position: 1.0; color: goalRow.tint }
                          }
                        }
                      }
                    }
                  }
                }
              }
            }
          }

          Row {
            spacing: overviewCol.gap

            // Week
            Card {
              id: weekCard
              theme: root.theme
              tint: theme.blue
              focused: root.zone === "days"
              width: overviewCol.third
              height: 214
              title: "Last 7 days"
              caption: "steps · exercise · sleep"
              readonly property int first: Math.max(0, root.days.length - 7)
              readonly property var steps: root.tail("steps", 7)
              readonly property var exercise: root.tail("exerciseMin", 7)
              readonly property var sleep: root.tail("sleepHours", 7)
              function peak(list) {
                var hi = 0
                for (var i = 0; i < list.length; i++) if (list[i] !== null && list[i] !== undefined) hi = Math.max(hi, Number(list[i]))
                return hi || 1
              }
              Row {
                anchors.fill: parent
                spacing: 6
                Repeater {
                  model: Math.min(7, root.days.length)
                  delegate: Rectangle {
                    id: dayCol
                    required property int index
                    readonly property int dayPos: weekCard.first + index
                    readonly property bool active: root.dayIndex === dayPos
                    width: (weekCard.width - weekCard.pad * 2 - 36) / 7
                    height: parent.height
                    radius: 12
                    color: active ? root.alpha(theme.blue, 0.22) : root.alpha(theme.darkerBackground, 0.6)
                    border.width: active ? 1 : 0
                    border.color: theme.blue
                    Column {
                      anchors.top: parent.top
                      anchors.topMargin: 8
                      anchors.horizontalCenter: parent.horizontalCenter
                      spacing: 2
                      Text {
                        anchors.horizontalCenter: parent.horizontalCenter
                        text: root.weekday(root.days[dayCol.dayPos])
                        color: theme.darkForeground
                        font.family: theme.fontFamily
                        font.pixelSize: theme.fontSize - 3
                      }
                      Text {
                        anchors.horizontalCenter: parent.horizontalCenter
                        text: root.dateNumber(root.days[dayCol.dayPos])
                        color: theme.brightForeground
                        font.family: theme.fontFamily
                        font.pixelSize: theme.fontSize + 3
                        font.bold: true
                      }
                    }
                    Row {
                      anchors.bottom: parent.bottom
                      anchors.bottomMargin: 10
                      anchors.horizontalCenter: parent.horizontalCenter
                      height: 84
                      spacing: 3
                      Repeater {
                        model: 3
                        delegate: Rectangle {
                          id: weekBar
                          required property int index
                          readonly property var list: index === 0 ? weekCard.steps : index === 1 ? weekCard.exercise : weekCard.sleep
                          readonly property var raw: list[dayCol.index]
                          readonly property real share: (raw === null || raw === undefined) ? 0 : Number(raw) / weekCard.peak(list)
                          readonly property color tint: index === 0 ? theme.blue : index === 1 ? theme.green : theme.magenta
                          anchors.bottom: parent.bottom
                          width: 5
                          height: Math.max(3, 84 * share)
                          radius: 3
                          gradient: Gradient {
                            GradientStop { position: 0.0; color: weekBar.tint }
                            GradientStop { position: 1.0; color: root.alpha(weekBar.tint, 0.35) }
                          }
                        }
                      }
                    }
                    MouseArea {
                      anchors.fill: parent
                      cursorShape: Qt.PointingHandCursor
                      onClicked: {
                        root.zoneChosen("days")
                        root.dayChosen(dayCol.dayPos)
                      }
                    }
                  }
                }
              }
            }

            // Heart and steps
            Card {
              theme: root.theme
              tint: theme.brightCyan
              width: overviewCol.third
              height: 214
              title: "Heart and steps"
              caption: root.days.length ? root.dayName(root.days[root.days.length - 1]) : ""
              Column {
                anchors.fill: parent
                spacing: 6
                Row {
                  spacing: 8
                  Text {
                    text: root.fmt(root.lastOf("steps"), 0)
                    color: theme.brightForeground
                    font.family: theme.fontFamily
                    font.pixelSize: theme.fontSize + 12
                    font.bold: true
                  }
                  Column {
                    anchors.bottom: parent.bottom
                    anchors.bottomMargin: 4
                    Text {
                      text: "steps"
                      color: theme.foreground
                      font.family: theme.fontFamily
                      font.pixelSize: theme.fontSize - 2
                    }
                    Text {
                      text: Math.round(((root.lastOf("steps") || 0) / 10000) * 100) + "% of goal"
                      color: theme.brightCyan
                      font.family: theme.fontFamily
                      font.pixelSize: theme.fontSize - 3
                      font.bold: true
                    }
                  }
                }
                Item {
                  width: parent.width
                  height: parent.height - 76
                  Spark {
                    anchors.fill: parent
                    values: root.tail("steps", 30)
                    color: theme.brightCyan
                    color2: theme.blue
                    lineWidth: 2
                  }
                  Spark {
                    anchors.fill: parent
                    values: root.tail("heartRate", 30)
                    color: theme.red
                    color2: theme.orange
                    area: false
                    fromZero: false
                    lineWidth: 1.6
                  }
                  MouseArea {
                    anchors.fill: parent
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.openMetric("steps")
                  }
                }
                Row {
                  width: parent.width
                  spacing: 6
                  Repeater {
                    model: [
                      { id: "heartRate", label: "Avg HR" },
                      { id: "restingHr", label: "Resting" },
                      { id: "hrv", label: "HRV" }
                    ]
                    delegate: Rectangle {
                      required property var modelData
                      width: (parent.width - 12) / 3
                      height: 30
                      radius: 8
                      color: root.alpha(root.metricColor(modelData.id), 0.12)
                      Text {
                        anchors.centerIn: parent
                        text: modelData.label + " " + root.fmt(root.avgOf(modelData.id), 0)
                        color: root.metricColor(modelData.id)
                        font.family: theme.fontFamily
                        font.pixelSize: theme.fontSize - 3
                        font.bold: true
                      }
                      MouseArea {
                        anchors.fill: parent
                        cursorShape: Qt.PointingHandCursor
                        onClicked: root.openMetric(modelData.id)
                      }
                    }
                  }
                }
              }
            }

            // Sleep
            Card {
              theme: root.theme
              tint: theme.magenta
              width: overviewCol.third
              height: 214
              title: "Sleep"
              caption: "7–9 h band"
              Column {
                anchors.fill: parent
                spacing: 6
                Row {
                  spacing: 8
                  Text {
                    text: root.fmt(root.avgOf("sleepHours"), 1)
                    color: theme.brightForeground
                    font.family: theme.fontFamily
                    font.pixelSize: theme.fontSize + 12
                    font.bold: true
                  }
                  Text {
                    anchors.bottom: parent.bottom
                    anchors.bottomMargin: 6
                    text: "h average"
                    color: theme.foreground
                    font.family: theme.fontFamily
                    font.pixelSize: theme.fontSize - 2
                  }
                }
                Spark {
                  width: parent.width
                  height: parent.height - 76
                  values: root.tail("sleepHours", 14)
                  color: theme.magenta
                  color2: theme.blue
                  bars: true
                  band: [7, 9]
                  bandColor: root.alpha(theme.green, 0.12)
                  MouseArea {
                    anchors.fill: parent
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.openMetric("sleepHours")
                  }
                }
                Row {
                  width: parent.width
                  spacing: 6
                  Repeater {
                    model: [
                      { label: "Low", value: root.metricById("sleepHours") ? root.metricById("sleepHours").minText : "—" },
                      { label: "High", value: root.metricById("sleepHours") ? root.metricById("sleepHours").maxText : "—" },
                      { label: "Last", value: root.fmt(root.lastOf("sleepHours"), 1) }
                    ]
                    delegate: Rectangle {
                      required property var modelData
                      width: (parent.width - 12) / 3
                      height: 30
                      radius: 8
                      color: root.alpha(theme.magenta, 0.12)
                      Text {
                        anchors.centerIn: parent
                        text: modelData.label + " " + modelData.value
                        color: theme.magenta
                        font.family: theme.fontFamily
                        font.pixelSize: theme.fontSize - 3
                        font.bold: true
                      }
                    }
                  }
                }
              }
            }
          }

          Row {
            spacing: overviewCol.gap

            // Vitals
            Card {
              id: vitalsCard
              theme: root.theme
              tint: theme.red
              width: overviewCol.third
              height: 222
              title: "Vitals"
              caption: root.view && root.view.label ? root.view.label : ""
              Column {
                anchors.fill: parent
                spacing: 7
                Repeater {
                  model: ["restingHr", "hrv", "spo2", "respiratory", "weightKg"]
                  delegate: Item {
                    id: vitalRow
                    required property string modelData
                    readonly property var info: root.metricById(modelData)
                    readonly property color tint: root.metricColor(modelData)
                    readonly property real share: info && info.seriesMax > 0 ? (root.avgOf(modelData) || 0) / info.seriesMax : 0
                    width: parent.width
                    height: 28
                    Rectangle {
                      id: vDot
                      width: 8
                      height: 8
                      radius: 4
                      color: vitalRow.tint
                      y: 3
                    }
                    Text {
                      anchors.left: vDot.right
                      anchors.leftMargin: 8
                      width: vitalRow.width * 0.5
                      elide: Text.ElideRight
                      text: vitalRow.info ? vitalRow.info.name : vitalRow.modelData
                      color: theme.foreground
                      font.family: theme.fontFamily
                      font.pixelSize: theme.fontSize - 2
                    }
                    Text {
                      anchors.right: vDelta.left
                      anchors.rightMargin: 8
                      text: vitalRow.info ? vitalRow.info.value + (vitalRow.info.unit ? " " + vitalRow.info.unit : "") : "—"
                      color: theme.brightForeground
                      font.family: theme.fontFamily
                      font.pixelSize: theme.fontSize - 1
                      font.bold: true
                    }
                    Text {
                      id: vDelta
                      anchors.right: parent.right
                      width: 44
                      horizontalAlignment: Text.AlignRight
                      text: vitalRow.info ? vitalRow.info.delta : ""
                      color: root.toneColor(vitalRow.info ? vitalRow.info.tone : "")
                      font.family: theme.fontFamily
                      font.pixelSize: theme.fontSize - 3
                      font.bold: true
                    }
                    Rectangle {
                      anchors.bottom: parent.bottom
                      width: vitalRow.width
                      height: 5
                      radius: 3
                      color: root.alpha(vitalRow.tint, 0.14)
                      Rectangle {
                        height: parent.height
                        radius: 3
                        width: vitalRow.width * Math.max(0.02, Math.min(1, vitalRow.share))
                        gradient: Gradient {
                          orientation: Gradient.Horizontal
                          GradientStop { position: 0.0; color: root.alpha(vitalRow.tint, 0.45) }
                          GradientStop { position: 1.0; color: vitalRow.tint }
                        }
                      }
                    }
                    MouseArea {
                      anchors.fill: parent
                      cursorShape: Qt.PointingHandCursor
                      onClicked: root.openMetric(vitalRow.modelData)
                    }
                  }
                }
              }
            }

            // Agent flags
            Card {
              id: flagsCard
              theme: root.theme
              tint: theme.orange
              width: overviewCol.third
              height: 222
              title: "Agent flags"
              caption: root.classifying ? "classifying…" : root.agentLabel
              captionColor: root.classifying ? theme.green : theme.darkForeground
              readonly property var counts: root.allLevelCounts()
              readonly property var flagged: root.flaggedMetrics()
              Column {
                anchors.fill: parent
                spacing: 10
                Rectangle {
                  width: parent.width
                  height: 12
                  radius: 6
                  clip: true
                  color: root.alpha(theme.muted, 0.4)
                  Row {
                    anchors.fill: parent
                    Repeater {
                      model: ["normal", "mild", "alert", "severe"]
                      delegate: Rectangle {
                        required property string modelData
                        height: parent.height
                        width: flagsCard.counts.total > 0 ? parent.width * flagsCard.counts[modelData] / flagsCard.counts.total : 0
                        color: root.levelColor(modelData)
                      }
                    }
                  }
                }
                Grid {
                  columns: 2
                  columnSpacing: 10
                  rowSpacing: 6
                  width: parent.width
                  Repeater {
                    model: [
                      { key: "normal", label: "In range" },
                      { key: "mild", label: "Mild" },
                      { key: "alert", label: "Alert" },
                      { key: "severe", label: "Severe" }
                    ]
                    delegate: Row {
                      required property var modelData
                      width: (flagsCard.width - flagsCard.pad * 2 - 10) / 2
                      spacing: 6
                      Rectangle { width: 10; height: 10; radius: 3; color: root.levelColor(modelData.key); anchors.verticalCenter: parent.verticalCenter }
                      Text {
                        text: modelData.label
                        color: theme.foreground
                        font.family: theme.fontFamily
                        font.pixelSize: theme.fontSize - 2
                        anchors.verticalCenter: parent.verticalCenter
                      }
                      Text {
                        text: String(flagsCard.counts[modelData.key])
                        color: theme.brightForeground
                        font.family: theme.fontFamily
                        font.pixelSize: theme.fontSize - 1
                        font.bold: true
                        anchors.verticalCenter: parent.verticalCenter
                      }
                    }
                  }
                }
                Text {
                  visible: flagsCard.flagged.length === 0
                  width: parent.width
                  wrapMode: Text.Wrap
                  text: flagsCard.counts.total > 0 ? "Every classified day is in range." : "Open a metric and the agent classifies the days you are looking at."
                  color: theme.darkForeground
                  font.family: theme.fontFamily
                  font.pixelSize: theme.fontSize - 2
                }
                Repeater {
                  model: flagsCard.flagged
                  delegate: Rectangle {
                    required property var modelData
                    width: flagsCard.width - flagsCard.pad * 2
                    height: 26
                    radius: 8
                    color: root.alpha(root.levelColor(modelData.severe > 0 ? "severe" : modelData.alert > 0 ? "alert" : "mild"), 0.14)
                    Text {
                      anchors.left: parent.left
                      anchors.leftMargin: 10
                      anchors.verticalCenter: parent.verticalCenter
                      text: modelData.name
                      color: theme.brightForeground
                      font.family: theme.fontFamily
                      font.pixelSize: theme.fontSize - 2
                    }
                    Text {
                      anchors.right: parent.right
                      anchors.rightMargin: 10
                      anchors.verticalCenter: parent.verticalCenter
                      text: (modelData.severe > 0 ? modelData.severe + " severe  " : "") + (modelData.alert > 0 ? modelData.alert + " alert  " : "") + (modelData.mild > 0 ? modelData.mild + " mild" : "")
                      color: root.levelColor(modelData.severe > 0 ? "severe" : modelData.alert > 0 ? "alert" : "mild")
                      font.family: theme.fontFamily
                      font.pixelSize: theme.fontSize - 3
                      font.bold: true
                    }
                    MouseArea {
                      anchors.fill: parent
                      cursorShape: Qt.PointingHandCursor
                      onClicked: {
                        root.zoneChosen("metrics")
                        root.metricChosen(modelData.index)
                      }
                    }
                  }
                }
              }
            }

            // Documents
            Card {
              theme: root.theme
              tint: theme.brightCyan
              width: overviewCol.third
              height: 222
              title: "Records"
              caption: "X-rays and lab tests"
              Row {
                anchors.fill: parent
                spacing: 10
                Repeater {
                  model: [
                    { id: "xrays", label: "X-Rays", count: root.xrays.length, tint: "cyan" },
                    { id: "labs", label: "Lab tests", count: root.blood.length + root.urine.length, tint: "magenta" }
                  ]
                  delegate: Rectangle {
                    id: recordTile
                    required property var modelData
                    readonly property color tint: modelData.tint === "cyan" ? theme.brightCyan : theme.magenta
                    width: (parent.width - 10) / 2
                    height: parent.height
                    radius: 14
                    border.width: 1
                    border.color: root.alpha(tint, 0.45)
                    gradient: Gradient {
                      GradientStop { position: 0.0; color: root.alpha(recordTile.tint, 0.28) }
                      GradientStop { position: 1.0; color: root.alpha(recordTile.tint, 0.04) }
                    }
                    Column {
                      anchors.centerIn: parent
                      spacing: 6
                      Text {
                        anchors.horizontalCenter: parent.horizontalCenter
                        text: String(recordTile.modelData.count)
                        color: theme.brightForeground
                        font.family: theme.fontFamily
                        font.pixelSize: theme.fontSize + 18
                        font.bold: true
                      }
                      Text {
                        anchors.horizontalCenter: parent.horizontalCenter
                        text: recordTile.modelData.label
                        color: recordTile.tint
                        font.family: theme.fontFamily
                        font.pixelSize: theme.fontSize - 1
                        font.bold: true
                      }
                      Text {
                        anchors.horizontalCenter: parent.horizontalCenter
                        text: modelData.count === 1 ? "file" : "files"
                        color: theme.darkForeground
                        font.family: theme.fontFamily
                        font.pixelSize: theme.fontSize - 3
                      }
                    }
                    MouseArea {
                      anchors.fill: parent
                      cursorShape: Qt.PointingHandCursor
                      onClicked: root.sectionChosen(modelData.id)
                    }
                  }
                }
              }
            }
          }
        }
      }

      // One metric
      Item {
        id: metricPage
        visible: root.page === "metric" && root.hasDays
        anchors.fill: parent

        readonly property var counts: root.levelCounts(root.metric)
        readonly property var nums: root.numbers(root.metric, 0)
        readonly property real low: nums.length ? Math.min.apply(null, nums) : 0
        readonly property real high: nums.length ? Math.max.apply(null, nums) : 0
        readonly property real average: root.mean(nums) || 0

        Card {
          id: metricHero
          theme: root.theme
          tint: root.metricTint
          glow: true
          anchors.top: parent.top
          anchors.left: parent.left
          anchors.right: parent.right
          height: 150
          Row {
            anchors.fill: parent
            spacing: 18
            Column {
              width: parent.width - heroValue.width - heroRing.width - 36
              spacing: 5
              Rectangle {
                width: groupText.implicitWidth + 18
                height: 20
                radius: 10
                color: root.alpha(root.metricTint, 0.2)
                border.width: 1
                border.color: root.alpha(root.metricTint, 0.6)
                Text {
                  id: groupText
                  anchors.centerIn: parent
                  text: root.metric && root.metric.group === "vitals" ? "Vitals" : "Activity"
                  color: root.metricTint
                  font.family: theme.fontFamily
                  font.pixelSize: theme.fontSize - 3
                  font.bold: true
                }
              }
              Text {
                width: parent.width
                elide: Text.ElideRight
                text: root.metric ? root.metric.name : "Health"
                color: theme.brightForeground
                font.family: theme.fontFamily
                font.pixelSize: theme.fontSize + 9
                font.bold: true
              }
              Text {
                width: parent.width
                elide: Text.ElideRight
                text: root.rangeSpan()
                color: theme.foreground
                font.family: theme.fontFamily
                font.pixelSize: theme.fontSize - 1
              }
              Text {
                width: parent.width
                wrapMode: Text.Wrap
                maximumLineCount: 2
                elide: Text.ElideRight
                text: root.metric ? root.metric.trend : ""
                color: theme.darkForeground
                font.family: theme.fontFamily
                font.pixelSize: theme.fontSize - 2
              }
            }
            Column {
              id: heroValue
              anchors.verticalCenter: parent.verticalCenter
              width: 190
              spacing: 2
              Text {
                text: root.metric ? root.metric.aggregate : ""
                color: theme.darkForeground
                font.family: theme.fontFamily
                font.pixelSize: theme.fontSize - 2
              }
              Row {
                spacing: 6
                Text {
                  text: root.metric ? root.metric.value : "—"
                  color: theme.brightForeground
                  font.family: theme.fontFamily
                  font.pixelSize: theme.fontSize + 16
                  font.bold: true
                }
                Text {
                  anchors.bottom: parent.bottom
                  anchors.bottomMargin: 6
                  text: root.metric && root.metric.unit ? root.metric.unit : ""
                  color: root.metricTint
                  font.family: theme.fontFamily
                  font.pixelSize: theme.fontSize
                  font.bold: true
                }
              }
              Rectangle {
                visible: root.metric && root.metric.delta !== "—"
                width: heroDelta.implicitWidth + 16
                height: 22
                radius: 11
                color: root.alpha(root.toneColor(root.metric ? root.metric.tone : ""), 0.16)
                Text {
                  id: heroDelta
                  anchors.centerIn: parent
                  text: (root.metric ? root.metric.delta : "") + " vs previous"
                  color: root.toneColor(root.metric ? root.metric.tone : "")
                  font.family: theme.fontFamily
                  font.pixelSize: theme.fontSize - 3
                  font.bold: true
                }
              }
            }
            Ring {
              id: heroRing
              anchors.verticalCenter: parent.verticalCenter
              width: 112
              height: 112
              readonly property real goal: root.metric ? root.goalFor(root.metric.id) : 0
              value: metricPage.counts.total > 0
                     ? metricPage.counts.normal / metricPage.counts.total
                     : (goal > 0 ? metricPage.average / goal : (metricPage.high > 0 ? metricPage.average / metricPage.high : 0))
              label: Math.round(Math.min(9.99, value) * 100) + "%"
              sublabel: metricPage.counts.total > 0 ? "in range" : (goal > 0 ? "of goal" : "of peak")
              thickness: 11
              color: root.metricTint
              color2: Qt.lighter(root.metricTint, 1.3)
              track: root.alpha(root.metricTint, 0.15)
              fontFamily: theme.fontFamily
              fontSize: 20
              textColor: theme.brightForeground
              subColor: theme.darkForeground
            }
          }
        }

        Card {
          id: chartCard
          theme: root.theme
          tint: root.metricTint
          focused: root.zone === "days"
          anchors.top: metricHero.bottom
          anchors.bottom: statRow.top
          anchors.left: parent.left
          anchors.right: parent.right
          anchors.topMargin: 12
          anchors.bottomMargin: 12
          title: "Daily " + (root.metric ? root.metric.name.toLowerCase() : "values")
          caption: {
            var day = root.days.length > root.dayIndex ? root.dayName(root.days[root.dayIndex]) : ""
            var value = (root.metric && root.metric.seriesText && root.dayIndex < root.metric.seriesText.length)
                        ? root.metric.seriesText[root.dayIndex] + (root.metric.unit ? " " + root.metric.unit : "")
                        : ""
            return day + (value ? "  ·  " + value : "")
          }
          captionColor: theme.brightForeground

          Item {
            id: chartBox
            anchors.top: parent.top
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.bottom: chartFoot.top
            anchors.bottomMargin: 6
            visible: root.series.length > 0
            readonly property string axisUnit: {
              if (!root.metric) return ""
              if (root.metric.unit) return root.metric.unit
              return root.metric.id === "steps" ? "steps" : ""
            }
            readonly property var yScale: root.axisScale(root.metric && root.metric.seriesMax ? root.metric.seriesMax : 0)
            readonly property real yCeiling: yScale.ceiling
            readonly property var yTicks: yScale.ticks
            readonly property string tickKey: {
              var ticks = yTicks
              var parts = []
              for (var i = 0; i < ticks.length; i++) parts.push(ticks[i])
              return parts.join(",")
            }
            readonly property real axisInset: Math.max(8, theme.fontSize * 0.55)

            Text {
              id: axisSizer
              visible: false
              font.family: theme.fontFamily
              font.pixelSize: theme.fontSize - 2
              text: {
                var widest = ""
                var ticks = chartBox.yTicks
                for (var i = 0; i < ticks.length; i++) {
                  var label = root.formatAxis(ticks[i])
                  if (i === ticks.length - 1 && chartBox.axisUnit) label += " " + chartBox.axisUnit
                  if (label.length > widest.length) widest = label
                }
                return widest
              }
            }

            Item {
              id: yAxis
              anchors.left: parent.left
              anchors.top: parent.top
              anchors.bottom: parent.bottom
              width: Math.max(44, axisSizer.implicitWidth + 8)

              Repeater {
                model: chartBox.yTicks
                delegate: Text {
                  required property var modelData
                  required property int index
                  width: yAxis.width
                  horizontalAlignment: Text.AlignRight
                  text: root.formatAxis(modelData) + (index === chartBox.yTicks.length - 1 && chartBox.axisUnit ? " " + chartBox.axisUnit : "")
                  color: theme.darkForeground
                  font.family: theme.fontFamily
                  font.pixelSize: theme.fontSize - 2
                  y: {
                    var ceiling = chartBox.yCeiling
                    var inset = chartBox.axisInset
                    var span = Math.max(1, yAxis.height - inset * 2)
                    var grid = (yAxis.height - inset) - (ceiling > 0 ? (Number(modelData) / ceiling) * span : 0)
                    return grid - height / 2
                  }
                }
              }
            }

            Canvas {
              id: chartCanvas
              anchors.left: yAxis.right
              anchors.leftMargin: 10
              anchors.top: parent.top
              anchors.right: parent.right
              anchors.bottom: parent.bottom
              property var plotted: root.series
              property string levelKey: {
                var rows = (root.metric && root.metric.seriesLevel) ? root.metric.seriesLevel : []
                var parts = []
                for (var n = 0; n < rows.length; n++) parts.push(rows[n] || "")
                return parts.join("\n")
              }
              property var barColors: root.severityColors
              property color tint: root.metricTint
              property int focusDay: root.dayIndex
              property int dragLo: root.dragAnchor
              property int dragHi: root.dragEnd
              property real ceiling: chartBox.yCeiling
              property string tickKey: chartBox.tickKey
              property real axisInset: chartBox.axisInset
              onPlottedChanged: requestPaint()
              onLevelKeyChanged: requestPaint()
              onBarColorsChanged: requestPaint()
              onTintChanged: requestPaint()
              onFocusDayChanged: requestPaint()
              onDragLoChanged: requestPaint()
              onDragHiChanged: requestPaint()
              onCeilingChanged: requestPaint()
              onTickKeyChanged: requestPaint()
              onAxisInsetChanged: requestPaint()
              onWidthChanged: requestPaint()
              onHeightChanged: requestPaint()
              onPaint: {
                var ctx = getContext("2d")
                ctx.clearRect(0, 0, width, height)
                var series = plotted
                var n = series ? series.length : 0
                if (n === 0 || width <= 0 || height <= 0) return
                var slot = width / n
                var barW = Math.max(1, slot > 3 ? slot * 0.72 : slot)
                var maxV = ceiling
                var inset = axisInset
                var span = Math.max(1, height - inset * 2)
                var base = height - inset
                var lo = dragLo
                var hi = dragHi
                if (lo > hi) { var swap = lo; lo = hi; hi = swap }
                var dragging = lo >= 0 && hi >= 0 && lo !== hi
                if (dragging) {
                  ctx.fillStyle = root.alpha(tint, 0.14)
                  ctx.fillRect(lo * slot, 0, (hi - lo + 1) * slot, height)
                } else if (focusDay >= 0 && focusDay < n) {
                  ctx.fillStyle = root.alpha(tint, 0.14)
                  ctx.fillRect(focusDay * slot, 0, Math.max(slot, 1), height)
                }
                var ticks = tickKey.length ? tickKey.split(",") : []
                ctx.strokeStyle = root.alpha(theme.foreground, 0.08)
                ctx.lineWidth = 1
                for (var t = 0; t < ticks.length; t++) {
                  var tick = Number(ticks[t])
                  var gy = Math.round(base - (maxV > 0 ? (tick / maxV) * span : 0)) + 0.5
                  ctx.beginPath()
                  ctx.moveTo(0, gy)
                  ctx.lineTo(width, gy)
                  ctx.stroke()
                }
                ctx.strokeStyle = root.alpha(theme.foreground, 0.18)
                ctx.beginPath()
                ctx.moveTo(0.5, inset)
                ctx.lineTo(0.5, base)
                ctx.stroke()
                var colors = barColors || {}
                var levels = levelKey.length ? levelKey.split("\n") : []
                for (var i = 0; i < n; i++) {
                  var value = series[i]
                  if (value === null || value === undefined || maxV <= 0) continue
                  var h = Math.max(2, (Number(value) / maxV) * span)
                  var level = i < levels.length ? levels[i] : ""
                  var paint = tint
                  if ((level === "severe" || level === "alert" || level === "mild" || level === "normal") && colors[level]) paint = colors[level]
                  var x = i * slot + Math.max(0, (slot - barW) / 2)
                  var y = base - h
                  var g = ctx.createLinearGradient(0, y, 0, base)
                  g.addColorStop(0, level ? paint : root.alpha(paint, 0.95))
                  g.addColorStop(1, root.alpha(paint, level ? 0.45 : 0.22))
                  ctx.fillStyle = g
                  var r = Math.min(barW / 2, 5)
                  ctx.beginPath()
                  ctx.moveTo(x, base)
                  ctx.lineTo(x, y + r)
                  ctx.arcTo(x, y, x + r, y, r)
                  ctx.lineTo(x + barW - r, y)
                  ctx.arcTo(x + barW, y, x + barW, y + r, r)
                  ctx.lineTo(x + barW, base)
                  ctx.closePath()
                  ctx.fill()
                  if (i === focusDay && !dragging) {
                    ctx.strokeStyle = theme.brightForeground
                    ctx.lineWidth = 1.5
                    ctx.stroke()
                  }
                }
              }
              MouseArea {
                id: chartDrag
                anchors.fill: parent
                hoverEnabled: true
                preventStealing: true
                cursorShape: Qt.SizeHorCursor
                property int pressIndex: -1
                onPressed: mouse => {
                  pressIndex = root.dayAt(mouse.x, width)
                  root.dragAnchor = pressIndex
                  root.dragEnd = pressIndex
                }
                onPositionChanged: mouse => {
                  if (pressIndex < 0) return
                  root.dragEnd = root.dayAt(mouse.x, width)
                }
                onReleased: mouse => {
                  var end = root.dayAt(mouse.x, width)
                  var start = pressIndex
                  pressIndex = -1
                  if (start < 0 || end < 0) return
                  if (start === end) {
                    root.dragAnchor = -1
                    root.dragEnd = -1
                    root.zoneChosen("days")
                    root.dayChosen(start)
                    return
                  }
                  var lo = Math.min(start, end)
                  var hi = Math.max(start, end)
                  root.customRangeChosen(root.days[lo], root.days[hi])
                }
                onCanceled: {
                  pressIndex = -1
                  root.dragAnchor = -1
                  root.dragEnd = -1
                }
              }
            }
          }

          Column {
            id: chartFoot
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.bottom: parent.bottom
            spacing: 8

            Row {
              width: parent.width
              anchors.left: parent.left
              anchors.leftMargin: yAxis.width + 10
              Text {
                width: (chartFoot.width - yAxis.width - 10) / 3
                text: root.dayName(root.days[0])
                color: theme.darkForeground
                font.family: theme.fontFamily
                font.pixelSize: theme.fontSize - 2
              }
              Text {
                width: (chartFoot.width - yAxis.width - 10) / 3
                horizontalAlignment: Text.AlignHCenter
                text: root.days.length > 2 ? root.dayName(root.days[Math.floor(root.days.length / 2)]) : ""
                color: theme.darkForeground
                font.family: theme.fontFamily
                font.pixelSize: theme.fontSize - 2
              }
              Text {
                width: (chartFoot.width - yAxis.width - 10) / 3
                horizontalAlignment: Text.AlignRight
                text: root.dayName(root.days[root.days.length - 1])
                color: theme.darkForeground
                font.family: theme.fontFamily
                font.pixelSize: theme.fontSize - 2
              }
            }

            Row {
              spacing: 14
              Repeater {
                model: [
                  { key: "normal", label: "In range" },
                  { key: "mild", label: "Mild" },
                  { key: "alert", label: "Alert" },
                  { key: "severe", label: "Severe" },
                  { key: "", label: "Waiting for the agent" }
                ]
                delegate: Row {
                  required property var modelData
                  spacing: 6
                  Rectangle {
                    width: 10
                    height: 10
                    radius: 3
                    anchors.verticalCenter: parent.verticalCenter
                    color: modelData.key ? root.levelColor(modelData.key) : root.metricTint
                    opacity: modelData.key ? 1 : 0.7
                  }
                  Text {
                    text: modelData.label
                    color: theme.darkForeground
                    font.family: theme.fontFamily
                    font.pixelSize: theme.fontSize - 2
                    anchors.verticalCenter: parent.verticalCenter
                  }
                }
              }
            }
          }
        }

        Row {
          id: statRow
          anchors.left: parent.left
          anchors.right: parent.right
          anchors.bottom: parent.bottom
          height: 92
          spacing: 12
          Repeater {
            model: [
              { label: "Low", tint: "cyan", kind: "low" },
              { label: "Average", tint: "metric", kind: "avg" },
              { label: "High", tint: "orange", kind: "high" },
              { label: "Selected day", tint: "magenta", kind: "day" }
            ]
            delegate: Card {
              id: statCard
              required property var modelData
              theme: root.theme
              tint: modelData.tint === "cyan" ? theme.brightCyan : modelData.tint === "orange" ? theme.orange : modelData.tint === "magenta" ? theme.magenta : root.metricTint
              width: (statRow.width - 36) / 4
              height: statRow.height
              pad: 12
              readonly property real raw: {
                if (modelData.kind === "low") return metricPage.low
                if (modelData.kind === "high") return metricPage.high
                if (modelData.kind === "avg") return metricPage.average
                var v = root.series[root.dayIndex]
                return v === null || v === undefined ? 0 : Number(v)
              }
              readonly property string shown: {
                if (!root.metric) return "—"
                if (modelData.kind === "low") return root.metric.minText
                if (modelData.kind === "high") return root.metric.maxText
                if (modelData.kind === "avg") return root.metric.avgText
                return (root.metric.seriesText && root.dayIndex < root.metric.seriesText.length) ? root.metric.seriesText[root.dayIndex] : "—"
              }
              Column {
                anchors.fill: parent
                spacing: 4
                Text {
                  text: modelData.label
                  color: theme.darkForeground
                  font.family: theme.fontFamily
                  font.pixelSize: theme.fontSize - 2
                }
                Row {
                  spacing: 5
                  Text {
                    text: statCard.shown
                    color: theme.brightForeground
                    font.family: theme.fontFamily
                    font.pixelSize: theme.fontSize + 6
                    font.bold: true
                  }
                  Text {
                    anchors.bottom: parent.bottom
                    anchors.bottomMargin: 3
                    text: root.metric && root.metric.unit ? root.metric.unit : ""
                    color: theme.darkForeground
                    font.family: theme.fontFamily
                    font.pixelSize: theme.fontSize - 2
                  }
                }
                Rectangle {
                  width: parent.width
                  height: 6
                  radius: 3
                  color: root.alpha(statCard.tint, 0.15)
                  Rectangle {
                    height: parent.height
                    radius: 3
                    width: parent.width * Math.max(0.02, Math.min(1, metricPage.high > 0 ? statCard.raw / metricPage.high : 0))
                    color: statCard.tint
                  }
                }
              }
            }
          }
        }
      }
    }
  }
}
