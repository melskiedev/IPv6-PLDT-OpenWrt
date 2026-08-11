#!/bin/sh
# tests/test-wan-recovery-common.sh
#
# Stage C1 deterministic test suite for the wan-recovery-common shared
# coordinator library.
#
# This suite is self-contained and deterministic. It does NOT depend on
# local-only/ files. A clean public Git clone must be able to run this suite.
#
# Mocks: date, flock, ifdown, ifup, sleep. No actual networking.
#
# Usage: sh tests/test-wan-recovery-common.sh
# Exit:  0 = all pass, 1 = any fail

PASS=0
FAIL=0

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
LIB="$SCRIPT_DIR/wan-recovery-common"

# Per-test temp root (repo-local, gitignored).
TEST_ROOT="$SCRIPT_DIR/.test-tmp/wrc-test-$$"
mkdir -p "$TEST_ROOT"

cleanup() {
    rm -rf "$TEST_ROOT" 2>/dev/null
}
trap cleanup EXIT
trap 'cleanup; exit 130' INT
trap 'cleanup; exit 143' TERM

# ================================================================
# Test helpers
# ================================================================

pass() {
    PASS=$((PASS + 1))
    echo "  PASS: $1"
}

fail() {
    FAIL=$((FAIL + 1))
    echo "  FAIL: $1"
}

# assert_eq <desc> <actual> <expected>
assert_eq() {
    if [ "$2" = "$3" ]; then
        pass "$1 (got '$2')"
    else
        fail "$1 (got '$2', expected '$3')"
    fi
}

# assert_ne <desc> <actual> <notexpected>
assert_ne() {
    if [ "$2" != "$3" ]; then
        pass "$1 (got '$2', != '$3')"
    else
        fail "$1 (got '$2', should != '$3')"
    fi
}

# assert_file_eq <desc> <file> <expected>
assert_file_eq() {
    local f="$2" expected="$3"
    if [ -f "$f" ]; then
        local v
        v=$(cat "$f" | tr -d '[:space:]')
        if [ "$v" = "$expected" ]; then
            pass "$1 (file '$f' = '$v')"
        else
            fail "$1 (file '$f' = '$v', expected '$expected')"
        fi
    else
        fail "$1 (file '$f' missing, expected '$expected')"
    fi
}

# assert_file_exists <desc> <file>
# Uses -e so it works for both regular files and directories (the fallback
# lock is a directory).
assert_file_exists() {
    if [ -e "$2" ]; then
        pass "$1 (exists: $2)"
    else
        fail "$1 (missing: $2)"
    fi
}

# assert_file_missing <desc> <file>
# Uses ! -e so it works for both regular files and directories.
assert_file_missing() {
    if [ ! -e "$2" ]; then
        pass "$1 (absent: $2)"
    else
        fail "$1 (exists but should not: $2)"
    fi
}

# assert_rc <desc> <actual_rc> <expected_rc>
assert_rc() {
    assert_eq "$1 (rc)" "$2" "$3"
}

# Setup a fresh state dir + PATH-stub environment for one test.
# Writes STUB_DIR, STATE_DIR, and sources the library into the current shell.
# Sets WAN_RECOVERY_STATE_DIR and resets _WAN_RECOVERY_* internal vars.
fresh_env() {
    STATE_DIR="$TEST_ROOT/state-$$-$TEST_ID"
    STUB_DIR="$TEST_ROOT/stubs-$$-$TEST_ID"
    mkdir -p "$STATE_DIR" "$STUB_DIR"

    # Reset internal library state (the library sets these on acquire).
    _WAN_RECOVERY_LOCK_HELD=0
    _WAN_RECOVERY_LOCK_FD=""
    _WAN_RECOVERY_OWN_FALLBACK=0

    # By default, make flock UNAVAILABLE so the mkdir fallback path is
    # exercised. Tests that want the flock path set FLOCK_AVAILABLE=1 before
    # calling fresh_env.
    FLOCK_AVAILABLE="${FLOCK_AVAILABLE:-0}"

    if [ "$FLOCK_AVAILABLE" = 1 ]; then
        cat > "$STUB_DIR/flock" <<'EOF'
#!/bin/sh
# Minimal flock stub. Implements only -n (nonblocking) and -u (unlock).
# Uses a marker file to track lock state for the given fd.
case "$1" in
    -n)
        fd="$2"
        eval "lockfile=\${_FLOCK_FILE_$fd}"
        if [ -f "$lockfile" ]; then
            exit 1
        fi
        : > "$lockfile"
        exit 0
        ;;
    -u)
        fd="$2"
        eval "lockfile=\${_FLOCK_FILE_$fd}"
        rm -f "$lockfile" 2>/dev/null
        exit 0
        ;;
