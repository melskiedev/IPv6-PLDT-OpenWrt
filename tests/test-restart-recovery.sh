#!/bin/sh
# tests/test-restart-recovery.sh
#
# Test harness for RESTART-ASSISTED (class B) IPv6 recovery closure.
#
# Three distinct recovery classes exist:
#   A. Ordinary          confirmed failure 1/2 -> healthy, no WAN restart
#   B. Restart-assisted  confirmed failure 3 -> full WAN restart -> healthy
#   C. Critical/hold     restart budget exhausted / ONT alert -> healthy
#
# Class A is closed by notify_ordinary_recovery(); class C by
# notify_ipv6_recovered(). Class B had NO owner: do_wan_restart() zeroes
# FAIL_FILE, so by the time IPv6 goes healthy again FAILS is 0 and the
# ordinary closure is correctly silent, while notify_ipv6_recovered() stays
# ONT_FLAG-gated and a plain restart never sets ONT_FLAG. Production on
# KamuningFlint2 (Aug 16) hit exactly this: failures 1-3, "Full WAN restart
# #1 of 3", gateway replaced, source policy switched to pd-preferred, IPv6
# healthy -- and not one closure line.
#
# Contract under test:
#   - A full WAN restart opens a restart-incident marker recording THIS
#     incident's restart ordinal.
#   - The marker, not the cumulative shared disruption_count, is what proves
#     the current incident required a restart. disruption_count is same-boot
#     cumulative shared state and must never by itself trigger a closure.
#   - The marker survives the wan6 ifdown/ifup lifecycle and subsequent cron
#     ticks; it is cleared only by a positive-health closure or by the
#     incident passing into critical/hold ownership.
#   - Exactly one closure fires per incident. Precedence:
#     critical/hold > restart-assisted > ordinary.
#   - The restart-assisted closure must never claim "No WAN restart was
#     required."
#
# Usage: bash tests/test-restart-recovery.sh
# Exit:  0 = all pass, 1 = any fail

TEST_SCRIPT="$0"
SCRIPT_DIR="$(cd "$(dirname "$TEST_SCRIPT")/.." && pwd)"

TEST_ROOT="$(mktemp -d 2>/dev/null || { D="/tmp/rrtest-$$"; mkdir -p "$D"; echo "$D"; })"
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

export WAN_RECOVERY_COMMON="$SCRIPT_DIR/wan-recovery-common"
export WAN_RECOVERY_STATE_DIR="$SHARED_DIR"

cleanup() { rm -rf "$TEST_ROOT"; }
trap cleanup EXIT
trap 'cleanup; exit 130' INT
trap 'cleanup; exit 143' TERM

# ================================================================
# Stubs
# ================================================================

cat > "$STUB_DIR/ubus" <<'STUBEOF'
#!/bin/sh
CTRL="${RC_CTRL:-/tmp/rrtest-ctrl}"
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
    *'"up"'*)        printf '%s' "$INPUT" | sed -n 's/.*"up":\([a-z]*\).*/\1/p' ;;
    *'"l3_device"'*) printf '%s' "$INPUT" | sed -n 's/.*"l3_device":"\([^"]*\)".*/\1/p' ;;
    *'"pending"'*)   printf '%s' "$INPUT" | sed -n 's/.*"pending":\([a-z]*\).*/\1/p' ;;
    *'"ipv6-prefix"'*'.mask'*) printf '%s' "$INPUT" | sed -n 's/.*"mask":\([0-9]*\).*/\1/p' ;;
    *'"ipv6-prefix"'*) printf '%s' "$INPUT" | sed -n 's/.*"address":"\([^"]*\)".*/\1/p' ;;
esac
STUBEOF
chmod +x "$STUB_DIR/jsonfilter"

cat > "$STUB_DIR/ip" <<'STUBEOF'
#!/bin/sh
CTRL="${RC_CTRL:-/tmp/rrtest-ctrl}"
GW="fe80::1"
[ -f "$CTRL/gw" ] && GW=$(cat "$CTRL/gw")

