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
  property var rangeLabels: ["7 days", "30 days", "90 days", "1 year"]
  property string state: "loading"
  property string stateMessage: ""
  property string errorMessage: ""
  property bool sample: false
  property string agentLabel: "No agent chosen"
  property bool agentInstalled: false

  signal rangeChosen(int index)
  signal metricChosen(int index)
  signal dayChosen(int index)
  signal zoneChosen(string name)

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

  function ensureDayVisible() {
    if (series.length === 0) return
    var w = Math.max(4, chartRow.barWidth)
    var x = dayIndex * w
    var viewRight = chartFlick.contentX + chartFlick.width
    if (x < chartFlick.contentX) chartFlick.contentX = x
    else if (x + w > viewRight) chartFlick.contentX = Math.max(0, x + w - chartFlick.width)
  }

  onDayIndexChanged: ensureDayVisible()
  onMetricIndexChanged: ensureDayVisible()

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
          color: index === root.rangeIndex ? theme.selection : theme.darkBackground
          border.width: root.zone === "ranges" && index === root.rangeIndex ? 2 : 1
          border.color: index === root.rangeIndex ? theme.accent : theme.lighterBackground
          Text {
            id: chip
            anchors.centerIn: parent
            text: modelData
            color: index === root.rangeIndex ? theme.brightForeground : theme.foreground
            font.family: theme.fontFamily
            font.pixelSize: theme.fontSize
            font.bold: index === root.rangeIndex
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
        anchors.fill: parent
        anchors.margins: 8
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
    }

    Rectangle {
      id: chartPane
      width: body.width - listPane.width - body.spacing
      height: parent.height
      radius: 8
      color: theme.darkBackground
      border.width: root.zone === "days" ? 2 : 1
      border.color: root.zone === "days" ? theme.accent : theme.lighterBackground

      Column {
        id: chartHead
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
        visible: root.state === "ready" && root.series.length > 0

          Flickable {
            id: chartFlick
            anchors.fill: parent
            contentWidth: chartRow.width
            contentHeight: height
            clip: true
            boundsBehavior: Flickable.StopAtBounds
            flickableDirection: Flickable.HorizontalFlick

            Row {
              id: chartRow
              height: chartFlick.height
              spacing: 0
              property real barWidth: {
                var n = Math.max(1, root.series.length)
                return Math.max(4, (chartBox.width - 2) / n)
              }

              Repeater {
                model: root.series
                delegate: Item {
                  required property var modelData
                  required property int index
                  width: chartRow.barWidth
                  height: chartRow.height
                  Rectangle {
                    anchors.fill: parent
                    color: index === root.dayIndex ? theme.selection : "transparent"
                  }
                  Rectangle {
                    anchors.bottom: parent.bottom
                    anchors.horizontalCenter: parent.horizontalCenter
                    width: Math.max(1, parent.width - 1)
                    height: {
                      var maxV = root.metric && root.metric.seriesMax ? root.metric.seriesMax : 0
                      if (modelData === null || modelData === undefined || maxV <= 0) return 0
                      return Math.max(2, (Number(modelData) / maxV) * (parent.height - 4))
                    }
                    color: index === root.dayIndex ? theme.accent : theme.muted
                  }
                  MouseArea {
                    anchors.fill: parent
                    onClicked: {
                      root.zoneChosen("days")
                      root.dayChosen(index)
                    }
                  }
                }
              }
            }
          }
        }

      Column {
        id: chartFoot
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        anchors.margins: 14
        spacing: 6

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
            if (root.state === "loading") return "Reading the health export…"
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
}