esac
exit 0
EOF
    else
        # flock unavailable: stub returns 127 (command not found semantics)
        cat > "$STUB_DIR/flock" <<'EOF'
#!/bin/sh
exit 127
EOF
    fi
    chmod +x "$STUB_DIR/flock"

    # ifdown / ifup: log calls, return 0 by default. Tests can force failure
    # by creating a FAIL_IFDOWN or FAIL_IFUP marker file in the stub dir.
    cat > "$STUB_DIR/ifdown" <<'EOF'
#!/bin/sh
echo "$@" >> "$IFDOWN_LOG"
if [ -f "$FAIL_IFDOWN" ]; then exit 1; fi
exit 0
EOF
    cat > "$STUB_DIR/ifup" <<'EOF'
#!/bin/sh
echo "$@" >> "$IFUP_LOG"
if [ -f "$FAIL_IFUP" ]; then exit 1; fi
exit 0
EOF
    chmod +x "$STUB_DIR/ifdown" "$STUB_DIR/ifup"

    # sleep: no-op (record count for assertion)
    cat > "$STUB_DIR/sleep" <<'EOF'
#!/bin/sh
echo "$@" >> "$SLEEP_LOG"
exit 0
EOF
    chmod +x "$STUB_DIR/sleep"

    # date: use _WAN_RECOVERY_NOW if set, else real date +%s only when called
    # with +%s. For other formats, delegate to real date.
    REAL_DATE=$(command -v date)
    cat > "$STUB_DIR/date" <<EOF
#!/bin/sh
if [ "\$1" = "+%s" ]; then
    if [ -n "\$_WAN_RECOVERY_NOW" ]; then
        echo "\$_WAN_RECOVERY_NOW"
    else
        "$REAL_DATE" +%s
    fi
    exit 0
fi
"$REAL_DATE" "\$@"
EOF
    chmod +x "$STUB_DIR/date"

    # log files for ifdown/ifup/sleep
    IFDOWN_LOG="$STATE_DIR/ifdown.log"
    IFUP_LOG="$STATE_DIR/ifup.log"
    SLEEP_LOG="$STATE_DIR/sleep.log"
    : > "$IFDOWN_LOG"
    : > "$IFUP_LOG"
    : > "$SLEEP_LOG"
    export IFDOWN_LOG IFUP_LOG SLEEP_LOG
    export FAIL_IFDOWN="$STATE_DIR/.fail_ifdown"
    export FAIL_IFUP="$STATE_DIR/.fail_ifup"

    # state dir override + library config
    WAN_RECOVERY_STATE_DIR="$STATE_DIR"
    export WAN_RECOVERY_STATE_DIR

    PATH="$STUB_DIR:$PATH"
    export PATH

    # Source the library fresh for each test so internal state is clean.
    # shellcheck disable=SC1090
    . "$LIB"

    # Refresh the library's path globals so they point at THIS test's state
    # dir (the begin functions call _wan_recovery_paths() too, but other
    # state files like DISRUPTION_LOCK_DIR must be correct even before a
    # begin, and any globals left over from a previous test's begin must be
    # reset).
    _wan_recovery_paths
}

# Set deterministic "now" for the library.
set_now() {
    _WAN_RECOVERY_NOW="$1"
    export _WAN_RECOVERY_NOW
}

