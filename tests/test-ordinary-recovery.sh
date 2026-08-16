#!/bin/sh
# tests/test-ordinary-recovery.sh
#
# Test harness for ipv6-watchdog v3.10.1 ORDINARY recovery closure.
#
# Background: the ordinary-recovery mechanism (fail_count > 0 -> healthy) was
# designed for a v3.9.10 that was never committed, tagged, or pushed. v3.10.0
# was branched directly from v3.9.9 and therefore shipped without it, so a
# confirmed connectivity incident that resolved without a full WAN restart
# closed completely silently: no log line and no Discord message. The design's
# own guard against this ("Discord test D5") never became an executable test,
# which is why nothing failed. This suite is that missing test.
#
# Contract under test:
#   - Ordinary closure fires ONLY when FAILS > 0 on a non-hold path.
#   - It is a SEPARATE mechanism from notify_ipv6_recovered(), which remains
#     the critical/ONT-alert closure and keeps its own ONT_FLAG gate.
#   - Exactly one recovery notice can fire per incident (no ordinary+critical
#     duplication).
#   - Both recovery paths are covered: the normal healthy path and the
#     successful fix_gateway -> ipv6_ok path.
#   - incident_start opens on the 0 -> 1 transition, is never overwritten while
#     the incident stays open, and is cleared by both reset_recovery_state()
#     and do_wan_restart().
#   - Shared wan-recovery budget/hold semantics are untouched.
#
# Tests the actual script logic via stub commands and temp state dirs.
# Does not require a live router.
#
# Usage: bash tests/test-ordinary-recovery.sh
# Exit:  0 = all pass, 1 = any fail

# --- Locate repo root ---
TEST_SCRIPT="$0"
SCRIPT_DIR="$(cd "$(dirname "$TEST_SCRIPT")/.." && pwd)"

# --- Create temp workspace ---
TEST_ROOT="$(mktemp -d 2>/dev/null || { D="/tmp/ortest-$$"; mkdir -p "$D"; echo "$D"; })"
STUB_DIR="$TEST_ROOT/stubs"
STATE_DIR="$TEST_ROOT/state"
SHARED_DIR="$TEST_ROOT/wan-recovery"
CTRL_DIR="$TEST_ROOT/ctrl"
LOG_FILE="$TEST_ROOT/log.txt"
CONF_FILE="$TEST_ROOT/test.conf"
WATCHDOG_TEST="$TEST_ROOT/ipv6-watchdog.test"

ORIG_PATH="$PATH"
export RC_CTRL="$CTRL_DIR"
export RC_LOG="$LOG_FILE"

mkdir -p "$STUB_DIR" "$STATE_DIR" "$CTRL_DIR" "$SHARED_DIR"

# Point the watchdog at the REAL shared coordinator with a test-local shared
# state dir, so budget/hold semantics are exercised for real.
export WAN_RECOVERY_COMMON="$SCRIPT_DIR/wan-recovery-common"
export WAN_RECOVERY_STATE_DIR="$SHARED_DIR"

cleanup() {
    rm -rf "$TEST_ROOT"
}
trap cleanup EXIT
trap 'cleanup; exit 130' INT
trap 'cleanup; exit 143' TERM

# ================================================================
# Stub executables
# ================================================================

cat > "$STUB_DIR/ubus" <<'STUBEOF'
#!/bin/sh
CTRL="${RC_CTRL:-/tmp/ortest-ctrl}"
if [ "$1" = "call" ] && [ "$2" = "network.interface.wan6" ] && [ "$3" = "status" ]; then
    if [ -f "$CTRL/wan6_up" ]; then
        DEV=""
        [ -f "$CTRL/wan_dev" ] && DEV=$(cat "$CTRL/wan_dev")
        PREFIX_PART=""
        if [ -f "$CTRL/has_prefix" ]; then
            ADDR="2001:db8:1234:5678::1"
            [ -f "$CTRL/prefix_addr" ] && ADDR=$(cat "$CTRL/prefix_addr")
            MASK="56"
            [ -f "$CTRL/prefix_mask" ] && MASK=$(cat "$CTRL/prefix_mask")
            PREFIX_PART='"ipv6-prefix":[{"address":"'"$ADDR"'","mask":'"$MASK"'}],'
        fi
        printf '{"up":true,"l3_device":"%s",%s"pending":false}' "$DEV" "$PREFIX_PART"
    else
        printf '{"up":false}'
    fi
