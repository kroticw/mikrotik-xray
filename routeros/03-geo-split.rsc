# 03-geo-split.rsc — offload domestic (RU) traffic from the xray container.
#
# Sends only foreign traffic through xray by bypassing RU-destined traffic at
# the router, BEFORE the via-xray routing mark. Previously the container
# terminated every connection just to route RU traffic back out "direct",
# which loaded its file descriptors and memory needlessly. Pre-filtering on the
# router cuts that load at the source.
#
# IPv6 is not proxied through the container (the v6 mangle chain is passthrough
# only), so an IPv4 RU list is sufficient.
#
# device-mode REQUIREMENT: the auto-update script + scheduler below need
#   /system/device-mode  fetch=yes  scheduler=yes
# which require physical confirmation on the device. Until they are enabled,
# import this file ONLY for the mangle rule and populate the RU list manually
# (see routeros/README.md -> "RU geo list").

# --- mangle: bypass RU before the via-xray mark -----------------------------
/ip firewall mangle
:if ([:len [find where comment="xray-mark: bypass RU (geo offload)"]] = 0) do={
    add chain=prerouting action=accept dst-address-list=RU comment="xray-mark: bypass RU (geo offload)" place-before=[find where action=mark-routing and new-routing-mark=via-xray]
}

# --- script: rebuild the RU address-list from ipdeny ------------------------
# Needs device-mode fetch=yes + scheduler=yes. check-certificate=no is used
# because the device has no CA store; the list only steers routing, but for
# stricter safety import the issuing CA and switch to check-certificate=yes.
/system script
:if ([:len [find where name="ru-geo-update"]] = 0) do={
    add name=ru-geo-update policy=read,write,test source={
        # Fetch the pre-built address-list .rsc and import it. RouterOS cannot
        # read a large raw list into a script variable (both /file/get contents
        # and fetch as-value cap at ~63 KB), so the list is built off-box: a CI
        # job regenerates ru-geo.rsc from ipdeny and commits it, and we just
        # fetch + import the file (no size limit on /import). check-certificate=no
        # because the device has no CA store; the file only steers routing.
        :local url "https://raw.githubusercontent.com/kroticw/mikrotik-xray/master/routeros/ru-geo.rsc"
        :do {
            /tool/fetch url=$url mode=https check-certificate=no dst-path="ru-geo.rsc"
        } on-error={
            :log warning "ru-geo-update: fetch failed, keeping existing RU list"
            :error "fetch failed"
        }
        :delay 1s
        :if ([:len [/file/find name="ru-geo.rsc"]] = 0) do={
            :log warning "ru-geo-update: ru-geo.rsc missing after fetch"
            :error "no file"
        }
        /import file-name="ru-geo.rsc"
        :log info ("ru-geo-update: RU list imported, entries=" . \
            [:len [/ip firewall address-list find where list=RU]])
    }
}

# --- scheduler: refresh daily -----------------------------------------------
/system scheduler
:if ([:len [find where name="ru-geo-update"]] = 0) do={
    add name=ru-geo-update interval=1d start-time=04:30:00 on-event="/system script run ru-geo-update" comment="refresh RU geo address-list for xray bypass"
}