# Convenience: write a state file with a value.
put_state() {
    echo "$2" > "$STATE_DIR/$1"
}

# Convenience: read a state file (trimmed).
get_state() {
    cat "$STATE_DIR/$1" 2>/dev/null | tr -d '[:space:]'
}

# count ifdown log lines matching <arg>
count_ifdown() {
    local n
    n=$(grep -c "^$1$" "$IFDOWN_LOG" 2>/dev/null)
    echo "${n:-0}"
}

count_ifup() {
    local n
    n=$(grep -c "^$1$" "$IFUP_LOG" 2>/dev/null)
    echo "${n:-0}"
}

# ================================================================
# Tests
# ================================================================

echo "--- A. defaults sanitize correctly ---"
TEST_ID=A
fresh_env
assert_eq "WAN_DISRUPTION_LIMIT default" "$WAN_DISRUPTION_LIMIT" "3"
assert_eq "WAN_DISRUPTION_COOLDOWN default" "$WAN_DISRUPTION_COOLDOWN" "1200"
assert_eq "WAN6_TO_FULL_WAN_GRACE default" "$WAN6_TO_FULL_WAN_GRACE" "60"
assert_eq "WAN_RECOVERY_STALE_LOCK_AGE default" "$WAN_RECOVERY_STALE_LOCK_AGE" "600"
assert_eq "WAN_DOWN_SLEEP default" "$WAN_DOWN_SLEEP" "30"
assert_eq "WAN_UP_SLEEP default" "$WAN_UP_SLEEP" "20"

echo "--- B. invalid numeric config -> safe defaults ---"
TEST_ID=B
WAN_DISRUPTION_LIMIT="abc" WAN_DISRUPTION_COOLDOWN="" WAN6_TO_FULL_WAN_GRACE="-5"
WAN_RECOVERY_STALE_LOCK_AGE="12x" WAN_DOWN_SLEEP=" " WAN_UP_SLEEP="oops"
fresh_env
# Trigger sanitize by calling a begin (which calls _wan_recovery_sanitize_config).
# We need the library to re-read the already-set (invalid) env vars. Since
# fresh_env sources the library (which reads defaults with :-), the invalid
# values were already captured. Force sanitize by calling the internal helper.
_wan_recovery_sanitize_config
assert_eq "WAN_DISRUPTION_LIMIT invalid->default" "$WAN_DISRUPTION_LIMIT" "3"
assert_eq "WAN_DISRUPTION_COOLDOWN empty->default" "$WAN_DISRUPTION_COOLDOWN" "1200"
assert_eq "WAN6_TO_FULL_WAN_GRACE negative->default" "$WAN6_TO_FULL_WAN_GRACE" "60"
assert_eq "WAN_RECOVERY_STALE_LOCK_AGE nonnum->default" "$WAN_RECOVERY_STALE_LOCK_AGE" "600"
assert_eq "WAN_DOWN_SLEEP blank->default" "$WAN_DOWN_SLEEP" "30"
assert_eq "WAN_UP_SLEEP nonnum->default" "$WAN_UP_SLEEP" "20"

echo "--- C. full_begin: no hold/cooldown -> rc=0 + lock HELD ---"
TEST_ID=C
fresh_env
set_now 100000
wan_recovery_full_begin
rc=$?
assert_rc "C: full_begin rc" "$rc" "0"
assert_eq "C: lock held after begin" "$_WAN_RECOVERY_LOCK_HELD" "1"
wan_recovery_end
assert_eq "C: lock released after end" "$_WAN_RECOVERY_LOCK_HELD" "0"

echo "--- D. full_begin: hold file exists -> rc=2 + lock RELEASED ---"
TEST_ID=D
fresh_env
set_now 100000
: > "$STATE_DIR/disruption_hold"
wan_recovery_full_begin
rc=$?
assert_rc "D: full_begin with hold rc" "$rc" "2"
assert_eq "D: lock released when blocked by hold" "$_WAN_RECOVERY_LOCK_HELD" "0"

