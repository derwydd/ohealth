import QtQuick

// Settings for the local health database and severity colors. Closes on Esc or Close.
Item {
  id: root

  required property var theme
  property string databasePath: ""
  property var colors: ({ severe: "#f7768e", alert: "#ff9e64", mild: "#e0af68", normal: "#9ece6a" })
  property bool classifyAuto: true
  property bool classifyAll: false
  property string picking: ""

  signal requestClose()
  signal requestChoose()
  signal colorsChosen(string severe, string alert, string mild, string normal)
  signal classifyAutoChosen(bool enabled)
  signal classifyAllChosen(bool enabled)

  readonly property var colorFields: [
    { key: "severe", label: "Severe" },
    { key: "alert", label: "Alert" },
    { key: "mild", label: "Mild" },
    { key: "normal", label: "In range" }
  ]
  readonly property var presets: ["#f7768e", "#e64539", "#ff9e64", "#e0af68", "#e0c04a", "#9ece6a", "#73daca", "#7aa2f7", "#bb9af7", "#c0caf5"]

  function colorOf(id) {
    return (colors && colors[id]) ? colors[id] : "#000000"
  }

  function commitColor(id, hex) {
    var text = String(hex || "").trim()
    if (text.length === 4 && text.charAt(0) === "#") {
      text = "#" + text.charAt(1) + text.charAt(1) + text.charAt(2) + text.charAt(2) + text.charAt(3) + text.charAt(3)
    }
    if (!/^#[0-9A-Fa-f]{6}$/.test(text)) return
    var next = {
      severe: root.colorOf("severe"),
      alert: root.colorOf("alert"),
      mild: root.colorOf("mild"),
      normal: root.colorOf("normal")
    }
    next[id] = text.toLowerCase()
    root.colors = next
    root.colorsChosen(next.severe, next.alert, next.mild, next.normal)
  }

  focus: true
  Keys.onEscapePressed: {
    if (picking) picking = ""
    else root.requestClose()
  }
  Component.onCompleted: forceActiveFocus()

  Rectangle {
    anchors.fill: parent
    color: theme.background

    Flickable {
      anchors.fill: parent
      anchors.margins: 28
      contentWidth: width
      contentHeight: body.implicitHeight
      clip: true
      boundsBehavior: Flickable.StopAtBounds

      Column {
        id: body
        width: parent.width
        spacing: 16

        Text {
          text: "Settings"
          color: theme.brightForeground
          font.family: theme.fontFamily
          font.pixelSize: 20
          font.bold: true
        }

        Text {
          width: parent.width
          wrapMode: Text.Wrap
          text: "OHealth opens the health data saved in the local database."
          color: theme.foreground
          font.family: theme.fontFamily
          font.pixelSize: theme.fontSize
        }

        Column {
          width: parent.width
          spacing: 4
          Text {
            text: "Saved data"
            color: theme.darkForeground
            font.family: theme.fontFamily
            font.pixelSize: theme.fontSize - 1
          }
          Text {
            width: parent.width
            wrapMode: Text.Wrap
            text: root.databasePath
            color: theme.brightForeground
            font.family: theme.fontFamily
            font.pixelSize: theme.fontSize
          }
        }

        Rectangle {
          width: chooseLabel.implicitWidth + 28
          height: 34
          radius: 6
          color: chooseArea.containsMouse ? theme.selection : theme.lighterBackground
          border.width: 1
          border.color: theme.muted
          Text {
            id: chooseLabel
            anchors.centerIn: parent
            text: "Choose database"
            color: theme.brightForeground
            font.family: theme.fontFamily
            font.pixelSize: theme.fontSize
          }
          MouseArea {
            id: chooseArea
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: root.requestChoose()
          }
        }

        Text {
          width: parent.width
          wrapMode: Text.Wrap
          text: "Severity colors are saved in the database and reused. The agent classifies a chart only the first time that day is seen."
          color: theme.foreground
          font.family: theme.fontFamily
          font.pixelSize: theme.fontSize
        }

        Column {
          width: parent.width
          spacing: 8
          Repeater {
            model: root.colorFields
            delegate: Column {
              id: colorRow
              required property var modelData
              readonly property string fieldId: modelData.key
              width: parent.width
              spacing: 6
              Row {
                width: parent.width
                spacing: 10
                Rectangle {
                  width: 28
                  height: 28
                  radius: 6
                  anchors.verticalCenter: parent.verticalCenter
                  color: root.colorOf(modelData.key)
                  border.width: root.picking === modelData.key ? 2 : 1
                  border.color: root.picking === modelData.key ? theme.brightForeground : theme.lighterBackground
                  MouseArea {
                    anchors.fill: parent
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.picking = root.picking === modelData.key ? "" : modelData.key
                  }
                }
                Text {
                  width: 88
                  text: modelData.label
                  color: theme.brightForeground
                  font.family: theme.fontFamily
                  font.pixelSize: theme.fontSize
                  anchors.verticalCenter: parent.verticalCenter
                }
                Rectangle {
                  width: 110
                  height: 28
                  radius: 6
                  color: theme.darkerBackground
                  border.width: 1
                  border.color: theme.lighterBackground
                  anchors.verticalCenter: parent.verticalCenter
                  TextInput {
                    anchors.fill: parent
                    anchors.margins: 6
                    text: root.colorOf(modelData.key)
                    color: theme.brightForeground
                    font.family: theme.fontFamily
                    font.pixelSize: theme.fontSize - 1
                    verticalAlignment: TextInput.AlignVCenter
                    selectByMouse: true
                    onEditingFinished: root.commitColor(modelData.key, text)
                  }
                }
              }
              Row {
                visible: root.picking === modelData.key
                spacing: 6
                Repeater {
                  model: root.presets
                  delegate: Rectangle {
                    required property string modelData
                    width: 22
                    height: 22
                    radius: 4
                    color: modelData
                    border.width: 1
                    border.color: theme.lighterBackground
                    MouseArea {
                      anchors.fill: parent
                      cursorShape: Qt.PointingHandCursor
                      onClicked: root.commitColor(parent.parent.parent.fieldId, modelData)
                    }
                  }
                }
              }
            }
          }
        }

        Column {
          width: parent.width
          spacing: 8
          Row {
            spacing: 10
            Rectangle {
              width: 22
              height: 22
              radius: 4
              anchors.verticalCenter: parent.verticalCenter
              color: root.classifyAuto ? theme.accent : theme.darkerBackground
              border.width: 1
              border.color: root.classifyAuto ? theme.accent : theme.lighterBackground
              Text {
                anchors.centerIn: parent
                visible: root.classifyAuto
                text: "✓"
                color: theme.darkerBackground
                font.pixelSize: 14
                font.bold: true
              }
              MouseArea {
                anchors.fill: parent
                cursorShape: Qt.PointingHandCursor
                onClicked: root.classifyAutoChosen(!root.classifyAuto)
              }
            }
            Text {
              width: body.width - 32
              wrapMode: Text.Wrap
              text: "Classify the chart you are looking at"
              color: theme.brightForeground
              font.family: theme.fontFamily
              font.pixelSize: theme.fontSize
              anchors.verticalCenter: parent.verticalCenter
            }
          }
          Row {
            spacing: 10
            Rectangle {
              width: 22
              height: 22
              radius: 4
              anchors.verticalCenter: parent.verticalCenter
              color: root.classifyAll ? theme.accent : theme.darkerBackground
              border.width: 1
              border.color: root.classifyAll ? theme.accent : theme.lighterBackground
              Text {
                anchors.centerIn: parent
                visible: root.classifyAll
                text: "✓"
                color: theme.darkerBackground
                font.pixelSize: 14
                font.bold: true
              }
              MouseArea {
                anchors.fill: parent
                cursorShape: Qt.PointingHandCursor
                onClicked: root.classifyAllChosen(!root.classifyAll)
              }
            }
            Text {
              width: body.width - 32
              wrapMode: Text.Wrap
              text: "Classify all saved days in the background"
              color: theme.brightForeground
              font.family: theme.fontFamily
              font.pixelSize: theme.fontSize
              anchors.verticalCenter: parent.verticalCenter
            }
          }
          Text {
            width: parent.width
            wrapMode: Text.Wrap
            text: "Background classification stays off until you turn it on. Stored levels are kept either way, so the agent is not asked again."
            color: theme.darkForeground
            font.family: theme.fontFamily
            font.pixelSize: theme.fontSize - 1
          }
        }

        Rectangle {
          width: closeLabel.implicitWidth + 28
          height: 34
          radius: 6
          color: closeArea.containsMouse ? Qt.lighter(theme.accent, 1.12) : theme.accent
          Text {
            id: closeLabel
            anchors.centerIn: parent
            text: "Close"
            color: theme.darkerBackground
            font.family: theme.fontFamily
            font.pixelSize: theme.fontSize
            font.bold: true
          }
          MouseArea {
            id: closeArea
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: root.requestClose()
          }
        }
      }
    }
  }
}
