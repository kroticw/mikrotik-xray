# 01-container-setup.rsc — install the xray-container on a MikroTik router.
#
# Prerequisites (run once on the router, not part of this script):
#   1. /system/package/print  → confirm `container` package is installed
#   2. /system/device-mode/update container=yes  → physically press reset button
#   3. USB/SD attached. Its `slot` name (run `/disk/print` — column "Slot")
#      is the path prefix for files on that disk. This script uses `usb1/...`
#      matching the default slot for the first USB stick on RouterOS 7.x.
#      Change every `usb1/...` below if your slot is named differently
#      (e.g. `disk1`, `nvme1`, `sata1`).
#   4. Image tar uploaded to `usb1/xray-container.tar` (or your slot).
#
# Variables — edit before sourcing:
:local containerName "xray"
:local containerAddr "172.20.0.2"
:local hostAddr      "172.20.0.1"
:local containerNet  "172.20.0.0/24"
:local bridgeName    "br-containers"
:local vethName      "veth-xray"
:local imageFile     "usb1/xray-container.tar"
:local rootDir       "usb1/xray-root"
:local stateDir      "usb1/xray-state"
:local logsDir       "usb1/xray-logs"

# Subscription configuration — REPLACE with your Remnawave URL.
# Do NOT commit a real URL to a public repo.
:local subscriptionUrl       "https://<domain>/<sub-id>>"
:local subscriptionUserAgent "Xray/26.3.27"
:local subscriptionFormat    "auto"
:local refreshIntervalSec    "43200"
:local balancerStrategy      "leastPing"
:local logLevel              "info"

# Direct-route bypasses applied INSIDE xray, used by both routing modes.
# Used only by `02b-routing-rules-foreign.rsc` in practice (selective mode
# whitelists in vpn-routes, so nothing reaches these rules), but harmless.
#
# Each entry in bypassDomain is a comma-separated xray domain matcher:
#   regexp:<re>   — regex over the FQDN
#   domain:<d>    — match `d` and every subdomain
#   keyword:<k>   — substring match
#   full:<d>      — exact match
#   geosite:<g>   — geosite group from geosite.dat
# NOTE: RouterOS `/import` mangles non-ASCII characters in string literals
# (e.g. `\.рф` becomes `\.    `). Keep this value pure ASCII. The geosite:cn
# group covers Chinese sites incidentally — drop it if you don't want that
# bypass. For Russian-on-foreign-TLD we list explicit domains.
:local bypassDomain          "regexp:\\.ru\$,domain:vk.com,domain:vk.ru,domain:mail.ru,domain:my.com,domain:yandex.com,domain:yandex.net,domain:yandex.ru,domain:sber.com,domain:gosuslugi.ru,domain:ok.ru,domain:dzen.ru,domain:rutube.ru,domain:rt.com"
:local bypassGeoip           "ru"

# ---------- bridge for container traffic --------------------------------------
:if ([:len [/interface/bridge/find name=$bridgeName]] = 0) do={
    /interface/bridge/add name=$bridgeName comment="containers — xray"
    /ip/address/add address=($hostAddr . "/24") interface=$bridgeName
}

# ---------- veth pair attached to the container -------------------------------
:if ([:len [/interface/veth/find name=$vethName]] = 0) do={
    /interface/veth/add name=$vethName address=($containerAddr . "/24") gateway=$hostAddr
}
:if ([:len [/interface/bridge/port/find interface=$vethName]] = 0) do={
    /interface/bridge/port/add bridge=$bridgeName interface=$vethName
}

# ---------- environment for the container -------------------------------------
/container/envs/remove [find list="xray-env"]
/container/envs/add list="xray-env" key="SUBSCRIPTION_URL"        value=$subscriptionUrl
/container/envs/add list="xray-env" key="SUBSCRIPTION_USER_AGENT" value=$subscriptionUserAgent
/container/envs/add list="xray-env" key="SUBSCRIPTION_FORMAT"     value=$subscriptionFormat
/container/envs/add list="xray-env" key="REFRESH_INTERVAL_SECONDS" value=$refreshIntervalSec
/container/envs/add list="xray-env" key="BALANCER_STRATEGY"       value=$balancerStrategy
/container/envs/add list="xray-env" key="LOG_LEVEL"               value=$logLevel
/container/envs/add list="xray-env" key="TPROXY_PORT"             value="12345"
/container/envs/add list="xray-env" key="SOCKS_PORT"              value="10808"
/container/envs/add list="xray-env" key="DNS_PORT"                value="10853"
/container/envs/add list="xray-env" key="BYPASS_DOMAIN"           value=$bypassDomain
/container/envs/add list="xray-env" key="BYPASS_GEOIP"            value=$bypassGeoip
# REDIRECT_ENABLED=1 makes entrypoint install iptables nat REDIRECT in the
# container's own namespace, so xray can read SO_ORIGINAL_DST. Pair with
# routeros/02c-routing-rules.rsc (mark-routing -> gw=container).
/container/envs/add list="xray-env" key="REDIRECT_ENABLED"        value="1"

# ---------- persistent volumes (optional) -------------------------------------
# Disabled by default. RouterOS requires an extra device-mode flag to allow
# bind-mounting host paths into a container, and enabling it needs a physical
# reset-button press. Without mounts, /var/lib/xray and /var/log/xray live in
# the container's ephemeral filesystem and are lost when the container is
# *recreated* (not on regular stop/start).
#
# To enable: add `mounts=yes` (or whatever flag your build exposes) via
#     /system/device-mode/update container=yes mounts=yes
# then press reset within 60s, then uncomment the lines below AND the
# `mount=...` argument in /container/add.
#
# /container/mounts/remove [find list="xray-state"]
# /container/mounts/remove [find list="xray-logs"]
# /container/mounts/add list="xray-state" src=$stateDir dst="/var/lib/xray"
# /container/mounts/add list="xray-logs"  src=$logsDir  dst="/var/log/xray"

# ---------- container itself --------------------------------------------------
:if ([:len [/container/find name=$containerName]] > 0) do={
    :put "container '$containerName' already exists, stopping and removing"
    /container/stop   [find name=$containerName]
    :delay 5s
    /container/remove [find name=$containerName]
}

/container/add \
    file=$imageFile \
    interface=$vethName \
    root-dir=$rootDir \
    envlist="xray-env" \
    logging=yes \
    start-on-boot=yes \
    name=$containerName \
    comment="xray-core with Remnawave subscription"
# To bind /var/lib/xray and /var/log/xray to disk, add this argument once
# the device-mode mount flag is enabled (see comment block above):
#     mount="xray-state,xray-logs" \

# Start it. First boot pulls subscription and builds the config — give it 30s.
/container/start [find name=$containerName]

:put "container started; tail /log/print where topics~\"container\" for status"
:put "container IP:  $containerAddr"
:put "TPROXY port:   12345 (tcp+udp)"
:put "SOCKS5 port:   10808 (tcp)"
:put "DNS port:      10853 (udp)"
