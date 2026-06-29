#!/usr/bin/env bash
# Unit test for the Shadowsocks URI parser in scripts/entrypoint.sh
# (parse_ss_uri). entrypoint.sh runs main() at the bottom, so the URI parsers
# are extracted (urldecode .. parse_ss_uri) rather than sourced, with log/die
# stubbed, and exercised against crafted ss:// links.
#
# Run: bash tests/ss_uri_test.sh
set -u

here="$(cd "$(dirname "$0")" && pwd)"
entrypoint="${here}/../scripts/entrypoint.sh"
work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT

# Extract the URI-parser block: from urldecode() down to the end of parse_ss_uri
# (the next thing is the parse_base64_subscription comment).
awk '/^# parse_base64_subscription/{f=0} /^urldecode\(\)/{f=1} f{print}' \
    "${entrypoint}" > "${work}/funcs.sh"
log()  { :; }   # silence the skip diagnostics the parsers emit
die()  { echo "die: $*" >&2; return 1; }
# shellcheck source=/dev/null
. "${work}/funcs.sh"

pass=0; fail=0
chk() {
    if [ "$2" = "$3" ]; then
        pass=$((pass + 1))
    else
        fail=$((fail + 1))
        echo "FAIL ${1}: got '${2}' want '${3}'"
    fi
}

# SS2022: userinfo is base64(method:serverKey:userKey); the password xray wants
# is everything after the first colon (serverKey:userKey, keeping its colon).
method="2022-blake3-aes-256-gcm"
server_key="s3IKxJwoZxxWU3kZenHFYdHuvhmfzvF1CgkpJOxVI4="
user_key="empwc2RhdERCN0Nnc1dUb1lKWDl0NHM5eGZ6clRwa3E="
userinfo="$(printf '%s:%s:%s' "${method}" "${server_key}" "${user_key}" | base64 | tr -d '\n')"
uri="ss://${userinfo}@178.154.217.235:1234#%F0%9F%87%B7%20ss-2022"

out="$(parse_ss_uri "${uri}" "ss-test-1")"
chk "protocol" "$(printf '%s' "${out}" | jq -r '.protocol')"               "shadowsocks"
chk "tag"      "$(printf '%s' "${out}" | jq -r '.tag')"                    "ss-test-1"
chk "address"  "$(printf '%s' "${out}" | jq -r '.settings.servers[0].address')" "178.154.217.235"
chk "port"     "$(printf '%s' "${out}" | jq -r '.settings.servers[0].port')"    "1234"
chk "method"   "$(printf '%s' "${out}" | jq -r '.settings.servers[0].method')"  "${method}"
chk "password" "$(printf '%s' "${out}" | jq -r '.settings.servers[0].password')" "${server_key}:${user_key}"
chk "network"  "$(printf '%s' "${out}" | jq -r '.streamSettings.network')"  "tcp"

# Plain (non-base64) userinfo: method:password where password has no colon.
uri2="ss://aes-128-gcm:hunter2@10.0.0.1:8388#plain"
out2="$(parse_ss_uri "${uri2}" "ss-test-2")"
chk "plain method"   "$(printf '%s' "${out2}" | jq -r '.settings.servers[0].method')"   "aes-128-gcm"
chk "plain password" "$(printf '%s' "${out2}" | jq -r '.settings.servers[0].password')" "hunter2"

# Non-ss scheme → rejected (no output, non-zero).
if parse_ss_uri "vless://uuid@host:443" "x" >/dev/null 2>&1; then
    fail=$((fail + 1)); echo "FAIL reject-vless: accepted a vless:// uri"
else
    pass=$((pass + 1))
fi

# Plugin query → unsupported, rejected.
if parse_ss_uri "ss://${userinfo}@1.2.3.4:1234?plugin=v2ray" "x" >/dev/null 2>&1; then
    fail=$((fail + 1)); echo "FAIL reject-plugin: accepted an ss:// uri with a plugin"
else
    pass=$((pass + 1))
fi

echo "PASS=${pass} FAIL=${fail}"
[ "${fail}" -eq 0 ]
