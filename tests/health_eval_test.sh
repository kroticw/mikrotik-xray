#!/usr/bin/env bash
# Unit test for the liveness-watchdog failure counter in scripts/entrypoint.sh
# (health_eval). entrypoint.sh runs main() at the bottom, so the function is
# extracted rather than sourced, and exercised as a pure state machine:
# (prev_fails, probe_rc, threshold) → "<new_fails> <reload>".
#
# Run: bash tests/health_eval_test.sh
set -u

here="$(cd "$(dirname "$0")" && pwd)"
entrypoint="${here}/../scripts/entrypoint.sh"
work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT

awk '/^# health_watchdog_loop:/{f=0} /^health_eval\(\)/{f=1} f{print}' \
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

# A successful probe (rc 0) always resets the streak and never reloads.
chk "success resets"        "$(health_eval 0 0 3)" "0 0"
chk "success after fails"   "$(health_eval 2 0 3)" "0 0"

# Failures below the threshold accumulate but do not reload.
chk "first fail"            "$(health_eval 0 1 3)" "1 0"
chk "second fail"          "$(health_eval 1 1 3)" "2 0"

# Reaching the threshold asks for a reload.
chk "third fail reloads"   "$(health_eval 2 1 3)" "3 1"

# Threshold of 1 reloads on the first failure.
chk "threshold 1"          "$(health_eval 0 1 1)" "1 1"

# Threshold 0 disables: a failure increments but never reloads.
chk "threshold 0 disabled" "$(health_eval 5 1 0)" "6 0"

# A non-zero curl exit other than 1 (e.g. 28 timeout) still counts as a failure.
chk "timeout counts"       "$(health_eval 2 28 3)" "3 1"

echo "PASS=${pass} FAIL=${fail}"
[ "${fail}" -eq 0 ]