fi
STUBEOF
chmod +x "$STUB_DIR/ubus"

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
    *'"pending"'*)
        printf '%s' "$INPUT" | sed -n 's/.*"pending":\([a-z]*\).*/\1/p'
        ;;
    *'"ipv6-prefix"'*'.mask'*)
        printf '%s' "$INPUT" | sed -n 's/.*"mask":\([0-9]*\).*/\1/p'
        ;;
    *'"ipv6-prefix"'*)
        printf '%s' "$INPUT" | sed -n 's/.*"address":"\([^"]*\)".*/\1/p'
        ;;
esac
STUBEOF
chmod +x "$STUB_DIR/jsonfilter"

# ip: same model as the reachability suite. $CTRL/gw overrides the gateway
# address emitted by the generic default route, and $CTRL/no_via emits a
# default route with NO "via" token so current_default_gw() yields nothing
# (used to prove the gateway clause is omitted when not provable).
cat > "$STUB_DIR/ip" <<'STUBEOF'
#!/bin/sh
CTRL="${RC_CTRL:-/tmp/ortest-ctrl}"
GW="fe80::1"
[ -f "$CTRL/gw" ] && GW=$(cat "$CTRL/gw")

if [ "$1" = "-6" ] && [ "$2" = "addr" ] && [ "$3" = "show" ]; then
    DEP=""
    PREV=""
    for a in "$@"; do
        [ "$a" = "deprecated" ] && DEP=1
        PREV="$a"
    done
    [ -n "$DEP" ] && exit 0
    LAN_SRC=$(cat "$CTRL/lan_src" 2>/dev/null)
    if [ -n "$LAN_SRC" ] && [ -f "$CTRL/has_prefix" ]; then
        printf 'inet6 %s/64 scope global dynamic\n' "$LAN_SRC"
        printf '   valid_lft 86400sec preferred_lft 14400sec\n'
    fi
    exit 0
fi

if [ "$1" = "-6" ] && [ "$2" = "route" ] && [ "$3" = "show" ] && [ "$4" = "default" ]; then
    FROM=""
    shift 4
    while [ $# -gt 0 ]; do
        case "$1" in
            from) FROM="$2"; shift ;;
            dev) shift ;;
        esac
        shift
    done
    if [ -n "$FROM" ]; then
        [ -f "$CTRL/has_src_route" ] && echo "default from $FROM via $GW dev eth0 metric 512"
    else
        if [ -f "$CTRL/has_route" ]; then
            if [ -f "$CTRL/no_via" ]; then
                # Default route present but with no via token: gateway is NOT provable.
                echo "default dev eth0 metric 512"
            else
                echo "default via $GW dev eth0 metric 512"
            fi
        fi
    fi
    exit 0
fi

if [ "$1" = "-6" ] && [ "$2" = "route" ] && [ "$3" = "get" ]; then
    FROM=""
    shift 3
    while [ $# -gt 0 ]; do
        case "$1" in
            from) FROM="$2"; shift 2 ;;
            *) shift ;;
        esac
    done
    [ -n "$FROM" ] || exit 1
    if [ -f "$CTRL/has_src_route" ] || [ -f "$CTRL/has_route" ]; then
        echo "$FROM via $GW dev eth0 metric 512"
    else
        echo "unreachable $FROM dev eth0"
    fi
    exit 0
fi

if [ "$1" = "-6" ] && [ "$2" = "neigh" ] && [ "$3" = "show" ]; then
    if [ -f "$CTRL/neigh_router" ]; then
        echo "$GW dev eth0 lladdr 00:11:22:33:44:55 router REACHABLE"
    fi
    exit 0
fi

exit 0
STUBEOF
chmod +x "$STUB_DIR/ip"

cat > "$STUB_DIR/ping6" <<'STUBEOF'
#!/bin/sh
CTRL="${RC_CTRL:-/tmp/ortest-ctrl}"
SEQ_FILE="$CTRL/ping_seq"
POS_FILE="$CTRL/ping_pos"
POS=$(cat "$POS_FILE" 2>/dev/null)
[ -z "$POS" ] && POS=0
TOKEN=$(awk -v p=$((POS + 1)) '{print $p}' "$SEQ_FILE" 2>/dev/null)
echo $((POS + 1)) > "$POS_FILE"
[ "$TOKEN" = "pass" ] && exit 0
exit 1
STUBEOF
chmod +x "$STUB_DIR/ping6"

