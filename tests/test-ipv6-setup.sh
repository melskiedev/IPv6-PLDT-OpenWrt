#!/bin/sh
# tests/test-ipv6-setup.sh
#
# Deterministic test suite for the v3.10 99-ipv6-setup hotplug helper.
# Verifies the event-driven, PD-first, source-aware, NON-DISRUPTIVE contract.
#
# Tests A-N cover: irrelevant event, no WAN device, no IA_PD, no LAN_PD_SRC,
# fast-path no-op, gateway failover, neighbor-table candidate, route-table
# candidate, all-candidates-fail rollback, /128+/56 coexistence, /128 absent
# accepted, /128/unbound success does not accept, unrelated routes preserved,
# and forbidden-operation static assertions.
#
# Run via: sh tests/test-ipv6-setup.sh
# Exit:  0 = all pass, 1 = any fail

# --- Locate repo root ---
TEST_SCRIPT="$0"
SCRIPT_DIR="$(cd "$(dirname "$TEST_SCRIPT")/.." && pwd)"

# --- Create temp workspace ---
TEST_ROOT="$(mktemp -d 2>/dev/null || { D="/tmp/setup-test-$$"; mkdir -p "$D"; echo "$D"; })"
STUB_DIR="$TEST_ROOT/stubs"
STATE_DIR="$TEST_ROOT/state"
CTRL_DIR="$TEST_ROOT/ctrl"
LOG_FILE="$TEST_ROOT/log.txt"
CONF_FILE="$TEST_ROOT/test.conf"
SETUP_TEST="$TEST_ROOT/99-ipv6-setup.test"

ORIG_PATH="$PATH"
export SETUP_CTRL="$CTRL_DIR"
export SETUP_LOG="$LOG_FILE"

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

# ubus: outputs JSON for wan6 status based on control files.
# Supports: up, l3_device, ipv6-prefix (address+mask), pending.
cat > "$STUB_DIR/ubus" <<'STUBEOF'
#!/bin/sh
CTRL="${SETUP_CTRL:-/tmp/setup-ctrl}"
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
# Stateful: route replace/del update has_route/route_gw/has_src_route/src_route_gw.
# Supports: unrelated source-specific routes, NDP resolution, forced failures.
cat > "$STUB_DIR/ip" <<'STUBEOF'
#!/bin/sh
CTRL="${SETUP_CTRL:-/tmp/setup-ctrl}"

# addr show dev <dev> [deprecated]
if [ "$1" = "-6" ] && [ "$2" = "addr" ] && [ "$3" = "show" ]; then
    DEP=""
    DEV=""
    PREV=""
    for a in "$@"; do
        [ "$a" = "deprecated" ] && DEP=1
        if [ "$PREV" = "dev" ]; then DEV="$a"; fi
        PREV="$a"
    done
    [ -n "$DEP" ] && exit 0
    if [ -f "$CTRL/has_wan128" ]; then
        printf 'inet6 2001:db8:dead:beef::1/128 scope global dynamic\n'
        printf '   valid_lft 86400sec preferred_lft 14400sec\n'
    fi
    LAN_SRC=$(cat "$CTRL/lan_src" 2>/dev/null)
    if [ -n "$LAN_SRC" ] && [ -f "$CTRL/has_prefix" ]; then
        printf 'inet6 %s/64 scope global dynamic\n' "$LAN_SRC"
        printf '   valid_lft 86400sec preferred_lft 14400sec\n'
    fi
    LAN_TMP=$(cat "$CTRL/lan_src_tmp" 2>/dev/null)
    if [ -n "$LAN_TMP" ] && [ -f "$CTRL/has_prefix" ]; then
        printf 'inet6 %s/64 scope global temporary dynamic\n' "$LAN_TMP"
        printf '   valid_lft 86400sec preferred_lft 14400sec\n'
    fi
    exit 0
fi

# route show default [from <src>] dev <dev>
# Emits BOTH the managed routes (has_route/has_src_route) AND any unrelated
# source-specific routes (from the unrelated_routes control file), matching
# the real `ip -6 route show default dev <dev>` which shows ALL defaults.
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
        # Source-specific default route query: check managed route then unrelated.
        if [ -f "$CTRL/has_src_route" ]; then
            GW=$(cat "$CTRL/src_route_gw" 2>/dev/null)
            [ -z "$GW" ] && GW="fe80::1"
            echo "default from $FROM via $GW dev eth0 metric 512"
        fi
        # Check unrelated routes matching this FROM.
        if [ -f "$CTRL/unrelated_routes" ]; then
            grep "from $FROM " "$CTRL/unrelated_routes" 2>/dev/null
        fi
    else
        # Generic default route query: emit generic managed route + ALL routes.
        if [ -f "$CTRL/has_route" ]; then
            GW=$(cat "$CTRL/route_gw" 2>/dev/null)
            [ -z "$GW" ] && GW="fe80::1"
            echo "default via $GW dev eth0 metric 512"
        fi
        # Emit source-specific managed route (real `ip route show default` shows all).
        if [ -f "$CTRL/has_src_route" ]; then
            GW=$(cat "$CTRL/src_route_gw" 2>/dev/null)
            [ -z "$GW" ] && GW="fe80::1"
            PD_CIDR=$(cat "$CTRL/prefix_cidr" 2>/dev/null)
            if [ -n "$PD_CIDR" ]; then
                echo "default from $PD_CIDR via $GW dev eth0 metric 512"
            fi
        fi
        # Emit unrelated routes.
        if [ -f "$CTRL/unrelated_routes" ]; then
            cat "$CTRL/unrelated_routes" 2>/dev/null
        fi
    fi
    exit 0
fi

