#!/bin/sh
# tests/test-recovery-hold.sh
#
# Test harness for ipv6-watchdog recovery hold state-change logging
# and ipv6-prefix-tracker hold-aware suppression.
#
# Tests the actual script logic via stub commands and temp state dirs.
# Does not require a live router.
#
# Usage: sh tests/test-recovery-hold.sh
# Exit:  0 = all pass, 1 = any fail

# --- Locate repo root ---
TEST_SCRIPT="$0"
SCRIPT_DIR="$(cd "$(dirname "$TEST_SCRIPT")/.." && pwd)"

# --- Create temp workspace ---
TEST_ROOT="$(mktemp -d 2>/dev/null || { D="/tmp/holdtest-$$"; mkdir -p "$D"; echo "$D"; })"
STUB_DIR="$TEST_ROOT/stubs"
STATE_DIR="$TEST_ROOT/state"
SHARED_DIR="$TEST_ROOT/wan-recovery"
CTRL_DIR="$TEST_ROOT/ctrl"
LOG_FILE="$TEST_ROOT/log.txt"
CONF_FILE="$TEST_ROOT/test.conf"
WATCHDOG_TEST="$TEST_ROOT/ipv6-watchdog.test"
TRACKER_TEST="$TEST_ROOT/ipv6-prefix-tracker.test"

ORIG_PATH="$PATH"
export HOLDTEST_CTRL="$CTRL_DIR"
export HOLDTEST_LOG="$LOG_FILE"

mkdir -p "$STUB_DIR" "$STATE_DIR" "$CTRL_DIR" "$SHARED_DIR"

# Stage C2: point the watchdog at the REAL shared coordinator (repo file) with
# a test-local shared state dir. This exercises the real legacy-state migration,
# shared hold/cooldown reads, and fail-closed API verification.
export WAN_RECOVERY_COMMON="$SCRIPT_DIR/wan-recovery-common"
export WAN_RECOVERY_STATE_DIR="$SHARED_DIR"

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

# ubus: outputs JSON for wan6 status based on control files.
# v3.10 contract: ipv6-prefix entries include both "address" and "mask".
cat > "$STUB_DIR/ubus" <<'STUBEOF'
#!/bin/sh
CTRL="${HOLDTEST_CTRL:-/tmp/holdtest-ctrl}"
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

# jsonfilter: extracts fields from JSON on stdin.
# v3.10 contract: distinguish .address from .mask within ipv6-prefix.
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

# ip: outputs routes, neighbors, and addresses based on control flags.
# v3.10 contract: supports source-specific route queries and LAN addr show
# so populate_pd_context / ipv6_ok Layers 1-4 can pass in Test G and any
# future PD-first hold-classifier tests.
cat > "$STUB_DIR/ip" <<'STUBEOF'
#!/bin/sh
CTRL="${HOLDTEST_CTRL:-/tmp/holdtest-ctrl}"

# addr show dev <dev> [deprecated]
if [ "$1" = "-6" ] && [ "$2" = "addr" ] && [ "$3" = "show" ]; then
    DEP=""
    for a in "$@"; do
        [ "$a" = "deprecated" ] && DEP=1
    done
    [ -n "$DEP" ] && exit 0
    # Emit WAN /128 if has_wan128 is set (for get_wan128 / Test T).
    if [ -f "$CTRL/has_wan128" ]; then
        printf 'inet6 2001:db8:dead:beef::1/128 scope global dynamic\n'
        printf '   valid_lft 86400sec preferred_lft 14400sec\n'
    fi
    LAN_SRC=$(cat "$CTRL/lan_src" 2>/dev/null)
    if [ -n "$LAN_SRC" ] && [ -f "$CTRL/has_prefix" ]; then
        printf 'inet6 %s/64 scope global dynamic\n' "$LAN_SRC"
        printf '   valid_lft 86400sec preferred_lft 14400sec\n'
    fi
    exit 0
fi

# route show default [from <src>] dev <dev>
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
        [ -f "$CTRL/has_src_route" ] && echo "default from $FROM via fe80::1 dev eth0 metric 512"
    else
        [ -f "$CTRL/has_route" ] && echo "default via fe80::1 dev eth0 metric 512"
    fi
    exit 0
fi

