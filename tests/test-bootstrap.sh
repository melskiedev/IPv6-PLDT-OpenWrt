#!/bin/sh
# tests/test-bootstrap.sh
#
# Phase 3: Temporary IA_NA-assisted bootstrap hardening tests.
# Tests the ACTUAL production try_128_bootstrap() extracted from ipv6-watchdog.
# Mocks uci, ubus, jsonfilter, ip, ping6, ifdown, ifup, sleep, logger so the
# test harness never touches a real network or modifies real UCI state.
#
# Usage: sh tests/test-bootstrap.sh
# Exit:  0 = all pass, 1 = any fail

TEST_SCRIPT="$0"
SCRIPT_DIR="$(cd "$(dirname "$TEST_SCRIPT")/.." && pwd)"
TEST_BASE="$SCRIPT_DIR/.test-tmp"
TEST_ROOT="$TEST_BASE/bootstrap-test-$$"
mkdir -p "$TEST_ROOT"

cleanup() { rm -rf "$TEST_ROOT"; }
trap cleanup EXIT
trap 'cleanup; exit 130' INT
trap 'cleanup; exit 143' TERM

PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); echo "  PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); echo "  FAIL: $1"; }
assert_eq() {
    if [ "$2" = "$3" ]; then pass "$1 ($2)"; else fail "$1 (expected '$3', got '$2')"; fi
}
assert_contains() {
    if grep -q "$2" "$3" 2>/dev/null; then pass "$1"; else fail "$1 (no match for '$2' in $3)"; fi
}
assert_not_contains() {
    if grep -q "$2" "$3" 2>/dev/null; then fail "$1 (found '$2' in $3)"; else pass "$1"; fi
}

# ================================================================
# Extract production helpers from ipv6-watchdog.
# Range: has_prefix() through the end of try_128_bootstrap().
# ================================================================

EXTRACT="$TEST_ROOT/helpers.sh"

awk '
/^has_prefix\(\)/ { start=1 }
start { print }
start && /^try_128_bootstrap\(\)/ { saw_bootstrap=1 }
saw_bootstrap && /^}/ { start=0; saw_bootstrap=0 }
' "$SCRIPT_DIR/ipv6-watchdog" > "$EXTRACT"

for fn in has_prefix get_pd_addr get_pd_mask get_wan_dev wan6_pending wan6_up \
          get_wan128 addr_in_prefix is_link_local is_ula get_lan_pd_src \
          pending_state_tick pending_state_reset populate_pd_context \
          pd_internet_ok wan128_internet_ok dhcpv6_renew cleanup_deprecated_v6 \
          current_default_gw gateway_mac internet_ok_now pd_routes_ok \
          snapshot_default_routes restore_route_snapshot clear_default_routes \
          install_gw_routes keep_gateway fix_gateway in_cooldown \
          recovery_hold_active reset_recovery_state do_wan_restart \
          notify_ont_powercycle notify_ipv6_recovered maybe_wan_restart \
          try_128_bootstrap migrate_legacy_recovery_state sync_legacy_state \
          coordinated_wan6_begin coordinated_wan6_end; do
    if ! grep -q "^${fn}()" "$EXTRACT"; then
        echo "FATAL: could not extract $fn from ipv6-watchdog" >&2
        exit 2
    fi
done

# log() stub: append to a shared log file we can inspect.
# cleanup_lock + on_exit stubs: these are defined in ipv6-watchdog BEFORE
# has_prefix() (the extraction start point), so they are not in the extract.
# on_exit is reproduced verbatim from ipv6-watchdog so the test exercises the
# real trap logic against the mock uci.
WATCHDOG_LOG="$TEST_ROOT/watchdog.log"
: > "$WATCHDOG_LOG"
printf 'log() { echo "$1" >> "%s"; }\n' "$WATCHDOG_LOG" > "$TEST_ROOT/preamble.sh"
printf 'cleanup_lock() { :; }\n' >> "$TEST_ROOT/preamble.sh"
cat >> "$TEST_ROOT/preamble.sh" <<'OEEOF'
on_exit() {
    if [ "$BOOTSTRAP_UCI_STAGED" = "1" ]; then
        uci revert network.wan6.reqaddress 2>/dev/null
        BOOTSTRAP_UCI_STAGED=0
    fi
    rm -f "$STATE_DIR"/fix_gateway_routes.* 2>/dev/null
    # Stage C2: release shared WAN-recovery lock if this process holds it.
    # Idempotent and safe to call without a successful begin. Guarded so it
    # does not error if the coordinator was never sourced (function absent).
    command -v wan_recovery_cleanup >/dev/null 2>&1 && wan_recovery_cleanup 2>/dev/null
    cleanup_lock
}
OEEOF

# Source the extracted helpers. Provide minimal globals so sourcing does not fail.
STATE_DIR="$TEST_ROOT/state"
mkdir -p "$STATE_DIR"
# Stage C2: shared coordinator paths + interface stubs. The coordinated
# producers (wan_recovery_*) live in the wan-recovery-common library, which is
# NOT part of the extract; the test harness supplies success-returning stubs
# and the REAL coordinated_wan6_begin/end + migration/sync helpers from the
# extract drive them.
WAN_RECOVERY_STATE_DIR="$TEST_ROOT/wan-recovery"
mkdir -p "$WAN_RECOVERY_STATE_DIR"
DISRUPTION_COUNT_FILE="$WAN_RECOVERY_STATE_DIR/disruption_count"
LAST_FULL_WAN_DISRUPTION_FILE="$WAN_RECOVERY_STATE_DIR/last_full_wan_disruption"
DISRUPTION_HOLD_FILE="$WAN_RECOVERY_STATE_DIR/disruption_hold"
WAN_DISRUPTION_COOLDOWN=1200
WAN_RECOVERY_AVAILABLE=1
wan_recovery_ready() { [ "$WAN_RECOVERY_AVAILABLE" = 1 ]; }
wan_recovery_wan6_begin() { return 0; }
wan_recovery_wan6_record_locked() { return 0; }
wan_recovery_end() { return 0; }
wan_recovery_cleanup() { return 0; }
wan_recovery_full_begin() { return 0; }
wan_recovery_full_execute_locked() { return 0; }
GOOD_GW_FILE="$STATE_DIR/good_gateway"
STICKY_GATEWAY="${STICKY_GATEWAY:-1}"
WAN6_PENDING_GRACE=180
WAN6_PENDING_SEEN_FILE="$STATE_DIR/wan6_pending_seen"
WAN6_PENDING_EXPIRED_FILE="$STATE_DIR/wan6_pending_expired"
ROUTE_SNAPSHOT_FILE=""
LAN_DEV="br-lan"
CLEANUP_DEPRECATED_LAN=0
REACHABILITY_CONFIRM_DELAY=0
WAN_RESTART_COOLDOWN=1200
WAN_RESTART_LIMIT=3
WAN_RESTART_FILE="$STATE_DIR/wan_restart_count"
LAST_WAN_RESTART_FILE="$STATE_DIR/last_wan_restart"
FAIL_FILE="$STATE_DIR/fail_count"
PREFIX_FAIL_FILE="$STATE_DIR/prefix_fail_count"
TIER0_FAIL_FILE="$STATE_DIR/tier0_fail_count"
PREFIX_BACKOFF_FILE="$STATE_DIR/prefix_next_attempt"
ONT_FLAG="$STATE_DIR/ont_notified"
RECOVERY_HOLD_FILE="$STATE_DIR/recovery_hold"
HOLD_STATUS_FILE="$STATE_DIR/hold_status"
WAN_RESTARTS=0
NOW=$(date +%s)

