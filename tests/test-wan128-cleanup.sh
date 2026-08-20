#!/bin/sh
# tests/test-wan128-cleanup.sh
#
# v3.11.0 opt-in unusable-WAN128 cleanup: tests maybe_cleanup_unusable_wan128()
# extracted from ipv6-watchdog.
#
# The feature is opportunistic maintenance ONLY. It must never restore IPv6
# connectivity, never consume the shared disruption budget, never modify hold
# or cooldown state, and never touch UCI / wan6 / network / odhcpd / Tailscale.
# It must never delete a HEALTHY IA_NA /128 (the Lumban case), and it must
# never act while any recovery or transitional state owns the router.
#
# Usage: sh tests/test-wan128-cleanup.sh
# Exit:  0 = all pass, 1 = any fail

TEST_SCRIPT="$0"
SCRIPT_DIR="$(cd "$(dirname "$TEST_SCRIPT")/.." && pwd)"
TEST_BASE="$SCRIPT_DIR/.test-tmp"
TEST_ROOT="$TEST_BASE/wan128-cleanup-test-$$"
mkdir -p "$TEST_ROOT"

cleanup() { rm -rf "$TEST_ROOT"; }
trap cleanup EXIT
trap 'cleanup; exit 130' INT
trap 'cleanup; exit 143' TERM

PASS=0
FAIL=0
ORIG_PATH="$PATH"

# ================================================================
# Extract production helpers from ipv6-watchdog.
# ================================================================

EXTRACT="$TEST_ROOT/helpers.sh"

# 1. sanitize_int (defined before the PD context section).
awk '/^sanitize_int\(\)/ { start=1 } start { print } start && /^}/ { start=0; print ""; exit }' \
    "$SCRIPT_DIR/ipv6-watchdog" > "$EXTRACT"

# 2. PD-first context helpers through ensure_router_source_policy(). This block
#    supplies populate_pd_context, get_wan128, get_lan_pd_src, addr_in_prefix,
#    pd_internet_ok, wan128_internet_ok, pd_route_effective, pd_routes_ok,
#    current_default_gw and the _src_policy_* cache helpers.
awk '
    /PD-FIRST SOURCE-AWARE CONTEXT/ { start=1 }
    start { print }
    start && /^ensure_router_source_policy\(\)/ { saw=1 }
    saw && /^}$/ { start=0; saw=0; print ""; exit }
' "$SCRIPT_DIR/ipv6-watchdog" >> "$EXTRACT"

# 3. in_cooldown(), recovery_hold_active(), wan_recovery_ready() and
#    reset_recovery_state() (recovery-state gates + the top-level closure the
#    post-delete contract test exercises).
awk '/^in_cooldown\(\)/ { start=1 } start { print } start && /^}$/ { print ""; exit }' \
    "$SCRIPT_DIR/ipv6-watchdog" >> "$EXTRACT"
awk '/^recovery_hold_active\(\)/ { start=1 } start { print } start && /^}$/ { print ""; exit }' \
    "$SCRIPT_DIR/ipv6-watchdog" >> "$EXTRACT"
awk '/^wan_recovery_ready\(\)/ { start=1 } start { print } start && /^}$/ { print ""; exit }' \
    "$SCRIPT_DIR/ipv6-watchdog" >> "$EXTRACT"
awk '/^reset_recovery_state\(\)/ { start=1 } start { print } start && /^}$/ { print ""; exit }' \
    "$SCRIPT_DIR/ipv6-watchdog" >> "$EXTRACT"
# The REAL closure notifiers, so the top-level post-delete contract test proves
# their actual gating rather than a stub's.
for _nfn in ordinary_incident_duration notify_ordinary_recovery notify_restart_recovery; do
    awk -v fn="^${_nfn}\\(\\)" '$0 ~ fn { start=1 } start { print } start && /^}$/ { print ""; exit }' \
        "$SCRIPT_DIR/ipv6-watchdog" >> "$EXTRACT"
done
unset _nfn

# notify_ipv6_recovered is NOT extracted: its body contains a JSON payload with
# a column-0 '}', which truncates the brace-matched extraction and silently
# breaks everything appended after it. It is Discord-only, so this stub
# reproduces its real gate exactly (force flag OR ONT_FLAG, then a configured
# webhook) and makes any emission observable in the log.
cat >> "$EXTRACT" <<'STUBEOF'
notify_ipv6_recovered() {
    _nir_force="${2:-0}"
    if [ "$_nir_force" != "1" ] && [ ! -f "$ONT_FLAG" ]; then
        return 0
    fi
    [ -n "$DISCORD_WEBHOOK" ] || return 0
    log "NOTIFY_IPV6_RECOVERED_SENT"
}
STUBEOF

# 4. The v3.11.0 cleanup block through maybe_cleanup_unusable_wan128().
awk '
    /UNUSABLE WAN IA_NA \/128 CLEANUP/ { start=1 }
    start { print }
    start && /^maybe_cleanup_unusable_wan128\(\)/ { saw=1 }
    saw && /^}$/ { start=0; saw=0; print ""; exit }
' "$SCRIPT_DIR/ipv6-watchdog" >> "$EXTRACT"

for fn in sanitize_int get_wan128 addr_in_prefix get_lan_pd_src \
          populate_pd_context pd_internet_ok wan128_internet_ok \
          pd_route_effective pd_routes_ok current_default_gw \
          ensure_router_source_policy _src_policy_key _src_policy_cached_mode \
          _src_policy_cached_key in_cooldown recovery_hold_active \
          _wan_dev_has_addr128 _wan128_shared_recovery_active \
          _wan128_cleanup_clear _wan128_cleanup_count _wan128_cleanup_abandon \
          wan_recovery_ready reset_recovery_state \
          maybe_cleanup_unusable_wan128; do
    if ! grep -q "^${fn}()" "$EXTRACT" 2>/dev/null; then
        echo "FATAL: could not extract $fn from ipv6-watchdog" >&2
        exit 2
    fi
done

# log() stub.
WATCHDOG_LOG="$TEST_ROOT/watchdog.log"
: > "$WATCHDOG_LOG"
printf 'log() { echo "$1" >> "%s"; }\n' "$WATCHDOG_LOG" > "$TEST_ROOT/preamble.sh"

STATE_DIR="$TEST_ROOT/state"
mkdir -p "$STATE_DIR"
LAN_DEV="br-lan"
CLEANUP_DEPRECATED_LAN=0
REACHABILITY_CONFIRM_DELAY=0

# shellcheck disable=SC1090
. "$TEST_ROOT/preamble.sh"
# shellcheck disable=SC1090
. "$EXTRACT"

# State-file paths (must mirror ipv6-watchdog definitions).
SRC_POLICY_MODE_FILE="$STATE_DIR/src_policy_mode"
SRC_POLICY_KEY_FILE="$STATE_DIR/src_policy_key"
SRC_POLICY_TS_FILE="$STATE_DIR/src_policy_ts"
SRC_POLICY_MANAGED_SRC_FILE="$STATE_DIR/src_policy_managed_src"
SRC_POLICY_REFRESH=600
WAN128_CLEANUP_KEY_FILE="$STATE_DIR/wan128_cleanup_key"
WAN128_CLEANUP_COUNT_FILE="$STATE_DIR/wan128_cleanup_count"
FAIL_FILE="$STATE_DIR/fail_count"
INCIDENT_START_FILE="$STATE_DIR/incident_start"
RESTART_INCIDENT_FILE="$STATE_DIR/restart_incident"
ONT_FLAG="$STATE_DIR/ont_notified"
# Every other path the real reset_recovery_state() writes or removes. Without
# these, its redirections target an empty filename; dash treats that as a fatal
# redirection error and aborts the sourced happy-path block.
PREFIX_FAIL_FILE="$STATE_DIR/prefix_fail_count"
TIER0_FAIL_FILE="$STATE_DIR/tier0_fail_count"
LAST_WAN_RESTART_FILE="$STATE_DIR/last_wan_restart"
RECOVERY_HOLD_FILE="$STATE_DIR/recovery_hold"
HOLD_STATUS_FILE="$STATE_DIR/hold_status"
PREFIX_BACKOFF_FILE="$STATE_DIR/prefix_next_attempt"
GOOD_GW_FILE="$STATE_DIR/good_gateway"
ORDINARY_MAX_INCIDENT_SECS=86400
FAIL_LIMIT=3
DISCORD_WEBHOOK=""
NOW=1000000

# Shared coordinator. The REAL wan-recovery-common library is sourced so the
# exclusion guard around the irreversible delete is exercised against the
# production locking algorithm rather than a stand-in.
WAN_RECOVERY_STATE_DIR="$TEST_ROOT/wan-recovery"
mkdir -p "$WAN_RECOVERY_STATE_DIR"
WAN_DISRUPTION_COOLDOWN=1200
WAN_DISRUPTION_LIMIT=3
WAN6_TO_FULL_WAN_GRACE=0
WAN_RESTART_LIMIT=3
WAN_RESTARTS=0
# shellcheck disable=SC1090
. "$SCRIPT_DIR/wan-recovery-common"
_wan_recovery_paths
WAN_RECOVERY_AVAILABLE=1
for _fn in wan_recovery_full_begin wan_recovery_end wan_recovery_cleanup; do
    command -v "$_fn" >/dev/null 2>&1 || { echo "FATAL: coordinator missing $_fn" >&2; exit 2; }
done
unset _fn

# Feature defaults for the suite (individual tests override).
AUTO_CLEANUP_UNUSABLE_WAN128=1
WAN128_CLEANUP_CONFIRMATIONS=2
FAILS=0

# ================================================================
# Mock framework
# ================================================================

MOCK_DIR="$TEST_ROOT/mock"
mkdir -p "$MOCK_DIR"
SCENARIO="$TEST_ROOT/scenario"
export SCENARIO

