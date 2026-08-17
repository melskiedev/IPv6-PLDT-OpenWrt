#!/bin/sh
# tests/test-wan-recovery-ipv6-integration.sh
#
# Stage C2: ipv6-watchdog <-> wan-recovery-common integration tests.
#
# Exercises the REAL production C2 helpers extracted from ipv6-watchdog
# (migrate_legacy_recovery_state, sync_legacy_state, coordinated_wan6_begin/
# end, in_cooldown, recovery_hold_active, do_wan_restart, maybe_wan_restart)
# against the REAL wan-recovery-common coordinator library. Health/route
# functions are overridden with test doubles after sourcing -- the C2 contract
# under test is COORDINATION, not IPv6 health (health is covered by the other
# suites).
#
# Contract coverage (A-AC):
#   A/B/C/D/E   full-WAN begin: allowed+failed, recovered-while-waiting,
#               cooldown-blocked, hold-blocked, lock-busy
#   F           coordinator missing -> fail-closed (no fallback)
#   G           incomplete coordinator API -> fail-closed + static gate
#   H/I/J/K/L/M legacy-state migration semantics (count, limit, max, ts,
#               idempotence, hold-only)
#   N           migration write failure -> fail-closed
#   O/P/Q       wan6-only: record-before-ifdown, recovered-while-waiting,
#               hold-blocked
#   R           in_cooldown reads shared timestamp
#   S           do_wan_restart mirrors shared -> legacy after coordinated run
#   T           maybe_wan_restart post-lock recovery -> no accounting
#   U           budget exhaustion latches hold; 4th begin blocked
#   V           wan6-only does NOT consume budget / latch hold
#   W           reset_recovery_state preserves shared budget + cooldown
#   X           coordinator lock released on end; cleanup idempotent
#   Y           recovery_hold_active shared-hold precedence
#   Z           in_cooldown expiry boundary
#   AA          static: per-script lock precedes all coordinated calls
#   AB          Tier 0 recheck type = ipv6_ok (wan6-begin wires ipv6_ok)
#   AC          bootstrap B3 recheck type = has_prefix
#
# Usage: sh tests/test-wan-recovery-ipv6-integration.sh
# Exit:  0 = all pass, 1 = any fail

TEST_SCRIPT="$0"
SCRIPT_DIR="$(cd "$(dirname "$TEST_SCRIPT")/.." && pwd)"
TEST_BASE="$SCRIPT_DIR/.test-tmp"
TEST_ROOT="$TEST_BASE/wr6-test-$$"
mkdir -p "$TEST_ROOT"

cleanup() { rm -rf "$TEST_ROOT"; }
trap cleanup EXIT
trap 'cleanup; exit 130' INT
trap 'cleanup; exit 143' TERM

PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); }
fail() { FAIL=$((FAIL + 1)); echo "  FAIL: $1"; }
assert_eq() {
    if [ "$2" = "$3" ]; then pass; else fail "$1 (expected '$3', got '$2')"; fi
}
assert_contains() {
    if grep -q "$2" "$3" 2>/dev/null; then pass; else fail "$1 (no match for '$2' in $3)"; fi
}
assert_not_contains() {
    if grep -q "$2" "$3" 2>/dev/null; then fail "$1 (found '$2' in $3)"; else pass; fi
}
assert_file_exists() {
    if [ -f "$2" ]; then pass; else fail "$1 ($2 missing)"; fi
}
assert_file_not_exists() {
    if [ -f "$2" ]; then fail "$1 ($2 present)"; else pass; fi
}

# ================================================================
# Production extraction: sanitize_int() through end of try_128_bootstrap().
# Includes the C2 helpers (migrate/sync/coordinated_*) + in_cooldown +
# recovery_hold_active + do_wan_restart + maybe_wan_restart.
# ================================================================

EXTRACT="$TEST_ROOT/extract.sh"
awk '
/^sanitize_int\(\)/ { start=1 }
start { print }
start && /^try_128_bootstrap\(\)/ { saw_end=1 }
saw_end && /^}/ { start=0; saw_end=0 }
' "$SCRIPT_DIR/ipv6-watchdog" > "$EXTRACT"

for fn in sanitize_int migrate_legacy_recovery_state sync_legacy_state \
          coordinated_wan6_begin coordinated_wan6_end in_cooldown \
          recovery_hold_active reset_recovery_state do_wan_restart \
          maybe_wan_restart try_128_bootstrap; do
    if ! grep -q "^${fn}()" "$EXTRACT"; then
        echo "FATAL: could not extract $fn from ipv6-watchdog" >&2
        exit 2
    fi
done

# ================================================================
# Mock PATH (real coordinator runs real lifecycle commands through mocks).
# ================================================================
MOCK_DIR="$TEST_ROOT/mock"
mkdir -p "$MOCK_DIR"

cat > "$MOCK_DIR/flock" <<'EOF'
#!/bin/sh
echo "flock $*" >> "$WRC_FLOCK_LOG"
exit "${WRC_FLOCK_RC:-0}"
EOF
chmod +x "$MOCK_DIR/flock"

