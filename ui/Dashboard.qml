import QtQuick

// Summary, activity, vitals, and the trend of the focused metric.
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
  property var xrays: []
  property var blood: []
  property var urine: []
  property string focusId: ""
  property var severityColors: ({})
  property bool classifying: false

  signal rangeChosen(int index)
  signal customRangeChosen(string start, string end)
  signal metricChosen(int index)
  signal dayChosen(int index)
  signal zoneChosen(string name)
  signal sectionChosen(string name)
  signal documentChosen(string id, string kind)
  signal galleryClosed()

  readonly property var metrics: (view && view.metrics) ? view.metrics : []
  readonly property var summary: (view && view.summary) ? view.summary : []
  readonly property var days: (view && view.days) ? view.days : []
  readonly property var metric: (metricIndex >= 0 && metricIndex < metrics.length) ? metrics[metricIndex] : null
  readonly property var series: (metric && metric.series) ? metric.series : []

  function dayName(iso) {
    if (!iso) return ""
    var p = String(iso).split("-")
    if (p.length < 3) return String(iso)
    var dt = new Date(Number(p[0]), Number(p[1]) - 1, Number(p[2]))
    var names = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
    var months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
    return names[dt.getDay()] + " " + dt.getDate() + " " + months[dt.getMonth()]
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

  onViewChanged: {
    dragAnchor = -1
    dragEnd = -1
  }

  Column {
    id: top
    anchors.top: parent.top
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.margins: theme.space(16)
    spacing: theme.space(12)

    Row {
      spacing: theme.space(8)
      Repeater {
        model: root.rangeLabels
        delegate: Rectangle {
          required property string modelData
          required property int index
          width: chip.implicitWidth + 22
          height: 28
          radius: 6
          color: !root.customActive && index === root.rangeIndex ? theme.selection : theme.darkBackground
          border.width: root.zone === "ranges" && !root.customActive && index === root.rangeIndex ? 2 : 1
          border.color: !root.customActive && index === root.rangeIndex ? theme.accent : theme.lighterBackground
          Text {
            id: chip
            anchors.centerIn: parent
            text: modelData
            color: !root.customActive && index === root.rangeIndex ? theme.brightForeground : theme.foreground
            font.family: theme.fontFamily
            font.pixelSize: theme.fontSize
            font.bold: !root.customActive && index === root.rangeIndex
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
        width: customChip.implicitWidth + 22
        height: 28
        radius: 6
        color: theme.selection
        border.width: 2
        border.color: theme.accent
        Text {
          id: customChip
          anchors.centerIn: parent
          text: "Custom"
          color: theme.brightForeground
          font.family: theme.fontFamily
          font.pixelSize: theme.fontSize
          font.bold: true
        }
      }
    }

    Rectangle {
      visible: root.sample
      width: top.width
      height: sampleText.implicitHeight + 16
      radius: 6
      color: theme.darkBackground
      border.color: theme.yellow
      border.width: 1
      Text {
        id: sampleText
        x: 8
        y: 8
        width: parent.width - 16
        wrapMode: Text.Wrap
        text: "Sample data. These numbers are invented so the window can be used before an Apple Health export is here. They are not a record of anyone's health."
        color: theme.yellow
        font.family: theme.fontFamily
        font.pixelSize: theme.fontSize - 1
      }
    }

    Rectangle {
      visible: root.errorMessage.length > 0
      width: top.width
      height: errorText.implicitHeight + 16
      radius: 6
      color: theme.darkBackground
      border.color: theme.red
      border.width: 1
      Text {
        id: errorText
        x: 8
        y: 8
        width: parent.width - 16
        wrapMode: Text.Wrap
        text: root.errorMessage
        color: theme.red
        font.family: theme.fontFamily
        font.pixelSize: theme.fontSize - 1
      }
    }

    Row {
      width: top.width
      spacing: theme.space(8)
      Repeater {
        model: root.summary
        delegate: Rectangle {
          required property var modelData
          width: Math.max(80, (top.width - theme.space(8) * 3) / 4)
          height: 78
          radius: 8
          color: theme.darkBackground
          border.width: root.metric && root.metric.id === modelData.id ? 2 : 1
          border.color: root.metric && root.metric.id === modelData.id ? theme.accent : theme.lighterBackground
          Column {
            anchors.fill: parent
            anchors.margins: 10
            spacing: 2
            Text {
              text: modelData.label
              color: theme.darkForeground
              font.family: theme.fontFamily
              font.pixelSize: theme.fontSize - 2
              elide: Text.ElideRight
              width: parent.width
            }
            Text {
              text: modelData.value
              color: theme.brightForeground
              font.family: theme.fontFamily
              font.pixelSize: theme.fontSize + 6
              font.bold: true
              elide: Text.ElideRight
              width: parent.width
            }
            Text {
              width: parent.width
              elide: Text.ElideRight
              text: modelData.unit + "  " + modelData.delta
              color: theme.tone(modelData.tone)
              font.family: theme.fontFamily
              font.pixelSize: theme.fontSize - 2
            }
          }
          MouseArea {
            anchors.fill: parent
            cursorShape: Qt.PointingHandCursor
            onClicked: {
              for (var i = 0; i < root.metrics.length; i++) {
                if (root.metrics[i].id === modelData.id) {
                  root.zoneChosen("metrics")
                  root.metricChosen(i)
                  break
                }
              }
            }
          }
        }
      }
    }
  }

  Row {
    id: body
    anchors.top: top.bottom
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.bottom: parent.bottom
    anchors.leftMargin: theme.space(16)
    anchors.rightMargin: theme.space(16)
    anchors.bottomMargin: theme.space(12)
    anchors.topMargin: theme.space(12)
    spacing: theme.space(12)

    Rectangle {
      id: listPane
      width: Math.min(420, Math.max(280, body.width * 0.38))
      height: parent.height
      radius: 8
      color: theme.darkBackground
      border.width: root.zone === "metrics" ? 2 : 1
      border.color: root.zone === "metrics" ? theme.accent : theme.lighterBackground

      Flickable {
        anchors.top: parent.top
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: documents.top
        anchors.margins: 8
        anchors.bottomMargin: 0
        contentHeight: metricCol.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds

        Column {
          id: metricCol
          width: parent.width
          spacing: 2

          Repeater {
            model: root.metrics
            delegate: Column {
              required property var modelData
              required property int index
              width: metricCol.width
              spacing: 2

              Text {
                visible: index === 0 || root.metrics[index - 1].group !== modelData.group
                text: modelData.group === "vitals" ? "Vitals" : "Activity"
                color: theme.accent
                font.family: theme.fontFamily
                font.pixelSize: theme.fontSize - 1
                font.bold: true
                topPadding: index === 0 ? 4 : 12
                leftPadding: 8
              }

              Rectangle {
                width: parent.width
                height: 34
                radius: 4
                color: index === root.metricIndex ? theme.selection : "transparent"
                border.width: root.zone === "metrics" && index === root.metricIndex ? 1 : 0
                border.color: theme.accent
                Row {
                  anchors.fill: parent
                  anchors.leftMargin: 8
                  anchors.rightMargin: 8
                  spacing: 8
                  Text {
                    width: parent.width - deltaText.width - 8
                    anchors.verticalCenter: parent.verticalCenter
                    text: modelData.name
                    color: index === root.metricIndex ? theme.brightForeground : theme.foreground
                    font.family: theme.fontFamily
                    font.pixelSize: theme.fontSize
                    font.bold: index === root.metricIndex
                    elide: Text.ElideRight
                  }
                  Text {
                    id: deltaText
                    anchors.verticalCenter: parent.verticalCenter
                    text: modelData.delta
                    color: theme.tone(modelData.tone)
                    font.family: theme.fontFamily
                    font.pixelSize: theme.fontSize - 1
                    font.bold: true
                  }
                }
                MouseArea {
                  anchors.fill: parent
                  cursorShape: Qt.PointingHandCursor
                  onClicked: {
                    root.zoneChosen("metrics")
                    root.metricChosen(index)
                  }
                }
              }
            }
          }
        }
      }

      DocumentSection {
        id: documents
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        anchors.leftMargin: 8
        anchors.rightMargin: 8
        anchors.bottomMargin: 8
      }
    }

    Rectangle {
      id: chartPane
      width: body.width - listPane.width - body.spacing
      height: parent.height
      radius: 8
      color: theme.darkBackground
      border.width: root.zone === "days" ? 2 : 1
      border.color: root.zone === "days" ? theme.accent : theme.lighterBackground

      Gallery {
        anchors.fill: parent
        visible: root.gallery !== ""
        theme: root.theme
        title: root.gallery === "xrays" ? "X-Rays" : "Blood and Urine Tests"
        files: root.gallery === "xrays" ? root.xrays : root.blood.concat(root.urine)
        focusId: root.focusId
        onFocusChosen: (id, kind) => root.documentChosen(id, kind)
        onCloseRequested: root.galleryClosed()
      }

      Column {
        id: chartHead
        visible: root.gallery === ""
        anchors.top: parent.top
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.margins: 14
        spacing: 8

        Text {
          width: parent.width
          text: root.metric ? root.metric.name : "Health"
          color: theme.brightForeground
          font.family: theme.fontFamily
          font.pixelSize: theme.fontSize + 4
          font.bold: true
          elide: Text.ElideRight
        }

        Text {
          width: parent.width
          elide: Text.ElideRight
          visible: root.rangeSpan().length > 0
          text: root.rangeSpan() + (root.classifying ? "  ·  classifying…" : "")
          color: theme.accent
          font.family: theme.fontFamily
          font.pixelSize: theme.fontSize - 1
        }

        Row {
          width: parent.width
          spacing: 16
          visible: root.metric && root.state === "ready"
          Text {
            text: root.days.length > root.dayIndex ? root.dayName(root.days[root.dayIndex]) : ""
            color: theme.foreground
            font.family: theme.fontFamily
            font.pixelSize: theme.fontSize
          }
          Text {
            text: (root.metric && root.metric.seriesText && root.dayIndex < root.metric.seriesText.length)
                  ? root.metric.seriesText[root.dayIndex] + (root.metric.unit ? " " + root.metric.unit : "")
                  : ""
            color: theme.brightForeground
            font.family: theme.fontFamily
            font.pixelSize: theme.fontSize
            font.bold: true
          }
          Text {
            text: root.metric ? root.metric.aggregate + " " + root.metric.value : ""
            color: theme.darkForeground
            font.family: theme.fontFamily
            font.pixelSize: theme.fontSize - 1
          }
        }
      }

      Item {
        id: chartBox
        anchors.top: chartHead.bottom
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: chartFoot.top
        anchors.leftMargin: 14
        anchors.rightMargin: 14
        anchors.topMargin: 8
        visible: root.gallery === "" && root.state === "ready" && root.series.length > 0

        Canvas {
          id: chartCanvas
          anchors.fill: parent
          property var plotted: root.series
          property var levels: (root.metric && root.metric.seriesLevel) ? root.metric.seriesLevel : []
          property string levelKey: {
            var rows = (root.metric && root.metric.seriesLevel) ? root.metric.seriesLevel : []
            var parts = []
            for (var n = 0; n < rows.length; n++) parts.push(rows[n] || "")
            return parts.join("\n")
          }
          property var barColors: root.severityColors
          property int focusDay: root.dayIndex
          property int dragLo: root.dragAnchor
          property int dragHi: root.dragEnd
          property real peak: root.metric && root.metric.seriesMax ? root.metric.seriesMax : 0
          onPlottedChanged: requestPaint()
          onLevelsChanged: requestPaint()
          onLevelKeyChanged: requestPaint()
          onBarColorsChanged: requestPaint()
          onFocusDayChanged: requestPaint()
          onDragLoChanged: requestPaint()
          onDragHiChanged: requestPaint()
          onPeakChanged: requestPaint()
          onWidthChanged: requestPaint()
          onHeightChanged: requestPaint()
          onPaint: {
            var ctx = getContext("2d")
            ctx.clearRect(0, 0, width, height)
            var series = plotted
            var n = series ? series.length : 0
            if (n === 0 || width <= 0 || height <= 0) return
            var slot = width / n
            var barW = Math.max(1, slot > 2 ? slot - 1 : slot)
            var maxV = peak
            var lo = dragLo
            var hi = dragHi
            if (lo > hi) { var swap = lo; lo = hi; hi = swap }
            var dragging = lo >= 0 && hi >= 0 && lo !== hi
            if (dragging) {
              ctx.fillStyle = theme.selection
              ctx.fillRect(lo * slot, 0, (hi - lo + 1) * slot, height)
            } else if (focusDay >= 0 && focusDay < n) {
              ctx.fillStyle = theme.selection
              ctx.fillRect(focusDay * slot, 0, Math.max(slot, 1), height)
            }
            var colors = barColors || {}
            for (var i = 0; i < n; i++) {
              var value = series[i]
              if (value === null || value === undefined || maxV <= 0) continue
              var h = Math.max(1, (Number(value) / maxV) * (height - 4))
              var level = levelKey.length ? levelKey.split("\n")[i] : ""
              var paint = theme.muted
              if (level === "severe" && colors.severe) paint = colors.severe
              else if (level === "alert" && colors.alert) paint = colors.alert
              else if (level === "mild" && colors.mild) paint = colors.mild
              else if (level === "normal" && colors.normal) paint = colors.normal
              ctx.fillStyle = paint
              ctx.fillRect(i * slot + Math.max(0, (slot - barW) / 2), height - h, barW, h)
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
        visible: root.gallery === ""
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        anchors.margins: 14
        spacing: 6

        Row {
          visible: root.state === "ready" && root.days.length > 0 && root.metric && root.metric.seriesLevel
          spacing: 14
          Repeater {
            model: [
              { key: "normal", label: "In range" },
              { key: "mild", label: "Mild" },
              { key: "alert", label: "Alert" },
              { key: "severe", label: "Severe" }
            ]
            delegate: Row {
              required property var modelData
              spacing: 6
              Rectangle {
                width: 10
                height: 10
                radius: 2
                anchors.verticalCenter: parent.verticalCenter
                color: (root.severityColors && root.severityColors[modelData.key]) ? root.severityColors[modelData.key] : theme.muted
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

        Row {
          visible: root.state === "ready" && root.days.length > 0
          width: parent.width
          Text {
            width: parent.width / 3
            text: root.dayName(root.days[0])
            color: theme.darkForeground
            font.family: theme.fontFamily
            font.pixelSize: theme.fontSize - 2
          }
          Text {
            width: parent.width / 3
            horizontalAlignment: Text.AlignHCenter
            text: root.days.length > 2 ? root.dayName(root.days[Math.floor(root.days.length / 2)]) : ""
            color: theme.darkForeground
            font.family: theme.fontFamily
            font.pixelSize: theme.fontSize - 2
          }
          Text {
            width: parent.width / 3
            horizontalAlignment: Text.AlignRight
            text: root.dayName(root.days[root.days.length - 1])
            color: theme.darkForeground
            font.family: theme.fontFamily
            font.pixelSize: theme.fontSize - 2
          }
        }

        Text {
          visible: root.state === "ready" && root.metric
          width: parent.width
          wrapMode: Text.Wrap
          text: root.metric ? root.metric.trend : ""
          color: theme.foreground
          font.family: theme.fontFamily
          font.pixelSize: theme.fontSize
        }

        Text {
          visible: root.state === "ready" && root.metric
          width: parent.width
          text: root.metric ? ("Low " + root.metric.minText + "   avg " + root.metric.avgText + "   high " + root.metric.maxText) : ""
          color: theme.darkForeground
          font.family: theme.fontFamily
          font.pixelSize: theme.fontSize - 1
        }

        Text {
          visible: root.state !== "ready"
          width: parent.width
          wrapMode: Text.Wrap
          text: {
            if (root.state === "loading") return "Opening saved health data…"
            if (root.state === "empty") return root.stateMessage.length > 0 ? root.stateMessage : "No days to chart yet."
            if (root.state === "error" && !(root.metric && root.days.length > 0))
              return "The last read failed before any days were indexed."
            return ""
          }
          color: root.state === "error" ? theme.red : theme.foreground
          font.family: theme.fontFamily
          font.pixelSize: theme.fontSize
        }
      }
    }
  }

  component DocumentSection: Column {
    spacing: 2

    Text {
      text: "Documents"
      color: theme.accent
      font.family: theme.fontFamily
      font.pixelSize: theme.fontSize - 1
      font.bold: true
      topPadding: 12
      leftPadding: 8
    }

    Repeater {
      model: [
        { id: "xrays", label: "X-Rays" },
        { id: "labs", label: "Blood and Urine Tests" }
      ]
      delegate: Rectangle {
        required property var modelData
        width: parent.width
        height: 34
        radius: 4
        color: root.gallery === modelData.id ? theme.selection : "transparent"
        border.width: root.gallery === modelData.id ? 1 : 0
        border.color: theme.accent
        Text {
          anchors.fill: parent
          anchors.leftMargin: 8
          anchors.rightMargin: 8
          verticalAlignment: Text.AlignVCenter
          elide: Text.ElideRight
          text: modelData.label
          color: root.gallery === modelData.id ? theme.brightForeground : theme.foreground
          font.family: theme.fontFamily
          font.pixelSize: theme.fontSize
          font.bold: root.gallery === modelData.id
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