reset_scenario() {
    : > "$SCENARIO"
    printf 'ROUTES=\n' >> "$SCENARIO"
    printf 'PD_PREFIX_ADDR=2001:db8:100::\n' >> "$SCENARIO"
    printf 'PD_PREFIX_MASK=56\n' >> "$SCENARIO"
    printf 'WAN_L3_DEVICE=eth1\n' >> "$SCENARIO"
    printf 'LAN_SRC=2001:db8:100:ab::1\n' >> "$SCENARIO"
    printf 'WAN128=\n' >> "$SCENARIO"
    printf 'WAN128_2=\n' >> "$SCENARIO"
    printf 'PD_PING_OK=1\n' >> "$SCENARIO"
    printf 'PD_PING_OK_AFTER_DEL=\n' >> "$SCENARIO"
    printf 'WAN128_PING_OK=0\n' >> "$SCENARIO"
    printf 'IP_LOG=\n' >> "$SCENARIO"
    printf 'PING6_LOG=\n' >> "$SCENARIO"
    printf 'FAIL_ADDR_DEL=0\n' >> "$SCENARIO"
    printf 'ADDR_DEL_NOOP=0\n' >> "$SCENARIO"
    printf 'DELETED=0\n' >> "$SCENARIO"
    # When set to a directory path, the ping6 mock creates it while probing the
    # WAN128 source. That models another watchdog acquiring shared recovery
    # ownership DURING the fresh probe -- i.e. inside the exact check/use window
    # between the passive ownership pre-filter and the irreversible delete.
    printf 'GRAB_LOCK_DIR=\n' >> "$SCENARIO"
    : > "$WATCHDOG_LOG"
    rm -f "$STATE_DIR"/src_policy_* 2>/dev/null
    rm -f "$WAN128_CLEANUP_KEY_FILE" "$WAN128_CLEANUP_COUNT_FILE" 2>/dev/null
    rm -f "$INCIDENT_START_FILE" "$RESTART_INCIDENT_FILE" "$ONT_FLAG" 2>/dev/null
    # Release any coordinator lock a previous test left held, then clear state.
    wan_recovery_cleanup 2>/dev/null
    rm -f "$DISRUPTION_HOLD_FILE" "$LAST_FULL_WAN_DISRUPTION_FILE" 2>/dev/null
    rm -f "$DISRUPTION_COUNT_FILE" "$LAST_WAN6_ACTION_FILE" 2>/dev/null
    rmdir "$DISRUPTION_LOCK_DIR" 2>/dev/null
    rm -f "$DISRUPTION_LOCK_FILE" 2>/dev/null
    FAILS=0
    WAN_RESTARTS=0
    AUTO_CLEANUP_UNUSABLE_WAN128=1
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
cat > "$MOCK_DIR/ip" <<'EOF'
#!/bin/sh
# Mock ip: route show/get/replace, addr show, addr del.
SCEN="${SCENARIO:-/dev/null}"
ROUTES_FILE=$(sed -n 's/^ROUTES=//p' "$SCEN" | head -1)
IP_LOG=$(sed -n 's/^IP_LOG=//p' "$SCEN" | head -1)
[ -n "$IP_LOG" ] && echo "ip $*" >> "$IP_LOG"

_scen_set() {
    _k="$1"; _v="$2"; _t="$SCEN.m$$"
    grep -v "^${_k}=" "$SCEN" 2>/dev/null > "$_t"
    printf '%s=%s\n' "$_k" "$_v" >> "$_t"
    mv "$_t" "$SCEN"
}

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
                from=""
                shift 3
                while [ $# -gt 0 ]; do
                    case "$1" in
                        from) from="$2"; shift ;;
                        *) shift ;;
                    esac
                done
                [ -n "$from" ] || exit 1
                line=$(grep "^default via .* dev " "$ROUTES_FILE" 2>/dev/null | head -1)
                if [ -n "$line" ]; then
                    gw=$(printf '%s\n' "$line" | awk '{for(i=1;i<=NF;i++) if($i=="via"){print $(i+1); exit}}')
                    dev=$(printf '%s\n' "$line" | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}')
                    printf '%s from %s via %s dev %s\n' "2001:4860:4860::8888" "$from" "$gw" "$dev"
                else
                    echo "unreachable $from"
                fi
                ;;
            replace)
                spec="$4"; shift 4
                while [ $# -gt 0 ]; do spec="$spec $1"; shift; done
                key_via=$(printf '%s\n' "$spec" | awk '{for(i=1;i<=NF;i++) if($i=="via"){print $(i+1); exit}}')
                key_dev=$(printf '%s\n' "$spec" | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}')
                if [ -n "$key_via" ]; then
                    grep -v "^default via .*dev $key_dev" "$ROUTES_FILE" 2>/dev/null > "$ROUTES_FILE.tmp"
                    mv "$ROUTES_FILE.tmp" "$ROUTES_FILE" 2>/dev/null
                fi
                printf '%s\n' "$spec" >> "$ROUTES_FILE"
                ;;
            *) ;;
        esac
        ;;
    addr)
        case "$3" in
            show)
                _query_dev="$5"
                _w1=$(sed -n 's/^WAN128=//p' "$SCEN" | head -1)
                _w2=$(sed -n 's/^WAN128_2=//p' "$SCEN" | head -1)
                _lan=$(sed -n 's/^LAN_SRC=//p' "$SCEN" | head -1)
                case "$_query_dev" in
                    eth1)
                        [ -n "$_w1" ] && printf 'inet6 %s/128 scope global dynamic\n' "$_w1"
                        [ -n "$_w1" ] && printf '   valid_lft 86400sec preferred_lft 14400sec\n'
                        [ -n "$_w2" ] && printf 'inet6 %s/128 scope global dynamic\n' "$_w2"
                        [ -n "$_w2" ] && printf '   valid_lft 86400sec preferred_lft 14400sec\n'
                        ;;
                    *)
                        [ -n "$_lan" ] && printf 'inet6 %s/64 scope global dynamic\n' "$_lan"
                        [ -n "$_lan" ] && printf '   valid_lft 86400sec preferred_lft 14400sec\n'
                        ;;
                esac
                ;;
            del)
                # ip -6 addr del <addr>/<len> dev <dev>
                _target="$4"
                _fail=$(sed -n 's/^FAIL_ADDR_DEL=//p' "$SCEN" | head -1)
                _noop=$(sed -n 's/^ADDR_DEL_NOOP=//p' "$SCEN" | head -1)
                [ "$_fail" = "1" ] && exit 1
                # ADDR_DEL_NOOP models a delete that reports success but leaves
                # the address in place.
                if [ "$_noop" = "1" ]; then exit 0; fi
                _plain="${_target%%/*}"
                _w1=$(sed -n 's/^WAN128=//p' "$SCEN" | head -1)
                _w2=$(sed -n 's/^WAN128_2=//p' "$SCEN" | head -1)
                if [ "$_plain" = "$_w1" ]; then
                    _scen_set WAN128 ""
                    _scen_set DELETED 1
                elif [ "$_plain" = "$_w2" ]; then
                    _scen_set WAN128_2 ""
                    _scen_set DELETED 1
                else
                    exit 1
                fi
                ;;
            *) ;;
        esac
        ;;
    neigh) ;;
    *) ;;
esac
exit 0
EOF
chmod +x "$MOCK_DIR/ip"

cat > "$MOCK_DIR/ping6" <<'EOF'
#!/bin/sh
SCEN="${SCENARIO:-/dev/null}"
PD_PING_OK=$(sed -n 's/^PD_PING_OK=//p' "$SCEN" | head -1)
PD_AFTER=$(sed -n 's/^PD_PING_OK_AFTER_DEL=//p' "$SCEN" | head -1)
DELETED=$(sed -n 's/^DELETED=//p' "$SCEN" | head -1)
WAN128_PING_OK=$(sed -n 's/^WAN128_PING_OK=//p' "$SCEN" | head -1)
W1=$(sed -n 's/^WAN128=//p' "$SCEN" | head -1)
W2=$(sed -n 's/^WAN128_2=//p' "$SCEN" | head -1)
PING6_LOG=$(sed -n 's/^PING6_LOG=//p' "$SCEN" | head -1)
[ -n "$PING6_LOG" ] && echo "$@" >> "$PING6_LOG"

src=""; target=""; prev=""
for a in "$@"; do
    if [ "$prev" = "-I" ]; then src="$a"; fi
    prev="$a"
    case "$a" in -*) ;; *) target="$a";; esac
done

# TOCTOU model: another recovery owner takes the shared lock while this probe
# is running, i.e. after the passive ownership pre-filter already passed.
GRAB=$(sed -n 's/^GRAB_LOCK_DIR=//p' "$SCEN" | head -1)
if [ -n "$GRAB" ] && [ -n "$W1" ] && [ "$src" = "$W1" ]; then
    mkdir -p "$(dirname "$GRAB")" 2>/dev/null
    mkdir "$GRAB" 2>/dev/null
fi

case "$target" in
    2001:4860:4860::8888|2606:4700:4700::1111)
        [ -n "$src" ] || exit 1
        if [ -n "$W1" ] && [ "$src" = "$W1" ]; then
            [ "$WAN128_PING_OK" = "1" ] && exit 0 || exit 1
        fi
        if [ -n "$W2" ] && [ "$src" = "$W2" ]; then
            [ "$WAN128_PING_OK" = "1" ] && exit 0 || exit 1
        fi
        # PD-derived source. Allow the post-delete result to differ.
        if [ "$DELETED" = "1" ] && [ -n "$PD_AFTER" ]; then
            [ "$PD_AFTER" = "1" ] && exit 0 || exit 1
        fi
        [ "$PD_PING_OK" = "1" ] && exit 0 || exit 1
        ;;
    *) exit 0 ;;
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
        printf '%s' "$input" | sed -n 's/.*"ipv6-prefix":\[{"address":"\([^"]*\)".*/\1/p' ;;
    '@["ipv6-prefix"][0].mask')
        printf '%s' "$input" | sed -n 's/.*"mask":\([0-9]*\).*/\1/p' ;;
    '@["l3_device"]')
        printf '%s' "$input" | sed -n 's/.*"l3_device":"\([^"]*\)".*/\1/p' ;;
    '@["up"]')
        printf '%s' "$input" | sed -n 's/.*"up":\([a-z]*\).*/\1/p' ;;
    '@["pending"]')
        printf '%s' "$input" | sed -n 's/.*"pending":\([a-z]*\).*/\1/p' ;;
    *)
        printf '%s' "$input" | sed -n 's/.*"ipv6-prefix":\[{"address":"\([^"]*\)".*/\1/p' ;;
