#!/usr/bin/env bash
# entrypoint.sh — supervisor for xray-core fed by a Remnawave subscription URL.
#
# Responsibilities:
#   1. Pull the subscription (xray-json or base64 of vless:// links, autodetected).
#   2. Build a complete xray config: TPROXY + SOCKS5 + DNS inbounds, a
#      `proxy` balancer over all VLESS outbounds, routing that bypasses
#      private/loopback, and an observatory for leastPing.
#   3. Configure host-side TPROXY rules (PREROUTING + ip rule) if CAP_NET_ADMIN
#      is granted; otherwise warn and continue with SOCKS only.
#   4. Run xray, periodically re-fetch the subscription, and atomically
#      restart xray when the resulting config actually changes.

set -o errexit
set -o nounset
set -o pipefail
IFS=$'\n\t'

# ---------- configuration via env ---------------------------------------------

: "${SUBSCRIPTION_URL:?SUBSCRIPTION_URL is required}"
: "${SUBSCRIPTION_USER_AGENT:=Xray/26.3.27}"
: "${SUBSCRIPTION_FORMAT:=auto}"          # auto | xray-json | base64
: "${REFRESH_INTERVAL_SECONDS:=43200}"    # 12h
: "${TPROXY_PORT:=12345}"
: "${SOCKS_PORT:=10808}"
: "${DNS_PORT:=10853}"
: "${BALANCER_STRATEGY:=leastPing}"       # leastPing | random | roundRobin
: "${OBSERVATORY_INTERVAL:=5m}"
: "${LOG_LEVEL:=warning}"
: "${XRAY_CONFIG_DIR:=/etc/xray}"
: "${XRAY_STATE_DIR:=/var/lib/xray}"
: "${BYPASS_PRIVATE:=1}"
# Additional direct-route matchers, applied BEFORE the balancer.
# BYPASS_DOMAIN: CSV of xray domain matchers, each may use prefixes
#   regexp:  — regular expression on the FQDN (e.g. `regexp:\.ru$`)
#   domain:  — match the domain and every subdomain (e.g. `domain:vk.com`)
#   keyword: — substring match
#   full:    — exact match
#   geosite: — match a geosite group baked into geosite.dat
# BYPASS_GEOIP: CSV of GeoIP codes (e.g. `ru,private`).
: "${BYPASS_DOMAIN:=}"
: "${BYPASS_GEOIP:=}"
: "${TPROXY_MARK:=0x1}"
: "${TPROXY_TABLE:=100}"
: "${REDIRECT_ENABLED:=0}"
: "${TPROXY_ENABLED:=0}"
# Geo-database auto-update. The image ships geoip.dat/geosite.dat as a seed;
# they are copied into a writable dir and periodically refreshed from these
# URLs. xray reads them via XRAY_LOCATION_ASSET (exported in main). Set the
# URLs to a reachable mirror if GitHub is blocked. Empty URL disables update
# of that file (seed/baked-in copy is kept).
: "${GEODATA_REFRESH_SECONDS:=86400}"     # 24h
: "${GEODATA_URL_GEOIP:=https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geoip.dat}"
: "${GEODATA_URL_GEOSITE:=https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geosite.dat}"
# Memory watchdog. xray slowly leaks memory under full-tunnel (unbounded
# growth from connections that never fully close — XTLS/Xray-core#4054,#4294);
# policy timeouts only slow it. To avoid the container OOM-killing, reload
# xray (a ~1-2s in-container restart that resets RSS) once its memory crosses
# the soft threshold. 0 disables the watchdog.
: "${XRAY_MEM_RELOAD_MB:=280}"
: "${MEM_CHECK_INTERVAL_SECONDS:=30}"

CONFIG_FILE="${XRAY_CONFIG_DIR}/config.json"
CONFIG_NEW="${XRAY_CONFIG_DIR}/config.json.new"
HASH_FILE="${XRAY_STATE_DIR}/config.sha256"
GEODATA_DIR="${XRAY_STATE_DIR}/geodata"
GEODATA_SEED_DIR="/usr/local/share/xray"
GEODATA_LAST_RUN=0

XRAY_PID=0
REFRESH_PID=0
WATCHDOG_PID=0
SHUTTING_DOWN=0

# ---------- logging -----------------------------------------------------------

log() { printf '[%s] %s\n' "$(date --utc +%FT%TZ)" "$*" >&2; }
die() { log "FATAL: $*"; exit 1; }