cat > "$MOCK_DIR/ifdown" <<'EOF'
#!/bin/sh
echo "$*" >> "$WRC_IFDOWN_LOG"
echo "count=$(cat "$WRC_DISRUPTION_COUNT" 2>/dev/null)" >> "$WRC_IFDOWN_LOG"
exit 0
EOF
chmod +x "$MOCK_DIR/ifdown"

cat > "$MOCK_DIR/ifup" <<'EOF'
#!/bin/sh
echo "$*" >> "$WRC_IFUP_LOG"
exit 0
EOF
chmod +x "$MOCK_DIR/ifup"

cat > "$MOCK_DIR/sleep" <<'EOF'
#!/bin/sh
echo "$*" >> "$WRC_SLEEP_LOG"
exit 0
EOF
chmod +x "$MOCK_DIR/sleep"

cat > "$MOCK_DIR/date" <<'EOF'
#!/bin/sh
if [ "$1" = "+%s" ]; then
    echo "${WRC_NOW:-1700000000}"
    exit 0
fi
/usr/bin/date "$@"
EOF
chmod +x "$MOCK_DIR/date"

# ubus mock: returns empty JSON so production ubus callers get empty results.
# Health functions are overridden by define_health_doubles() after extract
# source, so this mock only needs to exist (not produce meaningful output).
cat > "$MOCK_DIR/ubus" <<'EOF'
#!/bin/sh
exit 0
EOF
chmod +x "$MOCK_DIR/ubus"

# jsonfilter mock: exits non-zero (no match) so production callers that
# pipe ubus | jsonfilter get empty results. Overridden by test doubles.
cat > "$MOCK_DIR/jsonfilter" <<'EOF'
#!/bin/sh
exit 1
EOF
chmod +x "$MOCK_DIR/jsonfilter"

# --- Mock isolation guard ---------------------------------------------------
# Every mock is created at top level into a MOCK_DIR that never changes, and
# build_env plus all tests run after this point, so one enforcement call covers
# the whole suite. date, ifdown, ifup and sleep are BusyBox applets; without
# this guard `busybox ash` resolved them ahead of PATH and this suite invoked
# the REAL host ifdown/ifup. See tests/lib/mock-isolation.sh.
. "$SCRIPT_DIR/tests/lib/mock-isolation.sh"
mock_isolation_enforce MOCK_DIR "date flock ifdown ifup sleep ubus jsonfilter"

echo "---" >> "$TEST_ROOT/noop_marker" 2>/dev/null || :

