import QtQuick

// Right-hand chat with the chosen Omarchy agent.
Item {
  id: root

  required property var theme
  property string agentLabel: "No agent chosen"
  property bool busy: false
  property string scope: "selected"
  property var messages: []

  signal sendRequested(string text)
  signal scopeChosen(string scope)
  signal agentRequested()

  function submit() {
    var text = draft.text.trim()
    if (!text || root.busy) return
    draft.text = ""
    root.sendRequested(text)
  }

  Rectangle {
    anchors.fill: parent
    color: theme.darkerBackground

    Rectangle {
      anchors.left: parent.left
      width: 1
      height: parent.height
      color: theme.lighterBackground
    }

    Column {
      anchors.fill: parent
      anchors.margins: 12
      spacing: 10

      Row {
        width: parent.width
        spacing: 8
        Text {
          text: "Ask"
          color: theme.brightForeground
          font.family: theme.fontFamily
          font.pixelSize: theme.fontSize + 1
          font.bold: true
          anchors.verticalCenter: parent.verticalCenter
        }
        Rectangle {
          height: 26
          width: Math.min(agentChip.implicitWidth + 16, parent.width - 150)
          radius: 6
          color: theme.darkBackground
          anchors.verticalCenter: parent.verticalCenter
          Text {
            id: agentChip
            anchors.centerIn: parent
            text: root.agentLabel
            color: theme.accent
            font.family: theme.fontFamily
            font.pixelSize: theme.fontSize - 1
            elide: Text.ElideRight
          }
          MouseArea {
            anchors.fill: parent
            cursorShape: Qt.PointingHandCursor
            onClicked: root.agentRequested()
          }
        }
      }

      Row {
        spacing: 6
        Repeater {
          model: [
            { id: "selected", label: "Selected" },
            { id: "all", label: "All data" }
          ]
          delegate: Rectangle {
            required property var modelData
            width: scopeText.implicitWidth + 16
            height: 26
            radius: 6
            color: root.scope === modelData.id ? theme.selection : theme.darkBackground
            border.width: 1
            border.color: root.scope === modelData.id ? theme.accent : theme.lighterBackground
            Text {
              id: scopeText
              anchors.centerIn: parent
              text: modelData.label
              color: theme.brightForeground
              font.family: theme.fontFamily
              font.pixelSize: theme.fontSize - 1
            }
            MouseArea {
              anchors.fill: parent
              cursorShape: Qt.PointingHandCursor
              onClicked: root.scopeChosen(modelData.id)
            }
          }
        }
      }

      ListView {
        id: transcript
        width: parent.width
        height: Math.max(80, parent.height - composer.height - 130)
        clip: true
        spacing: 8
        model: root.messages
        onCountChanged: positionViewAtEnd()
        delegate: Column {
          required property var modelData
          width: transcript.width
          spacing: 2
          Text {
            text: modelData.role === "user" ? "You" : (modelData.agent || "Agent")
            color: theme.darkForeground
            font.family: theme.fontFamily
            font.pixelSize: theme.fontSize - 2
          }
          Text {
            width: parent.width
            wrapMode: Text.Wrap
            text: modelData.body || ""
            color: theme.foreground
            font.family: theme.fontFamily
            font.pixelSize: theme.fontSize - 1
          }
        }
        Text {
          visible: transcript.count === 0
          width: parent.width
          wrapMode: Text.Wrap
          text: "Ask about the selection, or about everything in the database. The agent can read the sqlite file and the imported X-rays and lab results."
          color: theme.darkForeground
          font.family: theme.fontFamily
          font.pixelSize: theme.fontSize - 1
        }
      }

      Text {
        id: busyText
        visible: root.busy
        text: "The agent is reading…"
        color: theme.accent
        font.family: theme.fontFamily
        font.pixelSize: theme.fontSize - 1
      }

      Row {
        id: composer
        width: parent.width
        spacing: 6
        Rectangle {
          width: parent.width - send.width - 6
          height: 36
          radius: 6
          color: theme.darkBackground
          border.width: 1
          border.color: theme.lighterBackground
          TextInput {
            id: draft
            anchors.fill: parent
            anchors.margins: 8
            clip: true
            color: theme.brightForeground
            font.family: theme.fontFamily
            font.pixelSize: theme.fontSize
            verticalAlignment: TextInput.AlignVCenter
            selectByMouse: true
            Keys.onReturnPressed: root.submit()
            Keys.onEnterPressed: root.submit()
          }
        }
        Rectangle {
          id: send
          width: 64
          height: 36
          radius: 6
          color: sendArea.containsMouse ? Qt.lighter(theme.accent, 1.12) : theme.accent
          Text {
            anchors.centerIn: parent
            text: "Send"
            color: theme.darkerBackground
            font.family: theme.fontFamily
            font.pixelSize: theme.fontSize - 1
            font.bold: true
          }
          MouseArea {
            id: sendArea
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: root.submit()
          }
        }
      }
    }
  }
}
