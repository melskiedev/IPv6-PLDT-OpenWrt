#!/bin/sh
# tests/test-reachability-confirmation.sh
#
# Test harness for ipv6-watchdog v3.9.9 reachability confirmation delay.
# Verifies that transient IPv6 reachability misses are suppressed and only
# confirmed Layer-3 failures produce the new validation log.
#
# Tests the actual script logic via stub commands and temp state dirs.
# Does not require a live router.
#
# Usage: bash tests/test-reachability-confirmation.sh
# Exit:  0 = all pass, 1 = any fail

# --- Locate repo root ---
TEST_SCRIPT="$0"
SCRIPT_DIR="$(cd "$(dirname "$TEST_SCRIPT")/.." && pwd)"

# --- Create temp workspace ---
TEST_ROOT="$(mktemp -d 2>/dev/null || { D="/tmp/rctest-$$"; mkdir -p "$D"; echo "$D"; })"
STUB_DIR="$TEST_ROOT/stubs"
STATE_DIR="$TEST_ROOT/state"
CTRL_DIR="$TEST_ROOT/ctrl"
LOG_FILE="$TEST_ROOT/log.txt"
CONF_FILE="$TEST_ROOT/test.conf"
WATCHDOG_TEST="$TEST_ROOT/ipv6-watchdog.test"

ORIG_PATH="$PATH"
export RC_CTRL="$CTRL_DIR"
export RC_LOG="$LOG_FILE"

mkdir -p "$STUB_DIR" "$STATE_DIR" "$CTRL_DIR"

# --- Cleanup on exit ---
cleanup() {
    rm -rf "$TEST_ROOT"
}
trap cleanup EXIT
trap 'cleanup; exit 130' INT
trap 'cleanup; exit 143' TERM

# ================================================================
# Stub executables
# ================================================================

# ubus: outputs JSON for wan6 status based on control files
cat > "$STUB_DIR/ubus" <<'STUBEOF'
#!/bin/sh
CTRL="${RC_CTRL:-/tmp/rctest-ctrl}"
if [ "$1" = "call" ] && [ "$2" = "network.interface.wan6" ] && [ "$3" = "status" ]; then
    if [ -f "$CTRL/wan6_up" ]; then
        DEV=""
        [ -f "$CTRL/wan_dev" ] && DEV=$(cat "$CTRL/wan_dev")
        PREFIX_PART=""
        if [ -f "$CTRL/has_prefix" ]; then
            ADDR="2001:db8:1234:5678::1"
            [ -f "$CTRL/prefix_addr" ] && ADDR=$(cat "$CTRL/prefix_addr")
            PREFIX_PART='"ipv6-prefix":[{"address":"'"$ADDR"'"}],'
        fi
        printf '{"up":true,"l3_device":"%s",%s"pending":false}' "$DEV" "$PREFIX_PART"
    else
        printf '{"up":false}'
    fi
fi
STUBEOF
chmod +x "$STUB_DIR/ubus"

# jsonfilter: extracts fields from JSON on stdin
cat > "$STUB_DIR/jsonfilter" <<'STUBEOF'
#!/bin/sh
INPUT=$(cat)
case "$2" in
    *'"up"'*)
        printf '%s' "$INPUT" | sed -n 's/.*"up":\([a-z]*\).*/\1/p'
        ;;
    *'"l3_device"'*)
        printf '%s' "$INPUT" | sed -n 's/.*"l3_device":"\([^"]*\)".*/\1/p'
        ;;
    *'"ipv6-prefix"'*)
        printf '%s' "$INPUT" | sed -n 's/.*"address":"\([^"]*\)".*/\1/p'
        ;;
esac
STUBEOF
chmod +x "$STUB_DIR/jsonfilter"

# ip: outputs default route if control flag exists.
# Also supports neigh show and route del/replace for fix_gateway.
cat > "$STUB_DIR/ip" <<'STUBEOF'
#!/bin/sh
CTRL="${RC_CTRL:-/tmp/rctest-ctrl}"
# Default route display
if [ "$1" = "-6" ] && [ "$2" = "route" ] && [ "$3" = "show" ] && [ "$4" = "default" ]; then
    if [ -f "$CTRL/has_route" ]; then
        echo "default via fe80::1 dev eth0 metric 512"
    fi
    exit 0