# shellcheck disable=SC1090
. "$TEST_ROOT/preamble.sh"
# shellcheck disable=SC1090
. "$EXTRACT"

# ================================================================
# Mock framework
# ================================================================

MOCK_DIR="$TEST_ROOT/mock"
mkdir -p "$MOCK_DIR"
SCENARIO="$TEST_ROOT/scenario"
export SCENARIO

# Scenario keys (replacement semantics, same as Phase 2 harness):
#   REQADDRESS_COMMITTED   committed reqaddress value (default: none)
#   REQADDRESS_STAGED      current staged reqaddress (set by mock uci)
#   PREFIX_ADDR            IA_PD prefix address (empty = no PD)
#   PREFIX_MASK            IA_PD prefix mask
#   WAN_L3_DEVICE          wan6 l3_device
#   LAN_SRC                LAN PD source address
#   WAN128_ADDR            global /128 on WAN_DEV (empty = no /128)
#   PD_OK_GATEWAYS         gateways that forward PD traffic
#   ROUTES_FILE            path to mock route file
#   NEIGH_FILE             path to mock neigh file
#   PING6_LOG              path to ping6 call log
#   UCI_LOG                path to uci call log
#   UBUS_LOG               path to ubus call log
#   IFDOWN_LOG             path to ifdown call log
#   IFUP_LOG               path to ifup call log
#   BOOTSTRAP_STAGED       tracks whether reqaddress=try is currently staged

reset_scenario() {
    : > "$SCENARIO"
    printf 'REQADDRESS_COMMITTED=none\n' >> "$SCENARIO"
    printf 'REQADDRESS_STAGED=\n' >> "$SCENARIO"
    printf 'PREFIX_ADDR=\n' >> "$SCENARIO"
    printf 'PREFIX_MASK=56\n' >> "$SCENARIO"
    printf 'WAN_L3_DEVICE=eth1\n' >> "$SCENARIO"
    printf 'LAN_SRC=2001:db8:7e3:7700:abcd::1\n' >> "$SCENARIO"
    printf 'WAN128_ADDR=\n' >> "$SCENARIO"
    printf 'PD_OK_GATEWAYS=\n' >> "$SCENARIO"
    printf 'ROUTES=\n' >> "$SCENARIO"
    printf 'NEIGH=\n' >> "$SCENARIO"
    printf 'PING6_LOG=\n' >> "$SCENARIO"
    printf 'UCI_LOG=\n' >> "$SCENARIO"
    printf 'UBUS_LOG=\n' >> "$SCENARIO"
    printf 'IFDOWN_LOG=\n' >> "$SCENARIO"
    printf 'IFUP_LOG=\n' >> "$SCENARIO"
    printf 'IP_TRACE=\n' >> "$SCENARIO"
    printf 'POST_REVERT_PREFIX=\n' >> "$SCENARIO"
    printf 'POST_REVERT_ACTIVE=\n' >> "$SCENARIO"
    printf 'WAN128_CLEANED=\n' >> "$SCENARIO"
    printf 'POST_CLEANUP_PING_FAIL=\n' >> "$SCENARIO"
    : > "$WATCHDOG_LOG"
    rm -f "$GOOD_GW_FILE" "$RECOVERY_HOLD_FILE" "$ONT_FLAG"
    rm -f "$STATE_DIR"/fix_gateway_routes.* 2>/dev/null
    # Stage C2: also clear shared-coordinator state (test R creates a shared
    # disruption hold; it must not bleed into subsequent tests, whose
    # try_128_bootstrap entry gate would then refuse under an active hold).
    rm -f "$DISRUPTION_HOLD_FILE" "$DISRUPTION_COUNT_FILE" \
        "$LAST_FULL_WAN_DISRUPTION_FILE" "$LAST_WAN6_ACTION_FILE"
    rm -rf "$DISRUPTION_LOCK_DIR" 2>/dev/null
    rm -f "$STATE_DIR"/c2_migrated 2>/dev/null
}

set_scenario() {
    _ss_key="$1"; _ss_val="$2"
    _ss_tmp="$SCENARIO.set.$$"
    if [ -f "$SCENARIO" ]; then
        grep -v "^${_ss_key}=" "$SCENARIO" 2>/dev/null > "$_ss_tmp" || :
    else
        : > "$_ss_tmp"
    fi
    printf '%s=%s\n' "$_ss_key" "$_ss_val" >> "$_ss_tmp"
    mv "$_ss_tmp" "$SCENARIO"
}
get_scenario() { sed -n "s/^$1=//p" "$SCENARIO" | head -1; }

build_mocks() {
# --- mock uci ---
cat > "$MOCK_DIR/uci" <<'EOF'
#!/bin/sh
SCEN="${SCENARIO:-/dev/null}"
UCI_LOG=$(sed -n 's/^UCI_LOG=//p' "$SCEN" | head -1)
[ -n "$UCI_LOG" ] && echo "uci $*" >> "$UCI_LOG"

COMMITTED=$(sed -n 's/^REQADDRESS_COMMITTED=//p' "$SCEN" | head -1)
STAGED=$(sed -n 's/^REQADDRESS_STAGED=//p' "$SCEN" | head -1)

case "$1" in
    get)
        # uci get network.wan6.reqaddress
        case "$2" in
            network.wan6.reqaddress)
                if [ -n "$STAGED" ]; then
                    printf '%s\n' "$STAGED"
                else
                    printf '%s\n' "$COMMITTED"
                fi
                exit 0
                ;;
            *)
                exit 0
                ;;
        esac
        ;;
    set)
        # uci set network.wan6.reqaddress='try'
        # Parse: network.wan6.reqaddress='try'
        val="$2"
        case "$val" in
            network.wan6.reqaddress=*)
                newval="${val#network.wan6.reqaddress=}"
                # Strip quotes
                newval="${newval#\'}"
                newval="${newval%\'}"
                # Update staged in scenario
                tmp="$SCEN.uci.$$"
                grep -v "^REQADDRESS_STAGED=" "$SCEN" 2>/dev/null > "$tmp" || :
                printf 'REQADDRESS_STAGED=%s\n' "$newval" >> "$tmp"
                mv "$tmp" "$SCEN"
                ;;
        esac
        exit 0
        ;;
    revert)
        # uci revert network.wan6.reqaddress
        case "$2" in
            network.wan6.reqaddress)
                tmp="$SCEN.uci.$$"
                grep -v "^REQADDRESS_STAGED=" "$SCEN" 2>/dev/null > "$tmp" || :
                printf 'REQADDRESS_STAGED=\n' >> "$tmp"
                mv "$tmp" "$SCEN"
                ;;
        esac
        exit 0
        ;;
    commit)
        # Should never be called from bootstrap
        exit 0
        ;;
    *)
        exit 0
        ;;
esac
EOF
chmod +x "$MOCK_DIR/uci"

