# FastestVPN for Omarchy

Connect, switch and monitor FastestVPN locations from the Omarchy bar, with a
world map of exit points.

![Disconnected, showing every location on a world map; and connected to Denmark, with the country outlined and the camera framed on it](docs/screenshot.png)

> Work in progress. It does what is described here, but the panel is plain and
> parts of the location data are still rough.

## How it works

The plugin ships **no privileged component**. NetworkManager is the privileged
half, and it is already on every Omarchy box:

- `org.freedesktop.NetworkManager.network-control` defaults to
  `allow_active=yes`, so bringing a connection up or down never prompts.
- Importing profiles needs `settings.modify.system`, which stock Arch grants to
  a local user in `wheel` with no prompt — see **Privilege** below.

So the running plugin is a plain unprivileged `nmcli` client. It also
**downloads no VPN configuration**: you fetch FastestVPN's profile bundle
yourself and unpack it where the plugin can read it, so nothing the plugin
imports can change behind your back.

## Install and remove

    omarchy plugin add https://github.com/nzkritik/omarchy-fastestvpn --enable

`--enable` puts the widget straight on the bar. Leave it off if you would rather
read the code first and enable it later with
`omarchy plugin enable nzkritik.fastestvpn`. Either way, setup happens in the
panel — follow **First run** below.

Removing it takes two steps more than most plugins, because the import created
NetworkManager connections and a keyring entry that both outlive the plugin.
Undo them in this order, while the scripts are still there:

    bin/fvpn-creds forget       # clear the keyring entry
    bin/fvpn-wipe --yes         # remove every fvpn-* connection and certificate
    omarchy plugin remove nzkritik.fastestvpn

Credentials go first: `fvpn-creds` finds the account from the connections, so
after a wipe it has nothing to look up. `fvpn-wipe` takes `--dry-run` to list
what would go, and removes only what the import created. If the plugin is
already gone, the connections can still be cleared with `nmcli connection
delete <name>` for each `fvpn-*` entry.

## First run

Installing the plugin downloads nothing, and neither does the plugin once it is
running. `omarchy plugin add` clones the repo and stops there — it never runs
code from it, which is what lets you review a plugin before enabling it. So
setup happens in the panel, from the gear in its header.

1. `omarchy pkg add networkmanager-openvpn`
2. Open the panel and click the gear. Fill in your **account**, **Save** the
   password, and set the **profile directory** if you do not want the default
   `~/.local/share/fastestvpn/profiles`.
3. Put FastestVPN's profiles in that directory yourself — see **Getting the
   profiles** below. **Download bundle** opens the download in your browser,
   and **Open folder** opens the directory, creating it first. **Add
   profiles…** copies in `.ovpn` files of your own; both can be used together.
4. **Import profiles** turns them into NetworkManager connections. It runs as
   you and asks for nothing.

Locations appear as soon as the import finishes, and **Locate new** runs by
itself to fill in where each endpoint is.

Until something is imported the panel says so, and names the one step that is
next rather than reciting all of them:

| Panel says | What to do |
|---|---|
| Add your FastestVPN account and password in settings | fill in the account, then **Save** the password |
| Download FastestVPN's profile bundle and unzip it into the profile folder | **Download bundle**, then unzip it with **Open folder**, or add your own `.ovpn` files |
| The profiles are ready. Import them in settings | **Import profiles** |

### Getting the profiles

The plugin does not fetch VPN configuration for you. A profile decides which
server you connect to and which certificate that server is trusted by, so it
comes from you rather than from a download the plugin makes on its own.

FastestVPN publishes every profile in one zip,
<https://support.fastestvpn.com/download/fastestvpn_ovpn/>, which saves as
`fastestvpn_ovpn.zip`. Unzip it into the profile directory as it is:

    unzip ~/Downloads/fastestvpn_ovpn.zip -d ~/.local/share/fastestvpn/profiles

or click **Open folder**, drop the zip in, and choose **Extract**. The zip holds
`udp_files/` and `tcp_files/`, and the importer reads up to two folders down,
so either way works without moving anything.

Importing only adds locations it does not have yet. When FastestVPN moves a
server, unzip the new bundle over the old one, remove the existing connections
with `bin/fvpn-wipe --yes`, and import again.

## Requirements

You need a **FastestVPN account**. The plugin drives a subscription you already
have; it does not create one, and the profiles are useless without credentials
to authenticate them.

Everything the plugin runs is present on a default Omarchy except one package,
which the first step installs:

- **`networkmanager-openvpn`** — `omarchy pkg add networkmanager-openvpn`.
  NetworkManager cannot speak OpenVPN without it.

Everything else comes from Arch's `base` metapackage (`coreutils`, `findutils`,
`util-linux`, `systemd`, `grep`, `sed`, `bash`), from Omarchy's own package list
(`networkmanager`, `libsecret`), or from something Omarchy already
depends on (`python` via `uwsm`/`ufw`, `polkit` via
`quickshell` itself).

`zenity` is optional. It provides the **Add profiles…** file picker, and the
button is hidden when it is absent — profiles can always be copied into the
directory by hand instead.

## Credentials

The password lives in the desktop keyring (Secret Service), never in
NetworkManager and never on disk in the clear. `bin/fvpn-connect` pipes it from
`secret-tool` straight into `nmcli … passwd-file /dev/stdin`, so it never
reaches a shell variable, never appears in `ps`, and is never written out.
Connections are stored `password-flags=2` (not-saved).

    bin/fvpn-creds store     # save the password
    bin/fvpn-creds status    # check without printing it
    bin/fvpn-creds forget    # remove it

