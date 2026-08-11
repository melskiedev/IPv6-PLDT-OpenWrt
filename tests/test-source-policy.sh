#!/bin/sh
# tests/test-source-policy.sh
#
# v3.10.0 router source policy layer: tests ensure_router_source_policy()
# extracted from ipv6-watchdog. Verifies the IA_NA /128 vs PD-source
# reachability classification, cache identity invalidation, preferred-src
# install/restore, native transition, and route ownership safety.
#
# The source policy layer is SEPARATE from household health. WAN128
# success/failure MUST NEVER define ipv6_ok, increment recovery failures,
# trigger wan6/full-WAN recovery, consume shared disruption budget, or
# trigger recovery hold. These tests prove that boundary.
#
# Usage: sh tests/test-source-policy.sh
# Exit:  0 = all pass, 1 = any fail

TEST_SCRIPT="$0"
SCRIPT_DIR="$(cd "$(dirname "$TEST_SCRIPT")/.." && pwd)"
TEST_BASE="$SCRIPT_DIR/.test-tmp"
TEST_ROOT="$TEST_BASE/src-policy-test-$$"
mkdir -p "$TEST_ROOT"

cleanup() { rm -rf "$TEST_ROOT"; }
trap cleanup EXIT
trap 'cleanup; exit 130' INT
trap 'cleanup; exit 143' TERM

PASS=0
FAIL=0

# ================================================================
# Extract production helpers from ipv6-watchdog.
# We need: sanitize_int, get_pd_addr, get_pd_mask, get_wan_dev,
# get_wan128, addr_in_prefix (with _expand_ipv6, _count_groups,
# _emit_groups inner helpers), is_link_local, is_ula, get_lan_pd_src,
# populate_pd_context, pd_internet_ok, wan128_internet_ok,
# current_default_gw, and ensure_router_source_policy (with its
# inner helpers: _src_policy_key, _src_policy_cached_mode,
# _src_policy_cached_key, _src_policy_cached_ts, _src_policy_write_cache,
# _generic_default_src, _install_preferred_src, _remove_managed_preferred_src).
# ================================================================

EXTRACT="$TEST_ROOT/helpers.sh"

# Extract sanitize_int() separately (it's before the PD context section).
awk '/^sanitize_int\(\)/ { start=1 } start { print } start && /^}/ { start=0; print ""; exit }' \
    "$SCRIPT_DIR/ipv6-watchdog" > "$EXTRACT"

# Extract from the PD-FIRST SOURCE-AWARE CONTEXT comment through the end of
# ensure_router_source_policy(). This captures all PD-context helpers plus
# the source-policy layer, matching the proven extraction pattern from
# test-prefix-helpers.sh.
awk '
    /PD-FIRST SOURCE-AWARE CONTEXT/ { start=1 }
    start { print }
    start && /^ensure_router_source_policy\(\)/ { saw_esp=1 }
    saw_esp && /^}$/ { start=0; saw_esp=0; print ""; exit }
' "$SCRIPT_DIR/ipv6-watchdog" >> "$EXTRACT"

# Sanity: the extract must contain our key functions.
for fn in sanitize_int get_wan128 addr_in_prefix is_link_local is_ula \
           get_lan_pd_src populate_pd_context pd_internet_ok wan128_internet_ok \
           current_default_gw ensure_router_source_policy \
           _src_policy_key _src_policy_cached_mode _src_policy_cached_key \
           _src_policy_cached_ts _src_policy_write_cache \
           _src_policy_managed_src \
           _generic_default_src _generic_default_raw_line \
           _install_preferred_src _remove_managed_preferred_src \
           _relinquish_stale_managed_src; do
    if ! grep -q "^${fn}()" "$EXTRACT" 2>/dev/null && ! grep -q "^${fn} " "$EXTRACT" 2>/dev/null; then
        echo "FATAL: could not extract $fn from ipv6-watchdog" >&2
        exit 2
    fi
done

# log() stub: append to a shared log file we can inspect.
WATCHDOG_LOG="$TEST_ROOT/watchdog.log"
: > "$WATCHDOG_LOG"
printf 'log() { echo "$1" >> "%s"; }\n' "$WATCHDOG_LOG" > "$TEST_ROOT/preamble.sh"

# Minimal defaults so sourcing does not fail.
STATE_DIR="$TEST_ROOT/state"
mkdir -p "$STATE_DIR"
GOOD_GW_FILE="$STATE_DIR/good_gateway"
LAN_DEV="br-lan"
CLEANUP_DEPRECATED_LAN=0
REACHABILITY_CONFIRM_DELAY=0

# Source the extracted helpers.
# shellcheck disable=SC1090
. "$TEST_ROOT/preamble.sh"
# shellcheck disable=SC1090
. "$EXTRACT"

# Source-policy cache files (must match ipv6-watchdog definitions).
SRC_POLICY_MODE_FILE="$STATE_DIR/src_policy_mode"
SRC_POLICY_KEY_FILE="$STATE_DIR/src_policy_key"
SRC_POLICY_TS_FILE="$STATE_DIR/src_policy_ts"
SRC_POLICY_MANAGED_SRC_FILE="$STATE_DIR/src_policy_managed_src"
SRC_POLICY_REFRESH=600
NOW=1000000

# ================================================================
# Mock framework
# ================================================================

MOCK_DIR="$TEST_ROOT/mock"
mkdir -p "$MOCK_DIR"
SCENARIO="$TEST_ROOT/scenario"
export SCENARIO