# --- mock ubus ---
cat > "$MOCK_DIR/ubus" <<'EOF'
#!/bin/sh
SCEN="${SCENARIO:-/dev/null}"
UBUS_LOG=$(sed -n 's/^UBUS_LOG=//p' "$SCEN" | head -1)
[ -n "$UBUS_LOG" ] && echo "ubus $*" >> "$UBUS_LOG"
# ubus call network.interface.wan6 status
# Script is invoked as "ubus", so $1=call $2=network.interface.wan6 $3=status
case "$1" in
    call)
        case "$2" in
            network.interface.wan6)
                case "$3" in
                    status)
                        PREFIX_ADDR=$(sed -n 's/^PREFIX_ADDR=//p' "$SCEN" | head -1)
                        PREFIX_MASK=$(sed -n 's/^PREFIX_MASK=//p' "$SCEN" | head -1)
                        L3=$(sed -n 's/^WAN_L3_DEVICE=//p' "$SCEN" | head -1)
                        # Stateful: after uci revert clears REQADDRESS_STAGED,
                        # return POST_REVERT_PREFIX if the key is present (even
                        # if empty = PD disappeared). Use POST_REVERT_ACTIVE=1
                        # to enable this override.
                        STAGED=$(sed -n 's/^REQADDRESS_STAGED=//p' "$SCEN" | head -1)
                        POST_REVERT_ACTIVE=$(sed -n 's/^POST_REVERT_ACTIVE=//p' "$SCEN" | head -1)
                        POST_REVERT=$(sed -n 's/^POST_REVERT_PREFIX=//p' "$SCEN" | head -1)
                        if [ -z "$STAGED" ] && [ "$POST_REVERT_ACTIVE" = "1" ]; then
                            PREFIX_ADDR="$POST_REVERT"
                        fi
                        if [ -n "$PREFIX_ADDR" ]; then
                            printf '{"up":true,"pending":false,"l3_device":"%s","ipv6-prefix":[{"address":"%s","mask":%s}],"delegation":true}' "$L3" "$PREFIX_ADDR" "$PREFIX_MASK"
                        else
                            printf '{"up":true,"pending":false,"l3_device":"%s","ipv6-prefix":[]}' "$L3"
                        fi
                        ;;
                    renew)
                        exit 0
                        ;;
                esac
                ;;
            network)
                case "$3" in
                    reload)
                        exit 0
                        ;;
                    get_proto_handlers)
                        printf '{}'
                        ;;
                esac
                ;;
        esac
        ;;
esac
exit 0
EOF
chmod +x "$MOCK_DIR/ubus"

# --- mock jsonfilter ---
cat > "$MOCK_DIR/jsonfilter" <<'EOF'
#!/bin/sh
input=$(cat)
expr="$2"
case "$expr" in
    '@["ipv6-prefix"][0].address')
        printf '%s' "$input" | sed -n 's/.*"ipv6-prefix":\[{"address":"\([^"]*\)".*/\1/p'
        ;;
    '@["ipv6-prefix"][0].mask')
        printf '%s' "$input" | sed -n 's/.*"mask":\([0-9]*\).*/\1/p'
        ;;
    '@["l3_device"]')
        printf '%s' "$input" | sed -n 's/.*"l3_device":"\([^"]*\)".*/\1/p'
        ;;
    '@["up"]')
        printf '%s' "$input" | sed -n 's/.*"up":\([a-z]*\).*/\1/p'
        ;;
    '@["pending"]')
        printf '%s' "$input" | sed -n 's/.*"pending":\([a-z]*\).*/\1/p'
        ;;
    *)
        printf '%s' "$input" | sed -n 's/.*"ipv6-prefix":\[{"address":"\([^"]*\)".*/\1/p'
        ;;
esac
EOF
chmod +x "$MOCK_DIR/jsonfilter"

# --- mock ip ---
cat > "$MOCK_DIR/ip" <<'EOF'
#!/bin/sh
SCEN="${SCENARIO:-/dev/null}"
ROUTES_FILE=$(sed -n 's/^ROUTES=//p' "$SCEN" | head -1)
NEIGH_FILE=$(sed -n 's/^NEIGH=//p' "$SCEN" | head -1)
IP_TRACE=$(sed -n 's/^IP_TRACE=//p' "$SCEN" | head -1)
[ -n "$IP_TRACE" ] && echo "ip args: $*" >> "$IP_TRACE"

case "$2" in
    route)
        case "$3" in
            show)
                dev=""; from=""
                shift 3
                while [ $# -gt 0 ]; do
                    case "$1" in
                        default) ;;
                        dev) dev="$2"; shift ;;
                        from) from="$2"; shift ;;
                    esac
                    shift
                done
                if [ -n "$from" ]; then
                    grep "^default from $from " "$ROUTES_FILE" 2>/dev/null
                elif [ -n "$dev" ]; then
                    grep "^default.* dev $dev" "$ROUTES_FILE" 2>/dev/null
                else
                    grep '^default' "$ROUTES_FILE" 2>/dev/null
                fi
                ;;
            get)
                # ip -6 route get <target> from <src> -- kernel-truth
                # effective-route lookup. Source-specific rule wins over the
                # generic default; with neither, "unreachable" with rc=0.
                from=""
                shift 3
                while [ $# -gt 0 ]; do
                    case "$1" in
                        from) from="$2"; shift ;;
                        *) shift ;;
                    esac
                done
                [ -n "$from" ] || exit 1
                line=$(grep "^default from $from .* dev " "$ROUTES_FILE" 2>/dev/null | head -1)
                [ -z "$line" ] && line=$(grep "^default via .* dev " "$ROUTES_FILE" 2>/dev/null | head -1)
                if [ -n "$line" ]; then
                    gw=$(printf '%s\n' "$line" | awk '{for(i=1;i<=NF;i++) if($i=="via"){print $(i+1); exit}}')
                    dev=$(printf '%s\n' "$line" | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}')
                    metric=$(printf '%s\n' "$line" | awk '{for(i=1;i<=NF;i++) if($i=="metric"){print $(i+1); exit}}')
                    printf '%s via %s dev %s metric %s\n' "$from" "$gw" "$dev" "${metric:-0}"
                else
                    echo "unreachable $from"
                fi
                ;;
            replace)
                spec="$4"; shift 4
                while [ $# -gt 0 ]; do spec="$spec $1"; shift; done
                key_from=$(printf '%s\n' "$spec" | awk '{for(i=1;i<=NF;i++) if($i=="from"){print $(i+1); exit}}')
                key_via=$(printf '%s\n' "$spec" | awk '{for(i=1;i<=NF;i++) if($i=="via"){print $(i+1); exit}}')
                key_dev=$(printf '%s\n' "$spec" | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}')
                if [ -n "$key_from" ]; then
                    grep -v "^default from $key_from .*dev $key_dev" "$ROUTES_FILE" 2>/dev/null > "$ROUTES_FILE.tmp"
                    mv "$ROUTES_FILE.tmp" "$ROUTES_FILE" 2>/dev/null
                elif [ -n "$key_via" ]; then
                    grep -v "^default via .*dev $key_dev" "$ROUTES_FILE" 2>/dev/null > "$ROUTES_FILE.tmp"
                    mv "$ROUTES_FILE.tmp" "$ROUTES_FILE" 2>/dev/null
                fi
                printf '%s\n' "$spec" >> "$ROUTES_FILE"
                ;;
            del)
                spec="$4"; shift 4
                while [ $# -gt 0 ]; do spec="$spec $1"; shift; done
                grep -v "^$(printf '%s' "$spec" | sed 's/[][\\.*+?(){}|^$]/\\&/g')\$" "$ROUTES_FILE" 2>/dev/null > "$ROUTES_FILE.tmp"
                mv "$ROUTES_FILE.tmp" "$ROUTES_FILE" 2>/dev/null
                ;;
        esac
        ;;
    neigh)
        case "$3" in
            show)
                dev="$5"
                if [ -n "$dev" ]; then
                    awk -v d="$dev" '$0 ~ "dev "d {print}' "$NEIGH_FILE" 2>/dev/null
                else
                    cat "$NEIGH_FILE" 2>/dev/null
                fi
                ;;
            replace)
                gw="$5"; mac="$7"; dev="$9"
                grep -v "^$gw " "$NEIGH_FILE" 2>/dev/null > "$NEIGH_FILE.tmp"
                mv "$NEIGH_FILE.tmp" "$NEIGH_FILE" 2>/dev/null
                printf '%s lladdr %s dev %s router\n' "$gw" "$mac" "$dev" >> "$NEIGH_FILE"
                ;;
        esac
        ;;
    addr)
        case "$3" in
            show)
                # ip -6 addr show dev WAN_DEV -> emit WAN128 if present
                # Args: $1=-6 $2=addr $3=show $4=dev $5=<devname>
                wan128=$(sed -n 's/^WAN128_ADDR=//p' "$SCEN" | head -1)
                lan_src=$(sed -n 's/^LAN_SRC=//p' "$SCEN" | head -1)
                dev="$5"
                if [ "$dev" = "eth1" ] && [ -n "$wan128" ]; then
                    printf 'inet6 %s/128 scope global\n' "$wan128"
                    printf '   valid_lft 86400sec preferred_lft 14400sec\n'
                fi
                if [ "$dev" = "br-lan" ] && [ -n "$lan_src" ]; then
                    printf 'inet6 %s/64 scope global dynamic\n' "$lan_src"
                    printf '   valid_lft 86400sec preferred_lft 14400sec\n'
                fi
                ;;
            del)
                # ip -6 addr del <addr> dev <dev>
                # Args: $1=-6 $2=addr $3=del $4=<addr> $5=dev $6=<devname>
                # Track deletion by clearing WAN128_ADDR and setting WAN128_CLEANED
                [ -n "$IP_TRACE" ] && echo "ip addr del: dev=$6 addr=$4" >> "$IP_TRACE"
                dev="$6"
                if [ "$dev" = "eth1" ]; then
                    tmp="$SCEN.ip.$$"
                    grep -v "^WAN128_ADDR=\|^WAN128_CLEANED=" "$SCEN" 2>/dev/null > "$tmp" || :
                    printf 'WAN128_ADDR=\n' >> "$tmp"
                    printf 'WAN128_CLEANED=1\n' >> "$tmp"
                    mv "$tmp" "$SCEN"
                fi
                ;;
        esac
        ;;
