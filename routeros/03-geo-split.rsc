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
        :local url "https://www.ipdeny.com/ipblocks/data/aggregated/ru-aggregated.zone"
        :do {
            /tool/fetch url=$url mode=https check-certificate=no dst-path="ru-aggregated.zone"
        } on-error={
            :log warning "ru-geo-update: fetch failed, keeping existing RU list"
            :error "fetch failed"
        }
        :delay 2s
        :local data [/file/get [/file/find name="ru-aggregated.zone"] contents]
        :if ([:len $data] < 100) do={
            :log warning "ru-geo-update: empty download, keeping existing RU list"
            :error "empty download"
        }
        /ip firewall address-list remove [find list=RU]
        :local pos 0
        :local len [:len $data]
        :while ($pos < $len) do={
            :local nl [:find $data "\n" $pos]
            :local line
            :if ([:typeof $nl] = "nil") do={
                :set line [:pick $data $pos $len]
                :set pos $len
            } else={
                :set line [:pick $data $pos $nl]
                :set pos ($nl + 1)
            }
            :if ([:len $line] > 6) do={
                :do { /ip firewall address-list add list=RU address=$line } on-error={}
            }
        }
        :log info ("ru-geo-update: RU list rebuilt, entries=" . \
            [:len [/ip firewall address-list find where list=RU]])
    }
}

# --- scheduler: refresh daily -----------------------------------------------
/system scheduler
:if ([:len [find where name="ru-geo-update"]] = 0) do={
    add name=ru-geo-update interval=1d start-time=04:30:00 on-event="/system script run ru-geo-update" comment="refresh RU geo address-list for xray bypass"
}