# ---------- subscription fetch ------------------------------------------------

# fetch_raw → stdout: raw response body
fetch_raw() {
    curl \
        --silent \
        --show-error \
        --fail \
        --location \
        --max-time 30 \
        --user-agent "${SUBSCRIPTION_USER_AGENT}" \
        --header "Accept: application/json, text/plain" \
        "${SUBSCRIPTION_URL}"
}

# detect_format <raw> → echoes "xray-json" or "base64"
detect_format() {
    local raw="$1"
    local trimmed
    trimmed="$(printf '%s' "$raw" | tr -d '[:space:]')"
    if [ -z "${trimmed}" ]; then
        die "subscription response is empty"
    fi
    case "${SUBSCRIPTION_FORMAT}" in
        xray-json|base64) echo "${SUBSCRIPTION_FORMAT}"; return ;;
    esac
    # auto: JSON if the first non-space char is '{' or '['
    case "${trimmed:0:1}" in
        '{'|'[') echo "xray-json" ;;
        *)       echo "base64" ;;
    esac
}

# ---------- VLESS URI parser → outbound JSON ---------------------------------

# urldecode <encoded> → decoded
urldecode() {
    local s="${1//+/ }"
    printf '%b' "${s//%/\\x}"
}

# parse_vless_uri <uri> <tag> → emits one xray outbound JSON object, or nothing
# Returns non-zero if the URI is not a usable vless:// reality/tls/none link.
parse_vless_uri() {
    local uri="$1"
    local tag="$2"

    [[ "${uri}" =~ ^vless:// ]] || return 1
    local body="${uri#vless://}"

    # split off fragment (#name) if any — we already use $tag, but skip it
    body="${body%%#*}"

    # split userinfo@host:port?query
    local userinfo hostport query
    if [[ "${body}" == *\?* ]]; then
        query="${body#*\?}"
        body="${body%%\?*}"
    else
        query=""
    fi
    userinfo="${body%%@*}"
    hostport="${body#*@}"

    local host port
    # IPv6 literal: [::1]:443
    if [[ "${hostport}" == \[*\]:* ]]; then
        host="${hostport%%]*}"
        host="${host#\[}"
        port="${hostport##*:}"
    else
        host="${hostport%%:*}"
        port="${hostport##*:}"
    fi

    local uuid="${userinfo}"
    [[ -n "${host}" && -n "${port}" && -n "${uuid}" ]] || return 1

    # query parameter helper — no associative arrays, portable to bash 3.2.
    # awk's -v is the POSIX-standard assignment flag (no long alias exists).
    query_get() {
        local key="$1" default="${2:-}" raw
        raw="$(printf '%s' "${query}" \
            | awk -v key="${key}" 'BEGIN{RS="&"; FS="="} $1==key{print $2; exit}')"
        if [ -z "${raw}" ]; then
            printf '%s' "${default}"
        else
            urldecode "${raw}"
        fi
    }

    local type security flow sni fp alpn pbk sid spx path host_hdr service_name grpc_mode header_type
    type="$(query_get type tcp)"
    security="$(query_get security none)"
    flow="$(query_get flow)"
    sni="$(query_get sni "$(query_get peer)")"
    fp="$(query_get fp chrome)"
    alpn="$(query_get alpn)"
    pbk="$(query_get pbk)"
    sid="$(query_get sid)"
    spx="$(query_get spx /)"
    path="$(query_get path /)"
    host_hdr="$(query_get host)"
    service_name="$(query_get serviceName)"
    grpc_mode="$(query_get mode gun)"
    header_type="$(query_get headerType none)"

    # streamSettings.network branch
    local stream_network_json
    case "${type}" in
        tcp)
            if [ "${header_type}" = "http" ]; then
                stream_network_json=$(jq --null-input \
                    --arg path "${path}" --arg host "${host_hdr}" \
                    '{network:"tcp", tcpSettings:{header:{type:"http", request:{path:[$path], headers:(if $host=="" then {} else {Host:[$host]} end)}}}}')
            else
                stream_network_json='{"network":"tcp"}'
            fi
            ;;
        ws)
            # xray 26.x: ws `host` is a top-level field; `headers.Host` is deprecated.
            stream_network_json=$(jq --null-input \
                --arg path "${path}" --arg host "${host_hdr}" \
                '{network:"ws", wsSettings:({path:$path} + (if $host=="" then {} else {host:$host} end))}')
            ;;
        grpc)
            stream_network_json=$(jq --null-input \
                --arg sn "${service_name}" --arg mode "${grpc_mode}" \
                '{network:"grpc", grpcSettings:{serviceName:$sn, multiMode:($mode=="multi")}}')
            ;;
        http|h2)
            stream_network_json=$(jq --null-input \
                --arg path "${path}" --arg host "${host_hdr}" \
                '{network:"http", httpSettings:{path:$path, host:(if $host=="" then [] else [$host] end)}}')
            ;;
        xhttp|splithttp)
            stream_network_json=$(jq --null-input \
                --arg path "${path}" --arg host "${host_hdr}" --arg mode "${grpc_mode}" \
                '{network:"xhttp", xhttpSettings:({path:$path, mode:(if $mode=="gun" then "auto" else $mode end)}
                    + (if $host=="" then {} else {host:$host} end))}')
            ;;
        *)
            log "skip ${tag}: unsupported transport type=${type}"
            return 1
            ;;
    esac

    # streamSettings.security branch
    local stream_security_json
    case "${security}" in
        none)
            stream_security_json='{"security":"none"}'
            ;;
        tls)
            stream_security_json=$(jq --null-input \
                --arg sni "${sni}" --arg fp "${fp}" --arg alpn "${alpn}" \
                '{security:"tls", tlsSettings:({serverName:$sni, fingerprint:$fp}
                    + (if $alpn=="" then {} else {alpn:($alpn|split(","))} end))}')
            ;;
        reality)
            [[ -n "${pbk}" && -n "${sni}" ]] || { log "skip ${tag}: reality without pbk/sni"; return 1; }
            stream_security_json=$(jq --null-input \
                --arg sni "${sni}" --arg fp "${fp}" --arg pbk "${pbk}" \
                --arg sid "${sid}" --arg spx "${spx}" \
                '{security:"reality", realitySettings:{serverName:$sni, fingerprint:$fp, publicKey:$pbk, shortId:$sid, spiderX:$spx}}')
            ;;
        *)
            log "skip ${tag}: unsupported security=${security}"
            return 1
            ;;
    esac

    jq --null-input \
        --arg tag "${tag}" \
        --arg addr "${host}" \
        --argjson port "${port}" \
        --arg uuid "${uuid}" \
        --arg flow "${flow}" \
        --argjson stream_net "${stream_network_json}" \
        --argjson stream_sec "${stream_security_json}" \
        '{
            tag: $tag,
            protocol: "vless",
            settings: {
                vnext: [{
                    address: $addr,
                    port: $port,
                    users: [{
                        id: $uuid,
                        encryption: "none"
                    } + (if $flow=="" then {} else {flow:$flow} end)]
                }]
            },
            streamSettings: ($stream_net + $stream_sec)
        }'
}

