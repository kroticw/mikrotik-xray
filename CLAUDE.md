# CLAUDE.md

Guidance for Claude Code when working in this repository.

## What this is

A container image that runs [xray-core](https://github.com/XTLS/Xray-core)
fed by a Remnawave subscription URL, built to run inside a **MikroTik
RouterOS container** (primarily arm64, e.g. hAP ax3). It pulls the
subscription, builds a full xray config (TPROXY/REDIRECT + SOCKS + DNS
inbounds, a balancer over the VLESS outbounds, routing with bypass rules),
runs xray, and keeps it alive.

License: MPL-2.0. This is a **public** repository — never commit secrets
(subscription URLs/tokens), router IPs/MACs/serials, or other private
infrastructure details.

## Layout

- `Containerfile` — multi-stage build. Stage `xray-fetch` downloads and
  SHA-256-verifies the xray-core release for the target arch; the runtime
  stage is Alpine + xray + a non-root user, with a `HEALTHCHECK` that probes
  xray end-to-end through the SOCKS inbound.
- `scripts/entrypoint.sh` — the supervisor. Subscription fetch + parse
  (base64 vless:// links or xray-json, autodetected), config build via `jq`,
  host-side REDIRECT/TPROXY setup, xray process management, periodic refresh,
  geo-database auto-update, and a memory watchdog.
- `build.sh` — builds for `linux/arm64`, exports an OCI tar, optionally
  `scp`s it to a RouterOS disk slot.
- `routeros/`, `adguard/` — `.rsc` setup scripts for the router side.

## Build environment

The dev machine runs **OrbStack** (not Colima — the global standards file is
out of date on this point). `docker` is a real binary backed by OrbStack
with `buildx` available, so `./build.sh --export` works directly. Builds are
native arm64 on Apple Silicon.

```bash
./build.sh --export                 # build + write dist/xray-container.tar
./build.sh --export --push <host>   # also scp the tar to the router
```

## Deploying to RouterOS

RouterOS has **no in-place image swap** — rolling out a new image means
remove + re-add the container. The env list and mount definitions survive a
container remove, so capture the exact add parameters first
(`/container/export`) before removing.

Rollout sequence:

1. `scp` the new tar over the existing one on the router's disk slot.
2. `/container/stop` the container, wait past `stop-time`, `/container/remove`
   (this also clears `root-dir`).
3. `/container/add … file=<slot>/xray-container.tar` with the same
   `interface`, `envlists`, `root-dir`, `name`, restart policy, and
   `memory-max`; then `/container/set … memory-high=…` if needed.
4. `/container/start`, then verify the container reaches the `H` (HEALTHY)
   flag and `memory-current` stays under the cap.

Runtime tunables are kept in a RouterOS **env list** (`/container/envs`), so
most tuning needs no rebuild — only changes to defaults baked into
`entrypoint.sh` do.

## Memory / OOM tuning

The container's recurring failure mode is **OOM**: under load from several
LAN devices xray's RSS climbs (per-connection buffers/goroutines plus an
upstream connection leak — see XTLS/Xray-core #4054, #4294, #5828) until it
hits the cgroup `memory-max` and the kernel kills it (`signal 9` /
`killed due to out of memory` in the RouterOS log). RouterOS exposes **no
per-container file-descriptor limit**, but fd exhaustion is *not* the usual
cause here — confirm via the logs before assuming.

Keep these monotonic so the soft mechanisms fire before the hard kill:

```
GOMEMLIMIT  <  XRAY_MEM_RELOAD_MB (watchdog)  <  cgroup reload (% of max)  <  memory-high  <  memory-max
```

The OOM-killer acts on the **cgroup** memory (anon + kernel socket buffers +
mmap'd geodata), which `VmRSS` undercounts — on a RAM-tight router the cgroup
reaches `memory-max` while `VmRSS` is still below `XRAY_MEM_RELOAD_MB`, so an
RSS-only watchdog never fires and the kernel hard-kills first. The watchdog
therefore reloads on **either** signal, whichever trips first.

Relevant knobs:

- `XRAY_CGROUP_RELOAD_PCT` (default 85) — reload when the container's own
  cgroup memory crosses this percentage of its `memory-max`. This is the
  primary guard; keep it just below `memory-high` so the reload lands before
  the kernel's reclaim throttle (which stalls xray and trips the healthcheck).
  0 disables the cgroup check. `MEM_RELOAD_COOLDOWN_SECONDS` (default 30) is
  the post-reload settle window before checks resume.
- `XRAY_MEM_RELOAD_MB` / `MEM_CHECK_INTERVAL_SECONDS` — RSS fallback: reload
  xray when VmRSS crosses the threshold; a short interval is what catches load
  spikes before the OOM kill.
- `GOMEMLIMIT`, `GOGC` — Go GC pressure (soft heap target; does not cap
  goroutine stacks, so it cannot prevent OOM on its own).
- `POLICY_CONN_IDLE` (default 90s) — idle-connection reap window; shorter
  frees per-connection memory sooner.
- RouterOS `memory-high` (soft, reclaim pressure) and `memory-max` (hard).

## xray-core versioning

xray-core's **stable** release is the latest non-prerelease tag; most recent
tags are marked `prerelease`. Always confirm the actual latest via the GitHub
API (`/repos/XTLS/Xray-core/releases/latest` for stable) rather than from
memory, and verify the `arm64-v8a` asset + `.dgst` exist for the chosen tag
before bumping `XRAY_VERSION` in the `Containerfile`. Bumping to a
pre-release is a deliberate choice (newer leak fixes vs. less battle-testing).

## Conventions

- Branch names: `type/short-description` (e.g. `fix/xray-oom-under-load`).
- Commit per logical block; integrate via squash PR into `master`.
- `entrypoint.sh` targets bash and stays POSIX-ish where practical (no
  associative arrays). Run `bash -n scripts/entrypoint.sh` after edits;
  the generated config is additionally validated by `xray run -test` at
  runtime before it replaces a working config.