# route get <target> [from <src>] -- kernel-truth effective-route lookup.
# Resolution model (kernel FIB): an existing source-specific rule wins over
# the generic default; with neither, the kernel prints "unreachable" with
# rc=0. Generic-default-only routing is a valid effective path.
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
    if [ -f "$CTRL/has_src_route" ]; then
        echo "$FROM via fe80::1 dev eth0 metric 512"
    elif [ -f "$CTRL/has_route" ]; then
        echo "$FROM via fe80::1 dev eth0 metric 512"
    else
        echo "unreachable $FROM dev eth0"
    fi
    exit 0
fi

# neigh show dev <dev>
if [ "$1" = "-6" ] && [ "$2" = "neigh" ] && [ "$3" = "show" ]; then
    [ -f "$CTRL/neigh_router" ] && echo "fe80::1 dev eth0 lladdr 00:11:22:33:44:55 router REACHABLE"
    exit 0
fi

# neigh replace / route replace / route del: no-op success
exit 0
STUBEOF
chmod +x "$STUB_DIR/ip"

# ping6: distinguishes PD-source-bound from unbound pings.
# v3.10 contract: the hold classifier uses pd_internet_ok (PD-source-bound
# via -I <LAN_PD_SRC>), NOT internet_ok_now (unbound). Link-local/ff02::2 NDP
# probes always succeed. PD-source-bound public pings require pd_ok flag;
# unbound public pings require internet_ok flag (kept for diagnostics).
cat > "$STUB_DIR/ping6" <<'STUBEOF'
#!/bin/sh
CTRL="${HOLDTEST_CTRL:-/tmp/holdtest-ctrl}"
# Extract target (last non-flag arg) and detect -I source binding.
TARGET=""
HAS_SRC=0
for a in "$@"; do
    case "$a" in
        -I) HAS_SRC=1 ;;
        -*) ;;
        *) TARGET="$a" ;;
    esac
done
case "$TARGET" in
    ff02::2|fe80::*) exit 0 ;;
esac
# PD-source-bound public ping: use pd_ok flag.
if [ "$HAS_SRC" = "1" ]; then
    [ -f "$CTRL/pd_ok" ] && exit 0
    exit 1
fi
# Unbound public ping: use internet_ok flag (diagnostics only).
[ -f "$CTRL/internet_ok" ]
STUBEOF
chmod +x "$STUB_DIR/ping6"

# logger: captures messages to log file
cat > "$STUB_DIR/logger" <<'STUBEOF'
#!/bin/sh
LOG="${HOLDTEST_LOG:-/tmp/holdtest-log}"
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

# killall: no-op success
cat > "$STUB_DIR/killall" <<'STUBEOF'
#!/bin/sh
exit 0
STUBEOF
chmod +x "$STUB_DIR/killall"

# flock: pass-through success so the watchdog lock does not block tests.
cat > "$STUB_DIR/flock" <<'STUBEOF'
#!/bin/sh
exit 0
STUBEOF
chmod +x "$STUB_DIR/flock"

# sleep: no-op so tests run fast.
cat > "$STUB_DIR/sleep" <<'STUBEOF'
#!/bin/sh
exit 0
STUBEOF
chmod +x "$STUB_DIR/sleep"

# ifdown / ifup: no-op (not exercised by hold tests but stubbed for safety).
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

# ================================================================
# Test configuration
# ================================================================

cat > "$CONF_FILE" <<EOF
DISCORD_WEBHOOK="http://dummy-webhook.test"
WAN_RESTART_LIMIT=3
EOF

# ================================================================
# Modified script copies (sed: redirect paths only, logic unchanged)
# ================================================================

sed -e "s|STATE_DIR=\"/tmp/ipv6-watchdog\"|STATE_DIR=\"$STATE_DIR\"|" \
    -e "s|CONF=\"/etc/ipv6-watchdog.conf\"|CONF=\"$CONF_FILE\"|" \
    -e 's|^UPTIME_SECS=.*|UPTIME_SECS=999|' \
    "$SCRIPT_DIR/ipv6-watchdog" > "$WATCHDOG_TEST"
chmod +x "$WATCHDOG_TEST"