if [ "$1" = "-6" ] && [ "$2" = "addr" ] && [ "$3" = "show" ]; then
    DEP=""
    for a in "$@"; do [ "$a" = "deprecated" ] && DEP=1; done
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
    [ -f "$CTRL/neigh_router" ] && echo "$GW dev eth0 lladdr 00:11:22:33:44:55 router REACHABLE"
    exit 0
fi

exit 0
STUBEOF
chmod +x "$STUB_DIR/ip"

cat > "$STUB_DIR/ping6" <<'STUBEOF'
#!/bin/sh
CTRL="${RC_CTRL:-/tmp/rrtest-ctrl}"
POS=$(cat "$CTRL/ping_pos" 2>/dev/null)
[ -z "$POS" ] && POS=0
TOKEN=$(awk -v p=$((POS + 1)) '{print $p}' "$CTRL/ping_seq" 2>/dev/null)
echo $((POS + 1)) > "$CTRL/ping_pos"
[ "$TOKEN" = "pass" ] && exit 0
exit 1
STUBEOF
chmod +x "$STUB_DIR/ping6"

for s in sleep ifdown ifup flock; do
    printf '#!/bin/sh\nexit 0\n' > "$STUB_DIR/$s"
    chmod +x "$STUB_DIR/$s"
done

cat > "$STUB_DIR/logger" <<'STUBEOF'
#!/bin/sh
LOG="${RC_LOG:-/tmp/rrtest-log}"
while [ $# -gt 0 ]; do
    case "$1" in
        -t) shift 2 ;;
        *) echo "$1" >> "$LOG"; shift ;;
    esac
done
STUBEOF
chmod +x "$STUB_DIR/logger"

# uci: models the reqaddress staging that try_128_bootstrap depends on.
#   get network.wan6.reqaddress -> "none" (the only committed value the
#     bootstrap will act on)
#   set ...reqaddress='try'     -> IA_NA-assisted acquisition yields an IA_PD,
#     so the prefix appears. This is the mechanism the bootstrap is testing.
#   revert                      -> production mode returns; the prefix survives
#     unless $CTRL/lose_pd_after_revert is set (the B7 failure case).
# Any other get returns a hostname so notify_* identity lookups work.
cat > "$STUB_DIR/uci" <<'STUBEOF'
#!/bin/sh
CTRL="${RC_CTRL:-/tmp/rrtest-ctrl}"
case "$1 $2" in
    "get network.wan6.reqaddress")
        if [ -f "$CTRL/reqaddress" ]; then cat "$CTRL/reqaddress"; else echo "none"; fi
        exit 0
        ;;
esac
case "$2" in
    "network.wan6.reqaddress='try'"|"network.wan6.reqaddress=try")
        echo "try" > "$CTRL/reqaddress"
        [ -f "$CTRL/bootstrap_yields_pd" ] && touch "$CTRL/has_prefix"
        exit 0
        ;;
    "network.wan6.reqaddress")
        # uci revert: back to the committed production value.
        rm -f "$CTRL/reqaddress"
        [ -f "$CTRL/lose_pd_after_revert" ] && rm -f "$CTRL/has_prefix"
        exit 0
        ;;
esac
echo "TestRouter"
STUBEOF
chmod +x "$STUB_DIR/uci"

cat > "$STUB_DIR/curl" <<'STUBEOF'
#!/bin/sh
CTRL="${RC_CTRL:-/tmp/rrtest-ctrl}"
echo "POST" >> "$CTRL/curl_log"
exit 0
STUBEOF
chmod +x "$STUB_DIR/curl"

cat > "$STUB_DIR/date" <<'STUBEOF'
#!/bin/sh
CTRL="${RC_CTRL:-/tmp/rrtest-ctrl}"
if [ "$1" = "+%s" ]; then
    if [ -f "$CTRL/now" ]; then cat "$CTRL/now"; else echo 1700000000; fi
    exit 0