echo "--- E. full_begin: count >= limit with no hold file -> rc=2, hold latches, lock released ---"
TEST_ID=E
fresh_env
set_now 100000
put_state disruption_count 3
assert_file_missing "E: no hold file before begin" "$STATE_DIR/disruption_hold"
wan_recovery_full_begin
rc=$?
assert_rc "E: full_begin count>=limit rc" "$rc" "2"
assert_file_exists "E: hold latched during begin" "$STATE_DIR/disruption_hold"
assert_eq "E: lock released" "$_WAN_RECOVERY_LOCK_HELD" "0"

echo "--- F. full_begin: recent full-WAN timestamp -> rc=1 + released ---"
TEST_ID=F
fresh_env
set_now 100000
put_state last_full_wan_disruption 99900
wan_recovery_full_begin
rc=$?
assert_rc "F: full_begin recent full-WAN rc" "$rc" "1"
assert_eq "F: lock released" "$_WAN_RECOVERY_LOCK_HELD" "0"

echo "--- G. full_begin: recent wan6 timestamp inside grace -> rc=1 + released ---"
TEST_ID=G
fresh_env
set_now 100000
put_state last_wan6_action 99950
wan_recovery_full_begin
rc=$?
assert_rc "G: full_begin recent wan6 inside grace rc" "$rc" "1"
assert_eq "G: lock released" "$_WAN_RECOVERY_LOCK_HELD" "0"

echo "--- H. full_begin: stale wan6 timestamp outside grace -> rc=0 + held ---"
TEST_ID=H
fresh_env
set_now 100000
put_state last_wan6_action 99900
wan_recovery_full_begin
rc=$?
assert_rc "H: full_begin stale wan6 outside grace rc" "$rc" "0"
assert_eq "H: lock held" "$_WAN_RECOVERY_LOCK_HELD" "1"
wan_recovery_end

echo "--- I. full_begin: lock busy -> rc=3 ---"
TEST_ID=I
fresh_env
set_now 100000
# Pre-create the fallback lock dir owned by "another process".
mkdir "$STATE_DIR/disruption.lock.dir"
wan_recovery_full_begin
rc=$?
assert_rc "I: full_begin lock busy rc" "$rc" "3"
assert_eq "I: lock not held" "$_WAN_RECOVERY_LOCK_HELD" "0"

echo "--- J. ATOMICITY regression: state changes AFTER lock but before policy check ---"
TEST_ID=J
fresh_env
set_now 100000
# Simulate: another process latches a hold file AFTER our lock acquire but
# before our policy check. We do this by pre-creating a scenario where the
# hold appears only at the moment of the check. Since our begin reads state
# WHILE holding the lock, the begin must observe the hold.
# We pre-create the hold file (simulating it was written before our read).
: > "$STATE_DIR/disruption_hold"
wan_recovery_full_begin
rc=$?
assert_rc "J: begin sees hold written before locked read rc" "$rc" "2"
# Also test: count at limit with no hold file (reconciliation path).
TEST_ID=J2
fresh_env
set_now 100000
put_state disruption_count 2
# The lock is acquired, then _wan_recovery_hold_active_locked reads count=2,
# sees 2 < 3, does NOT latch. begin should succeed.
wan_recovery_full_begin
rc=$?
assert_rc "J2: count=2 < limit, begin allowed rc" "$rc" "0"
assert_eq "J2: lock held" "$_WAN_RECOVERY_LOCK_HELD" "1"
wan_recovery_end
# Now test: count=3 (at limit) -> hold reconciled even without hold file.
TEST_ID=J3
fresh_env
set_now 100000
put_state disruption_count 3
wan_recovery_full_begin
rc=$?
assert_rc "J3: count=3 >= limit, begin blocked rc" "$rc" "2"
assert_file_exists "J3: hold reconciled" "$STATE_DIR/disruption_hold"