# Scenario keys:
#   ROUTES=           path to route table file
#   NEIGH=            path to neighbor table file
#   PD_PREFIX_ADDR=   IA_PD prefix address
#   PD_PREFIX_MASK=   IA_PD prefix mask
#   WAN_L3_DEVICE=    WAN L3 device
#   LAN_SRC=          LAN PD-derived source address
#   WAN128=           WAN /128 address (empty = absent)
#   PD_PING_OK=       1 = pd_internet_ok passes
#   WAN128_PING_OK=   1 = wan128_internet_ok passes
#   IP_LOG=           path to ip call log
reset_scenario() {
    : > "$SCENARIO"
    printf 'ROUTES=\n' >> "$SCENARIO"
    printf 'NEIGH=\n' >> "$SCENARIO"
    printf 'PD_PREFIX_ADDR=2001:db8:100::\n' >> "$SCENARIO"
    printf 'PD_PREFIX_MASK=56\n' >> "$SCENARIO"
    printf 'WAN_L3_DEVICE=eth1\n' >> "$SCENARIO"
    printf 'LAN_SRC=2001:db8:100:ab::1\n' >> "$SCENARIO"
    printf 'WAN128=\n' >> "$SCENARIO"
    printf 'PD_PING_OK=1\n' >> "$SCENARIO"
    printf 'WAN128_PING_OK=0\n' >> "$SCENARIO"
    printf 'IP_LOG=\n' >> "$SCENARIO"
    printf 'PING6_LOG=\n' >> "$SCENARIO"
    printf 'FAIL_ROUTE_REPLACE=0\n' >> "$SCENARIO"
    printf 'REAL_IPROUTE2_SELECTOR=0\n' >> "$SCENARIO"
    : > "$WATCHDOG_LOG"
    rm -f "$STATE_DIR"/src_policy_* 2>/dev/null
    rm -f "$STATE_DIR"/fix_gateway_routes.* 2>/dev/null
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

# Build the mock binaries once.
build_mocks() {
cat > "$MOCK_DIR/ip" <<'EOF'
#!/bin/sh
# Mock ip. Implements route show, route replace, route del, neigh show,
# addr show using a ROUTES_FILE described by the scenario.
SCEN="${SCENARIO:-/dev/null}"
ROUTES_FILE=$(sed -n 's/^ROUTES=//p' "$SCEN" | head -1)
IP_LOG=$(sed -n 's/^IP_LOG=//p' "$SCEN" | head -1)
[ -n "$IP_LOG" ] && echo "ip $*" >> "$IP_LOG"

case "$2" in
    route)
        case "$3" in
            show)
                dev=""
                from=""
                shift 3
                while [ $# -gt 0 ]; do
                    case "$1" in
                        default) ;;
                        dev) dev="$2"; shift ;;
                        from) from="$2"; shift ;;
                    esac
                    shift
                done
                # Model real iproute2 behavior: when a `dev` selector is
                # supplied, real `ip -6 route show default dev eth1` OMITS
                # the `dev eth1` token from the output (the selector is
                # implied). When REAL_IPROUTE2_SELECTOR=1, strip `dev <dev>`
                # from the output lines to reproduce this behavior. This
                # catches the production bug where _generic_default_raw_line
                # relied on the selector and got lines without `dev`.
                _real_selector=$(sed -n 's/^REAL_IPROUTE2_SELECTOR=//p' "$SCEN" | head -1)
                if [ -n "$from" ]; then
                    grep "^default from $from " "$ROUTES_FILE" 2>/dev/null
                elif [ -n "$dev" ]; then
                    if [ "$_real_selector" = "1" ]; then
                        # Real iproute2: strip `dev <dev>` from output
                        grep "^default.* dev $dev" "$ROUTES_FILE" 2>/dev/null \
                            | sed "s/ dev $dev//"
                    else
                        grep "^default.* dev $dev" "$ROUTES_FILE" 2>/dev/null
                    fi
                else
                    grep '^default' "$ROUTES_FILE" 2>/dev/null
                fi
                ;;
            get)
                # ip -6 route get <target> from <src>
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
                    src=$(printf '%s\n' "$line" | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}')
                    if [ -n "$src" ]; then
                        printf '%s from %s via %s dev %s src %s\n' "2001:4860:4860::8888" "$from" "$gw" "$dev" "$src"
                    else
                        printf '%s from %s via %s dev %s\n' "2001:4860:4860::8888" "$from" "$gw" "$dev"
                    fi
                else
                    echo "unreachable $from"
                fi
                ;;
            replace)
                # ip -6 route replace <spec...>
                spec="$4"
                shift 4
                while [ $# -gt 0 ]; do
                    spec="$spec $1"
                    shift
                done
                # Check if route replace should fail (test F).
                _fail_rr=$(sed -n 's/^FAIL_ROUTE_REPLACE=//p' "$SCEN" | head -1)
                if [ "$_fail_rr" = "1" ]; then
                    exit 1
                fi
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
                spec="$4"
                shift 4
                while [ $# -gt 0 ]; do
                    spec="$spec $1"
                    shift
                done
                grep -v "^$(printf '%s' "$spec" | sed 's/[][\\.*+?(){}|^$]/\\&/g')\$" "$ROUTES_FILE" 2>/dev/null > "$ROUTES_FILE.tmp"
                mv "$ROUTES_FILE.tmp" "$ROUTES_FILE" 2>/dev/null
                ;;
            *) ;;
        esac
        ;;
    neigh)
        case "$3" in
            show)
                dev="$5"
                cat "$NEIGH_FILE" 2>/dev/null
                ;;
            *) ;;
        esac
        ;;
    addr)
        # ip -6 addr show dev <dev> -> emit addresses based on device
        #   WAN device (eth1): emit WAN128 if set (as /128 scope global)
        #   LAN device (br-lan): emit LAN_SRC (as /64 scope global dynamic)
        _query_dev="$5"
        _wan128_addr=$(sed -n 's/^WAN128=//p' "$SCEN" | head -1)
        _lan_src=$(sed -n 's/^LAN_SRC=//p' "$SCEN" | head -1)
        case "$_query_dev" in
            eth1)
                # WAN device: emit /128 if WAN128 is set
                if [ -n "$_wan128_addr" ]; then
                    printf 'inet6 %s/128 scope global dynamic\n' "$_wan128_addr"
                    printf '   valid_lft 86400sec preferred_lft 14400sec\n'
                fi
                ;;
            br-lan|*)
                # LAN device: emit LAN_SRC as /64
                if [ -n "$_lan_src" ]; then
                    printf 'inet6 %s/64 scope global dynamic\n' "$_lan_src"
                    printf '   valid_lft 86400sec preferred_lft 14400sec\n'
                fi
                ;;
        esac
        ;;
    *) ;;
esac
exit 0
EOF
chmod +x "$MOCK_DIR/ip"

cat > "$MOCK_DIR/ping6" <<'EOF'
#!/bin/sh
# Mock ping6.
#   -I LAN_PD_SRC <public> -> PD_PING_OK
#   -I WAN128 <public>     -> WAN128_PING_OK
#   -I WAN_DEV <gw> (link-local) -> exit 0 (gateway_mac probe)
SCEN="${SCENARIO:-/dev/null}"
PD_PING_OK=$(sed -n 's/^PD_PING_OK=//p' "$SCEN" | head -1)
WAN128_PING_OK=$(sed -n 's/^WAN128_PING_OK=//p' "$SCEN" | head -1)
WAN128=$(sed -n 's/^WAN128=//p' "$SCEN" | head -1)
PING6_LOG=$(sed -n 's/^PING6_LOG=//p' "$SCEN" | head -1)
[ -n "$PING6_LOG" ] && echo "$@" >> "$PING6_LOG"

src=""
target=""
prev=""
for a in "$@"; do
    if [ "$prev" = "-I" ]; then src="$a"; fi
    prev="$a"
    case "$a" in -*) ;; *) target="$a";; esac
done

case "$target" in
    2001:4860:4860::8888|2606:4700:4700::1111)
        if [ -n "$src" ]; then
            if [ -n "$WAN128" ] && [ "$src" = "$WAN128" ]; then
                [ "$WAN128_PING_OK" = "1" ] && exit 0 || exit 1
            fi
            [ "$PD_PING_OK" = "1" ] && exit 0 || exit 1
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

cat > "$MOCK_DIR/ubus" <<'EOF'
#!/bin/sh
SCEN="${SCENARIO:-/dev/null}"
PD_ADDR=$(sed -n 's/^PD_PREFIX_ADDR=//p' "$SCEN" | head -1)
PD_MASK=$(sed -n 's/^PD_PREFIX_MASK=//p' "$SCEN" | head -1)
L3=$(sed -n 's/^WAN_L3_DEVICE=//p' "$SCEN" | head -1)
if [ -n "$PD_ADDR" ]; then
    printf '{"up":true,"pending":false,"l3_device":"%s","ipv6-prefix":[{"address":"%s","mask":%s}]}' "$L3" "$PD_ADDR" "$PD_MASK"
else
    printf '{"up":true,"pending":false,"l3_device":"%s","ipv6-prefix":[]}' "$L3"
fi
EOF
chmod +x "$MOCK_DIR/ubus"

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

cat > "$MOCK_DIR/sleep" <<'EOF'
#!/bin/sh
:
EOF
chmod +x "$MOCK_DIR/sleep"
}

