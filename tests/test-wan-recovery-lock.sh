#!/bin/sh
# tests/test-wan-recovery-lock.sh
#
# Shared-coordinator flock OWNERSHIP regression suite.
#
# tests/test-wan-recovery-common.sh deliberately stubs flock (default 127) so
# the mkdir fallback is exercised, and it runs in a shell whose descriptor
# layout does not resemble ipv6-watchdog's. Neither condition could catch the
# defect this suite exists for:
#
#   _wan_recovery_lock_acquire opened its candidate fd inside a SUBSHELL, so
#   the descriptor vanished before `flock -n "$_fd"` ran in the parent. With
#   ipv6-watchdog already holding fd 9 for its own watchdog.lock, the lock
#   could be taken against the WRONG FILE and recorded as ownership of the
#   shared disruption lock -- after which wan_recovery_end would unlock and
#   close the watchdog's own lock.
#
# These tests therefore use the REAL flock binary and reproduce production fd
# ownership (fd 9 held on watchdog.lock) rather than mocking it away.
#
# Usage: sh tests/test-wan-recovery-lock.sh
# Exit:  0 = all pass, 1 = any fail, 2 = mock isolation failure

TEST_SCRIPT="$0"
SCRIPT_DIR="$(cd "$(dirname "$TEST_SCRIPT")/.." && pwd)"
TEST_BASE="$SCRIPT_DIR/.test-tmp"
TEST_ROOT="$TEST_BASE/wan-recovery-lock-test-$$"
mkdir -p "$TEST_ROOT"

cleanup() {
    wan_recovery_cleanup 2>/dev/null
    exec 9>&- 2>/dev/null
    rm -rf "$TEST_ROOT"
}
trap cleanup EXIT
trap 'cleanup; exit 130' INT
trap 'cleanup; exit 143' TERM

PASS=0
FAIL=0
ORIG_PATH="$PATH"