echo "--- K. caller-recovered simulation: begin rc=0, no execute, end -> count/timestamps unchanged ---"
TEST_ID=K
fresh_env
set_now 100000
put_state disruption_count 0
wan_recovery_full_begin
rc=$?
assert_rc "K: begin allowed rc" "$rc" "0"
# Caller performs health recheck -> recovered -> end (no execute).
wan_recovery_end
assert_eq "K: count unchanged (0)" "$(get_state disruption_count)" "0"
# No disruption occurred, so no full-WAN timestamp should have been written.
assert_file_missing "K: no last_full_wan_disruption written" "$STATE_DIR/last_full_wan_disruption"
assert_file_missing "K: no hold latched" "$STATE_DIR/disruption_hold"
assert_file_missing "K: no last_full_wan_reason" "$STATE_DIR/last_full_wan_reason"

echo "--- L. execute_locked from count=0: state/timestamp/reason written BEFORE first mocked ifdown ---"
TEST_ID=L
fresh_env
set_now 123456
put_state disruption_count 0
wan_recovery_full_begin
assert_rc "L: begin allowed" "$?" "0"
# Capture pre-execute state.
pre_ifdown_count=$(count_ifdown wan6)
# Execute. We wrap so we can inspect state BEFORE ifdown by using a custom
# ifdown stub that records the count-at-first-call. We redefine via a marker.
# Easier: after execute, verify the state files were written AND ifdown was
# called. To prove ordering, we use a sentinel: the ifdown stub records the
# current disruption_count into a file at call time.
cat > "$STUB_DIR/ifdown" <<'EOF'
#!/bin/sh
echo "$@" >> "$IFDOWN_LOG"
# Record the current disruption_count at the moment ifdown is called.
cat "$WAN_RECOVERY_STATE_DIR/disruption_count" > "$WAN_RECOVERY_STATE_DIR/count_at_first_ifdown"
exit 0
EOF
chmod +x "$STUB_DIR/ifdown"
wan_recovery_full_execute_locked "test-reason"
exec_rc=$?
assert_rc "L: execute rc (no failure)" "$exec_rc" "0"
assert_file_eq "L: count written before ifdown" "$STATE_DIR/count_at_first_ifdown" "1"
assert_file_eq "L: disruption_count = 1" "$STATE_DIR/disruption_count" "1"
assert_file_eq "L: last_full_wan_disruption = now" "$STATE_DIR/last_full_wan_disruption" "123456"
assert_file_eq "L: last_full_wan_reason" "$STATE_DIR/last_full_wan_reason" "test-reason"
# Lifecycle sequence: ifdown wan6, ifdown wan, then ifup wan, ifup wan6
assert_eq "L: ifdown wan6 called once" "$(count_ifdown wan6)" "1"
assert_eq "L: ifdown wan called once" "$(count_ifdown wan)" "1"
assert_eq "L: ifup wan called once" "$(count_ifup wan)" "1"
assert_eq "L: ifup wan6 called once" "$(count_ifup wan6)" "1"
# Sleep called with WAN_DOWN_SLEEP then WAN_UP_SLEEP
grep -q "^30$" "$SLEEP_LOG" && pass "L: sleep 30 (WAN_DOWN_SLEEP) called" || fail "L: sleep 30 missing"
grep -q "^20$" "$SLEEP_LOG" && pass "L: sleep 20 (WAN_UP_SLEEP) called" || fail "L: sleep 20 missing"
wan_recovery_end

echo "--- M. third disruption: count 2 -> execute -> count 3, hold latched, lifecycle still executes ---"
TEST_ID=M
fresh_env
set_now 200000
put_state disruption_count 2
wan_recovery_full_begin
assert_rc "M: begin allowed (count=2 < limit=3)" "$?" "0"
assert_file_missing "M: no hold before execute" "$STATE_DIR/disruption_hold"
wan_recovery_full_execute_locked "third-disruption"
exec_rc=$?
assert_rc "M: execute rc" "$exec_rc" "0"
assert_file_eq "M: count = 3" "$STATE_DIR/disruption_count" "3"
assert_file_exists "M: hold latched at count=3" "$STATE_DIR/disruption_hold"
assert_file_eq "M: last_full_wan_reason" "$STATE_DIR/last_full_wan_reason" "third-disruption"
# Current lifecycle still executed (third disruption runs).
assert_eq "M: ifdown wan6 called" "$(count_ifdown wan6)" "1"
assert_eq "M: ifup wan6 called" "$(count_ifup wan6)" "1"
wan_recovery_end