build_mocks

# Per-test setup.
run_test() {
    name="$1"
    ROUTES_FILE="$TEST_ROOT/routes_$$.txt"
    NEIGH_FILE="$TEST_ROOT/neigh_$$.txt"
    IP_LOG="$TEST_ROOT/ip_$$.log"
    PING6_LOG="$TEST_ROOT/ping6_$$.log"
    : > "$ROUTES_FILE"
    : > "$NEIGH_FILE"
    : > "$IP_LOG"
    : > "$PING6_LOG"
    reset_scenario
    set_scenario "ROUTES" "$ROUTES_FILE"
    set_scenario "NEIGH" "$NEIGH_FILE"
    set_scenario "IP_LOG" "$IP_LOG"
    set_scenario "PING6_LOG" "$PING6_LOG"
    PATH="$MOCK_DIR:$ORIG_PATH" "$name"
    rc=$?
    rm -f "$ROUTES_FILE" "$NEIGH_FILE" "$IP_LOG" 2>/dev/null
    rm -f "$STATE_DIR"/src_policy_* 2>/dev/null
    return $rc
}

add_route() { printf '%s\n' "$1" >> "$ROUTES_FILE"; }
add_neigh() { printf '%s\n' "$1" >> "$NEIGH_FILE"; }

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

# Helper: read cached mode.
cached_mode() { cat "$SRC_POLICY_MODE_FILE" 2>/dev/null; }
cached_key() { cat "$SRC_POLICY_KEY_FILE" 2>/dev/null; }
cached_managed_src() { cat "$SRC_POLICY_MANAGED_SRC_FILE" 2>/dev/null; }

# Helper: check if the generic default route has a src attribute.
generic_default_has_src() {
    ip -6 route show default dev "$WAN_DEV" 2>/dev/null \
        | grep -v '^default from ' | head -1 \
        | grep -q ' src '
}
generic_default_src_val() {
    ip -6 route show default dev "$WAN_DEV" 2>/dev/null \
        | grep -v '^default from ' | head -1 \
        | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}'
}

PD_CIDR="2001:db8:100::/56"
PD_ADDR="2001:db8:100::"
PD_MASK="56"
LAN_PD_SRC="2001:db8:100:ab::1"
WAN_DEV="eth1"
WAN128=""
ORIG_PATH="$PATH"

# ================================================================
# Test 1: WAN128 absent + PD healthy -> native, no preferred src
# ================================================================
test_1() {
    echo "--- 1: WAN128 absent + PD healthy -> native ---"
    add_route "default via fe80::aaaa dev eth1 metric 512"
    set_scenario "WAN128" ""
    set_scenario "PD_PING_OK" "1"
    ensure_router_source_policy
    rc=$?
    assert_eq "return" "$rc" "0"
    assert_eq "cached_mode" "$(cached_mode)" "native"
    assert_eq "no managed_src" "$(cached_managed_src)" ""
    assert_not_contains "no src on generic default" " src " "$ROUTES_FILE"
}

# ================================================================
# Test 2: WAN128 present + WAN128 healthy + PD healthy -> native
# (dual-source healthy case)
# ================================================================
test_2() {
    echo "--- 2: WAN128 present + WAN128 healthy + PD healthy -> native (dual-source healthy) ---"
    add_route "default via fe80::aaaa dev eth1 metric 512"
    _wan128="2001:db8:dead::1"
    set_scenario "WAN128" "$_wan128"
    set_scenario "WAN128_PING_OK" "1"
    set_scenario "PD_PING_OK" "1"
    ensure_router_source_policy
    rc=$?
    assert_eq "return" "$rc" "0"
    assert_eq "cached_mode" "$(cached_mode)" "native"
    assert_eq "no managed_src" "$(cached_managed_src)" ""
    assert_not_contains "no src on generic default" " src " "$ROUTES_FILE"
}

# ================================================================
# Test 3: WAN128 present + WAN128 unhealthy + PD healthy -> pd-preferred
# (IA_NA-unusable case)
# ================================================================
test_3() {
    echo "--- 3: WAN128 present + WAN128 unhealthy + PD healthy -> pd-preferred (IA_NA-unusable) ---"
    add_route "default via fe80::aaaa dev eth1 metric 512"
    _wan128="2001:db8:dead::1"
    set_scenario "WAN128" "$_wan128"
    set_scenario "WAN128_PING_OK" "0"
    set_scenario "PD_PING_OK" "1"
    ensure_router_source_policy
    rc=$?
    assert_eq "return" "$rc" "0"
    assert_eq "cached_mode" "$(cached_mode)" "pd-preferred"
    assert_eq "managed_src set" "$(cached_managed_src)" "$LAN_PD_SRC"
    assert_contains "src on generic default" "src $LAN_PD_SRC" "$ROUTES_FILE"
    # Verify the route still has the gateway and metric
    assert_contains "gateway preserved" "via fe80::aaaa" "$ROUTES_FILE"
    assert_contains "metric preserved" "metric 512" "$ROUTES_FILE"
}

# ================================================================
# Test 4: pd-preferred cached, same key, route refresh silently removes src
# -> restore src WITHOUT rerunning WAN128 probes
# ================================================================
test_4() {
    echo "--- 4: pd-preferred cached, src silently removed -> restore without WAN128 probes ---"
    add_route "default via fe80::aaaa dev eth1 metric 512"
    _wan128="2001:db8:dead::1"
    set_scenario "WAN128" "$_wan128"
    set_scenario "WAN128_PING_OK" "0"
    set_scenario "PD_PING_OK" "1"

    # Prime the cache with pd-preferred. The watchdog installs src and
    # claims ownership.
    ensure_router_source_policy
    assert_eq "first call mode" "$(cached_mode)" "pd-preferred"
    assert_eq "ownership recorded" "$(cached_managed_src)" "$LAN_PD_SRC"

    # Simulate route refresh removing src (rewrite route without src).
    : > "$ROUTES_FILE"
    add_route "default via fe80::aaaa dev eth1 metric 512"

    # Clear the ping6 call log. We will verify WAN128 probes are NOT rerun
    # (cached pd-preferred, same key -> only src verification, no WAN128 ping).
    PING6_LOG="$TEST_ROOT/ping6_4.log"
    : > "$PING6_LOG"
    set_scenario "PING6_LOG" "$PING6_LOG"

    # Second call: same key, cached pd-preferred. Should restore src.
    ensure_router_source_policy
    rc=$?
    assert_eq "return" "$rc" "0"
    assert_eq "still pd-preferred" "$(cached_mode)" "pd-preferred"
    assert_contains "src restored" "src $LAN_PD_SRC" "$ROUTES_FILE"
    # Verify WAN128 probes were NOT rerun (no ping6 -I <WAN128> calls).
    if grep -q "2001:db8:dead::1" "$PING6_LOG" 2>/dev/null; then
        fail "WAN128 probe was rerun (should not be for cached pd-preferred)"
    else
        pass "WAN128 probe not rerun (cached pd-preferred)"
    fi
}