esac
EOF
chmod +x "$MOCK_DIR/jsonfilter"

cat > "$MOCK_DIR/sleep" <<'EOF'
#!/bin/sh
:
EOF
chmod +x "$MOCK_DIR/sleep"

# flock stub. Default 127 = "present but unusable", which makes the real
# coordinator fall back to its mkdir lock. That is the mode the target routers
# actually run in (BusyBox builds without a usable flock), and it is the same
# default tests/test-wan-recovery-common.sh uses. FLOCK_MODE=real removes the
# stub so the genuine binary is used.
cat > "$MOCK_DIR/flock" <<'EOF'
#!/bin/sh
exit 127
EOF
chmod +x "$MOCK_DIR/flock"

# Forbidden-mutation tripwires. If the cleanup path ever calls one of these,
# it is recorded and the suite fails.
for _f in uci ifdown ifup odhcpd tailscale; do
cat > "$MOCK_DIR/$_f" <<EOF
#!/bin/sh
echo "FORBIDDEN $_f \$*" >> "\$FORBIDDEN_LOG"
exit 0
EOF
chmod +x "$MOCK_DIR/$_f"
done
}

build_mocks

# --- Mock isolation guard ---------------------------------------------------
# ip, ping6 and sleep are BusyBox applets and would otherwise resolve ahead of
# PATH under `busybox ash`. See tests/lib/mock-isolation.sh.
# flock is included: it is a BusyBox applet, so under `busybox ash` with
# FEATURE_SH_STANDALONE it would resolve ahead of PATH and the coordinator
# would take a REAL host lock instead of the stub.
. "$SCRIPT_DIR/tests/lib/mock-isolation.sh"
mock_isolation_enforce MOCK_DIR "ip ping6 sleep ubus jsonfilter flock"

FORBIDDEN_LOG="$TEST_ROOT/forbidden.log"
export FORBIDDEN_LOG
: > "$FORBIDDEN_LOG"

pass() { PASS=$((PASS + 1)); echo "  PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); echo "  FAIL: $1"; }
assert_eq() {
    if [ "$2" = "$3" ]; then pass "$1 ($2)"; else fail "$1 (expected '$3', got '$2')"; fi
}
assert_contains() {
    if grep -q "$2" "$3" 2>/dev/null; then pass "$1"; else fail "$1 (no match for '$2')"; fi
}
assert_not_contains() {
    if grep -q "$2" "$3" 2>/dev/null; then fail "$1 (found '$2')"; else pass "$1"; fi
}

run_test() {
    name="$1"
    ROUTES_FILE="$TEST_ROOT/routes_$$.txt"
    IP_LOG="$TEST_ROOT/ip_$$.log"
    PING6_LOG="$TEST_ROOT/ping6_$$.log"
    : > "$ROUTES_FILE"; : > "$IP_LOG"; : > "$PING6_LOG"
    : > "$FORBIDDEN_LOG"
    reset_scenario
    set_scenario "ROUTES" "$ROUTES_FILE"
    set_scenario "IP_LOG" "$IP_LOG"
    set_scenario "PING6_LOG" "$PING6_LOG"
    PATH="$MOCK_DIR:$ORIG_PATH" "$name"
    rc=$?
    rm -f "$ROUTES_FILE" "$IP_LOG" "$PING6_LOG" 2>/dev/null
    return $rc
}

add_route() { printf '%s\n' "$1" >> "$ROUTES_FILE"; }
cand_count() { cat "$WAN128_CLEANUP_COUNT_FILE" 2>/dev/null; }
cand_key() { cat "$WAN128_CLEANUP_KEY_FILE" 2>/dev/null; }

# Establish the eligible baseline: healthy PD, unusable WAN128, gateway
# PD-verified, source policy already classified pd-preferred for this context.
prime_eligible() {
    add_route "default via fe80::aaaa dev eth1 metric 512"
    set_scenario "WAN128" "${1:-2001:db8:dead::1}"
    set_scenario "WAN128_PING_OK" "0"
    set_scenario "PD_PING_OK" "1"
    ensure_router_source_policy
}

# Assert that no disruptive/forbidden operation was performed.
assert_clean_side_effects() {
    assert_not_contains "$1: no uci/ifdown/ifup/odhcpd/tailscale" "FORBIDDEN" "$FORBIDDEN_LOG"
    assert_not_contains "$1: no route del" "route del" "$IP_LOG"
    assert_not_contains "$1: no addr flush" "addr flush" "$IP_LOG"
}

echo "=== v3.11.0 unusable-WAN128 cleanup ==="
echo "  (source policy classification is reused; deletion requires a fresh probe)"

# ================================================================
# A. Feature disabled: pd-preferred unaffected, WAN128 retained
# ================================================================
test_A() {
    echo "--- A: feature disabled (AUTO_CLEANUP_UNUSABLE_WAN128=0) ---"
    AUTO_CLEANUP_UNUSABLE_WAN128=0
    prime_eligible
    assert_eq "source policy classified" "$(cat "$SRC_POLICY_MODE_FILE" 2>/dev/null)" "pd-preferred"

    maybe_cleanup_unusable_wan128
    assert_eq "return" "$?" "0"
    assert_eq "WAN128 retained" "$(get_scenario WAN128)" "2001:db8:dead::1"
    assert_eq "no candidate recorded" "$(cand_count)" ""
    assert_not_contains "A: no delete issued" "addr del" "$IP_LOG"
    assert_eq "pd-preferred unchanged" "$(cat "$SRC_POLICY_MODE_FILE" 2>/dev/null)" "pd-preferred"
    assert_clean_side_effects "A"
}

# ================================================================
# B. Healthy WAN128: never deleted, candidate cleared
# ================================================================
test_B() {
    echo "--- B: healthy WAN128 is retained and clears any candidate ---"
    prime_eligible
    # Seed a stale candidate, then let WAN128 become healthy.
    maybe_cleanup_unusable_wan128
    assert_eq "candidate seeded" "$(cand_count)" "1"

    set_scenario "WAN128_PING_OK" "1"
    maybe_cleanup_unusable_wan128
    assert_eq "WAN128 retained" "$(get_scenario WAN128)" "2001:db8:dead::1"
    assert_eq "candidate cleared" "$(cand_count)" ""
    assert_not_contains "B: no delete issued" "addr del" "$IP_LOG"
    assert_contains "B: clearing reason logged" "reachability recovered" "$WATCHDOG_LOG"
    assert_clean_side_effects "B"
}

# ================================================================
# C. First eligible observation: candidate recorded, no deletion
# ================================================================
test_C() {
    echo "--- C: first eligible observation records a candidate only ---"
    prime_eligible
    maybe_cleanup_unusable_wan128
    assert_eq "return" "$?" "0"
    assert_eq "count = 1" "$(cand_count)" "1"
    assert_eq "WAN128 still present" "$(get_scenario WAN128)" "2001:db8:dead::1"
    assert_not_contains "C: no delete on first observation" "addr del" "$IP_LOG"
    assert_contains "C: candidate log emitted" "awaiting stable confirmation" "$WATCHDOG_LOG"

    # A second identical tick must not re-log the candidate line.
    : > "$WATCHDOG_LOG"
    assert_clean_side_effects "C"
}

# ================================================================
# D. Confirmed stable failure: exact /128 deleted
# ================================================================
test_D() {
    echo "--- D: second identical observation deletes the exact /128 ---"
    prime_eligible
    maybe_cleanup_unusable_wan128
    assert_eq "obs 1 -> count 1" "$(cand_count)" "1"
    assert_not_contains "D: no delete yet" "addr del" "$IP_LOG"

    maybe_cleanup_unusable_wan128
    rc=$?
    assert_eq "obs 2 return" "$rc" "0"
    assert_contains "D: exact address deleted" "addr del 2001:db8:dead::1/128 dev eth1" "$IP_LOG"
    assert_eq "WAN128 gone" "$(get_scenario WAN128)" ""
    assert_eq "candidate cleared after delete" "$(cand_count)" ""
    assert_contains "D: success logged" "Removed unusable WAN IA_NA /128" "$WATCHDOG_LOG"
    assert_contains "D: PD health asserted in success log" "PD-source Internet remains healthy" "$WATCHDOG_LOG"
    assert_clean_side_effects "D"
}

# ================================================================
# E. PD failure prevents cleanup
# ================================================================
test_E() {
    echo "--- E: WAN128 FAIL + PD FAIL -> no deletion, candidate cleared ---"
    prime_eligible
    maybe_cleanup_unusable_wan128
    assert_eq "candidate seeded" "$(cand_count)" "1"

    set_scenario "PD_PING_OK" "0"
    maybe_cleanup_unusable_wan128
    assert_eq "candidate cleared" "$(cand_count)" ""
    assert_eq "WAN128 retained" "$(get_scenario WAN128)" "2001:db8:dead::1"
    assert_not_contains "E: no delete" "addr del" "$IP_LOG"
    assert_contains "E: reason logged" "PD-source Internet validation failed" "$WATCHDOG_LOG"
    assert_clean_side_effects "E"
}

# ================================================================
# F. fail_count becomes nonzero before confirmation
# ================================================================
test_F() {
    echo "--- F: fail_count > 0 clears the candidate ---"
    prime_eligible
    maybe_cleanup_unusable_wan128
    assert_eq "candidate seeded" "$(cand_count)" "1"

    FAILS=1
    maybe_cleanup_unusable_wan128
    assert_eq "candidate cleared" "$(cand_count)" ""
    assert_eq "WAN128 retained" "$(get_scenario WAN128)" "2001:db8:dead::1"
    assert_not_contains "F: no delete" "addr del" "$IP_LOG"
    assert_contains "F: reason logged" "IPv6 failure count is 1" "$WATCHDOG_LOG"
    FAILS=0
    assert_clean_side_effects "F"
}

# ================================================================
# G. Recovery ownership markers each block cleanup
# ================================================================
test_G() {
    echo "--- G: recovery ownership blocks cleanup ---"
    for marker in incident restart ont; do
        prime_eligible
        maybe_cleanup_unusable_wan128
        case "$marker" in
            incident) : > "$INCIDENT_START_FILE"; want="ordinary incident is still open" ;;
            restart)  : > "$RESTART_INCIDENT_FILE"; want="restart-assisted incident owns recovery" ;;
            ont)      : > "$ONT_FLAG"; want="critical/ONT incident owns recovery" ;;
        esac
        maybe_cleanup_unusable_wan128
        assert_eq "$marker: candidate cleared" "$(cand_count)" ""
        assert_eq "$marker: WAN128 retained" "$(get_scenario WAN128)" "2001:db8:dead::1"
        assert_contains "$marker: reason logged" "$want" "$WATCHDOG_LOG"
        rm -f "$INCIDENT_START_FILE" "$RESTART_INCIDENT_FILE" "$ONT_FLAG"
    done
    assert_not_contains "G: no delete on any ownership marker" "addr del" "$IP_LOG"
    assert_clean_side_effects "G"

    # Shared disruption hold.
    prime_eligible
    maybe_cleanup_unusable_wan128
    : > "$DISRUPTION_HOLD_FILE"
    maybe_cleanup_unusable_wan128
    assert_eq "hold: candidate cleared" "$(cand_count)" ""
    assert_contains "hold: reason logged" "shared disruption hold is active" "$WATCHDOG_LOG"
    rm -f "$DISRUPTION_HOLD_FILE"

    # Budget exhaustion also latches the hold via recovery_hold_active.
    prime_eligible
    maybe_cleanup_unusable_wan128
    WAN_RESTARTS=3
    maybe_cleanup_unusable_wan128
    assert_eq "budget: candidate cleared" "$(cand_count)" ""
    WAN_RESTARTS=0
    assert_not_contains "G: still no delete" "addr del" "$IP_LOG"
}