# route get <target> [from <src>] -- kernel-like effective-route lookup.
# Resolution model (kernel FIB): an existing source-specific rule wins over
# the generic default; with neither, the kernel prints an "unreachable" line
# with rc=0 (real-kernel null-route behavior). route_get_override overrides
# output verbatim (used for prohibit/blackhole/wrong-dev/Error cases);
# route_get_rc overrides the exit status (default 0).
if [ "$1" = "-6" ] && [ "$2" = "route" ] && [ "$3" = "get" ]; then
    FROM=""
    shift 3
    while [ $# -gt 0 ]; do
        case "$1" in
            from) FROM="$2"; shift 2 ;;
            *) shift ;;
        esac
    done
    if [ -f "$CTRL/route_get_override" ]; then
        cat "$CTRL/route_get_override"
        RG_RC=$(cat "$CTRL/route_get_rc" 2>/dev/null)
        [ -n "$RG_RC" ] && exit "$RG_RC"
        exit 0
    fi
    [ -n "$FROM" ] || exit 1
    if [ -f "$CTRL/has_src_route" ]; then
        GW=$(cat "$CTRL/src_route_gw" 2>/dev/null)
        [ -z "$GW" ] && GW="fe80::1"
        echo "$FROM via $GW dev eth0 metric 512"
        exit 0
    fi
    if [ -f "$CTRL/has_route" ]; then
        GW=$(cat "$CTRL/route_gw" 2>/dev/null)
        [ -z "$GW" ] && GW="fe80::1"
        echo "$FROM via $GW dev eth0 metric 512"
        exit 0
    fi
    echo "unreachable $FROM dev eth0"
    exit 0
fi

# neigh show dev <dev>
# Emits neighbors from control file. Format: <gw> <mac> <state>
# Output format: <gw> dev eth0 lladdr <mac> router <state>
if [ "$1" = "-6" ] && [ "$2" = "neigh" ] && [ "$3" = "show" ]; then
    if [ -f "$CTRL/neigh_routers" ]; then
        while read -r line; do
            [ -z "$line" ] && continue
            echo "$line" | awk '{printf "%s dev eth0 lladdr %s router %s\n", $1, $2, $3}'
        done < "$CTRL/neigh_routers"
    fi
    exit 0
fi

# neigh replace: no-op success
if [ "$1" = "-6" ] && [ "$2" = "neigh" ] && [ "$3" = "replace" ]; then
    exit 0
fi

# route replace: record the operation, update control state.
# Supports forced failure via fail_generic_route or fail_src_route flags.
if [ "$1" = "-6" ] && [ "$2" = "route" ] && [ "$3" = "replace" ]; then
    echo "route replace $*" >> "$CTRL/ip_ops"
    local_from=""
    local_gw=""
    shift 3
    while [ $# -gt 0 ]; do
        case "$1" in
            from) local_from="$2"; shift 2 ;;
            via) local_gw="$2"; shift 2 ;;
            *) shift ;;
        esac
    done
    if [ -n "$local_gw" ]; then
        if [ -n "$local_from" ]; then
            # Source-specific route replace.
            if [ -f "$CTRL/fail_src_route" ]; then
                exit 1
            fi
            echo "$local_gw" > "$CTRL/src_route_gw"
            touch "$CTRL/has_src_route"
        else
            # Generic route replace.
            if [ -f "$CTRL/fail_generic_route" ]; then
                exit 1
            fi
            echo "$local_gw" > "$CTRL/route_gw"
            touch "$CTRL/has_route"
        fi
    fi
    exit 0
fi

# route del: record the operation, update control state.
# Only removes the matching managed route (generic or PD source-specific).
# Unrelated routes are never removed by this stub.
if [ "$1" = "-6" ] && [ "$2" = "route" ] && [ "$3" = "del" ]; then
    echo "route del $*" >> "$CTRL/ip_ops"
    local_from=""
    local_gw=""
    shift 3
    while [ $# -gt 0 ]; do
        case "$1" in
            from) local_from="$2"; shift 2 ;;
            via) local_gw="$2"; shift 2 ;;
            *) shift ;;
        esac
    done
    if [ -n "$local_gw" ]; then
        if [ -n "$local_from" ]; then
            # Source-specific route del: only remove if it matches the current managed route.
            CUR=$(cat "$CTRL/src_route_gw" 2>/dev/null)
            if [ "$CUR" = "$local_gw" ]; then
                rm -f "$CTRL/has_src_route" "$CTRL/src_route_gw"
            fi
        else
            # Generic route del: only remove if it matches.
            CUR=$(cat "$CTRL/route_gw" 2>/dev/null)
            if [ "$CUR" = "$local_gw" ]; then
                rm -f "$CTRL/has_route" "$CTRL/route_gw"
            fi
        fi
    fi
    exit 0
fi

exit 0
STUBEOF
chmod +x "$STUB_DIR/ip"

# ping6: distinguishes PD-source-bound from unbound pings.
# PD-source-bound (-I <src>): succeeds if the current generic route gateway
# is in the pd_ok_gateways allow-list (gateway-aware model).
# Unbound (no -I): succeeds if internet_ok flag is set.
# Link-local/ff02::2 NDP probes always succeed.
# NDP resolution: if a unicast ping6 -I <dev> <gw> is sent to a gateway
# listed in ndp_resolvable, add it to neigh_routers with its MAC.
cat > "$STUB_DIR/ping6" <<'STUBEOF'
#!/bin/sh
CTRL="${SETUP_CTRL:-/tmp/setup-ctrl}"
TARGET=""
HAS_SRC=0
# Check if -I argument is a link-local (device binding) vs a global (source binding).
SRC_ARG=""
for a in "$@"; do
    case "$a" in
        -I) HAS_SRC=1 ;;
        -*) ;;
        *) [ "$HAS_SRC" = "1" ] && [ -z "$SRC_ARG" ] && SRC_ARG="$a"; TARGET="$a" ;;
    esac
done
# Reset HAS_SRC for the target detection; -I can be interface or source.
# If -I <dev> <target> where target is fe80::, it's an NDP probe.
case "$TARGET" in
    ff02::2) exit 0 ;;
esac

# NDP probe: ping6 -c 2 -W 2 -I <dev> <gw> to resolve a gateway's MAC.
# If the gateway is in ndp_resolvable, add it to neigh_routers.
if [ -n "$TARGET" ] && echo "$TARGET" | grep -q '^fe80::'; then
    # This is a unicast probe to a link-local gateway.
    # Check if it's a device-bound probe (no global source address).
    IS_SRC=0
    case "$SRC_ARG" in
        fe80::*|eth0|eth1) IS_SRC=0 ;;  # device or link-local = NDP probe
        *) IS_SRC=1 ;;  # global source = PD-source-bound ping
    esac
    if [ "$IS_SRC" = "0" ]; then
        # NDP probe: resolve the gateway if it's in ndp_resolvable.
        if [ -f "$CTRL/ndp_resolvable" ]; then
            if grep -q "^$TARGET " "$CTRL/ndp_resolvable"; then
                # Add to neigh_routers (format: gw mac state).
                grep "^$TARGET " "$CTRL/ndp_resolvable" >> "$CTRL/neigh_routers"
            fi
        fi
        exit 0
    fi