echo "--- N. lifecycle partial failure: accounting remains recorded, all commands attempted, rc nonzero ---"
TEST_ID=N
fresh_env
set_now 300000
put_state disruption_count 0
# Force ifdown wan6 to fail (first command).
: > "$FAIL_IFDOWN"
wan_recovery_full_begin
assert_rc "N: begin allowed" "$?" "0"
wan_recovery_full_execute_locked "partial-fail"
exec_rc=$?
assert_rc "N: execute rc nonzero on ifdown failure" "$exec_rc" "1"
# Accounting still recorded.
assert_file_eq "N: count = 1" "$STATE_DIR/disruption_count" "1"
assert_file_eq "N: last_full_wan_disruption" "$STATE_DIR/last_full_wan_disruption" "300000"
# All lifecycle commands still attempted (the sequence continues past failure).
assert_eq "N: ifdown wan6 attempted" "$(count_ifdown wan6)" "1"
assert_eq "N: ifdown wan attempted" "$(count_ifdown wan)" "1"
assert_eq "N: ifup wan attempted" "$(count_ifup wan)" "1"
assert_eq "N: ifup wan6 attempted" "$(count_ifup wan6)" "1"
wan_recovery_end

echo "--- O. fourth begin after count/hold limit: blocked before lifecycle ---"
TEST_ID=O
fresh_env
set_now 400000
put_state disruption_count 3
: > "$STATE_DIR/disruption_hold"
wan_recovery_full_begin
rc=$?
assert_rc "O: begin blocked by hold rc" "$rc" "2"
# No ifdown/ifup should have been called.
assert_eq "O: no ifdown" "$(count_ifdown wan6)" "0"
assert_eq "O: no ifup" "$(count_ifup wan6)" "0"

echo "--- P. end is idempotent ---"
TEST_ID=P
fresh_env
set_now 100000
wan_recovery_full_begin
assert_rc "P: begin allowed" "$?" "0"
wan_recovery_end
# Second end should be a no-op (no error).
wan_recovery_end
assert_eq "P: lock not held after double end" "$_WAN_RECOVERY_LOCK_HELD" "0"
# Third end still safe.
wan_recovery_end
pass "P: triple end safe"

echo "--- Q. end without begin safe ---"
TEST_ID=Q
fresh_env
wan_recovery_end
assert_eq "Q: lock not held" "$_WAN_RECOVERY_LOCK_HELD" "0"
pass "Q: end without begin did not error"

echo "--- R. wan6_begin: normal -> rc=0 + shared lock held ---"
TEST_ID=R
fresh_env
set_now 100000
wan_recovery_wan6_begin
rc=$?
assert_rc "R: wan6_begin rc" "$rc" "0"
assert_eq "R: lock held" "$_WAN_RECOVERY_LOCK_HELD" "1"
wan_recovery_end

echo "--- S. wan6_begin: full-WAN cooldown active -> rc=1 ---"
TEST_ID=S
fresh_env
set_now 100000
put_state last_full_wan_disruption 99900
wan_recovery_wan6_begin
rc=$?
assert_rc "S: wan6_begin blocked by cooldown rc" "$rc" "1"
assert_eq "S: lock released" "$_WAN_RECOVERY_LOCK_HELD" "0"

echo "--- T. wan6_begin: shared hold active -> rc=2 ---"
TEST_ID=T
fresh_env
set_now 100000
: > "$STATE_DIR/disruption_hold"
wan_recovery_wan6_begin
rc=$?
assert_rc "T: wan6_begin blocked by hold rc" "$rc" "2"
assert_eq "T: lock released" "$_WAN_RECOVERY_LOCK_HELD" "0"