# ================================================================
# Test 5: Delegated prefix/LAN_PD_SRC changes -> cache key invalidated,
# stale managed src not retained, policy reclassified
# ================================================================
test_5() {
    echo "--- 5: PD/LAN_PD_SRC changes -> cache invalidated, reclassified ---"
    add_route "default via fe80::aaaa dev eth1 metric 512"
    _wan128="2001:db8:dead::1"
    set_scenario "WAN128" "$_wan128"
    set_scenario "WAN128_PING_OK" "0"
    set_scenario "PD_PING_OK" "1"

    # Prime the cache with pd-preferred. Watchdog installs src and
    # claims ownership.
    ensure_router_source_policy
    assert_eq "first call mode" "$(cached_mode)" "pd-preferred"
    assert_eq "first managed_src" "$(cached_managed_src)" "$LAN_PD_SRC"

    # Change LAN_PD_SRC (new PD context).
    NEW_LAN_SRC="2001:db8:200:cd::2"
    set_scenario "LAN_SRC" "$NEW_LAN_SRC"
    set_scenario "PD_PREFIX_ADDR" "2001:db8:200::"
    LAN_PD_SRC="$NEW_LAN_SRC"
    PD_CIDR="2001:db8:200::/56"
    PD_ADDR="2001:db8:200::"

    # The route still has the OLD src. The helper should detect the key
    # change, reclassify, and install the NEW preferred src (after removing
    # the stale one via _relinquish_stale_managed_src which verifies current
    # route src == old managed_src before removing).
    ensure_router_source_policy
    rc=$?
    assert_eq "return" "$rc" "0"
    assert_eq "reclassified mode" "$(cached_mode)" "pd-preferred"
    assert_eq "new managed_src" "$(cached_managed_src)" "$NEW_LAN_SRC"
    # The route should now have the new src (the stale src removal happens
    # via the route replace which overwrites the old line).
    assert_contains "new src on default" "src $NEW_LAN_SRC" "$ROUTES_FILE"
    assert_not_contains "old src removed" "src 2001:db8:100:ab::1" "$ROUTES_FILE"
}

# ================================================================
# Test 6: Default gateway changes -> cache key invalidated and reclassified
# ================================================================
test_6() {
    echo "--- 6: gateway changes -> cache invalidated, reclassified ---"
    add_route "default via fe80::aaaa dev eth1 metric 512"
    _wan128="2001:db8:dead::1"
    set_scenario "WAN128" "$_wan128"
    set_scenario "WAN128_PING_OK" "0"
    set_scenario "PD_PING_OK" "1"

    # Prime the cache with pd-preferred via gateway A.
    ensure_router_source_policy
    assert_eq "first call mode" "$(cached_mode)" "pd-preferred"
    assert_contains "src installed" "src $LAN_PD_SRC" "$ROUTES_FILE"

    # Change the gateway to B.
    : > "$ROUTES_FILE"
    add_route "default via fe80::bbbb dev eth1 metric 512"

    ensure_router_source_policy
    rc=$?
    assert_eq "return" "$rc" "0"
    assert_eq "reclassified mode" "$(cached_mode)" "pd-preferred"
    # The new gateway should get the preferred src.
    assert_contains "src on new gw route" "src $LAN_PD_SRC" "$ROUTES_FILE"
    assert_contains "new gw in route" "via fe80::bbbb" "$ROUTES_FILE"
}

# ================================================================
# Test 7: WAN128 changes -> cache invalidated and reclassified
# ================================================================
test_7() {
    echo "--- 7: WAN128 changes -> cache invalidated, reclassified ---"
    add_route "default via fe80::aaaa dev eth1 metric 512"
    set_scenario "WAN128" "2001:db8:dead::1"
    set_scenario "WAN128_PING_OK" "0"
    set_scenario "PD_PING_OK" "1"

    # Prime: WAN128 present + WAN128 fails -> pd-preferred.
    ensure_router_source_policy
    assert_eq "first call mode" "$(cached_mode)" "pd-preferred"

    # WAN128 changes (new address) AND now passes.
    set_scenario "WAN128" "2001:db8:beef::2"
    set_scenario "WAN128_PING_OK" "1"
    WAN128="2001:db8:beef::2"

    ensure_router_source_policy
    rc=$?
    assert_eq "return" "$rc" "0"
    # WAN128 now passes -> native.
    assert_eq "native mode" "$(cached_mode)" "native"
    assert_eq "no managed_src" "$(cached_managed_src)" ""
    # Native transition should remove the watchdog-managed preferred src.
    assert_not_contains "no src on default" " src " "$ROUTES_FILE"
}

# ================================================================
# Test 8: PD connectivity unhealthy -> no policy-driven route mutation,
# WAN128 result NOT treated as household recovery input
# ================================================================
test_8() {
    echo "--- 8: PD unhealthy -> no policy mutation, WAN128 not recovery input ---"
    add_route "default via fe80::aaaa dev eth1 metric 512"
    _wan128="2001:db8:dead::1"
    set_scenario "WAN128" "$_wan128"
    set_scenario "WAN128_PING_OK" "0"
    set_scenario "PD_PING_OK" "0"

    # PD Internet fails: classification D. No policy-driven mutation.
    ensure_router_source_policy
    rc=$?
    assert_eq "return" "$rc" "0"
    # No cache should be written (helper returns 0 before writing cache).
    assert_eq "no cache mode" "$(cached_mode)" ""
    assert_not_contains "no src mutation" " src " "$ROUTES_FILE"
    # Verify no WAN128 probe was used as recovery input (no state files written).
    assert_eq "no managed_src" "$(cached_managed_src)" ""
}

# ================================================================
# Test 9: Native transition after watchdog-managed pd-preferred state
# -> only watchdog-owned preferred src is removed
# ================================================================
test_9() {
    echo "--- 9: native transition removes only watchdog-owned src ---"
    add_route "default via fe80::aaaa dev eth1 metric 512"
    _wan128="2001:db8:dead::1"
    set_scenario "WAN128" "$_wan128"
    set_scenario "WAN128_PING_OK" "0"
    set_scenario "PD_PING_OK" "1"

    # Prime: pd-preferred with managed src.
    ensure_router_source_policy
    assert_eq "primed mode" "$(cached_mode)" "pd-preferred"
    assert_eq "managed_src set" "$(cached_managed_src)" "$LAN_PD_SRC"
    assert_contains "src on default" "src $LAN_PD_SRC" "$ROUTES_FILE"

    # WAN128 now passes -> native transition. The cache key is unchanged
    # (same WAN128 address, same PD, same gateway), so the helper would NOT
    # rerun WAN128 probes in the cached pd-preferred path. To trigger
    # reclassification, advance NOW past the refresh interval, which
    # invalidates the cache key at the end of the pd-preferred case. Then
    # call ensure_router_source_policy again to reclassify with the now-
    # invalidated key.
    set_scenario "WAN128_PING_OK" "1"
    NOW=$((NOW + SRC_POLICY_REFRESH + 1))

    # First call: cached pd-preferred, same key. The helper verifies src,
    # then invalidates the key for the next tick (refresh interval elapsed).
    ensure_router_source_policy
    # Second call: key is now invalidated. The helper reclassifies.
    ensure_router_source_policy
    rc=$?
    assert_eq "return" "$rc" "0"
    assert_eq "native mode" "$(cached_mode)" "native"
    # The watchdog-managed src should be removed (route rewritten without src).
    assert_not_contains "no src on default" " src " "$ROUTES_FILE"
    assert_contains "gateway preserved" "via fe80::aaaa" "$ROUTES_FILE"
    assert_eq "managed_src cleared" "$(cached_managed_src)" ""
}

