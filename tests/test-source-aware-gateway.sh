#!/bin/sh
# tests/test-source-aware-gateway.sh
#
# Phase 2: source-aware PLDT gateway selection. Tests the ACTUAL production
# fix_gateway(), keep_gateway(), pd_routes_ok(), snapshot/rollback, and
# install_gw_routes() helpers extracted from ipv6-watchdog. Mocks ip, ping6,
# ubus, and jsonfilter so the test harness never touches a real network.
#
# The decisive acceptance test is pd_internet_ok (sourced from LAN_PD_SRC).
# WAN128 must never influence candidate acceptance, and no unbound external
# ping is permitted in the gateway path (link-local NDP discovery is exempt).
#
# Usage: sh tests/test-source-aware-gateway.sh
# Exit:  0 = all pass, 1 = any fail

TEST_SCRIPT="$0"
SCRIPT_DIR="$(cd "$(dirname "$TEST_SCRIPT")/.." && pwd)"
# Repository-local test root (gitignored). Never uses /tmp or D:\tmp.
TEST_BASE="$SCRIPT_DIR/.test-tmp"
TEST_ROOT="$TEST_BASE/gateway-test-$$"
mkdir -p "$TEST_ROOT"

cleanup() { rm -rf "$TEST_ROOT"; }
trap cleanup EXIT
trap 'cleanup; exit 130' INT
trap 'cleanup; exit 143' TERM

PASS=0
FAIL=0

# ================================================================
# Extract production helpers from ipv6-watchdog.
# Range: has_prefix() through the end of wan128_internet_ok(). Captures
# every helper used by fix_gateway / keep_gateway including
# populate_pd_context, pd_internet_ok, pd_routes_ok, snapshot/rollback,
# install_gw_routes, current_default_gw, gateway_mac.
# ================================================================

EXTRACT="$TEST_ROOT/helpers.sh"

awk '
/^has_prefix\(\)/ { start=1 }
start { print }
start && /^fix_gateway\(\)/ { saw_fix=1 }
saw_fix && /^}/ { start=0; saw_fix=0 }
' "$SCRIPT_DIR/ipv6-watchdog" > "$EXTRACT"

# Sanity: the extract must contain our key gateway functions.
for fn in fix_gateway keep_gateway pd_routes_ok install_gw_routes \
          snapshot_default_routes restore_route_snapshot clear_default_routes \
          pd_internet_ok populate_pd_context current_default_gw gateway_mac; do
    if ! grep -q "^${fn}()" "$EXTRACT"; then
        echo "FATAL: could not extract $fn from ipv6-watchdog" >&2
        exit 2
    fi
done

# log() stub: append to a shared log file we can inspect.
WATCHDOG_LOG="$TEST_ROOT/watchdog.log"
: > "$WATCHDOG_LOG"
printf 'log() { echo "$1" >> "%s"; }\n' "$WATCHDOG_LOG" > "$TEST_ROOT/preamble.sh"

# Source the extracted helpers. The helpers reference several globals
# (WAN_DEV, PD_CIDR, LAN_PD_SRC, PD_ADDR, PD_MASK, GOOD_GW_FILE,
# STATE_DIR, STICKY_GATEWAY) which each test sets up explicitly. We provide
# minimal defaults here so sourcing does not fail.
STATE_DIR="$TEST_ROOT/state"
mkdir -p "$STATE_DIR"
GOOD_GW_FILE="$STATE_DIR/good_gateway"
STICKY_GATEWAY="${STICKY_GATEWAY:-1}"
WAN6_PENDING_GRACE=180
WAN6_PENDING_SEEN_FILE="$STATE_DIR/wan6_pending_seen"
WAN6_PENDING_EXPIRED_FILE="$STATE_DIR/wan6_pending_expired"
ROUTE_SNAPSHOT_FILE=""
LAN_DEV="br-lan"
CLEANUP_DEPRECATED_LAN=0
REACHABILITY_CONFIRM_DELAY=0

# shellcheck disable=SC1090
. "$TEST_ROOT/preamble.sh"
# shellcheck disable=SC1090
. "$EXTRACT"

# ================================================================
# Mock framework
# ================================================================
# Each test builds a fresh stub directory on PATH containing mock `ip`,
# `ping6`, `ubus`, `jsonfilter`, `sleep`. The mocks read a scenario config
# file describing route table, neighbor table, and ping outcomes.

MOCK_DIR="$TEST_ROOT/mock"
mkdir -p "$MOCK_DIR"
SCENARIO="$TEST_ROOT/scenario"
export SCENARIO