sed -e "s|STATE_FILE=\"/etc/ipv6-prefix-current\"|STATE_FILE=\"$STATE_DIR/prefix-current\"|" \
    -e "s|RECOVERY_HOLD_FILE=\"/tmp/ipv6-watchdog/recovery_hold\"|RECOVERY_HOLD_FILE=\"$STATE_DIR/recovery_hold\"|" \
    -e "s|CONF=\"/etc/ipv6-watchdog.conf\"|CONF=\"$CONF_FILE\"|" \
    "$SCRIPT_DIR/ipv6-prefix-tracker" > "$TRACKER_TEST"
chmod +x "$TRACKER_TEST"

# ================================================================
# Test helpers
# ================================================================

PASS=0
FAIL=0

run_watchdog() {
    : > "$LOG_FILE"
    PATH="$STUB_DIR:$ORIG_PATH" "$WATCHDOG_TEST" 2>/dev/null
}

run_tracker() {
    : > "$LOG_FILE"
    PATH="$STUB_DIR:$ORIG_PATH" "$TRACKER_TEST" 2>/dev/null
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

reset_state() {
    rm -rf "$STATE_DIR"/* 2>/dev/null
    rm -f "$CTRL_DIR"/* 2>/dev/null
    # Stage C2: also clear the shared coordinator state so each test starts
    # with a fresh same-boot budget (simulated reboot in Test G).
    rm -rf "$SHARED_DIR"/* 2>/dev/null
    mkdir -p "$SHARED_DIR"
    : > "$LOG_FILE"
}

set_restart_count() {
    mkdir -p "$STATE_DIR"
    echo "$1" > "$STATE_DIR/wan_restart_count"
}

seed_recovery_counters() {
    echo "5" > "$STATE_DIR/fail_count"
    echo "3" > "$STATE_DIR/prefix_fail_count"
    echo "2" > "$STATE_DIR/tier0_fail_count"
}

# v3.10 contract: seed full PD context so ipv6_ok Layers 1-5 pass.
# Required for Test G (clean healthy tick, no hold) which exercises the
# main ipv6_ok path, and for hold-block recovered state which now uses
# pd_internet_ok (PD-source-bound) instead of internet_ok_now (unbound).
seed_pd_context() {
    echo "56" > "$CTRL_DIR/prefix_mask"
    echo "2001:db8:1234:5678::1" > "$CTRL_DIR/prefix_addr"
    echo "2001:db8:1234:5678::abcd" > "$CTRL_DIR/lan_src"
    touch "$CTRL_DIR/has_src_route"
    touch "$CTRL_DIR/neigh_router"
    touch "$CTRL_DIR/pd_ok"
}

# ================================================================
# Tests A-G: ipv6-watchdog recovery hold
# ================================================================

echo "=== Test A: First hold tick with wan6 down ==="
reset_state
set_restart_count 3
seed_recovery_counters
run_watchdog
assert_contains "Recovery hold entered"
assert_contains "passive status: wan6-down"
assert_contains "ACTION REQUIRED"
assert_contains "Discord alert sent"
assert_file_exists "$STATE_DIR/recovery_hold"
assert_file_eq "$STATE_DIR/hold_status" "wan6-down"
assert_file_exists "$STATE_DIR/ont_notified"
assert_file_eq "$STATE_DIR/fail_count" "5"
assert_file_eq "$STATE_DIR/prefix_fail_count" "3"
echo "  done (pass=$PASS fail=$FAIL)"

echo "=== Test B: Five unchanged wan6-down ticks ==="
reset_state
set_restart_count 3
run_watchdog
for i in 1 2 3 4 5; do
    run_watchdog
    assert_empty_log
done
echo "  done (pass=$PASS fail=$FAIL)"

echo "=== Test C: wan6-down to no-prefix ==="
reset_state
set_restart_count 3
run_watchdog
touch "$CTRL_DIR/wan6_up"
echo "eth0" > "$CTRL_DIR/wan_dev"
run_watchdog
assert_contains "state change: wan6-down -> no-prefix"
assert_not_contains "ACTION REQUIRED"
assert_not_contains "Discord alert sent"
assert_file_eq "$STATE_DIR/hold_status" "no-prefix"
echo "  done (pass=$PASS fail=$FAIL)"

echo "=== Test D: no-prefix to recovered ==="
reset_state
set_restart_count 3
seed_recovery_counters
touch "$CTRL_DIR/wan6_up"
echo "eth0" > "$CTRL_DIR/wan_dev"
run_watchdog
touch "$CTRL_DIR/has_prefix"
touch "$CTRL_DIR/has_route"
seed_pd_context
run_watchdog
assert_contains "state change: no-prefix -> recovered"
assert_contains "spontaneously recovered"
assert_contains "Discord recovery notice sent"
assert_file_eq "$STATE_DIR/hold_status" "recovered"
assert_file_eq "$STATE_DIR/wan_restart_count" "3"
assert_file_exists "$STATE_DIR/ont_notified"
assert_file_exists "$STATE_DIR/recovery_hold"
assert_file_eq "$STATE_DIR/fail_count" "5"
assert_file_eq "$STATE_DIR/prefix_fail_count" "3"
echo "  done (pass=$PASS fail=$FAIL)"

echo "=== Test E: Five repeated recovered ticks ==="
reset_state
set_restart_count 3
touch "$CTRL_DIR/wan6_up"
echo "eth0" > "$CTRL_DIR/wan_dev"
touch "$CTRL_DIR/has_prefix"
touch "$CTRL_DIR/has_route"
seed_pd_context
run_watchdog
for i in 1 2 3 4 5; do
    run_watchdog
    assert_empty_log
done
echo "  done (pass=$PASS fail=$FAIL)"

echo "=== Test F: recovered to prefix-present-unreachable ==="
reset_state
set_restart_count 3
run_watchdog
touch "$CTRL_DIR/wan6_up"
echo "eth0" > "$CTRL_DIR/wan_dev"
touch "$CTRL_DIR/has_prefix"
touch "$CTRL_DIR/has_route"
seed_pd_context
run_watchdog
rm -f "$CTRL_DIR/pd_ok"
run_watchdog
assert_contains "state change: recovered -> prefix-present-unreachable"
assert_not_contains "ACTION REQUIRED"
assert_not_contains "Discord recovery notice"
echo "  done (pass=$PASS fail=$FAIL)"

echo "=== Test G: Simulated reboot (clear /tmp state) ==="
reset_state
set_restart_count 0
touch "$CTRL_DIR/wan6_up"
echo "eth0" > "$CTRL_DIR/wan_dev"
touch "$CTRL_DIR/has_prefix"
touch "$CTRL_DIR/has_route"
touch "$CTRL_DIR/internet_ok"
# v3.10 contract: seed full PD context so ipv6_ok Layers 1-4 pass on the
# clean healthy tick (no hold, so the main ipv6_ok path runs, not the hold
# block's internet_ok_now classifier).
seed_pd_context
run_watchdog
assert_empty_log
assert_file_not_exists "$STATE_DIR/recovery_hold"
echo "  done (pass=$PASS fail=$FAIL)"

# ================================================================
# Tests H-J: ipv6-prefix-tracker
# ================================================================

echo "=== Test H: prefix-tracker no prefix, no hold ==="
reset_state
run_tracker
assert_contains "No delegated prefix currently available"
echo "  done (pass=$PASS fail=$FAIL)"

echo "=== Test I: prefix-tracker no prefix, hold present ==="
reset_state
touch "$STATE_DIR/recovery_hold"
run_tracker
assert_empty_log
echo "  done (pass=$PASS fail=$FAIL)"

echo "=== Test J: prefix-tracker prefix present during hold ==="
reset_state
touch "$STATE_DIR/recovery_hold"
touch "$CTRL_DIR/wan6_up"
echo "eth0" > "$CTRL_DIR/wan_dev"
touch "$CTRL_DIR/has_prefix"
echo "2001:db8:aaaa::1" > "$CTRL_DIR/prefix_addr"
run_tracker
assert_contains "Prefix initialized"
assert_file_eq "$STATE_DIR/prefix-current" "2001:db8:aaaa::1"
echo "2001:db8:bbbb::2" > "$CTRL_DIR/prefix_addr"
run_tracker
assert_contains "Prefix changed"
assert_contains "SIGHUP"
assert_file_eq "$STATE_DIR/prefix-current" "2001:db8:bbbb::2"
echo "  done (pass=$PASS fail=$FAIL)"

# ================================================================
# Test K: First hold tick already recovered
# ================================================================

echo "=== Test K1: First hold tick already recovered (with ONT_FLAG) ==="
reset_state
set_restart_count 3
seed_recovery_counters
touch "$STATE_DIR/ont_notified"
touch "$CTRL_DIR/wan6_up"
echo "eth0" > "$CTRL_DIR/wan_dev"
touch "$CTRL_DIR/has_prefix"
touch "$CTRL_DIR/has_route"
seed_pd_context
run_watchdog
assert_contains "Recovery hold entered"
assert_contains "passive status: recovered"
assert_contains "spontaneously recovered"
assert_contains "Discord recovery notice sent"
assert_not_contains "ACTION REQUIRED"
assert_file_eq "$STATE_DIR/hold_status" "recovered"
assert_file_eq "$STATE_DIR/wan_restart_count" "3"
assert_file_exists "$STATE_DIR/ont_notified"
assert_file_exists "$STATE_DIR/recovery_hold"
assert_file_eq "$STATE_DIR/fail_count" "5"
# Second tick: silent
run_watchdog
assert_empty_log
echo "  done (pass=$PASS fail=$FAIL)"

echo "=== Test K2: First hold tick already recovered (no ONT_FLAG) ==="
reset_state
set_restart_count 3
seed_recovery_counters
touch "$CTRL_DIR/wan6_up"
echo "eth0" > "$CTRL_DIR/wan_dev"
touch "$CTRL_DIR/has_prefix"
touch "$CTRL_DIR/has_route"
seed_pd_context
run_watchdog
assert_contains "Recovery hold entered"
assert_contains "passive status: recovered"
assert_contains "spontaneously recovered"
# Recovery notification IS sent (force=1 bypasses ONT_FLAG gate in hold mode)
assert_contains "Discord recovery notice sent"
# No ONT alert because hold_state is recovered
assert_not_contains "ACTION REQUIRED"
assert_file_eq "$STATE_DIR/hold_status" "recovered"
assert_file_eq "$STATE_DIR/wan_restart_count" "3"
# ONT_FLAG NOT created (state was recovered, ONT alert block skipped)
assert_file_not_exists "$STATE_DIR/ont_notified"
assert_file_exists "$STATE_DIR/recovery_hold"
# Second tick: silent
run_watchdog
assert_empty_log
echo "  done (pass=$PASS fail=$FAIL)"

echo "=== Test L: recovered -> degraded -> recovered ==="
reset_state
set_restart_count 3
seed_recovery_counters
touch "$STATE_DIR/ont_notified"
touch "$CTRL_DIR/wan6_up"
echo "eth0" > "$CTRL_DIR/wan_dev"
touch "$CTRL_DIR/has_prefix"
touch "$CTRL_DIR/has_route"
seed_pd_context
# Tick 1: first recovered - one recovery notification
run_watchdog
assert_contains "spontaneously recovered"
assert_contains "Discord recovery notice sent"
# Tick 2: degrade - transition logged, no recovery re-notification
rm -f "$CTRL_DIR/pd_ok"
run_watchdog
assert_contains "state change: recovered -> prefix-present-unreachable"
assert_not_contains "Discord recovery notice"
assert_not_contains "spontaneously recovered"
# Tick 3: recover again - exactly one new recovery notification
touch "$CTRL_DIR/pd_ok"
run_watchdog
assert_contains "state change: prefix-present-unreachable -> recovered"
assert_contains "spontaneously recovered"
assert_contains "Discord recovery notice sent"
# Tick 4: silent
run_watchdog
assert_empty_log
echo "  done (pass=$PASS fail=$FAIL)"

# ================================================================
# Tests M-T: v3.10 PD-first hold classification
# The hold classifier now matches ipv6_ok() Layers 1-5. "recovered"
# requires IA_PD + LAN_PD_SRC + generic default + PD source-specific
# default + pd_internet_ok. WAN /128 or unbound reachability must NEVER
# classify as recovered.
# ================================================================

echo "=== Test M: PD healthy -> recovered ==="
reset_state
set_restart_count 3
seed_recovery_counters
touch "$CTRL_DIR/wan6_up"
echo "eth0" > "$CTRL_DIR/wan_dev"
touch "$CTRL_DIR/has_prefix"
touch "$CTRL_DIR/has_route"
seed_pd_context
run_watchdog
assert_contains "Recovery hold entered"
assert_contains "passive status: recovered"
assert_file_eq "$STATE_DIR/hold_status" "recovered"
echo "  done (pass=$PASS fail=$FAIL)"

echo "=== Test N: WAN /128 works but PD-source path fails -> NOT recovered ==="
reset_state
set_restart_count 3
seed_recovery_counters
touch "$CTRL_DIR/wan6_up"
echo "eth0" > "$CTRL_DIR/wan_dev"
touch "$CTRL_DIR/has_prefix"
touch "$CTRL_DIR/has_route"
# PD context: LAN source + src route present, but PD-source-bound ping fails.
echo "56" > "$CTRL_DIR/prefix_mask"
echo "2001:db8:1234:5678::1" > "$CTRL_DIR/prefix_addr"
echo "2001:db8:1234:5678::abcd" > "$CTRL_DIR/lan_src"
touch "$CTRL_DIR/has_src_route"
touch "$CTRL_DIR/neigh_router"
# NO pd_ok flag -> pd_internet_ok fails.
# internet_ok flag set -> unbound ping would succeed, but must NOT matter.
touch "$CTRL_DIR/internet_ok"
run_watchdog
assert_contains "passive status: prefix-present-unreachable"
assert_not_contains "passive status: recovered"
assert_file_eq "$STATE_DIR/hold_status" "prefix-present-unreachable"
echo "  done (pass=$PASS fail=$FAIL)"

echo "=== Test O: IA_PD exists but LAN_PD_SRC missing -> NOT recovered ==="
reset_state
set_restart_count 3
seed_recovery_counters
touch "$CTRL_DIR/wan6_up"
echo "eth0" > "$CTRL_DIR/wan_dev"
touch "$CTRL_DIR/has_prefix"
touch "$CTRL_DIR/has_route"
# PD context: prefix mask + addr present, but NO lan_src.
echo "56" > "$CTRL_DIR/prefix_mask"
echo "2001:db8:1234:5678::1" > "$CTRL_DIR/prefix_addr"
# NO lan_src file -> get_lan_pd_src returns empty.
# Even if unbound ping works, this must NOT be recovered.
touch "$CTRL_DIR/internet_ok"
touch "$CTRL_DIR/pd_ok"
run_watchdog
assert_contains "passive status: prefix-no-lan-src"
assert_not_contains "passive status: recovered"
assert_file_eq "$STATE_DIR/hold_status" "prefix-no-lan-src"
echo "  done (pass=$PASS fail=$FAIL)"

echo "=== Test P: generic-default-only contract -> recovered ==="
reset_state
set_restart_count 3
seed_recovery_counters
touch "$CTRL_DIR/wan6_up"
echo "eth0" > "$CTRL_DIR/wan_dev"
touch "$CTRL_DIR/has_prefix"
touch "$CTRL_DIR/has_route"
# PD context: lan_src present, but NO has_src_route (generic-default-only).
# Kernel-effective resolution falls back to the generic default, so the hold
# classifies recovered when PD-source reachability passes -- an explicit
# 'default from <PD_CIDR>' rule is OPTIONAL for health (live-verified state).
echo "56" > "$CTRL_DIR/prefix_mask"
echo "2001:db8:1234:5678::1" > "$CTRL_DIR/prefix_addr"
echo "2001:db8:1234:5678::abcd" > "$CTRL_DIR/lan_src"
touch "$CTRL_DIR/neigh_router"
touch "$CTRL_DIR/pd_ok"
# NO has_src_route -> Layer 4 still passes (effective via generic default).
run_watchdog
assert_contains "passive status: recovered"
assert_not_contains "passive status: prefix-present-no-src-route"
assert_file_eq "$STATE_DIR/hold_status" "recovered"
echo "  done (pass=$PASS fail=$FAIL)"

echo "=== Test Q: PD routes coherent but PD-source external connectivity fails -> prefix-present-unreachable ==="
reset_state
set_restart_count 3
seed_recovery_counters
touch "$CTRL_DIR/wan6_up"
echo "eth0" > "$CTRL_DIR/wan_dev"
touch "$CTRL_DIR/has_prefix"
touch "$CTRL_DIR/has_route"
echo "56" > "$CTRL_DIR/prefix_mask"
echo "2001:db8:1234:5678::1" > "$CTRL_DIR/prefix_addr"
echo "2001:db8:1234:5678::abcd" > "$CTRL_DIR/lan_src"
touch "$CTRL_DIR/has_src_route"
touch "$CTRL_DIR/neigh_router"
# NO pd_ok -> pd_internet_ok fails (Layer 5).
run_watchdog
assert_contains "passive status: prefix-present-unreachable"
assert_not_contains "passive status: recovered"
assert_file_eq "$STATE_DIR/hold_status" "prefix-present-unreachable"
echo "  done (pass=$PASS fail=$FAIL)"

echo "=== Test R: repeated identical degraded state -> silent ==="
reset_state
set_restart_count 3
seed_recovery_counters
touch "$CTRL_DIR/wan6_up"
echo "eth0" > "$CTRL_DIR/wan_dev"
touch "$CTRL_DIR/has_prefix"
touch "$CTRL_DIR/has_route"
echo "56" > "$CTRL_DIR/prefix_mask"
echo "2001:db8:1234:5678::1" > "$CTRL_DIR/prefix_addr"
echo "2001:db8:1234:5678::abcd" > "$CTRL_DIR/lan_src"
touch "$CTRL_DIR/has_src_route"
touch "$CTRL_DIR/neigh_router"
# NO pd_ok -> stuck in prefix-present-unreachable.
run_watchdog
assert_contains "Recovery hold entered"
assert_contains "passive status: prefix-present-unreachable"
# Five repeated ticks: same state, must be silent.
for i in 1 2 3 4 5; do
    run_watchdog
    assert_empty_log
done
assert_file_eq "$STATE_DIR/hold_status" "prefix-present-unreachable"
echo "  done (pass=$PASS fail=$FAIL)"

echo "=== Test S: recovered -> degraded -> recovered -> exactly one notification per transition ==="
reset_state
set_restart_count 3
seed_recovery_counters
touch "$STATE_DIR/ont_notified"
touch "$CTRL_DIR/wan6_up"
echo "eth0" > "$CTRL_DIR/wan_dev"
touch "$CTRL_DIR/has_prefix"
touch "$CTRL_DIR/has_route"
seed_pd_context
# Tick 1: first recovered - one recovery notification.
run_watchdog
assert_contains "spontaneously recovered"
assert_contains "Discord recovery notice sent"
# Tick 2: degrade to prefix-no-lan-src (remove lan_src) - transition logged.
rm -f "$CTRL_DIR/lan_src"
run_watchdog
assert_contains "state change: recovered -> prefix-no-lan-src"
assert_not_contains "Discord recovery notice"
assert_not_contains "spontaneously recovered"
# Tick 3: recover again - restore lan_src, exactly one new notification.
echo "2001:db8:1234:5678::abcd" > "$CTRL_DIR/lan_src"
run_watchdog
assert_contains "state change: prefix-no-lan-src -> recovered"
assert_contains "spontaneously recovered"
assert_contains "Discord recovery notice sent"
# Tick 4: silent.
run_watchdog
assert_empty_log
echo "  done (pass=$PASS fail=$FAIL)"

echo "=== Test T: healthy /128 + healthy /56 coexistence -> recovered, /128 not a fault ==="
reset_state
set_restart_count 3
seed_recovery_counters
touch "$STATE_DIR/ont_notified"
touch "$CTRL_DIR/wan6_up"
echo "eth0" > "$CTRL_DIR/wan_dev"
touch "$CTRL_DIR/has_prefix"
touch "$CTRL_DIR/has_route"
seed_pd_context
# Simulate WAN /128 presence: the ip stub emits it when has_wan128 is set.
# The hold classifier must IGNORE /128 and still classify as recovered.
touch "$CTRL_DIR/has_wan128"
run_watchdog
assert_contains "passive status: recovered"
assert_not_contains "prefix-present-unreachable"
assert_not_contains "prefix-no-lan-src"
assert_file_eq "$STATE_DIR/hold_status" "recovered"
# Second tick: still recovered, silent (no degradation from /128 presence).
run_watchdog
assert_empty_log
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
