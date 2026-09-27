import QtQuick

// Rounded dashboard card. Children go below the title row.
Rectangle {
  id: card

  required property var theme
  property color tint: theme.accent
  property bool focused: false
  property bool glow: false
  property string title: ""
  property string caption: ""
  property color captionColor: theme.darkForeground
  property real pad: 14
  default property alias content: body.data

  radius: 16
  border.width: focused ? 2 : 1
  border.color: focused ? tint : Qt.rgba(tint.r, tint.g, tint.b, 0.22)
  gradient: Gradient {
    GradientStop { position: 0.0; color: Qt.tint(card.theme.darkBackground, Qt.rgba(card.tint.r, card.tint.g, card.tint.b, card.glow ? 0.30 : 0.10)) }
    GradientStop { position: 1.0; color: Qt.tint(card.theme.darkBackground, Qt.rgba(card.tint.r, card.tint.g, card.tint.b, card.glow ? 0.06 : 0.02)) }
  }

  Item {
    id: header
    visible: card.title.length > 0
    anchors.top: parent.top
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.topMargin: card.pad - 2
    anchors.leftMargin: card.pad
    anchors.rightMargin: card.pad
    height: visible ? 22 : 0

    Rectangle {
      id: dot
      width: 8
      height: 8
      radius: 4
      color: card.tint
      anchors.verticalCenter: parent.verticalCenter
    }
    Text {
      anchors.left: dot.right
      anchors.leftMargin: 8
      anchors.right: captionText.left
      anchors.rightMargin: 8
      anchors.verticalCenter: parent.verticalCenter
      text: card.title
      elide: Text.ElideRight
      color: card.theme.brightForeground
      font.family: card.theme.fontFamily
      font.pixelSize: card.theme.fontSize
      font.bold: true
    }
    Text {
      id: captionText
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      width: Math.min(implicitWidth, parent.width * 0.55)
      horizontalAlignment: Text.AlignRight
      elide: Text.ElideLeft
      text: card.caption
      color: card.captionColor
      font.family: card.theme.fontFamily
      font.pixelSize: card.theme.fontSize - 2
    }
  }

  Item {
    id: body
    anchors.top: header.visible ? header.bottom : parent.top
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.bottom: parent.bottom
    anchors.topMargin: header.visible ? 10 : card.pad
    anchors.leftMargin: card.pad
    anchors.rightMargin: card.pad
    anchors.bottomMargin: card.pad
  }
}