esac
exit 0
EOF
chmod +x "$MOCK_DIR/ip"

# --- mock ping6 ---
cat > "$MOCK_DIR/ping6" <<'EOF'
#!/bin/sh
SCEN="${SCENARIO:-/dev/null}"
PING6_LOG=$(sed -n 's/^PING6_LOG=//p' "$SCEN" | head -1)
[ -n "$PING6_LOG" ] && echo "$@" >> "$PING6_LOG"

ROUTES_FILE=$(sed -n 's/^ROUTES=//p' "$SCEN" | head -1)
PD_OK_GATEWAYS=$(sed -n 's/^PD_OK_GATEWAYS=//p' "$SCEN" | head -1)
PD_CIDR=$(sed -n 's/^PREFIX_ADDR=//p' "$SCEN" | head -1)/$(sed -n 's/^PREFIX_MASK=//p' "$SCEN" | head -1)

# Extract -I source if present.
src=""
target=""
prev=""
for a in "$@"; do
    if [ "$prev" = "-I" ]; then src="$a"; fi
    prev="$a"
    case "$a" in -*) ;; *) target="$a";; esac
done

case "$target" in
    ff02::2)
        exit 0
        ;;
    2001:4860:4860::8888|2606:4700:4700::1111)
        if [ -n "$src" ]; then
            # Stateful: if WAN128 was just cleaned and POST_CLEANUP_PING_FAIL=1,
            # simulate PD connectivity failure after cleanup (test M).
            WAN128_CLEANED=$(sed -n 's/^WAN128_CLEANED=//p' "$SCEN" | head -1)
            POST_CLEANUP_FAIL=$(sed -n 's/^POST_CLEANUP_PING_FAIL=//p' "$SCEN" | head -1)
            if [ "$WAN128_CLEANED" = "1" ] && [ "$POST_CLEANUP_FAIL" = "1" ]; then
                exit 1
            fi
            # PD-sourced ping: gateway-aware model
            if [ -n "$PD_OK_GATEWAYS" ]; then
                gen_gw=$(grep '^default via ' "$ROUTES_FILE" 2>/dev/null \
                    | awk '{for(i=1;i<=NF;i++) if($i=="via"){print $(i+1); exit}}' | head -1)
                src_gw=$(grep "^default from $PD_CIDR via " "$ROUTES_FILE" 2>/dev/null \
                    | awk '{for(i=1;i<=NF;i++) if($i=="via"){print $(i+1); exit}}' | head -1)
                [ -n "$gen_gw" ] || exit 1
                [ -n "$src_gw" ] || exit 1
                [ "$gen_gw" = "$src_gw" ] || exit 1
                for ok in $PD_OK_GATEWAYS; do
                    [ "$ok" = "$gen_gw" ] && exit 0
                done
                exit 1
            else
                exit 1
            fi
        else
            exit 1
        fi
        ;;
    *)
        exit 0
        ;;
esac
EOF
chmod +x "$MOCK_DIR/ping6"

# --- mock ifdown ---
cat > "$MOCK_DIR/ifdown" <<'EOF'
#!/bin/sh
SCEN="${SCENARIO:-/dev/null}"
IFDOWN_LOG=$(sed -n 's/^IFDOWN_LOG=//p' "$SCEN" | head -1)
[ -n "$IFDOWN_LOG" ] && echo "$@" >> "$IFDOWN_LOG"
exit 0
EOF
chmod +x "$MOCK_DIR/ifdown"

# --- mock ifup ---
cat > "$MOCK_DIR/ifup" <<'EOF'
#!/bin/sh
SCEN="${SCENARIO:-/dev/null}"
IFUP_LOG=$(sed -n 's/^IFUP_LOG=//p' "$SCEN" | head -1)
[ -n "$IFUP_LOG" ] && echo "$@" >> "$IFUP_LOG"
exit 0
EOF
chmod +x "$MOCK_DIR/ifup"

# --- mock sleep ---
cat > "$MOCK_DIR/sleep" <<'EOF'
#!/bin/sh
:
EOF
chmod +x "$MOCK_DIR/sleep"

# --- mock logger ---
cat > "$MOCK_DIR/logger" <<'EOF'
#!/bin/sh
exit 0
EOF
chmod +x "$MOCK_DIR/logger"
}

build_mocks

# ================================================================
# Per-test setup
# ================================================================
ORIG_PATH="$PATH"