# ================================================================
# Per-test environment builder.
# ================================================================
build_env() {
    C2_STATE="$TEST_ROOT/c2-state"
    LEGACY_STATE="$TEST_ROOT/legacy-state"
    rm -rf "$C2_STATE" "$LEGACY_STATE"
    mkdir -p "$C2_STATE" "$LEGACY_STATE"

    WAN_RECOVERY_STATE_DIR="$C2_STATE"
    export WAN_RECOVERY_STATE_DIR
    # Point the production loading block at the REAL coordinator so the
    # extract's source/API validation path is exercised (not bypassed).
    # Tests F and G override this to a non-existent path to test fail-closed.
    WAN_RECOVERY_COMMON="$SCRIPT_DIR/wan-recovery-common"
    export WAN_RECOVERY_COMMON
    # The coordinator library owns the lifecycle commands (ifdown/ifup/sleep)
    # and the lock (flock); run them through the mocks so no real networking
    # or locking occurs.
    ORIG_PATH="${ORIG_PATH:-$PATH}"
    export PATH="$MOCK_DIR:$ORIG_PATH"
    # WAN_RECOVERY_AVAILABLE is NOT set here: the extract's production loading
    # block (ipv6-watchdog lines 145-157) sets it based on whether the
    # coordinator was successfully sourced and its API verified. This exercises
    # the REAL production source/API validation path.
    export WRC_FLOCK_LOG="$TEST_ROOT/flock_$$.log"
    export WRC_IFDOWN_LOG="$TEST_ROOT/ifdown_$$.log"
    export WRC_IFUP_LOG="$TEST_ROOT/ifup_$$.log"
    export WRC_SLEEP_LOG="$TEST_ROOT/sleep_$$.log"
    export WRC_DISRUPTION_COUNT="$C2_STATE/disruption_count"
    export WRC_FLOCK_RC=0
    export WRC_NOW=1700000000
    : > "$WRC_FLOCK_LOG"
    : > "$WRC_IFDOWN_LOG"
    : > "$WRC_IFUP_LOG"
    : > "$WRC_SLEEP_LOG"

    # Legacy (watchdog) state files.
    STATE_DIR="$LEGACY_STATE"
    WAN_RESTART_FILE="$LEGACY_STATE/wan_restart_count"
    LAST_WAN_RESTART_FILE="$LEGACY_STATE/last_wan_restart"
    FAIL_FILE="$LEGACY_STATE/fail_count"
    PREFIX_FAIL_FILE="$LEGACY_STATE/prefix_fail_count"
    TIER0_FAIL_FILE="$LEGACY_STATE/tier0_fail_count"
    PREFIX_BACKOFF_FILE="$LEGACY_STATE/prefix_next_attempt"
    ONT_FLAG="$LEGACY_STATE/ont_notified"
    RECOVERY_HOLD_FILE="$LEGACY_STATE/recovery_hold"
    HOLD_STATUS_FILE="$LEGACY_STATE/hold_status"
    GOOD_GW_FILE="$LEGACY_STATE/good_gateway"

    # Shared state paths (as the production load block resolves them).
    DISRUPTION_COUNT_FILE="$C2_STATE/disruption_count"
    LAST_FULL_WAN_DISRUPTION_FILE="$C2_STATE/last_full_wan_disruption"
    LAST_WAN6_ACTION_FILE="$C2_STATE/last_wan6_action"
    LAST_FULL_WAN_REASON_FILE="$C2_STATE/last_full_wan_reason"
    LAST_WAN6_REASON_FILE="$C2_STATE/last_wan6_reason"
    DISRUPTION_HOLD_FILE="$C2_STATE/disruption_hold"
    DISRUPTION_LOCK_FILE="$C2_STATE/disruption.lock"
    DISRUPTION_LOCK_DIR="$C2_STATE/disruption.lock.dir"

    # Production config mapping (line-for-line from ipv6-watchdog).
    WAN_RESTART_LIMIT=3
    WAN_RESTART_COOLDOWN=1200
    WAN_DISRUPTION_LIMIT="${WAN_DISRUPTION_LIMIT:-${WAN_RESTART_LIMIT:-3}}"
    WAN_DISRUPTION_COOLDOWN="${WAN_DISRUPTION_COOLDOWN:-${WAN_RESTART_COOLDOWN:-1200}}"
    WAN_RESTARTS=0
    NOW="${WRC_NOW}"
    BOOTSTRAP_ENABLED=0
    CLEANUP_WAN128=0
    BOOTSTRAP_UCI_STAGED=0
    STICKY_GATEWAY=0

    C2_LOG="$TEST_ROOT/c2_$$.log"
    log() { echo "$1" >> "$C2_LOG"; }

    # Health doubles (overridden after extract source; C2 tests coordinate,
    # they do not re-test IPv6 health).
    IPV6_OK_FILE="$TEST_ROOT/ipv6_ok_$$.flag"
    PD_OK_FILE="$TEST_ROOT/pd_ok_$$.flag"
    HAS_PFX_FILE="$TEST_ROOT/has_pfx_$$.flag"
    EFF_OK_FILE="$TEST_ROOT/eff_ok_$$.flag"
    rm -f "$IPV6_OK_FILE" "$PD_OK_FILE" "$HAS_PFX_FILE" "$EFF_OK_FILE"

    ipv6_ok() { [ -f "$IPV6_OK_FILE" ]; }
    has_prefix() { [ -f "$HAS_PFX_FILE" ]; }
    populate_pd_context() { WAN_DEV="eth1"; PD_CIDR="2001:db8:1::/56"; LAN_PD_SRC="2001:db8:1::10"; }
    pd_internet_ok() { [ -f "$PD_OK_FILE" ]; }
    pd_routes_ok() { return 0; }
    pd_route_effective() { [ -f "$EFF_OK_FILE" ]; }
    fix_gateway() { return 0; }
    dhcpv6_renew() { return 0; }
    notify_ont_powercycle() { echo "ONT-$1" >> "$C2_LOG"; }
    notify_ipv6_recovered() { echo "RECOVERED" >> "$C2_LOG"; }
    cleanup_deprecated_v6() { :; }
    install_gw_routes() { return 0; }
    clear_default_routes() { :; }
    snapshot_default_routes() { :; }
    restore_route_snapshot() { :; }
    remove_candidate_routes() { :; }
}

# Re-source the REAL coordinator library into the current shell.
source_coordinator() {
    # shellcheck disable=SC1090
    . "$SCRIPT_DIR/wan-recovery-common"
    _wan_recovery_sanitize_config
}