This needs the login keyring unlocked, which rules out boot-time autoconnect
and headless SSH activation.

## Availability

Locations are never tested in the background. This avoids triggering
concurrency or rate-limits on your account.

An endpoint is therefore judged only when you ask to connect to it, and only
two outcomes mark it unavailable: the server not answering, or a tunnel that
comes up without a usable address. A rejected password never does, because
FastestVPN returns `AUTH_FAILED` for too many open sessions as well as for bad
credentials.

Verdicts live in `~/.local/state/fastestvpn/endpoints.json`. Hovering a row
shows what happened last time; **Retry** clears the verdict first, so nothing is
condemned permanently.

Clicking a location only selects it — a **Connect** button appears on the
selected row, so connecting is never one stray click away.

## Location data

`data/locations.json` is a catalogue of known endpoints: labels, coordinates and
notes such as `countryMismatch` (the exit geolocates to a different country than
the name claims) and `via` (the entry node of a double-hop profile, drawn on the
map as a dashed link).

`bin/fvpn-geolocate` fills in coordinates by resolving each profile's `remote`
host and looking the IP up with ip2location.io. It never connects through an
endpoint to find out where it is. One lookup is made per unique IP rather than
per file, so 134 profiles cost about 64 of the API's 1000 free daily calls, and
it only looks up what it does not already know.

## Tools

    bin/fvpn-geolocate          # locate endpoints not located yet (--all for every one)
    bin/fvpn-connect <conn>     # connect, or --down to disconnect
    bin/fvpn-creds              # keyring credential

Both of these take `--dry-run`:

    bin/fvpn-import-profiles    # create the NetworkManager connections
    bin/fvpn-wipe               # remove every connection and certificate

## Privilege

**Nothing in this plugin runs as root, and nothing in it escalates.**

NetworkManager is the only component that needs privilege, and it already has
it. Stock Arch ships
`/usr/share/polkit-1/rules.d/org.freedesktop.NetworkManager.rules`, which grants
`org.freedesktop.NetworkManager.settings.modify.system` to a local user in the
`wheel` group with no prompt, so importing and removing connections both run as
you. Check your own session with:

    pkcheck --action-id org.freedesktop.NetworkManager.settings.modify.system --process $$

That is also the arrangement that works unattended from the panel:
`omarchy-shell` is a long-lived process with no TTY. Omarchy 4.0.3 does now
register a polkit agent of its own, so a prompt could be answered — but an
import that needs no prompt is the better shape, and this plugin never asks for
one. If the rule does not cover your session the import says so and explains
what is missing, rather than reaching for privilege.

Because the import runs as you, NetworkManager extracts each profile's inline
`<ca>`/`<tls-auth>` blob to
`~/.local/share/networkmanagement/certificates/nm-openvpn/` at `0600`, owned by
you. Activation still works because the OpenVPN service declares
`supports-safe-private-file-access=true` — NM opens the certificate on the
activating user's behalf. Only a *root* import ever had to copy certificates
into a world-readable directory under `/etc`.

The profile directory is user-writable and its path is predictable, so no tool
is pointed straight at a path inside it. Each profile is copied out through a
no-follow, non-blocking, byte-bounded read into a private staging directory, and
`nmcli` only ever sees the staged copy under a name the importer chose.

Every process the plugin starts runs with a closed environment. Tools are named
by absolute path, `PATH` is pinned to `/usr/bin`, and only the session variables
the tools need (home, runtime directory, D-Bus and display) are passed through,
so nothing is resolved through an inherited `PATH`, and hooks such as
`LD_PRELOAD`, `BASH_ENV` or `PYTHONPATH` never reach a child. The scripts pin
`PATH` again themselves, so they behave the same when run by hand.

**The plugin downloads no VPN configuration.** Profiles control the server, the
certificate it is trusted by, and potentially routing and DNS, and a download
the plugin made by itself would not be bound to anything a reviewer saw. So
they come only from you, and the plugin never replaces them behind your back.
**Download bundle** and **Open folder** only hand a URL to your desktop's own
handler.

The importer reads the profile directory up to three levels down, which covers
the bundle as unzipped and as wrapped by a file manager's **Extract**. It never
follows a symlinked directory, prunes hidden entries, and reports anything it
passes over: a `*.ovpn` that is a link or a FIFO, a linked directory, a file
with an unusable name, or a second file wanting the same connection. Where two
files would make the same connection, the one nearest the top wins.

## Attribution

`WorldMap.qml` adapts the projection, Natural Earth path data and pin rendering
from [OmaMullvad](https://github.com/kallupx/oma-mullvad) by kallupx, MIT
licensed — see `LICENSE.oma-mullvad`. The multi-hop link rendering is an
addition.

Endpoint IP addresses are geolocated by
[ip2location.io](https://api.ip2location.io), which fits easily inside their
free allowance of 1000 queries a day — one full run of `bin/fvpn-geolocate`
costs about 64.

`data/countries.json` is generated from
[Natural Earth](https://www.naturalearthdata.com/) 1:110m Admin 0 countries
(public domain), reprojected into the same equirectangular 1000×500 space as the
base map and reduced to an ISO 3166-1 alpha-2 key, an outline path, and the
bounding box of each landmass — the last of which lets the camera frame the
mainland United States rather than a box stretching from Alaska to Florida.

Licensed MIT — see `LICENSE`.