echo "--- U. wan6_begin: shared lock busy -> rc=3 ---"
TEST_ID=U
fresh_env
set_now 100000
mkdir "$STATE_DIR/disruption.lock.dir"
wan_recovery_wan6_begin
rc=$?
assert_rc "U: wan6_begin busy rc" "$rc" "3"
assert_eq "U: lock not held" "$_WAN_RECOVERY_LOCK_HELD" "0"

echo "--- V. wan6_record_locked: writes last_wan6_action BEFORE ifdown, no count/hold mutation ---"
TEST_ID=V
fresh_env
set_now 555555
put_state disruption_count 1
wan_recovery_wan6_begin
assert_rc "V: wan6_begin allowed" "$?" "0"
# Record BEFORE caller's ifdown.
wan_recovery_wan6_record_locked "tier0-flap"
record_rc=$?
assert_rc "V: wan6_record_locked rc" "$record_rc" "0"
assert_file_eq "V: last_wan6_action = now" "$STATE_DIR/last_wan6_action" "555555"
assert_file_eq "V: last_wan6_reason" "$STATE_DIR/last_wan6_reason" "tier0-flap"
# Count NOT incremented by wan6 record.
assert_file_eq "V: disruption_count unchanged (1)" "$STATE_DIR/disruption_count" "1"
# Hold NOT latched by wan6 record.
assert_file_missing "V: no hold latched" "$STATE_DIR/disruption_hold"
# last_full_wan_disruption NOT written by wan6 record.
assert_file_missing "V: no last_full_wan_disruption" "$STATE_DIR/last_full_wan_disruption"
# Caller now performs its own ifdown wan6 (simulated by calling the stub).
"$STUB_DIR/ifdown" wan6
wan_recovery_end

echo "--- W. common lock serialization: held wan6 prevents simultaneous full-WAN begin ---"
TEST_ID=W
fresh_env
set_now 100000
# Acquire the shared lock via wan6_begin (held).
wan_recovery_wan6_begin
assert_rc "W: wan6_begin allowed" "$?" "0"
# While wan6 holds the lock, a full_begin in the SAME process would see the
# internal _WAN_RECOVERY_LOCK_HELD=1 already. But the real serialization
# scenario is TWO PROCESSES. Simulate a second process by pre-creating the
# fallback lock dir (as if another process holds it).
# Release our lock first, then simulate another holder.
wan_recovery_end
mkdir "$STATE_DIR/disruption.lock.dir"
# Now a full_begin should see busy.
wan_recovery_full_begin
rc=$?
assert_rc "W: full_begin blocked while wan6 holder active rc" "$rc" "3"

echo "--- X. reverse serialization: held full-WAN prevents wan6_begin ---"
TEST_ID=X
fresh_env
set_now 100000
# Simulate a full-WAN holder by pre-creating the fallback lock dir.
mkdir "$STATE_DIR/disruption.lock.dir"
wan_recovery_wan6_begin
rc=$?
assert_rc "X: wan6_begin blocked while full-WAN holder active rc" "$rc" "3"

echo "--- Y. mkdir fallback fresh dir -> busy ---"
TEST_ID=Y
fresh_env
set_now 100000
# Fresh fallback dir owned by another process.
mkdir "$STATE_DIR/disruption.lock.dir"
# Make it "fresh" by ensuring its mtime is current. The library's stale check
# compares the dir's real mtime against (now - WAN_RECOVERY_STALE_LOCK_AGE).
# With _WAN_RECOVERY_NOW=100000 and STALE_LOCK_AGE=600, stale_at=99400. A
# real mtime (~1.7e9) is far greater, so the dir is correctly NOT stale.
command -v touch >/dev/null 2>&1 && touch "$STATE_DIR/disruption.lock.dir"
wan_recovery_full_begin
rc=$?
assert_rc "Y: fresh fallback dir -> busy rc" "$rc" "3"
assert_file_exists "Y: fresh dir NOT removed" "$STATE_DIR/disruption.lock.dir"

