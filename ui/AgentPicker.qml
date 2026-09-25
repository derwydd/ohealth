import QtQuick

// Lists the agents omarchy-default-agent accepts. Enter writes
// ~/.config/omarchy/defaults/agent, the file that command reads.
Rectangle {
  id: root

  required property var theme
  property var agents: []
  property int cursor: 0
  property string selectedId: ""
  property bool omarchyLauncher: false
  signal requestClose()
  signal commitRequested()
  signal cursorMoved(int index)

  color: Qt.rgba(0, 0, 0, 0.62)

  MouseArea {
    anchors.fill: parent
    onClicked: root.requestClose()
  }

  Rectangle {
    anchors.centerIn: parent
    width: Math.min(520, root.width - 32)
    height: Math.min(list.implicitHeight + 148, root.height - 32)
    radius: 12
    color: theme.darkBackground
    border.color: theme.lighterBackground
    border.width: 1
    MouseArea { anchors.fill: parent }

    Column {
      id: list
      anchors.fill: parent
      anchors.margins: 22
      spacing: 8

      Text {
        text: "Omarchy agent"
        color: theme.brightForeground
        font.family: theme.fontFamily
        font.pixelSize: 18
        font.bold: true
      }
      Text {
        width: parent.width
        wrapMode: Text.Wrap
        text: "This is the system agent Omarchy launches. The choice is saved in ~/.config/omarchy/defaults/agent. Enter asks it about the metric you were on, after you close this with a selection."
        color: theme.darkForeground
        font.family: theme.fontFamily
        font.pixelSize: theme.fontSize - 1
      }

      Flickable {
        width: parent.width
        height: parent.height - 96
        contentHeight: rows.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds

        Column {
          id: rows
          width: parent.width
          spacing: 2
          Repeater {
            model: root.agents
            delegate: Rectangle {
              required property var modelData
              required property int index
              width: rows.width
              height: 32
              radius: 4
              color: index === root.cursor ? theme.selection : "transparent"
              border.width: index === root.cursor ? 1 : 0
              border.color: theme.accent
              Row {
                anchors.fill: parent
                anchors.leftMargin: 10
                anchors.rightMargin: 10
                spacing: 10
                Text {
                  width: 18
                  anchors.verticalCenter: parent.verticalCenter
                  text: modelData.selected || modelData.id === root.selectedId ? "●" : ""
                  color: theme.accent
                  font.family: theme.fontFamily
                  font.pixelSize: theme.fontSize
                }
                Text {
                  width: 180
                  anchors.verticalCenter: parent.verticalCenter
                  text: modelData.name
                  color: index === root.cursor ? theme.brightForeground : theme.foreground
                  font.family: theme.fontFamily
                  font.pixelSize: theme.fontSize
                  font.bold: index === root.cursor
                  elide: Text.ElideRight
                }
                Text {
                  anchors.verticalCenter: parent.verticalCenter
                  text: modelData.installed ? "installed" : "not on PATH"
                  color: modelData.installed ? theme.green : theme.darkForeground
                  font.family: theme.fontFamily
                  font.pixelSize: theme.fontSize - 1
                }
              }
              MouseArea {
                anchors.fill: parent
                onClicked: root.cursorMoved(index)
                onDoubleClicked: {
                  root.cursorMoved(index)
                  root.commitRequested()
                }
              }
            }
          }
        }
      }

      Text {
        width: parent.width
        wrapMode: Text.Wrap
        text: root.omarchyLauncher
          ? "j/k move · enter saves · o opens Omarchy's menu · esc closes"
          : "j/k move · enter saves · esc closes"
        color: theme.darkForeground
        font.family: theme.fontFamily
        font.pixelSize: theme.fontSize - 2
      }
    }
  }
}