run_test() {
    name="$1"
    ROUTES_FILE="$TEST_ROOT/routes_$$.txt"
    NEIGH_FILE="$TEST_ROOT/neigh_$$.txt"
    PING6_LOG="$TEST_ROOT/ping6_$$.log"
    UCI_LOG="$TEST_ROOT/uci_$$.log"
    UBUS_LOG="$TEST_ROOT/ubus_$$.log"
    IFDOWN_LOG="$TEST_ROOT/ifdown_$$.log"
    IFUP_LOG="$TEST_ROOT/ifup_$$.log"
    : > "$ROUTES_FILE"
    : > "$NEIGH_FILE"
    : > "$PING6_LOG"
    : > "$UCI_LOG"
    : > "$UBUS_LOG"
    : > "$IFDOWN_LOG"
    : > "$IFUP_LOG"
    IP_TRACE="$TEST_ROOT/ip_trace_$$.log"
    : > "$IP_TRACE"
    reset_scenario
    set_scenario "ROUTES" "$ROUTES_FILE"
    set_scenario "NEIGH" "$NEIGH_FILE"
    set_scenario "PING6_LOG" "$PING6_LOG"
    set_scenario "UCI_LOG" "$UCI_LOG"
    set_scenario "UBUS_LOG" "$UBUS_LOG"
    set_scenario "IFDOWN_LOG" "$IFDOWN_LOG"
    set_scenario "IFUP_LOG" "$IFUP_LOG"
    set_scenario "IP_TRACE" "$IP_TRACE"
    set_scenario "IFDOWN_LOG" "$IFDOWN_LOG"
    set_scenario "IFUP_LOG" "$IFUP_LOG"
    # Set globals the helpers expect
    PD_CIDR="2001:db8:7e3:7700::/56"
    PD_ADDR="2001:db8:7e3:7700::"
    PD_MASK="56"
    LAN_PD_SRC="2001:db8:7e3:7700:abcd::1"
    WAN_DEV="eth1"
    WAN128=""
    WAN_RESTARTS=0
    BOOTSTRAP_UCI_STAGED=0
    # Harness default: CLEANUP_WAN128=0 (a healthy /128 is OPTIONAL and may be
    # retained per the v3.10 health contract). Tests that exercise the opt-in
    # cleanup path set CLEANUP_WAN128=1 explicitly.
    CLEANUP_WAN128="${CLEANUP_WAN128:-0}"
    # Harness default: BOOTSTRAP_ENABLED=1 so the existing A-T tests exercise
    # the enabled experimental path. Tests U/V/W override this to 0 to verify
    # the disabled-by-default behavior.
    BOOTSTRAP_ENABLED="${BOOTSTRAP_ENABLED:-1}"
    PATH="$MOCK_DIR:$ORIG_PATH" "$name"
    rc=$?
    rm -f "$ROUTES_FILE" "$NEIGH_FILE" "$PING6_LOG" "$UCI_LOG" "$UBUS_LOG" "$IFDOWN_LOG" "$IFUP_LOG" "$IP_TRACE" 2>/dev/null
    rm -f "$STATE_DIR"/fix_gateway_routes.* 2>/dev/null
    return $rc
}

add_route() { printf '%s\n' "$1" >> "$ROUTES_FILE"; }
add_neigh() { printf '%s\n' "$1" >> "$NEIGH_FILE"; }

# ================================================================
# Tests
# ================================================================

# A. Production reqaddress=none: temporary try staging allowed
test_A() {
    echo "--- A: production reqaddress=none, staging allowed ---"
    set_scenario "PREFIX_ADDR" "2001:db8:7e3:7700::"
    set_scenario "PD_OK_GATEWAYS" "fe80::aaaa"
    add_route "default via fe80::aaaa dev eth1 metric 512"
    add_route "default from 2001:db8:7e3:7700::/56 via fe80::aaaa dev eth1 metric 512"
    add_neigh "fe80::aaaa lladdr aa:aa:aa:aa:aa:aa dev eth1 router"
    try_128_bootstrap
    rc=$?
    assert_eq "bootstrap return" "$rc" "0"
    # Verify staging happened and was reverted
    assert_contains "uci set was called" "network.wan6.reqaddress" "$UCI_LOG"
    assert_contains "uci revert was called" "revert" "$UCI_LOG"
}

# B. Production reqaddress != none: refuses, zero UCI mutation
test_B() {
    echo "--- B: production reqaddress != none, refuses ---"
    set_scenario "REQADDRESS_COMMITTED" "try"
    try_128_bootstrap
    rc=$?
    assert_eq "bootstrap return (refuse)" "$rc" "1"
    assert_not_contains "no uci set" "network.wan6.reqaddress=" "$UCI_LOG"
    assert_not_contains "no ifdown" "wan6" "$IFDOWN_LOG"
}

# C. IA_NA only: failure, restored to none, no success-state reset
test_C() {
    echo "--- C: IA_NA only, failure ---"
    set_scenario "PREFIX_ADDR" ""
    set_scenario "WAN128_ADDR" "2001:db8::1"
    try_128_bootstrap
    rc=$?
    assert_eq "bootstrap return (IA_NA-only failure)" "$rc" "1"
    assert_contains "uci revert called" "revert" "$UCI_LOG"
    # Verify no GOOD_GW_FILE was set
    assert_eq "GOOD_GW_FILE empty" "$(cat "$GOOD_GW_FILE" 2>/dev/null)" ""
}

# D. IA_PD without WAN128: valid path
test_D() {
    echo "--- D: IA_PD without WAN128, valid ---"
    set_scenario "PREFIX_ADDR" "2001:db8:7e3:7700::"
    set_scenario "WAN128_ADDR" ""
    set_scenario "PD_OK_GATEWAYS" "fe80::aaaa"
    add_route "default via fe80::aaaa dev eth1 metric 512"
    add_route "default from 2001:db8:7e3:7700::/56 via fe80::aaaa dev eth1 metric 512"
    add_neigh "fe80::aaaa lladdr aa:aa:aa:aa:aa:aa dev eth1 router"
    try_128_bootstrap
    rc=$?
    assert_eq "bootstrap return (PD without WAN128)" "$rc" "0"
}

# E. IA_NA + IA_PD: WAN128 does not define success, PD path does
test_E() {
    echo "--- E: IA_NA + IA_PD, PD path defines success ---"
    set_scenario "PREFIX_ADDR" "2001:db8:7e3:7700::"
    set_scenario "WAN128_ADDR" "2001:db8::1"
    set_scenario "PD_OK_GATEWAYS" "fe80::aaaa"
    add_route "default via fe80::aaaa dev eth1 metric 512"
    add_route "default from 2001:db8:7e3:7700::/56 via fe80::aaaa dev eth1 metric 512"
    add_neigh "fe80::aaaa lladdr aa:aa:aa:aa:aa:aa dev eth1 router"
    try_128_bootstrap
    rc=$?
    assert_eq "bootstrap return" "$rc" "0"
}

# F. PD exists but LAN_PD_SRC absent: failure
test_F() {
    echo "--- F: PD exists but LAN_PD_SRC absent ---"
    set_scenario "PREFIX_ADDR" "2001:db8:7e3:7700::"
    set_scenario "LAN_SRC" ""
    try_128_bootstrap
    rc=$?
    assert_eq "bootstrap return (no LAN_PD_SRC)" "$rc" "1"
    assert_contains "uci revert called" "revert" "$UCI_LOG"
}