fi
# Neighbor show (used by gateway_mac and candidate scan)
if [ "$1" = "-6" ] && [ "$2" = "neigh" ] && [ "$3" = "show" ]; then
    if [ -f "$CTRL/neigh_router" ]; then
        echo "fe80::1 dev eth0 lladdr 00:11:22:33:44:55 router REACHABLE"
    fi
    exit 0
fi
# neigh replace / route replace / route del: no-op success
exit 0
STUBEOF
chmod +x "$STUB_DIR/ip"

# ping6: stateful stub driven by a sequence control file.
# $RC_CTRL/ping_seq holds a space-separated list of "pass"/"fail" outcomes,
# consumed in order per ping6 invocation across the whole run. Each ping6
# call consumes one token (two ping6 invocations happen per internet_ok_now
# only when the first fails; a single pass short-circuits). When the list
# is exhausted, default is "fail".
cat > "$STUB_DIR/ping6" <<'STUBEOF'
#!/bin/sh
CTRL="${RC_CTRL:-/tmp/rctest-ctrl}"
SEQ_FILE="$CTRL/ping_seq"
POS_FILE="$CTRL/ping_pos"
POS=$(cat "$POS_FILE" 2>/dev/null)
[ -z "$POS" ] && POS=0
# Read token at position POS (1-indexed field)
TOKEN=$(awk -v p=$((POS + 1)) '{print $p}' "$SEQ_FILE" 2>/dev/null)
echo $((POS + 1)) > "$POS_FILE"
[ "$TOKEN" = "pass" ] && exit 0
exit 1
STUBEOF
chmod +x "$STUB_DIR/ping6"

# sleep: no-op so tests run fast, but records every requested sleep duration
# to $RC_CTRL/sleep_log (one line per call, value only). This lets Test 8
# verify the production sanitize/cap logic end-to-end by inspecting which
# value the confirmation-delay sleep actually received.
# Tests use delay>=1 so the delayed confirmation branch executes; the actual
# wait is skipped. Production default remains 3 seconds.
cat > "$STUB_DIR/sleep" <<'STUBEOF'
#!/bin/sh
CTRL="${RC_CTRL:-/tmp/rctest-ctrl}"
echo "$1" >> "$CTRL/sleep_log"
exit 0
STUBEOF
chmod +x "$STUB_DIR/sleep"

# ifdown / ifup: no-op (used by Tier 0 and do_wan_restart; not exercised here
# but stubbed for safety so any incidental call does not fail the script).
cat > "$STUB_DIR/ifdown" <<'STUBEOF'
#!/bin/sh
exit 0
STUBEOF
chmod +x "$STUB_DIR/ifdown"
cat > "$STUB_DIR/ifup" <<'STUBEOF'
#!/bin/sh
exit 0
STUBEOF
chmod +x "$STUB_DIR/ifup"

# logger: captures messages to log file
cat > "$STUB_DIR/logger" <<'STUBEOF'
#!/bin/sh
LOG="${RC_LOG:-/tmp/rctest-log}"
while [ $# -gt 0 ]; do
    case "$1" in
        -t) shift 2 ;;
        *) echo "$1" >> "$LOG"; shift ;;
    esac
done
STUBEOF
chmod +x "$STUB_DIR/logger"

# uci: returns hostname
cat > "$STUB_DIR/uci" <<'STUBEOF'
#!/bin/sh
echo "TestRouter"
STUBEOF
chmod +x "$STUB_DIR/uci"

# curl: always succeeds
cat > "$STUB_DIR/curl" <<'STUBEOF'
#!/bin/sh
exit 0
STUBEOF
chmod +x "$STUB_DIR/curl"

# flock: pass-through success so the watchdog lock does not block tests.
cat > "$STUB_DIR/flock" <<'STUBEOF'
#!/bin/sh
exit 0
STUBEOF
chmod +x "$STUB_DIR/flock"

# date: returns a fixed epoch so NOW is deterministic.
cat > "$STUB_DIR/date" <<'STUBEOF'
#!/bin/sh
if [ "$1" = "+%s" ]; then
    echo 1700000000
    exit 0
fi
# Fall back to real date for any other invocation.
/usr/bin/date "$@"
STUBEOF
chmod +x "$STUB_DIR/date"

# ================================================================
# Test configuration
# ================================================================