# Default scenario values; reset per test.
# Gateway-aware PD connectivity model (Phase 2B):
#   PD_OK_GATEWAYS  space-separated list of link-local gateways that forward
#                  PD-sourced traffic to the internet. The mock ping6 derives
#                  the current active PD gateway from the mocked ROUTES file
#                  (generic default + source-specific default from PD_CIDR)
#                  and succeeds ONLY when both routes exist, both point at the
#                  same gateway, and that gateway is in PD_OK_GATEWAYS.
#   PD_PING_OK      legacy all-or-nothing fallback, used ONLY when
#                  PD_OK_GATEWAYS is unset/empty. Kept so non-gateway tests
#                  (e.g. snapshot unit test L) can force pd_internet_ok without
#                  modeling per-gateway forwarding.
reset_scenario() {
    : > "$SCENARIO"
    printf 'ROUTES=\n' >> "$SCENARIO"
    printf 'NEIGH=\n' >> "$SCENARIO"
    printf 'PD_PREFIX_ADDR=2001:db8:7e3:7700::\n' >> "$SCENARIO"
    printf 'PD_PREFIX_MASK=56\n' >> "$SCENARIO"
    printf 'WAN_L3_DEVICE=eth1\n' >> "$SCENARIO"
    printf 'LAN_SRC=2001:db8:7e3:7700:abcd::1\n' >> "$SCENARIO"
    printf 'WAN128=\n' >> "$SCENARIO"
    printf 'PD_OK_GATEWAYS=\n' >> "$SCENARIO"   # space-separated gateways that forward PD traffic
    printf 'PD_PING_OK=0\n' >> "$SCENARIO"      # legacy fallback only (unused when PD_OK_GATEWAYS set)
    printf 'WAN128_PING_OK=0\n' >> "$SCENARIO"  # 1 = wan128 ping succeeds (must NOT influence)
    printf 'UNBOUND_PING_OK=0\n' >> "$SCENARIO" # 1 = unbound ping6 to public succeeds
    printf 'PING6_LOG=\n' >> "$SCENARIO"        # path to ping6 call log
    printf 'IP_LOG=\n' >> "$SCENARIO"            # path to ip call log
    printf 'NDP_PROBE_OK=1\n' >> "$SCENARIO"    # ff02::2 probe allowed
    : > "$WATCHDOG_LOG"
    rm -f "$GOOD_GW_FILE"
    rm -f "$STATE_DIR"/fix_gateway_routes.* 2>/dev/null
    rm -f "$STATE_DIR"/keep_gateway_routes.* 2>/dev/null
}

# Set a scenario key=value pair, REPLACING any existing entry for the key so
# the scenario file always contains exactly one value per key. BusyBox/POSIX
# compatible: uses a temporary file then mv it back. reset_scenario() writes
# initial default values; set_scenario() must override those defaults rather
# than append duplicates (the mock readers select the FIRST match, so a stale
# empty default would otherwise shadow the real override).
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

# Build the mock binaries once; they read $SCENARIO at call time.
build_mocks() {
cat > "$MOCK_DIR/ip" <<'EOF'
#!/bin/sh
# Mock ip. Implements `route show`, `route replace`, `route del`, `neigh show`,
# `neigh replace`, and `addr show` for the gateway tests using a ROUTES_FILE
# and NEIGH_FILE described by the scenario.
SCEN="${SCENARIO:-/dev/null}"
ROUTES_FILE=$(sed -n 's/^ROUTES=//p' "$SCEN" | head -1)
NEIGH_FILE=$(sed -n 's/^NEIGH=//p' "$SCEN" | head -1)
IP_LOG=$(sed -n 's/^IP_LOG=//p' "$SCEN" | head -1)
[ -n "$IP_LOG" ] && echo "ip $*" >> "$IP_LOG"

case "$2" in
    route)
        case "$3" in
            show)
                # ip -6 route show default dev WAN_DEV
                # or: ip -6 route show default from X dev WAN_DEV
                dev=""
                from=""
                rest=""
                shift 3
                while [ $# -gt 0 ]; do
                    case "$1" in
                        default) ;;
                        dev) dev="$2"; shift ;;
                        from) from="$2"; shift ;;
                        *) rest="$rest $1" ;;
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
                # ip -6 route replace <spec...> -- append/replace in ROUTES_FILE
                spec="$4"
                shift 4
                while [ $# -gt 0 ]; do
                    spec="$spec $1"
                    shift
                done
                # Extract key fields for dedup: from + via + dev
                key_from=$(printf '%s\n' "$spec" | awk '{for(i=1;i<=NF;i++) if($i=="from"){print $(i+1); exit}}')
                key_via=$(printf '%s\n' "$spec" | awk '{for(i=1;i<=NF;i++) if($i=="via"){print $(i+1); exit}}')
                key_dev=$(printf '%s\n' "$spec" | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}')
                if [ -n "$key_from" ]; then
                    # Remove existing source-specific route with same from/dev
                    grep -v "^default from $key_from .*dev $key_dev" "$ROUTES_FILE" 2>/dev/null > "$ROUTES_FILE.tmp"
                    mv "$ROUTES_FILE.tmp" "$ROUTES_FILE" 2>/dev/null
                elif [ -n "$key_via" ]; then
                    # Remove existing generic default with same dev (no from)
                    grep -v "^default via .*dev $key_dev" "$ROUTES_FILE" 2>/dev/null > "$ROUTES_FILE.tmp"
                    mv "$ROUTES_FILE.tmp" "$ROUTES_FILE" 2>/dev/null
                fi
                printf '%s\n' "$spec" >> "$ROUTES_FILE"
                ;;
            del)
                # ip -6 route del <spec...>
                spec="$4"
                shift 4
                while [ $# -gt 0 ]; do
                    spec="$spec $1"
                    shift
                done
                # Remove matching line(s)
                grep -v "^$(printf '%s' "$spec" | sed 's/[][\\.*+?(){}|^$]/\\&/g')\$" "$ROUTES_FILE" 2>/dev/null > "$ROUTES_FILE.tmp"
                mv "$ROUTES_FILE.tmp" "$ROUTES_FILE" 2>/dev/null
                ;;
            *) ;;
        esac
        ;;
    neigh)
        case "$3" in
            show)
                # ip -6 neigh show dev WAN_DEV -> print neighbors for that dev
                dev="$5"
                if [ -n "$dev" ]; then
                    awk -v d="$dev" '$0 ~ "dev "d {print}' "$NEIGH_FILE" 2>/dev/null
                else
                    cat "$NEIGH_FILE" 2>/dev/null
                fi
                ;;
            replace)
                # ip -6 neigh replace GW lladdr MAC dev WAN_DEV nud stale
                # Record into NEIGH_FILE (dedup by gw).
                gw="$5"
                mac="$7"
                dev="$9"
                grep -v "^$gw " "$NEIGH_FILE" 2>/dev/null > "$NEIGH_FILE.tmp"
                mv "$NEIGH_FILE.tmp" "$NEIGH_FILE" 2>/dev/null
                printf '%s lladdr %s dev %s router\n' "$gw" "$mac" "$dev" >> "$NEIGH_FILE"
                ;;
            *) ;;
        esac
        ;;
    addr)
        # ip -6 addr show dev LAN_DEV [deprecated] -> emit one LAN_PD_SRC
        # address line that get_lan_pd_src() can parse. The LAN source is
        # controlled by the LAN_SRC scenario key.
        lan_src=$(sed -n 's/^LAN_SRC=//p' "$SCEN" | head -1)
        if [ -n "$lan_src" ]; then
            printf 'inet6 %s/64 scope global dynamic\n' "$lan_src"
            printf '   valid_lft 86400sec preferred_lft 14400sec\n'
        fi
        ;;
    *) ;;