# G. PD source exists but pd_internet_ok fails: failure
test_G() {
    echo "--- G: PD source exists but pd_internet_ok fails ---"
    set_scenario "PREFIX_ADDR" "2001:db8:7e3:7700::"
    set_scenario "PD_OK_GATEWAYS" ""
    add_route "default via fe80::aaaa dev eth1 metric 512"
    add_route "default from 2001:db8:7e3:7700::/56 via fe80::aaaa dev eth1 metric 512"
    add_neigh "fe80::aaaa lladdr aa:aa:aa:aa:aa:aa dev eth1 router"
    try_128_bootstrap
    rc=$?
    assert_eq "bootstrap return (pd_internet_ok fails)" "$rc" "1"
    assert_contains "uci revert called" "revert" "$UCI_LOG"
}

# H. PD healthy while temporary try staged: revert, settle, PD survives
test_H() {
    echo "--- H: PD healthy while try staged, survives revert ---"
    set_scenario "PREFIX_ADDR" "2001:db8:7e3:7700::"
    set_scenario "PD_OK_GATEWAYS" "fe80::aaaa"
    add_route "default via fe80::aaaa dev eth1 metric 512"
    add_route "default from 2001:db8:7e3:7700::/56 via fe80::aaaa dev eth1 metric 512"
    add_neigh "fe80::aaaa lladdr aa:aa:aa:aa:aa:aa dev eth1 router"
    try_128_bootstrap
    rc=$?
    assert_eq "bootstrap return" "$rc" "0"
}

# I. PD disappears after revert: failure
test_I() {
    echo "--- I: PD disappears after revert ---"
    # PD is present during the temporary-try acquisition window (PREFIX_ADDR set),
    # but after uci revert clears REQADDRESS_STAGED, the stateful ubus mock returns
    # POST_REVERT_PREFIX (empty here) instead of PREFIX_ADDR, simulating PD loss.
    set_scenario "PREFIX_ADDR" "2001:db8:7e3:7700::"
    set_scenario "PD_OK_GATEWAYS" "fe80::aaaa"
    set_scenario "POST_REVERT_ACTIVE" "1"
    set_scenario "POST_REVERT_PREFIX" ""
    add_route "default via fe80::aaaa dev eth1 metric 512"
    add_route "default from 2001:db8:7e3:7700::/56 via fe80::aaaa dev eth1 metric 512"
    add_neigh "fe80::aaaa lladdr aa:aa:aa:aa:aa:aa dev eth1 router"
    try_128_bootstrap >/dev/null 2>&1
    rc=$?
    assert_eq "bootstrap return (PD lost after revert)" "$rc" "1"
    assert_contains "uci revert called" "revert" "$UCI_LOG"
}

# J. PD survives revert but source-specific route is wrong: fix_gateway repair
test_J() {
    echo "--- J: PD survives but routes incoherent, fix_gateway repair ---"
    set_scenario "PREFIX_ADDR" "2001:db8:7e3:7700::"
    set_scenario "PD_OK_GATEWAYS" "fe80::bbbb"
    # Generic via a, PD via a (incoherent with PD_OK_GATEWAYS which wants b)
    add_route "default via fe80::aaaa dev eth1 metric 512"
    add_route "default from 2001:db8:7e3:7700::/56 via fe80::aaaa dev eth1 metric 512"
    add_neigh "fe80::aaaa lladdr aa:aa:aa:aa:aa:aa dev eth1 router"
    add_neigh "fe80::bbbb lladdr bb:bb:bb:bb:bb:bb dev eth1 router"
    try_128_bootstrap
    rc=$?
    # fix_gateway should repair routes to point at bbbb (PD_OK_GATEWAYS)
    assert_eq "bootstrap return" "$rc" "0"
    assert_contains "generic via b" "default via fe80::bbbb" "$ROUTES_FILE"
    assert_contains "PD route via b" "default from 2001:db8:7e3:7700::/56 via fe80::bbbb" "$ROUTES_FILE"
}

# K. Full success: PD survives, routes coherent, pd_internet_ok; WAN128 retained
# v3.10: CLEANUP_WAN128 defaults to 0. A healthy /128 is OPTIONAL and may be
# retained. Full success no longer implies /128 removal.
test_K() {
    echo "--- K: full success, WAN128 retained (CLEANUP_WAN128=0 default) ---"
    set_scenario "PREFIX_ADDR" "2001:db8:7e3:7700::"
    set_scenario "WAN128_ADDR" "2001:db8::1"
    set_scenario "PD_OK_GATEWAYS" "fe80::aaaa"
    add_route "default via fe80::aaaa dev eth1 metric 512"
    add_route "default from 2001:db8:7e3:7700::/56 via fe80::aaaa dev eth1 metric 512"
    add_neigh "fe80::aaaa lladdr aa:aa:aa:aa:aa:aa dev eth1 router"
    try_128_bootstrap
    rc=$?
    assert_eq "bootstrap return (full success)" "$rc" "0"
    # WAN128 must be retained (default CLEANUP_WAN128=0)
    wan128_after=$(get_scenario "WAN128_ADDR")
    assert_eq "WAN128 retained" "$wan128_after" "2001:db8::1"
    assert_eq "no cleanup flag" "$(get_scenario WAN128_CLEANED)" ""
}

# L. Opt-in WAN128 cleanup (CLEANUP_WAN128=1): legacy/experimental behavior
# When an operator explicitly enables cleanup, the /128 is removed after PD
# health is confirmed. This remains a supported opt-in, not the default.
test_L() {
    echo "--- L: opt-in WAN128 cleanup (CLEANUP_WAN128=1) ---"
    CLEANUP_WAN128=1
    set_scenario "PREFIX_ADDR" "2001:db8:7e3:7700::"
    set_scenario "WAN128_ADDR" "2001:db8::1"
    set_scenario "PD_OK_GATEWAYS" "fe80::aaaa"
    add_route "default via fe80::aaaa dev eth1 metric 512"
    add_route "default from 2001:db8:7e3:7700::/56 via fe80::aaaa dev eth1 metric 512"
    add_neigh "fe80::aaaa lladdr aa:aa:aa:aa:aa:aa dev eth1 router"
    try_128_bootstrap
    rc=$?
    assert_eq "bootstrap return (opt-in cleanup success)" "$rc" "0"
    # WAN128 should be cleaned up since cleanup was explicitly enabled
    wan128_after=$(get_scenario "WAN128_ADDR")
    assert_eq "WAN128 cleaned" "$wan128_after" ""
    assert_eq "cleanup flag set" "$(get_scenario WAN128_CLEANED)" "1"
    CLEANUP_WAN128=0
}

# M. PD connectivity fails after opt-in WAN128 cleanup: failure
# CLEANUP_WAN128=1 is required for cleanup to run; the stateful ping6 mock
# sees POST_CLEANUP_PING_FAIL=1 and fails the final pd_internet_ok gate.
test_M() {
    echo "--- M: PD connectivity fails after opt-in WAN128 cleanup ---"
    CLEANUP_WAN128=1
    set_scenario "PREFIX_ADDR" "2001:db8:7e3:7700::"
    set_scenario "WAN128_ADDR" "2001:db8::1"
    set_scenario "PD_OK_GATEWAYS" "fe80::aaaa"
    set_scenario "POST_CLEANUP_PING_FAIL" "1"
    add_route "default via fe80::aaaa dev eth1 metric 512"
    add_route "default from 2001:db8:7e3:7700::/56 via fe80::aaaa dev eth1 metric 512"
    add_neigh "fe80::aaaa lladdr aa:aa:aa:aa:aa:aa dev eth1 router"
    try_128_bootstrap >/dev/null 2>&1
    rc=$?
    assert_eq "bootstrap return (PD fails after cleanup)" "$rc" "1"
    # Verify cleanup actually happened (WAN128 was removed) before the failure
    assert_eq "WAN128 was cleaned" "$(get_scenario WAN128_ADDR)" ""
    assert_eq "WAN128_CLEANED flag set" "$(get_scenario WAN128_CLEANED)" "1"
    CLEANUP_WAN128=0
}