cat > "$STUB_DIR/sleep" <<'STUBEOF'
#!/bin/sh
exit 0
STUBEOF
chmod +x "$STUB_DIR/sleep"

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

cat > "$STUB_DIR/logger" <<'STUBEOF'
#!/bin/sh
LOG="${RC_LOG:-/tmp/ortest-log}"
while [ $# -gt 0 ]; do
    case "$1" in
        -t) shift 2 ;;
        *) echo "$1" >> "$LOG"; shift ;;
    esac
done
STUBEOF
chmod +x "$STUB_DIR/logger"

cat > "$STUB_DIR/uci" <<'STUBEOF'
#!/bin/sh
echo "TestRouter"
STUBEOF
chmod +x "$STUB_DIR/uci"

# curl: records each webhook POST so direct-Discord delivery can be counted.
# notify_ordinary_recovery must NEVER invoke curl; notify_ipv6_recovered does.
cat > "$STUB_DIR/curl" <<'STUBEOF'
#!/bin/sh
CTRL="${RC_CTRL:-/tmp/ortest-ctrl}"
echo "POST" >> "$CTRL/curl_log"
exit 0
STUBEOF
chmod +x "$STUB_DIR/curl"

cat > "$STUB_DIR/flock" <<'STUBEOF'
#!/bin/sh
exit 0
STUBEOF
chmod +x "$STUB_DIR/flock"

# date: epoch is controllable via $CTRL/now so incident durations are
# deterministic. Defaults to 1700000000.
cat > "$STUB_DIR/date" <<'STUBEOF'
#!/bin/sh
CTRL="${RC_CTRL:-/tmp/ortest-ctrl}"
if [ "$1" = "+%s" ]; then
    if [ -f "$CTRL/now" ]; then
        cat "$CTRL/now"
    else
        echo 1700000000
    fi
    exit 0
fi
/usr/bin/date "$@"
STUBEOF
chmod +x "$STUB_DIR/date"

# ================================================================
# Test configuration
# ================================================================

cat > "$CONF_FILE" <<EOF
DISCORD_WEBHOOK="http://dummy-webhook.test"
WAN_RESTART_LIMIT=3
REACHABILITY_CONFIRM_DELAY=1
EOF