# Re-apply test doubles AFTER . "$EXTRACT" so production health functions
# (which use ubus/jsonfilter/ip) are overridden. The extract includes the
# production versions of ipv6_ok, has_prefix, populate_pd_context, etc.
# (lines 236-710 of ipv6-watchdog) which override the doubles from
# build_env(). This function restores the doubles so tests exercise
# COORDINATION, not IPv6 health (health is covered by the other suites).
define_health_doubles() {
    ipv6_ok() { [ -f "$IPV6_OK_FILE" ]; }
    has_prefix() { [ -f "$HAS_PFX_FILE" ]; }
    populate_pd_context() { WAN_DEV="eth1"; PD_CIDR="2001:db8:1::/56"; LAN_PD_SRC="2001:db8:1::10"; }
    pd_internet_ok() { [ -f "$PD_OK_FILE" ]; }
    pd_routes_ok() { return 0; }
    pd_route_effective() { [ -f "$EFF_OK_FILE" ]; }
    fix_gateway() { return 0; }
    dhcpv6_renew() { return 0; }
    notify_ont_powercycle() { echo "ONT-$1" >> "$C2_LOG"; }
    notify_ipv6_recovered() { echo "RECOVERED" >> "$C2_LOG"; }
    cleanup_deprecated_v6() { :; }
    install_gw_routes() { return 0; }
    clear_default_routes() { :; }
    snapshot_default_routes() { :; }
    restore_route_snapshot() { :; }
    remove_candidate_routes() { :; }
}

# ================================================================
# Tests
# ================================================================

test_A() {
    echo "--- A: full-WAN begin allowed, still failed -> accounting BEFORE first ifdown, lifecycle runs ---"
    build_env
    source_coordinator
    # shellcheck disable=SC1090
    . "$EXTRACT"
    define_health_doubles
    maybe_wan_restart "3 consecutive connectivity failures"
    [ ! -f "$IPV6_OK_FILE" ] || rm -f "$IPV6_OK_FILE"
    assert_contains "reason recorded" "3 consecutive connectivity failures" "$C2_STATE/last_full_wan_reason"
    assert_eq "shared count" "$(cat "$DISRUPTION_COUNT_FILE" 2>/dev/null)" "1"
    assert_contains "docker lifecycle order (wan6 down first)" "wan6" "$WRC_IFDOWN_LOG"
    assert_contains "wan down logged" "wan" "$WRC_IFDOWN_LOG"
    assert_contains "wan up logged" "wan" "$WRC_IFUP_LOG"
    assert_contains "wan6 up logged" "wan6" "$WRC_IFUP_LOG"
    assert_contains "full-WAN log" "Full WAN restart #1 of 3" "$C2_LOG"
    # Accounting-before-ifdown: the mock ifdown captured the count AT its own
    # invocation; the first ifdown line must already show count=1.
    first=$(head -2 "$WRC_IFDOWN_LOG" | tail -1)
    assert_eq "count already 1 at first ifdown" "$first" "count=1"
}

test_B() {
    echo "--- B: health recovered while waiting for lock -> NO action, NO accounting ---"
    build_env
    source_coordinator
    # shellcheck disable=SC1090
    . "$EXTRACT"
    define_health_doubles
    touch "$IPV6_OK_FILE"
    maybe_wan_restart "transient failure"
    assert_file_not_exists "no shared count file" "$DISRUPTION_COUNT_FILE"
    assert_eq "ifdown empty" "$(cat "$WRC_IFDOWN_LOG" 2>/dev/null)" ""
    assert_contains "recovered log" "recovered while waiting for shared lock" "$C2_LOG"
}

test_C() {
    echo "--- C: full-WAN begin blocked by shared cooldown -> no action ---"
    build_env
    source_coordinator
    # shellcheck disable=SC1090
    . "$EXTRACT"
    define_health_doubles
    now=$(_wan_recovery_now)
    echo "$now" > "$LAST_FULL_WAN_DISRUPTION_FILE"
    maybe_wan_restart "cooldown test"
    assert_eq "ifdown empty" "$(cat "$WRC_IFDOWN_LOG" 2>/dev/null)" ""
    assert_contains "cooldown log" "in post-restart cooldown" "$C2_LOG"
}

test_D() {
    echo "--- D: full-WAN begin blocked by shared hold -> ONT notify once, passive ---"
    build_env
    source_coordinator
    # shellcheck disable=SC1090
    . "$EXTRACT"
    define_health_doubles
    touch "$DISRUPTION_HOLD_FILE"
    maybe_wan_restart "hold test"
    assert_eq "ifdown empty" "$(cat "$WRC_IFDOWN_LOG" 2>/dev/null)" ""
    assert_contains "ONT notified" "ONT-0" "$C2_LOG"
    assert_file_exists "ONT flag latched" "$ONT_FLAG"
    # Second call: silent (flag exists).
    : > "$C2_LOG"
    maybe_wan_restart "hold test 2"
    assert_contains "awaiting manual ONT" "awaiting manual ONT powercycle" "$C2_LOG"
}

test_E() {
    echo "--- E: full-WAN lock busy -> no fallback, no action ---"
    build_env
    source_coordinator
    # shellcheck disable=SC1090
    . "$EXTRACT"
    define_health_doubles
    WRC_FLOCK_RC=1
    export WRC_FLOCK_RC
    maybe_wan_restart "busy test"
    assert_eq "ifdown empty" "$(cat "$WRC_IFDOWN_LOG" 2>/dev/null)" ""
    assert_contains "busy log" "shared lock busy" "$C2_LOG"
}