fi
/usr/bin/date "$@"
STUBEOF
chmod +x "$STUB_DIR/date"

# ================================================================
# Config / build
# ================================================================

cat > "$CONF_FILE" <<EOF
DISCORD_WEBHOOK="http://dummy-webhook.test"
WAN_RESTART_LIMIT=3
REACHABILITY_CONFIRM_DELAY=1
EOF

# Second config with the experimental Phase 3 bootstrap ENABLED, so the
# try_128_bootstrap success path (reset_recovery_state call site #3) is
# actually reachable. Production default remains BOOTSTRAP_ENABLED=0.
BOOT_CONF="$TEST_ROOT/bootstrap.conf"
WATCHDOG_BOOT="$TEST_ROOT/ipv6-watchdog.boot"
cat > "$BOOT_CONF" <<EOF
DISCORD_WEBHOOK="http://dummy-webhook.test"
WAN_RESTART_LIMIT=3
REACHABILITY_CONFIRM_DELAY=1
BOOTSTRAP_ENABLED=1
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
build_watchdog "$WATCHDOG_BOOT" "$BOOT_CONF"

# ================================================================
# Helpers
# ================================================================

PASS=0
FAIL=0

RESTART_PREFIX="IPv6 connectivity recovered after full WAN restart"
ORDINARY_PREFIX="IPv6 connectivity recovered after"
MARKER="$STATE_DIR/restart_incident"

run_watchdog() {
    : > "$LOG_FILE"
    : > "$CTRL_DIR/curl_log"
    PATH="$STUB_DIR:$ORIG_PATH" "$WATCHDOG_TEST" 2>/dev/null
}

# Run the BOOTSTRAP_ENABLED=1 build (exercises reset_recovery_state site #3).
run_watchdog_boot() {
    : > "$LOG_FILE"
    : > "$CTRL_DIR/curl_log"
    PATH="$STUB_DIR:$ORIG_PATH" "$WATCHDOG_BOOT" 2>/dev/null
}

# Stage the no-prefix ladder so the NEXT tick lands on PREFIX_FAILS == 3,
# which is the try_128_bootstrap branch. Clears the prefix and the backoff
# gate, and pushes NOW past the shared post-restart cooldown.
stage_bootstrap_tick() {
    rm -f "$CTRL_DIR/has_prefix"
    rm -f "$STATE_DIR/prefix_next_attempt"
    echo "2" > "$STATE_DIR/prefix_fail_count"
    touch "$CTRL_DIR/bootstrap_yields_pd"
    # try_128_bootstrap calls pd_internet_ok several times (B5 fix_gateway,
    # the B6 revert gate, and the B9 final gate). Give it a long pass run so
    # reachability is not the thing under test here.
    many_pass
}

# A ping sequence long enough that no reachability check runs off the end.
many_pass() {
    n=0
    seq=""
    while [ "$n" -lt 40 ]; do
        seq="$seq pass"
        n=$((n + 1))
    done
    set_ping_seq $seq
}

assert_contains() {
    if grep -qF "$1" "$LOG_FILE" 2>/dev/null; then PASS=$((PASS + 1))
    else
        FAIL=$((FAIL + 1)); echo "  FAIL: expected log containing: $1"
        sed 's/^/    /' "$LOG_FILE" 2>/dev/null >&2
    fi
}

assert_not_contains() {
    if grep -qF "$1" "$LOG_FILE" 2>/dev/null; then
        FAIL=$((FAIL + 1)); echo "  FAIL: log should NOT contain: $1"
        sed 's/^/    /' "$LOG_FILE" 2>/dev/null >&2
    else PASS=$((PASS + 1)); fi
}

count_of() {
    n=$(grep -cF "$1" "$LOG_FILE" 2>/dev/null)
    [ -z "$n" ] && n=0
    echo "$n"
}

