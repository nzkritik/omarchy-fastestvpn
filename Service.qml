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

  // ── Configuration ─────────────────────────────────────────────────────────
  // Pushed in from the bar widget's shell.json entry. The profile directory is
  // where .ovpn files live and is the source of truth for which endpoints
  // exist at all; the account is the VPN username the keyring credential
  // belongs to.
  property string profileDir: ""
  property string account: ""
  readonly property bool configured: profileDir !== "" && account !== ""

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

  // ── Endpoint verdicts ─────────────────────────────────────────────────────
  // Written by bin/fvpn-connect, one entry per real connect attempt. This is
  // the ONLY thing that marks an endpoint unavailable. Nothing probes in the
  // background: every probe costs an authentication against an account that
  // rate-limits, and a sweep of them once got this account blocked for a day.
  //
  // `auth` verdicts are deliberately not treated as unavailability. FastestVPN
  // answers AUTH_FAILED both for a wrong password and for too many concurrent
  // sessions, so believing it would condemn healthy endpoints the moment the
  // account is throttled.
  property var endpointState: ({})

  function verdictFor(id) {
    var v = endpointState ? endpointState[id] : null
    return (v && typeof v === "object") ? v : null
  }

  function isUnavailable(id) {
    var v = verdictFor(id)
    return !!v && v.result === "unreachable"
  }

  // Selectable means: present in the profile directory and imported here under
  // the current transport, not retired upstream, and not already proven broken
  // by a real connect. The catalogue's own `status` no longer gates anything —
  // it came from a TCP probe with known false positives, and judging endpoints
  // without connecting is exactly what this rework removed.
  function isSelectable(loc) {
    return !!loc && loc.retired !== true
        && hasTransport(loc.id, transport) && !isUnavailable(loc.id)
  }

  readonly property int liveCount: {
    var n = 0
    for (var i = 0; i < allLocations.length; i++)
      if (isSelectable(allLocations[i])) n++
    return n
  }
  readonly property int notInstalledCount: {
    var n = 0
    for (var i = 0; i < allLocations.length; i++)
      if (!allLocations[i].retired && !hasTransport(allLocations[i].id, transport)) n++
    return n
  }
  // Every location dialable on this transport, working or not. liveCount plus
  // unavailableHereCount equals this, so the three numbers the panel shows are
  // consistent with one another.
  readonly property int importedCount: {
    var n = 0
    for (var i = 0; i < allLocations.length; i++)
      if (!allLocations[i].retired && hasTransport(allLocations[i].id, transport)) n++
    return n
  }

  // Flagged unavailable AND present on this transport. The panel's chip counts
  // this rather than every verdict on record, or the arithmetic would not add
  // up on a transport where some of the failed endpoints are not imported.
  readonly property int unavailableHereCount: {
    var n = 0
    for (var i = 0; i < allLocations.length; i++) {
      var l = allLocations[i]
      if (!l.retired && hasTransport(l.id, transport) && isUnavailable(l.id)) n++
    }
    return n
  }

  // Every verdict on record, regardless of transport — what the settings screen
  // offers to clear.
  readonly property int unavailableCount: {
    var n = 0
    for (var i = 0; i < allLocations.length; i++)
      if (isUnavailable(allLocations[i].id)) n++
    return n
  }

  // ── Profile management ────────────────────────────────────────────────────
  property bool updating: false
  property string updateStatus: ""
  property int profileCount: 0
  property bool credentialPresent: false
  readonly property string fetchBin: pluginDir + "bin/fvpn-fetch-profiles"
  readonly property string importBin: pluginDir + "bin/fvpn-import-profiles"
  readonly property string credsBin: pluginDir + "bin/fvpn-creds"

  // Qt hands us a file:// URL; Process needs a plain path.
  readonly property string pluginDir: {
    var u = String(Qt.resolvedUrl("."))
    return u.indexOf("file://") === 0 ? u.substring(7) : u
  }
  readonly property string connectBin: pluginDir + "bin/fvpn-connect"
  readonly property string dataFile: pluginDir + "data/locations.json"

  function locationById(id) {
    if (!id) return null
    var all = allLocations
    for (var i = 0; i < all.length; i++)
      if (all[i].id === id) return all[i]
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
            // Informational only. Availability is decided by real connect
            // verdicts in `endpointState`, never by this field.
            status: st,
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

  // ── Endpoint verdict state ────────────────────────────────────────────────
  // Same guarded read as the catalogue: this path is predictable and lives
  // under $HOME, so anything running as this user could plant a symlink or a
  // FIFO there. nofollow refuses the link, nonblock refuses to wedge on the
  // FIFO, and the count bounds a swollen file.
  readonly property string stateFile: {
    var base = Quickshell.env("XDG_STATE_HOME")
    if (!base || base === "") base = Quickshell.env("HOME") + "/.local/state"
    return base + "/fastestvpn/endpoints.json"
  }

  Process {
    id: stateLoadProcess
    running: false
    command: ["dd", "if=" + root.stateFile, "iflag=nofollow,nonblock",
              "bs=65536", "count=8"]
    stdout: StdioCollector {
      onStreamFinished: {
        var parsed = null
        try { parsed = JSON.parse(text) } catch (e) { return }
        var src = (parsed && parsed.endpoints) || {}
        var out = ({})
        for (var id in src) {
          // Ids reach the UI and are compared against catalogue entries; a
          // crafted key must not slip through just because it parsed as JSON.
          if (!/^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$/.test(id)) continue
          var v = src[id]
          if (!v || typeof v !== "object") continue
          var res = String(v.result || "")
          if (["ok", "unreachable", "auth", "inconclusive"].indexOf(res) < 0) continue
          out[id] = {
            result: res,
            at: String(v.at || ""),
            detail: String(v.detail || "").substring(0, 200),
            failures: Number(v.failures) || 0
          }
        }
        root.endpointState = out
      }
    }
    // A missing file is the normal first-run case, not an error: no attempt
    // has been made yet, so nothing is known and nothing is marked bad.
    onExited: function (code) { if (code !== 0) root.endpointState = ({}) }
  }

  function reloadEndpointState() {
    if (stateLoadProcess.running) return
    stateLoadProcess.running = true
  }

  // Forget a recorded failure so the endpoint becomes selectable again. The
  // user needs this: a verdict can be collateral damage from a throttled
  // account or a dropped uplink, and without a way back an endpoint would be
  // condemned forever by one bad evening.
  function clearVerdict(id) {
    if (!id) return
    var next = ({})
    for (var k in endpointState) if (k !== id) next[k] = endpointState[k]
    root.endpointState = next
    clearProcess.command = ["python3", "-c",
      "import json,os,sys,tempfile\n" +
      "p=sys.argv[1]; i=sys.argv[2]\n" +
      "try:\n" +
      "    d=json.load(open(p))\n" +
      "except Exception:\n" +
      "    sys.exit(0)\n" +
      "e=d.get('endpoints') or {}\n" +
      "e.pop(i,None); d['endpoints']=e\n" +
      "fd,t=tempfile.mkstemp(dir=os.path.dirname(p))\n" +
      "os.write(fd, json.dumps(d, indent=2, sort_keys=True).encode()); os.close(fd)\n" +
      "os.chmod(t,0o600); os.replace(t,p)\n",
      root.stateFile, id]
    clearProcess.running = true
  }

  Process { id: clearProcess; running: false; command: [] }

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

  // Connections that exist here but are absent from the shipped catalogue —
  // which is exactly what a profile the user dropped in themselves looks like.
  // Without this they would import fine and then never appear in the list,
  // making "add your own .ovpn" a feature that silently does nothing.
  // They carry no coordinates, so the map skips them and the list does not.
  readonly property var extraLocations: {
    var out = []
    var seen = ({})
    for (var i = 0; i < locations.length; i++) seen[locations[i].id] = true
    var ids = []
    for (var a in installedIds) if (!seen[a]) ids.push(a)
    for (var b in tcpIds) if (!seen[b] && ids.indexOf(b) < 0) ids.push(b)
    ids.sort()
    for (var j = 0; j < ids.length; j++) {
      out.push({
        id: ids[j],
        connection: "fvpn-" + ids[j],
        label: ids[j],
        country: "", countryCode: "", city: "",
        latitude: NaN, longitude: NaN,
        precision: "none", kind: "custom", protocols: ["udp"],
        status: "", retired: false, variantOf: "",
        countryMismatch: null, via: null,
        custom: true
      })
    }
    return out
  }

  // Everything user-facing iterates this, not `locations`.
  //
  // The geo table fills in position for everything the catalogue does not
  // already KNOW, but it does not overrule what was measured by connecting.
  //
  // The two answer different questions. Geolocating the server's IP says where
  // you ENTER the provider's network; connecting through it and looking at the
  // exit address says where you APPEAR. Usually the same place — but `russia`
  // registers in Moscow and exits in Stockholm, and `switzerland-via-usa`
  // enters at Chicago and exits in Los Angeles. Letting the cheap lookup
  // overwrite a measured exit would silently replace a fact with a guess, so
  // `precision: "measured"` entries keep their coordinates and only pick up
  // the network details.
  readonly property var allLocations: {
    var base = locations.concat(extraLocations)
    if (!geoById) return base
    var out = []
    for (var i = 0; i < base.length; i++) {
      var l = base[i]
      var g = geoById[l.id]
      if (!g) { out.push(l); continue }
      var m = ({})
      for (var k in l) m[k] = l[k]
      m.ip = g.ip
      m.asName = g.asName
      m.endpointHost = g.endpoint
      m.entryCity = g.city
      m.entryCountryCode = g.countryCode
      if (l.precision !== "measured") {
        m.latitude = g.latitude
        m.longitude = g.longitude
        if (g.city) m.city = g.city
        if (g.country) m.country = g.country
        if (g.countryCode) m.countryCode = g.countryCode
        m.region = g.region
        // Located from the server's own address, not by connecting through it.
        m.precision = "server"
      }
      out.push(m)
    }
    return out
  }

  // ── Endpoint geolocation ──────────────────────────────────────────────────
  // Built by bin/fvpn-geolocate from each profile's remote host. Keyed by
  // catalogue id: the udp and tcp variants of an endpoint share a server, so
  // they share a location.
  property var geoById: ({})
  property int geoCount: 0
  readonly property string geoBin: pluginDir + "bin/fvpn-geolocate"
  readonly property string geoFile: {
    var base = Quickshell.env("XDG_DATA_HOME")
    if (!base || base === "") base = Quickshell.env("HOME") + "/.local/share"
    return base + "/fastestvpn/endpoints-geo.json"
  }

  Process {
    id: geoLoadProcess
    running: false
    command: ["dd", "if=" + root.geoFile, "iflag=nofollow,nonblock",
              "bs=65536", "count=16"]
    stdout: StdioCollector {
      onStreamFinished: {
        var parsed = null
        try { parsed = JSON.parse(text) } catch (e) { return }
        var rows = (parsed && parsed.rows) || []
        var out = ({})
        var n = 0
        for (var i = 0; i < rows.length; i++) {
          var r = rows[i]
          if (!r || typeof r.id !== "string") continue
          if (!/^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$/.test(r.id)) continue
          var lat = Number(r.latitude), lon = Number(r.longitude)
          if (!isFinite(lat) || !isFinite(lon)) continue
          if (lat < -90 || lat > 90 || lon < -180 || lon > 180) continue
          if (out[r.id]) continue          // udp and tcp rows agree; take the first
          out[r.id] = {
            latitude: lat,
            longitude: lon,
            city: String(r.city_name || ""),
            region: String(r.region_name || ""),
            country: String(r.country_name || ""),
            countryCode: String(r.country_code || ""),
            ip: String(r.ip || ""),
            asName: String(r["as"] || ""),
            endpoint: String(r.endpoint || "")
          }
          n++
        }
        root.geoById = out
        root.geoCount = n
      }
    }
    onExited: function (code) {
      if (code !== 0) { root.geoById = ({}); root.geoCount = 0 }
    }
  }

  function reloadGeo() {
    if (geoLoadProcess.running) return
    geoLoadProcess.running = true
  }

  // Locate endpoints that have no entry yet. Safe to run at any time: it asks
  // a geolocation API about each server's IP and never connects to a VPN, so
  // it spends no authentication against the account.
  Process {
    id: geoProcess
    running: false
    command: []
    stdout: SplitParser {
      // The script prints one line per lookup; surface the last as progress.
      onRead: function (line) {
        var t = String(line).trim()
        if (t.indexOf("[") === 0) root.updateStatus = t
      }
    }
    stderr: StdioCollector {
      onStreamFinished: {
        var msg = String(text).trim()
        if (msg !== "") root.lastError = msg
      }
    }
    onExited: function (code) {
      root.updating = false
      root.updateStatus = code === 0 ? "Locations updated" : "Could not locate endpoints"
      root.reloadGeo()
    }
  }

  function geolocate(all) {
    if (updating || profileDir === "") return
    root.lastError = ""
    root.updating = true
    root.updateStatus = "Locating endpoints…"
    var cmd = [root.geoBin, "--dir", root.profileDir]
    if (all === true) cmd.push("--all")
    geoProcess.command = cmd
    geoProcess.running = true
  }

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
      // A connect attempt is the moment a verdict gets written, so pick it up
      // straight away — this is what turns a failed click into a location
      // greying out, with no probing anywhere.
      root.reloadEndpointState()
      root.refresh()
    }
  }

  function connectTo(id) {
    if (busy) return
    var loc = locationById(id)
    if (!loc) { root.lastError = "unknown location: " + id; return }
    if (!hasTransport(loc.id, transport)) {
      root.lastError = loc.label + " has no " + transport.toUpperCase()
                     + " connection on this machine — import profiles in settings"
      return
    }
    root.lastError = ""
    root.actionStatus = "Connecting to " + loc.label + "…"
    root.busy = true
    actionProcess.label = "Connect"
    // The configured account overrides whatever the connection was imported
    // with, so changing it in settings does not mean reimporting everything.
    actionProcess.environment = root.account !== ""
      ? ({ "FVPN_ACCOUNT": root.account }) : ({})
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

  // \u2500\u2500 Profile directory \u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500
  // How many .ovpn files the configured directory holds. Counted rather than
  // listed: the panel only needs to tell the user whether the directory looks
  // populated, and reading 150 filenames into QML to display one number is
  // waste.
  Process {
    id: countProcess
    running: false
    command: []
    stdout: StdioCollector {
      onStreamFinished: { root.profileCount = Number(String(text).trim()) || 0 }
    }
    onExited: function (code) { if (code !== 0) root.profileCount = 0 }
  }

  function refreshProfileCount() {
    if (countProcess.running || profileDir === "") return
    // -maxdepth 1 -type f excludes symlinks and subdirectories, matching
    // exactly what the importer will agree to read.
    countProcess.command = ["sh", "-c",
      "find \"$1\" -maxdepth 1 -type f -name '*.ovpn' 2>/dev/null | wc -l",
      "sh", profileDir]
    countProcess.running = true
  }

  // \u2500\u2500 Credential status \u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500
  Process {
    id: credStatusProcess
    running: false
    command: []
    onExited: function (code) { root.credentialPresent = (code === 0) }
  }

  function refreshCredential() {
    if (credStatusProcess.running || account === "") {
      if (account === "") root.credentialPresent = false
      return
    }
    credStatusProcess.environment = ({ "FVPN_ACCOUNT": root.account })
    credStatusProcess.command = [root.credsBin, "status"]
    credStatusProcess.running = true
  }

  // Store the password in the keyring. It goes in on stdin and is never held
  // in a QML property, never placed in argv, and never written to disk.
  Process {
    id: credStoreProcess
    running: false
    command: []
    stdinEnabled: true
    onExited: function (code) {
      root.updating = false
      root.updateStatus = code === 0 ? "Password saved" : "Could not save the password"
      root.refreshCredential()
    }
  }

  function storeCredential(password) {
    if (updating || account === "" || !password) return
    root.updating = true
    root.updateStatus = "Saving password\u2026"
    credStoreProcess.environment = ({ "FVPN_ACCOUNT": root.account })
    credStoreProcess.command = [root.credsBin, "store", "--stdin"]
    credStoreProcess.running = true
    credStoreProcess.write(password + "\n")
    credStoreProcess.stdinEnabled = false   // EOF, so the script stops reading
  }

  // \u2500\u2500 Fetching and importing profiles \u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500
  // Two separate steps on purpose. Fetching is unprivileged and just fills a
  // directory; importing needs root, so it is the only thing that ever raises
  // a polkit prompt. Neither one connects to anything.
  Process {
    id: fetchProcess
    running: false
    command: []
    stderr: StdioCollector {
      onStreamFinished: {
        var msg = String(text).trim()
        if (msg !== "") root.lastError = msg
      }
    }
    onExited: function (code) {
      root.updating = false
      root.updateStatus = code === 0 ? "Profiles updated" : "Could not fetch profiles"
      root.refreshProfileCount()
    }
  }

  function fetchProfiles() {
    if (updating || profileDir === "") return
    root.lastError = ""
    root.updating = true
    root.updateStatus = "Downloading profiles\u2026"
    fetchProcess.command = [root.fetchBin, "--dir", root.profileDir]
    fetchProcess.running = true
  }

  Process {
    id: importProcess
    running: false
    command: []
    stderr: StdioCollector {
      onStreamFinished: {
        var msg = String(text).trim()
        if (msg !== "") root.lastError = msg
      }
    }
    onExited: function (code) {
      root.updating = false
      // rc 126/127 is pkexec's "dismissed or not authorised", which is a user
      // decision rather than a failure worth shouting about.
      root.updateStatus = code === 0 ? "Profiles imported"
                        : (code === 126 || code === 127) ? "Import cancelled"
                        : "Import failed"
      root.refreshInstalled()
      // A fresh import is the moment new endpoints appear, and locating them
      // costs nothing but an API call each — so do it now rather than leaving
      // the map empty until the user finds the button.
      if (code === 0) root.geolocate(false)
    }
  }

  function importProfiles() {
    if (updating || !configured) return
    root.lastError = ""
    root.updating = true
    root.updateStatus = "Importing into NetworkManager\u2026"
    importProcess.command = ["pkexec", "bash", root.importBin,
                             "--dir", root.profileDir,
                             "--user", Quickshell.env("USER") || "",
                             "--account", root.account]
    importProcess.running = true
  }

  // Copy user-supplied .ovpn files into the profile directory. The picker
  // returns newline-separated absolute paths; cp is given them as arguments
  // rather than interpolated into a shell string.
  Process {
    id: addProcess
    running: false
    command: []
    onExited: function (code) {
      root.updating = false
      root.updateStatus = code === 0 ? "Profiles added" : "Could not add profiles"
      root.refreshProfileCount()
    }
  }

  function addProfiles(paths) {
    if (updating || profileDir === "" || !paths || paths.length === 0) return
    root.updating = true
    root.updateStatus = "Adding profiles\u2026"
    var cmd = ["cp", "-n", "--no-dereference", "--preserve=mode"]
    for (var i = 0; i < paths.length; i++) {
      // Only accept plain absolute paths ending in .ovpn. The picker is
      // trusted, but this is the boundary where a path becomes an argument.
      if (/^\/[^\0]*\.ovpn$/.test(paths[i])) cmd.push(paths[i])
    }
    if (cmd.length === 4) { root.updating = false; root.updateStatus = "No .ovpn files chosen"; return }
    cmd.push(root.profileDir)
    addProcess.command = cmd
    addProcess.running = true
  }

  // zenity rather than a QML FileDialog: the panel is a layer-shell surface,
  // and a Qt modal parented to it does not reliably take keyboard focus.
  Process {
    id: browseProcess
    running: false
    command: ["zenity", "--file-selection", "--multiple", "--separator=\n",
              "--title=Add OpenVPN profiles", "--file-filter=OpenVPN profiles | *.ovpn"]
    stdout: StdioCollector {
      onStreamFinished: {
        var picked = String(text).trim()
        if (picked === "") return
        root.addProfiles(picked.split("\n"))
      }
    }
  }

  function browseForProfiles() {
    if (browseProcess.running || profileDir === "") return
    browseProcess.running = true
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

  // Configuration arrives after construction (the bar pushes it once shell.json
  // is read), so re-derive anything that depends on it whenever it changes.
  onProfileDirChanged: refreshProfileCount()
  onAccountChanged: refreshCredential()

  Component.onCompleted: {
    reloadLocations()
    reloadEndpointState()
    reloadGeo()
    refreshInstalled()
    refresh()
  }
}
