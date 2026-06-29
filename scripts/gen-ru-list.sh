#!/usr/bin/env bash
# gen-ru-list.sh — generate a RouterOS address-list .rsc of RU IPv4 subnets
# from ipdeny, for the geo-split bypass (see routeros/03-geo-split.rsc).
#
# Use this manual path while the router's device-mode has fetch=no, so the
# on-router auto-update cannot run. Produces ru-geo.rsc; import on the router:
#
#   scp ru-geo.rsc admin@<router>:ru-geo.rsc
#   # then on RouterOS:  /import file-name=ru-geo.rsc
#
# Usage: ./scripts/gen-ru-list.sh [output.rsc]
set -o errexit
set -o nounset
set -o pipefail

URL="https://www.ipdeny.com/ipblocks/data/aggregated/ru-aggregated.zone"
OUT="${1:-ru-geo.rsc}"
TMP="$(mktemp)"
trap 'rm -f "${TMP}"' EXIT

curl --silent --show-error --fail --location --max-time 60 --output "${TMP}" "${URL}"

# sanity: the download must be a plain list of IPv4 CIDRs
if grep -qvE '^[0-9]{1,3}(\.[0-9]{1,3}){3}/[0-9]{1,2}$' "${TMP}"; then
    echo "ERROR: non-CIDR lines in download, refusing to generate" >&2
    exit 1
fi

{
    echo "/ip firewall address-list"
    echo "remove [find list=RU]"
    awk '{print "add list=RU address=" $1}' "${TMP}"
} > "${OUT}"

echo "wrote ${OUT} ($(grep -c '^add' "${OUT}") RU entries)"