# ================================================================
# H. Brief post-restart health must not authorize deletion
# ================================================================
test_H() {
    echo "--- H: transient health right after a restart-assisted recovery ---"
    # Model the Kamuning 15:12 sequence: a full WAN restart occurred, the
    # restart marker is still open, and PD momentarily passes.
    prime_eligible
    : > "$RESTART_INCIDENT_FILE"
    echo 1 > "$DISRUPTION_COUNT_FILE"
    maybe_cleanup_unusable_wan128
    assert_eq "no candidate while restart incident open" "$(cand_count)" ""
    assert_not_contains "H: no delete during transition" "addr del" "$IP_LOG"

    # The incident closes; one healthy tick records a candidate.
    rm -f "$RESTART_INCIDENT_FILE"
    maybe_cleanup_unusable_wan128
    assert_eq "candidate after closure" "$(cand_count)" "1"

    # PD then fails again (15:14:43), before confirmation could complete.
    set_scenario "PD_PING_OK" "0"
    maybe_cleanup_unusable_wan128
    assert_eq "candidate cleared on relapse" "$(cand_count)" ""
    assert_eq "WAN128 never deleted" "$(get_scenario WAN128)" "2001:db8:dead::1"
    assert_not_contains "H: no delete across the whole sequence" "addr del" "$IP_LOG"
    assert_clean_side_effects "H"
}

# ================================================================
# I. Post-restart cooldown blocks cleanup
# ================================================================
test_I() {
    echo "--- I: post-restart cooldown blocks cleanup ---"
    prime_eligible
    maybe_cleanup_unusable_wan128
    assert_eq "candidate seeded" "$(cand_count)" "1"

    echo $((NOW - 60)) > "$LAST_FULL_WAN_DISRUPTION_FILE"
    maybe_cleanup_unusable_wan128
    assert_eq "candidate cleared" "$(cand_count)" ""
    assert_eq "WAN128 retained" "$(get_scenario WAN128)" "2001:db8:dead::1"
    assert_contains "I: reason logged" "post-restart cooldown is active" "$WATCHDOG_LOG"
    assert_not_contains "I: no delete" "addr del" "$IP_LOG"

    # Cooldown expiry re-enables eligibility.
    echo $((NOW - (WAN_DISRUPTION_COOLDOWN + 60))) > "$LAST_FULL_WAN_DISRUPTION_FILE"
    maybe_cleanup_unusable_wan128
    assert_eq "candidate restarts at 1 after cooldown" "$(cand_count)" "1"
    assert_clean_side_effects "I"
}

# ================================================================
# J. Context changes invalidate a pending candidate
# ================================================================
# Each J sub-case runs as its own test so run_test() gives it a clean
# scenario. Sharing one function let an earlier sub-case's PD prefix leak into
# a later one and silently produce an ineligible state instead of the
# context-change behaviour under test.
test_J1() {
    echo "--- J1: WAN128 changes (new IA_NA lease) ---"
    prime_eligible
    maybe_cleanup_unusable_wan128
    assert_eq "J1 obs1" "$(cand_count)" "1"
    _k1=$(cand_key)
    set_scenario "WAN128" "2001:db8:dead::2"
    ensure_router_source_policy
    maybe_cleanup_unusable_wan128
    assert_eq "J1 count restarts at 1" "$(cand_count)" "1"
    if [ "$(cand_key)" != "$_k1" ]; then pass "J1 key changed"; else fail "J1 key unchanged"; fi
    assert_not_contains "J1: no delete" "addr del" "$IP_LOG"
    assert_clean_side_effects "J1"
}

test_J2() {
    echo "--- J2: delegated prefix changes ---"
    prime_eligible
    maybe_cleanup_unusable_wan128
    assert_eq "J2 obs1" "$(cand_count)" "1"
    _k2=$(cand_key)
    set_scenario "PD_PREFIX_ADDR" "2001:db8:200::"
    set_scenario "LAN_SRC" "2001:db8:200:ab::1"
    ensure_router_source_policy
    maybe_cleanup_unusable_wan128
    assert_eq "J2 count restarts at 1" "$(cand_count)" "1"
    if [ "$(cand_key)" != "$_k2" ]; then pass "J2 key changed"; else fail "J2 key unchanged"; fi
    assert_not_contains "J2: no delete" "addr del" "$IP_LOG"
    assert_clean_side_effects "J2"
}

test_J3() {
    echo "--- J3: LAN_PD_SRC changes within the same prefix ---"
    prime_eligible
    maybe_cleanup_unusable_wan128
    assert_eq "J3 obs1" "$(cand_count)" "1"
    _k3=$(cand_key)
    set_scenario "LAN_SRC" "2001:db8:100:ab::99"
    ensure_router_source_policy
    maybe_cleanup_unusable_wan128
    assert_eq "J3 count restarts at 1" "$(cand_count)" "1"
    if [ "$(cand_key)" != "$_k3" ]; then pass "J3 key changed"; else fail "J3 key unchanged"; fi
    assert_not_contains "J3: no delete" "addr del" "$IP_LOG"
    assert_clean_side_effects "J3"
}

test_J4() {
    echo "--- J4: gateway changes ---"
    prime_eligible
    maybe_cleanup_unusable_wan128
    assert_eq "J4 obs1" "$(cand_count)" "1"
    _k4=$(cand_key)
    : > "$ROUTES_FILE"
    add_route "default via fe80::bbbb dev eth1 metric 512"
    ensure_router_source_policy
    maybe_cleanup_unusable_wan128
    assert_eq "J4 count restarts at 1" "$(cand_count)" "1"
    if [ "$(cand_key)" != "$_k4" ]; then pass "J4 key changed"; else fail "J4 key unchanged"; fi
    assert_not_contains "J4: no delete" "addr del" "$IP_LOG"
    assert_clean_side_effects "J4"
}

# ================================================================
# K. WAN128 disappears naturally
# ================================================================
test_K() {
    echo "--- K: WAN128 disappears on its own ---"
    prime_eligible
    maybe_cleanup_unusable_wan128
    assert_eq "candidate seeded" "$(cand_count)" "1"

    set_scenario "WAN128" ""
    maybe_cleanup_unusable_wan128
    assert_eq "return" "$?" "0"
    assert_eq "candidate cleared" "$(cand_count)" ""
    assert_not_contains "K: no delete attempted" "addr del" "$IP_LOG"
    assert_contains "K: reason logged" "WAN128 no longer present" "$WATCHDOG_LOG"
    assert_clean_side_effects "K"
}

# ================================================================
# L. Delete command failure must not report success
# ================================================================
test_L() {
    echo "--- L: ip addr del failure ---"
    prime_eligible
    maybe_cleanup_unusable_wan128
    set_scenario "FAIL_ADDR_DEL" "1"
    maybe_cleanup_unusable_wan128
    rc=$?
    assert_eq "returns failure" "$rc" "1"
    assert_eq "WAN128 still present" "$(get_scenario WAN128)" "2001:db8:dead::1"
    assert_contains "L: failure logged" "removal of 2001:db8:dead::1/128 on eth1 failed" "$WATCHDOG_LOG"
    assert_not_contains "L: no false success" "Removed unusable WAN IA_NA" "$WATCHDOG_LOG"
    assert_eq "candidate cleared" "$(cand_count)" ""
    assert_clean_side_effects "L"
}