pass() { PASS=$((PASS + 1)); echo "  PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); echo "  FAIL: $1"; }
assert_eq() {
    if [ "$2" = "$3" ]; then pass "$1 ($2)"; else fail "$1 (expected '$3', got '$2')"; fi
}

# ================================================================
# Mocks. Only sleep/date-free helpers are stubbed; flock is REAL because its
# real fd semantics are precisely what is under test.
# ================================================================
MOCK_DIR="$TEST_ROOT/mock"
mkdir -p "$MOCK_DIR"

for _c in ifdown ifup; do
cat > "$MOCK_DIR/$_c" <<EOF
#!/bin/sh
echo "FORBIDDEN $_c \$*" >> "\$LOCK_FORBIDDEN_LOG"
exit 0
EOF
chmod +x "$MOCK_DIR/$_c"
done
unset _c

cat > "$MOCK_DIR/sleep" <<'EOF'
#!/bin/sh
:
EOF
chmod +x "$MOCK_DIR/sleep"

# flock wrapper. Created BEFORE any test runs, because shells cache command
# lookups: dropping a stub into PATH later would be ignored once the real
# binary had already been hashed. Mode is switched through a control file
# instead. `exec` preserves file descriptors, so the real fd semantics under
# test are unaffected by the extra layer.
REAL_FLOCK=$(command -v flock 2>/dev/null)
FLOCK_MODE_FILE="$TEST_ROOT/flock.mode"
echo real > "$FLOCK_MODE_FILE"
export FLOCK_MODE_FILE
cat > "$MOCK_DIR/flock" <<EOF
#!/bin/sh
[ "\$(cat "\$FLOCK_MODE_FILE" 2>/dev/null)" = "unusable" ] && exit 127
[ -n "$REAL_FLOCK" ] || exit 127
exec "$REAL_FLOCK" "\$@"
EOF
chmod +x "$MOCK_DIR/flock"

LOCK_FORBIDDEN_LOG="$TEST_ROOT/forbidden.log"
export LOCK_FORBIDDEN_LOG
: > "$LOCK_FORBIDDEN_LOG"

# Mock isolation. flock is intentionally NOT shimmed: this suite must use the
# genuine binary/applet. ifdown/ifup/sleep are shimmed because they are
# BusyBox applets that would otherwise reach the real host.
. "$SCRIPT_DIR/tests/lib/mock-isolation.sh"
mock_isolation_enforce MOCK_DIR "ifdown ifup sleep"

PATH="$MOCK_DIR:$ORIG_PATH"

# ================================================================
# Load the coordinator
# ================================================================
WAN_RECOVERY_STATE_DIR="$TEST_ROOT/wan-recovery"
mkdir -p "$WAN_RECOVERY_STATE_DIR"
WAN_DISRUPTION_LIMIT=3
WAN_DISRUPTION_COOLDOWN=1200
WAN6_TO_FULL_WAN_GRACE=0
# shellcheck disable=SC1090
. "$SCRIPT_DIR/wan-recovery-common"
_wan_recovery_paths

HAVE_FLOCK=0
command -v flock >/dev/null 2>&1 && HAVE_FLOCK=1
HAVE_PROCFD=0
[ -d "/proc/$$/fd" ] && HAVE_PROCFD=1

echo "=== shared coordinator lock ownership ==="
echo "  flock: $HAVE_FLOCK   /proc fd introspection: $HAVE_PROCFD"

WATCHDOG_LOCK="$TEST_ROOT/watchdog.lock"

reset_coord_state() {
    wan_recovery_cleanup 2>/dev/null
    rm -f "$DISRUPTION_COUNT_FILE" "$LAST_FULL_WAN_DISRUPTION_FILE" \
          "$LAST_WAN6_ACTION_FILE" "$LAST_FULL_WAN_REASON_FILE" \
          "$LAST_WAN6_REASON_FILE" "$DISRUPTION_HOLD_FILE" 2>/dev/null
    rmdir "$DISRUPTION_LOCK_DIR" 2>/dev/null
    : > "$LOCK_FORBIDDEN_LOG"
}

# Does an independent process hold an exclusive flock on the given file?
# Returns 0 when the file is FREE (we could take it), 1 when it is held.
external_can_lock() {
    _ecl_f="$1"
    [ "$HAVE_FLOCK" = "1" ] || return 0
    sh -c 'exec 3>>"$1"; flock -n 3' _ "$_ecl_f" 2>/dev/null
}

fd_target() { readlink "/proc/$$/fd/$1" 2>/dev/null; }

# ================================================================
# A. Pre-occupied fd 9 (production layout)
# ================================================================
test_A() {
    echo "--- A: caller already owns fd 9 (watchdog.lock) ---"
    reset_coord_state

    exec 9>>"$WATCHDOG_LOCK"
    if [ "$HAVE_FLOCK" = "1" ]; then
        if flock -n 9 2>/dev/null; then
            pass "A: test process holds watchdog fd 9"
        else
            fail "A: could not lock watchdog fd 9"
        fi
    else
        pass "A: flock unavailable, fd 9 opened without lock"
    fi

    _a_fd9_before=$(fd_target 9)
    assert_eq "A: fd 9 points at watchdog.lock" "$_a_fd9_before" "$WATCHDOG_LOCK"

    wan_recovery_full_begin
    _a_rc=$?
    echo "    wan_recovery_full_begin rc=$_a_rc  coord fd='$_WAN_RECOVERY_LOCK_FD'  fallback=$_WAN_RECOVERY_OWN_FALLBACK"

    # The coordinator must never claim fd 9.
    if [ "$_WAN_RECOVERY_LOCK_FD" = "9" ]; then
        fail "A: coordinator hijacked caller fd 9"
    else
        pass "A: coordinator did not claim fd 9"
    fi

    if [ "$_a_rc" -eq 0 ]; then
        pass "A: begin granted exclusion"
        if [ -n "$_WAN_RECOVERY_LOCK_FD" ]; then
            _a_t=$(fd_target "$_WAN_RECOVERY_LOCK_FD")
            if [ "$_a_t" = "$DISRUPTION_LOCK_FILE" ]; then
                pass "A: coordinator fd refers to disruption.lock"
            else
                fail "A: coordinator fd refers to '$_a_t', not disruption.lock"
            fi
        else
            # mkdir fallback path
            if [ -d "$DISRUPTION_LOCK_DIR" ]; then
                pass "A: mkdir fallback ownership taken"
            else
                fail "A: rc=0 with neither an fd nor the fallback dir"
            fi
        fi
    else
        fail "A: begin should have been granted on a free coordinator (rc=$_a_rc)"
    fi

    # fd 9 must be untouched and still locked while the coordinator holds its own.
    assert_eq "A: fd 9 still points at watchdog.lock" "$(fd_target 9)" "$WATCHDOG_LOCK"
    if [ "$HAVE_FLOCK" = "1" ]; then
        if external_can_lock "$WATCHDOG_LOCK"; then
            fail "A: watchdog.lock became free while coordinator held its lock"
        else
            pass "A: watchdog.lock still exclusively held"
        fi
    else
        pass "A: watchdog lock check skipped (no flock)"
    fi

    wan_recovery_end

    # After release, fd 9 must STILL be open and locked.
    assert_eq "A: fd 9 open after wan_recovery_end" "$(fd_target 9)" "$WATCHDOG_LOCK"
    if [ "$HAVE_FLOCK" = "1" ]; then
        if external_can_lock "$WATCHDOG_LOCK"; then
            fail "A: wan_recovery_end released the caller's watchdog lock"
        else
            pass "A: wan_recovery_end left the watchdog lock intact"
        fi
    else
        pass "A: watchdog lock post-check skipped (no flock)"
    fi

    exec 9>&- 2>/dev/null
}

# ================================================================
# B. rc=0 means real exclusion against an independent process
# ================================================================
test_B() {
    echo "--- B: rc=0 excludes a competing process ---"
    reset_coord_state

    if external_can_lock "$DISRUPTION_LOCK_FILE"; then
        pass "B: disruption.lock free before begin"
    else
        fail "B: disruption.lock already held before begin"
    fi

    wan_recovery_full_begin
    _b_rc=$?
    assert_eq "B: begin granted" "$_b_rc" "0"

    if [ "$HAVE_FLOCK" = "1" ] && [ -n "$_WAN_RECOVERY_LOCK_FD" ]; then
        if external_can_lock "$DISRUPTION_LOCK_FILE"; then
            fail "B: another process could still lock disruption.lock -- NOT exclusive"
        else
            pass "B: competing process is blocked while ownership is held"
        fi
    else
        # mkdir fallback: exclusion is proven by the directory existing.
        if [ -d "$DISRUPTION_LOCK_DIR" ]; then
            pass "B: fallback lock dir present (exclusion via mkdir)"
        else
            fail "B: no exclusion artifact after rc=0"
        fi
    fi

    wan_recovery_end

    if [ "$HAVE_FLOCK" = "1" ] && [ "$_b_rc" -eq 0 ]; then
        if external_can_lock "$DISRUPTION_LOCK_FILE"; then
            pass "B: lock is free again after wan_recovery_end"
        else
            fail "B: disruption.lock still held after wan_recovery_end"
        fi
    else
        if [ -d "$DISRUPTION_LOCK_DIR" ]; then
            fail "B: fallback dir left behind after end"
        else
            pass "B: fallback dir removed after end"
        fi
    fi
}

# ================================================================
# C. Busy: an existing owner must not be disturbed
# ================================================================
test_C() {
    echo "--- C: existing owner blocks begin and is not disturbed ---"
    reset_coord_state

    if [ "$HAVE_FLOCK" != "1" ]; then
        # Model the fallback owner instead.
        mkdir -p "$DISRUPTION_LOCK_DIR"
        wan_recovery_full_begin
        _c_rc=$?
        assert_eq "C: begin refused (fallback owner)" "$_c_rc" "3"
        if [ -d "$DISRUPTION_LOCK_DIR" ]; then pass "C: owner's lock dir intact"; else fail "C: owner's lock dir removed"; fi
        rmdir "$DISRUPTION_LOCK_DIR" 2>/dev/null
        return 0
    fi

    # Hold disruption.lock from a genuinely independent process.
    #
    # Synchronisation uses BLOCKING FIFO reads, not a polling loop: `sleep` is
    # mocked to a no-op here, so any spin-wait is a race and made this case
    # intermittently fail. Opening/reading a FIFO blocks until the peer writes,
    # which is a real primitive and needs no timing assumptions.
    _c_ready="$TEST_ROOT/c.ready.fifo"
    _c_rel="$TEST_ROOT/c.release.fifo"
    rm -f "$_c_ready" "$_c_rel"
    mkfifo "$_c_ready" "$_c_rel" 2>/dev/null

    sh -c 'exec 3>>"$1"
           if flock -n 3; then echo ready > "$2"; else echo failed > "$2"; exit 1; fi
           read _x < "$3"' \
        _ "$DISRUPTION_LOCK_FILE" "$_c_ready" "$_c_rel" &
    _c_pid=$!

    _c_status=""
    read _c_status < "$_c_ready"     # blocks until the holder reports

    if [ "$_c_status" = "ready" ]; then
        pass "C: independent owner acquired disruption.lock"
        wan_recovery_full_begin
        _c_rc=$?
        assert_eq "C: begin refused as busy" "$_c_rc" "3"
        assert_eq "C: no coordinator fd recorded" "$_WAN_RECOVERY_LOCK_FD" ""
        assert_eq "C: not marked as holding" "$_WAN_RECOVERY_LOCK_HELD" "0"
        # The owner must still hold it.
        if external_can_lock "$DISRUPTION_LOCK_FILE"; then
            fail "C: the existing owner's lock was disturbed"
        else
            pass "C: existing owner undisturbed"
        fi
    else
        fail "C: could not establish an independent lock owner (status='$_c_status')"
        fail "C: skipped dependent assertion (begin refused)"
        fail "C: skipped dependent assertion (no coordinator fd)"
        fail "C: skipped dependent assertion (not marked holding)"
        fail "C: skipped dependent assertion (owner undisturbed)"
    fi

    # Release the holder: this write blocks until it performs its read, so the
    # process is guaranteed to be finished with the lock before we continue.
    echo go > "$_c_rel"
    wait "$_c_pid" 2>/dev/null
    rm -f "$_c_ready" "$_c_rel"

    # Ownership must be genuinely free again now that the holder has exited.
    if external_can_lock "$DISRUPTION_LOCK_FILE"; then
        pass "C: lock free after the independent owner exited"
    else
        fail "C: lock still held after the independent owner exited"
    fi
}

# ================================================================
# D. mkdir fallback when flock is unusable
# ================================================================
test_D() {
    echo "--- D: mkdir fallback when flock is unusable ---"
    reset_coord_state

    echo unusable > "$FLOCK_MODE_FILE"

    wan_recovery_full_begin
    _d_rc=$?
    assert_eq "D: begin granted via fallback" "$_d_rc" "0"
    assert_eq "D: no flock fd recorded" "$_WAN_RECOVERY_LOCK_FD" ""
    assert_eq "D: fallback ownership flagged" "$_WAN_RECOVERY_OWN_FALLBACK" "1"
    if [ -d "$DISRUPTION_LOCK_DIR" ]; then pass "D: fallback lock dir created"; else fail "D: no fallback lock dir"; fi

    # A second begin in the same process must see the directory as busy.
    _d_saved_held=$_WAN_RECOVERY_LOCK_HELD
    _d_saved_own=$_WAN_RECOVERY_OWN_FALLBACK
    _WAN_RECOVERY_LOCK_HELD=0
    _WAN_RECOVERY_OWN_FALLBACK=0
    wan_recovery_full_begin
    assert_eq "D: second begin refused while dir exists" "$?" "3"
    _WAN_RECOVERY_LOCK_HELD=$_d_saved_held
    _WAN_RECOVERY_OWN_FALLBACK=$_d_saved_own

    wan_recovery_end
    if [ -d "$DISRUPTION_LOCK_DIR" ]; then fail "D: fallback dir not removed"; else pass "D: fallback dir removed on end"; fi

    echo real > "$FLOCK_MODE_FILE"
}

# ================================================================
# E. No fd leaks, no stale artifacts, caller fd intact
# ================================================================
test_E() {
    echo "--- E: no fd leak, no stale lock, caller fd intact ---"
    reset_coord_state

    exec 9>>"$WATCHDOG_LOCK"
    [ "$HAVE_FLOCK" = "1" ] && flock -n 9 2>/dev/null

    _e_before=$(ls "/proc/$$/fd" 2>/dev/null | sort | tr '\n' ' ')

    _e_i=0
    while [ "$_e_i" -lt 5 ]; do
        _e_i=$((_e_i + 1))
        wan_recovery_full_begin >/dev/null 2>&1
        wan_recovery_end
    done
    # Idempotent double release must not throw or close anything extra.
    wan_recovery_end
    wan_recovery_cleanup
    wan_recovery_cleanup

    _e_after=$(ls "/proc/$$/fd" 2>/dev/null | sort | tr '\n' ' ')
    assert_eq "E: descriptor set unchanged after 5 begin/end cycles" "$_e_after" "$_e_before"
    assert_eq "E: no coordinator fd retained" "$_WAN_RECOVERY_LOCK_FD" ""
    assert_eq "E: not marked as holding" "$_WAN_RECOVERY_LOCK_HELD" "0"
    if [ -d "$DISRUPTION_LOCK_DIR" ]; then fail "E: stale fallback dir"; else pass "E: no stale fallback dir"; fi
    assert_eq "E: caller fd 9 intact" "$(fd_target 9)" "$WATCHDOG_LOCK"
    if [ "$HAVE_FLOCK" = "1" ]; then
        if external_can_lock "$WATCHDOG_LOCK"; then
            fail "E: caller's watchdog lock was released"
        else
            pass "E: caller's watchdog lock still held"
        fi
    else
        pass "E: watchdog lock check skipped (no flock)"
    fi

    exec 9>&- 2>/dev/null
}

# ================================================================
# F. Accounting semantics unchanged by the lock fix
# ================================================================
test_F() {
    echo "--- F: begin/end write no accounting ---"
    reset_coord_state

    wan_recovery_full_begin >/dev/null 2>&1
    wan_recovery_end

    if [ -f "$DISRUPTION_COUNT_FILE" ]; then fail "F: disruption_count written"; else pass "F: disruption_count untouched"; fi
    if [ -f "$LAST_FULL_WAN_DISRUPTION_FILE" ]; then fail "F: cooldown timestamp written"; else pass "F: last_full_wan_disruption untouched"; fi
    if [ -f "$LAST_FULL_WAN_REASON_FILE" ]; then fail "F: reason written"; else pass "F: last_full_wan_reason untouched"; fi
    if [ -f "$LAST_WAN6_ACTION_FILE" ]; then fail "F: wan6 action written"; else pass "F: last_wan6_action untouched"; fi
    if [ -f "$DISRUPTION_HOLD_FILE" ]; then fail "F: hold latched"; else pass "F: disruption_hold untouched"; fi
    if [ -s "$LOCK_FORBIDDEN_LOG" ]; then fail "F: ifdown/ifup called"; else pass "F: no ifdown/ifup performed"; fi

    # Documented reconciliation: at/over budget with a missing latch, begin
    # RECREATES the hold latch and refuses. This is coordinator-owned state
    # repair, not caller accounting, and it must keep working.
    reset_coord_state
    echo 3 > "$DISRUPTION_COUNT_FILE"
    wan_recovery_full_begin
    assert_eq "F: begin refuses at budget" "$?" "2"
    if [ -f "$DISRUPTION_HOLD_FILE" ]; then pass "F: hold latch reconciled by begin (documented)"; else fail "F: hold latch not reconciled"; fi
    assert_eq "F: count not modified by reconciliation" "$(cat "$DISRUPTION_COUNT_FILE")" "3"
    if [ -d "$DISRUPTION_LOCK_DIR" ]; then fail "F: lock left held after refusal"; else pass "F: lock released on refusal"; fi
    reset_coord_state
}

# ================================================================
# G. Acquisition must work when the caller runs inside a subshell
# ================================================================
# Descriptor introspection must use /proc/self, not /proc/$$: `$$` keeps the
# original shell's pid inside a subshell, so the checks would inspect the
# PARENT's descriptor table while the fd was opened in the child, reject every
# candidate, and return a spurious BUSY. ipv6-watchdog's callers legitimately
# run inside subshells and command substitutions.
test_G() {
    echo "--- G: acquisition inside a subshell ---"
    reset_coord_state

    _g_out="$TEST_ROOT/g.out"
    ( wan_recovery_full_begin
      echo "rc=$? fd=$_WAN_RECOVERY_LOCK_FD fallback=$_WAN_RECOVERY_OWN_FALLBACK" > "$_g_out"
      wan_recovery_end
    )
    _g_line=$(cat "$_g_out" 2>/dev/null)
    echo "    subshell: $_g_line"

    case "$_g_line" in
        rc=0*) pass "G: begin granted inside a subshell" ;;
        *)     fail "G: begin refused inside a subshell ($_g_line)" ;;
    esac

    # The subshell exit released everything; the lock must be free again.
    if external_can_lock "$DISRUPTION_LOCK_FILE"; then
        pass "G: lock free after the subshell exited"
    else
        fail "G: lock still held after the subshell exited"
    fi
    if [ -d "$DISRUPTION_LOCK_DIR" ]; then fail "G: stale fallback dir"; else pass "G: no stale fallback dir"; fi
}

for t in test_A test_B test_C test_D test_E test_F test_G; do
    "$t"
done

echo
echo "================================"
echo "PASS: $PASS"
echo "FAIL: $FAIL"
echo "================================"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
