# FastestVPN for Omarchy

Connect, switch and monitor FastestVPN locations from the Omarchy bar, with a
world map of exit points.

> Work in progress. It does what is described here, but the panel is plain and
> parts of the location data are still rough.

## How it works

The plugin ships **no privileged component**. NetworkManager is the privileged
half, and it is already on every Omarchy box:

- `org.freedesktop.NetworkManager.network-control` defaults to
  `allow_active=yes`, so bringing a connection up or down never prompts.
- Importing profiles needs `settings.modify.system` (`auth_admin_keep`), which
  is a one-time setup step, not something the bar does.

So the running plugin is a plain unprivileged `nmcli` client.

## Setup

Everything after the package install happens in the plugin's settings screen —
the gear in the panel header.

1. `omarchy pkg add networkmanager-openvpn`
2. Open the panel, click the gear, and fill in **account**, **password** and the
   **profile directory** (defaults to `~/.local/share/fastestvpn/profiles`).
3. **Refresh profiles** downloads FastestVPN's bundle into that directory.
   **Add profiles…** copies in `.ovpn` files of your own.
4. **Import profiles** creates the NetworkManager connections. This is the only
   step that asks for your password.
5. **Locate new** fills in where each endpoint is. It runs automatically after
   an import.

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

Locations are never tested in the background. Each test spends an
authentication against your account, and FastestVPN rate-limits — a bulk sweep
during development got the account blocked for most of a day.

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

Where an entry was previously measured by connecting and reading the real exit
address, that measurement wins over the IP lookup: the lookup says where you
*enter* the network, a real connection says where you *appear*, and those differ
for virtual and double-hop locations.

The catalogue used to carry probe results and measurement provenance
(`status`, `reachable`, `host`, `verified`, `measured*`, `site*` and others)
from an earlier design that tested endpoints in the background. Nothing read
them any more, so they are gone; earlier revisions are in git history if the
raw measurements are ever wanted again.

## Tools

    bin/fvpn-fetch-profiles     # download the bundle into the profile directory
    bin/fvpn-geolocate          # locate endpoints not located yet (--all for every one)
    bin/fvpn-connect <conn>     # connect, or --down to disconnect
    bin/fvpn-creds              # keyring credential

Root, via pkexec, and both take `--dry-run`:

    bin/fvpn-import-profiles    # create the NetworkManager connections
    bin/fvpn-wipe               # remove every connection, profile and certificate

Reads of the profile directory are performed *as the invoking user* via
`runuser`, so a symlink planted in that user-writable directory cannot walk root
into a file it should not read.

## Attribution

`WorldMap.qml` adapts the projection, Natural Earth path data and pin rendering
from [OmaMullvad](https://github.com/kallupx/oma-mullvad) by kallupx, MIT
licensed — see `LICENSE.oma-mullvad`. The multi-hop link rendering is an
addition.

`data/countries.json` is generated from
[Natural Earth](https://www.naturalearthdata.com/) 1:110m Admin 0 countries
(public domain), reprojected into the same equirectangular 1000×500 space as the
base map and reduced to an ISO 3166-1 alpha-2 key, an outline path, and the
bounding box of each landmass — the last of which lets the camera frame the
mainland United States rather than a box stretching from Alaska to Florida.

Licensed MIT — see `LICENSE`.
