# xray-container

[English](README.md) · [Русский](README.ru.md)

xray-core packaged for the MikroTik RouterOS container runtime. Pulls a
[Remnawave](https://remna.st/) subscription on boot, builds a complete
xray config (balancer over every VLESS server, observatory, sniffing,
bypass rules) and provides transparent VPN routing for the whole LAN
with selective bypass — `.ru`, popular Russian services, and `geoip:ru`
go direct, everything else flows through the VLESS balancer.

Tested on **MikroTik hAP ax3** (IPQ-6010, ARM64, 1 GB RAM, RouterOS 7.x).

## Quick install

You will need:

- The router on RouterOS 7.10+, with the `container` extra package
  installed and a USB stick / microSD that shows up under `/disk/print`
  (these examples assume slot `usb1`).
- Docker / nerdctl on your build host (macOS Colima works) with
  `linux/arm64` support.
- Physical access to the router for one reset-button press.

### 1. Enable container mode (one-time)

In WinBox or SSH on the router:

```routeros
/system/device-mode/print
# if "container: no", run:
/system/device-mode/update container=yes
# short-press the reset button within 60 seconds
/system/device-mode/print
# expect "container: yes"
```

### 2. Build the image

```bash
git clone https://github.com/davydovd/xray-container ~/opensource/xray-container
cd ~/opensource/xray-container
./build.sh --export
# → dist/xray-container.tar (~100 MB, linux/arm64)
```

### 3. Set your subscription URL

Open `routeros/01-container-setup.rsc` and replace the placeholder:

```routeros
:local subscriptionUrl       "https://CHANGEME.example/your-token"
```

with your real Remnawave subscription URL. **Do not commit a real URL** —
`routeros/*.local.rsc` is git-ignored on purpose, use that suffix for
private copies.

### 4. Upload everything to the router

Replace `192.168.88.1` with your router IP:

```bash
ROUTER=192.168.88.1
scp dist/xray-container.tar              admin@$ROUTER:usb1/
scp routeros/01-container-setup.rsc      admin@$ROUTER:usb1/
scp routeros/02c-routing-rules.rsc       admin@$ROUTER:usb1/
```

Alternative: drag the three files into `usb1/` via WinBox → Files.

### 5. Create the container

In WinBox / SSH terminal:

```routeros
/import file=usb1/01-container-setup.rsc
/log/print follow where topics~"container"
# wait until you see:
#   [Z] REDIRECT rules installed (PREROUTING tcp -> :12345); ip_forward=1
#   [Z] starting xray (config=/etc/xray/config.json)
#   [Z] xray pid=...
# press Ctrl-C to stop following
```

### 6. Wire the container bridge into the LAN list

```routeros
/interface/list/member/add list=LAN interface=br-containers
```

This is required exactly once — it lets the LAN firewall rules accept
traffic from / to the container.

### 7. Enable transparent routing

```routeros
/import file=usb1/02c-routing-rules.rsc
```

### 8. Verify from a LAN client

```bash
curl --silent --max-time 15 https://ifconfig.co
# → IP of one of your VLESS servers (NOT your ISP)

curl --silent --max-time 10 https://ya.ru -o /dev/null -w "%{remote_ip}\n"
# → some Russian IP (direct, bypassed)
```

Done. Whole LAN now egresses through the VPN by default, with `.ru` and a
hard-coded list of Russian services going direct.

## How it works

```
LAN client                RouterOS                     container netns
─────────                 ────────                     ──────────────
curl https://x.com ─────► mangle prerouting            
                          ├─ src=container         → accept (no loop)
                          ├─ dst=private/local     → accept (bypass)
                          ├─ dst=53                → accept (DNS direct)
                          └─ in=LAN, tcp           → mark-routing via-xray
                                ↓
                          /ip/route via-xray
                          default → gw=172.20.0.2 (the container)
                                ↓
                          packet leaves through veth, original dst intact
                                ↓
                                                    iptables -t nat
                                                    PREROUTING tcp
                                                    REDIRECT --to-ports 12345
                                                          ↓
                                                    xray dokodemo-door
                                                    followRedirect=true
                                                    reads SO_ORIGINAL_DST
                                                          ↓
                                                    sniff SNI from TLS hello
                                                          ↓
                                                    routing rules:
                                                    ├─ private          → direct
                                                    ├─ BYPASS_DOMAIN    → direct
                                                    ├─ BYPASS_GEOIP     → direct
                                                    └─ default          → balancer
                                                                            ↓
                                                                    VLESS outbound
                                                                    (leastPing)
```

Why mark-routing instead of `dst-nat REDIRECT` on the router:
`SO_ORIGINAL_DST` reads from conntrack. If dst-nat runs on the host, its
conntrack record lives in the host's network namespace, invisible to the
xray process inside the container's namespace. Doing the REDIRECT inside
the container puts conntrack and xray in the same namespace, so the
lookup actually works. (MikroTik's container kernel also ships without
the TPROXY iptables module, so classic `iptables -t mangle TPROXY` is
not an option either.)

QUIC (UDP/443) is dropped by `02c-routing-rules.rsc` so browsers fall
back to TCP TLS — since SO_ORIGINAL_DST only works for TCP, UDP traffic
would otherwise bypass xray completely. Set `:local blockQuic false` in
the rsc to disable.

## Repository layout

```
.
├── Containerfile                  multi-stage Alpine + xray + supervisor
├── build.sh                       build + OCI tar export for RouterOS
├── scripts/
│   └── entrypoint.sh              fetch → parse → build → run + refresh loop
└── routeros/
    ├── 01-container-setup.rsc     veth / bridge / envs / container
    └── 02c-routing-rules.rsc      mark-routing + LAN→container gateway
```

## Configuration

All knobs are environment variables baked into the container by
`/container/envs` in `01-container-setup.rsc`. Edit the variables at the
top of that file and re-import to apply.

| Name                          | Default        | Meaning                                                                 |
| ----------------------------- | -------------- | ----------------------------------------------------------------------- |
| `SUBSCRIPTION_URL`            | (required)     | Remnawave subscription URL                                              |
| `SUBSCRIPTION_USER_AGENT`     | `Xray/26.3.27` | UA sent on fetch — controls the subscription format Remnawave returns   |
| `SUBSCRIPTION_FORMAT`         | `auto`         | `auto` / `xray-json` / `base64`                                         |
| `REFRESH_INTERVAL_SECONDS`    | `43200`        | 12 h — how often to re-fetch the subscription                           |
| `TPROXY_PORT`                 | `12345`        | Internal port where xray's `dokodemo-door` listens (REDIRECT target)    |
| `SOCKS_PORT`                  | `10808`        | SOCKS5 listen port (also reachable from LAN for manual clients)         |
| `DNS_PORT`                    | `10853`        | DNS dokodemo-door port                                                  |
| `REDIRECT_ENABLED`            | `1`            | Install `iptables -t nat REDIRECT` in the container; required for the   |
|                               |                | mark-routing scheme                                                     |
| `BALANCER_STRATEGY`           | `leastPing`    | `leastPing` / `random` / `roundRobin`                                   |
| `OBSERVATORY_INTERVAL`        | `5m`           | How often to probe each VLESS outbound for latency                      |
| `LOG_LEVEL`                   | `warning`      | `debug` / `info` / `warning` / `error` — bump to `info` to debug        |
| `BYPASS_PRIVATE`              | `1`            | If `1`, add geoip/geosite:private bypass                                |
| `BYPASS_DOMAIN`               | see rsc        | CSV of xray domain matchers routed `direct` (regexp/domain/keyword/...) |
| `BYPASS_GEOIP`                | `ru`           | CSV of GeoIP codes routed `direct`                                      |

### Adjusting what stays direct

Edit `bypassDomain` / `bypassGeoip` in `01-container-setup.rsc`, then:

```routeros
/import file=usb1/01-container-setup.rsc
```

The script is idempotent — it stops the old container, replaces envs,
and starts fresh.

Domain matcher prefixes (xray syntax):

- `domain:vk.com`   — match `vk.com` and any subdomain
- `regexp:\.ru$`    — regex over the FQDN
- `keyword:apple`   — substring
- `full:example.org` — exact
- `geosite:cn`      — geosite group from the bundled geosite.dat

> Cyrillic characters in `BYPASS_DOMAIN` are lost by RouterOS `/import`
> (it strips non-ASCII bytes from string literals). Keep this variable
> pure ASCII — use explicit `domain:` entries for Russian-on-foreign-TLD
> services instead of `regexp:\.рф$`.

## Operations

### Force a subscription refresh

```routeros
/container/stop xray
/container/start xray
```

### Recreate the container after image rebuild

```bash
./build.sh --export
scp dist/xray-container.tar admin@$ROUTER:usb1/
```

```routeros
/container/stop xray
/container/remove xray
/import file=usb1/01-container-setup.rsc
```

### Disable VPN temporarily (whole LAN goes direct)

```routeros
/ip/firewall/mangle/disable [find comment~"xray-mark"]
```

Re-enable:

```routeros
/ip/firewall/mangle/enable [find comment~"xray-mark"]
```

### Full uninstall

```routeros
/ip/firewall/mangle/remove [find comment~"xray-mark"]
/ip/firewall/filter/remove [find comment~"xray-mark"]
/ip/route/remove [find routing-table="via-xray"]
/routing/table/remove [find name="via-xray"]
/container/stop xray
/container/remove xray
/container/envs/remove [find list="xray-env"]
/interface/list/member/remove [find interface=br-containers]
/interface/bridge/port/remove [find interface=veth-xray]
/interface/veth/remove [find name=veth-xray]
/ip/address/remove [find interface=br-containers]
/interface/bridge/remove [find name=br-containers]
```

## Troubleshooting

**`/import` fails with `bad parameter mounts` / `mount`.** Your RouterOS
build's device-mode does not allow bind-mounts. The script ships with
mounts commented out for this reason — xray state and logs live in the
container's writable layer and are lost only on `container/remove`,
not on `stop/start`.

**`failed to call getsockopt > no such file or directory`** in xray
logs. The REDIRECT iptables rule never installed inside the container.
Open a shell (`/container/shell xray`) and run `iptables -t nat -L XRAY
-n -v` — the chain should exist. If not, check that `REDIRECT_ENABLED=1`
is in `/container/envs/print where list="xray-env"`.

**`SUBSCRIPTION_URL is required` in logs.** Container env list is empty
— most likely you ran `/import 01-container-setup.rsc` while
`subscriptionUrl` still held the `CHANGEME` placeholder, then later
re-imported but without recreating the env list. Run `/container/envs/remove
[find list="xray-env"]` and re-import.

**`xray run -test` rejects the generated config.** Some VLESS server in
your subscription uses a transport/security combination the parser does
not yet handle. Bump `LOG_LEVEL=info`, restart, and watch the line
where the URI is rejected. The rejected config is kept at
`/etc/xray/config.json.new.rejected` inside the container for
inspection (`/container/shell xray`).

**Browser shows direct IP for foreign sites.** Either QUIC is sneaking
through (check that `:local blockQuic` is `true` in
`02c-routing-rules.rsc`), or your client uses DoH/DoT bypassing the
router. xray matches by SNI, so DoH still works — but if the browser
keeps a long-lived QUIC connection it never falls back to TCP.

**Counters on the dst-nat / mark-routing rule are zero.** The bridge
`br-containers` is not in `/interface/list/member` for `LAN`. Add it:
`/interface/list/member/add list=LAN interface=br-containers`.

## Security notes

- Never commit your real Remnawave URL — it grants full access to your
  account. `routeros/*.local.rsc` is gitignored, use that suffix for
  private copies you want to keep on disk.
- The xray process inside the container runs as UID 65532. The
  iptables setup and conntrack require NET_ADMIN, which RouterOS
  grants to all containers by default.
- The bundled `geoip.dat` / `geosite.dat` are vendored at build time;
  refresh them by rebuilding the image with an updated `XRAY_VERSION`.

## License

Source files in this repository: MIT.
Bundled xray-core remains under
[MPL-2.0](https://github.com/XTLS/Xray-core/blob/main/LICENSE).