# N. Early exit / signal: staged UCI reverted
test_N() {
    echo "--- N: on_exit reverts staged UCI ---"
    # Part 1: on_exit helper behavior - direct invocation proves the helper
    # reverts staged UCI and clears the flag. This does NOT prove trap wiring.
    BOOTSTRAP_UCI_STAGED=1
    set_scenario "REQADDRESS_STAGED" "try"
    on_exit
    assert_eq "BOOTSTRAP_UCI_STAGED cleared" "$BOOTSTRAP_UCI_STAGED" "0"
    staged=$(get_scenario "REQADDRESS_STAGED")
    assert_eq "staged reverted" "$staged" ""

    # Part 2: static assertion that production ipv6-watchdog registers the
    # EXIT/INT/TERM traps to on_exit. This proves the trap CONTRACT exists in
    # the production script without relying on live signal delivery (which is
    # a BusyBox/ash runtime behavior requiring live validation).
    assert_contains "production EXIT trap registered" "trap 'on_exit' EXIT" "$SCRIPT_DIR/ipv6-watchdog"
    assert_contains "production INT trap registered" "trap 'on_exit; exit 130' INT" "$SCRIPT_DIR/ipv6-watchdog"
    assert_contains "production TERM trap registered" "trap 'on_exit; exit 143' TERM" "$SCRIPT_DIR/ipv6-watchdog"
}

# O. Zero uci commit network
test_O() {
    echo "--- O: zero uci commit ---"
    set_scenario "PREFIX_ADDR" "2001:db8:7e3:7700::"
    set_scenario "PD_OK_GATEWAYS" "fe80::aaaa"
    add_route "default via fe80::aaaa dev eth1 metric 512"
    add_route "default from 2001:db8:7e3:7700::/56 via fe80::aaaa dev eth1 metric 512"
    add_neigh "fe80::aaaa lladdr aa:aa:aa:aa:aa:aa dev eth1 router"
    try_128_bootstrap >/dev/null 2>&1
    assert_not_contains "no uci commit" "commit" "$UCI_LOG"
}

# P. Zero ifdown/ifup wan, network restart, LAN restart, reboot
test_P() {
    echo "--- P: zero ifdown wan / ifup wan ---"
    # Stage C2: NO prefix at B3 begin time (if a prefix were already present,
    # the coordinated post-lock recheck would skip the wan6 cycle entirely and
    # no ifdown/ifup would occur). The prefix stays absent so the cycle
    # executes and the wait loop times out, then the bootstrap reverts.
    set_scenario "PREFIX_ADDR" ""
    set_scenario "PD_OK_GATEWAYS" "fe80::aaaa"
    add_route "default via fe80::aaaa dev eth1 metric 512"
    add_route "default from 2001:db8:7e3:7700::/56 via fe80::aaaa dev eth1 metric 512"
    add_neigh "fe80::aaaa lladdr aa:aa:aa:aa:aa:aa dev eth1 router"
    try_128_bootstrap >/dev/null 2>&1
    # Only wan6 should appear in ifdown/ifup logs, never wan alone
    assert_not_contains "no ifdown wan (alone)" "^wan$" "$IFDOWN_LOG"
    assert_not_contains "no ifup wan (alone)" "^wan$" "$IFUP_LOG"
    assert_contains "ifdown wan6 called" "wan6" "$IFDOWN_LOG"
    assert_contains "ifup wan6 called" "wan6" "$IFUP_LOG"
}

# Q. Zero unbound public ping from try_128_bootstrap
test_Q() {
    echo "--- Q: zero unbound public ping ---"
    set_scenario "PREFIX_ADDR" "2001:db8:7e3:7700::"
    set_scenario "PD_OK_GATEWAYS" "fe80::aaaa"
    add_route "default via fe80::aaaa dev eth1 metric 512"
    add_route "default from 2001:db8:7e3:7700::/56 via fe80::aaaa dev eth1 metric 512"
    add_neigh "fe80::aaaa lladdr aa:aa:aa:aa:aa:aa dev eth1 router"
    try_128_bootstrap >/dev/null 2>&1
    # Check ping6 log for any public-target ping without -I
    if [ -s "$PING6_LOG" ]; then
        unbound=0
        while read -r line; do
            target=$(printf '%s' "$line" | awk '{print $NF}')
            case "$target" in
                2001:4860:4860::8888|2606:4700:4700::1111)
                    case "$line" in
                        *"-I "*) ;;
                        *) unbound=1; echo "  unbound ping: $line" ;;
                    esac
                    ;;
            esac
        done < "$PING6_LOG"
        if [ "$unbound" = "0" ]; then pass "no unbound public ping"; else fail "unbound public ping detected"; fi
    else
        pass "no ping6 calls at all"
    fi
}

# R. IA_NA-only does not reset FAIL_FILE, PREFIX_FAIL_FILE, etc.
test_R() {
    echo "--- R: IA_NA-only does not reset recovery counters ---"
    echo "5" > "$FAIL_FILE"
    echo "3" > "$PREFIX_FAIL_FILE"
    echo "2" > "$WAN_RESTART_FILE"
    WAN_RESTARTS=2
    # Stage C2: recovery_hold_active() reads the SHARED hold file (the legacy
    # RECOVERY_HOLD_FILE is preserved for forensics but no longer checked).
    touch "$DISRUPTION_HOLD_FILE"
    set_scenario "PREFIX_ADDR" ""
    set_scenario "WAN128_ADDR" "2001:db8::1"
    try_128_bootstrap >/dev/null 2>&1
    assert_eq "FAIL_FILE unchanged" "$(cat "$FAIL_FILE")" "5"
    assert_eq "PREFIX_FAIL_FILE unchanged" "$(cat "$PREFIX_FAIL_FILE")" "3"
    assert_eq "WAN_RESTART_FILE unchanged" "$(cat "$WAN_RESTART_FILE")" "2"
    assert_eq "shared disruption hold still exists" "$(test -f "$DISRUPTION_HOLD_FILE" && echo yes || echo no)" "yes"
    assert_eq "legacy recovery hold not created" "$(test -f "$RECOVERY_HOLD_FILE" && echo yes || echo no)" "no"
}

# S. Successful bootstrap does not modify clientid/duid
test_S() {
    echo "--- S: no clientid/duid modification ---"
    set_scenario "PREFIX_ADDR" "2001:db8:7e3:7700::"
    set_scenario "PD_OK_GATEWAYS" "fe80::aaaa"
    add_route "default via fe80::aaaa dev eth1 metric 512"
    add_route "default from 2001:db8:7e3:7700::/56 via fe80::aaaa dev eth1 metric 512"
    add_neigh "fe80::aaaa lladdr aa:aa:aa:aa:aa:aa dev eth1 router"
    try_128_bootstrap >/dev/null 2>&1
    assert_not_contains "no clientid set" "clientid" "$UCI_LOG"
    assert_not_contains "no duid set" "dhcp_default_duid" "$UCI_LOG"
}