# parse_base64_subscription <raw> → emits a JSON array of outbounds
parse_base64_subscription() {
    local raw="$1"
    local decoded
    # Remnawave/sub-link conventions often use URL-safe base64 and may omit padding.
    decoded="$(printf '%s' "${raw}" | tr -d '[:space:]' | tr '_-' '/+')"
    # pad to a multiple of 4
    local pad=$(( (4 - ${#decoded} % 4) % 4 ))
    decoded="${decoded}$(printf '=%.0s' $(seq 1 "${pad}"))"
    decoded="$(printf '%s' "${decoded}" | base64 -d 2>/dev/null || true)"
    [ -n "${decoded}" ] || die "failed to base64-decode subscription"

    local out='[]'
    local line idx=0 tag name
    while IFS= read -r line; do
        line="$(printf '%s' "${line}" | tr -d '\r')"
        [ -z "${line}" ] && continue
        # extract name from #fragment for human-readable tag
        name=""
        if [[ "${line}" == *\#* ]]; then
            name="$(urldecode "${line#*#}")"
        fi
        idx=$(( idx + 1 ))
        tag="vless-$(printf '%s' "${name:-server-${idx}}" \
            | tr ' /:' '___' | tr -cd 'A-Za-z0-9._-' | cut -c1-48)"
        # ensure uniqueness if names collide
        tag="${tag}-${idx}"

        local outbound preview
        # Truncate URI for logging without leaking the UUID/key fully.
        preview="$(printf '%s' "${line}" | cut -c1-12)…$(printf '%s' "${line}" | awk -F'?' '{print "?" substr($2,1,40)}')"
        if outbound="$(parse_vless_uri "${line}" "${tag}")"; then
            out="$(printf '%s' "${out}" | jq --argjson o "${outbound}" '. + [$o]')"
        else
            log "skip line ${idx}: ${preview}"
        fi
    done <<< "${decoded}"

    [ "$(printf '%s' "${out}" | jq 'length')" -gt 0 ] || die "no vless outbounds parsed from base64 subscription"
    printf '%s' "${out}"
}

# parse_xray_json_subscription <raw> → emits a JSON array of outbounds
# Accepts either a full xray config (has .outbounds) or a bare outbounds array.
parse_xray_json_subscription() {
    local raw="$1"
    local outbounds
    if outbounds="$(printf '%s' "${raw}" | jq -c '
        if type == "object" and has("outbounds") then .outbounds
        elif type == "array" then .
        else error("not an xray config")
        end
        | map(select(.protocol == "vless"))
    ' 2>/dev/null)" && [ "$(printf '%s' "${outbounds}" | jq 'length')" -gt 0 ]; then
        # ensure tags exist and are prefixed
        printf '%s' "${outbounds}" | jq -c '
            to_entries | map(
                (.value.tag //= ("vless-server-" + ((.key+1)|tostring)))
                | (if (.value.tag | startswith("vless-")) then .value
                   else .value + {tag: ("vless-" + .value.tag)}
                   end)
            )
        '
        return 0
    fi
    return 1
}

# ---------- xray config builder ----------------------------------------------

build_config() {
    local outbounds_json="$1"

    # selector accepts tag prefixes; "vless-" matches every tag we emit in
    # parse_vless_uri / parse_xray_json_subscription. observatory uses the same.
    local selector_prefix='["vless-"]'

    local privacy_rules='[]'
    if [ "${BYPASS_PRIVATE}" = "1" ]; then
        privacy_rules='[
            {"type":"field","outboundTag":"direct","ip":["geoip:private"]},
            {"type":"field","outboundTag":"direct","domain":["geosite:private"]}
        ]'
    fi

    # Build direct-route bypass rules from BYPASS_DOMAIN / BYPASS_GEOIP.
    # Each comma-separated entry becomes one matcher inside a single rule.
    local bypass_domain_arr='[]'
    if [ -n "${BYPASS_DOMAIN}" ]; then
        bypass_domain_arr="$(printf '%s' "${BYPASS_DOMAIN}" \
            | jq --raw-input '
                split(",")
                | map(gsub("^\\s+|\\s+$"; ""))
                | map(select(length > 0))
            ')"
    fi
    local bypass_geoip_arr='[]'
    if [ -n "${BYPASS_GEOIP}" ]; then
        bypass_geoip_arr="$(printf '%s' "${BYPASS_GEOIP}" \
            | jq --raw-input '
                split(",")
                | map(gsub("^\\s+|\\s+$"; ""))
                | map(select(length > 0))
                | map("geoip:" + .)
            ')"
    fi
    local bypass_rules
    bypass_rules="$(jq --null-input \
        --argjson dom "${bypass_domain_arr}" \
        --argjson gip "${bypass_geoip_arr}" '
        [
          (if ($dom | length) > 0
           then {type:"field", outboundTag:"direct", domain:$dom}
           else empty end),
          (if ($gip | length) > 0
           then {type:"field", outboundTag:"direct", ip:$gip}
           else empty end)
        ]
    ')"

    jq --null-input \
        --argjson outbounds        "${outbounds_json}" \
        --argjson selector_prefix  "${selector_prefix}" \
        --argjson privacy_rules    "${privacy_rules}" \
        --argjson bypass_rules     "${bypass_rules}" \
        --arg     log_level        "${LOG_LEVEL}" \
        --argjson tproxy_port      "${TPROXY_PORT}" \
        --argjson socks_port       "${SOCKS_PORT}" \
        --argjson dns_port         "${DNS_PORT}" \
        --arg     strategy         "${BALANCER_STRATEGY}" \
        --arg     probe_interval   "${OBSERVATORY_INTERVAL}" \
        '{
            log: { loglevel: $log_level },
            policy: {
                # Bound per-connection memory and reap stuck/idle connections.
                # Under full-tunnel xray holds a buffer + goroutines per LAN
                # connection; without these caps memory grows unbounded as
                # half-open/idle connections accumulate (see XTLS/Xray-core
                # #4054, #4294). bufferSize caps per-direction RAM; connIdle
                # closes silent connections so they stop pinning memory.
                levels: {
                    "0": {
                        handshake: 4,
                        connIdle: 180,
                        uplinkOnly: 2,
                        downlinkOnly: 4,
                        bufferSize: 64
                    }
                },
                system: {
                    statsInboundUplink: false,
                    statsInboundDownlink: false,
                    statsOutboundUplink: false,
                    statsOutboundDownlink: false
                }
            },
            dns: {
                servers: [
                    { address: "1.1.1.1", domains: ["geosite:geolocation-!cn"] },
                    { address: "8.8.8.8", skipFallback: true },
                    "localhost"
                ]
            },
            inbounds: [
                {
                    # TCP REDIRECT mode: host (RouterOS) dst-nats packets here,
                    # xray reads original destination via SO_ORIGINAL_DST.
                    # UDP cannot use SO_ORIGINAL_DST: it needs real TPROXY,
                    # which the MikroTik container kernel does not expose.
                    tag: "tproxy-in",
                    listen: "0.0.0.0",
                    port: $tproxy_port,
                    protocol: "dokodemo-door",
                    settings: { network: "tcp", followRedirect: true },
                    sniffing: { enabled: true, destOverride: ["http","tls","quic"], routeOnly: false }
                },
                {
                    tag: "socks-in",
                    listen: "0.0.0.0",
                    port: $socks_port,
                    protocol: "socks",
                    settings: { auth: "noauth", udp: true },
                    sniffing: { enabled: true, destOverride: ["http","tls","quic"] }
                },
                {
                    tag: "dns-in",
                    listen: "0.0.0.0",
                    port: $dns_port,
                    protocol: "dokodemo-door",
                    settings: { address: "1.1.1.1", port: 53, network: "tcp,udp" }
                }
            ],
            outbounds: ([
                { tag: "direct",    protocol: "freedom",   settings: { domainStrategy: "UseIP" } },
                { tag: "blackhole", protocol: "blackhole", settings: {} },
                { tag: "dns-out",   protocol: "dns",       settings: {} }
            ] + $outbounds),
            routing: {
                domainStrategy: "IPIfNonMatch",
                rules: ($privacy_rules + $bypass_rules + [
                    { type: "field", inboundTag: ["dns-in"], outboundTag: "dns-out" },
                    { type: "field", port: "53", outboundTag: "dns-out" },
                    # xray 26.x rejects rules with no matching criterion, so anchor
                    # the default route on our inbound tags.
                    { type: "field", inboundTag: ["tproxy-in", "socks-in"], balancerTag: "proxy" }
                ]),
                balancers: [
                    {
                        tag: "proxy",
                        selector: $selector_prefix,
                        strategy: { type: $strategy }
                    }
                ]
            },
            observatory: {
                subjectSelector: $selector_prefix,
                probeUrl: "http://www.gstatic.com/generate_204",
                probeInterval: $probe_interval
            }
        }'
}

# ---------- geo-database management ------------------------------------------

# init_geodata: ensure GEODATA_DIR holds usable geoip.dat/geosite.dat, seeding
# from the image's baked-in copy when absent, and point xray at the writable
# dir. Must run before the first config validation so geoip:/geosite: matchers
# resolve.
init_geodata() {
    mkdir --parents "${GEODATA_DIR}"
    local f
    for f in geoip.dat geosite.dat; do
        if [ ! -s "${GEODATA_DIR}/${f}" ] && [ -s "${GEODATA_SEED_DIR}/${f}" ]; then
            cp "${GEODATA_SEED_DIR}/${f}" "${GEODATA_DIR}/${f}"
            log "geodata: seeded ${f} from image"
        fi
    done
    export XRAY_LOCATION_ASSET="${GEODATA_DIR}"
}

# fetch_one_geodata <filename> <url>: download atomically into GEODATA_DIR.
# Returns 10 if the file changed, 0 if unchanged or URL empty, 1 on failure
# (the existing file is always kept on failure).
fetch_one_geodata() {
    local f="$1" url="$2" tmp new_hash old_hash
    [ -n "${url}" ] || return 0
    tmp="${GEODATA_DIR}/.${f}.tmp"
    if ! curl --silent --show-error --fail --location --max-time 120 \
            --output "${tmp}" "${url}"; then
        rm --force "${tmp}" 2>/dev/null || true
        log "geodata: ${f} download failed, keeping existing copy"
        return 1
    fi
    if [ ! -s "${tmp}" ]; then
        rm --force "${tmp}" 2>/dev/null || true
        log "geodata: ${f} download empty, skipped"
        return 1
    fi
    new_hash="$(sha256sum "${tmp}" | awk '{print $1}')"
    old_hash="$(sha256sum "${GEODATA_DIR}/${f}" 2>/dev/null | awk '{print $1}')"
    if [ "${new_hash}" = "${old_hash}" ]; then
        rm --force "${tmp}"
        return 0
    fi
    mv --force "${tmp}" "${GEODATA_DIR}/${f}"
    log "geodata: ${f} updated (${new_hash:0:12})"
    return 10
}

# fetch_geodata: refresh both geo files. Returns 10 if any changed (caller
# should reload xray to pick them up), else 0. Download errors are non-fatal.
fetch_geodata() {
    local changed=0 rc
    rc=0; fetch_one_geodata geoip.dat   "${GEODATA_URL_GEOIP}"   || rc=$?
    [ "${rc}" -eq 10 ] && changed=1
    rc=0; fetch_one_geodata geosite.dat "${GEODATA_URL_GEOSITE}" || rc=$?
    [ "${rc}" -eq 10 ] && changed=1
    GEODATA_LAST_RUN="$(date +%s)"
    [ "${changed}" -eq 1 ] && return 10
    return 0
}

# ---------- subscription pipeline --------------------------------------------

refresh_config_once() {
    local raw outbounds new_hash old_hash format
    log "fetching subscription"
    raw="$(fetch_raw)" || { log "fetch failed"; return 1; }

    format="$(detect_format "${raw}")"
    log "subscription format: ${format}"

    if [ "${format}" = "xray-json" ]; then
        if ! outbounds="$(parse_xray_json_subscription "${raw}")"; then
            log "xray-json had no vless outbounds, falling back to base64"
            outbounds="$(parse_base64_subscription "${raw}")"
        fi
    else
        outbounds="$(parse_base64_subscription "${raw}")"
    fi

    local count
    count="$(printf '%s' "${outbounds}" | jq 'length')"
    log "parsed ${count} vless outbound(s)"

    build_config "${outbounds}" > "${CONFIG_NEW}"
    log "validating new config"
    local test_out
    if ! test_out="$(xray run -test -format json -config "${CONFIG_NEW}" 2>&1)"; then
        log "ERROR: new config rejected by 'xray run -test':"
        printf '%s\n' "${test_out}" | sed 's/^/    xray-test: /' >&2
        log "keeping previous config; saving rejected one to ${CONFIG_NEW}.rejected for inspection"
        mv --force "${CONFIG_NEW}" "${CONFIG_NEW}.rejected"
        return 1
    fi

    new_hash="$(sha256sum "${CONFIG_NEW}" | awk '{print $1}')"
    old_hash="$(cat "${HASH_FILE}" 2>/dev/null || true)"

    mv --force "${CONFIG_NEW}" "${CONFIG_FILE}"
    printf '%s\n' "${new_hash}" > "${HASH_FILE}"

    if [ "${new_hash}" != "${old_hash}" ]; then
        log "config updated (hash ${new_hash:0:12})"
        return 10        # exit-code-as-signal: caller should restart xray
    fi
    log "config unchanged"
    return 0
}

# ---------- inbound helper ----------------------------------------------------
# Three modes, controlled via env:
#
#   REDIRECT_ENABLED=1   (recommended on MikroTik) — install
#       iptables -t nat PREROUTING REDIRECT to :TPROXY_PORT, enable ip_forward
#       so transit packets coming through veth get caught by the local socket.
#       xray reads original destination via SO_ORIGINAL_DST (`followRedirect`).
#       Requires the kernel to expose `xt_REDIRECT` + conntrack (it does on
#       RouterOS 7.x containers — verified empirically).
#
#   TPROXY_ENABLED=1     — classic Linux TPROXY iptables setup. Needs the
#       TPROXY module in kernel; MikroTik containers DO NOT expose it, so
#       this branch is only useful on generic Linux hosts.
#
#   neither               — xray just listens on the inbound, host is
#       responsible for delivering traffic by some external means
#       (e.g. SOCKS5 clients connecting to :SOCKS_PORT).

setup_inbound() {
    if [ "${REDIRECT_ENABLED:-0}" = "1" ]; then
        setup_inbound_redirect
        return
    fi
    if [ "${TPROXY_ENABLED:-0}" = "1" ]; then
        setup_inbound_tproxy
        return
    fi
    log "No transparent-redirect mode enabled."
    log "SOCKS5 is reachable on :${SOCKS_PORT}; configure clients manually."
}

setup_inbound_redirect() {
    if ! iptables --table nat --list-rules >/dev/null 2>&1; then
        log "WARN: REDIRECT_ENABLED=1 but iptables nat not usable — falling back to SOCKS-only"
        return 0
    fi

    # The xray socket is in this namespace, so packets must be forwarded into
    # the input path. ip_forward=1 + REDIRECT does that: PREROUTING rewrites
    # destination to a local socket BEFORE the routing decision.
    sysctl --write net.ipv4.ip_forward=1 >/dev/null 2>&1 || true

    iptables --table nat --new-chain XRAY 2>/dev/null || iptables --table nat --flush XRAY
    iptables --table nat --append XRAY --protocol tcp --jump REDIRECT --to-ports "${TPROXY_PORT}"
    iptables --table nat --check PREROUTING --jump XRAY 2>/dev/null \
        || iptables --table nat --append PREROUTING --jump XRAY

    log "REDIRECT rules installed (PREROUTING tcp -> :${TPROXY_PORT}); ip_forward=1"
}

setup_inbound_tproxy() {
    if ! iptables --table mangle --list-rules >/dev/null 2>&1; then
        log "WARN: TPROXY_ENABLED=1 but no NET_ADMIN — TPROXY inbound will not receive traffic"
        return 0
    fi

    iptables --table mangle --new-chain XRAY 2>/dev/null || iptables --table mangle --flush XRAY
    iptables --table mangle --append XRAY --protocol tcp --jump TPROXY --on-port "${TPROXY_PORT}" --on-ip 127.0.0.1 --tproxy-mark "${TPROXY_MARK}"
    iptables --table mangle --append XRAY --protocol udp --jump TPROXY --on-port "${TPROXY_PORT}" --on-ip 127.0.0.1 --tproxy-mark "${TPROXY_MARK}"
    iptables --table mangle --check PREROUTING --jump XRAY 2>/dev/null \
        || iptables --table mangle --append PREROUTING --jump XRAY

    ip rule del fwmark "${TPROXY_MARK}" table "${TPROXY_TABLE}" 2>/dev/null || true
    ip rule add fwmark "${TPROXY_MARK}" table "${TPROXY_TABLE}"
    ip route replace local default dev lo table "${TPROXY_TABLE}"

    log "TPROXY rules installed (mark=${TPROXY_MARK}, table=${TPROXY_TABLE}, port=${TPROXY_PORT})"
}

# ---------- xray process management ------------------------------------------

start_xray() {
    log "starting xray (config=${CONFIG_FILE})"
    xray run -config "${CONFIG_FILE}" &
    XRAY_PID=$!
    log "xray pid=${XRAY_PID}"
}

stop_xray() {
    [ "${XRAY_PID}" -gt 0 ] || return 0
    if kill -0 "${XRAY_PID}" 2>/dev/null; then
        log "stopping xray pid=${XRAY_PID}"
        kill -TERM "${XRAY_PID}" 2>/dev/null || true
        # wait up to 5s
        local i=0
        while kill -0 "${XRAY_PID}" 2>/dev/null && [ "${i}" -lt 50 ]; do
            sleep 0.1
            i=$(( i + 1 ))
        done
        kill -KILL "${XRAY_PID}" 2>/dev/null || true
        wait "${XRAY_PID}" 2>/dev/null || true
    fi
    XRAY_PID=0
}

refresh_loop() {
    while sleep "${REFRESH_INTERVAL_SECONDS}" & wait $!; do
        if [ "${SHUTTING_DOWN}" = "1" ]; then return 0; fi
        local need_reload=0 rc=0
        refresh_config_once || rc=$?
        if [ "${rc}" -eq 10 ]; then
            need_reload=1
        elif [ "${rc}" -ne 0 ]; then
            log "refresh failed (rc=${rc}), will retry next cycle"
        fi
        # Geo-databases refresh on their own (slower) cadence.
        local now
        now="$(date +%s)"
        if [ "$(( now - GEODATA_LAST_RUN ))" -ge "${GEODATA_REFRESH_SECONDS}" ]; then
            rc=0; fetch_geodata || rc=$?
            [ "${rc}" -eq 10 ] && need_reload=1
        fi
        if [ "${need_reload}" -eq 1 ]; then
            log "config/geodata changed → restarting xray"
            kill -USR1 "$$" 2>/dev/null || true
        fi
    done
}

# xray_rss_mb → echoes the resident set size of the running xray in MiB, or
# nothing if xray is not found. Uses pidof so it tracks the current pid across
# reloads (the watchdog runs in a subshell and cannot see XRAY_PID updates).
xray_rss_mb() {
    local pid rss_kb
    pid="$(pidof xray 2>/dev/null | awk '{print $1}')"
    [ -n "${pid}" ] || return 0
    rss_kb="$(awk '/^VmRSS:/{print $2}' "/proc/${pid}/status" 2>/dev/null)"
    [ -n "${rss_kb}" ] && printf '%s' "$(( rss_kb / 1024 ))"
}

# memory_watchdog_loop: periodically reload xray once its RSS crosses the soft
# threshold, reclaiming memory before the container hits its hard cgroup limit
# and gets OOM-killed. Signals the parent (USR1) so reload runs in the main
# context, like refresh_loop.
memory_watchdog_loop() {
    [ "${XRAY_MEM_RELOAD_MB}" -gt 0 ] 2>/dev/null || { log "memory-watchdog disabled"; return 0; }
    log "memory-watchdog: reload xray when RSS >= ${XRAY_MEM_RELOAD_MB}MiB (every ${MEM_CHECK_INTERVAL_SECONDS}s)"
    while sleep "${MEM_CHECK_INTERVAL_SECONDS}" & wait $!; do
        [ "${SHUTTING_DOWN}" = "1" ] && return 0
        local rss
        rss="$(xray_rss_mb)"
        [ -n "${rss}" ] || continue
        if [ "${rss}" -ge "${XRAY_MEM_RELOAD_MB}" ]; then
            log "memory-watchdog: xray RSS ${rss}MiB >= ${XRAY_MEM_RELOAD_MB}MiB → reloading xray"
            kill -USR1 "$$" 2>/dev/null || true
        fi
    done
}

# ---------- signal handling --------------------------------------------------

shutdown() {
    [ "${SHUTTING_DOWN}" = "1" ] && return 0
    SHUTTING_DOWN=1
    log "shutting down"
    [ "${REFRESH_PID}" -gt 0 ] && kill -TERM "${REFRESH_PID}" 2>/dev/null || true
    [ "${WATCHDOG_PID}" -gt 0 ] && kill -TERM "${WATCHDOG_PID}" 2>/dev/null || true
    stop_xray
    exit 0
}

reload_xray() {
    [ "${SHUTTING_DOWN}" = "1" ] && return 0
    log "reload signal received"
    stop_xray
    start_xray
}

trap shutdown    TERM INT QUIT
trap reload_xray USR1

# ---------- main --------------------------------------------------------------

main() {
    mkdir --parents "${XRAY_CONFIG_DIR}" "${XRAY_STATE_DIR}"

    setup_inbound

    init_geodata
    log "refreshing geo-databases (geoip/geosite)"
    fetch_geodata || true

    log "performing initial subscription fetch"
    local rc=0
    refresh_config_once || rc=$?
    if [ "${rc}" -ne 0 ] && [ "${rc}" -ne 10 ]; then
        die "initial subscription fetch failed"
    fi

    start_xray
    refresh_loop &
    REFRESH_PID=$!
    log "refresh loop pid=${REFRESH_PID}, interval=${REFRESH_INTERVAL_SECONDS}s"

    memory_watchdog_loop &
    WATCHDOG_PID=$!

    # block until xray exits or a signal forces shutdown.
    # Loop because USR1 trap re-spawns xray and we must wait on the new pid.
    while [ "${XRAY_PID}" -gt 0 ]; do
        wait "${XRAY_PID}" 2>/dev/null || true
        if [ "${SHUTTING_DOWN}" = "1" ]; then break; fi
        # if xray died on its own (not via our reload), retry after backoff
        if kill -0 "${XRAY_PID}" 2>/dev/null; then
            continue
        fi
        log "xray exited unexpectedly, restarting in 3s"
        sleep 3
        [ "${SHUTTING_DOWN}" = "1" ] && break
        start_xray
    done
}

main "$@"