# Default config for Tests 1-7 and 9: REACHABILITY_CONFIRM_DELAY=1 keeps tests
# fast (sleep is stubbed) while exercising the delayed confirmation branch.
# Production default is 3. Test 8 builds separate watchdog copies with
# different delay configs to verify the production sanitize/cap logic
# end-to-end via the recording sleep stub.
# WAN_RESTART_LIMIT=3 matches production default; STICKY_GATEWAY=0 default.
cat > "$CONF_FILE" <<EOF
DISCORD_WEBHOOK="http://dummy-webhook.test"
WAN_RESTART_LIMIT=3
REACHABILITY_CONFIRM_DELAY=1
EOF

# ================================================================
# Modified script copy (sed: redirect paths only, logic unchanged)
# ================================================================

# Build a watchdog copy from the production source, redirecting STATE_DIR and
# CONF to the test workspace and forcing UPTIME_SECS past the boot grace period.
# $1 = output path, $2 = conf file path (defaults to $CONF_FILE).
build_watchdog() {
    local out="${1:-$WATCHDOG_TEST}"
    local conf="${2:-$CONF_FILE}"
    sed -e "s|STATE_DIR=\"/tmp/ipv6-watchdog\"|STATE_DIR=\"$STATE_DIR\"|" \
        -e "s|CONF=\"/etc/ipv6-watchdog.conf\"|CONF=\"$conf\"|" \
        -e 's|^UPTIME_SECS=.*|UPTIME_SECS=999|' \
        "$SCRIPT_DIR/ipv6-watchdog" > "$out"
    chmod +x "$out"
}

build_watchdog "$WATCHDOG_TEST" "$CONF_FILE"

# ================================================================
# Test helpers
# ================================================================

PASS=0
FAIL=0

# Run the default watchdog copy. Optional $1 overrides the binary path.
run_watchdog() {
    : > "$LOG_FILE"
    : > "$CTRL_DIR/sleep_log"
    local wd="${1:-$WATCHDOG_TEST}"
    PATH="$STUB_DIR:$ORIG_PATH" "$wd" 2>/dev/null
}

# Extract the confirmation-delay sleep value from the sleep log.
# The production script calls `sleep "$REACHABILITY_CONFIRM_DELAY"` exactly
# once in ipv6_ok() when the first internet_ok_now fails and the delay is >0.
# Other sleeps in the script use fixed values (5, 10, 15, 20, 30, 2, 1) or
# jitter ($((RANDOM % 5 + 5))). To isolate the confirmation sleep we drive a
# scenario where ipv6_ok's first internet_ok_now fails and the delayed branch
# runs (ping_seq: fail fail fail fail -> both checks fail), so the only
# non-jitter sleep with the configured delay value is the confirmation one.
# We return the first sleep value that is not the jitter range [5..9].
get_confirm_sleep() {
    awk '{if ($1+0 < 5 || $1+0 > 9) {print; exit}}' "$CTRL_DIR/sleep_log" 2>/dev/null
}

assert_contains() {
    if grep -qF "$1" "$LOG_FILE" 2>/dev/null; then
        PASS=$((PASS + 1))
    else
        FAIL=$((FAIL + 1))
        echo "  FAIL: expected log containing: $1"
        sed 's/^/    /' "$LOG_FILE" 2>/dev/null >&2
    fi
}

assert_not_contains() {
    if grep -qF "$1" "$LOG_FILE" 2>/dev/null; then
        FAIL=$((FAIL + 1))
        echo "  FAIL: expected log NOT containing: $1"
        sed 's/^/    /' "$LOG_FILE" 2>/dev/null >&2
    else
        PASS=$((PASS + 1))
    fi
}

assert_empty_log() {
    if [ -s "$LOG_FILE" ]; then
        FAIL=$((FAIL + 1))
        echo "  FAIL: expected empty log, got:"
        sed 's/^/    /' "$LOG_FILE" 2>/dev/null >&2
    else
        PASS=$((PASS + 1))
    fi
}

assert_file_eq() {
    actual=$(cat "$1" 2>/dev/null)
    if [ "$actual" = "$2" ]; then
        PASS=$((PASS + 1))
    else
        FAIL=$((FAIL + 1))
        echo "  FAIL: expected '$2' in $(basename "$1"), got '$actual'"
    fi
}

assert_file_not_exists() {
    if [ -f "$1" ]; then
        FAIL=$((FAIL + 1))
        echo "  FAIL: expected file $(basename "$1") to NOT exist"
    else
        PASS=$((PASS + 1))
    fi
}

