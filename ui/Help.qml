import QtQuick

// Keyboard reference. Closes on ?, Esc, or q.
Rectangle {
  id: root

  required property var theme
  signal requestClose()

  color: Qt.rgba(0, 0, 0, 0.62)

  readonly property var sections: [
    { title: "Move", keys: [
      ["tab  shift+tab", "next region, previous region"],
      ["1  2  3  4", "7 days, 30 days, 90 days, 1 year"],
      ["h  l  ←  →", "change the focused row"],
      ["j  k  ↑  ↓", "change the focused row"],
      ["g  home", "first day or first metric"],
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
      ["r", "read the Health export again"],
      ["shift+r", "check the Apple session"],
      ["ctrl+p", "preview invented sample data"],
      ["?", "this list"],
      ["esc", "close this, or the picker, or quit"],
      ["q", "quit"]
    ]},
    { title: "Regions", keys: [
      ["ranges", "the four windows across the top"],
      ["metrics", "activity, then vitals"],
      ["days", "the bars of the focused metric"],
      ["agent", "the Omarchy agent named in the footer"]
    ]}
  ]

  MouseArea {
    anchors.fill: parent
    onClicked: root.requestClose()
  }

  Rectangle {
    anchors.centerIn: parent
    width: Math.min(body.implicitWidth + 64, root.width - 32)
    height: Math.min(body.implicitHeight + 56, root.height - 32)
    radius: 12
    color: theme.darkBackground
    border.color: theme.lighterBackground
    border.width: 1
    MouseArea { anchors.fill: parent }

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
        spacing: 18
        Text {
          text: "Keys"
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
  }
}