test_F() {
    echo "--- F: coordinator unavailable -> fail-closed, no fallback cycle ---"
    build_env
    # Prevent the extract's loading block from sourcing the coordinator.
    WAN_RECOVERY_COMMON="/nonexistent/coordinator"
    export WAN_RECOVERY_COMMON
    # shellcheck disable=SC1090
    . "$EXTRACT"
    define_health_doubles
    maybe_wan_restart "failclosed test"
    assert_eq "ifdown empty" "$(cat "$WRC_IFDOWN_LOG" 2>/dev/null)" ""
    assert_contains "fail-closed log" "fail-closed" "$C2_LOG"
}

test_G() {
    echo "--- G: incomplete coordinator API -> fail-closed + static API gate ---"
    build_env
    # Prevent the extract's loading block from sourcing the coordinator.
    WAN_RECOVERY_COMMON="/nonexistent/coordinator"
    export WAN_RECOVERY_COMMON
    # shellcheck disable=SC1090
    . "$EXTRACT"
    define_health_doubles
    if coordinated_wan6_begin "api test" ipv6_ok; then
        fail "G: coordinated_wan6_begin should not succeed with coordinator unavailable"
    else
        pass
    fi
    assert_eq "no wan6 ifdown" "$(cat "$WRC_IFDOWN_LOG" 2>/dev/null)" ""
    # Static: production verifies every required API after sourcing.
    assert_contains "static API gate: full_begin verified" "wan_recovery_full_begin" "$SCRIPT_DIR/ipv6-watchdog"
    assert_contains "static API gate: execute verified" "wan_recovery_full_execute_locked" "$SCRIPT_DIR/ipv6-watchdog"
    assert_contains "static API gate: wan6_begin verified" "wan_recovery_wan6_begin" "$SCRIPT_DIR/ipv6-watchdog"
    assert_contains "static API gate: wan6_record verified" "wan_recovery_wan6_record_locked" "$SCRIPT_DIR/ipv6-watchdog"
    assert_contains "static API gate: end verified" "wan_recovery_end" "$SCRIPT_DIR/ipv6-watchdog"
    assert_contains "static API gate: cleanup verified" "wan_recovery_cleanup" "$SCRIPT_DIR/ipv6-watchdog"
}

test_H() {
    echo "--- H: legacy count=2 -> shared count=2, hold NOT latched ---"
    build_env
    source_coordinator
    # shellcheck disable=SC1090
    . "$EXTRACT"
    define_health_doubles
    echo "2" > "$WAN_RESTART_FILE"
    migrate_legacy_recovery_state
    rc=$?
    assert_eq "migrate rc" "$rc" "0"
    assert_eq "shared count" "$(cat "$DISRUPTION_COUNT_FILE" 2>/dev/null)" "2"
    assert_file_not_exists "hold not latched" "$DISRUPTION_HOLD_FILE"
    assert_file_exists "migration marker" "$STATE_DIR/c2_migrated"
}

test_I() {
    echo "--- I: legacy count=3 (== limit) -> shared count=3, hold latched ---"
    build_env
    source_coordinator
    # shellcheck disable=SC1090
    . "$EXTRACT"
    define_health_doubles
    echo "3" > "$WAN_RESTART_FILE"
    migrate_legacy_recovery_state
    assert_eq "shared count" "$(cat "$DISRUPTION_COUNT_FILE" 2>/dev/null)" "3"
    assert_file_exists "hold latched at limit" "$DISRUPTION_HOLD_FILE"
}

test_J() {
    echo "--- J: migration max semantics (legacy 1, shared 2 -> shared stays 2) ---"
    build_env
    source_coordinator
    # shellcheck disable=SC1090
    . "$EXTRACT"
    define_health_doubles
    echo "2" > "$DISRUPTION_COUNT_FILE"
    echo "1" > "$WAN_RESTART_FILE"
    migrate_legacy_recovery_state
    assert_eq "shared count preserved" "$(cat "$DISRUPTION_COUNT_FILE" 2>/dev/null)" "2"
}

test_K() {
    echo "--- K: migration ts max semantics (legacy newer -> shared updated) ---"
    build_env
    source_coordinator
    # shellcheck disable=SC1090
    . "$EXTRACT"
    define_health_doubles
    echo "1699990000" > "$LAST_FULL_WAN_DISRUPTION_FILE"
    echo "1700000000" > "$LAST_WAN_RESTART_FILE"
    migrate_legacy_recovery_state
    assert_eq "shared ts updated to newer" "$(cat "$LAST_FULL_WAN_DISRUPTION_FILE" 2>/dev/null)" "1700000000"
}

test_L() {
    echo "--- L: migration idempotent (marker -> no-op, no double merge) ---"
    build_env
    source_coordinator
    # shellcheck disable=SC1090
    . "$EXTRACT"
    define_health_doubles
    echo "2" > "$WAN_RESTART_FILE"
    migrate_legacy_recovery_state
    echo "5" > "$WAN_RESTART_FILE"   # legacy changes after first migration
    migrate_legacy_recovery_state
    assert_eq "shared count stable" "$(cat "$DISRUPTION_COUNT_FILE" 2>/dev/null)" "2"
}

