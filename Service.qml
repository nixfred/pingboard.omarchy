import QtQuick
import Quickshell
import Quickshell.Io

// One long-running python3 prober (pingboard.py) prints a JSON line every
// interval. This service keeps only the latest line; the backend owns the
// history, stats and the LAN / ISP / DNS / tailnet verdict, so the bar and
// the panel can never disagree.
Item {
  id: root

  property var settings: ({})

  readonly property string pluginDir: decodeURIComponent(String(Qt.resolvedUrl(".")).replace(/^file:\/\/(localhost)?/, ""))

  readonly property int intervalSec: {
    var n = parseInt(String(settings && settings.intervalSec !== undefined ? settings.intervalSec : 5), 10)
    return isFinite(n) ? Math.max(2, Math.min(60, n)) : 5
  }
  readonly property string tailnetHosts: {
    var s = settings && settings.tailnetHosts !== undefined ? String(settings.tailnetHosts) : "vic,fnix,blu"
    return s.replace(/[^A-Za-z0-9_.,-]/g, "")
  }

  property bool ready: false
  property string link: ""
  property string device: ""
  property string gateway: ""
  property string prober: ""
  property string level: "ok"
  property string where: ""
  property string why: "Waiting for the first probe..."
  property var targets: []
  property double updatedAt: 0
  property string lastError: ""

  function target(id) {
    for (var i = 0; i < targets.length; i++) if (targets[i].id === id) return targets[i]
    return null
  }
  // Internet ms for the bar: Google first, Cloudflare as fallback.
  readonly property var inet: {
    var g = target("google"), c = target("cloudflare")
    if (g && g.last !== null) return g
    if (c && c.last !== null) return c
    return g
  }

  function apply(line) {
    var d
    try { d = JSON.parse(line) } catch (e) { return }
    if (!d || !d.targets) return
    link = d.link || ""
    device = d.device || ""
    gateway = d.gateway || ""
    prober = d.prober || ""
    level = d.verdict ? d.verdict.level : "ok"
    where = d.verdict ? d.verdict.where : ""
    why = d.verdict ? d.verdict.why : ""
    targets = d.targets
    updatedAt = Date.now()
    ready = true
  }

  Process {
    id: proc
    command: ["python3", root.pluginDir + "pingboard.py",
              "--interval", String(root.intervalSec),
              "--tailnet", root.tailnetHosts]
    running: true
    stdout: SplitParser {
      splitMarker: "\n"
      onRead: function(line) { root.apply(line) }
    }
    stderr: SplitParser {
      splitMarker: "\n"
      onRead: function(line) { root.lastError = line; console.warn("pingboard:", line) }
    }
    onRunningChanged: if (!running) respawn.restart()
  }

  // Settings changes alter the command; restart the prober so they apply.
  onIntervalSecChanged: restart()
  onTailnetHostsChanged: restart()
  function restart() { proc.running = false; respawn.restart() }

  // Crash or settings change: come back after a short pause, never a tight loop.
  Timer { id: respawn; interval: 3000; onTriggered: if (!proc.running) proc.running = true }
}
