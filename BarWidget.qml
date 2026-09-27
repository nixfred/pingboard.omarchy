import QtQuick
import Quickshell
import qs.Commons
import qs.Ui
// A health dot plus the internet round trip. Theme accent = healthy, fixed
// amber = degraded, fixed red = down (themes may map urgent to green).
// active theme.
BarWidget {
  id: root
  moduleName: "nixfred.pingboard"
  property var anchorItem: button

  readonly property var svc: bar && bar.shell ? bar.shell.serviceFor(moduleName) : null
  readonly property bool ready: svc ? svc.ready : false
  readonly property string level: svc ? svc.level : "ok"

  function setting(name, fallback) {
    var v = settings ? settings[name] : undefined
    return v === undefined ? fallback : v
  }
  readonly property bool showMs: String(setting("showMs", true)) !== "false"
  readonly property color foreground: bar ? bar.foreground : Color.foreground

  readonly property color dotColor: !ready ? Util.alpha(foreground, 0.3)
    : level === "down" ? "#ff4d5e"
    // Fixed amber/red: some themes map urgent to green, so status never derives from it.
    : level === "warn" ? "#f5a623"
    : Color.accent

  readonly property string msText: {
    var t = svc ? svc.inet : null
    if (!ready || !t) return "--"
    return t.last === null ? "loss" : Math.round(t.last) + "ms"
  }

  readonly property real contentWidth: Style.space(showMs ? 64 : 24)
  implicitWidth: vertical ? barSize : contentWidth
  implicitHeight: vertical ? contentWidth : barSize

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: ""
    labelVisible: false
    hasVisualContent: true
    active: false
    useActiveColor: false
    tooltipText: {
      if (!root.ready) return "Pingboard: waiting for first probe"
      var lines = ["Pingboard  " + (svc.where || "") + "  " + svc.why]
      for (var i = 0; i < svc.targets.length; i++) {
        var t = svc.targets[i]
        lines.push(t.label + ": " + (t.last === null ? "lost" : t.last + " ms") + "  loss " + t.loss + "%")
      }
      return lines.join("\n")
    }

    Row {
      anchors.centerIn: parent
      spacing: Style.space(5)

      Item {
        width: Style.space(14); height: width
        anchors.verticalCenter: parent.verticalCenter
        Rectangle {
          anchors.centerIn: parent
          width: parent.width; height: width; radius: width / 2
          color: root.dotColor; border.width: 0; opacity: 0.22
        }
        Rectangle {
          anchors.centerIn: parent
          width: parent.width * 0.6; height: width; radius: width / 2
          color: root.dotColor; border.width: 0
          Behavior on color { ColorAnimation { duration: 300 } }
        }
      }

      Text {
        visible: root.showMs
        anchors.verticalCenter: parent.verticalCenter
        text: root.msText
        color: root.level === "down" ? "#ff4d5e" : root.foreground
        font.family: root.bar ? root.bar.fontFamily : Style.font.family
        font.pixelSize: Style.font.bodySmall
      }
    }

    onPressed: function(code) {
      if (root.bar) root.bar.hideTooltip(root)
      root.toggle()
    }
  }

  readonly property bool opened: panel.opened
  function open() { panel.controller.show() }
  function close() { panel.controller.hide() }
  function toggle() { opened ? close() : open() }
  function closeForPopoutSwitch() { close() }
  readonly property bool popoutSwitchClosing: false

  PingPanel {
    id: panel
    widget: root
  }
}