esac
exit 0
EOF
chmod +x "$MOCK_DIR/ip"

cat > "$MOCK_DIR/ping6" <<'EOF'
#!/bin/sh
# Mock ping6. Gateway-aware PD connectivity model (Phase 2B).
#
# For a sourced public IPv6 ping (-I LAN_PD_SRC <public target>):
#   1. Read the current generic default gateway from the mocked ROUTES file
#      (line matching '^default via <gw> dev <dev>').
#   2. Read the current source-specific default gateway for PD_CIDR
#      (line matching '^default from <PD_CIDR> via <gw> dev <dev>').
#   3. The PD ping succeeds ONLY when:
#        - both routes exist
#        - both point at the same gateway
#        - that gateway is listed in PD_OK_GATEWAYS
#      If PD_OK_GATEWAYS is unset/empty, fall back to the legacy PD_PING_OK
#      flag so non-gateway unit tests can force success.
# WAN128-sourced pings use WAN128_PING_OK (never influences PD candidates).
# Unbound pings use UNBOUND_PING_OK.
# Link-local/ff02::2 NDP probes use NDP_PROBE_OK.
SCEN="${SCENARIO:-/dev/null}"
PD_OK_GATEWAYS=$(sed -n 's/^PD_OK_GATEWAYS=//p' "$SCEN" | head -1)
PD_PING_OK=$(sed -n 's/^PD_PING_OK=//p' "$SCEN" | head -1)
WAN128_PING_OK=$(sed -n 's/^WAN128_PING_OK=//p' "$SCEN" | head -1)
UNBOUND_PING_OK=$(sed -n 's/^UNBOUND_PING_OK=//p' "$SCEN" | head -1)
NDP_PROBE_OK=$(sed -n 's/^NDP_PROBE_OK=//p' "$SCEN" | head -1)
PING6_LOG=$(sed -n 's/^PING6_LOG=//p' "$SCEN" | head -1)
ROUTES_FILE=$(sed -n 's/^ROUTES=//p' "$SCEN" | head -1)
PD_CIDR=$(sed -n 's/^PD_PREFIX_ADDR=//p' "$SCEN" | head -1)/$(sed -n 's/^PD_PREFIX_MASK=//p' "$SCEN" | head -1)
WAN128=$(sed -n 's/^WAN128=//p' "$SCEN" | head -1)
[ -n "$PING6_LOG" ] && echo "$@" >> "$PING6_LOG"

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
        [ "$NDP_PROBE_OK" = "1" ] && exit 0 || exit 1
        ;;
    2001:4860:4860::8888|2606:4700:4700::1111)
        if [ -n "$src" ]; then
            # WAN128-sourced ping is separate and never influences PD.
            if [ -n "$WAN128" ] && [ "$src" = "$WAN128" ]; then
                [ "$WAN128_PING_OK" = "1" ] && exit 0 || exit 1
            fi
            # PD-sourced ping: gateway-aware model.
            if [ -n "$PD_OK_GATEWAYS" ]; then
                # Derive current generic default gateway from ROUTES_FILE.
                gen_gw=$(grep '^default via ' "$ROUTES_FILE" 2>/dev/null \
                    | awk '{for(i=1;i<=NF;i++) if($i=="via"){print $(i+1); exit}}' | head -1)
                # Derive current source-specific default gateway for PD_CIDR.
                src_gw=$(grep "^default from $PD_CIDR via " "$ROUTES_FILE" 2>/dev/null \
                    | awk '{for(i=1;i<=NF;i++) if($i=="via"){print $(i+1); exit}}' | head -1)
                # Both must exist and agree.
                [ -n "$gen_gw" ] || exit 1
                [ -n "$src_gw" ] || exit 1
                [ "$gen_gw" = "$src_gw" ] || exit 1
                # Current gateway must be in PD_OK_GATEWAYS.
                for ok in $PD_OK_GATEWAYS; do
                    [ "$ok" = "$gen_gw" ] && exit 0
                done
                exit 1
            else
                # Legacy fallback for non-gateway unit tests.
                [ "$PD_PING_OK" = "1" ] && exit 0 || exit 1
            fi
        else
            [ "$UNBOUND_PING_OK" = "1" ] && exit 0 || exit 1
        fi
        ;;
    *)
        # Link-local gateway ping (gateway_mac uses ping6 -I WAN_DEV <gw>).
        exit 0
        ;;
esac
EOF
chmod +x "$MOCK_DIR/ping6"