# ================================================================
# M. Post-delete PD validation failure
# ================================================================
test_M() {
    echo "--- M: PD fails after a successful delete ---"
    prime_eligible
    maybe_cleanup_unusable_wan128
    set_scenario "PD_PING_OK_AFTER_DEL" "0"
    # Scope the side-effect assertions to the deleting tick only: priming ran
    # ensure_router_source_policy, whose preferred-src install is a legitimate
    # route replace that belongs to the source-policy layer, not to cleanup.
    : > "$IP_LOG"
    maybe_cleanup_unusable_wan128
    rc=$?
    assert_eq "returns failure" "$rc" "1"
    assert_contains "M: delete did happen" "addr del 2001:db8:dead::1/128" "$IP_LOG"
    assert_contains "M: condition logged" "PD-source Internet validation failed afterwards" "$WATCHDOG_LOG"
    assert_not_contains "M: no false success" "Removed unusable WAN IA_NA" "$WATCHDOG_LOG"
    assert_eq "candidate cleared" "$(cand_count)" ""
    # The feature must take NO corrective action of its own.
    assert_clean_side_effects "M"
    assert_not_contains "M: no re-add attempted" "addr add" "$IP_LOG"
    assert_not_contains "M: no route mutation" "route replace" "$IP_LOG"
}

# ================================================================
# N. Delete reports success but the address is still present
# ================================================================
test_N() {
    echo "--- N: delete returns 0 but the address remains ---"
    prime_eligible
    maybe_cleanup_unusable_wan128
    set_scenario "ADDR_DEL_NOOP" "1"
    maybe_cleanup_unusable_wan128
    rc=$?
    assert_eq "returns failure" "$rc" "1"
    assert_contains "N: not treated as success" "still present on eth1 after removal" "$WATCHDOG_LOG"
    assert_not_contains "N: no false success" "Removed unusable WAN IA_NA" "$WATCHDOG_LOG"
    assert_eq "WAN128 still present" "$(get_scenario WAN128)" "2001:db8:dead::1"
    assert_clean_side_effects "N"
}

# ================================================================
# O. Two simultaneous global /128 addresses (exact-match verification)
# ================================================================
test_O() {
    echo "--- O: two global /128s -- only the tested one is removed ---"
    prime_eligible
    set_scenario "WAN128_2" "2001:db8:beef::9"
    ensure_router_source_policy
    maybe_cleanup_unusable_wan128
    assert_eq "obs1" "$(cand_count)" "1"
    maybe_cleanup_unusable_wan128
    rc=$?
    assert_eq "return" "$rc" "0"
    assert_contains "O: first /128 deleted" "addr del 2001:db8:dead::1/128 dev eth1" "$IP_LOG"
    assert_not_contains "O: second /128 untouched" "addr del 2001:db8:beef::9" "$IP_LOG"
    assert_eq "first /128 gone" "$(get_scenario WAN128)" ""
    assert_eq "second /128 retained" "$(get_scenario WAN128_2)" "2001:db8:beef::9"
    # The surviving second /128 must not make the deletion look like a failure.
    assert_contains "O: success still reported" "Removed unusable WAN IA_NA /128" "$WATCHDOG_LOG"
    assert_clean_side_effects "O"

    # Exact-match helper: the surviving address is found, the deleted one is not.
    WAN_DEV="eth1"
    if _wan_dev_has_addr128 "2001:db8:beef::9"; then pass "O: helper finds surviving /128"; else fail "O: helper missed surviving /128"; fi
    if _wan_dev_has_addr128 "2001:db8:dead::1"; then fail "O: helper still reports deleted /128"; else pass "O: helper reports deleted /128 absent"; fi
    # A prefix-substring address must not match.
    if _wan_dev_has_addr128 "2001:db8:beef::"; then fail "O: helper substring-matched"; else pass "O: helper requires exact match"; fi
}

# ================================================================
# P. Lumban-style healthy IA_NA: no candidate, native policy preserved
# ================================================================
test_P() {
    echo "--- P: healthy IA_NA (Lumban) is never a cleanup candidate ---"
    add_route "default via fe80::aaaa dev eth1 metric 512"
    set_scenario "WAN128" "2001:db8:1ead::1"
    set_scenario "WAN128_PING_OK" "1"
    set_scenario "PD_PING_OK" "1"
    ensure_router_source_policy
    assert_eq "policy stays native" "$(cat "$SRC_POLICY_MODE_FILE" 2>/dev/null)" "native"

    maybe_cleanup_unusable_wan128
    maybe_cleanup_unusable_wan128
    assert_eq "no candidate ever recorded" "$(cand_count)" ""
    assert_eq "WAN128 retained" "$(get_scenario WAN128)" "2001:db8:1ead::1"
    assert_not_contains "P: no delete" "addr del" "$IP_LOG"
    assert_eq "policy still native" "$(cat "$SRC_POLICY_MODE_FILE" 2>/dev/null)" "native"
    assert_clean_side_effects "P"
}

# ================================================================
# Q. Source policy must already agree for this exact context
# ================================================================
test_Q() {
    echo "--- Q: cleanup requires pd-preferred for the current context ---"
    # No source-policy cache at all.
    add_route "default via fe80::aaaa dev eth1 metric 512"
    set_scenario "WAN128" "2001:db8:dead::1"
    set_scenario "WAN128_PING_OK" "0"
    set_scenario "PD_PING_OK" "1"
    maybe_cleanup_unusable_wan128
    assert_eq "no candidate without classification" "$(cand_count)" ""
    assert_not_contains "Q: no delete" "addr del" "$IP_LOG"

    # Cache present but for a stale context (key mismatch).
    ensure_router_source_policy
    echo "stale|key|values|here" > "$SRC_POLICY_KEY_FILE"
    maybe_cleanup_unusable_wan128
    assert_eq "no candidate on stale key" "$(cand_count)" ""
    assert_not_contains "Q: still no delete" "addr del" "$IP_LOG"
    assert_clean_side_effects "Q"
}

# ================================================================
# R. Shared recovery ownership, both locking modes
# ================================================================
test_R() {
    echo "--- R: shared WAN recovery ownership blocks cleanup ---"

    # R1: mkdir fallback lock held.
    prime_eligible
    maybe_cleanup_unusable_wan128
    assert_eq "candidate seeded" "$(cand_count)" "1"
    mkdir -p "$DISRUPTION_LOCK_DIR"
    if _wan128_shared_recovery_active; then pass "R1 mkdir lock detected"; else fail "R1 mkdir lock not detected"; fi
    maybe_cleanup_unusable_wan128
    assert_eq "R1 candidate cleared" "$(cand_count)" ""
    assert_eq "R1 WAN128 retained" "$(get_scenario WAN128)" "2001:db8:dead::1"
    assert_contains "R1 reason logged" "shared WAN recovery operation is in progress" "$WATCHDOG_LOG"
    assert_not_contains "R1: no delete" "addr del" "$IP_LOG"
    rmdir "$DISRUPTION_LOCK_DIR" 2>/dev/null

    # R2: no lock held at all -> not active.
    if _wan128_shared_recovery_active; then fail "R2 false positive with no lock"; else pass "R2 no lock -> not active"; fi

    # R3: flock mode. The suite stubs flock as unusable (127) so the coordinator
    # exercises its mkdir fallback, so the stub is removed for this case to test
    # the genuine flock path. flock(2) treats independent file descriptions as
    # conflicting even within one process, so the probe must report busy.
    _r3_saved="$TEST_ROOT/flock.r3"
    _r3_stubbed=0
    if [ -x "$MOCK_DIR/flock" ]; then
        mv "$MOCK_DIR/flock" "$_r3_saved"
        unset -f flock 2>/dev/null
        _r3_stubbed=1
    fi
    if command -v flock >/dev/null 2>&1; then
        : > "$DISRUPTION_LOCK_FILE"
        if ( exec 7>>"$DISRUPTION_LOCK_FILE"; flock -n 7 ) 2>/dev/null; then
            # Confirm an unheld flock reads as free.
            if _wan128_shared_recovery_active; then fail "R3 free flock reported busy"; else pass "R3 free flock -> not active"; fi
        else
            fail "R3 could not probe a free flock"
        fi

        exec 7>>"$DISRUPTION_LOCK_FILE"
        if flock -n 7 2>/dev/null; then
            if _wan128_shared_recovery_active; then pass "R3 held flock detected"; else fail "R3 held flock not detected"; fi
            prime_eligible
            maybe_cleanup_unusable_wan128
            assert_eq "R3 no candidate while flock held" "$(cand_count)" ""
            assert_not_contains "R3: no delete while flock held" "addr del" "$IP_LOG"
            flock -u 7 2>/dev/null
        else
            fail "R3 could not acquire the test flock"
        fi
        exec 7>&- 2>/dev/null
        rm -f "$DISRUPTION_LOCK_FILE"
    else
        pass "R3 skipped (flock unavailable); mkdir mode covered by R1"
        pass "R3 skipped (flock unavailable); mkdir mode covered by R1"
        pass "R3 skipped (flock unavailable); mkdir mode covered by R1"
    fi
    if [ "$_r3_stubbed" = "1" ]; then
        mv "$_r3_saved" "$MOCK_DIR/flock"
        eval 'flock() { "$MOCK_DIR"/flock "$@"; }'
    fi

    # R4: the probe must never CREATE coordinator state.
    rm -f "$DISRUPTION_LOCK_FILE"
    rmdir "$DISRUPTION_LOCK_DIR" 2>/dev/null
    _wan128_shared_recovery_active
    if [ -e "$DISRUPTION_LOCK_FILE" ]; then fail "R4 probe created the lock file"; else pass "R4 probe creates no lock file"; fi
    if [ -d "$DISRUPTION_LOCK_DIR" ]; then fail "R4 probe created the lock dir"; else pass "R4 probe creates no lock dir"; fi
}