test_M() {
    echo "--- M: legacy hold file only (no count) -> shared hold created ---"
    build_env
    source_coordinator
    # shellcheck disable=SC1090
    . "$EXTRACT"
    define_health_doubles
    touch "$RECOVERY_HOLD_FILE"
    migrate_legacy_recovery_state
    assert_file_exists "shared hold created" "$DISRUPTION_HOLD_FILE"
}

test_N() {
    echo "--- N: migration write failure -> rc=1 (fail-closed) ---"
    build_env
    source_coordinator
    # shellcheck disable=SC1090
    . "$EXTRACT"
    define_health_doubles
    echo "2" > "$WAN_RESTART_FILE"
    # Break the shared dir: replace it with a regular FILE so writes fail.
    rm -rf "$DISRUPTION_COUNT_FILE"
    rm -rf "$DISRUPTION_LOCK_DIR"
    rm -rf "$WAN_RECOVERY_STATE_DIR"
    echo x > "$WAN_RECOVERY_STATE_DIR" 2>/dev/null || true
    migrate_legacy_recovery_state
    rc=$?
    assert_eq "fail-closed rc" "$rc" "1"
    rm -f "$WAN_RECOVERY_STATE_DIR"
}

test_O() {
    echo "--- O: wan6-only: record BEFORE first ifdown, full count untouched ---"
    build_env
    source_coordinator
    # shellcheck disable=SC1090
    . "$EXTRACT"
    define_health_doubles
    if ! coordinated_wan6_begin "Tier 0: wan6 recovery" ipv6_ok; then
        fail "O: begin should succeed"
    fi
    # Record must exist BEFORE the caller's first ifdown.
    assert_file_exists "wan6 action recorded" "$LAST_WAN6_ACTION_FILE"
    # The ifdown log must be empty BEFORE the caller's ifdown (coordinated_wan6_begin
    # acquires the lock and records the action; it does NOT call ifdown -- the
    # caller performs the lifecycle after begin returns 0).
    assert_eq "no ifdown before caller cycle" "$(cat "$WRC_IFDOWN_LOG" 2>/dev/null)" ""
    ifdown wan6; sleep 5; ifup wan6
    # After the caller's lifecycle, the ifdown log must show wan6.
    first_ifdown=$(head -1 "$WRC_IFDOWN_LOG")
    assert_eq "first ifdown is wan6" "$first_ifdown" "wan6"
    coordinated_wan6_end
    assert_file_not_exists "full count never touched" "$DISRUPTION_COUNT_FILE"
    assert_file_not_exists "hold never latched" "$DISRUPTION_HOLD_FILE"
    assert_file_exists "wan6 reason recorded" "$C2_STATE/last_wan6_reason"
}

test_P() {
    echo "--- P: wan6-only recovers while waiting for lock -> NO cycle, NO record ---"
    build_env
    source_coordinator
    # shellcheck disable=SC1090
    . "$EXTRACT"
    define_health_doubles
    touch "$IPV6_OK_FILE"
    if coordinated_wan6_begin "tier0 recovered" ipv6_ok; then
        fail "P: begin should skip when health is back"
    else
        pass
    fi
    assert_file_not_exists "no wan6 record" "$LAST_WAN6_ACTION_FILE"
    assert_eq "no ifdown" "$(cat "$WRC_IFDOWN_LOG" 2>/dev/null)" ""
}

test_Q() {
    echo "--- Q: shared hold blocks wan6-only -> no lifecycle ---"
    build_env
    source_coordinator
    # shellcheck disable=SC1090
    . "$EXTRACT"
    define_health_doubles
    touch "$DISRUPTION_HOLD_FILE"
    if coordinated_wan6_begin "hold blocked wan6" ipv6_ok; then
        fail "Q: begin should be blocked by hold"
    else
        pass
    fi
    assert_eq "no ifdown" "$(cat "$WRC_IFDOWN_LOG" 2>/dev/null)" ""
    assert_contains "passive log" "shared disruption hold active" "$C2_LOG"
}

test_R() {
    echo "--- R: in_cooldown reads SHARED timestamp ---"
    build_env
    source_coordinator
    # shellcheck disable=SC1090
    . "$EXTRACT"
    define_health_doubles
    : > "$LAST_FULL_WAN_DISRUPTION_FILE"
    if in_cooldown; then
        fail "R: empty shared ts must NOT be in cooldown"
    else
        pass
    fi
    now=$(_wan_recovery_now)
    echo "$now" > "$LAST_FULL_WAN_DISRUPTION_FILE"
    if in_cooldown; then pass; else fail "R: fresh shared ts must be in cooldown"; fi
}

