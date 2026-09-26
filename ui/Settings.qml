import QtQuick

// Settings for the local health database. Closes on Esc or Close.
Item {
  id: root

  required property var theme
  property string databasePath: ""

  signal requestClose()
  signal requestChoose()

  focus: true
  Keys.onEscapePressed: root.requestClose()
  Component.onCompleted: forceActiveFocus()

  Rectangle {
    anchors.fill: parent
    color: theme.background

    Column {
      anchors.fill: parent
      anchors.margins: 28
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

      Item { width: 1; height: 8 }

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