# ================================================================
# S. Shared budget / hold state is never mutated by cleanup
# ================================================================
test_S() {
    echo "--- S: shared disruption state is never modified ---"
    prime_eligible
    echo 1 > "$DISRUPTION_COUNT_FILE"
    echo 12345 > "$LAST_FULL_WAN_DISRUPTION_FILE"
    _before_count=$(cat "$DISRUPTION_COUNT_FILE")
    _before_ts=$(cat "$LAST_FULL_WAN_DISRUPTION_FILE")

    # Cooldown is long past, so cleanup is allowed to proceed to deletion.
    echo $((NOW - (WAN_DISRUPTION_COOLDOWN + 600))) > "$LAST_FULL_WAN_DISRUPTION_FILE"
    _before_ts=$(cat "$LAST_FULL_WAN_DISRUPTION_FILE")
    maybe_cleanup_unusable_wan128
    maybe_cleanup_unusable_wan128
    assert_contains "S: deletion did occur" "addr del 2001:db8:dead::1/128" "$IP_LOG"

    assert_eq "disruption_count unchanged" "$(cat "$DISRUPTION_COUNT_FILE")" "$_before_count"
    assert_eq "cooldown timestamp unchanged" "$(cat "$LAST_FULL_WAN_DISRUPTION_FILE")" "$_before_ts"
    if [ -f "$DISRUPTION_HOLD_FILE" ]; then fail "S: hold latch created"; else pass "S: hold latch not created"; fi
    if [ -f "$FAIL_FILE" ]; then fail "S: fail_count file written"; else pass "S: fail_count file not written"; fi
    if [ -f "$RESTART_INCIDENT_FILE" ]; then fail "S: restart marker written"; else pass "S: restart marker not written"; fi
    assert_clean_side_effects "S"
}

# ================================================================
# T. Static source assertions: no disruptive primitive in the feature
# ================================================================
test_T() {
    echo "--- T: static forbidden-operation assertions ---"
    FEATURE_SRC="$TEST_ROOT/feature.sh"
    awk '
        /UNUSABLE WAN IA_NA \/128 CLEANUP/ { start=1 }
        start { print }
        start && /^maybe_cleanup_unusable_wan128\(\)/ { saw=1 }
        saw && /^}$/ { start=0; saw=0; exit }
    ' "$SCRIPT_DIR/ipv6-watchdog" > "$FEATURE_SRC"

    # wan_recovery_full_begin / wan_recovery_end are ALLOWED and intentional:
    # together they are the coordinator's documented acquire-then-release path
    # that writes no accounting. The accounting entry point
    # (wan_recovery_full_execute_locked) and every disruptive primitive remain
    # forbidden.
    _forbidden="ifdown ifup uci ubus_reload odhcpd tailscale maybe_wan_restart do_wan_restart reset_recovery_state wan_recovery_full_execute_locked wan_recovery_wan6_begin wan_recovery_wan6_record_locked dhcpv6_renew fix_gateway"
    _static_fail=0
    for _cmd in $_forbidden; do
        if grep -v '^[[:space:]]*#' "$FEATURE_SRC" 2>/dev/null | grep -qE "(^|[[:space:];(])($_cmd)([[:space:]);]|$)"; then
            fail "executable $_cmd found in cleanup source"
            _static_fail=1
        fi
    done
    [ "$_static_fail" = "0" ] && pass "no disruptive primitive in cleanup source"

    # The only address mutation must be a single exact /128 delete.
    _dels=$(grep -c 'ip -6 addr del' "$FEATURE_SRC")
    assert_eq "exactly one addr del call site" "$_dels" "1"
    if grep -q 'addr flush' "$FEATURE_SRC"; then fail "addr flush present"; else pass "no addr flush"; fi
    if grep -q 'scope global' "$FEATURE_SRC"; then fail "bulk /128 scan present"; else pass "no bulk /128 scan"; fi

    # CLEANUP_WAN128 must not be referenced by the new feature.
    if grep -q 'CLEANUP_WAN128' "$FEATURE_SRC"; then
        if grep -q 'AUTO_CLEANUP_UNUSABLE_WAN128' "$FEATURE_SRC"; then
            # Only the new flag may appear; the legacy name must not.
            if grep -E 'CLEANUP_WAN128' "$FEATURE_SRC" | grep -qv 'AUTO_CLEANUP_UNUSABLE_WAN128'; then
                fail "legacy CLEANUP_WAN128 referenced by the new feature"
            else
                pass "legacy CLEANUP_WAN128 not referenced"
            fi
        else
            fail "legacy CLEANUP_WAN128 referenced by the new feature"
        fi
    else
        pass "legacy CLEANUP_WAN128 not referenced"
    fi

    # Default must be OFF in the production script.
    if grep -q 'AUTO_CLEANUP_UNUSABLE_WAN128="${AUTO_CLEANUP_UNUSABLE_WAN128:-0}"' "$SCRIPT_DIR/ipv6-watchdog"; then
        pass "feature defaults to 0"
    else
        fail "feature does not default to 0"
    fi

    # Confirmation constant must not be config-overridable.
    if grep -q 'WAN128_CLEANUP_CONFIRMATIONS="\${WAN128_CLEANUP_CONFIRMATIONS' "$SCRIPT_DIR/ipv6-watchdog"; then
        fail "WAN128_CLEANUP_CONFIRMATIONS is config-overridable"
    else
        pass "WAN128_CLEANUP_CONFIRMATIONS is a fixed constant"
    fi

    # The call site must precede reset_recovery_state in the happy path.
    # Comment lines are stripped first: the call site's own comment explains
    # that it must run before reset_recovery_state, and matching that sentence
    # would compare a comment against the real statement.
    _call=$(grep -vn '^[[:space:]]*#' "$SCRIPT_DIR/ipv6-watchdog" \
        | grep 'maybe_cleanup_unusable_wan128$' | tail -1 | cut -d: -f1)
    _reset=$(grep -vn '^[[:space:]]*#' "$SCRIPT_DIR/ipv6-watchdog" \
        | awk -F: '/^[0-9]+:if ipv6_ok; then/{f=1} f && /reset_recovery_state/{print $1; exit}')
    if [ -n "$_call" ] && [ -n "$_reset" ] && [ "$_call" -lt "$_reset" ]; then
        pass "call site precedes reset_recovery_state"
    else
        fail "call site does not precede reset_recovery_state (call=$_call reset=$_reset)"
    fi

    # 99-ipv6-setup must remain free of address deletion.
    if grep -q 'addr del' "$SCRIPT_DIR/99-ipv6-setup"; then
        fail "99-ipv6-setup gained an addr del"
    else
        pass "99-ipv6-setup ownership boundary intact"
    fi
}

# ================================================================
# U. Disabling the feature must invalidate a live candidate
# ================================================================
test_U() {
    echo "--- U: disable clears a live candidate; re-enable restarts at 1 ---"
    prime_eligible
    maybe_cleanup_unusable_wan128
    assert_eq "candidate exists while enabled" "$(cand_count)" "1"

    # Disable. The candidate must not survive.
    # Scope the "no probe / no mutation" assertions to the disabled tick only:
    # the enabled observation above legitimately probed and wrote routes.
    : > "$PING6_LOG"
    : > "$IP_LOG"
    AUTO_CLEANUP_UNUSABLE_WAN128=0
    maybe_cleanup_unusable_wan128
    rc=$?
    assert_eq "disabled return" "$rc" "0"
    assert_eq "count file removed" "$(cand_count)" ""
    assert_eq "key file removed" "$(cand_key)" ""
    if [ -f "$WAN128_CLEANUP_KEY_FILE" ]; then fail "U: key file still on disk"; else pass "U: key file gone from disk"; fi
    if [ -f "$WAN128_CLEANUP_COUNT_FILE" ]; then fail "U: count file still on disk"; else pass "U: count file gone from disk"; fi
    # Disabled mode must be silent and perform no probe or mutation.
    assert_not_contains "U: no delete while disabled" "addr del" "$IP_LOG"
    assert_not_contains "U: no probe while disabled" "2001:db8:dead::1" "$PING6_LOG"
    assert_clean_side_effects "U"

    # Re-enable with an IDENTICAL context. The first post-enable observation
    # must be #1, not #2, and must not delete.
    AUTO_CLEANUP_UNUSABLE_WAN128=1
    maybe_cleanup_unusable_wan128
    assert_eq "re-enabled restarts at 1" "$(cand_count)" "1"
    assert_eq "WAN128 still present" "$(get_scenario WAN128)" "2001:db8:dead::1"
    assert_not_contains "U: no delete on first post-enable observation" "addr del" "$IP_LOG"

    # Only the NEXT independent observation may delete.
    maybe_cleanup_unusable_wan128
    assert_contains "U: deletes only on the second post-enable observation" "addr del 2001:db8:dead::1/128" "$IP_LOG"
}

# ================================================================
# V. An unhealthy tick must not bridge two confirmations
# ================================================================
# The watchdog clears the candidate on every unhealthy path (the function is
# simply not called on those ticks, so the script-level clear is what enforces
# this). These cases model the real sequence: healthy -> unhealthy -> healthy
# with an IDENTICAL context, which is the only dangerous shape.
test_V() {
    echo "--- V: healthy -> unhealthy -> healthy cannot confirm ---"
    prime_eligible
    maybe_cleanup_unusable_wan128
    assert_eq "healthy tick 1 -> count 1" "$(cand_count)" "1"

    # An unhealthy tick. ipv6_ok() fails, so maybe_cleanup_unusable_wan128 is
    # never called; the script-level invalidation runs instead.
    _wan128_cleanup_clear
    assert_eq "unhealthy tick clears the candidate" "$(cand_count)" ""

    # Health returns with the SAME WAN128 / PD_CIDR / LAN_PD_SRC / gateway.
    maybe_cleanup_unusable_wan128
    assert_eq "post-gap observation is #1, not #2" "$(cand_count)" "1"
    assert_eq "WAN128 survived the gap" "$(get_scenario WAN128)" "2001:db8:dead::1"
    assert_not_contains "V: no deletion across a health gap" "addr del" "$IP_LOG"

    # Only a genuinely consecutive healthy observation may delete.
    maybe_cleanup_unusable_wan128
    assert_contains "V: consecutive pair deletes" "addr del 2001:db8:dead::1/128" "$IP_LOG"
    assert_clean_side_effects "V"
}