# ================================================================
# Test 10: Unknown/admin-created preferred src -> never stripped by cleanup
# ================================================================
test_10() {
    echo "--- 10: unknown/admin src -> never stripped ---"
    # Admin set a src that the watchdog did NOT install.
    ADMIN_SRC="2001:db8:9999::1"
    add_route "default via fe80::aaaa dev eth1 metric 512 src $ADMIN_SRC"
    _wan128="2001:db8:dead::1"
    set_scenario "WAN128" "$_wan128"
    set_scenario "WAN128_PING_OK" "1"
    set_scenario "PD_PING_OK" "1"

    # No prior managed_src. The helper classifies native (WAN128 OK).
    ensure_router_source_policy
    rc=$?
    assert_eq "return" "$rc" "0"
    assert_eq "native mode" "$(cached_mode)" "native"
    # The admin src must be preserved (not stripped).
    assert_contains "admin src preserved" "src $ADMIN_SRC" "$ROUTES_FILE"
    assert_eq "no managed_src" "$(cached_managed_src)" ""
}

# ================================================================
# Test 11: No source-policy path performs ifdown/ifup or shared disruption
# ================================================================
test_11() {
    echo "--- 11: no ifdown/ifup/disruption in source-policy path ---"
    add_route "default via fe80::aaaa dev eth1 metric 512"
    _wan128="2001:db8:dead::1"
    set_scenario "WAN128" "$_wan128"
    set_scenario "WAN128_PING_OK" "0"
    set_scenario "PD_PING_OK" "1"

    IP_LOG="$TEST_ROOT/ip_11.log"
    : > "$IP_LOG"
    set_scenario "IP_LOG" "$IP_LOG"

    ensure_router_source_policy
    rc=$?
    assert_eq "return" "$rc" "0"

    # Verify no ifdown/ifup/uci/service commands in the ip log.
    assert_not_contains "no ifdown" "ifdown" "$IP_LOG"
    assert_not_contains "no ifup" "ifup" "$IP_LOG"

    # Static check: ensure_router_source_policy and its helpers contain no
    # executable ifdown/ifup/service/uci-commit/wan_recovery calls. The EXTRACT
    # contains comments too, so we grep for lines that do NOT start with # and
    # contain the forbidden command as an executable word.
    _forbidden="ifdown ifup service uci_commit wan_recovery_full_begin wan_recovery_full_execute_locked wan_recovery_wan6_begin wan_recovery_wan6_record_locked maybe_wan_restart do_wan_restart"
    _static_fail=0
    for _cmd in $_forbidden; do
        # Match lines where the command appears as an executable word (not in
        # a comment). We strip comment-only lines first.
        if grep -v '^[[:space:]]*#' "$EXTRACT" 2>/dev/null | grep -qE "[[:space:]]($_cmd)([[:space:]]|$)"; then
            fail "executable $_cmd found in helper source"
            _static_fail=1
        fi
    done
    [ "$_static_fail" = "0" ] && pass "no executable ifdown/ifup/disruption in helper source"
    unset _forbidden _static_fail _cmd
}

# ================================================================
# Test A: native -> pd-preferred via 600s refresh (same key)
# ================================================================
test_A() {
    echo "--- A: native -> pd-preferred via 600s refresh ---"
    add_route "default via fe80::aaaa dev eth1 metric 512"
    _wan128="2001:db8:dead::1"
    set_scenario "WAN128" "$_wan128"
    set_scenario "WAN128_PING_OK" "1"
    set_scenario "PD_PING_OK" "1"

    # Prime: WAN128 OK -> native.
    ensure_router_source_policy
    assert_eq "primed native" "$(cached_mode)" "native"

    # WAN128 now fails (same key: same WAN128 addr, same PD, same gw).
    set_scenario "WAN128_PING_OK" "0"
    # Advance NOW past refresh interval.
    NOW=$((NOW + SRC_POLICY_REFRESH + 1))

    # First call: native cached, refresh elapsed, WAN128 now fails.
    ensure_router_source_policy
    assert_eq "pd-preferred after refresh" "$(cached_mode)" "pd-preferred"
    assert_contains "src installed" "src $LAN_PD_SRC" "$ROUTES_FILE"
    assert_eq "managed_src recorded" "$(cached_managed_src)" "$LAN_PD_SRC"
}

# ================================================================
# Test B: source-specific default preservation
# ================================================================
test_B() {
    echo "--- B: source-specific default preservation ---"
    add_route "default via fe80::aaaa dev eth1 metric 512"
    add_route "default from 2001:db8:100::/56 via fe80::aaaa dev eth1 metric 512"
    _wan128="2001:db8:dead::1"
    set_scenario "WAN128" "$_wan128"
    set_scenario "WAN128_PING_OK" "0"
    set_scenario "PD_PING_OK" "1"

    # Enter pd-preferred.
    ensure_router_source_policy
    assert_eq "pd-preferred" "$(cached_mode)" "pd-preferred"
    assert_contains "src on generic" "src $LAN_PD_SRC" "$ROUTES_FILE"
    # Source-specific route must be preserved.
    assert_contains "src-specific preserved" "default from 2001:db8:100::/56 via fe80::aaaa" "$ROUTES_FILE"

    # Transition to native: remove managed src.
    set_scenario "WAN128_PING_OK" "1"
    WAN128="2001:db8:beef::2"
    set_scenario "WAN128" "2001:db8:beef::2"
    ensure_router_source_policy
    assert_eq "native" "$(cached_mode)" "native"
    # Source-specific route must STILL be preserved.
    assert_contains "src-specific still preserved" "default from 2001:db8:100::/56 via fe80::aaaa" "$ROUTES_FILE"
}

# ================================================================
# Test C: admin src already equals LAN_PD_SRC, no ownership claimed
# ================================================================
test_C() {
    echo "--- C: admin src == LAN_PD_SRC, no ownership claimed ---"
    # Admin installed src=LAN_PD_SRC before the watchdog ran.
    add_route "default via fe80::aaaa dev eth1 src $LAN_PD_SRC metric 512"
    _wan128="2001:db8:dead::1"
    set_scenario "WAN128" "$_wan128"
    set_scenario "WAN128_PING_OK" "0"
    set_scenario "PD_PING_OK" "1"

    ensure_router_source_policy
    assert_eq "pd-preferred classified" "$(cached_mode)" "pd-preferred"
    # Watchdog must NOT claim ownership (it did not install the src).
    assert_eq "no ownership claimed" "$(cached_managed_src)" ""
    # Route must still have the src (unchanged).
    assert_contains "src preserved" "src $LAN_PD_SRC" "$ROUTES_FILE"

    # Transition to native.
    set_scenario "WAN128_PING_OK" "1"
    WAN128="2001:db8:beef::2"
    set_scenario "WAN128" "2001:db8:beef::2"
    ensure_router_source_policy
    assert_eq "native" "$(cached_mode)" "native"
    # src must remain (watchdog has no ownership, cannot remove it).
    assert_contains "src still present" "src $LAN_PD_SRC" "$ROUTES_FILE"
    assert_eq "still no ownership" "$(cached_managed_src)" ""
}