cat > "$MOCK_DIR/ubus" <<'EOF'
#!/bin/sh
# Mock ubus call network.interface.wan6 status -> emit JSON the mock
# jsonfilter parses. We emit a compact JSON with the scenario-controlled
# fields. The mock jsonfilter below ignores most of it.
SCEN="${SCENARIO:-/dev/null}"
PD_ADDR=$(sed -n 's/^PD_PREFIX_ADDR=//p' "$SCEN" | head -1)
PD_MASK=$(sed -n 's/^PD_PREFIX_MASK=//p' "$SCEN" | head -1)
L3=$(sed -n 's/^WAN_L3_DEVICE=//p' "$SCEN" | head -1)
# If PD_ADDR empty, emit prefix array empty.
if [ -n "$PD_ADDR" ]; then
    printf '{"up":true,"pending":false,"l3_device":"%s","ipv6-prefix":[{"address":"%s","mask":%s}]}' "$L3" "$PD_ADDR" "$PD_MASK"
else
    printf '{"up":true,"pending":false,"l3_device":"%s","ipv6-prefix":[]}' "$L3"
fi
EOF
chmod +x "$MOCK_DIR/ubus"

cat > "$MOCK_DIR/jsonfilter" <<'EOF'
#!/bin/sh
# Mock jsonfilter. Reads the ubus JSON from stdin and extracts -e '@[...]'
# expressions for the fields the helpers use.
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
        # grep -q . semantics: print nothing if no match.
        printf '%s' "$input" | sed -n 's/.*"ipv6-prefix":\[{"address":"\([^"]*\)".*/\1/p'
        ;;
esac
EOF
chmod +x "$MOCK_DIR/jsonfilter"

cat > "$MOCK_DIR/sleep" <<'EOF'
#!/bin/sh
: # no-op sleep for tests
EOF
chmod +x "$MOCK_DIR/sleep"
}

build_mocks

# --- Mock isolation guard ---------------------------------------------------
# build_mocks() creates every mock up front into a MOCK_DIR that never changes,
# and every test runs after this point, so one enforcement call covers the whole
# suite. ip, ping6 and sleep are BusyBox applets and would otherwise be resolved
# ahead of PATH under `busybox ash`. See tests/lib/mock-isolation.sh.
. "$SCRIPT_DIR/tests/lib/mock-isolation.sh"
mock_isolation_enforce MOCK_DIR "ip ping6 sleep ubus jsonfilter"

# Per-test setup: prepare a fresh route table and neigh table files, and
# run a test body with PATH pointing at the mocks.
# Usage: run_test <name> <body-fn>
run_test() {
    name="$1"
    ROUTES_FILE="$TEST_ROOT/routes_$$.txt"
    NEIGH_FILE="$TEST_ROOT/neigh_$$.txt"
    PING6_LOG="$TEST_ROOT/ping6_$$.log"
    IP_LOG="$TEST_ROOT/ip_$$.log"
    : > "$ROUTES_FILE"
    : > "$NEIGH_FILE"
    : > "$PING6_LOG"
    : > "$IP_LOG"
    reset_scenario
    set_scenario "ROUTES" "$ROUTES_FILE"
    set_scenario "NEIGH" "$NEIGH_FILE"
    set_scenario "PING6_LOG" "$PING6_LOG"
    set_scenario "IP_LOG" "$IP_LOG"
    # Run the body with mocks on PATH.
    PATH="$MOCK_DIR:$ORIG_PATH" "$name"
    rc=$?
    # Cleanup per-test files.
    rm -f "$ROUTES_FILE" "$NEIGH_FILE" "$PING6_LOG" "$IP_LOG" 2>/dev/null
    rm -f "$STATE_DIR"/fix_gateway_routes.* 2>/dev/null
    rm -f "$STATE_DIR"/keep_gateway_routes.* 2>/dev/null
    return $rc
}

# Helpers to populate route/neigh tables.
add_route() { printf '%s\n' "$1" >> "$ROUTES_FILE"; }
add_neigh() { printf '%s\n' "$1" >> "$NEIGH_FILE"; }