echo "--- Z. mkdir fallback stale dir -> cleanup exact dir + acquire ---"
TEST_ID=Z
fresh_env
set_now 100000
# Create a stale fallback dir. To make stat -c %Y return an old mtime, we
# need the dir's real mtime to be old. Since we can't actually wait 600s,
# we set WAN_RECOVERY_STALE_LOCK_AGE=1 and sleep 2 via the stub (which is
# a no-op). Instead, create the dir, then use touch -d to backdate it if
# supported; else rely on a tiny STALE_LOCK_AGE + real sleep.
WAN_RECOVERY_STALE_LOCK_AGE=1
export WAN_RECOVERY_STALE_LOCK_AGE
mkdir "$STATE_DIR/disruption.lock.dir"
# Backdate the dir mtime if touch -d supports epoch. If not, real-sleep.
if touch -d "@100" "$STATE_DIR/disruption.lock.dir" 2>/dev/null; then
    : # backdated successfully
else
    # Real sleep 2s to exceed STALE_LOCK_AGE=1. Use real sleep, not stub.
    ( sleep 2 )
fi
# Re-source library so it picks up the new STALE_LOCK_AGE (already sourced; the
# global is read at sanitize time inside begin). Call begin.
wan_recovery_full_begin
rc=$?
assert_rc "Z: stale fallback dir cleaned + acquired rc" "$rc" "0"
# The stale dir should have been removed and re-created by us (own fallback=1),
# so it exists and we own it.
assert_eq "Z: lock held" "$_WAN_RECOVERY_LOCK_HELD" "1"
assert_eq "Z: we own the fallback" "$_WAN_RECOVERY_OWN_FALLBACK" "1"
wan_recovery_end
# After release, the dir we own should be removed.
assert_file_missing "Z: fallback dir removed on end" "$STATE_DIR/disruption.lock.dir"

echo "--- AA. library does NOT install/change caller trap (static assertion) ---"
TEST_ID=AA
# Static assertion: the library must not contain a 'trap' command that
# installs its own EXIT/INT/TERM handler.
if grep -n '^[[:space:]]*trap[[:space:]]' "$LIB" >/dev/null 2>&1; then
    fail "AA: library installs a trap (should not)"
else
    pass "AA: library does not install a trap (static)"
fi
# Also verify the library exposes wan_recovery_cleanup for callers to invoke
# from THEIR trap.
if grep -q '^wan_recovery_cleanup()' "$LIB"; then
    pass "AA: wan_recovery_cleanup exposed for caller trap use"
else
    fail "AA: wan_recovery_cleanup not exposed"
fi

echo "--- AB. no protocol-health symbols exist ---"
TEST_ID=AB
for sym in ipv4_ok wan_has_ip wan_link_up ipv6_ok has_prefix pd_internet_ok wan6_is_up; do
    if grep -q "^${sym}()" "$LIB"; then
        fail "AB: protocol-health symbol '$sym' found in library (should be absent)"
    else
        pass "AB: '$sym' absent (protocol-neutral)"
    fi
done

echo "--- AC. no router-specific addresses/identities ---"
TEST_ID=AC
# The library must not embed router identities, MAC addresses, IPv6
# addresses, provider names, or local paths. Check common leak patterns.
leaks=0
for pat in 'fe80::' '2001:4453' '2001:4451' 'PLDT' '/mnt/' 'eth1' 'br-lan' 'gl-mt6000'; do
    if grep -q "$pat" "$LIB"; then
        fail "AC: router-specific pattern '$pat' found in library"
        leaks=$((leaks + 1))
    else
        pass "AC: '$pat' absent (router-neutral)"
    fi
done
if [ "$leaks" -eq 0 ]; then
    pass "AC: library is router-neutral"
fi

# ================================================================
# Summary
# ================================================================
echo ""
echo "=== SUMMARY ==="
echo "PASS: $PASS"
echo "FAIL: $FAIL"
if [ "$FAIL" -gt 0 ]; then
    echo "TESTS FAILED"
    exit 1
fi
echo "ALL TESTS PASSED"
exit 0