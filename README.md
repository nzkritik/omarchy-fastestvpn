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

1. `omarchy pkg add networkmanager-openvpn`
2. Import the `.ovpn` profiles as `fvpn-<location>` NetworkManager connections
   (`autoconnect no`, scoped to your user).
3. `bin/fvpn-creds store`

## Location data

`data/locations.json` carries one entry per profile. Coordinates are the **exit**
location — where you appear to the internet.

- `precision: "measured"` — observed by connecting and geolocating the exit IP.
- `precision: "city"` / `"country"` — inferred from the profile name or server
  hostname, not measured.
- `reachable: false` — the endpoint did not answer a probe of its own
  `host:port`. A little over a third of FastestVPN's advertised locations were
  dead when this data was gathered; the widget hides them by default
  (`hideDeadEndpoints`).
- `countryMismatch` — the exit geolocates to a different country than the label
  claims (a "virtual location"). The UI says so rather than quietly plotting one
  country under another's name.
- `via` — for double-hop profiles, the entry node actually dialled. The map
  draws entry → exit as a dashed link, suppressed when the two coincide.

Coordinates can be re-measured with `fvpn-measure-locations` and folded back in
with `fvpn-merge-measurements`.


## Keeping endpoints current

FastestVPN publishes its OpenVPN bundle at
`https://support.fastestvpn.com/download/fastestvpn_ovpn/`. That bundle — not
the support site's server table, which lists only a fraction of the fleet — is
the authoritative endpoint list.

    bin/fvpn-endpoints check     # what changed upstream
    bin/fvpn-endpoints sync      # merge upstream into the catalogue
    bin/fvpn-endpoints enrich    # resolve, probe and geolocate anything missing
    bin/fvpn-endpoints status    # summary

The **Update** button in the panel runs `sync` then `enrich`.

Enrichment geolocates each server's own IP rather than connecting through it.
That is deliberate: learning where 70 endpoints are by tunnelling through each
in turn would hijack the network for minutes. Spot-checked against a live
measurement — for `uk2` both methods return `51.5085,-0.1257`.

Installing a *new* endpoint's profile needs root, so it is a separate step:

    sudo bash bin/fvpn-install-endpoints --dry-run
    sudo bash bin/fvpn-install-endpoints

## Filters and selectability

Under the search box: a **UDP / TCP** transport toggle and a **Show
unavailable** toggle.

A NetworkManager connection's transport is fixed when it is imported, so the
toggle does not filter — it selects a *different connection*:

    fvpn-<id>       UDP  (default)
    fvpn-<id>-tcp   TCP  (for networks that block UDP)

Each chip shows how many locations are available on that transport, and is
dimmed when none are. Switching while connected disconnects first, so the bar
never shows a stale transport. Install the TCP side with:

    sudo bash bin/fvpn-install-tcp --dry-run
    sudo bash bin/fvpn-install-tcp

`--remove` deletes them again.

A location is selectable only when it is both fully identified — resolved host,
reachable port, known coordinates — and imported on this machine. Anything else
is listed greyed with the reason (`unreachable`, `no location`, `checking…`,
`not imported`) and cannot be clicked, so a half-known endpoint is never a
silent 20-second timeout.

## Attribution

`WorldMap.qml` adapts the projection, Natural Earth path data and pin rendering
from [OmaMullvad](https://github.com/kallupx/oma-mullvad) by kallupx, MIT
licensed — see `LICENSE.oma-mullvad`. The underlying Natural Earth 1:110m land
data is public domain. The multi-hop link rendering is an addition.