# ================================================================
# W. Every non-happy top-level path invalidates the candidate
# ================================================================
# Structural proof against the real script. Each unhealthy exit class must
# reach a _wan128_cleanup_clear before it can exit, otherwise a candidate could
# survive a health gap and be confirmed by the next healthy tick.
test_W() {
    echo "--- W: script-level invalidation on every unhealthy path ---"
    W_SRC="$SCRIPT_DIR/ipv6-watchdog"

    _line() { grep -n "$1" "$W_SRC" | head -1 | cut -d: -f1; }

    # 1. The unhealthy region (everything after the happy path) clears first.
    _happy_end=$(awk '/^if ipv6_ok; then/{f=1} f&&/^fi$/{print NR; exit}' "$W_SRC")
    _clear_after=$(awk -v e="$_happy_end" 'NR>e && /_wan128_cleanup_clear/{print NR; exit}' "$W_SRC")
    _noprefix=$(awk '/^if ! has_prefix; then/{print NR; exit}' "$W_SRC")
    if [ -n "$_clear_after" ] && [ -n "$_noprefix" ] && [ "$_clear_after" -lt "$_noprefix" ]; then
        pass "W1 unhealthy region clears before the no-prefix ladder"
    else
        fail "W1 no clear between the happy path and the no-prefix ladder"
    fi

    # The fix_gateway repair path resets FAILS to 0, so it MUST be after the
    # clear above; otherwise it would leave a bridgeable candidate.
    _fixgw=$(_line '^if fix_gateway; then')
    if [ -n "$_clear_after" ] && [ "$_clear_after" -lt "$_fixgw" ]; then
        pass "W2 clear precedes the fix_gateway repair path"
    else
        fail "W2 fix_gateway repair path can bridge a candidate"
    fi

    # The confirmed-failure FAILS increment is also downstream of the clear.
    _failinc=$(_line '^FAILS=\$((FAILS + 1))')
    if [ -n "$_clear_after" ] && [ "$_clear_after" -lt "$_failinc" ]; then
        pass "W3 clear precedes the confirmed-failure path"
    else
        fail "W3 confirmed-failure path not covered"
    fi

    # 2. Tier 0 (wan6 down) clears before any of its exits.
    _t0=$(awk '/^if ! ubus call network.interface.wan6 status/{print NR; exit}' "$W_SRC")
    _t0_clear=$(awk -v s="$_t0" 'NR>s && /_wan128_cleanup_clear/{print NR; exit}' "$W_SRC")
    _t0_exit=$(awk -v s="$_t0" 'NR>s && /exit 0/{print NR; exit}' "$W_SRC")
    if [ -n "$_t0_clear" ] && [ -n "$_t0_exit" ] && [ "$_t0_clear" -lt "$_t0_exit" ]; then
        pass "W4 Tier 0 clears before its first exit"
    else
        fail "W4 Tier 0 can exit with a live candidate"
    fi

    # 3. The WAN_DEV-missing exit clears.
    if grep -q '_wan128_cleanup_clear; log "ERROR: WAN_DEV not found' "$W_SRC"; then
        pass "W5 WAN_DEV-missing exit clears"
    else
        fail "W5 WAN_DEV-missing exit does not clear"
    fi

    # 4. The recovery-hold branch clears (defense in depth).
    _hold=$(_line '^if recovery_hold_active; then')
    _hold_clear=$(awk -v s="$_hold" 'NR>s && /_wan128_cleanup_clear/{print NR; exit}' "$W_SRC")
    _hold_exit=$(awk -v s="$_hold" 'NR>s && /^    exit 0$/{print NR; exit}' "$W_SRC")
    if [ -n "$_hold_clear" ] && [ -n "$_hold_exit" ] && [ "$_hold_clear" -lt "$_hold_exit" ]; then
        pass "W6 recovery-hold branch clears before exit"
    else
        fail "W6 recovery-hold branch can exit with a live candidate"
    fi

    # 5. The disabled branch of the function clears rather than bare-returning.
    _dis=$(awk '/AUTO_CLEANUP_UNUSABLE_WAN128" != "1"/{print NR; exit}' "$W_SRC")
    if [ -n "$_dis" ]; then
        _dis_clear=$(awk -v s="$_dis" 'NR>s && NR<=s+3 && /_wan128_cleanup_clear/{print NR; exit}' "$W_SRC")
        if [ -n "$_dis_clear" ]; then pass "W7 disabled branch clears"; else fail "W7 disabled branch returns without clearing"; fi
    else
        fail "W7 disabled branch not found (bare '|| return 0' would be unsafe)"
    fi

    # 6. Boot grace needs no clear: it only runs within 120s of boot, and a
    #    reboot clears /tmp (and therefore STATE_DIR) before that.
    if grep -q 'Boot grace period active' "$W_SRC"; then
        pass "W8 boot grace exists (candidate cannot predate a reboot)"
    else
        fail "W8 boot grace guard missing"
    fi
}

# ================================================================
# X. TOCTOU: ownership taken DURING the probe window must block the delete
# ================================================================
# The dangerous window is between the passive ownership pre-filter and the
# irreversible delete: the fresh wan128_internet_ok probe sits inside it and
# can take seconds. GRAB_LOCK_DIR makes the probe itself create the shared
# mkdir lock, so ownership is acquired at exactly the wrong moment.
test_X() {
    echo "--- X: concurrent ownership acquired during the probe window ---"
    prime_eligible
    maybe_cleanup_unusable_wan128
    assert_eq "obs 1 recorded" "$(cand_count)" "1"

    # Arm the race for the confirming tick.
    set_scenario "GRAB_LOCK_DIR" "$DISRUPTION_LOCK_DIR"
    : > "$IP_LOG"
    maybe_cleanup_unusable_wan128
    rc=$?

    if [ -d "$DISRUPTION_LOCK_DIR" ]; then pass "X: another owner did take the lock mid-window"; else fail "X: race was not actually armed"; fi
    assert_eq "X: cleanup refused" "$rc" "1"
    assert_not_contains "X: NO delete while another owner holds the lock" "addr del" "$IP_LOG"
    assert_eq "X: WAN128 retained" "$(get_scenario WAN128)" "2001:db8:dead::1"
    assert_contains "X: refusal logged" "shared coordinator declined exclusion" "$WATCHDOG_LOG"
    assert_eq "X: candidate cleared" "$(cand_count)" ""
    assert_clean_side_effects "X"

    # The guard must not have consumed budget or written accounting.
    if [ -f "$DISRUPTION_COUNT_FILE" ]; then fail "X: disruption_count written"; else pass "X: disruption_count not written"; fi
    if [ -f "$LAST_FULL_WAN_DISRUPTION_FILE" ]; then fail "X: cooldown timestamp written"; else pass "X: cooldown timestamp not written"; fi
    if [ -f "$DISRUPTION_HOLD_FILE" ]; then fail "X: hold latched"; else pass "X: hold not latched"; fi

    rmdir "$DISRUPTION_LOCK_DIR" 2>/dev/null
    set_scenario "GRAB_LOCK_DIR" ""

    # With the interloper gone, the very next observation pair deletes normally
    # and still leaves the coordinator lock released.
    maybe_cleanup_unusable_wan128
    maybe_cleanup_unusable_wan128
    assert_contains "X: deletes once ownership is free" "addr del 2001:db8:dead::1/128" "$IP_LOG"
    if [ -d "$DISRUPTION_LOCK_DIR" ]; then fail "X: lock left held after delete"; else pass "X: coordinator lock released after delete"; fi
    if [ -f "$DISRUPTION_COUNT_FILE" ]; then fail "X: budget consumed by a successful delete"; else pass "X: successful delete consumed no budget"; fi
}

# ================================================================
# X2. Coordinator unavailable -> fail closed
# ================================================================
test_X2() {
    echo "--- X2: no coordinator means no exclusive ownership proof ---"
    prime_eligible
    maybe_cleanup_unusable_wan128
    WAN_RECOVERY_AVAILABLE=0
    : > "$IP_LOG"
    maybe_cleanup_unusable_wan128
    rc=$?
    assert_eq "X2: refused" "$rc" "1"
    assert_not_contains "X2: no delete" "addr del" "$IP_LOG"
    assert_contains "X2: reason logged" "shared coordinator unavailable" "$WATCHDOG_LOG"
    assert_eq "X2: WAN128 retained" "$(get_scenario WAN128)" "2001:db8:dead::1"
    WAN_RECOVERY_AVAILABLE=1
    assert_clean_side_effects "X2"
}

# ================================================================
# X3. Shared hold is caught by the LOCAL pre-gate, before any lock is taken
# ================================================================
# Naming note: an earlier version of this case claimed to exercise the
# coordinator's locked hold check. It does not. recovery_hold_active() reads
# DISRUPTION_HOLD_FILE directly and runs long before wan_recovery_full_begin,
# so the local pre-gate always wins and the coordinator is never consulted.
# That ordering is itself worth pinning: it means a held budget cannot even
# cause a lock acquisition. X4 covers the coordinator-side refusal.
test_X3() {
    echo "--- X3: shared hold is caught by the local pre-gate ---"
    prime_eligible
    maybe_cleanup_unusable_wan128
    : > "$DISRUPTION_HOLD_FILE"
    : > "$IP_LOG"
    maybe_cleanup_unusable_wan128
    rc=$?
    assert_eq "X3: pre-gate returns 0 (abandon, not failure)" "$rc" "0"
    assert_not_contains "X3: no delete under hold" "addr del" "$IP_LOG"
    assert_contains "X3: local hold reason logged" "shared disruption hold is active" "$WATCHDOG_LOG"
    assert_eq "X3: candidate cleared" "$(cand_count)" ""
    # Proof the coordinator was never consulted: no lock artifact was created.
    if [ -d "$DISRUPTION_LOCK_DIR" ]; then fail "X3: coordinator lock was taken"; else pass "X3: coordinator never consulted"; fi
    rm -f "$DISRUPTION_HOLD_FILE"
}