assert_count() {
    actual=$(count_of "$1")
    if [ "$actual" = "$2" ]; then PASS=$((PASS + 1))
    else
        FAIL=$((FAIL + 1)); echo "  FAIL: expected $2 line(s) matching '$1', got $actual"
        sed 's/^/    /' "$LOG_FILE" 2>/dev/null >&2
    fi
}

# Count of restart-assisted lines specifically (a subset of ORDINARY_PREFIX).
assert_restart_count() { assert_count "$RESTART_PREFIX" "$1"; }

# Ordinary closure lines EXCLUDING restart-assisted ones.
assert_ordinary_only_count() {
    total=$(count_of "$ORDINARY_PREFIX")
    restart=$(count_of "$RESTART_PREFIX")
    actual=$((total - restart))
    if [ "$actual" = "$1" ]; then PASS=$((PASS + 1))
    else
        FAIL=$((FAIL + 1)); echo "  FAIL: expected $1 ordinary-only closure(s), got $actual"
        sed 's/^/    /' "$LOG_FILE" 2>/dev/null >&2
    fi
}

assert_file_eq() {
    actual=$(cat "$1" 2>/dev/null)
    if [ "$actual" = "$2" ]; then PASS=$((PASS + 1))
    else FAIL=$((FAIL + 1)); echo "  FAIL: expected '$2' in $(basename "$1"), got '$actual'"; fi
}

assert_file_exists() {
    if [ -f "$1" ]; then PASS=$((PASS + 1))
    else FAIL=$((FAIL + 1)); echo "  FAIL: expected file $(basename "$1") to exist"; fi
}

assert_file_not_exists() {
    if [ -f "$1" ]; then FAIL=$((FAIL + 1)); echo "  FAIL: expected file $(basename "$1") to NOT exist"
    else PASS=$((PASS + 1)); fi
}

