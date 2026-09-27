import QtQuick

// Small trend line or bar strip. Null values leave a gap.
Canvas {
  id: spark

  property var values: []
  property color color: "#7aa2f7"
  property color color2: color
  property bool area: true
  property bool bars: false
  property real lineWidth: 2
  property bool fromZero: true
  property real ceiling: 0
  property var band: null
  property color bandColor: Qt.rgba(0.6, 0.8, 0.4, 0.12)
  property int highlight: -1
  property color highlightColor: "#ffffff"

  readonly property string valuesKey: {
    var list = values || []
    var parts = []
    for (var i = 0; i < list.length; i++) parts.push(list[i] === null || list[i] === undefined ? "" : String(list[i]))
    return parts.join(",")
  }
  readonly property string bandKey: band ? String(band[0]) + ":" + String(band[1]) : ""

  onValuesKeyChanged: requestPaint()
  onBandKeyChanged: requestPaint()
  onColorChanged: requestPaint()
  onColor2Changed: requestPaint()
  onHighlightChanged: requestPaint()
  onCeilingChanged: requestPaint()
  onWidthChanged: requestPaint()
  onHeightChanged: requestPaint()

  function alpha(c, a) { return Qt.rgba(c.r, c.g, c.b, a) }

  onPaint: {
    var ctx = getContext("2d")
    ctx.clearRect(0, 0, width, height)
    var list = values || []
    var n = list.length
    if (n === 0 || width <= 0 || height <= 0) return
    var lo = Infinity
    var hi = -Infinity
    for (var i = 0; i < n; i++) {
      var v = list[i]
      if (v === null || v === undefined || !isFinite(Number(v))) continue
      v = Number(v)
      if (v < lo) lo = v
      if (v > hi) hi = v
    }
    if (band) {
      lo = Math.min(lo, band[0])
      hi = Math.max(hi, band[1])
    }
    if (!isFinite(lo) || !isFinite(hi)) return
    if (fromZero) lo = Math.min(0, lo)
    else lo = lo - (hi - lo) * 0.15
    if (ceiling > 0) hi = Math.max(hi, ceiling)
    else hi = hi + (hi - lo) * 0.1
    if (hi <= lo) hi = lo + 1
    var pad = lineWidth + 2
    var span = height - pad * 2
    function yOf(value) { return pad + span - ((value - lo) / (hi - lo)) * span }

    if (band) {
      ctx.fillStyle = bandColor
      var top = yOf(band[1])
      ctx.fillRect(0, top, width, yOf(band[0]) - top)
    }

    if (bars) {
      var slot = width / n
      var w = Math.max(1, slot * 0.62)
      for (var b = 0; b < n; b++) {
        var bv = list[b]
        if (bv === null || bv === undefined) continue
        var y = yOf(Number(bv))
        var h = Math.max(2, height - pad - y)
        var x = b * slot + (slot - w) / 2
        var g = ctx.createLinearGradient(0, y, 0, y + h)
        g.addColorStop(0, b === highlight ? highlightColor : color)
        g.addColorStop(1, alpha(color2, 0.25))
        ctx.fillStyle = g
        var r = Math.min(w / 2, 4)
        ctx.beginPath()
        ctx.moveTo(x, y + h)
        ctx.lineTo(x, y + r)
        ctx.arcTo(x, y, x + r, y, r)
        ctx.lineTo(x + w - r, y)
        ctx.arcTo(x + w, y, x + w, y + r, r)
        ctx.lineTo(x + w, y + h)
        ctx.closePath()
        ctx.fill()
      }
      return
    }

    var step = n > 1 ? width / (n - 1) : 0
    var segments = []
    var current = []
    for (var p = 0; p < n; p++) {
      var pv = list[p]
      if (pv === null || pv === undefined) {
        if (current.length) segments.push(current)
        current = []
        continue
      }
      current.push({ x: n > 1 ? p * step : width / 2, y: yOf(Number(pv)), i: p })
    }
    if (current.length) segments.push(current)

    for (var s = 0; s < segments.length; s++) {
      var seg = segments[s]
      if (area && seg.length > 1) {
        var fill = ctx.createLinearGradient(0, 0, 0, height)
        fill.addColorStop(0, alpha(color, 0.45))
        fill.addColorStop(1, alpha(color2, 0.0))
        ctx.fillStyle = fill
        ctx.beginPath()
        ctx.moveTo(seg[0].x, height)
        for (var a = 0; a < seg.length; a++) ctx.lineTo(seg[a].x, seg[a].y)
        ctx.lineTo(seg[seg.length - 1].x, height)
        ctx.closePath()
        ctx.fill()
      }
      var stroke = ctx.createLinearGradient(0, 0, width, 0)
      stroke.addColorStop(0, color2)
      stroke.addColorStop(1, color)
      ctx.strokeStyle = stroke
      ctx.lineWidth = lineWidth
      ctx.lineJoin = "round"
      ctx.lineCap = "round"
      ctx.beginPath()
      ctx.moveTo(seg[0].x, seg[0].y)
      for (var l = 1; l < seg.length; l++) ctx.lineTo(seg[l].x, seg[l].y)
      ctx.stroke()
    }

    var mark = highlight >= 0 ? highlight : -1
    if (mark < 0) {
      for (var q = n - 1; q >= 0; q--) {
        if (list[q] !== null && list[q] !== undefined) { mark = q; break }
      }
    }
    if (mark >= 0 && list[mark] !== null && list[mark] !== undefined) {
      var mx = n > 1 ? mark * step : width / 2
      var my = yOf(Number(list[mark]))
      ctx.fillStyle = alpha(color, 0.28)
      ctx.beginPath()
      ctx.arc(mx, my, lineWidth + 5, 0, Math.PI * 2)
      ctx.fill()
      ctx.fillStyle = highlightColor
      ctx.beginPath()
      ctx.arc(mx, my, lineWidth + 1.5, 0, Math.PI * 2)
      ctx.fill()
    }
  }
}
