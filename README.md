# FastestVPN for Omarchy

Connect, switch and monitor FastestVPN locations from the Omarchy bar, with a
world map of exit points.

## How it works

The plugin ships **no privileged component**. NetworkManager is the privileged
half, and it is already on every Omarchy box:

- `org.freedesktop.NetworkManager.network-control` defaults to
  `allow_active=yes`, so bringing a VPN connection up or down never prompts.
- Importing profiles needs `settings.modify.system` (`auth_admin_keep`), but
  that is a one-time setup step, not something the bar does.

So the running plugin is a plain unprivileged `nmcli` client — the same shape as
Mullvad's CLI talking to its daemon.

## Credentials

The account password lives in the desktop keyring (Secret Service), never in
NetworkManager and never on disk in the clear. `bin/fvpn-connect` pipes it
straight from `secret-tool` into `nmcli ... passwd-file /dev/stdin`, so it never
reaches a shell variable, never appears in `ps`, and is never written out.

Connections are stored with `password-flags=2` (not-saved), so NetworkManager
asks an agent for the secret and `nmcli` acts as that agent for one activation.

    bin/fvpn-creds store     # save the password
    bin/fvpn-creds status    # check without printing it
    bin/fvpn-creds forget    # remove it

Because this depends on the login keyring being unlocked, it deliberately rules
out boot-time autoconnect and headless SSH activation.

## Setup

Everything after the package install is done from the plugin's own settings
screen — the gear in the panel header.

1. `omarchy pkg add networkmanager-openvpn`
2. Open the panel, click the gear, and fill in:
   - **FastestVPN account** — the account your password belongs to.
   - **Password** — stored in the keyring, never in `shell.json`.
   - **OpenVPN profile directory** — defaults to
     `~/.local/share/fastestvpn/profiles`.
3. **Refresh profiles** downloads FastestVPN's current bundle into that
   directory. **Add profiles…** copies in `.ovpn` files of your own; those
   appear in the list like any other location once imported.
4. **Import profiles** creates the NetworkManager connections. This is the only
   step that asks for your password.
5. **Locate new** runs automatically after an import, and fills in where each
   endpoint is.

## Availability

Locations are never tested in the background. Every test would spend an
authentication against the account, and FastestVPN rate-limits: a bulk sweep
during development got the account blocked for the better part of a day.

So an endpoint is judged only when you actually ask to connect to it, and only
two outcomes mark it unavailable — the server not answering, or a tunnel that
comes up without a usable address. A rejected password never does, because
FastestVPN returns `AUTH_FAILED` both for bad credentials *and* for too many
open sessions; treating that as a server fault would condemn healthy endpoints
the moment the account is throttled.

Verdicts live in `~/.local/state/fastestvpn/endpoints.json`. Hovering a row
shows what happened last time. Selecting an unavailable location and pressing
**Retry** clears its verdict first, so nothing is condemned permanently.

Clicking a location only selects it — a **Connect** button appears on the
selected row. Connecting is never one stray click away, because on this
provider an attempt is not free.

## Location data

`data/locations.json` carries one entry per profile. Coordinates are the **exit**
location — where you appear to the internet.

- `precision: "measured"` — observed by connecting and geolocating the exit IP.
  These win over any later IP lookup.
- `precision: "server"` — from `fvpn-geolocate`, i.e. where the endpoint's own
  address is registered. This is where you *enter* the network, which is
  usually but not always where you appear.
- `precision: "city"` / `"country"` — inferred from the profile name or server
  hostname, not measured. Shown as "approx." in the list.
- `status` / `reachable` — legacy fields from a background probe that is no
  longer run and whose results proved unreliable. They are informational only
  and gate nothing; availability comes from real connection attempts.
- `countryMismatch` — the exit geolocates to a different country than the label
  claims (a "virtual location"). The UI says so rather than quietly plotting one
  country under another's name.