reset_state() {
    rm -rf "$STATE_DIR"/* 2>/dev/null
    rm -f "$CTRL_DIR"/* 2>/dev/null
    rm -rf "$SHARED_DIR"/* 2>/dev/null
    mkdir -p "$SHARED_DIR" "$STATE_DIR" "$CTRL_DIR"
    : > "$LOG_FILE"
    : > "$CTRL_DIR/curl_log"
}

set_ping_seq() { echo "$*" > "$CTRL_DIR/ping_seq"; echo "0" > "$CTRL_DIR/ping_pos"; }
set_now()      { echo "$1" > "$CTRL_DIR/now"; }
all_fail()     { set_ping_seq fail fail fail fail fail fail fail fail fail fail; }
all_pass()     { set_ping_seq pass pass pass pass; }

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

# Drive one tick that escalates to a full WAN restart (fail_count 2 -> 3).
escalate_to_restart() {
    echo "2" > "$STATE_DIR/fail_count"
    all_fail
    run_watchdog
}

# ================================================================
# Tests
# ================================================================

echo "=== Test A: failure 3 -> WAN restart -> healthy = exactly ONE restart-assisted closure ==="
reset_state
seed_healthy_layer12
set_now 1700000000
escalate_to_restart
assert_contains "Full WAN restart #1 of 3"
assert_file_eq "$STATE_DIR/fail_count" "0"
# Now IPv6 comes back on a later tick.
set_now 1700000300
all_pass
run_watchdog
assert_restart_count 1
assert_contains "IPv6 connectivity recovered after full WAN restart #1 of 3."
assert_contains "PD-source Internet connectivity verified."
assert_contains "Cause was not determined."
echo "  done (pass=$PASS fail=$FAIL)"

echo "=== Test B: no ORDINARY closure fires for a restart-assisted incident ==="
reset_state
seed_healthy_layer12
set_now 1700000000
escalate_to_restart
set_now 1700000300
all_pass
run_watchdog
assert_ordinary_only_count 0
echo "  done (pass=$PASS fail=$FAIL)"

echo "=== Test C: restart-assisted closure must NOT claim no restart was needed ==="
reset_state
seed_healthy_layer12
set_now 1700000000
escalate_to_restart
set_now 1700000300
all_pass
run_watchdog
assert_not_contains "No WAN restart was required."
echo "  done (pass=$PASS fail=$FAIL)"

echo "=== Test D: marker opens on restart and survives the wan6 lifecycle ==="
reset_state
seed_healthy_layer12
set_now 1700000000
escalate_to_restart
assert_file_exists "$MARKER"
assert_file_eq "$MARKER" "1"
# A tick where IPv6 is still broken must NOT close and must NOT lose the marker.
set_now 1700000200
all_fail
run_watchdog
assert_restart_count 0
assert_file_exists "$MARKER"
assert_file_eq "$MARKER" "1"
echo "  done (pass=$PASS fail=$FAIL)"

echo "=== Test E: marker clears on successful closure, and only then ==="
reset_state
seed_healthy_layer12
set_now 1700000000
escalate_to_restart
assert_file_exists "$MARKER"
set_now 1700000300
all_pass
run_watchdog
assert_restart_count 1
assert_file_not_exists "$MARKER"
# A second healthy tick must be silent: the incident is already closed.
run_watchdog
assert_restart_count 0
assert_ordinary_only_count 0
echo "  done (pass=$PASS fail=$FAIL)"

echo "=== Test F: a second restart incident reports restart #2 ==="
reset_state
seed_healthy_layer12
set_now 1700000000
escalate_to_restart
set_now 1700000300
all_pass
run_watchdog
assert_contains "full WAN restart #1 of 3."
# Advance past the 1200s shared cooldown so a second full restart is allowed.
set_now 1700002000
escalate_to_restart
assert_contains "Full WAN restart #2 of 3"
assert_file_eq "$MARKER" "2"
set_now 1700002300
all_pass
run_watchdog
assert_restart_count 1
assert_contains "full WAN restart #2 of 3."
assert_not_contains "full WAN restart #1 of 3."
echo "  done (pass=$PASS fail=$FAIL)"

echo "=== Test G: hold/critical ownership suppresses the restart-assisted closure ==="
reset_state
seed_healthy_layer12
set_now 1700000000
escalate_to_restart
assert_file_exists "$MARKER"
# Budget exhausted -> hold takes ownership of the incident.
echo "3" > "$SHARED_DIR/disruption_count"
set_now 1700000300
all_pass
run_watchdog
assert_restart_count 0
assert_ordinary_only_count 0
assert_contains "Recovery hold: IPv6 spontaneously recovered"
echo "  done (pass=$PASS fail=$FAIL)"

echo "=== Test H: historical disruption_count with NO marker emits no false closure ==="
reset_state
seed_healthy_layer12
set_now 1700000000
# Simulate a boot-time healthy tick where a restart happened earlier this boot
# for an incident that was already closed. Cumulative shared state must NOT be
# treated as proof that THIS tick closes a restart-assisted incident.
echo "1" > "$SHARED_DIR/disruption_count"
echo "0" > "$STATE_DIR/fail_count"
all_pass
run_watchdog
assert_restart_count 0
assert_ordinary_only_count 0
assert_file_not_exists "$MARKER"
echo "  done (pass=$PASS fail=$FAIL)"

echo "=== Test I: restart-assisted closure is exactly ONE log line ==="
reset_state
seed_healthy_layer12
set_now 1700000000
escalate_to_restart
set_now 1700000300
all_pass
run_watchdog
assert_restart_count 1
clauses=$(grep -cE 'PD-source Internet connectivity verified|Cause was not determined' "$LOG_FILE" 2>/dev/null)
if [ "$clauses" = "1" ]; then PASS=$((PASS + 1))
else
    FAIL=$((FAIL + 1))
    echo "  FAIL: restart closure spread across $clauses log lines, expected 1"
    sed 's/^/    /' "$LOG_FILE" 2>/dev/null >&2
fi
echo "  done (pass=$PASS fail=$FAIL)"

echo "=== Test J: gateway reported only when provable ==="
reset_state
seed_healthy_layer12
echo "fe80::57d9" > "$CTRL_DIR/gw"
set_now 1700000000
escalate_to_restart
set_now 1700000300
all_pass
run_watchdog
assert_contains "Current gateway: fe80::57d9."
# And omitted when the default route carries no via.
reset_state
seed_healthy_layer12
touch "$CTRL_DIR/no_via"
set_now 1700000000
escalate_to_restart
set_now 1700000300
all_pass
run_watchdog
assert_restart_count 1
assert_not_contains "Current gateway:"
echo "  done (pass=$PASS fail=$FAIL)"

echo "=== Test K: after a closed restart incident, a later ordinary incident closes as ordinary ==="
reset_state
seed_healthy_layer12
set_now 1700000000
escalate_to_restart
set_now 1700000300
all_pass
run_watchdog
assert_restart_count 1
assert_file_not_exists "$MARKER"
# New, milder incident: one confirmed failure then healthy.
set_now 1700000600
echo "0" > "$STATE_DIR/fail_count"
all_fail
run_watchdog
assert_contains "IPv6 connectivity failure 1/3 confirmed."
set_now 1700000900
all_pass
run_watchdog
assert_restart_count 0
assert_ordinary_only_count 1
assert_contains "No WAN restart was required."
echo "  done (pass=$PASS fail=$FAIL)"

echo "=== Test L: shared budget and cooldown untouched by a restart-assisted closure ==="
reset_state
seed_healthy_layer12
set_now 1700000000
escalate_to_restart
before_count=$(cat "$SHARED_DIR/disruption_count" 2>/dev/null)
before_ts=$(cat "$SHARED_DIR/last_full_wan_disruption" 2>/dev/null)
set_now 1700000300
all_pass
run_watchdog
assert_restart_count 1
assert_file_eq "$SHARED_DIR/disruption_count" "$before_count"
assert_file_eq "$SHARED_DIR/last_full_wan_disruption" "$before_ts"
echo "  done (pass=$PASS fail=$FAIL)"

# ================================================================
# reset_recovery_state() call site #3: try_128_bootstrap success.
#
# This site is only reachable with BOOTSTRAP_ENABLED=1. It is a positive-health
# closure (try_128_bootstrap returns 0 only past its B9 pd_internet_ok gate),
# but before v3.10.1 it called reset_recovery_state() with NO notifier, so an
# open incident was erased silently -- the same defect class as the original
# missing class-B closure, on a different path.
# ================================================================

echo "=== Test M: restart marker + bootstrap success -> exactly ONE restart-assisted closure ==="
reset_state
seed_healthy_layer12
set_now 1700000000
escalate_to_restart
assert_file_eq "$MARKER" "1"
# WAN came back but IA_PD did not; the no-prefix ladder reaches the bootstrap.
# NOW is pushed past the 1200s shared post-restart cooldown.
set_now 1700002000
stage_bootstrap_tick
run_watchdog_boot
assert_contains "Bootstrap succeeded"
assert_restart_count 1
assert_contains "IPv6 connectivity recovered after full WAN restart #1 of 3."
assert_ordinary_only_count 0
# Marker cleared only AFTER the closure was emitted.
assert_file_not_exists "$MARKER"
echo "  done (pass=$PASS fail=$FAIL)"

echo "=== Test N: FAILS>0, no restart marker, bootstrap success -> exactly ONE ordinary closure ==="
reset_state
seed_healthy_layer12
set_now 1700000000
# A confirmed connectivity incident that never escalated, then the prefix drops.
echo "2" > "$STATE_DIR/fail_count"
echo "1699999400" > "$STATE_DIR/incident_start"
assert_file_not_exists "$MARKER"
stage_bootstrap_tick
run_watchdog_boot
assert_contains "Bootstrap succeeded"
assert_ordinary_only_count 1
assert_contains "IPv6 connectivity recovered after 2 confirmed failed watchdog cycles."
assert_restart_count 0
assert_file_eq "$STATE_DIR/fail_count" "0"
assert_file_not_exists "$STATE_DIR/incident_start"
echo "  done (pass=$PASS fail=$FAIL)"

echo "=== Test O: bootstrap success with NO open incident stays silent ==="
reset_state
seed_healthy_layer12
set_now 1700000000
echo "0" > "$STATE_DIR/fail_count"
stage_bootstrap_tick
run_watchdog_boot
assert_contains "Bootstrap succeeded"
# Nothing was open, so nothing may be closed.
assert_restart_count 0
assert_ordinary_only_count 0
echo "  done (pass=$PASS fail=$FAIL)"

echo "=== Test P: bootstrap FAILURE emits no closure and leaves incident state intact ==="
reset_state
seed_healthy_layer12
set_now 1700000000
escalate_to_restart
assert_file_eq "$MARKER" "1"
set_now 1700002000
stage_bootstrap_tick
# Staging 'try' yields no IA_PD at all -> B4 failure path.
rm -f "$CTRL_DIR/bootstrap_yields_pd"
run_watchdog_boot
assert_contains "Bootstrap failed: no IA_PD acquired"
assert_restart_count 0
assert_ordinary_only_count 0
# The incident is still open: marker must survive.
assert_file_eq "$MARKER" "1"
echo "  done (pass=$PASS fail=$FAIL)"

echo "=== Test Q: bootstrap loses PD after revert -> no closure, marker intact ==="
reset_state
seed_healthy_layer12
set_now 1700000000
escalate_to_restart
set_now 1700002000
stage_bootstrap_tick
# PD appears while 'try' is staged but does not survive the revert (B7).
touch "$CTRL_DIR/lose_pd_after_revert"
run_watchdog_boot
assert_restart_count 0
assert_ordinary_only_count 0
assert_file_eq "$MARKER" "1"
echo "  done (pass=$PASS fail=$FAIL)"

echo "=== Test R: state-ownership invariant -- reset never erases an open incident silently ==="
# For every reachable open-incident state, a successful bootstrap must emit
# exactly one closure before reset_recovery_state() clears it.
inv_fail=0
for scenario in restart_open ordinary_open both_open; do
    reset_state
    seed_healthy_layer12
    set_now 1700000000
    case "$scenario" in
        restart_open)
            escalate_to_restart
            set_now 1700002000
            ;;
        ordinary_open)
            echo "1" > "$STATE_DIR/fail_count"
            ;;
        both_open)
            escalate_to_restart
            set_now 1700002000
            # Further confirmed failures after the restart, still unclosed.
            echo "2" > "$STATE_DIR/fail_count"
            ;;
    esac
    stage_bootstrap_tick
    run_watchdog_boot
    total=$(( $(count_of "$ORDINARY_PREFIX") ))
    if [ "$total" != "1" ]; then
        inv_fail=1
        echo "  FAIL: scenario '$scenario' emitted $total closures, expected exactly 1"
        sed 's/^/    /' "$LOG_FILE" 2>/dev/null >&2
    fi
    # And the state must actually be cleared afterwards.
    if [ -f "$MARKER" ] || [ "$(cat "$STATE_DIR/fail_count" 2>/dev/null)" != "0" ]; then
        inv_fail=1
        echo "  FAIL: scenario '$scenario' left incident state uncleared after closure"
    fi
done
if [ "$inv_fail" = "0" ]; then PASS=$((PASS + 1))
else FAIL=$((FAIL + 1)); fi
echo "  done (pass=$PASS fail=$FAIL)"

echo "=== Test S: restart-assisted outranks ordinary when both are open ==="
reset_state
seed_healthy_layer12
set_now 1700000000
escalate_to_restart
set_now 1700002000
echo "2" > "$STATE_DIR/fail_count"
stage_bootstrap_tick
run_watchdog_boot
assert_restart_count 1
assert_ordinary_only_count 0
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
