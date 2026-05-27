# 02c-routing-rules-mark.rsc — full-tunnel via mark-routing.
#
# Why this works on MikroTik (unlike 02b's dst-nat REDIRECT):
#   * dst-nat would have rewritten the destination on the RouterOS host,
#     leaving conntrack state on the host's netns. xray inside the container
#     could not read SO_ORIGINAL_DST because conntrack lives in another netns.
#   * Here RouterOS only MARKS packets and forwards them, untouched, to the
#     container as the next-hop gateway. The container itself does
#     `iptables -t nat REDIRECT --to-ports 12345` (set up by entrypoint.sh
#     when REDIRECT_ENABLED=1). conntrack and REDIRECT happen in the same
#     netns as xray, so SO_ORIGINAL_DST works.
#
# Use this INSTEAD of 02-routing-rules.rsc OR 02b-routing-rules-foreign.rsc
# (they all create the `via-xray` routing-table).
#
# Variables — keep in sync with 01-container-setup.rsc:
:local containerAddr      "172.20.0.2"
:local lanInterfaceList   "LAN"
:local blockQuic          true

# ---------- clean up older variants -------------------------------------------
/ip/firewall/nat/remove [find comment~"xray-foreign"]
/ip/firewall/filter/remove [find comment~"xray-foreign"]
/ip/firewall/mangle/remove [find comment~"xray-foreign"]
/ip/firewall/mangle/remove [find comment~"xray-container"]
/ip/route/remove [find routing-table="via-xray"]
:do { /routing/table/remove [find name="via-xray"] } on-error={}

# ---------- routing table — default route goes through the container ----------
/routing/table/add name="via-xray" fib comment="xray full-tunnel"
/ip/route/add \
    dst-address=0.0.0.0/0 \
    gateway=$containerAddr \
    routing-table="via-xray" \
    comment="xray full-tunnel"

# ---------- mangle: mark LAN TCP, bypass private/router-local/DNS -------------
# Order matters; first match wins per chain.

# 1. Never bounce container's own outbound back to itself.
/ip/firewall/mangle/add chain=prerouting src-address=$containerAddr action=accept \
    comment="xray-mark: bypass container itself"

# 2. Anything destined for the router or another local IP stays local.
/ip/firewall/mangle/add chain=prerouting dst-address-type=local action=accept \
    comment="xray-mark: bypass router-local"

# 3. Private/link-local/multicast destinations stay direct.
/ip/firewall/mangle/add chain=prerouting dst-address=10.0.0.0/8     action=accept comment="xray-mark: bypass private 10/8"
/ip/firewall/mangle/add chain=prerouting dst-address=172.16.0.0/12  action=accept comment="xray-mark: bypass private 172.16/12"
/ip/firewall/mangle/add chain=prerouting dst-address=192.168.0.0/16 action=accept comment="xray-mark: bypass private 192.168/16"
/ip/firewall/mangle/add chain=prerouting dst-address=169.254.0.0/16 action=accept comment="xray-mark: bypass link-local"
/ip/firewall/mangle/add chain=prerouting dst-address=224.0.0.0/4    action=accept comment="xray-mark: bypass multicast"

# 4. DNS bypass — let LAN DNS use the router/upstream resolver. xray matches
#    by sniffed SNI, so domain bypass works without DNS through the tunnel.
/ip/firewall/mangle/add chain=prerouting protocol=udp dst-port=53 action=accept comment="xray-mark: bypass DNS udp"
/ip/firewall/mangle/add chain=prerouting protocol=tcp dst-port=53 action=accept comment="xray-mark: bypass DNS tcp"

# 5. Everything else TCP from the LAN -> routing-mark "via-xray".
/ip/firewall/mangle/add \
    chain=prerouting \
    protocol=tcp \
    in-interface-list=$lanInterfaceList \
    action=mark-routing \
    new-routing-mark="via-xray" \
    passthrough=no \
    comment="xray-mark: mark LAN TCP"

# ---------- optional: drop QUIC so browsers fall back to TCP/443 --------------
:if ($blockQuic) do={
    /ip/firewall/filter/add \
        chain=forward \
        protocol=udp \
        src-address=$containerAddr \
        dst-port=443 \
        action=accept \
        comment="xray-mark: bypass container UDP/443"
    /ip/firewall/filter/add \
        chain=forward \
        protocol=udp \
        in-interface-list=$lanInterfaceList \
        dst-port=443 \
        action=drop \
        comment="xray-mark: drop QUIC udp/443"
}

# ---------- summary -----------------------------------------------------------
:put ""
:put "Mark-routing transparent mode active."
:put ("LAN TCP -> via-xray routing-table -> gateway " . $containerAddr)
:put ("Container will REDIRECT to 12345 inside its own netns (conntrack-safe).")
:put ""
:put "xray inside the container decides direct vs balancer using:"
:put "  - sniffed SNI vs BYPASS_DOMAIN"
:put "  - destination IP vs BYPASS_GEOIP (geoip:ru default)"
:put "  - private/loopback (always bypassed)"
:put ""
:if ($blockQuic) do={
    :put "QUIC (udp/443) is dropped to force TCP TLS. Disable via blockQuic=false."
} else={
    :put "QUIC (udp/443) is NOT blocked; it bypasses xray. Set blockQuic=true to force TCP."
}
:put ""
:put "Verify firewall forward chain allows:"
:put "    LAN -> bridge-containers"
:put "    bridge-containers -> WAN"