# ================================================================
# Test D: admin overrides watchdog-managed src, preserved on native
# ================================================================
test_D() {
    echo "--- D: admin overrides watchdog-managed src ---"
    add_route "default via fe80::aaaa dev eth1 metric 512"
    _wan128="2001:db8:dead::1"
    set_scenario "WAN128" "$_wan128"
    set_scenario "WAN128_PING_OK" "0"
    set_scenario "PD_PING_OK" "1"

    # Watchdog installs pd-preferred src and records ownership.
    ensure_router_source_policy
    assert_eq "pd-preferred" "$(cached_mode)" "pd-preferred"
    assert_eq "managed_src recorded" "$(cached_managed_src)" "$LAN_PD_SRC"
    assert_contains "src installed" "src $LAN_PD_SRC" "$ROUTES_FILE"

    # Admin overrides the route with a different src.
    ADMIN_SRC="2001:db8:9999::1"
    : > "$ROUTES_FILE"
    add_route "default via fe80::aaaa dev eth1 src $ADMIN_SRC metric 512"

    # Transition to native.
    set_scenario "WAN128_PING_OK" "1"
    WAN128="2001:db8:beef::2"
    set_scenario "WAN128" "2001:db8:beef::2"
    ensure_router_source_policy
    assert_eq "native" "$(cached_mode)" "native"
    # Admin src must be preserved (not stripped).
    assert_contains "admin src preserved" "src $ADMIN_SRC" "$ROUTES_FILE"
    # Ownership must be cleared (watchdog relinquished).
    assert_eq "ownership cleared" "$(cached_managed_src)" ""
}

# ================================================================
# Test E: PD changes after admin override, admin src preserved
# ================================================================
test_E() {
    echo "--- E: PD changes after admin override ---"
    add_route "default via fe80::aaaa dev eth1 metric 512"
    _wan128="2001:db8:dead::1"
    set_scenario "WAN128" "$_wan128"
    set_scenario "WAN128_PING_OK" "0"
    set_scenario "PD_PING_OK" "1"

    # Watchdog installs pd-preferred src and records ownership.
    ensure_router_source_policy
    assert_eq "managed_src recorded" "$(cached_managed_src)" "$LAN_PD_SRC"

    # Admin overrides the route with a different src.
    ADMIN_SRC="2001:db8:9999::1"
    : > "$ROUTES_FILE"
    add_route "default via fe80::aaaa dev eth1 src $ADMIN_SRC metric 512"

    # PD/LAN source changes (key invalidation).
    NEW_LAN_SRC="2001:db8:200:cd::2"
    set_scenario "LAN_SRC" "$NEW_LAN_SRC"
    set_scenario "PD_PREFIX_ADDR" "2001:db8:200::"
    LAN_PD_SRC="$NEW_LAN_SRC"
    PD_CIDR="2001:db8:200::/56"
    PD_ADDR="2001:db8:200::"

    ensure_router_source_policy
    # Admin src must be preserved (stale ownership relinquished, not stripped).
    assert_contains "admin src preserved" "src $ADMIN_SRC" "$ROUTES_FILE"
    assert_eq "stale ownership cleared" "$(cached_managed_src)" ""
}

# ================================================================
# Test F: install failure leaves managed_src empty
# ================================================================
test_F() {
    echo "--- F: install failure leaves managed_src empty ---"
    add_route "default via fe80::aaaa dev eth1 metric 512"
    _wan128="2001:db8:dead::1"
    set_scenario "WAN128" "$_wan128"
    set_scenario "WAN128_PING_OK" "0"
    set_scenario "PD_PING_OK" "1"
    # Force ip route replace to fail.
    set_scenario "FAIL_ROUTE_REPLACE" "1"

    ensure_router_source_policy
    assert_eq "pd-preferred classified" "$(cached_mode)" "pd-preferred"
    # managed_src MUST be empty (install failed).
    assert_eq "no ownership on failure" "$(cached_managed_src)" ""
    # Route must NOT have src (install failed).
    assert_not_contains "no src on route" " src " "$ROUTES_FILE"

    # Reset: allow route replace, advance time, retry on next tick.
    set_scenario "FAIL_ROUTE_REPLACE" "0"
    NOW=$((NOW + 1))
    # Invalidate key to force reclassification.
    : > "$SRC_POLICY_KEY_FILE"
    ensure_router_source_policy
    assert_eq "managed_src after retry" "$(cached_managed_src)" "$LAN_PD_SRC"
    assert_contains "src installed after retry" "src $LAN_PD_SRC" "$ROUTES_FILE"
}

# ================================================================
# Test G: route attribute preservation (proto, pref)
# ================================================================
test_G() {
    echo "--- G: route attribute preservation ---"
    # Generic default with extra attributes.
    add_route "default via fe80::aaaa dev eth1 proto static metric 512 pref medium"
    _wan128="2001:db8:dead::1"
    set_scenario "WAN128" "$_wan128"
    set_scenario "WAN128_PING_OK" "0"
    set_scenario "PD_PING_OK" "1"

    # Enter pd-preferred: src should be added, proto/pref preserved.
    ensure_router_source_policy
    assert_eq "pd-preferred" "$(cached_mode)" "pd-preferred"
    assert_contains "proto preserved" "proto static" "$ROUTES_FILE"
    assert_contains "pref preserved" "pref medium" "$ROUTES_FILE"
    assert_contains "src added" "src $LAN_PD_SRC" "$ROUTES_FILE"
    assert_contains "metric preserved" "metric 512" "$ROUTES_FILE"
    assert_contains "gateway preserved" "via fe80::aaaa" "$ROUTES_FILE"

    # Transition to native: src removed, proto/pref still preserved.
    set_scenario "WAN128_PING_OK" "1"
    WAN128="2001:db8:beef::2"
    set_scenario "WAN128" "2001:db8:beef::2"
    ensure_router_source_policy
    assert_eq "native" "$(cached_mode)" "native"
    assert_contains "proto still preserved" "proto static" "$ROUTES_FILE"
    assert_contains "pref still preserved" "pref medium" "$ROUTES_FILE"
    assert_not_contains "src removed" " src " "$ROUTES_FILE"
    assert_contains "metric still preserved" "metric 512" "$ROUTES_FILE"
}

# ================================================================
# Test H: admin src != LAN_PD_SRC in cached pd-preferred, never overwritten
# ================================================================
test_H() {
    echo "--- H: admin src != LAN_PD_SRC in cached pd-preferred ---"
    add_route "default via fe80::aaaa dev eth1 metric 512"
    _wan128="2001:db8:dead::1"
    set_scenario "WAN128" "$_wan128"
    set_scenario "WAN128_PING_OK" "0"
    set_scenario "PD_PING_OK" "1"

    # Prime: pd-preferred with watchdog-managed src.
    ensure_router_source_policy
    assert_eq "primed pd-preferred" "$(cached_mode)" "pd-preferred"
    assert_eq "managed_src" "$(cached_managed_src)" "$LAN_PD_SRC"

    # Admin changes the route to a different src (not LAN_PD_SRC).
    ADMIN_SRC="2001:db8:9999::1"
    : > "$ROUTES_FILE"
    add_route "default via fe80::aaaa dev eth1 src $ADMIN_SRC metric 512"

    # Next tick: cached pd-preferred, same key. The watchdog sees
    # cur_src=ADMIN_SRC which != LAN_PD_SRC and != cached_src (which is
    # LAN_PD_SRC). It must NOT overwrite the admin src.
    ensure_router_source_policy
    assert_eq "still pd-preferred" "$(cached_mode)" "pd-preferred"
    assert_contains "admin src not overwritten" "src $ADMIN_SRC" "$ROUTES_FILE"
    assert_not_contains "no watchdog src" "src $LAN_PD_SRC" "$ROUTES_FILE"
}

