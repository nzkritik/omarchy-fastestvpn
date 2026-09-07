import QtQuick
import Quickshell
import Quickshell.Io

// FastestVPN state and control.
//
// Everything here runs unprivileged. NetworkManager is the privileged half:
// its polkit default for org.freedesktop.NetworkManager.network-control is
// allow_active=yes, so bringing a VPN up or down never prompts. Credentials
// live in the desktop keyring and are piped into nmcli by bin/fvpn-connect;
// this process never sees them.
Item {
  id: root

  property var shell: null
  property int pollInterval: 30000

  // ── Location catalogue ────────────────────────────────────────────────────
  property var locations: []
  property bool locationsLoaded: false
  property string loadError: ""

  // ── Live state ────────────────────────────────────────────────────────────
  property string activeId: ""          // "" when nothing is up
  property string activeConnection: "" // the NM connection actually up
  property string activeState: ""       // nmcli GENERAL.STATE of the active conn
  property bool busy: false
  property string lastError: ""
  property string actionStatus: ""

  readonly property bool connected: activeId !== "" && activeState.indexOf("activated") === 0
  readonly property bool transitional: busy || (activeId !== "" && !connected)
  readonly property var activeLocation: locationById(activeId)

  // A location is selectable only when fully identified AND importable here.
  function isSelectable(loc) {
    return !!loc && loc.complete === true && hasTransport(loc.id, transport)
  }

  readonly property int liveCount: {
    var n = 0
    for (var i = 0; i < locations.length; i++)
      if (locations[i].complete && hasTransport(locations[i].id, transport)) n++
    return n
  }
  readonly property int notInstalledCount: {
    var n = 0
    for (var i = 0; i < locations.length; i++)
      if (locations[i].complete && !hasTransport(locations[i].id, transport)) n++
    return n
  }
  readonly property int pendingCount: {
    var n = 0
    for (var i = 0; i < locations.length; i++)
      if (locations[i].status === "pending" || locations[i].status === "no-geo") n++
    return n
  }

  // ── Endpoint catalogue refresh ────────────────────────────────────────────
  property bool updating: false
  property string updateStatus: ""
  readonly property string endpointsBin: pluginDir + "bin/fvpn-endpoints"

  // Qt hands us a file:// URL; Process needs a plain path.
  readonly property string pluginDir: {
    var u = String(Qt.resolvedUrl("."))
    return u.indexOf("file://") === 0 ? u.substring(7) : u
  }
  readonly property string connectBin: pluginDir + "bin/fvpn-connect"
  readonly property string dataFile: pluginDir + "data/locations.json"

  function locationById(id) {
    if (!id) return null
    for (var i = 0; i < locations.length; i++)
      if (locations[i].id === id) return locations[i]
    return null
  }

  // Resolve against the just-parsed array rather than through the `locations`
  // binding: reading a binding immediately after assigning its dependency can
  // still return the stale value.
  function _indexIn(list, id) {
    for (var i = 0; i < list.length; i++) if (list[i].id === id) return i
    return -1
  }

  // ── Catalogue load ────────────────────────────────────────────────────────
  // Read through dd with nofollow/nonblock and a byte bound rather than a
  // FileView: the shell is one long-lived process, and a symlink or FIFO
  // planted at this predictable path would otherwise redirect or block it.
  Process {
    id: loadProcess
    running: false
    command: ["dd", "if=" + root.dataFile, "iflag=nofollow,nonblock",
              "bs=65536", "count=16"]
    stdout: StdioCollector {
      onStreamFinished: {
        var parsed = null
        try {
          parsed = JSON.parse(text)
        } catch (e) {
          root.loadError = "locations.json is not valid JSON"
          root.locationsLoaded = true
          return
        }
        var src = (parsed && parsed.locations) || []
        var out = []
        for (var i = 0; i < src.length; i++) {
          var r = src[i]
          if (!r || typeof r.id !== "string") continue
          if (!/^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$/.test(r.id)) continue
          var lat = Number(r.latitude), lon = Number(r.longitude)
          if (!isFinite(lat) || !isFinite(lon)) continue
          if (lat < -90 || lat > 90 || lon < -180 || lon > 180) continue
          var st = String(r.status || "")
          out.push({
            id: r.id,
            connection: String(r.connection || ("fvpn-" + r.id)),
            label: String(r.label || r.id),
            country: String(r.country || ""),
            countryCode: String(r.countryCode || ""),
            city: r.city ? String(r.city) : "",
            latitude: lat,
            longitude: lon,
            precision: String(r.precision || "country"),
            kind: String(r.kind || "standard"),
            protocols: (r.protocols && r.protocols.length) ? r.protocols : ["udp"],
            status: st,
            // Only a fully-known endpoint may be chosen: resolved host,
            // reachable port and coordinates. Everything else still shows,
            // greyed, so the catalogue stays honest about what exists.
            complete: st === "complete",
            dead: st === "unreachable" || r.reachable === false,
            retired: r.retired === true,
            variantOf: r.variantOf ? String(r.variantOf) : "",
            countryMismatch: r.countryMismatch || null,
            via: r.via || null
          })
        }
        out.sort(function (a, b) { return a.label.localeCompare(b.label) })
        root.locations = out
        root.locationsLoaded = true
        root.loadError = out.length ? "" : "no usable locations in locations.json"
      }
    }
    onExited: function (code) {
      if (code !== 0 && !root.locationsLoaded) {
        root.loadError = "could not read locations.json"
        root.locationsLoaded = true
      }
    }
  }

  function reloadLocations() {
    if (loadProcess.running) return
    root.loadError = ""
    loadProcess.running = true
  }

  // ── Installed connections ─────────────────────────────────────────────────
  // The catalogue can list endpoints that upstream offers but this machine has
  // not imported (importing needs root). Those must not be selectable, or a
  // click just fails with "no such connection".
  property var installedIds: ({})     // locations with a UDP connection
  property var tcpIds: ({})           // locations with a TCP connection
  property int installedCount: 0

  // Which transport the user has chosen. A NetworkManager connection's protocol
  // is fixed at import, so switching means using a different connection.
  property string transport: "udp"

  function isInstalled(id) {
    return installedIds ? installedIds[id] === true : false
  }

  function isTcpInstalled(id) {
    return tcpIds ? tcpIds[id] === true : false
  }

  function hasTransport(id, t) {
    return t === "tcp" ? isTcpInstalled(id) : isInstalled(id)
  }

  // The NM connection name for a location under the current transport.
  function connectionFor(id) {
    return transport === "tcp" ? ("fvpn-" + id + "-tcp") : ("fvpn-" + id)
  }

  // fvpn-<id> and fvpn-<id>-tcp are the same location.
  function baseIdOf(name) {
    if (name.indexOf("fvpn-") !== 0) return ""
    var rest = name.substring(5)
    return rest.length > 4 && rest.lastIndexOf("-tcp") === rest.length - 4
      ? rest.substring(0, rest.length - 4) : rest
  }

  Process {
    id: installedProcess
    running: false
    command: ["nmcli", "--terse", "--fields", "NAME", "connection", "show"]
    stdout: StdioCollector {
      onStreamFinished: {
        var names = String(text).split("\n")
        var udp = ({}), tcp = ({})
        var n = 0
        for (var i = 0; i < names.length; i++) {
          var nm = names[i].trim()
          if (nm.indexOf("fvpn-") !== 0) continue
          var rest = nm.substring(5)
          if (rest.length > 4 && rest.lastIndexOf("-tcp") === rest.length - 4)
            tcp[rest.substring(0, rest.length - 4)] = true
          else
            udp[rest] = true
          n++
        }
        root.installedIds = udp
        root.tcpIds = tcp
        root.installedCount = n
      }
    }
  }

  function refreshInstalled() {
    if (installedProcess.running) return
    installedProcess.running = true
  }

  // ── Status refresh ────────────────────────────────────────────────────────
  Process {
    id: statusProcess
    running: false
    command: ["nmcli", "--terse", "--fields", "NAME,TYPE,STATE",
              "connection", "show", "--active"]
    stdout: StdioCollector {
      onStreamFinished: {
        var lines = String(text).split("\n")
        var foundId = ""
        var activeConn = ""
        for (var i = 0; i < lines.length; i++) {
          // NAME:TYPE:STATE — names are escaped by --terse, and ours are all
          // fvpn-<id> with no colons, so a plain split is safe here.
          var f = lines[i].split(":")
          if (f.length < 3) continue
          if (f[1] !== "vpn") continue
          if (f[0].indexOf("fvpn-") !== 0) continue
          foundId = root.baseIdOf(f[0])
          activeConn = f[0]
          break
        }
        root.activeId = foundId
        root.activeConnection = activeConn
        if (foundId === "") {
          root.activeState = ""
        } else {
          stateProcess.command = ["nmcli", "-g", "GENERAL.STATE",
                                  "connection", "show", activeConn]
          stateProcess.running = true
        }
      }
    }
  }

  Process {
    id: stateProcess
    running: false
    command: []
    stdout: StdioCollector {
      onStreamFinished: { root.activeState = String(text).trim() }
    }
  }

  function refresh() {
    if (statusProcess.running) return
    statusProcess.running = true
  }

  // ── Actions ───────────────────────────────────────────────────────────────
  Process {
    id: actionProcess
    running: false
    command: []
    property string label: ""
    stderr: StdioCollector {
      onStreamFinished: {
        var msg = String(text).trim()
        if (msg !== "") root.lastError = msg
      }
    }
    onExited: function (code) {
      root.busy = false
      root.actionStatus = code === 0 ? "" : (actionProcess.label + " failed")
      root.refresh()
    }
  }

  function connectTo(id) {
    if (busy) return
    var loc = locationById(id)
    if (!loc) { root.lastError = "unknown location: " + id; return }
    if (!isSelectable(loc)) {
      root.lastError = !loc.complete
        ? loc.label + " is not ready (" + (loc.status || "incomplete") + ")"
        : loc.label + " has no " + transport.toUpperCase() + " connection on this machine"
      return
    }
    root.lastError = ""
    root.actionStatus = "Connecting to " + loc.label + "…"
    root.busy = true
    actionProcess.label = "Connect"
    actionProcess.command = [root.connectBin, root.connectionFor(loc.id)]
    actionProcess.running = true
  }

  function disconnect() {
    if (busy) return
    root.lastError = ""
    root.actionStatus = "Disconnecting…"
    root.busy = true
    actionProcess.label = "Disconnect"
    actionProcess.command = [root.connectBin, "--down"]
    actionProcess.running = true
  }

  function toggle() {
    if (connected || activeId !== "") disconnect()
  }

  // Refresh the catalogue from upstream, then fill in anything missing.
  // Enrichment geolocates each server's own IP; it never connects through
  // them, so this is safe to run while the user is working.
  Process {
    id: updateProcess
    running: false
    command: []
    stdout: StdioCollector { }
    onExited: function (code) {
      if (updateProcess.command.length > 1 && updateProcess.command[1] === "sync" && code === 0) {
        root.updateStatus = "Filling in new endpoints\u2026"
        updateProcess.command = [root.endpointsBin, "enrich"]
        updateProcess.running = true
        return
      }
      root.updating = false
      root.updateStatus = code === 0 ? "" : "Endpoint update failed"
      root.reloadLocations()
    }
  }

  function updateEndpoints() {
    if (updating) return
    root.updating = true
    root.updateStatus = "Checking for new endpoints\u2026"
    updateProcess.command = [root.endpointsBin, "sync"]
    updateProcess.running = true
  }

  // ── Live updates ──────────────────────────────────────────────────────────
  // `nmcli monitor` is the direct analogue of `mullvad status listen`: it emits
  // a line on any connection change, so the bar reacts immediately instead of
  // waiting for the poll. The poll below is only a safety net.
  Process {
    id: monitorProcess
    command: ["nmcli", "monitor"]
    running: true
    stdout: SplitParser {
      onRead: debounce.restart()
    }
    onExited: restartMonitor.start()
  }

  Timer {
    id: restartMonitor
    interval: 5000
    repeat: false
    onTriggered: if (!monitorProcess.running) monitorProcess.running = true
  }

  Timer {
    id: debounce
    interval: 350
    repeat: false
    onTriggered: { root.refresh(); root.refreshInstalled() }
  }

  Timer {
    interval: root.pollInterval
    running: true
    repeat: true
    onTriggered: root.refresh()
  }

  Component.onCompleted: {
    reloadLocations()
    refreshInstalled()
    refresh()
  }
}
