import QtQuick

// Keyboard reference. Shown in its own window. Closes on Esc, q, or Close.
Item {
  id: root

  required property var theme
  signal requestClose()

  focus: true
  Keys.onEscapePressed: root.requestClose()
  Keys.onPressed: event => {
    if (event.text === "q" || event.text === "?") {
      root.requestClose()
      event.accepted = true
    }
  }
  Component.onCompleted: forceActiveFocus()

  readonly property var sections: [
    { title: "Move", keys: [
      ["tab  shift+tab", "next region, previous region"],
      ["1  2  3  4  5  6  7", "7 days, 30 days, 90 days, 1 year, 3 years, 5 years, all"],
      ["drag across a chart", "save that span as this person's date range"],
      ["h  l  ←  →", "change the focused row"],
      ["j  k  ↑  ↓", "change the focused row"],
      ["g  home", "first day or the dashboard"],
      ["G  end", "last day or last metric"],
      ["page up  page down", "move further in that region"],
      ["[", "shorter range"],
      ["]", "longer range"]
    ]},
    { title: "Act", keys: [
      ["enter", "ask the Omarchy agent about the focused metric"],
      ["agent region, j k", "change the saved Omarchy default"],
      ["a", "open the full agent list"],
      ["enter in the picker", "save that agent as the Omarchy default"],
      ["o in the picker", "open Omarchy's own agent menu, when the shell is installed"],
      ["r", "reload the saved health data"],
      ["file menu", "Settings, keyboard, switch person, Import, or close"],
      ["opening the app", "choose a person. Import asks you to confirm that person"],
      ["ctrl+p", "preview invented sample data"],
      ["?", "open this window"],
      ["esc", "close this window, or the picker, or quit"],
      ["q", "quit"]
    ]},
    { title: "Regions", keys: [
      ["ranges", "the four windows across the top"],
      ["metrics", "activity, then vitals"],
      ["days", "the bars of the focused metric"],
      ["chat", "the question field. Tab lands here so you can type"],
      ["agent", "the Omarchy agent named in the footer"]
    ]}
  ]

  Rectangle {
    anchors.fill: parent
    color: theme.background

    Flickable {
      anchors.fill: parent
      anchors.margins: 28
      anchors.bottomMargin: 72
      contentWidth: width
      contentHeight: body.implicitHeight
      clip: true
      boundsBehavior: Flickable.StopAtBounds

      Column {
        id: body
        width: parent.width
        spacing: 18
        Text {
          text: "Keyboard"
          color: theme.brightForeground
          font.family: theme.fontFamily
          font.pixelSize: 18
          font.bold: true
        }
        Text {
          width: parent.width
          wrapMode: Text.Wrap
          text: "The mouse works. Nothing in the window requires it."
          color: theme.darkForeground
          font.family: theme.fontFamily
          font.pixelSize: theme.fontSize - 1
        }
        Repeater {
          model: root.sections
          delegate: Column {
            required property var modelData
            width: body.width
            spacing: 6
            Text {
              text: modelData.title
              color: theme.accent
              font.family: theme.fontFamily
              font.pixelSize: theme.fontSize
              font.bold: true
            }
            Repeater {
              model: modelData.keys
              delegate: Row {
                required property var modelData
                width: body.width
                spacing: 16
                Text {
                  width: 220
                  text: modelData[0]
                  color: theme.brightForeground
                  font.family: theme.fontFamily
                  font.pixelSize: theme.fontSize - 1
                }
                Text {
                  width: body.width - 236
                  text: modelData[1]
                  color: theme.foreground
                  font.family: theme.fontFamily
                  font.pixelSize: theme.fontSize - 1
                  wrapMode: Text.Wrap
                }
              }
            }
          }
        }
      }
    }

    Rectangle {
      anchors.left: parent.left
      anchors.bottom: parent.bottom
      anchors.leftMargin: 28
      anchors.bottomMargin: 20
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