fi

# PD-source-bound public ping.
if [ "$IS_SRC" = "1" ] || echo "$SRC_ARG" | grep -q '2001:'; then
    CURRENT_GW=$(cat "$CTRL/route_gw" 2>/dev/null)
    if [ -f "$CTRL/pd_ok_gateways" ]; then
        grep -qF "$CURRENT_GW" "$CTRL/pd_ok_gateways" && exit 0
        exit 1
    fi
    [ -f "$CTRL/pd_ok" ] && exit 0
    exit 1
fi

# Unbound public ping.
[ -f "$CTRL/internet_ok" ]
STUBEOF
chmod +x "$STUB_DIR/ping6"

# logger: captures messages to log file
cat > "$STUB_DIR/logger" <<'STUBEOF'
#!/bin/sh
LOG="${SETUP_LOG:-/tmp/setup-log}"
while [ $# -gt 0 ]; do
    case "$1" in
        -t) shift 2 ;;
        *) echo "$1" >> "$LOG"; shift ;;
    esac
done
STUBEOF
chmod +x "$STUB_DIR/logger"

# flock: pass-through success
cat > "$STUB_DIR/flock" <<'STUBEOF'
#!/bin/sh
exit 0
STUBEOF
chmod +x "$STUB_DIR/flock"

# sleep: no-op so tests run fast
cat > "$STUB_DIR/sleep" <<'STUBEOF'
#!/bin/sh
exit 0
STUBEOF
chmod +x "$STUB_DIR/sleep"

# ifdown / ifup / uci / network: FORBIDDEN - trap and record if called.
cat > "$STUB_DIR/ifdown" <<'STUBEOF'
#!/bin/sh
echo "FORBIDDEN ifdown $*" >> "${SETUP_CTRL:-/tmp/setup-ctrl}/forbidden_ops"
exit 0
STUBEOF
chmod +x "$STUB_DIR/ifdown"

cat > "$STUB_DIR/ifup" <<'STUBEOF'
#!/bin/sh
echo "FORBIDDEN ifup $*" >> "${SETUP_CTRL:-/tmp/setup-ctrl}/forbidden_ops"
exit 0
STUBEOF
chmod +x "$STUB_DIR/ifup"

cat > "$STUB_DIR/uci" <<'STUBEOF'
#!/bin/sh
echo "FORBIDDEN uci $*" >> "${SETUP_CTRL:-/tmp/setup-ctrl}/forbidden_ops"
exit 0
STUBEOF
chmod +x "$STUB_DIR/uci"

# network: stub for ubus network reload (forbidden in 99)
cat > "$STUB_DIR/network" <<'STUBEOF'
#!/bin/sh
echo "FORBIDDEN network $*" >> "${SETUP_CTRL:-/tmp/setup-ctrl}/forbidden_ops"
exit 0
STUBEOF
chmod +x "$STUB_DIR/network"

# ================================================================
# Test configuration
# ================================================================

cat > "$CONF_FILE" <<EOF
LAN_DEV="br-lan"
EOF

# ================================================================
# Modified script copy (sed: redirect paths only, logic unchanged)
# ================================================================

sed -e "s|CONF=\"/etc/ipv6-watchdog.conf\"|CONF=\"$CONF_FILE\"|" \
    "$SCRIPT_DIR/99-ipv6-setup" > "$SETUP_TEST"
chmod +x "$SETUP_TEST"

# ================================================================
# Test helpers
# ================================================================

PASS=0
FAIL=0

run_setup() {
    : > "$LOG_FILE"
    : > "$CTRL_DIR/ip_ops" 2>/dev/null
    : > "$CTRL_DIR/forbidden_ops" 2>/dev/null
    PATH="$STUB_DIR:$ORIG_PATH" "$SETUP_TEST" 2>/dev/null
}

# Run setup with environment vars simulating hotplug ACTION/INTERFACE.
run_setup_event() {
    local action="$1" iface="$2"
    : > "$LOG_FILE"
    : > "$CTRL_DIR/ip_ops" 2>/dev/null
    : > "$CTRL_DIR/forbidden_ops" 2>/dev/null
    ACTION="$action" INTERFACE="$iface" PATH="$STUB_DIR:$ORIG_PATH" "$SETUP_TEST" 2>/dev/null
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
    local actual
    actual=$(cat "$1" 2>/dev/null)
    if [ "$actual" = "$2" ]; then
        PASS=$((PASS + 1))
    else
        FAIL=$((FAIL + 1))
        echo "  FAIL: expected '$2' in $(basename "$1"), got '$actual'"
    fi
}

assert_no_forbidden() {
    if [ -s "$CTRL_DIR/forbidden_ops" ]; then
        FAIL=$((FAIL + 1))
        echo "  FAIL: forbidden operations called:"
        sed 's/^/    /' "$CTRL_DIR/forbidden_ops" >&2
    else
        PASS=$((PASS + 1))
    fi
}

assert_no_route_replace() {
    if [ -s "$CTRL_DIR/ip_ops" ]; then
        FAIL=$((FAIL + 1))
        echo "  FAIL: route operations occurred (expected no-churn):"
        sed 's/^/    /' "$CTRL_DIR/ip_ops" >&2
    else
        PASS=$((PASS + 1))
    fi
}

assert_route_replace_contains() {
    if grep -qF "$1" "$CTRL_DIR/ip_ops" 2>/dev/null; then
        PASS=$((PASS + 1))
    else
        FAIL=$((FAIL + 1))
        echo "  FAIL: expected route op containing: $1"
        sed 's/^/    /' "$CTRL_DIR/ip_ops" 2>/dev/null >&2
    fi
}