build_watchdog() {
    out="${1:-$WATCHDOG_TEST}"
    conf="${2:-$CONF_FILE}"
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

ORDINARY_PREFIX="IPv6 connectivity recovered after"

run_watchdog() {
    : > "$LOG_FILE"
    : > "$CTRL_DIR/curl_log"
    wd="${1:-$WATCHDOG_TEST}"
    PATH="$STUB_DIR:$ORIG_PATH" "$wd" 2>/dev/null
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
        echo "  FAIL: log should NOT contain: $1"
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

assert_file_exists() {
    if [ -f "$1" ]; then
        PASS=$((PASS + 1))
    else
        FAIL=$((FAIL + 1))
        echo "  FAIL: expected file $(basename "$1") to exist"
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

# Count how many lines in the log open with the ordinary-recovery prefix.
count_ordinary() {
    # grep -c prints "0" AND exits 1 when there is no match, so a `|| echo 0`
    # fallback would emit a second line. Capture the count directly instead.
    n=$(grep -cF "$ORDINARY_PREFIX" "$LOG_FILE" 2>/dev/null)
    [ -z "$n" ] && n=0
    echo "$n"
}

assert_ordinary_count() {
    actual=$(count_ordinary)
    if [ "$actual" = "$1" ]; then
        PASS=$((PASS + 1))
    else
        FAIL=$((FAIL + 1))
        echo "  FAIL: expected $1 ordinary-recovery line(s), got $actual"
        sed 's/^/    /' "$LOG_FILE" 2>/dev/null >&2
    fi
}

# Count direct Discord webhook POSTs (curl invocations).
assert_curl_count() {
    actual=$(wc -l < "$CTRL_DIR/curl_log" 2>/dev/null | tr -d ' ')
    [ -z "$actual" ] && actual=0
    if [ "$actual" = "$1" ]; then
        PASS=$((PASS + 1))
    else
        FAIL=$((FAIL + 1))
        echo "  FAIL: expected $1 curl POST(s), got $actual"
    fi
}

reset_state() {
    rm -rf "$STATE_DIR"/* 2>/dev/null
    rm -f "$CTRL_DIR"/* 2>/dev/null
    rm -rf "$SHARED_DIR"/* 2>/dev/null
    mkdir -p "$SHARED_DIR" "$STATE_DIR" "$CTRL_DIR"
    : > "$LOG_FILE"
    : > "$CTRL_DIR/curl_log"
}

set_ping_seq() {
    echo "$*" > "$CTRL_DIR/ping_seq"
    echo "0" > "$CTRL_DIR/ping_pos"
}

set_now() {
    echo "$1" > "$CTRL_DIR/now"
}

seed_healthy_layer12() {
    touch "$CTRL_DIR/wan6_up"
    echo "eth0" > "$CTRL_DIR/wan_dev"
    touch "$CTRL_DIR/has_prefix"
    echo "56" > "$CTRL_DIR/prefix_mask"
    echo "2001:db8:1234:5678::abcd" > "$CTRL_DIR/lan_src"
    touch "$CTRL_DIR/has_route"
    touch "$CTRL_DIR/has_src_route"
    touch "$CTRL_DIR/neigh_router"
}

seed_fail_count() {
    echo "$1" > "$STATE_DIR/fail_count"
}

seed_incident_start() {
    echo "$1" > "$STATE_DIR/incident_start"
}

# ================================================================
# Tests
# ================================================================

echo "=== Test A: fail_count=1 -> healthy (happy path) emits ordinary recovery ==="
reset_state
seed_healthy_layer12
seed_fail_count 1
seed_incident_start 1699999640   # 360s before default NOW
set_ping_seq pass
run_watchdog
assert_contains "IPv6 connectivity recovered after 1 confirmed failed watchdog cycle."
assert_contains "Cause was not determined."
assert_contains "No WAN restart was required."
assert_ordinary_count 1
assert_file_eq "$STATE_DIR/fail_count" "0"
assert_file_not_exists "$STATE_DIR/incident_start"
echo "  done (pass=$PASS fail=$FAIL)"

echo "=== Test B: fail_count=0 -> healthy stays silent (no ordinary recovery) ==="
reset_state
seed_healthy_layer12
seed_fail_count 0
set_ping_seq pass
run_watchdog
assert_ordinary_count 0
assert_not_contains "$ORDINARY_PREFIX"
assert_file_eq "$STATE_DIR/fail_count" "0"
echo "  done (pass=$PASS fail=$FAIL)"

echo "=== Test C: fail_count=2 -> fix_gateway -> ipv6_ok emits ordinary recovery ==="
reset_state
seed_healthy_layer12
seed_fail_count 2
seed_incident_start 1699999400
# ipv6_ok attempt 1 + delayed attempt 2 both fail (4 tokens), fix_gateway fast
# path verifies the current gateway (token 5), post-fix ipv6_ok passes (token 6).
set_ping_seq fail fail fail fail pass pass
run_watchdog
assert_contains "IPv6 connectivity recovered after 2 confirmed failed watchdog cycles."
assert_ordinary_count 1
assert_file_eq "$STATE_DIR/fail_count" "0"
assert_file_not_exists "$STATE_DIR/incident_start"
echo "  done (pass=$PASS fail=$FAIL)"

echo "=== Test D: fail_count=0 -> fix_gateway -> ipv6_ok stays silent ==="
reset_state
seed_healthy_layer12
seed_fail_count 0
set_ping_seq fail fail fail fail pass pass
run_watchdog
assert_ordinary_count 0
assert_not_contains "$ORDINARY_PREFIX"
assert_file_eq "$STATE_DIR/fail_count" "0"
echo "  done (pass=$PASS fail=$FAIL)"

echo "=== Test E: 0 -> 1 transition opens incident_start ==="
reset_state
seed_healthy_layer12
seed_fail_count 0
set_now 1700000000
set_ping_seq fail fail fail fail fail fail fail fail fail fail
run_watchdog
assert_file_eq "$STATE_DIR/fail_count" "1"
assert_file_exists "$STATE_DIR/incident_start"
assert_file_eq "$STATE_DIR/incident_start" "1700000000"
echo "  done (pass=$PASS fail=$FAIL)"

echo "=== Test F: 1 -> 2 transition does NOT overwrite incident_start ==="
reset_state
seed_healthy_layer12
seed_fail_count 1
seed_incident_start 1699999000
set_now 1700000000
set_ping_seq fail fail fail fail fail fail fail fail fail fail
run_watchdog
assert_file_eq "$STATE_DIR/fail_count" "2"
# Start marker must still hold the FIRST failure time, not this tick's time.
assert_file_eq "$STATE_DIR/incident_start" "1699999000"
echo "  done (pass=$PASS fail=$FAIL)"

echo "=== Test G: escalation to full WAN restart clears incident_start, no ordinary line ==="
reset_state
seed_healthy_layer12
seed_fail_count 2
seed_incident_start 1699999000
set_ping_seq fail fail fail fail fail fail fail fail fail fail
run_watchdog
assert_contains "IPv6 connectivity failure 3/3 confirmed."
assert_contains "3 consecutive connectivity failures"
assert_ordinary_count 0
assert_file_eq "$STATE_DIR/fail_count" "0"
assert_file_not_exists "$STATE_DIR/incident_start"
echo "  done (pass=$PASS fail=$FAIL)"

echo "=== Test H: recovery hold active -> critical closure only, no ordinary line ==="
reset_state
seed_healthy_layer12
seed_fail_count 5
seed_incident_start 1699999000
# Exhaust the shared same-boot budget so recovery_hold_active() is true.
echo "3" > "$SHARED_DIR/disruption_count"
set_ping_seq pass pass pass pass
run_watchdog
assert_ordinary_count 0
assert_not_contains "$ORDINARY_PREFIX"
assert_contains "Recovery hold: IPv6 spontaneously recovered"
# Hold must preserve the same-boot budget and its counters untouched.
assert_file_eq "$STATE_DIR/fail_count" "5"
assert_file_eq "$SHARED_DIR/disruption_count" "3"
echo "  done (pass=$PASS fail=$FAIL)"

echo "=== Test I: ONT_FLAG set + fail_count>0 -> exactly ONE recovery notice ==="
reset_state
seed_healthy_layer12
seed_fail_count 4
seed_incident_start 1699999000
touch "$STATE_DIR/ont_notified"
set_ping_seq pass
run_watchdog
# Critical closure owns this incident; ordinary must be suppressed.
assert_ordinary_count 0
assert_contains "IPv6 recovered after critical failure, Discord recovery notice sent"
assert_curl_count 1
assert_file_eq "$STATE_DIR/fail_count" "0"
echo "  done (pass=$PASS fail=$FAIL)"

echo "=== Test J: ONT_FLAG set + fix_gateway path -> exactly ONE recovery notice ==="
reset_state
seed_healthy_layer12
seed_fail_count 4
touch "$STATE_DIR/ont_notified"
set_ping_seq fail fail fail fail pass pass
run_watchdog
assert_ordinary_count 0
assert_contains "IPv6 recovered after critical failure, Discord recovery notice sent"
assert_curl_count 1
echo "  done (pass=$PASS fail=$FAIL)"

echo "=== Test K: ordinary recovery performs NO direct Discord curl ==="
reset_state
seed_healthy_layer12
seed_fail_count 1
seed_incident_start 1699999640
set_ping_seq pass
run_watchdog
assert_ordinary_count 1
# The ordinary path logs only; the logger daemon forwards it. No webhook POST.
assert_curl_count 0
echo "  done (pass=$PASS fail=$FAIL)"

echo "=== Test L: missing incident_start -> duration omitted, no crash ==="
reset_state
seed_healthy_layer12
seed_fail_count 1
set_ping_seq pass
run_watchdog
assert_ordinary_count 1
assert_not_contains "Approximate incident duration"
assert_file_eq "$STATE_DIR/fail_count" "0"
echo "  done (pass=$PASS fail=$FAIL)"

echo "=== Test M: corrupt incident_start -> duration omitted, no crash ==="
reset_state
seed_healthy_layer12
seed_fail_count 1
seed_incident_start "not-an-epoch"
set_ping_seq pass
run_watchdog
assert_ordinary_count 1
assert_not_contains "Approximate incident duration"
echo "  done (pass=$PASS fail=$FAIL)"

echo "=== Test N: future-dated incident_start -> duration omitted, no crash ==="
reset_state
seed_healthy_layer12
seed_fail_count 1
seed_incident_start 1700009999   # after NOW
set_ping_seq pass
run_watchdog
assert_ordinary_count 1
assert_not_contains "Approximate incident duration"
echo "  done (pass=$PASS fail=$FAIL)"

echo "=== Test O: incident older than the 24h sanity ceiling -> duration omitted ==="
reset_state
seed_healthy_layer12
seed_fail_count 1
seed_incident_start 1699900000   # 100000s before NOW (> 86400)
set_ping_seq pass
run_watchdog
assert_ordinary_count 1
assert_not_contains "Approximate incident duration"
echo "  done (pass=$PASS fail=$FAIL)"

echo "=== Test P: duration formatting -- seconds ==="
reset_state
seed_healthy_layer12
seed_fail_count 1
seed_incident_start 1699999955   # 45s
set_ping_seq pass
run_watchdog
assert_contains "Approximate incident duration: 45s."
echo "  done (pass=$PASS fail=$FAIL)"

echo "=== Test Q: duration formatting -- minutes ==="
reset_state
seed_healthy_layer12
seed_fail_count 1
seed_incident_start 1699999640   # 360s = 6m
set_ping_seq pass
run_watchdog
assert_contains "Approximate incident duration: 6m."
echo "  done (pass=$PASS fail=$FAIL)"

echo "=== Test R: duration formatting -- hours and minutes ==="
reset_state
seed_healthy_layer12
seed_fail_count 1
seed_incident_start 1699992200   # 7800s = 2h 10m
set_ping_seq pass
run_watchdog
assert_contains "Approximate incident duration: 2h 10m."
echo "  done (pass=$PASS fail=$FAIL)"

echo "=== Test S: gateway reported only when provable ==="
reset_state
seed_healthy_layer12
seed_fail_count 1
echo "fe80::abcd" > "$CTRL_DIR/gw"
set_ping_seq pass
run_watchdog
assert_contains "Current gateway: fe80::abcd."
echo "  done (pass=$PASS fail=$FAIL)"

echo "=== Test T: gateway clause omitted when no via is present ==="
reset_state
seed_healthy_layer12
seed_fail_count 1
touch "$CTRL_DIR/no_via"
set_ping_seq pass
run_watchdog
assert_ordinary_count 1
assert_not_contains "Current gateway:"
echo "  done (pass=$PASS fail=$FAIL)"

echo "=== Test U: ordinary recovery is exactly ONE log line ==="
reset_state
seed_healthy_layer12
seed_fail_count 2
seed_incident_start 1699999640
set_ping_seq pass
run_watchdog
assert_ordinary_count 1
# The whole closure must be one line: count lines mentioning any of its clauses.
clauses=$(grep -cE 'Cause was not determined|No WAN restart was required|Approximate incident duration' "$LOG_FILE" 2>/dev/null)
if [ "$clauses" = "1" ]; then
    PASS=$((PASS + 1))
else
    FAIL=$((FAIL + 1))
    echo "  FAIL: ordinary closure spread across $clauses log lines, expected 1"
    sed 's/^/    /' "$LOG_FILE" 2>/dev/null >&2
fi
echo "  done (pass=$PASS fail=$FAIL)"

echo "=== Test V: evidence-based failure wording, no speculative cause ==="
reset_state
seed_healthy_layer12
seed_fail_count 0
set_ping_seq fail fail fail fail fail fail fail fail fail fail
run_watchdog
assert_contains "IPv6 connectivity failure 1/3 confirmed."
assert_contains "Delegated prefix and default route are present, but PD-source Internet reachability failed after confirmation and gateway recovery attempts."
assert_contains "No WAN restart performed yet."
assert_not_contains "gateway broken or route dead"
echo "  done (pass=$PASS fail=$FAIL)"

echo "=== Test W: shared budget untouched by an ordinary recovery ==="
reset_state
seed_healthy_layer12
seed_fail_count 1
seed_incident_start 1699999640
echo "1" > "$SHARED_DIR/disruption_count"
set_ping_seq pass
run_watchdog
assert_ordinary_count 1
# An ordinary closure must never consume or reset same-boot budget.
assert_file_eq "$SHARED_DIR/disruption_count" "1"
# With a restart already used this boot, the "no restart required" clause
# must NOT be asserted.
assert_not_contains "No WAN restart was required."
echo "  done (pass=$PASS fail=$FAIL)"

# ================================================================
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