- `via` — for double-hop profiles, the entry node actually dialled. The map
  draws entry → exit as a dashed link, suppressed when the two coincide.

Coordinates come from `bin/fvpn-geolocate` (see below). Where an entry was
previously measured by connecting and reading the real exit address, that
measurement wins over the IP lookup — the two answer different questions, and
the measured one is the truth about where you appear.


## Keeping endpoints current

FastestVPN publishes its OpenVPN bundle at
`https://support.fastestvpn.com/download/fastestvpn_ovpn/`. That bundle — not
the support site's server table, which lists only a fraction of the fleet — is
the authoritative endpoint list.

The profile directory set in the plugin's settings is the source of truth for
which endpoints exist. Everything below is reachable from the settings screen;
the scripts are the same ones those buttons run.

    bin/fvpn-fetch-profiles          # download the bundle into the profile dir
    bin/fvpn-geolocate               # locate any endpoint not located yet
    bin/fvpn-geolocate --all         # locate every endpoint again

Neither connects to a VPN. `fvpn-geolocate` resolves each profile's `remote`
host and looks the IP up with ip2location.io, so it learns where a server is
without tunnelling through it — doing that for 70 endpoints would hijack the
network for minutes and, worse, spend an account authentication per endpoint.
One lookup is made per unique IP rather than per file, so the UDP and TCP
variants of an endpoint share it: 134 profiles cost about 64 of the API's 1000
free daily calls. It is incremental by default, and also re-locates any host
that has since moved to a different IP.

Importing into NetworkManager needs root, so it is a separate step and the only
one that ever raises a password prompt:

    pkexec bash bin/fvpn-import-profiles --dir <profile-dir> \
        --user "$(id -un)" --account <vpn-account> --dry-run

Reads of the profile directory are performed *as the invoking user* via
`runuser`, so a symlink planted in that user-writable directory cannot walk root
into a file it should not read.

To start over — remove every `fvpn-*` connection, the installed profiles and
their certificates:

    pkexec bash bin/fvpn-wipe --dry-run
    pkexec bash bin/fvpn-wipe --yes

`bin/fvpn-endpoints` is a legacy catalogue tool from an earlier design that
probed endpoints in the background. Nothing in the plugin calls it, and its
probe results are not trusted — see *Availability* above.

## Filters and selectability

Under the search box: a **UDP / TCP** transport toggle and a **Show
unavailable** toggle.

A NetworkManager connection's transport is fixed when it is imported, so the
toggle does not filter — it selects a *different connection*:

    fvpn-<id>       UDP  (default)
    fvpn-<id>-tcp   TCP  (for networks that block UDP)

Each chip shows how many locations are available on that transport, and is
dimmed when none are. Switching while connected disconnects first, so the bar
never shows a stale transport. Both transports are imported together, since the
bundle ships a `-udp` and a `-tcp` profile for every endpoint.

A location is selectable when it is imported on this machine and has not failed
a connection attempt. Anything else
is listed greyed with the reason (`unreachable`, `no location`, `checking…`,
`not imported`) and cannot be clicked, so a half-known endpoint is never a
silent 20-second timeout.

## Attribution

`WorldMap.qml` adapts the projection, Natural Earth path data and pin rendering
from [OmaMullvad](https://github.com/kallupx/oma-mullvad) by kallupx, MIT
licensed — see `LICENSE.oma-mullvad`. The underlying Natural Earth 1:110m land
data is public domain. The multi-hop link rendering is an addition.

`data/countries.json` holds per-country outlines used to highlight and frame the
connected country. It is generated from [Natural Earth]
(https://www.naturalearthdata.com/) 1:110m Admin 0 countries — public domain,
no permission or attribution required — reprojected into the same
equirectangular 1000x500 space as the base map, rounded to one decimal, and
stripped of everything but an ISO 3166-1 alpha-2 key, the outline path, and the
bounding boxes of each landmass. That last part is what lets the camera frame
the mainland United States rather than a box stretching from Alaska to Florida.
