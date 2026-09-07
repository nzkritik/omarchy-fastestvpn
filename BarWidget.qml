import QtQuick
import Quickshell
import qs.Commons
import qs.Ui

BarWidget {
  id: root
  moduleName: "nzkritik.fastestvpn"

  readonly property var shell: bar && bar.shell ? bar.shell : null
  readonly property var svc: shell ? shell.serviceFor(moduleName) : null
  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property color barForeground: bar ? bar.barForeground : Color.foreground

  readonly property string shortLabel: {
    if (!svc) return "VPN"
    if (svc.connected && svc.activeLocation)
      return String(svc.activeLocation.countryCode || "VPN").toUpperCase()
    if (svc.transitional) return "···"
    return "VPN"
  }

  readonly property color stateColor: {
    if (!svc || svc.loadError !== "") return urgent
    if (svc.connected) return barForeground
    if (svc.transitional) return Qt.darker(barForeground, 1.2)
    return Qt.darker(barForeground, 1.55)
  }

  readonly property string barTooltip: {
    if (!svc) return "FastestVPN — starting…"
    if (svc.loadError !== "") return "FastestVPN — " + svc.loadError
    if (svc.busy) return svc.actionStatus || "FastestVPN — working…"
    if (svc.connected && svc.activeLocation) {
      var l = svc.activeLocation
      var where = l.city ? (l.city + ", " + l.country) : l.country
      var t = "Connected — " + l.label + "\n" + where
      if (l.countryMismatch)
        t += "\nNote: exits in " + l.countryMismatch.measured
             + ", not " + l.countryMismatch.claimed
      return t
    }
    if (svc.activeId !== "") return "FastestVPN — connecting…"
    return "FastestVPN — disconnected\nLeft click to choose a location"
  }

  readonly property bool opened: panelLoader.item ? panelLoader.item.opened === true : false

  function injectPanel() {
    if (!svc || !panelLoader.item) return
    panelLoader.item.bar = root.bar
    panelLoader.item.settings = root.settings
    panelLoader.item.anchorItem = button
    panelLoader.item.hostWidget = root
    panelLoader.item.service = root.svc
  }

  function loadPanel() {
    if (!svc || panelLoader.status !== Loader.Null) return
    panelLoader.setSource(Qt.resolvedUrl("Panel.qml"), {
      bar: root.bar, settings: root.settings, anchorItem: button,
      hostWidget: root, service: root.svc
    })
  }

  // The service is constructed before shell.json has been read, so settings are
  // pushed in rather than pulled: this runs again on every settings change.
  function pushSettings() {
    if (!svc) return
    var seconds = Number(root.setting("refreshIntervalSec", 30)) || 30
    svc.pollInterval = Math.max(5000, Math.min(3600000, seconds * 1000))

    // An unset profile directory resolves here rather than in the manifest,
    // which cannot expand ~ or read the environment.
    var dir = String(root.setting("profileDir", "")).trim()
    if (dir === "") {
      var base = Quickshell.env("XDG_DATA_HOME")
      if (!base || base === "") base = Quickshell.env("HOME") + "/.local/share"
      dir = base + "/fastestvpn/profiles"
    }
    svc.profileDir = dir
    svc.account = String(root.setting("username", "")).trim()
  }

  function open() { if (panelLoader.item) panelLoader.item.open() }
  function close() { if (panelLoader.item) panelLoader.item.close() }
  function toggle() { if (panelLoader.item) panelLoader.item.toggle() }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  Component.onCompleted: loadPanel()
  onBarChanged: injectPanel()
  onSettingsChanged: { injectPanel(); pushSettings() }
  onSvcChanged: { loadPanel(); injectPanel(); pushSettings() }

  Loader {
    id: panelLoader
    active: root.svc !== null
    visible: false
    onLoaded: root.injectPanel()
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    tooltipText: root.barTooltip
    iconComponent: Component {
      Item {
        implicitWidth: pill.implicitWidth
        implicitHeight: pill.implicitHeight
        Row {
          id: pill
          anchors.centerIn: parent
          spacing: Math.round(Style.bar.iconCanvas * 0.22)

          Rectangle {
            anchors.verticalCenter: parent.verticalCenter
            width: Math.round(Style.bar.iconCanvas * 0.34)
            height: width
            radius: width / 2
            color: root.stateColor
            // A hollow dot while transitional reads as "not yet on" at a glance.
            border.width: root.svc && root.svc.transitional && !root.svc.connected
                          ? Math.max(1, Math.round(width * 0.22)) : 0
            border.color: root.stateColor
            Behavior on color { ColorAnimation { duration: 160 } }
          }

          Text {
            anchors.verticalCenter: parent.verticalCenter
            text: root.shortLabel
            color: root.stateColor
            font.family: Style.fontFamily
            font.pixelSize: Math.round(Style.bar.iconCanvas * 0.58)
            font.bold: root.svc ? root.svc.connected : false
          }
        }
      }
    }
    onPressed: function (buttonCode) {
      if (buttonCode === Qt.RightButton) { if (root.svc) root.svc.toggle() }
      else if (buttonCode === Qt.MiddleButton) { if (root.svc) root.svc.refresh() }
      else root.toggle()
    }
  }
}
