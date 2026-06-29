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

### Keeping the list fresh — two paths

**Automatic (on-router).** `03-geo-split.rsc` installs a script + daily
scheduler that re-fetch the list. This needs RouterOS **device-mode** to allow
both features:

```text
/system/device-mode/print          ;# check: fetch and scheduler must be "yes"
/system/device-mode/update fetch=yes scheduler=yes
```

`device-mode/update` requires **physical confirmation** (press the reset/mode
button or power-cycle within the timeout) — it cannot be done purely remotely.
After enabling, import `03-geo-split.rsc` and run the job once:

```text
/import file-name=03-geo-split.rsc
/system script run ru-geo-update
```

**Manual (host-side).** While `fetch` is disabled in device-mode, generate the
list on a workstation and import it. `03-geo-split.rsc` still provides the
mangle rule; only the auto-refresh is dormant.

```bash
./scripts/gen-ru-list.sh ru-geo.rsc
scp ru-geo.rsc admin@<router>:ru-geo.rsc
# on RouterOS:
#   /import file-name=ru-geo.rsc
```

RU allocations change slowly, so a periodic manual refresh is acceptable until
device-mode auto-update is enabled.

### Reverting

```text
/ip firewall mangle remove [find comment="xray-mark: bypass RU (geo offload)"]
/ip firewall address-list remove [find list=RU]
```
