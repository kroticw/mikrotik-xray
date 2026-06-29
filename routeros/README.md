# RouterOS scripts

Setup scripts for running xray-container on MikroTik RouterOS.

- `01-container-setup.rsc` — veth, container env list, and the container itself.
- `02c-routing-rules.rsc` — mangle bypasses + `via-xray` routing mark that send
  LAN traffic into the container (full-tunnel).
- `03-geo-split.rsc` — **geo offload**: route only foreign traffic through the
  container by bypassing RU-destined traffic at the router.

## RU geo list (geo offload)

By default every LAN connection is marked `via-xray`, so the container
terminates all of it and only then sends domestic (RU) traffic back out
`direct`. That wastes the container's file descriptors and memory. `03-geo-split.rsc`
adds a mangle rule that bypasses RU-destined traffic **before** the `via-xray`
mark, so the container only ever sees foreign traffic.

The RU set lives in the `RU` IPv4 firewall address-list, built from
[ipdeny](https://www.ipdeny.com/) `ru-aggregated`. IPv6 is not proxied through
the container, so no v6 list is needed.

### How the list stays fresh

RouterOS cannot parse a large raw CIDR list in-script (both `/file/get
contents` and `fetch ... as-value` cap at ~63 KB), so the list is built
**off-box** and the router only fetches a ready-made `.rsc`:

1. A GitHub Action (`.github/workflows/update-ru-list.yml`) regenerates
   `routeros/ru-geo.rsc` from ipdeny weekly and commits it when it changes.
2. On the router, `03-geo-split.rsc` installs a script + daily scheduler that
   `fetch` the committed `ru-geo.rsc` from GitHub raw and `/import` it (no size
   limit on `/import`).

This needs RouterOS **device-mode** to allow `fetch` and `scheduler`:

```text
/system/device-mode/print          ;# fetch and scheduler must be "yes"
/system/device-mode/update fetch=yes scheduler=yes
```

`device-mode/update` requires **physical confirmation** (press the reset/mode
button or power-cycle within the timeout) — it cannot be done purely remotely.
Specify only the per-feature flags (no `mode=`), or the other features reset.
After enabling, import the setup and run the job once:

```text
/import file-name=03-geo-split.rsc
/system script run ru-geo-update
```

**Manual fallback (no device-mode / no CI).** Generate the list on a
workstation and import it directly; `03-geo-split.rsc` still provides the
mangle rule.

```bash
./scripts/gen-ru-list.sh ru-geo.rsc
scp ru-geo.rsc admin@<router>:ru-geo.rsc
# on RouterOS:  /import file-name=ru-geo.rsc
```

RU allocations change slowly, so even an occasional refresh is fine.

### Reverting

```text
/ip firewall mangle remove [find comment="xray-mark: bypass RU (geo offload)"]
/ip firewall address-list remove [find list=RU]
```