# ================================================================
# Test I: Mode file corrupted (deleted) while managed_src valid,
#         WAN128 absent, then WAN128 healthy -> watchdog src cleaned up
# ================================================================
test_I() {
    echo "--- I: mode file deleted, WAN128 absent, then healthy -> cleanup ---"
    add_route "default via fe80::aaaa dev eth1 metric 512"
    _wan128="2001:db8:dead::1"
    set_scenario "WAN128" "$_wan128"
    set_scenario "WAN128_PING_OK" "0"
    set_scenario "PD_PING_OK" "1"

    # Prime: pd-preferred, watchdog installs src and claims ownership.
    ensure_router_source_policy
    assert_eq "primed pd-preferred" "$(cached_mode)" "pd-preferred"
    assert_eq "managed_src recorded" "$(cached_managed_src)" "$LAN_PD_SRC"
    assert_contains "src on route" "src $LAN_PD_SRC" "$ROUTES_FILE"

    # Corrupt: delete ONLY the mode file. managed_src and route intact.
    rm -f "$SRC_POLICY_MODE_FILE"

    # WAN128 absent.
    set_scenario "WAN128" ""
    WAN128=""

    # Run ensure_router_source_policy. Fast path should detect managed_src
    # is set and clean it up even though cached mode is not pd-preferred.
    ensure_router_source_policy
    assert_eq "native after corruption" "$(cached_mode)" "native"
    assert_eq "managed_src cleaned" "$(cached_managed_src)" ""
    assert_not_contains "src removed from route" " src " "$ROUTES_FILE"
    assert_contains "gateway preserved" "via fe80::aaaa" "$ROUTES_FILE"

    # Now WAN128 becomes present and healthy (key changes).
    _wan128="2001:db8:beef::2"
    set_scenario "WAN128" "$_wan128"
    set_scenario "WAN128_PING_OK" "1"
    WAN128="$_wan128"

    ensure_router_source_policy
    assert_eq "native with healthy WAN128" "$(cached_mode)" "native"
    assert_eq "managed_src still empty" "$(cached_managed_src)" ""
    assert_not_contains "no src on route" " src " "$ROUTES_FILE"
}

# ================================================================
# Test J: Mode file contains invalid text while managed_src valid
# ================================================================
test_J() {
    echo "--- J: mode file invalid text, managed_src valid ---"
    add_route "default via fe80::aaaa dev eth1 metric 512"
    _wan128="2001:db8:dead::1"
    set_scenario "WAN128" "$_wan128"
    set_scenario "WAN128_PING_OK" "0"
    set_scenario "PD_PING_OK" "1"

    # Prime: pd-preferred, watchdog installs src.
    ensure_router_source_policy
    assert_eq "managed_src recorded" "$(cached_managed_src)" "$LAN_PD_SRC"

    # Corrupt mode file with invalid text.
    echo "garbage-invalid-mode" > "$SRC_POLICY_MODE_FILE"

    # WAN128 absent.
    set_scenario "WAN128" ""
    WAN128=""

    ensure_router_source_policy
    assert_eq "native after invalid mode" "$(cached_mode)" "native"
    assert_eq "managed_src cleaned" "$(cached_managed_src)" ""
    assert_not_contains "src removed" " src " "$ROUTES_FILE"
}

# ================================================================
# Test K: Mode says native but managed_src valid and route has owned src
# ================================================================
test_K() {
    echo "--- K: mode=native, managed_src valid, route has owned src ---"
    add_route "default via fe80::aaaa dev eth1 metric 512"
    _wan128="2001:db8:dead::1"
    set_scenario "WAN128" "$_wan128"
    set_scenario "WAN128_PING_OK" "0"
    set_scenario "PD_PING_OK" "1"

    # Prime: pd-preferred, watchdog installs src.
    ensure_router_source_policy
    assert_eq "managed_src recorded" "$(cached_managed_src)" "$LAN_PD_SRC"

    # Simulate: mode file says native (e.g. corrupted by a prior fast-path
    # write), but managed_src and route still have the watchdog's src.
    echo "native" > "$SRC_POLICY_MODE_FILE"

    # WAN128 absent, same key (no WAN128, same PD, same gw).
    set_scenario "WAN128" ""
    WAN128=""

    # First tick: fast path runs (WAN128 absent, mode=native != pd-preferred).
    # The fast path should detect managed_src and clean it up.
    ensure_router_source_policy
    assert_eq "native" "$(cached_mode)" "native"
    assert_eq "managed_src cleaned" "$(cached_managed_src)" ""
    assert_not_contains "src removed" " src " "$ROUTES_FILE"
}

# ================================================================
# Test L: Mode says native, managed_src valid, WAN128 healthy -> cleanup
# ================================================================
test_L() {
    echo "--- L: mode=native, managed_src valid, WAN128 healthy -> cleanup ---"
    add_route "default via fe80::aaaa dev eth1 metric 512"
    _wan128="2001:db8:dead::1"
    set_scenario "WAN128" "$_wan128"
    set_scenario "WAN128_PING_OK" "0"
    set_scenario "PD_PING_OK" "1"

    # Prime: pd-preferred, watchdog installs src.
    ensure_router_source_policy
    assert_eq "managed_src recorded" "$(cached_managed_src)" "$LAN_PD_SRC"

    # Simulate: mode file says native, but managed_src and route intact.
    echo "native" > "$SRC_POLICY_MODE_FILE"

    # WAN128 present and healthy (key changes because WAN128 is in the key).
    set_scenario "WAN128_PING_OK" "1"

    ensure_router_source_policy
    assert_eq "native" "$(cached_mode)" "native"
    assert_eq "managed_src cleaned" "$(cached_managed_src)" ""
    assert_not_contains "src removed" " src " "$ROUTES_FILE"
}

# ================================================================
# Test M: Mode says native, managed_src valid, route overridden by admin
#         -> ownership relinquished, admin src preserved
# ================================================================
test_M() {
    echo "--- M: mode=native, managed_src valid, admin overrode route ---"
    add_route "default via fe80::aaaa dev eth1 metric 512"
    _wan128="2001:db8:dead::1"
    set_scenario "WAN128" "$_wan128"
    set_scenario "WAN128_PING_OK" "0"
    set_scenario "PD_PING_OK" "1"

    # Prime: pd-preferred, watchdog installs src.
    ensure_router_source_policy
    assert_eq "managed_src recorded" "$(cached_managed_src)" "$LAN_PD_SRC"

    # Admin overrides the route with a different src.
    ADMIN_SRC="2001:db8:9999::1"
    : > "$ROUTES_FILE"
    add_route "default via fe80::aaaa dev eth1 src $ADMIN_SRC metric 512"

    # Mode file says native (corrupted), but managed_src still valid.
    echo "native" > "$SRC_POLICY_MODE_FILE"

    # WAN128 absent.
    set_scenario "WAN128" ""
    WAN128=""

    # Fast path should detect managed_src, call _remove_managed_preferred_src,
    # which checks cur_src != managed_src (admin override), and relinquishes
    # ownership without touching the route.
    ensure_router_source_policy
    assert_eq "native" "$(cached_mode)" "native"
    assert_eq "ownership relinquished" "$(cached_managed_src)" ""
    assert_contains "admin src preserved" "src $ADMIN_SRC" "$ROUTES_FILE"
}

