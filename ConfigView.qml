import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import qs.Commons
import qs.Ui

// The plugin's settings screen, shown in place of the location list.
//
// Everything here writes back into this widget's entry in shell.json through
// the host's updateEntryInline, EXCEPT the password: that goes straight to the
// desktop keyring and is never persisted by the shell. The password field is
// bound to nothing and is cleared the moment it has been handed over, so the
// secret exists only as long as the keystrokes sit in the text field.
ColumnLayout {
  id: cfg

  property var service: null
  property color foreground: Color.foreground
  property color urgent: Color.urgent
  property color accent: Color.accent
  property color dim: Qt.darker(foreground, 1.5)
  property string fontFamily: Style.font.family

  // Emitted with {key: value} for the host to persist.
  signal settingChanged(string key, var value)
  signal closeRequested()

  spacing: Style.space(12)

  component FieldLabel: Text {
    color: cfg.dim
    font.family: cfg.fontFamily
    font.pixelSize: Style.space(10)
    font.letterSpacing: 0.4
  }

  // ── Header ──────────────────────────────────────────────────────────────
  RowLayout {
    Layout.fillWidth: true
    spacing: Style.space(8)

    Text {
      text: "Settings"
      color: cfg.foreground
      font.family: cfg.fontFamily
      font.pixelSize: Style.space(12)
      font.bold: true
      font.letterSpacing: 0.6
    }
    Rectangle {
      Layout.fillWidth: true
      Layout.alignment: Qt.AlignVCenter
      height: 1
      color: Util.alpha(cfg.foreground, 0.16)
    }
    Button {
      text: "Done"
      onClicked: cfg.closeRequested()
    }
  }

  ScrollView {
    Layout.fillWidth: true
    Layout.fillHeight: true
    clip: true
    contentWidth: availableWidth

    ColumnLayout {
      width: parent ? parent.width : 0
      spacing: Style.space(14)

      // ── Account ─────────────────────────────────────────────────────────
      ColumnLayout {
        Layout.fillWidth: true
        spacing: Style.space(4)

        FieldLabel { text: "FASTESTVPN ACCOUNT" }

        TextField {
          id: accountField
          Layout.fillWidth: true
          placeholderText: "you@example.com"
          font.family: cfg.fontFamily
          onEditingFinished: cfg.settingChanged("username", text.trim())
        }

        // This view is built with the panel, which happens BEFORE the bar
        // pushes shell.json settings into the service — so a one-shot
        // Component.onCompleted assignment read an empty account and the field
        // stayed blank forever. Track the value instead, but stand aside while
        // the field has focus so it never fights the user's typing.
        Binding {
          target: accountField
          property: "text"
          value: cfg.service ? cfg.service.account : ""
          when: !accountField.activeFocus
          restoreMode: Binding.RestoreNone
        }

        FieldLabel {
          Layout.fillWidth: true
          wrapMode: Text.WordWrap
          text: "The account your VPN password belongs to. Stored in shell.json; "
              + "the password is not."
        }
      }

      // ── Password ────────────────────────────────────────────────────────
      ColumnLayout {
        Layout.fillWidth: true
        spacing: Style.space(4)

        RowLayout {
          Layout.fillWidth: true
          spacing: Style.space(8)
          FieldLabel { text: "PASSWORD" }
          Rectangle {
            Layout.alignment: Qt.AlignVCenter
            width: Style.space(7); height: width; radius: width / 2
            color: cfg.service && cfg.service.credentialPresent ? cfg.accent : cfg.dim
          }
          FieldLabel {
            text: cfg.service && cfg.service.credentialPresent
                  ? "saved in keyring" : "not saved"
          }
          Item { Layout.fillWidth: true }
        }

        RowLayout {
          Layout.fillWidth: true
          spacing: Style.space(6)

          TextField {
            id: passwordField
            Layout.fillWidth: true
            echoMode: TextInput.Password
            placeholderText: cfg.service && cfg.service.credentialPresent
                             ? "•••••••• (replace)" : "VPN password"
            font.family: cfg.fontFamily
            enabled: accountField.text.trim() !== ""
            onAccepted: savePassword.clicked()
          }

          Button {
            id: savePassword
            text: "Save"
            enabled: passwordField.text !== "" && accountField.text.trim() !== ""
                     && cfg.service && !cfg.service.updating
            onClicked: {
              if (!cfg.service) return
              // Push the account first: storing writes under whatever account
              // is configured, and an unsaved edit here would file the secret
              // under the old name.
              cfg.settingChanged("username", accountField.text.trim())
              cfg.service.account = accountField.text.trim()
              cfg.service.storeCredential(passwordField.text)
              passwordField.text = ""      // the secret leaves the UI at once
            }
          }
        }

        FieldLabel {
          Layout.fillWidth: true
          wrapMode: Text.WordWrap
          text: "Held in the desktop keyring and piped straight into NetworkManager "
              + "on connect. It never reaches a config file or a command line."
        }
      }

      // ── Profile directory ───────────────────────────────────────────────
      ColumnLayout {
        Layout.fillWidth: true
        spacing: Style.space(4)

        RowLayout {
          Layout.fillWidth: true
          spacing: Style.space(8)
          FieldLabel { text: "OPENVPN PROFILE DIRECTORY" }
          FieldLabel {
            text: cfg.service ? (cfg.service.profileCount + " profiles") : ""
          }
          Item { Layout.fillWidth: true }
        }

        TextField {
          id: dirField
          Layout.fillWidth: true
          placeholderText: "~/.local/share/fastestvpn/profiles"
          font.family: cfg.fontFamily
          onEditingFinished: cfg.settingChanged("profileDir", text.trim())
        }

        Binding {
          target: dirField
          property: "text"
          value: cfg.service ? cfg.service.profileDir : ""
          when: !dirField.activeFocus
          restoreMode: Binding.RestoreNone
        }

        RowLayout {
          Layout.fillWidth: true
          spacing: Style.space(6)

          Button {
            text: "Add profiles…"
            enabled: cfg.service && !cfg.service.updating
            onClicked: if (cfg.service) cfg.service.browseForProfiles()
          }

          Button {
            text: "Refresh profiles"
            enabled: cfg.service && !cfg.service.updating
            ToolTip.visible: cfg.visible && hovered
            ToolTip.text: "Download FastestVPN's current .ovpn bundle into the\n"
                        + "profile directory. Downloads only — connects to nothing."
            onClicked: if (cfg.service) cfg.service.fetchProfiles()
          }

          Item { Layout.fillWidth: true }
        }

        FieldLabel {
          Layout.fillWidth: true
          wrapMode: Text.WordWrap
          text: "Every .ovpn file here becomes a selectable location once imported. "
              + "Files named <name>-udp.ovpn or <name>-tcp.ovpn set the transport; "
              + "anything else is read from the profile's own proto line."
        }
      }

      // ── Import ──────────────────────────────────────────────────────────
      ColumnLayout {
        Layout.fillWidth: true
        spacing: Style.space(4)

        FieldLabel { text: "NETWORKMANAGER" }

        RowLayout {
          Layout.fillWidth: true
          spacing: Style.space(6)

          Button {
            text: "Import profiles"
            enabled: cfg.service && cfg.service.configured && !cfg.service.updating
            ToolTip.visible: cfg.visible && hovered
            ToolTip.text: "Create a NetworkManager connection for each profile.\n"
                        + "Asks for your password once — this is the only step\n"
                        + "that needs administrator rights."
            onClicked: if (cfg.service) cfg.service.importProfiles()
          }

          FieldLabel {
            Layout.fillWidth: true
            wrapMode: Text.WordWrap
            text: cfg.service
                  ? (cfg.service.installedCount + " connection(s) installed")
                  : ""
          }
        }

        FieldLabel {
          Layout.fillWidth: true
          wrapMode: Text.WordWrap
          visible: cfg.service && !cfg.service.configured
          color: cfg.urgent
          text: "Set an account and a profile directory before importing."
        }
      }

      // ── Locations ───────────────────────────────────────────────────────
      ColumnLayout {
        Layout.fillWidth: true
        spacing: Style.space(4)

        RowLayout {
          Layout.fillWidth: true
          spacing: Style.space(8)
          FieldLabel { text: "ENDPOINT LOCATIONS" }
          FieldLabel {
            text: cfg.service ? (cfg.service.geoCount + " located") : ""
          }
          Item { Layout.fillWidth: true }
        }

        RowLayout {
          Layout.fillWidth: true
          spacing: Style.space(6)

          Button {
            text: "Locate new"
            enabled: cfg.service && !cfg.service.updating
            ToolTip.visible: cfg.visible && hovered
            ToolTip.text: "Look up where each new endpoint's server is.\n"
                        + "Runs automatically after an import."
            onClicked: if (cfg.service) cfg.service.geolocate(false)
          }

          Button {
            text: "Re-locate all"
            enabled: cfg.service && !cfg.service.updating
            ToolTip.visible: cfg.visible && hovered
            ToolTip.text: "Look every endpoint up again, even ones already known."
            onClicked: if (cfg.service) cfg.service.geolocate(true)
          }

          Item { Layout.fillWidth: true }
        }

        FieldLabel {
          Layout.fillWidth: true
          wrapMode: Text.WordWrap
          text: "Each server's own IP address is looked up with ip2location.io. "
              + "Your traffic is never routed through the endpoint to find out "
              + "where it is, so this costs nothing against your VPN account. "
              + "The API allows 1000 lookups a day and one run needs about one "
              + "per endpoint."
        }
      }

      // ── Availability ────────────────────────────────────────────────────
      ColumnLayout {
        Layout.fillWidth: true
        spacing: Style.space(4)

        FieldLabel { text: "AVAILABILITY" }

        FieldLabel {
          Layout.fillWidth: true
          wrapMode: Text.WordWrap
          text: "Locations are never tested in the background — each attempt would "
              + "spend an authentication against your account, and enough of them "
              + "get it rate-limited. A location is marked unavailable only when a "
              + "connection you asked for times out or comes up without a usable "
              + "address. A rejected password never marks one unavailable, because "
              + "FastestVPN answers the same way when too many sessions are open."
        }

        RowLayout {
          Layout.fillWidth: true
          spacing: Style.space(6)

          FieldLabel {
            text: cfg.service
                  ? (cfg.service.unavailableCount + " marked unavailable")
                  : ""
          }

          Button {
            text: "Clear all"
            enabled: cfg.service && cfg.service.unavailableCount > 0
            ToolTip.visible: cfg.visible && hovered
            ToolTip.text: "Forget every recorded failure and let them all be tried again."
            onClicked: {
              if (!cfg.service) return
              var ids = []
              for (var k in cfg.service.endpointState) ids.push(k)
              for (var i = 0; i < ids.length; i++) cfg.service.clearVerdict(ids[i])
            }
          }

          Item { Layout.fillWidth: true }
        }
      }
    }
  }

  // ── Footer status ─────────────────────────────────────────────────────────
  Text {
    Layout.fillWidth: true
    visible: text !== ""
    text: {
      if (!cfg.service) return ""
      if (cfg.service.updating) return cfg.service.updateStatus
      if (cfg.service.lastError !== "") return cfg.service.lastError
      return cfg.service.updateStatus
    }
    color: cfg.service && cfg.service.lastError !== "" ? cfg.urgent : cfg.dim
    font.family: cfg.fontFamily
    font.pixelSize: Style.space(10)
    wrapMode: Text.WordWrap
  }
}