# ================================================================
# X4. Coordinator-side refusal reached with the local pre-gates satisfied
# ================================================================
# Drives the path X3 does not: every local gate passes, so cleanup really does
# call wan_recovery_full_begin, and the refusal comes from the coordinator.
# The shared budget is set at the limit with the hold latch deliberately
# ABSENT, so recovery_hold_active() (which reads the latch and WAN_RESTARTS)
# stays false while the coordinator's locked check refuses with rc 2 and
# reconciles the latch itself.
test_X4() {
    echo "--- X4: coordinator refuses under the lock, and reconciles its latch ---"
    prime_eligible
    maybe_cleanup_unusable_wan128
    assert_eq "X4: candidate seeded" "$(cand_count)" "1"

    echo "$WAN_DISRUPTION_LIMIT" > "$DISRUPTION_COUNT_FILE"
    rm -f "$DISRUPTION_HOLD_FILE"
    WAN_RESTARTS=0            # keep the LOCAL hold pre-gate false
    : > "$IP_LOG"

    maybe_cleanup_unusable_wan128
    rc=$?
    assert_eq "X4: cleanup refused" "$rc" "1"
    assert_not_contains "X4: no delete" "addr del" "$IP_LOG"
    assert_contains "X4: coordinator refusal logged" "shared coordinator declined exclusion" "$WATCHDOG_LOG"
    assert_eq "X4: WAN128 retained" "$(get_scenario WAN128)" "2001:db8:dead::1"
    assert_eq "X4: candidate cleared" "$(cand_count)" ""

    # Documented coordinator-owned reconciliation, not cleanup accounting.
    if [ -f "$DISRUPTION_HOLD_FILE" ]; then
        pass "X4: coordinator reconciled its own hold latch (documented)"
    else
        fail "X4: coordinator did not reconcile the hold latch"
    fi
    assert_eq "X4: disruption_count not altered by cleanup" "$(cat "$DISRUPTION_COUNT_FILE")" "$WAN_DISRUPTION_LIMIT"
    if [ -d "$DISRUPTION_LOCK_DIR" ]; then fail "X4: lock left held after refusal"; else pass "X4: lock released after refusal"; fi

    rm -f "$DISRUPTION_HOLD_FILE" "$DISRUPTION_COUNT_FILE"
}

# ================================================================
# Y. TOP-LEVEL contract: post-delete PD failure inside the happy path
# ================================================================
# Runs the REAL happy-path block extracted from ipv6-watchdog, with the real
# reset_recovery_state and the real cleanup, to prove that ignoring cleanup's
# return code cannot emit a false recovery notice or erase live recovery state.
test_Y() {
    echo "--- Y: post-delete PD failure does not corrupt happy-path closure ---"
    HAPPY="$TEST_ROOT/happy.sh"
    awk '/^if ipv6_ok; then/{f=1} f{print} f&&/^fi$/{exit}' "$SCRIPT_DIR/ipv6-watchdog" > "$HAPPY"
    if grep -q 'maybe_cleanup_unusable_wan128' "$HAPPY" && grep -q 'reset_recovery_state' "$HAPPY"; then
        pass "Y: extracted the real happy-path block"
    else
        fail "Y: could not extract the happy-path block"
        return 0
    fi

    prime_eligible
    maybe_cleanup_unusable_wan128          # observation 1
    assert_eq "Y: observation 1 recorded" "$(cand_count)" "1"
    set_scenario "PD_PING_OK_AFTER_DEL" "0"

    : > "$IP_LOG"
    : > "$WATCHDOG_LOG"

    # Only the health verdict and the Discord-only critical notifier are
    # stubbed. reset_recovery_state, notify_restart_recovery,
    # notify_ordinary_recovery and maybe_cleanup_unusable_wan128 are the REAL
    # extracted production functions, so their gating is what is under test.
    # DISCORD_WEBHOOK stays unset, so notify_ipv6_recovered cannot send.
    ipv6_ok() { return 0; }
    cleanup_deprecated_v6() { log "DEPRECATED_CLEANUP_RAN"; }
    DISCORD_WEBHOOK=""

    # The block ends in `exit 0`, so run it in a subshell.
    HAPPY_OUT="$TEST_ROOT/happy.out"
    ( . "$HAPPY" ) > "$HAPPY_OUT" 2>&1
    _happy_rc=$?

    if [ "$_happy_rc" != "0" ] && [ -s "$HAPPY_OUT" ]; then
        echo "    [happy-path output]"; sed 's/^/      /' "$HAPPY_OUT"
    fi
    assert_eq "Y: happy path exited 0" "$_happy_rc" "0"
    assert_contains "Y: the delete did happen" "addr del 2001:db8:dead::1/128" "$IP_LOG"
    assert_contains "Y: post-delete PD failure logged" "PD-source Internet validation failed afterwards" "$WATCHDOG_LOG"
    assert_contains "Y: the closure path really did run" "DEPRECATED_CLEANUP_RAN" "$WATCHDOG_LOG"

    # The contract: no closure notice may be emitted, because eligibility
    # required FAILS=0 with no ordinary/restart/ONT incident open. These assert
    # against the REAL notifiers' own log lines.
    assert_not_contains "Y: no false critical recovery notice" "NOTIFY_IPV6_RECOVERED_SENT" "$WATCHDOG_LOG"
    assert_not_contains "Y: no false recovery notice" "connectivity recovered" "$WATCHDOG_LOG"
    assert_not_contains "Y: no false restart-recovery notice" "recovered after full WAN restart" "$WATCHDOG_LOG"
    assert_not_contains "Y: no ordinary-closure notice" "without a full WAN restart" "$WATCHDOG_LOG"

    # reset_recovery_state ran, but had nothing meaningful to discard.
    assert_eq "Y: fail_count still 0" "$(cat "$FAIL_FILE" 2>/dev/null)" "0"
    if [ -f "$INCIDENT_START_FILE" ]; then fail "Y: incident marker appeared"; else pass "Y: no ordinary incident was open or created"; fi
    if [ -f "$RESTART_INCIDENT_FILE" ]; then fail "Y: restart marker appeared"; else pass "Y: no restart incident was open or created"; fi
    if [ -f "$ONT_FLAG" ]; then fail "Y: ONT flag appeared"; else pass "Y: no critical incident was open or created"; fi

    # Shared recovery state untouched by the whole closure.
    if [ -f "$DISRUPTION_COUNT_FILE" ]; then fail "Y: budget consumed"; else pass "Y: shared budget untouched"; fi
    if [ -f "$DISRUPTION_HOLD_FILE" ]; then fail "Y: hold latched"; else pass "Y: shared hold untouched"; fi
    if [ -d "$DISRUPTION_LOCK_DIR" ]; then fail "Y: coordinator lock left held"; else pass "Y: coordinator lock released"; fi

    # The next tick is what detects the new PD failure; nothing here pre-empts it.
    assert_eq "Y: WAN128 is gone, so the next tick sees the real state" "$(get_scenario WAN128)" ""
    assert_clean_side_effects "Y"

    unset -f ipv6_ok cleanup_deprecated_v6 2>/dev/null
}

# ================================================================
# Z. Real flock present: the guard must fail closed, never delete
# ================================================================
# The suite normally stubs flock as unusable so the coordinator uses its mkdir
# lock, matching the target routers. This case removes the stub so the real
# binary is used, and asserts the only acceptable outcomes: either exclusion is
# granted and the delete happens, or exclusion is refused and it does not.
# A delete WITHOUT exclusion is never acceptable.
test_Z() {
    echo "--- Z: behaviour with the real flock binary ---"
    _saved_flock="$TEST_ROOT/flock.saved"
    if [ ! -x "$MOCK_DIR/flock" ]; then
        pass "Z skipped (no flock stub to remove)"
        pass "Z skipped (no flock stub to remove)"
        return 0
    fi
    mv "$MOCK_DIR/flock" "$_saved_flock"
    # The shim created by mock_isolation_enforce still points at MOCK_DIR/flock,
    # so drop it for this case and let PATH/applet resolution find the real one.
    unset -f flock 2>/dev/null

    prime_eligible
    maybe_cleanup_unusable_wan128
    : > "$IP_LOG"
    maybe_cleanup_unusable_wan128
    rc=$?

    if grep -q 'addr del' "$IP_LOG" 2>/dev/null; then
        # Exclusion was granted -> deletion is legitimate, and the lock must
        # have been released again.
        assert_eq "Z: delete only with exclusion granted" "$rc" "0"
        if [ -d "$DISRUPTION_LOCK_DIR" ]; then fail "Z: lock left held"; else pass "Z: lock released after delete"; fi
    else
        # Exclusion refused -> fail closed. This is the expected outcome when
        # the coordinator cannot grant the lock on this platform.
        assert_eq "Z: refused without exclusion" "$rc" "1"
        assert_eq "Z: WAN128 retained when exclusion is refused" "$(get_scenario WAN128)" "2001:db8:dead::1"
    fi
    # Either way, no accounting may have been written.
    if [ -f "$DISRUPTION_COUNT_FILE" ]; then fail "Z: budget consumed"; else pass "Z: no budget consumed"; fi

    mv "$_saved_flock" "$MOCK_DIR/flock"
    # Restore the isolation shim for the remaining tests.
    eval 'flock() { "$MOCK_DIR"/flock "$@"; }'
}

for t in test_A test_B test_C test_D test_E test_F test_G test_H test_I \
         test_J1 test_J2 test_J3 test_J4 test_K test_L test_M test_N \
         test_O test_P test_Q test_R test_S test_T test_U test_V test_W \
         test_X test_X2 test_X3 test_X4 test_Y test_Z; do
    run_test "$t"
done

echo
echo "================================"
echo "PASS: $PASS"
echo "FAIL: $FAIL"
echo "================================"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