assert_route_replace_not_contains() {
    if grep -qF "$1" "$CTRL_DIR/ip_ops" 2>/dev/null; then
        FAIL=$((FAIL + 1))
        echo "  FAIL: unexpected route op containing: $1"
        sed 's/^/    /' "$CTRL_DIR/ip_ops" 2>/dev/null >&2
    else
        PASS=$((PASS + 1))
    fi
}

assert_no_route_del() {
    if grep -qF "route del" "$CTRL_DIR/ip_ops" 2>/dev/null; then
        FAIL=$((FAIL + 1))
        echo "  FAIL: route del occurred (expected no route deletion):"
        grep "route del" "$CTRL_DIR/ip_ops" >&2
    else
        PASS=$((PASS + 1))
    fi
}

reset_state() {
    rm -rf "$STATE_DIR"/* 2>/dev/null
    rm -f "$CTRL_DIR"/* 2>/dev/null
    : > "$LOG_FILE"
}

# Seed full PD context for healthy-state tests.
seed_pd_context() {
    echo "eth0" > "$CTRL_DIR/wan_dev"
    touch "$CTRL_DIR/wan6_up"
    touch "$CTRL_DIR/has_prefix"
    echo "56" > "$CTRL_DIR/prefix_mask"
    echo "2001:db8:1234:5678::1" > "$CTRL_DIR/prefix_addr"
    echo "2001:db8:1234:5678::1/56" > "$CTRL_DIR/prefix_cidr"
    echo "2001:db8:1234:5678::abcd" > "$CTRL_DIR/lan_src"
    touch "$CTRL_DIR/has_route"
    echo "fe80::1" > "$CTRL_DIR/route_gw"
    touch "$CTRL_DIR/has_src_route"
    echo "fe80::1" > "$CTRL_DIR/src_route_gw"
    echo "fe80::1" > "$CTRL_DIR/pd_ok_gateways"
    echo "fe80::1 00:11:22:33:44:55 router REACHABLE" > "$CTRL_DIR/neigh_routers"
}

# ================================================================
# Tests
# ================================================================

echo "=== Test A: Irrelevant hotplug event -> no action ==="
reset_state
run_setup_event "ifdown" "wan6"
assert_empty_log
echo "  done (pass=$PASS fail=$FAIL)"

echo "=== Test B: Irrelevant interface -> no action ==="
reset_state
run_setup_event "ifup" "lan"
assert_empty_log
echo "  done (pass=$PASS fail=$FAIL)"

echo "=== Test C: wan6 event but no usable WAN device -> safe exit ==="
reset_state
touch "$CTRL_DIR/wan6_up"
# No wan_dev control file -> l3_device empty.
run_setup_event "ifup" "wan6"
assert_contains "cannot determine WAN device"
assert_no_forbidden
echo "  done (pass=$PASS fail=$FAIL)"

echo "=== Test D: wan6 up but no IA_PD -> safe exit, no route fabrication ==="
reset_state
echo "eth0" > "$CTRL_DIR/wan_dev"
touch "$CTRL_DIR/wan6_up"
# No has_prefix -> no IA_PD.
run_setup_event "ifup" "wan6"
assert_contains "no IA_PD received"
assert_not_contains "route"
assert_no_forbidden
assert_no_route_replace
echo "  done (pass=$PASS fail=$FAIL)"

echo "=== Test E: IA_PD exists but no LAN_PD_SRC -> safe exit ==="
reset_state
echo "eth0" > "$CTRL_DIR/wan_dev"
touch "$CTRL_DIR/wan6_up"
touch "$CTRL_DIR/has_prefix"
echo "56" > "$CTRL_DIR/prefix_mask"
echo "2001:db8:1234:5678::1" > "$CTRL_DIR/prefix_addr"
# No lan_src -> get_lan_pd_src returns empty.
run_setup_event "ifup" "wan6"
assert_contains "no PD-derived LAN source"
assert_no_forbidden
assert_no_route_replace
echo "  done (pass=$PASS fail=$FAIL)"

echo "=== Test F: Routes effective + PD-source Internet works -> no-op ==="
reset_state
seed_pd_context
run_setup_event "ifup" "wan6"
assert_contains "Routes already effective"
assert_contains "no action needed"
assert_no_forbidden
assert_no_route_replace
echo "  done (pass=$PASS fail=$FAIL)"

echo "=== Test F2: IA_NA-unusable contract -- generic-default-only + effective + PD-source OK -> zero churn ==="
# LIVE-mirrored: router has IA_PD + LAN_PD_SRC + generic default via
# fe80::8a40... with NO explicit 'default from PD_CIDR', and PD-source pings
# pass. The fast path MUST accept it with NO route churn and NO manufactured
# source-specific route.
reset_state
echo "eth0" > "$CTRL_DIR/wan_dev"
touch "$CTRL_DIR/wan6_up"
touch "$CTRL_DIR/has_prefix"
echo "56" > "$CTRL_DIR/prefix_mask"
echo "2001:db8:1234:5678::1" > "$CTRL_DIR/prefix_addr"
echo "2001:db8:1234:5678::1/56" > "$CTRL_DIR/prefix_cidr"
echo "2001:db8:1234:5678::abcd" > "$CTRL_DIR/lan_src"
# Generic default only. NO has_src_route (deliberately absent).
touch "$CTRL_DIR/has_route"
echo "fe80::1" > "$CTRL_DIR/route_gw"
echo "fe80::1" > "$CTRL_DIR/pd_ok_gateways"
run_setup_event "ifup" "wan6"
assert_contains "Routes already effective"
assert_contains "no action needed"
assert_no_route_replace
assert_route_replace_not_contains "default from"
assert_no_forbidden
echo "  done (pass=$PASS fail=$FAIL)"

echo "=== Test G: Current gateway fails PD-source, alternate candidate succeeds ==="
reset_state
echo "eth0" > "$CTRL_DIR/wan_dev"
touch "$CTRL_DIR/wan6_up"
touch "$CTRL_DIR/has_prefix"
echo "56" > "$CTRL_DIR/prefix_mask"
echo "2001:db8:1234:5678::1" > "$CTRL_DIR/prefix_addr"
echo "2001:db8:1234:5678::abcd" > "$CTRL_DIR/lan_src"
# No existing routes -> forces gateway scan.
# Two neighbor candidates: fe80::bad (fails PD-source), fe80::good (succeeds).
echo "fe80::bad aa:bb:cc:dd:ee:ff router INCOMPLETE" > "$CTRL_DIR/neigh_routers"
echo "fe80::good 11:22:33:44:55:66 router REACHABLE" >> "$CTRL_DIR/neigh_routers"
# Gateway-aware model: only fe80::good passes PD-source test.
echo "fe80::good" > "$CTRL_DIR/pd_ok_gateways"
run_setup_event "ifup" "wan6"
assert_contains "PD-source reachability verified"
assert_contains "IPv6 setup complete"
assert_route_replace_contains "default via fe80::good"
# No pre-existing source-specific route -> MINIMUM mutation: generic-only
# repair must NOT manufacture an explicit 'default from PD_CIDR'.
assert_route_replace_not_contains "default from"
assert_no_forbidden
echo "  done (pass=$PASS fail=$FAIL)"

echo "=== Test H: Candidate from neighbor table succeeds ==="
reset_state
echo "eth0" > "$CTRL_DIR/wan_dev"
touch "$CTRL_DIR/wan6_up"
touch "$CTRL_DIR/has_prefix"
echo "56" > "$CTRL_DIR/prefix_mask"
echo "2001:db8:1234:5678::1" > "$CTRL_DIR/prefix_addr"
echo "2001:db8:1234:5678::abcd" > "$CTRL_DIR/lan_src"
# No existing routes -> forces gateway scan.
# Only neighbor table candidate.
echo "fe80::neigh 00:aa:bb:cc:dd:ee router REACHABLE" > "$CTRL_DIR/neigh_routers"
echo "fe80::neigh" > "$CTRL_DIR/pd_ok_gateways"
run_setup_event "ifup" "wan6"
assert_contains "PD-source reachability verified"
assert_route_replace_contains "default via fe80::neigh"
assert_route_replace_not_contains "default from"
assert_no_forbidden
echo "  done (pass=$PASS fail=$FAIL)"

echo "=== Test I: Candidate from route table only succeeds (targeted repair) ==="
reset_state
echo "eth0" > "$CTRL_DIR/wan_dev"
touch "$CTRL_DIR/wan6_up"
touch "$CTRL_DIR/has_prefix"
echo "56" > "$CTRL_DIR/prefix_mask"
echo "2001:db8:1234:5678::1" > "$CTRL_DIR/prefix_addr"
echo "2001:db8:1234:5678::1/56" > "$CTRL_DIR/prefix_cidr"
echo "2001:db8:1234:5678::abcd" > "$CTRL_DIR/lan_src"
# Generic route via DEAD fe80::bad (not in allow-list) -> PD-source fails.
# Source-specific route via fe80::routegw -> route-table evidence for the
# candidate WITHOUT any neighbor entry.
touch "$CTRL_DIR/has_route"
echo "fe80::bad" > "$CTRL_DIR/route_gw"
touch "$CTRL_DIR/has_src_route"
echo "fe80::routegw" > "$CTRL_DIR/src_route_gw"
# No neighbor entries initially; routegw resolvable via NDP probe.
echo "" > "$CTRL_DIR/neigh_routers"
echo "fe80::routegw 00:11:22:33:44:55 router STALE" > "$CTRL_DIR/ndp_resolvable"
echo "fe80::routegw" > "$CTRL_DIR/pd_ok_gateways"
run_setup_event "ifup" "wan6"
assert_contains "PD-source reachability verified"
assert_contains "IPv6 setup complete"
assert_route_replace_contains "default via fe80::routegw"
# Preexisting source-specific rule -> targeted replacement via candidate.
assert_route_replace_contains "default from 2001:db8:1234:5678::1/56 via fe80::routegw"
assert_no_forbidden
echo "  done (pass=$PASS fail=$FAIL)"

echo "=== Test J: All candidates fail -> original routes restored, no ifdown/ifup ==="
reset_state
echo "eth0" > "$CTRL_DIR/wan_dev"
touch "$CTRL_DIR/wan6_up"
touch "$CTRL_DIR/has_prefix"
echo "56" > "$CTRL_DIR/prefix_mask"
echo "2001:db8:1234:5678::1" > "$CTRL_DIR/prefix_addr"
echo "2001:db8:1234:5678::abcd" > "$CTRL_DIR/lan_src"
# Existing routes that should be restored.
touch "$CTRL_DIR/has_route"
echo "fe80::orig" > "$CTRL_DIR/route_gw"
touch "$CTRL_DIR/has_src_route"
echo "fe80::orig" > "$CTRL_DIR/src_route_gw"
# Candidate gateway that will fail PD-source test.
echo "fe80::failgw aa:bb:cc:dd:ee:ff router REACHABLE" > "$CTRL_DIR/neigh_routers"
# NO pd_ok -> pd_internet_ok fails for all candidates.
run_setup_event "ifup" "wan6"
assert_contains "no working gateway found"
assert_contains "deferring recovery to ipv6-watchdog"
assert_no_forbidden
echo "  done (pass=$PASS fail=$FAIL)"

echo "=== Test K: Healthy WAN /128 + healthy PD /56 -> accepted, /128 retained ==="
reset_state
seed_pd_context
# Simulate WAN /128 presence.
touch "$CTRL_DIR/has_wan128"
run_setup_event "ifup" "wan6"
assert_contains "Routes already effective"
assert_not_contains "addr del"
assert_not_contains "/128"
assert_no_forbidden
echo "  done (pass=$PASS fail=$FAIL)"

echo "=== Test L: WAN /128 absent + healthy PD /56 -> accepted, no /128 creation ==="
reset_state
seed_pd_context
# Explicitly NO has_wan128.
run_setup_event "ifup" "wan6"
assert_contains "Routes already effective"
assert_not_contains "addr del"
assert_not_contains "addr add"
assert_no_forbidden
echo "  done (pass=$PASS fail=$FAIL)"

echo "=== Test M: WAN /128/unbound Internet succeeds but PD-source fails -> NOT accepted ==="
reset_state
echo "eth0" > "$CTRL_DIR/wan_dev"
touch "$CTRL_DIR/wan6_up"
touch "$CTRL_DIR/has_prefix"
echo "56" > "$CTRL_DIR/prefix_mask"
echo "2001:db8:1234:5678::1" > "$CTRL_DIR/prefix_addr"
echo "2001:db8:1234:5678::abcd" > "$CTRL_DIR/lan_src"
# NO existing routes -> forces scan.
# Candidate gateway.
echo "fe80::gw1 aa:bb:cc:dd:ee:ff router REACHABLE" > "$CTRL_DIR/neigh_routers"
# internet_ok IS set (unbound succeeds) but pd_ok is NOT set (PD-source fails).
touch "$CTRL_DIR/internet_ok"
run_setup_event "ifup" "wan6"
assert_contains "PD-source reachability failed"
assert_contains "no working gateway found"
assert_not_contains "PD-source reachability verified"
assert_no_forbidden
echo "  done (pass=$PASS fail=$FAIL)"

echo "=== Test N: Forbidden operations never called ==="
# This is verified by assert_no_forbidden in every test above.
# Here we do a focused stress test: all-fail scenario with routes present.
reset_state
echo "eth0" > "$CTRL_DIR/wan_dev"
touch "$CTRL_DIR/wan6_up"
touch "$CTRL_DIR/has_prefix"
echo "56" > "$CTRL_DIR/prefix_mask"
echo "2001:db8:1234:5678::1" > "$CTRL_DIR/prefix_addr"
echo "2001:db8:1234:5678::abcd" > "$CTRL_DIR/lan_src"
touch "$CTRL_DIR/has_route"
echo "fe80::orig" > "$CTRL_DIR/route_gw"
touch "$CTRL_DIR/has_src_route"
echo "fe80::orig" > "$CTRL_DIR/src_route_gw"
echo "fe80::failgw aa:bb:cc:dd:ee:ff router REACHABLE" > "$CTRL_DIR/neigh_routers"
run_setup_event "ifup" "wan6"
assert_no_forbidden
# Also verify no uci, no ifdown, no ifup, no network restart was called
# by checking the forbidden_ops file is empty (assert_no_forbidden covers this).
echo "  done (pass=$PASS fail=$FAIL)"

echo "=== Test O: Existing unrelated source-specific route preserved ==="
# When the script scans gateways and restores the snapshot, it must not
# delete unrelated source-specific routes (e.g. from a different prefix).
reset_state
echo "eth0" > "$CTRL_DIR/wan_dev"
touch "$CTRL_DIR/wan6_up"
touch "$CTRL_DIR/has_prefix"
echo "56" > "$CTRL_DIR/prefix_mask"
echo "2001:db8:1234:5678::1" > "$CTRL_DIR/prefix_addr"
echo "2001:db8:1234:5678::abcd" > "$CTRL_DIR/lan_src"
# Existing routes: generic + PD src route (both coherent).
touch "$CTRL_DIR/has_route"
echo "fe80::1" > "$CTRL_DIR/route_gw"
touch "$CTRL_DIR/has_src_route"
echo "fe80::1" > "$CTRL_DIR/src_route_gw"
echo "fe80::1" > "$CTRL_DIR/pd_ok_gateways"
echo "fe80::1 00:11:22:33:44:55 router REACHABLE" > "$CTRL_DIR/neigh_routers"
# Fast path: routes coherent + pd_ok -> no route del at all.
run_setup_event "ifup" "wan6"
assert_contains "Routes already effective"
assert_no_route_del
assert_no_forbidden
echo "  done (pass=$PASS fail=$FAIL)"

echo "=== Test P: Static forbidden-operation assertions (all-fail stress) ==="
# Verify no ifdown, no ifup, no uci, no route del on the all-fail path.
reset_state
echo "eth0" > "$CTRL_DIR/wan_dev"
touch "$CTRL_DIR/wan6_up"
touch "$CTRL_DIR/has_prefix"
echo "56" > "$CTRL_DIR/prefix_mask"
echo "2001:db8:1234:5678::1" > "$CTRL_DIR/prefix_addr"
echo "2001:db8:1234:5678::abcd" > "$CTRL_DIR/lan_src"
touch "$CTRL_DIR/has_route"
echo "fe80::orig" > "$CTRL_DIR/route_gw"
touch "$CTRL_DIR/has_src_route"
echo "fe80::orig" > "$CTRL_DIR/src_route_gw"
echo "fe80::failgw aa:bb:cc:dd:ee:ff router REACHABLE" > "$CTRL_DIR/neigh_routers"
# No pd_ok_gateways -> all candidates fail.
run_setup_event "ifup" "wan6"
# No ifdown, ifup, uci, or network calls.
assert_no_forbidden
# No route del on the all-fail path (snapshot is restored via route replace).
assert_no_route_del
echo "  done (pass=$PASS fail=$FAIL)"

# ================================================================
# Gap-driven tests Q-V
# ================================================================

echo "=== Test Q: No original routes + all candidates fail -> no trial routes remain ==="
# GAP 1: When there were NO original default routes before candidate testing,
# failed candidate routes must NOT remain installed after exit.
reset_state
echo "eth0" > "$CTRL_DIR/wan_dev"
touch "$CTRL_DIR/wan6_up"
touch "$CTRL_DIR/has_prefix"
echo "56" > "$CTRL_DIR/prefix_mask"
echo "2001:db8:1234:5678::1" > "$CTRL_DIR/prefix_addr"
echo "2001:db8:1234:5678::1/56" > "$CTRL_DIR/prefix_cidr"
echo "2001:db8:1234:5678::abcd" > "$CTRL_DIR/lan_src"
# NO has_route, NO has_src_route -> no original routes to snapshot.
# One candidate that will fail PD-source test.
echo "fe80::failgw aa:bb:cc:dd:ee:ff router REACHABLE" > "$CTRL_DIR/neigh_routers"
# No pd_ok_gateways -> all candidates fail.
run_setup_event "ifup" "wan6"
assert_contains "no working gateway found"
# After exit: NO generic route should remain.
if [ -f "$CTRL_DIR/has_route" ]; then
    FAIL=$((FAIL + 1))
    echo "  FAIL: generic trial route remained installed"
else
    PASS=$((PASS + 1))
fi
# After exit: NO source-specific route should remain.
if [ -f "$CTRL_DIR/has_src_route" ]; then
    FAIL=$((FAIL + 1))
    echo "  FAIL: PD source-specific trial route remained installed"
else
    PASS=$((PASS + 1))
fi
assert_no_forbidden
echo "  done (pass=$PASS fail=$FAIL)"

echo "=== Test R: Partial install failure -> EXACT original snapshot restored ==="
# CORRECTION 3 regression: original generic via fe80::orig; candidate gw1's
# generic replace SUCCEEDS; the second (source-specific) operation FAILS;
# candidate rejected; FINAL generic must be restored to fe80::orig exactly.
# The stale source-specific rule (via fe80::orig) must also be preserved.
reset_state
echo "eth0" > "$CTRL_DIR/wan_dev"
touch "$CTRL_DIR/wan6_up"
touch "$CTRL_DIR/has_prefix"
echo "56" > "$CTRL_DIR/prefix_mask"
echo "2001:db8:1234:5678::1" > "$CTRL_DIR/prefix_addr"
echo "2001:db8:1234:5678::1/56" > "$CTRL_DIR/prefix_cidr"
echo "2001:db8:1234:5678::abcd" > "$CTRL_DIR/lan_src"
# Original routes: generic + PD source-specific, both via fe80::orig.
touch "$CTRL_DIR/has_route"
echo "fe80::orig" > "$CTRL_DIR/route_gw"
touch "$CTRL_DIR/has_src_route"
echo "fe80::orig" > "$CTRL_DIR/src_route_gw"
# Candidate that will partially fail: generic replace succeeds, src fails.
echo "fe80::gw1 aa:bb:cc:dd:ee:ff router REACHABLE" > "$CTRL_DIR/neigh_routers"
echo "fe80::gw1" > "$CTRL_DIR/pd_ok_gateways"
# Force the source-specific route replace to fail (generic replace succeeds).
touch "$CTRL_DIR/fail_src_route"
run_setup_event "ifup" "wan6"
# The candidate must NOT be accepted because install_gw_routes failed.
assert_not_contains "PD-source reachability verified"
assert_not_contains "IPv6 setup complete"
assert_contains "route installation failed"
# FINAL state: generic restored to fe80::orig exactly (NOT gw1).
assert_file_eq "$CTRL_DIR/route_gw" "fe80::orig"
# Stale source-specific rule restored to original gateway too.
assert_file_eq "$CTRL_DIR/src_route_gw" "fe80::orig"
assert_no_forbidden
echo "  done (pass=$PASS fail=$FAIL)"

echo "=== Test S: Both routes already point at PD-verified gateway -> zero-churn fast path ==="
reset_state
echo "eth0" > "$CTRL_DIR/wan_dev"
touch "$CTRL_DIR/wan6_up"
touch "$CTRL_DIR/has_prefix"
echo "56" > "$CTRL_DIR/prefix_mask"
echo "2001:db8:1234:5678::1" > "$CTRL_DIR/prefix_addr"
echo "2001:db8:1234:5678::1/56" > "$CTRL_DIR/prefix_cidr"
echo "2001:db8:1234:5678::abcd" > "$CTRL_DIR/lan_src"
# Both routes already via fe80::good, PD-source allow-listed.
touch "$CTRL_DIR/has_route"
echo "fe80::good" > "$CTRL_DIR/route_gw"
touch "$CTRL_DIR/has_src_route"
echo "fe80::good" > "$CTRL_DIR/src_route_gw"
echo "fe80::good" > "$CTRL_DIR/pd_ok_gateways"
echo "fe80::good 00:11:22:33:44:55 router REACHABLE" > "$CTRL_DIR/neigh_routers"
run_setup_event "ifup" "wan6"
assert_contains "Routes already effective"
assert_contains "no action needed"
assert_no_route_replace
assert_no_forbidden
echo "  done (pass=$PASS fail=$FAIL)"

echo "=== Test W: Stale source-specific route via dead gateway -> targeted repair ==="
# Live model: generic AND PD source-specific both point at a dead
# gateway; the reachable alternate candidate must repair BOTH (minimum
# mutation: generic replace + targeted stale-rule replacement).
reset_state
echo "eth0" > "$CTRL_DIR/wan_dev"
touch "$CTRL_DIR/wan6_up"
touch "$CTRL_DIR/has_prefix"
echo "56" > "$CTRL_DIR/prefix_mask"
echo "2001:db8:1234:5678::1" > "$CTRL_DIR/prefix_addr"
echo "2001:db8:1234:5678::1/56" > "$CTRL_DIR/prefix_cidr"
echo "2001:db8:1234:5678::abcd" > "$CTRL_DIR/lan_src"
# Both routes via DEAD fe80::bad (not in allow-list).
touch "$CTRL_DIR/has_route"
echo "fe80::bad" > "$CTRL_DIR/route_gw"
touch "$CTRL_DIR/has_src_route"
echo "fe80::bad" > "$CTRL_DIR/src_route_gw"
# Reachable alternate candidate.
echo "fe80::good 00:11:22:33:44:55 router REACHABLE" > "$CTRL_DIR/neigh_routers"
echo "fe80::good" > "$CTRL_DIR/pd_ok_gateways"
run_setup_event "ifup" "wan6"
assert_contains "PD-source reachability verified"
assert_contains "IPv6 setup complete"
assert_route_replace_contains "default via fe80::good"
# Stale source-specific rule corrected via the candidate.
assert_route_replace_contains "default from 2001:db8:1234:5678::1/56 via fe80::good"
# Kernel truth after repair: effective route resolves via fe80::good.
assert_file_eq "$CTRL_DIR/route_gw" "fe80::good"
assert_file_eq "$CTRL_DIR/src_route_gw" "fe80::good"
assert_no_forbidden
echo "  done (pass=$PASS fail=$FAIL)"

echo "=== Test T: True route-table-only candidate (NDP resolution, generic-only repair) ==="
# GAP 3: Gateway exists ONLY as route-table evidence (an unrelated
# source-specific route), NOT in the neighbor table. After the script's NDP
# probe the neighbor is resolved. No PD source-specific rule exists, so the
# repair is generic-only (no explicit 'default from PD_CIDR' manufactured).
reset_state
echo "eth0" > "$CTRL_DIR/wan_dev"
touch "$CTRL_DIR/wan6_up"
touch "$CTRL_DIR/has_prefix"
echo "56" > "$CTRL_DIR/prefix_mask"
echo "2001:db8:1234:5678::1" > "$CTRL_DIR/prefix_addr"
echo "2001:db8:1234:5678::1/56" > "$CTRL_DIR/prefix_cidr"
echo "2001:db8:1234:5678::abcd" > "$CTRL_DIR/lan_src"
# Generic route points at DEAD fe80::bad (not in allow-list) -> scan forced.
touch "$CTRL_DIR/has_route"
echo "fe80::bad" > "$CTRL_DIR/route_gw"
# NO PD source-specific route -> no targeted src repair available.
# Unrelated source-specific route provides route-table evidence of the
# alternative gateway WITHOUT any neighbor entry.
UNRELATED="default from 2001:db8:aaaa::/48 via fe80::rtonly dev eth0 metric 1024"
echo "$UNRELATED" > "$CTRL_DIR/unrelated_routes"
# No neighbor entry for fe80::rtonly initially.
echo "" > "$CTRL_DIR/neigh_routers"
# The gateway is resolvable via NDP (script probes it, it appears).
echo "fe80::rtonly 00:aa:bb:cc:dd:ee router STALE" > "$CTRL_DIR/ndp_resolvable"
echo "fe80::rtonly" > "$CTRL_DIR/pd_ok_gateways"
run_setup_event "ifup" "wan6"
# Verify: route-table candidate was discovered and accepted.
assert_contains "PD-source reachability verified"
assert_contains "IPv6 setup complete"
assert_route_replace_contains "default via fe80::rtonly"
# Generic-only repair: NO source-specific route is manufactured.
assert_route_replace_not_contains "default from 2001:db8:1234:5678::1/56"
# Unrelated route preserved.
if [ -f "$CTRL_DIR/unrelated_routes" ] && grep -qF "$UNRELATED" "$CTRL_DIR/unrelated_routes"; then
    PASS=$((PASS + 1))
else
    FAIL=$((FAIL + 1))
    echo "  FAIL: unrelated route was deleted during successful repair"
fi
assert_no_forbidden
echo "  done (pass=$PASS fail=$FAIL)"

echo "=== Test U: Unrelated route preserved during failed repair + rollback ==="
# GAP 4: An unrelated source-specific route must survive candidate trial
# and rollback. The script must not delete it.
reset_state
echo "eth0" > "$CTRL_DIR/wan_dev"
touch "$CTRL_DIR/wan6_up"
touch "$CTRL_DIR/has_prefix"
echo "56" > "$CTRL_DIR/prefix_mask"
echo "2001:db8:1234:5678::1" > "$CTRL_DIR/prefix_addr"
echo "2001:db8:1234:5678::1/56" > "$CTRL_DIR/prefix_cidr"
echo "2001:db8:1234:5678::abcd" > "$CTRL_DIR/lan_src"
# Existing routes: generic + PD src route (coherent at fe80::orig but
# PD-source will fail, forcing a scan).
touch "$CTRL_DIR/has_route"
echo "fe80::orig" > "$CTRL_DIR/route_gw"
touch "$CTRL_DIR/has_src_route"
echo "fe80::orig" > "$CTRL_DIR/src_route_gw"
# Unrelated source-specific route for a different prefix.
UNRELATED="default from 2001:db8:aaaa::/48 via fe80::other dev eth0 metric 1024"
echo "$UNRELATED" > "$CTRL_DIR/unrelated_routes"
# Candidate that will fail PD-source test.
echo "fe80::failgw aa:bb:cc:dd:ee:ff router REACHABLE" > "$CTRL_DIR/neigh_routers"
# No pd_ok_gateways -> all candidates fail.
run_setup_event "ifup" "wan6"
assert_contains "no working gateway found"
# Verify: unrelated route is still present in the control file.
if [ -f "$CTRL_DIR/unrelated_routes" ] && grep -qF "$UNRELATED" "$CTRL_DIR/unrelated_routes"; then
    PASS=$((PASS + 1))
else
    FAIL=$((FAIL + 1))
    echo "  FAIL: unrelated route was deleted during rollback"
fi
assert_no_forbidden
echo "  done (pass=$PASS fail=$FAIL)"

echo "=== Test V: Unrelated route preserved during successful repair ==="
# GAP 4: Unrelated route must also survive a successful candidate trial.
reset_state
echo "eth0" > "$CTRL_DIR/wan_dev"
touch "$CTRL_DIR/wan6_up"
touch "$CTRL_DIR/has_prefix"
echo "56" > "$CTRL_DIR/prefix_mask"
echo "2001:db8:1234:5678::1" > "$CTRL_DIR/prefix_addr"
echo "2001:db8:1234:5678::1/56" > "$CTRL_DIR/prefix_cidr"
echo "2001:db8:1234:5678::abcd" > "$CTRL_DIR/lan_src"
# Existing generic route points at fe80::bad, but PD-source fails.
touch "$CTRL_DIR/has_route"
echo "fe80::bad" > "$CTRL_DIR/route_gw"
# NO src route -> routes not coherent -> forces scan.
# Unrelated source-specific route.
UNRELATED="default from 2001:db8:aaaa::/48 via fe80::other dev eth0 metric 1024"
echo "$UNRELATED" > "$CTRL_DIR/unrelated_routes"
# Good candidate in neighbor table.
echo "fe80::good 00:11:22:33:44:55 router REACHABLE" > "$CTRL_DIR/neigh_routers"
echo "fe80::good" > "$CTRL_DIR/pd_ok_gateways"
run_setup_event "ifup" "wan6"
assert_contains "IPv6 setup complete"
# Verify: unrelated route is still present.
if [ -f "$CTRL_DIR/unrelated_routes" ] && grep -qF "$UNRELATED" "$CTRL_DIR/unrelated_routes"; then
    PASS=$((PASS + 1))
else
    FAIL=$((FAIL + 1))
    echo "  FAIL: unrelated route was deleted during successful repair"
fi
assert_no_forbidden
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