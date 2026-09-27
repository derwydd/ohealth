import QtQuick

// Progress ring with a label in the middle. value runs from 0 to 1.
Item {
  id: ring

  property real value: 0
  property color color: "#7aa2f7"
  property color color2: color
  property color track: "#24283b"
  property real thickness: 10
  property string label: ""
  property string sublabel: ""
  property string fontFamily: ""
  property int fontSize: 18
  property color textColor: "#c0caf5"
  property color subColor: "#565f89"

  Canvas {
    id: arc
    anchors.fill: parent
    property real amount: Math.max(0, Math.min(1, Number(ring.value) || 0))
    property color c1: ring.color
    property color c2: ring.color2
    property color tr: ring.track
    property real stroke: ring.thickness
    onAmountChanged: requestPaint()
    onC1Changed: requestPaint()
    onC2Changed: requestPaint()
    onTrChanged: requestPaint()
    onStrokeChanged: requestPaint()
    onWidthChanged: requestPaint()
    onHeightChanged: requestPaint()
    onPaint: {
      var ctx = getContext("2d")
      ctx.clearRect(0, 0, width, height)
      var r = Math.min(width, height) / 2 - stroke / 2 - 1
      if (r <= 0) return
      var cx = width / 2
      var cy = height / 2
      ctx.lineWidth = stroke
      ctx.lineCap = "round"
      ctx.strokeStyle = tr
      ctx.beginPath()
      ctx.arc(cx, cy, r, 0, Math.PI * 2)
      ctx.stroke()
      if (amount <= 0) return
      var g = ctx.createLinearGradient(0, 0, width, height)
      g.addColorStop(0, c1)
      g.addColorStop(1, c2)
      ctx.strokeStyle = g
      ctx.beginPath()
      ctx.arc(cx, cy, r, -Math.PI / 2, -Math.PI / 2 + Math.PI * 2 * amount)
      ctx.stroke()
    }
  }

  Column {
    anchors.centerIn: parent
    spacing: 0
    Text {
      anchors.horizontalCenter: parent.horizontalCenter
      text: ring.label
      color: ring.textColor
      font.family: ring.fontFamily
      font.pixelSize: ring.fontSize
      font.bold: true
    }
    Text {
      visible: ring.sublabel.length > 0
      anchors.horizontalCenter: parent.horizontalCenter
      text: ring.sublabel
      color: ring.subColor
      font.family: ring.fontFamily
      font.pixelSize: Math.max(9, ring.fontSize * 0.5)
    }
  }
}
