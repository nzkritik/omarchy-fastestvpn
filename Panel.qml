import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// `Panel` owns only the open/close state. The visible surface is the
// KeyboardPanel below, bound to `open: root.opened` — content placed directly
// in the Panel item would render nowhere, since the host Loader is invisible.
Panel {
  id: root

  moduleName: "nzkritik.fastestvpn"
  ipcTarget: moduleName
  manageIpc: false          // this file provides its own IpcHandler instead

  property var anchorItem: null
  property var hostWidget: null
  property var service: null

  property string query: ""
  property bool showUnavailable: false
  property bool configOpen: false

  // Persist one key back into this widget's shell.json entry. The host owns
  // the file; updateEntryInline merges into the existing entry and rewrites it,
  // which then flows back down as a settings change.
  function writeSetting(key, value) {
    var host = root.bar && root.bar.shell ? root.bar.shell : null
    if (!host || typeof host.updateEntryInline !== "function") return
    var next = ({})
    for (var k in root.settings) next[k] = root.settings[k]
    next[key] = value
    host.updateEntryInline(root.moduleName, next)
  }

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property color accent: Color.accent
  readonly property color dim: Qt.darker(foreground, 1.5)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  readonly property bool hideUnavailable: setting("hideUnavailable", true) !== false

  readonly property var rows: {
    var all = service ? service.allLocations : []
    var q = query.trim().toLowerCase()
    var out = []
    for (var i = 0; i < all.length; i++) {
      var l = all[i]
      if (l.retired) continue
      // Two different reasons a row can be missing, and they deserve different
      // treatment. Not imported: nothing to click, so hide it unless asked.
      // Proven unavailable: hide it only if the user wants it hidden, since
      // seeing what failed is often the point.
      var imported = service.hasTransport(l.id, service.transport)
      var bad = service.isUnavailable(l.id)
      if (!imported && !showUnavailable) continue
      if (bad && hideUnavailable && !showUnavailable) continue
      if (q !== "") {
        var hay = (l.label + " " + l.country + " " + l.city + " " + l.countryCode).toLowerCase()
        if (hay.indexOf(q) < 0) continue
      }
      out.push(l)
    }
    return out
  }

  // A profile the user added themselves has no coordinates, so it belongs in
  // the list but cannot be plotted. Filtering here rather than inside WorldMap
  // keeps the map free of "what if there is no position" special cases.
  readonly property var mappable: {
    var out = []
    for (var i = 0; i < rows.length; i++)
      if (isFinite(rows[i].latitude) && isFinite(rows[i].longitude)) out.push(rows[i])
    return out
  }

  readonly property var activeLoc: service ? service.activeLocation : null

  function connectRow(loc) {
    if (!service || !loc) return
    if (service.activeId === loc.id) { service.disconnect(); return }
    if (!service.hasTransport(loc.id, service.transport)) return  // nothing to dial
    // Asking for a location that was marked unavailable is the retry path:
    // drop the old verdict so this attempt is judged on its own.
    if (service.isUnavailable(loc.id)) service.clearVerdict(loc.id)
    service.connectTo(loc.id)
  }


  IpcHandler {
    target: root.ipcTarget
    function open(): void { root.open() }
    function close(): void { root.close() }
    function toggle(): void { root.toggle() }
    function refresh(): string { if (root.service) root.service.refresh(); return "ok" }
    function disconnect(): string { if (root.service) root.service.disconnect(); return "ok" }
    function connect(id: string): string {
      if (!root.service) return "no service"
      root.service.connectTo(String(id))
      return "ok"
    }
    function status(): string {
      if (!root.service) return "{}"
      var l = root.service.activeLocation
      return JSON.stringify({
        connected: root.service.connected,
        id: root.service.activeId,
        label: l ? l.label : "",
        country: l ? l.country : "",
        city: l ? l.city : "",
        catalogue: root.service.allLocations.length,
        selectable: root.service.liveCount,
        unavailable: root.service.unavailableCount,
        notImported: root.service.notInstalledCount,
        shown: root.rows.length,
        lastError: root.service.lastError
      })
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.hostWidget || root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher

    contentWidth: Style.space(520)
    contentHeight: Math.max(Style.space(260),
                            Math.min(availableCardHeight, Style.space(640)))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onCloseRequested: root.close()
      onActivateRequested: if (root.service && root.service.connected) root.service.disconnect()
    }

    ColumnLayout {
      anchors.fill: parent
      spacing: Style.space(10)

      // ── Title ─────────────────────────────────────────────────────────────
      // Names the provider explicitly: several VPN plugins can sit on the same
      // bar, and a panel showing only "Not connected" is ambiguous between them.
      RowLayout {
        Layout.fillWidth: true
        spacing: Style.space(8)

        Text {
          text: "FastestVPN"
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.space(12)
          font.bold: true
          font.letterSpacing: 0.6
        }

        Rectangle {
          Layout.fillWidth: true
          Layout.alignment: Qt.AlignVCenter
          height: 1
          color: Util.alpha(root.foreground, 0.16)
        }

        Text {
          visible: text !== "" && !root.configOpen
          text: root.service ? (root.service.liveCount + " locations") : ""
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.space(10)
        }

        // Gear. Drawn rather than pulled from an icon font, so it cannot come
        // out as a missing glyph on a system without one installed.
        Item {
          visible: !root.configOpen
          Layout.alignment: Qt.AlignVCenter
          implicitWidth: Style.space(18)
          implicitHeight: Style.space(18)
          opacity: gearHover.hovered ? 1.0 : 0.65

          HoverHandler { id: gearHover }
          TapHandler { onTapped: root.configOpen = true }

          Rectangle {
            anchors.centerIn: parent
            width: Style.space(12); height: width; radius: width / 2
            color: "transparent"
            border.width: Math.max(1, Style.space(2))
            border.color: root.foreground
          }
          Repeater {
            model: 4
            Rectangle {
              required property int index
              anchors.centerIn: parent
              width: Style.space(16)
              height: Math.max(1, Style.space(2))
              radius: height / 2
              color: root.foreground
              rotation: index * 45
            }
          }
          Rectangle {
            anchors.centerIn: parent
            width: Style.space(8); height: width; radius: width / 2
            color: root.bar ? root.bar.background : Color.background
          }
        }
      }

      // ── Status ────────────────────────────────────────────────────────────
      RowLayout {
        visible: !root.configOpen
        Layout.fillWidth: true
        spacing: Style.space(10)

        Rectangle {
          Layout.alignment: Qt.AlignVCenter
          width: Style.space(12); height: width; radius: width / 2
          color: root.service && root.service.connected ? root.accent : root.dim
        }

        ColumnLayout {
          Layout.fillWidth: true
          spacing: 0
          Text {
            Layout.fillWidth: true
            text: root.service && root.service.connected && root.activeLoc
                  ? root.activeLoc.label : "Not connected"
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.space(15)
            font.bold: true
            elide: Text.ElideRight
          }
          Text {
            Layout.fillWidth: true
            visible: text !== ""
            text: {
              if (!root.service) return ""
              if (root.service.busy) return root.service.actionStatus
              if (root.service.lastError !== "") return root.service.lastError
              if (root.service.connected && root.activeLoc) {
                var l = root.activeLoc
                var s = l.city ? (l.city + ", " + l.country) : l.country
                if (l.countryMismatch)
                  s += "  ·  exits " + l.countryMismatch.measured
                       + ", not " + l.countryMismatch.claimed
                return s
              }
              return "Choose a location below"
            }
            color: root.service && root.service.lastError !== "" ? root.urgent : root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.space(11)
            elide: Text.ElideRight
          }
        }

        Button {
          visible: root.service && (root.service.connected || root.service.activeId !== "")
          enabled: root.service && !root.service.busy
          text: "Disconnect"
          onClicked: if (root.service) root.service.disconnect()
        }

      }

      // ── Map ───────────────────────────────────────────────────────────────
      Rectangle {
        visible: !root.configOpen
        Layout.fillWidth: true
        Layout.preferredHeight: Style.space(190)
        radius: Style.space(6)
        color: Util.alpha(root.foreground, 0.05)
        clip: true

        WorldMap {
          anchors.fill: parent
          anchors.margins: Style.space(4)
          locations: root.mappable
          connectedPoint: root.service && root.service.connected && root.activeLoc
                          && isFinite(root.activeLoc.latitude) ? root.activeLoc : null
          foreground: root.foreground
          accent: root.accent
        }
      }

      // ── Search ────────────────────────────────────────────────────────────
      TextField {
        id: search
        visible: !root.configOpen
        Layout.fillWidth: true
        placeholderText: "Search locations…"
        onTextChanged: root.query = text
        font.family: root.fontFamily
      }

      // ── Filter ────────────────────────────────────────────────────────────
      Row {
        visible: !root.configOpen
        Layout.fillWidth: true
        spacing: Style.space(6)

        Repeater {
          model: ["udp", "tcp"]
          Rectangle {
            required property var modelData
            readonly property bool on: root.service && root.service.transport === modelData
            readonly property int count: {
              if (!root.service) return 0
              var n = 0
              for (var i = 0; i < root.service.allLocations.length; i++) {
                var l = root.service.allLocations[i]
                if (!l.retired && root.service.hasTransport(l.id, modelData)) n++
              }
              return n
            }
            radius: height / 2
            height: Style.space(22)
            width: tText.implicitWidth + Style.space(18)
            color: on ? Util.alpha(root.accent, 0.22) : Util.alpha(root.foreground, 0.07)
            border.width: on ? 1 : 0
            border.color: Util.alpha(root.accent, 0.65)
            opacity: count > 0 ? 1 : 0.4
            Text {
              id: tText
              anchors.centerIn: parent
              text: parent.modelData.toUpperCase() + "  " + parent.count
              color: parent.on ? root.foreground : root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.space(11)
            }
            TapHandler {
              // Switching transport while connected would leave the old
              // connection up under a stale label, so drop it first.
              onTapped: {
                if (!root.service || parent.count === 0) return
                if (root.service.connected) root.service.disconnect()
                root.service.transport = parent.modelData
              }
            }
          }
        }

        Rectangle {
          radius: height / 2
          height: Style.space(22)
          width: unavailText.implicitWidth + Style.space(18)
          color: root.showUnavailable ? Util.alpha(root.urgent, 0.20)
                                      : Util.alpha(root.foreground, 0.07)
          border.width: root.showUnavailable ? 1 : 0
          border.color: Util.alpha(root.urgent, 0.65)
          Text {
            id: unavailText
            anchors.centerIn: parent
            text: "Show unavailable"
            color: root.showUnavailable ? root.foreground : root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.space(11)
          }
          TapHandler { onTapped: root.showUnavailable = !root.showUnavailable }
        }
      }

      // ── Locations ─────────────────────────────────────────────────────────
      ListView {
        id: list
        visible: !root.configOpen
        Layout.fillWidth: true
        Layout.fillHeight: true
        clip: true
        model: root.rows
        spacing: Style.space(1)
        currentIndex: -1
        ScrollBar.vertical: ScrollBar { }

        delegate: Rectangle {
          id: row
          required property var modelData
          width: list.width
          height: Style.space(40)
          radius: Style.space(4)
          readonly property bool isActive: root.service && root.service.activeId === modelData.id
          readonly property bool unavailable: root.service ? root.service.isUnavailable(modelData.id) : false
          readonly property bool imported: root.service ? root.service.hasTransport(modelData.id, root.service.transport) : false
          // An unavailable row stays clickable: retrying is a deliberate user
          // action, and it is the only way back from a verdict that was really
          // a throttled account or a dropped uplink.
          readonly property bool usable: imported || isActive
          opacity: usable ? 1.0 : 0.45
          color: (hover.hovered && usable) ? Util.alpha(root.foreground, 0.08)
               : (isActive ? Util.alpha(root.accent, 0.16) : "transparent")

          HoverHandler { id: hover; enabled: row.usable }
          TapHandler { onTapped: root.connectRow(row.modelData) }

          RowLayout {
            anchors.fill: parent
            anchors.leftMargin: Style.space(10)
            anchors.rightMargin: Style.space(10)
            spacing: Style.space(8)

            Rectangle {
              Layout.alignment: Qt.AlignVCenter
              width: Style.space(7); height: width; radius: width / 2
              color: row.isActive ? root.accent : root.dim
              opacity: row.unavailable ? 0.35 : 1
            }

            ColumnLayout {
              Layout.fillWidth: true
              spacing: 0
              Text {
                Layout.fillWidth: true
                text: row.modelData.label
                color: row.unavailable ? root.dim : root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.space(13)
                elide: Text.ElideRight
              }
              Text {
                Layout.fillWidth: true
                visible: text !== ""
                text: {
                  var bits = []
                  if (row.modelData.custom) return "added by you"
                  if (row.modelData.city) bits.push(row.modelData.city)
                  if (row.modelData.precision !== "measured") bits.push("approx.")
                  if (row.modelData.countryMismatch)
                    bits.push("exits " + row.modelData.countryMismatch.measured)
                  return bits.join("  ·  ")
                }
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.space(10)
                elide: Text.ElideRight
              }
            }

            Text {
              visible: text !== ""
              text: {
                if (!root.service) return ""
                if (!row.imported) return "not imported"
                var v = root.service.verdictFor(row.modelData.id)
                if (!v) return ""
                if (v.result === "unreachable")
                  return v.failures > 1 ? ("unavailable \u00d7" + v.failures) : "unavailable"
                if (v.result === "auth") return "auth refused"
                return ""
              }
              color: root.urgent
              font.family: root.fontFamily
              font.pixelSize: Style.space(10)
            }
          }
        }
      }

      Text {
        Layout.fillWidth: true
        visible: !root.configOpen && text !== ""
        text: {
          if (!root.service) return ""
          if (root.service.updating) return root.service.updateStatus
          if (root.service.installedCount === 0)
            return "No profiles imported yet \u2014 open settings to get started"
          return ""
        }
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.space(10)
        elide: Text.ElideRight
      }

      Text {
        Layout.fillWidth: true
        visible: !root.configOpen && root.service && root.service.loadError !== ""
        text: root.service ? root.service.loadError : ""
        color: root.urgent
        font.family: root.fontFamily
        font.pixelSize: Style.space(10)
        wrapMode: Text.WordWrap
      }

      // ── Settings ──────────────────────────────────────────────────────────
      ConfigView {
        visible: root.configOpen
        Layout.fillWidth: true
        Layout.fillHeight: true
        service: root.service
        foreground: root.foreground
        urgent: root.urgent
        accent: root.accent
        dim: root.dim
        fontFamily: root.fontFamily
        onSettingChanged: function (key, value) { root.writeSetting(key, value) }
        onCloseRequested: root.configOpen = false
      }
    }
  }
}
