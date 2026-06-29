#!/usr/bin/env bash
# Unit test for the cgroup memory readers in scripts/entrypoint.sh
# (cgroup_mem_used_mb / cgroup_mem_limit_mb). entrypoint.sh runs main() at the
# bottom, so the functions are extracted rather than sourced, and exercised
# against synthetic cgroup v1/v2 trees with CGROUP_ROOT pointed at a temp dir.
#
# Run: bash tests/cgroup_mem_test.sh
set -u

here="$(cd "$(dirname "$0")" && pwd)"
entrypoint="${here}/../scripts/entrypoint.sh"
work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT

awk '/^# memory_watchdog_loop:/{f=0} /^cgroup_mem_used_mb\(\)/{f=1} f{print}' \
    "${entrypoint}" > "${work}/funcs.sh"
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

# cgroup v2: memory.current / memory.max
d="${work}/v2"; mkdir -p "${d}"; CGROUP_ROOT="${d}"
echo 536870912 > "${d}/memory.current"   # 512 MiB
echo 629145600 > "${d}/memory.max"        # 600 MiB
chk "v2 used"  "$(cgroup_mem_used_mb)"  "512"
chk "v2 limit" "$(cgroup_mem_limit_mb)" "600"
echo max > "${d}/memory.max"
chk "v2 unlimited" "$(cgroup_mem_limit_mb)" ""

# cgroup v1: memory/memory.usage_in_bytes / memory.limit_in_bytes
d="${work}/v1"; mkdir -p "${d}/memory"; CGROUP_ROOT="${d}"
echo 314572800 > "${d}/memory/memory.usage_in_bytes"   # 300 MiB
echo 629145600 > "${d}/memory/memory.limit_in_bytes"   # 600 MiB
chk "v1 used"  "$(cgroup_mem_used_mb)"  "300"
chk "v1 limit" "$(cgroup_mem_limit_mb)" "600"
echo 9223372036854771712 > "${d}/memory/memory.limit_in_bytes"   # ~unlimited
chk "v1 unlimited" "$(cgroup_mem_limit_mb)" ""

# unreadable / missing files → nothing
d="${work}/none"; mkdir -p "${d}"; CGROUP_ROOT="${d}"
chk "missing used"  "$(cgroup_mem_used_mb)"  ""
chk "missing limit" "$(cgroup_mem_limit_mb)" ""

# garbage content → nothing (never a bogus number)
d="${work}/bad"; mkdir -p "${d}"; CGROUP_ROOT="${d}"
printf 'oops\n' > "${d}/memory.current"
chk "bad used" "$(cgroup_mem_used_mb)" ""

echo "PASS=${pass} FAIL=${fail}"
[ "${fail}" -eq 0 ]