# ================================================================
# Test N: Real iproute2 selector behavior - _generic_default_raw_line
#         returns route WITH dev token despite `dev` selector omitting it
# ================================================================
test_N() {
    echo "--- N: real iproute2 selector - raw line includes dev ---"
    # Fixture matching real live router output.
    add_route "default via fe80::aaaa dev eth1 proto static metric 512 pref medium"
    # Also add a source-specific default to prove it's excluded.
    add_route "default from 2001:db8:100::/56 via fe80::aaaa dev eth1 metric 512"

    _wan128="2001:db8:dead::1"
    set_scenario "WAN128" "$_wan128"
    set_scenario "WAN128_PING_OK" "0"
    set_scenario "PD_PING_OK" "1"
    # Enable real iproute2 selector behavior: `ip -6 route show default dev eth1`
    # strips `dev eth1` from output.
    set_scenario "REAL_IPROUTE2_SELECTOR" "1"

    # The production _generic_default_raw_line() must NOT use the dev
    # selector; it must use `ip -6 route show default` and filter by awk.
    # The returned line must contain `dev eth1`.
    raw=$(_generic_default_raw_line)
    # Direct check: the raw line should contain "dev eth1"
    if printf '%s\n' "$raw" | grep -q "dev eth1"; then
        pass "raw line includes dev eth1"
    else
        fail "raw line missing dev eth1 (got: $raw)"
    fi
    # Source-specific route must be excluded.
    if printf '%s\n' "$raw" | grep -q "^default from "; then
        fail "raw line is source-specific (should be generic only)"
    else
        pass "raw line is generic (not source-specific)"
    fi
}

# ================================================================
# Test O: Live fixture - proto static, pref medium, src install + cleanup
#         with real iproute2 selector behavior enabled
# ================================================================
test_O() {
    echo "--- O: live fixture with real iproute2 selector ---"
    add_route "default via fe80::aaaa dev eth1 proto static metric 512 pref medium"
    _wan128="2001:db8:dead::1"
    set_scenario "WAN128" "$_wan128"
    set_scenario "WAN128_PING_OK" "0"
    set_scenario "PD_PING_OK" "1"
    set_scenario "REAL_IPROUTE2_SELECTOR" "1"

    # Enter pd-preferred: src should be added, proto/pref/dev preserved.
    ensure_router_source_policy
    assert_eq "pd-preferred" "$(cached_mode)" "pd-preferred"
    assert_eq "managed_src recorded" "$(cached_managed_src)" "$LAN_PD_SRC"
    assert_contains "dev preserved" "dev eth1" "$ROUTES_FILE"
    assert_contains "proto preserved" "proto static" "$ROUTES_FILE"
    assert_contains "pref preserved" "pref medium" "$ROUTES_FILE"
    assert_contains "src added" "src $LAN_PD_SRC" "$ROUTES_FILE"
    assert_contains "metric preserved" "metric 512" "$ROUTES_FILE"
    assert_contains "gateway preserved" "via fe80::aaaa" "$ROUTES_FILE"

    # Transition to native: src removed, all attributes still preserved.
    set_scenario "WAN128_PING_OK" "1"
    WAN128="2001:db8:beef::2"
    set_scenario "WAN128" "2001:db8:beef::2"
    ensure_router_source_policy
    assert_eq "native" "$(cached_mode)" "native"
    assert_contains "dev still preserved" "dev eth1" "$ROUTES_FILE"
    assert_contains "proto still preserved" "proto static" "$ROUTES_FILE"
    assert_contains "pref still preserved" "pref medium" "$ROUTES_FILE"
    assert_not_contains "src removed" " src " "$ROUTES_FILE"
    assert_contains "metric still preserved" "metric 512" "$ROUTES_FILE"
}

# ================================================================
# Test P: Regression - catches the original bug
#         If _generic_default_raw_line regresses to using the dev selector
#         and the output omits dev, the route replace would fail.
#         This test proves the mock would have caught the live bug.
# ================================================================
test_P() {
    echo "--- P: regression - catches selector-based dev-omission bug ---"
    add_route "default via fe80::aaaa dev eth1 proto static metric 512 pref medium"
    set_scenario "REAL_IPROUTE2_SELECTOR" "1"

    # Simulate the OLD buggy behavior: query with dev selector, which
    # strips dev from the output. Then verify the raw line is missing dev.
    _buggy_raw=$(ip -6 route show default dev eth1 2>/dev/null | grep -v '^default from ' | head -1)
    if printf '%s\n' "$_buggy_raw" | grep -q "dev eth1"; then
        fail "buggy query unexpectedly has dev (mock not modeling real behavior)"
    else
        pass "buggy query strips dev (mock models real iproute2)"
    fi

    # Now verify the FIXED _generic_default_raw_line does NOT use the
    # selector and returns a line WITH dev.
    _fixed_raw=$(_generic_default_raw_line)
    if printf '%s\n' "$_fixed_raw" | grep -q "dev eth1"; then
        pass "fixed raw line has dev eth1"
    else
        fail "fixed raw line missing dev eth1 (got: $_fixed_raw)"
    fi

    # Prove the fixed line can be used for route replace (it has dev).
    # The mock's route replace handler needs `key_dev` to dedup; without
    # dev in the line, the replace would fail or not dedup correctly.
    _wan128="2001:db8:dead::1"
    set_scenario "WAN128" "$_wan128"
    set_scenario "WAN128_PING_OK" "0"
    set_scenario "PD_PING_OK" "1"

    ensure_router_source_policy
    assert_eq "pd-preferred installed" "$(cached_mode)" "pd-preferred"
    assert_eq "ownership recorded" "$(cached_managed_src)" "$LAN_PD_SRC"
    assert_contains "route has dev after install" "dev eth1" "$ROUTES_FILE"
    assert_contains "route has src after install" "src $LAN_PD_SRC" "$ROUTES_FILE"
}

# ================================================================
# Test Q: Install-failure diagnostic log
# ================================================================
test_Q() {
    echo "--- Q: install-failure diagnostic log ---"
    add_route "default via fe80::aaaa dev eth1 proto static metric 512 pref medium"
    _wan128="2001:db8:dead::1"
    set_scenario "WAN128" "$_wan128"
    set_scenario "WAN128_PING_OK" "0"
    set_scenario "PD_PING_OK" "1"
    set_scenario "FAIL_ROUTE_REPLACE" "1"
    : > "$WATCHDOG_LOG"

    ensure_router_source_policy
    assert_eq "pd-preferred classified" "$(cached_mode)" "pd-preferred"
    assert_eq "no ownership on failure" "$(cached_managed_src)" ""
    # The install failure should be logged.
    assert_contains "install failure logged" "preferred-src route install failed" "$WATCHDOG_LOG"
}

# ================================================================
# Run all tests
# ================================================================

echo "============================================"
echo "Source Policy Test Suite"
echo "============================================"

run_test test_1
run_test test_2
run_test test_3
run_test test_4
run_test test_5
run_test test_6
run_test test_7
run_test test_8
run_test test_9
run_test test_10
run_test test_11
run_test test_A
run_test test_B
run_test test_C
run_test test_D
run_test test_E
run_test test_F
run_test test_G
run_test test_H
run_test test_I
run_test test_J
run_test test_K
run_test test_L
run_test test_M
run_test test_N
run_test test_O
run_test test_P
run_test test_Q

echo "============================================"
echo "PASS: $PASS  FAIL: $FAIL"
echo "============================================"

[ "$FAIL" -eq 0 ] && exit 0 || exit 1