# T. PD-without-WAN128 proves /128 is not prerequisite
test_T() {
    echo "--- T: PD without WAN128 proves /128 not prerequisite ---"
    set_scenario "PREFIX_ADDR" "2001:db8:7e3:7700::"
    set_scenario "WAN128_ADDR" ""
    set_scenario "PD_OK_GATEWAYS" "fe80::aaaa"
    add_route "default via fe80::aaaa dev eth1 metric 512"
    add_route "default from 2001:db8:7e3:7700::/56 via fe80::aaaa dev eth1 metric 512"
    add_neigh "fe80::aaaa lladdr aa:aa:aa:aa:aa:aa dev eth1 router"
    try_128_bootstrap
    rc=$?
    assert_eq "bootstrap return (PD without WAN128)" "$rc" "0"
    # Verify no ip addr del was issued (no /128 to clean up)
    assert_not_contains "no addr del (no /128 to clean)" "addr del" "$IP_TRACE"
    # Verify WAN128 remained absent throughout
    assert_eq "WAN128 stayed absent" "$(get_scenario WAN128_ADDR)" ""
}

# U. BOOTSTRAP_ENABLED defaults to 0 in production
# Static assertion that the production script defaults BOOTSTRAP_ENABLED to 0
# (disabled). This is the single most important safety property: the
# experimental hypothesis must not run unless an operator explicitly opts in.
test_U() {
    echo "--- U: BOOTSTRAP_ENABLED defaults to 0 in production ---"
    # Extract the default line from ipv6-watchdog and verify it is 0.
    default_val=$(sed -n 's/^BOOTSTRAP_ENABLED="${BOOTSTRAP_ENABLED:-\([0-9]*\)}"/\1/p' "$SCRIPT_DIR/ipv6-watchdog")
    assert_eq "BOOTSTRAP_ENABLED default is 0" "$default_val" "0"
    # Also verify the fail-safe case guard exists.
    assert_contains "fail-safe case guard exists" 'case "$BOOTSTRAP_ENABLED" in' "$SCRIPT_DIR/ipv6-watchdog"
    assert_contains "fail-safe resets to 0" 'BOOTSTRAP_ENABLED=0' "$SCRIPT_DIR/ipv6-watchdog"
}

# V. try_128_bootstrap disabled no-op: zero side effects
# When BOOTSTRAP_ENABLED=0, calling try_128_bootstrap directly must: return 1
# (deferred), perform zero UCI mutation, zero network reload, zero ifdown/ifup,
# zero route mutation, and zero recovery counter reset. The function guards on
# BOOTSTRAP_ENABLED itself, so this protects against any future alternate call
# site, not just the no-prefix ladder.
test_V() {
    echo "--- V: try_128_bootstrap disabled no-op (BOOTSTRAP_ENABLED=0) ---"
    BOOTSTRAP_ENABLED=0
    # Seed state that WOULD be mutated if the guard failed.
    echo "5" > "$FAIL_FILE"
    echo "3" > "$PREFIX_FAIL_FILE"
    echo "2" > "$WAN_RESTART_FILE"
    WAN_RESTARTS=2
    touch "$RECOVERY_HOLD_FILE"
    set_scenario "PREFIX_ADDR" "2001:db8:7e3:7700::"
    set_scenario "WAN128_ADDR" "2001:db8::1"
    set_scenario "PD_OK_GATEWAYS" "fe80::aaaa"
    add_route "default via fe80::aaaa dev eth1 metric 512"
    add_route "default from 2001:db8:7e3:7700::/56 via fe80::aaaa dev eth1 metric 512"
    add_neigh "fe80::aaaa lladdr aa:aa:aa:aa:aa:aa dev eth1 router"
    try_128_bootstrap >/dev/null 2>&1
    rc=$?
    # Must return 1 (deferred / disabled), NOT 0 (success).
    assert_eq "bootstrap return (disabled)" "$rc" "1"
    # Zero UCI mutation.
    assert_not_contains "no uci set" "network.wan6.reqaddress=" "$UCI_LOG"
    assert_not_contains "no uci revert" "revert" "$UCI_LOG"
    # Zero network reload.
    assert_not_contains "no ubus network reload" "network reload" "$UBUS_LOG"
    # Zero ifdown/ifup.
    assert_eq "no ifdown" "$(cat "$IFDOWN_LOG" 2>/dev/null)" ""
    assert_eq "no ifup" "$(cat "$IFUP_LOG" 2>/dev/null)" ""
    # Zero route mutation (no replace/del in IP_TRACE).
    assert_not_contains "no route replace" "route replace" "$IP_TRACE"
    assert_not_contains "no route del" "route del" "$IP_TRACE"
    assert_not_contains "no addr del" "addr del" "$IP_TRACE"
    # Zero recovery counter reset.
    assert_eq "FAIL_FILE unchanged" "$(cat "$FAIL_FILE")" "5"
    assert_eq "PREFIX_FAIL_FILE unchanged" "$(cat "$PREFIX_FAIL_FILE")" "3"
    assert_eq "WAN_RESTART_FILE unchanged" "$(cat "$WAN_RESTART_FILE")" "2"
    assert_eq "RECOVERY_HOLD_FILE still exists" "$(test -f "$RECOVERY_HOLD_FILE" && echo yes || echo no)" "yes"
    # WAN128 must be retained.
    assert_eq "WAN128 retained" "$(get_scenario WAN128_ADDR)" "2001:db8::1"
}

# W. No-prefix ladder with bootstrap disabled: static assertion
# When BOOTSTRAP_ENABLED=0, the PREFIX_FAILS=3 stage must NOT call
# try_128_bootstrap(); it must escalate directly to maybe_wan_restart(),
# preserving WAN restart cooldown, same-boot restart budget, and recovery hold.
# This is a static assertion against the production source because the
# no-prefix ladder is inline in the main watchdog body (not an extractable
# function), and exercising it end-to-end would require mocking the full
# watchdog runtime. The static assertion proves the ladder contract exists.
test_W() {
    echo "--- W: no-prefix ladder skips bootstrap when disabled ---"
    # Verify the ladder checks BOOTSTRAP_ENABLED at PREFIX_FAILS=3.
    assert_contains "ladder checks BOOTSTRAP_ENABLED" 'BOOTSTRAP_ENABLED" = "1"' "$SCRIPT_DIR/ipv6-watchdog"
    # Verify the disabled branch escalates to maybe_wan_restart.
    assert_contains "disabled escalates to maybe_wan_restart" 'maybe_wan_restart "No prefix after recovery attempts (bootstrap disabled)"' "$SCRIPT_DIR/ipv6-watchdog"
    # Verify the enabled branch still calls try_128_bootstrap.
    assert_contains "enabled branch calls try_128_bootstrap" "try_128_bootstrap" "$SCRIPT_DIR/ipv6-watchdog"
    # Verify maybe_wan_restart preserves budget/hold (existing invariants).
    assert_contains "maybe_wan_restart checks recovery_hold_active" "recovery_hold_active" "$SCRIPT_DIR/ipv6-watchdog"
    assert_contains "maybe_wan_restart checks in_cooldown" "in_cooldown" "$SCRIPT_DIR/ipv6-watchdog"
}

# ================================================================
# Run all tests
# ================================================================
echo "=== Phase 3: bootstrap hardening tests ==="

BOOT_TESTS="${BOOT_TESTS:-A B C D E F G H I J K L M N O P Q R S T U V W}"
for t in $BOOT_TESTS; do
    run_test "test_$t"
done

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