reset_state() {
    rm -rf "$STATE_DIR"/* 2>/dev/null
    rm -f "$CTRL_DIR"/* 2>/dev/null
    : > "$LOG_FILE"
    mkdir -p "$STATE_DIR" "$CTRL_DIR"
}

# Set the ping6 outcome sequence. Each token is consumed by one ping6 call.
# internet_ok_now calls ping6 up to twice: once for Google, once for Cloudflare
# only if the first failed. A single "pass" short-circuits internet_ok_now.
set_ping_seq() {
    echo "$*" > "$CTRL_DIR/ping_seq"
    echo "0" > "$CTRL_DIR/ping_pos"
}

# Common setup: wan6 up with device, prefix present, route present.
seed_healthy_layer12() {
    touch "$CTRL_DIR/wan6_up"
    echo "eth0" > "$CTRL_DIR/wan_dev"
    touch "$CTRL_DIR/has_prefix"
    touch "$CTRL_DIR/has_route"
}

# ================================================================
# Tests
# ================================================================

echo "=== Test 1: First reachability pass succeeds -- healthy and silent ==="
reset_state
seed_healthy_layer12
set_ping_seq pass
run_watchdog
assert_empty_log
assert_file_eq "$STATE_DIR/fail_count" "0"
echo "  done (pass=$PASS fail=$FAIL)"

echo "=== Test 2: Initial fail then delayed confirmation succeeds -- no alert, no fix, fail_count 0 ==="
reset_state
seed_healthy_layer12
# ipv6_ok first internet_ok_now: Google=fail, Cloudflare=fail -> both fail.
# REACHABILITY_CONFIRM_DELAY=1 (sleep stubbed) so delayed re-check runs.
# Delayed internet_ok_now: Google=pass -> success, return healthy, no log.
# No fix_gateway call because ipv6_ok returned 0.
set_ping_seq fail fail pass
run_watchdog
assert_empty_log
assert_file_eq "$STATE_DIR/fail_count" "0"
echo "  done (pass=$PASS fail=$FAIL)"

echo "=== Test 3: Both ipv6_ok checks fail, current gateway verifies in fix_gateway -- silent recovery, fail_count 0 ==="
reset_state
seed_healthy_layer12
# ipv6_ok attempt 1: Google=fail, Cloudflare=fail.
# ipv6_ok attempt 2 (delayed): Google=fail, Cloudflare=fail -> returns 1, no log.
# fix_gateway STEP1 reachability: Google=fail, Cloudflare=fail (skip route del).
# fix_gateway current gw check (internet_ok_now): Google=pass -> silent success, return 0.
# Post-fix ipv6_ok validation: Google=pass -> healthy, reset state, exit 0.
set_ping_seq fail fail fail fail fail fail pass pass
run_watchdog
assert_empty_log
assert_file_eq "$STATE_DIR/fail_count" "0"
echo "  done (pass=$PASS fail=$FAIL)"

echo "=== Test 4: Persistent Layer-3 failure -- one confirmed validation log and fail_count increment ==="
reset_state
seed_healthy_layer12
# ipv6_ok attempt 1: Google=fail, Cloudflare=fail.
# ipv6_ok attempt 2 (delayed): Google=fail, Cloudflare=fail -> returns 1, no log.
# fix_gateway STEP1: Google=fail, Cloudflare=fail (enter route-del loop, no from routes).
# fix_gateway current gw check: Google=fail, Cloudflare=fail -> scanning alternatives.
# NDP all-routers probe: fail.
# Candidate fe80::1 from route table: gateway_mac unicast probe fails, no MAC -> skip.
# fix_gateway returns 1. Post-fix ipv6_ok NOT called (fix_gateway failed).
# Confirmed-failure log fires, FAILS incremented to 1.
set_ping_seq fail fail fail fail fail fail fail fail fail fail
run_watchdog
assert_contains "Validation failed after confirmation: prefix and route exist but internet unreachable"
assert_contains "Connectivity failure 1"
assert_file_eq "$STATE_DIR/fail_count" "1"
echo "  done (pass=$PASS fail=$FAIL)"

echo "=== Test 5: Three persistent failures preserve existing escalation ==="
reset_state
seed_healthy_layer12
# Pre-seed fail_count=2 so this tick is the 3rd consecutive failure.
echo "2" > "$STATE_DIR/fail_count"
# Same call sequence as Test 4 (10 ping6 calls, all fail).
set_ping_seq fail fail fail fail fail fail fail fail fail fail
run_watchdog
assert_contains "Validation failed after confirmation: prefix and route exist but internet unreachable"
assert_contains "Connectivity failure 3"
assert_contains "3 consecutive connectivity failures"
# do_wan_restart increments WAN_RESTARTS and logs. The escalation log
# confirms the existing three-failure path still fires.
assert_contains "Full WAN restart #1 of 3"
assert_file_eq "$STATE_DIR/fail_count" "0"
echo "  done (pass=$PASS fail=$FAIL)"

echo "=== Test 6: Missing-prefix behavior unchanged ==="
reset_state
# wan6 up, NO prefix, NO route.
touch "$CTRL_DIR/wan6_up"
echo "eth0" > "$CTRL_DIR/wan_dev"
set_ping_seq pass
run_watchdog
assert_contains "Validation failed: no prefix assigned"
assert_not_contains "Validation failed after confirmation"
assert_not_contains "internet unreachable"
echo "  done (pass=$PASS fail=$FAIL)"

echo "=== Test 7: Missing-route behavior unchanged ==="
reset_state
# wan6 up, prefix present, NO route.
touch "$CTRL_DIR/wan6_up"
echo "eth0" > "$CTRL_DIR/wan_dev"
touch "$CTRL_DIR/has_prefix"
set_ping_seq pass
run_watchdog
assert_contains "Validation failed: no default IPv6 route"
assert_not_contains "Validation failed after confirmation"
assert_not_contains "internet unreachable"
echo "  done (pass=$PASS fail=$FAIL)"

echo "=== Test 8: REACHABILITY_CONFIRM_DELAY sanitize/cap end-to-end ==="
# Verify the production sanitize/cap logic by running the actual watchdog
# source with four separate configs. The recording sleep stub captures every
# sleep value; we isolate the confirmation-delay sleep from startup jitter
# (5..9s) and other fixed recovery sleeps by driving a scenario where the
# only non-jitter sleep is the confirmation delay: ipv6_ok first
# internet_ok_now fails (Google=fail, Cloudflare=fail), the delayed branch
# runs and the second internet_ok_now also fails (Google=fail, Cloudflare=fail),
# then fix_gateway STEP1 fails and the current-gw check fails, so no further
# recovery sleeps occur before exit. The confirmation sleep is the only sleep
# outside the jitter range [5..9] in this scenario.
#
# ping_seq for all four sub-tests: fail fail fail fail fail fail fail fail
# (4 for two ipv6_ok attempts + 2 for fix_gateway STEP1 + 2 for current gw).
# All fail so fix_gateway falls through to NDP probe + candidate scan, but
# those ping6 calls also fail (tokens exhausted -> default fail).

# 8a: unset (default -> 3)
reset_state
seed_healthy_layer12
RC_CONF_8A="$TEST_ROOT/conf_8a"
cat > "$RC_CONF_8A" <<EOF
DISCORD_WEBHOOK="http://dummy-webhook.test"
WAN_RESTART_LIMIT=3
EOF
RC_WD_8A="$TEST_ROOT/wd_8a"
build_watchdog "$RC_WD_8A" "$RC_CONF_8A"
set_ping_seq fail fail fail fail fail fail fail fail fail fail
run_watchdog "$RC_WD_8A"
RC_8A=$(get_confirm_sleep)
if [ "$RC_8A" = "3" ]; then
    PASS=$((PASS + 1))
else
    FAIL=$((FAIL + 1))
    echo "  FAIL: unset delay should produce confirm sleep 3, got '$RC_8A'"
    sed 's/^/    /' "$CTRL_DIR/sleep_log" 2>/dev/null >&2
fi

# 8b: non-numeric -> 3
reset_state
seed_healthy_layer12
RC_CONF_8B="$TEST_ROOT/conf_8b"
cat > "$RC_CONF_8B" <<EOF
DISCORD_WEBHOOK="http://dummy-webhook.test"
WAN_RESTART_LIMIT=3
REACHABILITY_CONFIRM_DELAY=abc
EOF
RC_WD_8B="$TEST_ROOT/wd_8b"
build_watchdog "$RC_WD_8B" "$RC_CONF_8B"
set_ping_seq fail fail fail fail fail fail fail fail fail fail
run_watchdog "$RC_WD_8B"
RC_8B=$(get_confirm_sleep)
if [ "$RC_8B" = "3" ]; then
    PASS=$((PASS + 1))
else
    FAIL=$((FAIL + 1))
    echo "  FAIL: non-numeric delay should fall back to 3, got '$RC_8B'"
    sed 's/^/    /' "$CTRL_DIR/sleep_log" 2>/dev/null >&2
fi

# 8c: 99 -> capped at 30
reset_state
seed_healthy_layer12
RC_CONF_8C="$TEST_ROOT/conf_8c"
cat > "$RC_CONF_8C" <<EOF
DISCORD_WEBHOOK="http://dummy-webhook.test"
WAN_RESTART_LIMIT=3
REACHABILITY_CONFIRM_DELAY=99
EOF
RC_WD_8C="$TEST_ROOT/wd_8c"
build_watchdog "$RC_WD_8C" "$RC_CONF_8C"
set_ping_seq fail fail fail fail fail fail fail fail fail fail
run_watchdog "$RC_WD_8C"
RC_8C=$(get_confirm_sleep)
if [ "$RC_8C" = "30" ]; then
    PASS=$((PASS + 1))
else
    FAIL=$((FAIL + 1))
    echo "  FAIL: delay 99 should cap at 30, got '$RC_8C'"
    sed 's/^/    /' "$CTRL_DIR/sleep_log" 2>/dev/null >&2
fi

# 8d: 0 -> no delayed confirmation sleep occurs
reset_state
seed_healthy_layer12
RC_CONF_8D="$TEST_ROOT/conf_8d"
cat > "$RC_CONF_8D" <<EOF
DISCORD_WEBHOOK="http://dummy-webhook.test"
WAN_RESTART_LIMIT=3
REACHABILITY_CONFIRM_DELAY=0
EOF
RC_WD_8D="$TEST_ROOT/wd_8d"
build_watchdog "$RC_WD_8D" "$RC_CONF_8D"
set_ping_seq fail fail fail fail fail fail fail fail fail fail
run_watchdog "$RC_WD_8D"
# With delay=0 the production guard `[ "$REACHABILITY_CONFIRM_DELAY" -gt 0 ]`
# is false, so the confirmation branch is skipped and `sleep 0` is never
# called. The first non-jitter sleep should be fix_gateway's NDP `sleep 2`,
# not a confirmation delay. Assert no 0 in the log and first non-jitter is 2.
RC_8D=$(get_confirm_sleep)
if [ "$RC_8D" = "2" ]; then
    PASS=$((PASS + 1))
else
    FAIL=$((FAIL + 1))
    echo "  FAIL: delay 0 should skip confirm branch (first non-jitter sleep should be 2), got '$RC_8D'"
    sed 's/^/    /' "$CTRL_DIR/sleep_log" 2>/dev/null >&2
fi
# Also assert no sleep value of 0 was recorded (guard skipped the branch).
if grep -qx '0' "$CTRL_DIR/sleep_log" 2>/dev/null; then
    FAIL=$((FAIL + 1))
    echo "  FAIL: delay 0 should not call sleep 0 (guard should skip branch)"
    sed 's/^/    /' "$CTRL_DIR/sleep_log" 2>/dev/null >&2
else
    PASS=$((PASS + 1))
fi
echo "  done (pass=$PASS fail=$FAIL)"

echo "=== Test 9: fix_gateway current-gateway-good path is silent (no 'no fix needed' notice) ==="
reset_state
seed_healthy_layer12
# Both ipv6_ok checks fail (4 fail), then fix_gateway STEP1 (2 fail), then
# current gw internet_ok_now passes (1 pass) -> silent success, return 0.
# Post-fix ipv6_ok: Google=pass -> healthy, reset state, exit 0.
set_ping_seq fail fail fail fail fail fail pass pass
run_watchdog
assert_not_contains "has internet reachability, no fix needed"
assert_empty_log
assert_file_eq "$STATE_DIR/fail_count" "0"
echo "  done (pass=$PASS fail=$FAIL)"

echo ""
echo "=== SUMMARY ==="
echo "PASS: $PASS"
echo "FAIL: $FAIL"
if [ "$FAIL" -eq 0 ]; then
    echo "ALL TESTS PASSED"
    exit 0
else
    echo "SOME TESTS FAILED"
    exit 1
fi