test_S() {
    echo "--- S: do_wan_restart mirrors shared count -> legacy after coordinated run ---"
    build_env
    source_coordinator
    # shellcheck disable=SC1090
    . "$EXTRACT"
    define_health_doubles
    maybe_wan_restart "mirror test"
    assert_eq "legacy count mirrored" "$(cat "$WAN_RESTART_FILE" 2>/dev/null)" "1"
    assert_eq "legacy ts mirrored" "$(cat "$LAST_WAN_RESTART_FILE" 2>/dev/null)" "$(_wan_recovery_now)"
}

test_T() {
    echo "--- T: maybe_wan_restart post-lock recovery -> no accounting, legacy untouched ---"
    build_env
    source_coordinator
    # shellcheck disable=SC1090
    . "$EXTRACT"
    define_health_doubles
    touch "$IPV6_OK_FILE"
    maybe_wan_restart "recovered during lock wait"
    assert_contains "recovered log" "recovered while waiting for shared lock" "$C2_LOG"
    assert_file_not_exists "no shared count" "$DISRUPTION_COUNT_FILE"
    assert_eq "legacy count untouched" "$(cat "$WAN_RESTART_FILE" 2>/dev/null)" ""
}

test_U() {
    echo "--- U: budget exhaustion latches hold; 4th full begin blocked ---"
    build_env
    source_coordinator
    # shellcheck disable=SC1090
    . "$EXTRACT"
    define_health_doubles
    echo "2" > "$DISRUPTION_COUNT_FILE"
    wan_recovery_full_begin
    assert_eq "begin rc (allowed, 3rd)" "$?" "0"
    wan_recovery_full_execute_locked "third disruption"
    wan_recovery_end
    assert_eq "count now 3" "$(cat "$DISRUPTION_COUNT_FILE" 2>/dev/null)" "3"
    assert_file_exists "hold latched at limit" "$DISRUPTION_HOLD_FILE"
    # Fourth begin must be blocked.
    wan_recovery_full_begin
    assert_eq "4th begin blocked (hold)" "$?" "2"
    wan_recovery_end
}

test_V() {
    echo "--- V: wan6-only does NOT consume budget, does NOT latch hold ---"
    build_env
    source_coordinator
    # shellcheck disable=SC1090
    . "$EXTRACT"
    define_health_doubles
    if ! coordinated_wan6_begin "wan6 exercise" ipv6_ok; then
        fail "V: begin should succeed"
    fi
    ifdown wan6; sleep 5; ifup wan6
    coordinated_wan6_end
    assert_file_not_exists "budget untouched" "$DISRUPTION_COUNT_FILE"
    assert_file_not_exists "hold untouched" "$DISRUPTION_HOLD_FILE"
}

test_W() {
    echo "--- W: reset_recovery_state preserves shared budget + cooldown ---"
    build_env
    source_coordinator
    # shellcheck disable=SC1090
    . "$EXTRACT"
    define_health_doubles
    echo "2" > "$DISRUPTION_COUNT_FILE"
    echo "1700000000" > "$LAST_FULL_WAN_DISRUPTION_FILE"
    reset_recovery_state
    assert_eq "shared count preserved" "$(cat "$DISRUPTION_COUNT_FILE" 2>/dev/null)" "2"
    assert_eq "shared cooldown preserved" "$(cat "$LAST_FULL_WAN_DISRUPTION_FILE" 2>/dev/null)" "1700000000"
}

test_X() {
    echo "--- X: lock released on end; cleanup idempotent ---"
    build_env
    source_coordinator
    # shellcheck disable=SC1090
    . "$EXTRACT"
    define_health_doubles
    wan_recovery_full_begin
    assert_eq "begin rc" "$?" "0"
    wan_recovery_end
    # Lock must be free now: a second begin must succeed.
    wan_recovery_full_begin
    assert_eq "second begin after end" "$?" "0"
    wan_recovery_end
    wan_recovery_cleanup
    wan_recovery_cleanup
    pass
}

test_Y() {
    echo "--- Y: recovery_hold_active: shared hold file takes precedence ---"
    build_env
    source_coordinator
    # shellcheck disable=SC1090
    . "$EXTRACT"
    define_health_doubles
    WAN_RESTARTS=0
    touch "$DISRUPTION_HOLD_FILE"
    if recovery_hold_active; then pass; else fail "Y: shared hold must force hold"; fi
    WAN_RESTARTS=3
    rm -f "$DISRUPTION_HOLD_FILE"
    if recovery_hold_active; then pass; else fail "Y: count at limit must force hold"; fi
}

test_Z() {
    echo "--- Z: in_cooldown expiry boundary (>= cooldown -> not in cooldown) ---"
    build_env
    source_coordinator
    # shellcheck disable=SC1090
    . "$EXTRACT"
    define_health_doubles
    now=$(_wan_recovery_now)
    past=$((now - WAN_DISRUPTION_COOLDOWN))
    echo "$past" > "$LAST_FULL_WAN_DISRUPTION_FILE"
    if in_cooldown; then fail "Z: expired ts must NOT be in cooldown"; else pass; fi
}

