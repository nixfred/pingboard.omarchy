import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import qs.Commons
import qs.Ui

// LAW 17: everything on one screen. The only thing that can scroll is the
// target list, in place, inside its own bounded box, and only when there are
// more tailnet hosts than rows.
Panel {
  id: panel
  moduleName: "nixfred.pingboard"
  // IPC target so scripts can open it: omarchy-shell nixfred.pingboard toggle
  ipcTarget: "nixfred.pingboard"

  required property var widget
  readonly property var svc: widget.svc

  readonly property color foreground: widget.bar ? widget.bar.foreground : Color.foreground
  readonly property color dim: Util.alpha(foreground, 0.62)
  readonly property color faint: Util.alpha(foreground, 0.10)
  readonly property color warnColor: Qt.tint(Color.accent, Util.alpha(Color.urgent, 0.55))
  readonly property string fontFamily: widget.bar ? widget.bar.fontFamily : Style.font.family
  readonly property string mono: "monospace"

  readonly property int panelWidth: Style.space(920)
  readonly property int rowH: Style.space(38)
  readonly property int maxRows: 10

  function levelColor(l) { return l === "down" ? Color.urgent : l === "warn" ? panel.warnColor : Color.accent }
  function msColor(t) {
    if (!t || t.last === null) return Color.urgent
    if (t.recentLoss > 15) return panel.warnColor
    return panel.foreground
  }
  function fmt(v, unit) { return v === null || v === undefined ? "--" : (Math.round(v * 10) / 10) + unit }
  function kindTip(k) {
    return k === "lan" ? "LAN: your default gateway (router). Loss here means wifi or cable."
      : k === "isp" ? "ISP: a public anycast IP, pinged by address so DNS cannot fool it."
      : k === "dns" ? "DNS: time to resolve a name. 'lookup' uses the system resolver, the other asks 1.1.1.1 directly."
      : "Tailnet: a Tailscale peer, resolved once with tailscale ip."
  }
  readonly property var zones: ["LAN", "ISP", "DNS", "TAILNET"]

  KeyboardPanel {
    id: kpanel
    anchorItem: panel.widget.anchorItem
    owner: panel.widget
    bar: panel.widget.bar
    open: panel.opened
    focusTarget: keyCatcher
    contentWidth: kpanel.fittedContentWidth(panel.panelWidth)
    contentHeight: kpanel.fittedContentHeight(content.implicitHeight, Style.space(640))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onCloseRequested: panel.widget.close()

      ColumnLayout {
        id: content
        width: parent.width
        spacing: Style.space(10)

        // ---------------------------------------------------------- header
        RowLayout {
          Layout.fillWidth: true
          spacing: Style.space(10)
          Rectangle {
            width: Style.space(12); height: width; radius: width / 2; border.width: 0
            color: svc && svc.ready ? panel.levelColor(svc.level) : panel.faint
          }
          Text {
            text: "PINGBOARD"
            color: panel.foreground
            font.family: panel.fontFamily
            font.pixelSize: Style.font.subtitle
            font.bold: true
            font.letterSpacing: 2
          }
          Text {
            text: svc ? (svc.link.toUpperCase() + "  " + svc.device) : ""
            color: panel.dim
            font.family: panel.mono
            font.pixelSize: Style.font.bodySmall
            MouseArea { id: linkHover; anchors.fill: parent; hoverEnabled: true }
            PanelToolTip { visible: linkHover.containsMouse; text: "Active default route (lowest metric). Switches live on eth/wifi handoff." }
          }
          Item { Layout.fillWidth: true }
          Text {
            text: svc ? (svc.prober + " every " + svc.intervalSec + "s") : ""
            color: panel.dim
            font.family: panel.mono
            font.pixelSize: Style.font.bodySmall
          }
        }

        // --------------------------------------------------------- verdict
        Rectangle {
          Layout.fillWidth: true
          implicitHeight: Style.space(58)
          radius: Style.space(4)
          color: Util.alpha(svc ? panel.levelColor(svc.level) : panel.faint, 0.10)
          border.width: 1
          border.color: Util.alpha(svc ? panel.levelColor(svc.level) : panel.faint, 0.6)

          RowLayout {
            anchors.fill: parent
            anchors.leftMargin: Style.space(12)
            anchors.rightMargin: Style.space(12)
            spacing: Style.space(8)

            Repeater {
              model: panel.zones
              delegate: Rectangle {
                required property string modelData
                readonly property bool hit: svc && svc.ready && svc.where === modelData
                implicitWidth: zt.implicitWidth + Style.space(16)
                implicitHeight: Style.space(26)
                radius: Style.space(3)
                color: hit ? panel.levelColor(svc.level) : "transparent"
                border.width: 1
                border.color: hit ? panel.levelColor(svc.level) : Util.alpha(Color.accent, 0.45)
                Text {
                  id: zt
                  anchors.centerIn: parent
                  text: modelData
                  color: parent.hit ? Color.background : Util.alpha(Color.accent, 0.9)
                  font.family: panel.mono
                  font.pixelSize: Style.font.bodySmall
                  font.bold: true
                }
              }
            }
            Text {
              Layout.fillWidth: true
              text: svc ? ((svc.level === "ok" ? "ALL CLEAR  " : "") + svc.why) : ""
              color: panel.foreground
              elide: Text.ElideRight
              font.family: panel.fontFamily
              font.pixelSize: Style.font.body
              font.bold: svc && svc.level !== "ok"
            }
          }
        }

        // ---------------------------------------------------- column heads
        RowLayout {
          Layout.fillWidth: true
          Layout.leftMargin: Style.space(8)
          Layout.rightMargin: Style.space(8)
          spacing: Style.space(10)
          Repeater {
            model: [
              { t: "",        w: 64,  tip: "" },
              { t: "TARGET",  w: 150, tip: "What is probed. Hover a row tag for what it proves." },
              { t: "LAST 5 MIN", w: -1, tip: "One sample per interval, 60 kept. Gaps drawn at the bottom are lost probes." },
              { t: "NOW",     w: 64,  tip: "Most recent round trip." },
              { t: "AVG",     w: 64,  tip: "Mean of answered probes in the window." },
              { t: "JIT",     w: 56,  tip: "Jitter: mean change between consecutive answers." },
              { t: "LOSS",    w: 56,  tip: "Share of probes in the window with no answer." }
            ]
            delegate: Text {
              required property var modelData
              Layout.preferredWidth: modelData.w > 0 ? Style.space(modelData.w) : -1
              Layout.fillWidth: modelData.w < 0
              horizontalAlignment: modelData.w > 0 && modelData.w < 100 ? Text.AlignRight : Text.AlignLeft
              text: modelData.t
              color: panel.dim
              font.family: panel.mono
              font.pixelSize: Style.font.bodySmall
              font.letterSpacing: 1
              MouseArea { id: hh; anchors.fill: parent; hoverEnabled: true }
              PanelToolTip { visible: hh.containsMouse && modelData.tip !== ""; text: modelData.tip }
            }
          }
        }

        // ------------------------------------------------------ target list
        // Bounded box: grows with the rows up to maxRows, then scrolls in place.
        ListView {
          id: list
          Layout.fillWidth: true
          Layout.preferredHeight: Math.min(count, panel.maxRows) * (panel.rowH + spacing)
          clip: true
          spacing: Style.space(3)
          interactive: count > panel.maxRows
          boundsBehavior: Flickable.StopAtBounds
          model: svc ? svc.targets : []

          delegate: Rectangle {
            required property var modelData
            required property int index
            width: ListView.view.width
            height: panel.rowH
            radius: Style.space(3)
            color: index % 2 ? "transparent" : Util.alpha(panel.foreground, 0.04)
            border.width: 0

            RowLayout {
              anchors.fill: parent
              anchors.leftMargin: Style.space(8)
              anchors.rightMargin: Style.space(8)
              spacing: Style.space(10)

              Rectangle {
                Layout.preferredWidth: Style.space(64)
                implicitHeight: Style.space(20)
                radius: Style.space(2)
                color: "transparent"
                border.width: 1
                border.color: Util.alpha(Color.accent, 0.5)
                Text {
                  anchors.centerIn: parent
                  text: modelData.kind.toUpperCase()
                  color: Color.accent
                  font.family: panel.mono
                  font.pixelSize: Style.font.bodySmall - 1
                  font.bold: true
                }
                MouseArea { id: kh; anchors.fill: parent; hoverEnabled: true }
                PanelToolTip { visible: kh.containsMouse; text: panel.kindTip(modelData.kind) }
              }

              Column {
                Layout.preferredWidth: Style.space(150)
                Text {
                  width: parent.width
                  text: modelData.label
                  color: panel.foreground
                  elide: Text.ElideRight
                  font.family: panel.fontFamily
                  font.pixelSize: Style.font.body
                  font.bold: true
                }
                Text {
                  width: parent.width
                  text: modelData.host || "no route"
                  color: panel.dim
                  elide: Text.ElideRight
                  font.family: panel.mono
                  font.pixelSize: Style.font.bodySmall - 1
                }
              }

              // Sparkline: repaints only when a new sample lands, never per frame.
              Canvas {
                id: spark
                Layout.fillWidth: true
                Layout.fillHeight: true
                Layout.topMargin: Style.space(5)
                Layout.bottomMargin: Style.space(5)
                property var hist: modelData.history
                property color lineColor: Color.accent
                property color lossColor: Color.urgent
                onHistChanged: requestPaint()
                onWidthChanged: requestPaint()
                onPaint: {
                  var ctx = getContext("2d")
                  ctx.reset()
                  var h = hist || []
                  var n = 60
                  if (!h.length) return
                  var mx = 1
                  for (var i = 0; i < h.length; i++) if (h[i] !== null && h[i] > mx) mx = h[i]
                  var dx = width / (n - 1)
                  var off = n - h.length
                  ctx.strokeStyle = Qt.rgba(lineColor.r, lineColor.g, lineColor.b, 0.18)
                  ctx.lineWidth = 1
                  ctx.beginPath(); ctx.moveTo(0, height - 0.5); ctx.lineTo(width, height - 0.5); ctx.stroke()
                  ctx.fillStyle = Qt.rgba(lineColor.r, lineColor.g, lineColor.b, 0.12)
                  ctx.strokeStyle = lineColor
                  ctx.lineWidth = 1.5
                  var started = false
                  ctx.beginPath()
                  for (var j = 0; j < h.length; j++) {
                    var x = (off + j) * dx
                    if (h[j] === null) { started = false; continue }
                    var y = height - 2 - (h[j] / mx) * (height - 4)
                    if (!started) { ctx.moveTo(x, y); started = true } else ctx.lineTo(x, y)
                  }
                  ctx.stroke()
                  ctx.fillStyle = lossColor
                  for (var k = 0; k < h.length; k++)
                    if (h[k] === null) ctx.fillRect((off + k) * dx - 1.5, height - 4, 3, 4)
                }
                MouseArea { id: sh; anchors.fill: parent; hoverEnabled: true }
                PanelToolTip {
                  visible: sh.containsMouse
                  text: "min " + panel.fmt(modelData.min, " ms") + "   max " + panel.fmt(modelData.max, " ms")
                        + "   " + modelData.samples + " samples   recent loss " + modelData.recentLoss + "%"
                }
              }

              Text {
                Layout.preferredWidth: Style.space(64)
                horizontalAlignment: Text.AlignRight
                text: modelData.last === null ? "LOST" : panel.fmt(modelData.last, "")
                color: panel.msColor(modelData)
                font.family: panel.mono
                font.pixelSize: Style.font.body
                font.bold: true
              }
              Text {
                Layout.preferredWidth: Style.space(64)
                horizontalAlignment: Text.AlignRight
                text: panel.fmt(modelData.avg, "")
                color: panel.foreground
                font.family: panel.mono
                font.pixelSize: Style.font.bodySmall
              }
              Text {
                Layout.preferredWidth: Style.space(56)
                horizontalAlignment: Text.AlignRight
                text: panel.fmt(modelData.jitter, "")
                color: panel.dim
                font.family: panel.mono
                font.pixelSize: Style.font.bodySmall
              }
              Text {
                Layout.preferredWidth: Style.space(56)
                horizontalAlignment: Text.AlignRight
                text: modelData.loss + "%"
                color: modelData.loss > 15 ? Color.urgent : modelData.loss > 0 ? panel.warnColor : panel.dim
                font.family: panel.mono
                font.pixelSize: Style.font.bodySmall
                font.bold: modelData.loss > 0
              }
            }
          }
        }

        // ------------------------------------------------------------ footer
        Text {
          Layout.fillWidth: true
          text: "ms round trip  |  window 5 min  |  verdict uses last 30 s  |  Esc closes"
          color: panel.dim
          horizontalAlignment: Text.AlignRight
          font.family: panel.mono
          font.pixelSize: Style.font.bodySmall - 1
        }
      }
    }
  }
}