# Assertion helpers.
pass() { PASS=$((PASS + 1)); echo "  PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); echo "  FAIL: $1"; }
assert_eq() {
    if [ "$2" = "$3" ]; then pass "$1 ($2)"; else fail "$1 (expected '$3', got '$2')"; fi
}
assert_contains() {
    if grep -q "$2" "$3"; then pass "$1"; else fail "$1 (no match for '$2' in $3)"; fi
}
assert_not_contains() {
    if grep -q "$2" "$3"; then fail "$1 (found '$2' in $3)"; else pass "$1"; fi
}

PD_CIDR="2001:db8:7e3:7700::/56"
PD_ADDR="2001:db8:7e3:7700::"
PD_MASK="56"
LAN_PD_SRC="2001:db8:7e3:7700:abcd::1"
WAN_DEV="eth1"
WAN128=""
ORIG_PATH="$PATH"

# ================================================================
# A. Correct generic + correct PD route + PD ping works -> fast path, no churn
# ================================================================
test_A() {
    echo "--- A: correct generic + PD route + PD ping -> fast path ---"
    add_route "default via fe80::aaaa dev eth1 metric 512"
    add_route "default from 2001:db8:7e3:7700::/56 via fe80::aaaa dev eth1 metric 512"
    add_neigh "fe80::aaaa lladdr aa:aa:aa:aa:aa:aa dev eth1 router"
    set_scenario "PD_OK_GATEWAYS" "fe80::aaaa"
    fix_gateway
    rc=$?
    assert_eq "fix_gateway return" "$rc" "0"
    # Fast path: no candidate scan, so no ip route replace for fe80::bbbb.
    assert_not_contains "no candidate route churn" "fe80::bbbb" "$ROUTES_FILE"
    assert_eq "GOOD_GW_FILE" "$(cat "$GOOD_GW_FILE" 2>/dev/null)" "fe80::aaaa"
}

# ================================================================
# B. Generic on A but PD source-specific on B (incoherent) -> only B wins
# ================================================================
# Starting state: generic default via A, source-specific default via B.
# This is incoherent: the two default routes point at different gateways.
# Only B forwards PD traffic. The fast path must reject the incoherent state;
# candidate A must be tested and rejected; candidate B must be tested and
# accepted. Final routes must both point at B.
test_B() {
    echo "--- B: generic via A but PD via B (incoherent) -> only B wins ---"
    add_route "default via fe80::aaaa dev eth1 metric 512"
    add_route "default from 2001:db8:7e3:7700::/56 via fe80::bbbb dev eth1 metric 512"
    add_neigh "fe80::aaaa lladdr aa:aa:aa:aa:aa:aa dev eth1 router"
    add_neigh "fe80::bbbb lladdr bb:bb:bb:bb:bb:bb dev eth1 router"
    set_scenario "PD_OK_GATEWAYS" "fe80::bbbb"
    fix_gateway
    rc=$?
    assert_eq "fix_gateway return" "$rc" "0"
    assert_contains "generic via b" "default via fe80::bbbb" "$ROUTES_FILE"
    assert_contains "PD route via b" "default from 2001:db8:7e3:7700::/56 via fe80::bbbb" "$ROUTES_FILE"
    assert_not_contains "no generic via a" "default via fe80::aaaa" "$ROUTES_FILE"
}

# ================================================================
# C. Gateway A locally reachable but no PD internet -> rejected, no fallback
# ================================================================
# A is the only gateway. A is locally reachable (NDP ok) but does not forward
# PD traffic. PD_OK_GATEWAYS is empty, so no candidate can pass pd_internet_ok.
# fix_gateway must fail and restore the original snapshot.
test_C() {
    echo "--- C: A locally reachable but PD fails -> rejected ---"
    add_route "default via fe80::aaaa dev eth1 metric 512"
    add_route "default from 2001:db8:7e3:7700::/56 via fe80::aaaa dev eth1 metric 512"
    add_neigh "fe80::aaaa lladdr aa:aa:aa:aa:aa:aa dev eth1 router"
    add_neigh "fe80::bbbb lladdr bb:bb:bb:bb:bb:bb dev eth1 router"
    set_scenario "PD_OK_GATEWAYS" ""
    fix_gateway
    rc=$?
    assert_eq "fix_gateway return (all fail)" "$rc" "1"
}

# ================================================================
# D. A fails PD forwarding, B succeeds -> B selected (both are candidates)
# ================================================================
# Both A and B are present in the neighbor table AND the route table starts
# with both routes via A. Production candidate discovery merges neigh and
# route-table gateways, so A MUST be tested first and rejected, then B tested
# and accepted. We do NOT remove A from candidate discovery.
test_D() {
    echo "--- D: A fails PD, B succeeds -> B selected (A tested, rejected) ---"
    add_route "default via fe80::aaaa dev eth1 metric 512"
    add_route "default from 2001:db8:7e3:7700::/56 via fe80::aaaa dev eth1 metric 512"
    add_neigh "fe80::aaaa lladdr aa:aa:aa:aa:aa:aa dev eth1 router"
    add_neigh "fe80::bbbb lladdr bb:bb:bb:bb:bb:bb dev eth1 router"
    set_scenario "PD_OK_GATEWAYS" "fe80::bbbb"
    fix_gateway
    rc=$?
    assert_eq "fix_gateway return" "$rc" "0"
    assert_contains "generic via b" "default via fe80::bbbb" "$ROUTES_FILE"
    assert_contains "PD route via b" "default from 2001:db8:7e3:7700::/56 via fe80::bbbb" "$ROUTES_FILE"
    assert_eq "GOOD_GW_FILE" "$(cat "$GOOD_GW_FILE" 2>/dev/null)" "fe80::bbbb"
}

# ================================================================
# E. Successful final route state: generic + PD via B (exact line forms)
# ================================================================
# Both A and B are candidates. A fails PD, B succeeds. Assert the exact final
# route line forms after B is selected.
test_E() {
    echo "--- E: final route state generic + PD via b ---"
    add_route "default via fe80::aaaa dev eth1 metric 512"
    add_route "default from 2001:db8:7e3:7700::/56 via fe80::aaaa dev eth1 metric 512"
    add_neigh "fe80::aaaa lladdr aa:aa:aa:aa:aa:aa dev eth1 router"
    add_neigh "fe80::bbbb lladdr bb:bb:bb:bb:bb:bb dev eth1 router"
    set_scenario "PD_OK_GATEWAYS" "fe80::bbbb"
    fix_gateway
    assert_contains "generic default via b" "^default via fe80::bbbb dev eth1" "$ROUTES_FILE"
    assert_contains "PD source-specific via b" "default from 2001:db8:7e3:7700::/56 via fe80::bbbb" "$ROUTES_FILE"
}

# ================================================================
# F. GOOD_GW_FILE records B (both A and B are candidates)
# ================================================================
test_F() {
    echo "--- F: GOOD_GW_FILE records b ---"
    add_route "default via fe80::aaaa dev eth1 metric 512"
    add_route "default from 2001:db8:7e3:7700::/56 via fe80::aaaa dev eth1 metric 512"
    add_neigh "fe80::aaaa lladdr aa:aa:aa:aa:aa:aa dev eth1 router"
    add_neigh "fe80::bbbb lladdr bb:bb:bb:bb:bb:bb dev eth1 router"
    set_scenario "PD_OK_GATEWAYS" "fe80::bbbb"
    fix_gateway
    assert_eq "GOOD_GW_FILE" "$(cat "$GOOD_GW_FILE" 2>/dev/null)" "fe80::bbbb"
}

# ================================================================
# S. A-fails/B-succeeds sequence proof (candidate A tested before B)
# ================================================================
# Proves from IP_LOG that candidate A was installed/tested first and failed,
# then candidate B was installed/tested and succeeded. This is the exact PLDT
# failure mode: a dead gateway is locally reachable, the candidate test must
# reject it using PD traffic, and the alternate gateway must be selected.
# A test that merely removes A from candidate discovery does NOT prove this.
test_S() {
    echo "--- S: A-fails/B-succeeds candidate sequence proof ---"
    add_route "default via fe80::aaaa dev eth1 metric 512"
    add_route "default from 2001:db8:7e3:7700::/56 via fe80::aaaa dev eth1 metric 512"
    add_neigh "fe80::aaaa lladdr aa:aa:aa:aa:aa:aa dev eth1 router"
    add_neigh "fe80::bbbb lladdr bb:bb:bb:bb:bb:bb dev eth1 router"
    set_scenario "PD_OK_GATEWAYS" "fe80::bbbb"
    fix_gateway
    rc=$?
    assert_eq "fix_gateway return" "$rc" "0"
    # IP_LOG records every mock ip invocation in order. Candidate install for
    # A must appear before candidate install for B. We look for the
    # `route replace default via <gw>` lines.
    a_line=$(grep -n 'route replace default via fe80::aaaa' "$IP_LOG" 2>/dev/null | head -1 | cut -d: -f1)
    b_line=$(grep -n 'route replace default via fe80::bbbb' "$IP_LOG" 2>/dev/null | head -1 | cut -d: -f1)
    if [ -n "$a_line" ] && [ -n "$b_line" ] && [ "$a_line" -lt "$b_line" ]; then
        pass "candidate A installed before candidate B (IP_LOG lines a=$a_line b=$b_line)"
    else
        fail "candidate order not A-then-B (a_line='$a_line' b_line='$b_line')"
    fi
    # A must have been installed (its route replace recorded) even though it
    # was rejected. This proves A was actually tested, not removed from
    # candidate discovery.
    if [ -n "$a_line" ]; then
        pass "candidate A was installed and tested (not skipped)"
    else
        fail "candidate A was never installed (skipped by discovery)"
    fi
    # B must have been installed and accepted.
    if [ -n "$b_line" ]; then
        pass "candidate B was installed and accepted"
    else
        fail "candidate B was never installed"
    fi
    # Final routes via B.
    assert_contains "final generic via b" "default via fe80::bbbb" "$ROUTES_FILE"
    assert_contains "final PD route via b" "default from 2001:db8:7e3:7700::/56 via fe80::bbbb" "$ROUTES_FILE"
}

# ================================================================
# R. Independent mock route-replace verification
# ================================================================
# Separately verifies the mock `ip route replace` behavior using the SAME
# commands production uses. This disproves (or confirms) any suspicion that
# the mock route replacement itself is broken, independent of the gateway
# selection logic.
test_R() {
    echo "--- R: mock route replace dedup/replace verification ---"
    # Fixture: both routes via A.
    add_route "default via fe80::aaaa dev eth1 metric 512"
    add_route "default from 2001:db8:7e3:7700::/56 via fe80::aaaa dev eth1 metric 512"
    # Invoke the same mocked commands production install_gw_routes uses.
    PATH="$MOCK_DIR:$ORIG_PATH" ip -6 route replace default via fe80::bbbb dev eth1 metric 512
    PATH="$MOCK_DIR:$ORIG_PATH" ip -6 route replace default from 2001:db8:7e3:7700::/56 via fe80::bbbb dev eth1 metric 512
    # Expected: both routes now via B, no A routes remain.
    assert_contains "generic via b" "default via fe80::bbbb dev eth1 metric 512" "$ROUTES_FILE"
    assert_contains "PD route via b" "default from 2001:db8:7e3:7700::/56 via fe80::bbbb dev eth1 metric 512" "$ROUTES_FILE"
    assert_not_contains "no generic A route" "default via fe80::aaaa" "$ROUTES_FILE"
    assert_not_contains "no PD-specific A route" "default from 2001:db8:7e3:7700::/56 via fe80::aaaa" "$ROUTES_FILE"
}

# ================================================================
# G. WAN128 works but PD through A fails -> A rejected, WAN128 no influence
# ================================================================
test_G() {
    echo "--- G: WAN128 works but PD fails -> A rejected ---"
    WAN128="2001:db8::1"
    set_scenario "WAN128" "$WAN128"
    set_scenario "WAN128_PING_OK" "1"
    set_scenario "PD_OK_GATEWAYS" ""
    add_route "default via fe80::aaaa dev eth1 metric 512"
    add_route "default from 2001:db8:7e3:7700::/56 via fe80::aaaa dev eth1 metric 512"
    add_neigh "fe80::aaaa lladdr aa:aa:aa:aa:aa:aa dev eth1 router"
    fix_gateway
    rc=$?
    assert_eq "fix_gateway return (PD fail beats WAN128 ok)" "$rc" "1"
    # WAN128 must not influence acceptance: GOOD_GW_FILE must not be set.
    assert_eq "GOOD_GW_FILE empty" "$(cat "$GOOD_GW_FILE" 2>/dev/null)" ""
    # No unbound ping6 to public targets occurred (only link-local/ff02::2 and
    # sourced pings). Verify ping6 log contains no unbound calls.
    if grep -E 'ping6.*2001:4860:4860::8888|ping6.*2606:4700:4700::1111' "$PING6_LOG" 2>/dev/null | grep -qv '\-I'; then
        fail "unbound ping6 to public target occurred"
    else
        pass "no unbound ping6 to public targets"
    fi
    WAN128=""
}

# ================================================================
# H. No LAN_PD_SRC -> gateway selection refuses, WAN128 no substitute
# ================================================================
test_H() {
    echo "--- H: no LAN_PD_SRC -> defer, no WAN128 fallback ---"
    WAN128="2001:db8::1"
    set_scenario "WAN128" "$WAN128"
    set_scenario "WAN128_PING_OK" "1"
    set_scenario "PD_OK_GATEWAYS" "fe80::aaaa"
    # Simulate no LAN_PD_SRC by making get_lan_pd_src return empty. We do
    # this by clearing the LAN address scenario: set LAN_SRC empty so the
    # mock ip returns no LAN address. Since populate_pd_context calls
    # get_lan_pd_src which uses `ip -6 addr show dev br-lan`, and our mock
    # ip returns nothing for `addr show`, LAN_PD_SRC will be empty.
    # Override LAN_PD_SRC directly post-context by stubbing populate_pd_context.
    # Simpler: set LAN_PD_SRC="" globally and skip populate_pd_context by
    # making it a no-op here. We override the function.
    populate_pd_context() {
        WAN_DEV="eth1"
        PD_ADDR="2001:db8:7e3:7700::"
        PD_MASK="56"
        PD_CIDR="2001:db8:7e3:7700::/56"
        LAN_PD_SRC=""
        WAN128="$WAN128"
    }
    add_route "default via fe80::aaaa dev eth1 metric 512"
    add_route "default from 2001:db8:7e3:7700::/56 via fe80::aaaa dev eth1 metric 512"
    add_neigh "fe80::aaaa lladdr aa:aa:aa:aa:aa:aa dev eth1 router"
    fix_gateway
    rc=$?
    assert_eq "fix_gateway return (no LAN_PD_SRC -> defer)" "$rc" "1"
    assert_eq "GOOD_GW_FILE empty" "$(cat "$GOOD_GW_FILE" 2>/dev/null)" ""
    # Restore real populate_pd_context by re-sourcing the extract.
    # shellcheck disable=SC1091
    . "$EXTRACT"
    WAN128=""
}

# ================================================================
# I. All candidates fail -> original generic AND source-specific restored,
#    no candidate route remains
# ================================================================
test_I() {
    echo "--- I: all candidates fail -> original routes restored ---"
    add_route "default via fe80::aaaa dev eth1 metric 512"
    add_route "default from 2001:db8:7e3:7700::/56 via fe80::aaaa dev eth1 metric 512"
    add_neigh "fe80::aaaa lladdr aa:aa:aa:aa:aa:aa dev eth1 router"
    add_neigh "fe80::bbbb lladdr bb:bb:bb:bb:bb:bb dev eth1 router"
    set_scenario "PD_OK_GATEWAYS" ""
    fix_gateway
    rc=$?
    assert_eq "fix_gateway return (all fail)" "$rc" "1"
    # Original routes must be restored.
    assert_contains "original generic restored" "default via fe80::aaaa dev eth1" "$ROUTES_FILE"
    assert_contains "original PD route restored" "default from 2001:db8:7e3:7700::/56 via fe80::aaaa" "$ROUTES_FILE"
    # No candidate b route remains.
    assert_not_contains "no b generic route" "default via fe80::bbbb" "$ROUTES_FILE"
    assert_not_contains "no b PD route" "default from 2001:db8:7e3:7700::/56 via fe80::bbbb" "$ROUTES_FILE"
}

# ================================================================
# J. Sticky GOOD_GW restoration installs generic + PD routes, validates LAN
# ================================================================
test_J() {
    echo "--- J: sticky restore installs generic + PD via good_gw ---"
    echo "fe80::bbbb" > "$GOOD_GW_FILE"
    add_route "default via fe80::aaaa dev eth1 metric 512"
    add_route "default from 2001:db8:7e3:7700::/56 via fe80::aaaa dev eth1 metric 512"
    add_neigh "fe80::aaaa lladdr aa:aa:aa:aa:aa:aa dev eth1 router"
    add_neigh "fe80::bbbb lladdr bb:bb:bb:bb:bb:bb dev eth1 router"
    set_scenario "PD_OK_GATEWAYS" "fe80::bbbb"
    keep_gateway
    rc=$?
    assert_eq "keep_gateway return" "$rc" "0"
    assert_contains "generic restored via b" "default via fe80::bbbb" "$ROUTES_FILE"
    assert_contains "PD route restored via b" "default from 2001:db8:7e3:7700::/56 via fe80::bbbb" "$ROUTES_FILE"
    assert_eq "GOOD_GW_FILE preserved" "$(cat "$GOOD_GW_FILE" 2>/dev/null)" "fe80::bbbb"
}

# ================================================================
# K. Sticky GOOD_GW fails PD validation -> broken sticky route not permanent
# ================================================================
test_K() {
    echo "--- K: sticky good_gw fails PD -> rolled back ---"
    echo "fe80::bbbb" > "$GOOD_GW_FILE"
    add_route "default via fe80::aaaa dev eth1 metric 512"
    add_route "default from 2001:db8:7e3:7700::/56 via fe80::aaaa dev eth1 metric 512"
    add_neigh "fe80::aaaa lladdr aa:aa:aa:aa:aa:aa dev eth1 router"
    add_neigh "fe80::bbbb lladdr bb:bb:bb:bb:bb:bb dev eth1 router"
    set_scenario "PD_OK_GATEWAYS" ""
    keep_gateway
    rc=$?
    assert_eq "keep_gateway return" "$rc" "0"
    # Broken sticky route (b) must not remain; original routes restored.
    assert_not_contains "no sticky b generic" "default via fe80::bbbb" "$ROUTES_FILE"
    assert_not_contains "no sticky b PD route" "default from 2001:db8:7e3:7700::/56 via fe80::bbbb" "$ROUTES_FILE"
    assert_contains "original generic restored" "default via fe80::aaaa" "$ROUTES_FILE"
    assert_contains "original PD route restored" "default from 2001:db8:7e3:7700::/56 via fe80::aaaa" "$ROUTES_FILE"
}

# ================================================================
# L. Route snapshot includes source-specific route and metric information
# ================================================================
test_L() {
    echo "--- L: snapshot preserves source-specific + metric ---"
    # Verify restore_route_snapshot replays the exact route line including
    # `from` and `metric` by snapshotting a rich route set and restoring it.
    add_route "default via fe80::aaaa dev eth1 metric 512"
    add_route "default from 2001:db8:7e3:7700::/56 via fe80::aaaa dev eth1 metric 512"
    snap="$STATE_DIR/snap_test.$$"
    PATH="$MOCK_DIR:$ORIG_PATH" snapshot_default_routes "$snap"
    if [ -s "$snap" ]; then pass "snapshot file non-empty"; else fail "snapshot empty"; fi
    if grep -q "default from 2001:db8:7e3:7700::/56 via fe80::aaaa" "$snap"; then
        pass "snapshot contains source-specific route"
    else
        fail "snapshot missing source-specific route"
    fi
    if grep -q "metric 512" "$snap"; then
        pass "snapshot contains metric"
    else
        fail "snapshot missing metric"
    fi
    # Clear routes and restore.
    : > "$ROUTES_FILE"
    PATH="$MOCK_DIR:$ORIG_PATH" restore_route_snapshot "$snap"
    if grep -q "default from 2001:db8:7e3:7700::/56 via fe80::aaaa" "$ROUTES_FILE"; then
        pass "restore replayed source-specific route"
    else
        fail "restore did not replay source-specific route"
    fi
    if grep -q "default via fe80::aaaa dev eth1 metric 512" "$ROUTES_FILE"; then
        pass "restore replayed generic route with metric"
    else
        fail "restore did not replay generic route with metric"
    fi
    rm -f "$snap" 2>/dev/null
}

# ================================================================
# M. No unbound external ping in fix_gateway / keep_gateway / candidate path
# ================================================================
test_M() {
    echo "--- M: no unbound external ping in gateway path ---"
    # Drive fix_gateway through a candidate scan and inspect ping6 log.
    add_route "default via fe80::aaaa dev eth1 metric 512"
    add_route "default from 2001:db8:7e3:7700::/56 via fe80::aaaa dev eth1 metric 512"
    add_neigh "fe80::aaaa lladdr aa:aa:aa:aa:aa:aa dev eth1 router"
    add_neigh "fe80::bbbb lladdr bb:bb:bb:bb:bb:bb dev eth1 router"
    set_scenario "PD_OK_GATEWAYS" "fe80::bbbb"
    fix_gateway >/dev/null 2>&1
    # Every ping6 call to a public target must have -I (sourced). Only
    # ff02::2 (NDP) and link-local gw pings may be unsourced.
    unbound=0
    if [ -s "$PING6_LOG" ]; then
        while read -r line; do
            target=$(printf '%s' "$line" | awk '{print $NF}')
            case "$target" in
                2001:4860:4860::8888|2606:4700:4700::1111)
                    case "$line" in
                        *"-I "*) ;;  # sourced, ok
                        *) unbound=1; echo "  unbound ping: $line" ;;
                    esac
                    ;;
            esac
        done < "$PING6_LOG"
    fi
    if [ "$unbound" = "0" ]; then pass "no unbound external ping in gateway path"; else fail "unbound external ping detected"; fi
    # Also check keep_gateway path.
    : > "$PING6_LOG"
    echo "fe80::bbbb" > "$GOOD_GW_FILE"
    set_scenario "PD_OK_GATEWAYS" "fe80::bbbb"
    keep_gateway >/dev/null 2>&1
    unbound=0
    if [ -s "$PING6_LOG" ]; then
        while read -r line; do
            target=$(printf '%s' "$line" | awk '{print $NF}')
            case "$target" in
                2001:4860:4860::8888|2606:4700:4700::1111)
                    case "$line" in
                        *"-I "*) ;;
                        *) unbound=1; echo "  unbound ping (keep_gateway): $line" ;;
                    esac
                    ;;
            esac
        done < "$PING6_LOG"
    fi
    if [ "$unbound" = "0" ]; then pass "no unbound external ping in keep_gateway"; else fail "unbound ping in keep_gateway"; fi
}

# ================================================================
# Run all tests
# ================================================================
echo "=== Phase 2: source-aware gateway tests ==="

# Allow running a subset of tests via GW_TESTS="A B S" for fork-resource-
# constrained environments (Cygwin on Windows exhausts fork heap after many
# mock invocations). Default: run the full suite.
GW_TESTS="${GW_TESTS:-A B C D E F G H I J K L R S M}"
for t in $GW_TESTS; do
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