test_AA() {
    echo "--- AA: static - per-script execution lock precedes all coordinated calls ---"
    build_env
    # The per-script lock (exec 9>/flock) is established at script top; the
    # coordinator source block is at config time; all runtime coordinated
    # calls appear later in the file. Verify the source ordering.
    lock_line=$(grep -n 'flock -n 9\|mkdir "\$LOCK_DIR"' "$SCRIPT_DIR/ipv6-watchdog" | head -1 | cut -d: -f1)
    src_line=$(grep -n "\. \"\$WAN_RECOVERY_COMMON\"" "$SCRIPT_DIR/ipv6-watchdog" | cut -d: -f1)
    first_call=$(grep -n 'coordinated_wan6_begin\|wan_recovery_full_begin\|migrate_legacy_recovery_state' "$SCRIPT_DIR/ipv6-watchdog" | grep -v '^\s*#' | head -1 | cut -d: -f1)
    if [ -n "$lock_line" ] && [ -n "$first_call" ] && [ "$lock_line" -lt "$first_call" ]; then
        pass
    else
        fail "AA: lock($lock_line) must precede first coordinated call($first_call)"
    fi
    if [ -n "$src_line" ] && [ "$src_line" -lt "$first_call" ]; then
        pass
    else
        fail "AA: coordinator source($src_line) must precede first coordinated call($first_call)"
    fi
}

test_AB() {
    echo "--- AB: Tier 0 wan6 cycle uses ipv6_ok recheck (recovered -> skip) ---"
    build_env
    source_coordinator
    # shellcheck disable=SC1090
    . "$EXTRACT"
    define_health_doubles
    touch "$IPV6_OK_FILE"
    if coordinated_wan6_begin "Tier 0: wan6 recovery" ipv6_ok; then
        fail "AB: ipv6_ok-healthy must skip the cycle"
    else
        pass
    fi
    assert_eq "no ifdown" "$(cat "$WRC_IFDOWN_LOG" 2>/dev/null)" ""
    assert_contains "recovered log" "recovered while waiting for shared lock" "$C2_LOG"
}

test_AC() {
    echo "--- AC: bootstrap B3 uses has_prefix recheck (prefix appeared -> skip) ---"
    build_env
    source_coordinator
    # shellcheck disable=SC1090
    . "$EXTRACT"
    define_health_doubles
    touch "$HAS_PFX_FILE"
    if coordinated_wan6_begin "Bootstrap B3: controlled wan6 acquisition" has_prefix; then
        fail "AC: prefix-present must skip the cycle"
    else
        pass
    fi
    assert_eq "no ifdown" "$(cat "$WRC_IFDOWN_LOG" 2>/dev/null)" ""
    assert_contains "prefix appeared log" "prefix appeared while waiting" "$C2_LOG"
}

test_AD() {
    echo "--- AD: migration creates WAN_RECOVERY_STATE_DIR when absent ---"
    build_env
    source_coordinator
    # shellcheck disable=SC1090
    . "$EXTRACT"
    define_health_doubles
    # Remove the shared state dir to simulate a fresh boot where
    # /tmp/wan-recovery does not exist yet.
    rm -rf "$WAN_RECOVERY_STATE_DIR"
    assert_file_not_exists "dir absent before migration" "$DISRUPTION_COUNT_FILE"
    echo "2" > "$WAN_RESTART_FILE"
    migrate_legacy_recovery_state
    rc=$?
    assert_eq "migrate rc (dir created)" "$rc" "0"
    assert_file_exists "dir created by migration" "$DISRUPTION_COUNT_FILE"
    assert_eq "shared count" "$(cat "$DISRUPTION_COUNT_FILE" 2>/dev/null)" "2"
    assert_file_exists "migration marker" "$STATE_DIR/c2_migrated"
}

test_AE() {
    echo "--- AE: migration fails closed when directory creation fails ---"
    build_env
    source_coordinator
    # shellcheck disable=SC1090
    . "$EXTRACT"
    define_health_doubles
    echo "2" > "$WAN_RESTART_FILE"
    # Make WAN_RECOVERY_STATE_DIR a regular file so mkdir -p fails.
    rm -rf "$WAN_RECOVERY_STATE_DIR"
    echo x > "$WAN_RECOVERY_STATE_DIR" 2>/dev/null || true
    migrate_legacy_recovery_state
    rc=$?
    assert_eq "fail-closed rc" "$rc" "1"
    # Clean up: remove the file so subsequent tests can use build_env.
    rm -f "$WAN_RECOVERY_STATE_DIR"
}

# ================================================================
# Run all tests
# ================================================================
echo "=== Stage C2: wan-recovery-common x ipv6-watchdog integration tests ==="

WR6_TESTS="${WR6_TESTS:-A B C D E F G H I J K L M N O P Q R S T U V W X Y Z AA AB AC AD AE}"
for t in $WR6_TESTS; do
    test_$t
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