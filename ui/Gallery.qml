import QtQuick
import QtQuick.Pdf

// Thumbnails for the X-ray or lab section chosen in the right panel.
Item {
  id: root

  required property var theme
  property string title: ""
  property var files: []
  property string focusId: ""

  signal focusChosen(string id, string kind)
  signal closeRequested()

  function fileUrl(path) {
    return "file://" + encodeURI(String(path || ""))
  }

  function isImage(path) {
    var lower = String(path || "").toLowerCase()
    return lower.endsWith(".png") || lower.endsWith(".jpg") || lower.endsWith(".jpeg")
        || lower.endsWith(".webp") || lower.endsWith(".gif") || lower.endsWith(".tif")
        || lower.endsWith(".tiff")
  }

  function isPdf(path) {
    return String(path || "").toLowerCase().endsWith(".pdf")
  }

  Rectangle {
    anchors.fill: parent
    color: theme.background

    Column {
      anchors.fill: parent
      anchors.margins: 16
      spacing: 12

      Row {
        width: parent.width
        spacing: 12
        Text {
          text: root.title
          color: theme.brightForeground
          font.family: theme.fontFamily
          font.pixelSize: 18
          font.bold: true
          anchors.verticalCenter: parent.verticalCenter
        }
        Rectangle {
          height: 28
          width: backLabel.implicitWidth + 18
          radius: 6
          color: backArea.containsMouse ? theme.selection : theme.darkBackground
          anchors.verticalCenter: parent.verticalCenter
          Text {
            id: backLabel
            anchors.centerIn: parent
            text: "Health"
            color: theme.foreground
            font.family: theme.fontFamily
            font.pixelSize: theme.fontSize - 1
          }
          MouseArea {
            id: backArea
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: root.closeRequested()
          }
        }
      }

      Flickable {
        width: parent.width
        height: parent.height - 40
        contentWidth: width
        contentHeight: grid.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds

        Grid {
          id: grid
          width: parent.width
          columns: Math.max(1, Math.floor(width / 220))
          columnSpacing: 16
          rowSpacing: 16

          Repeater {
            model: root.files
            delegate: Rectangle {
              required property var modelData
              width: 200
              height: 250
              radius: 8
              color: theme.darkBackground
              border.width: root.focusId === modelData.id ? 2 : 1
              border.color: root.focusId === modelData.id ? theme.accent : theme.lighterBackground

              Image {
                anchors.top: parent.top
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.margins: 8
                height: 190
                visible: root.isImage(modelData.path)
                fillMode: Image.PreserveAspectFit
                asynchronous: true
                source: visible ? root.fileUrl(modelData.path) : ""
              }

              Item {
                anchors.top: parent.top
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.margins: 8
                height: 190
                visible: root.isPdf(modelData.path)
                clip: true
                PdfDocument {
                  id: pdf
                  source: parent.visible ? root.fileUrl(modelData.path) : ""
                }
                PdfPageView {
                  anchors.fill: parent
                  document: pdf
                }
              }

              Text {
                anchors.centerIn: parent
                anchors.verticalCenterOffset: -16
                visible: !root.isImage(modelData.path) && !root.isPdf(modelData.path)
                text: "Document"
                color: theme.darkForeground
                font.family: theme.fontFamily
                font.pixelSize: theme.fontSize
              }

              Text {
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.bottom: parent.bottom
                anchors.margins: 8
                elide: Text.ElideRight
                text: (modelData.kind === "urine" ? "Urine  " : modelData.kind === "blood" ? "Blood  " : "") + modelData.name
                color: theme.brightForeground
                font.family: theme.fontFamily
                font.pixelSize: theme.fontSize - 1
              }

              MouseArea {
                anchors.fill: parent
                cursorShape: Qt.PointingHandCursor
                onClicked: {
                  var next = root.focusId === modelData.id ? "" : modelData.id
                  root.focusChosen(next, modelData.kind || "")
                }
              }
            }
          }
        }

        Text {
          visible: root.files.length === 0
          width: parent.width
          wrapMode: Text.Wrap
          text: "Nothing in this section yet."
          color: theme.darkForeground
          font.family: theme.fontFamily
          font.pixelSize: theme.fontSize
        }
      }
    }
  }
}
