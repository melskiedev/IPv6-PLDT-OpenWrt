#!/bin/sh
# tests/lib/mock-isolation.sh
#
# Canonical mock-isolation guard for the shell test harnesses.
#
# WHY THIS EXISTS
# ---------------
# Many distributions (Ubuntu among them) build BusyBox as a STANDALONE SHELL
# (FEATURE_SH_STANDALONE). In that build, `busybox ash` resolves BusyBox
# APPLETS *before* it consults PATH. The commands these harnesses mock split
# in two:
#
#   applets      ip, ping6, ifdown, ifup, sleep, date, awk, sed, grep, head
#   NOT applets  uci, ubus, jsonfilter, flock
#
# A harness that only prepends its mock directory to PATH therefore still gets
# the REAL command for every applet. Observed consequence, before this guard
# existed:
#
#   ifdown: can't open '/etc/network/interfaces': No such file or directory
#   ifup: can't open '/etc/network/interfaces': No such file or directory
#
# The non-applet mocks kept resolving, so scenario setup succeeded and the
# failure looked partial rather than total, which made it easy to misread as a
# production bug. dash and bash have no applet concept and always honour PATH,
# so the same suites pass there and the problem stays invisible until BusyBox
# runs them. Parse checks cannot catch it either: this is runtime command
# resolution, not syntax, and `dash -n` / `busybox ash -n` both pass.
#
# HOW IT IS FIXED
# ---------------
# Shell FUNCTIONS outrank both applets and PATH in dash, bash AND BusyBox ash
# (verified in all three). A thin function per mocked command therefore forces
# every invocation into the mock directory whichever shell runs the suite. The
# guard then PROVES that routing and aborts before any test runs if a single
# command is not the mock.
#
# THIS IS TEST-HARNESS ISOLATION ONLY. No production script is affected: on the
# router the watchdog is SUPPOSED to call the real ip/ifdown/ifup, and
# applet-first resolution is correct there.
#
# USAGE
# -----
#   . "$SCRIPT_DIR/tests/lib/mock-isolation.sh"
#   mock_isolation_enforce MOCK_DIR "uci ubus ip ping6 ifdown ifup sleep"
#
# Pass the NAME of the directory variable, not its value. The shims re-read
# that variable at CALL time, so a suite that reassigns its mock directory per
# test -- e.g. STUB_DIR="$TEST_ROOT/stubs-$$-$TEST_ID" -- keeps working without
# re-enforcing. Passing the value instead silently pins the shims to whichever
# directory existed at enforce time, which is a subtle and very hard-to-spot
# failure: tests appear to run but exercise stale stubs.
#
# PLACEMENT IS A PER-SUITE DECISION, NOT A MECHANICAL ONE
# -------------------------------------------------------
# Call this AFTER the mocks it names have been created and BEFORE the first
# test that needs them. Suites differ:
#   * mocks built in one block up front  -> a single call after that block;
#   * mocks built in stages              -> one call per stage, naming only the
#                                           mocks that exist at that point
#                                           (see tests/test-prefix-helpers.sh);
#   * mock dir rebuilt per test          -> a single call still suffices,
#                                           because the shims resolve the
#                                           directory variable at call time.
# Naming a mock that does not exist yet is not a bug in the caller -- the guard
# will fail closed, which is the intended behaviour.
#
# On any failure this prints a diagnostic and exits 2 without running anything.

MOCK_ISOLATION_SENTINEL="__mock_selftest__"

# Resolve the caller's mock directory by variable NAME, at call time.
_mock_isolation_dir() { eval "printf '%s' \"\$$MOCK_ISOLATION_VAR\""; }

mock_isolation_abort() {
    echo "FATAL: mock isolation check failed -- $1" >&2
    echo "FATAL: refusing to run tests; real host commands could be invoked." >&2
    echo "FATAL: ${MOCK_ISOLATION_VAR}=$(_mock_isolation_dir)" >&2
    exit 2
}

# Give every mock a sentinel response as its first action, before any logging
# or side effect. Injected generically so no mock body needs hand-editing and
# newly added mocks inherit the behaviour. Idempotent.
mock_isolation_inject_sentinels() {
    # Distinct variable names on purpose: this runs inside
    # mock_isolation_enforce, and POSIX sh has no scoping, so reusing the
    # caller's _mi_d here would clobber it (this was a real bug during
    # development -- the canary ended up being written to /).
    _mi_inj_d=$(_mock_isolation_dir)
    for _mi_inj_f in "$_mi_inj_d"/*; do
        [ -f "$_mi_inj_f" ] || continue
        head -2 "$_mi_inj_f" | grep -q "$MOCK_ISOLATION_SENTINEL" && continue
        {
            echo '#!/bin/sh'
            echo '[ "$1" = "__mock_selftest__" ] && { echo "MOCK_OK"; exit 0; }'
            tail -n +2 "$_mi_inj_f"
        } > "$_mi_inj_f.mi" && mv "$_mi_inj_f.mi" "$_mi_inj_f" && chmod +x "$_mi_inj_f"
    done
    unset _mi_inj_d _mi_inj_f
}

# mock_isolation_enforce <DIR_VAR_NAME> "<space separated command list>"
mock_isolation_enforce() {
    MOCK_ISOLATION_VAR="$1"
    MOCK_ISOLATION_CMDS="$2"
    _mi_d=$(_mock_isolation_dir)

    [ -n "$_mi_d" ] || mock_isolation_abort "\$$MOCK_ISOLATION_VAR is empty"
    [ -d "$_mi_d" ] || mock_isolation_abort "mock directory does not exist: $_mi_d"

    mock_isolation_inject_sentinels

    # A canary that exists ONLY as a mock: not an applet, not a host binary.
    # If the bare name answers, function-shim dispatch demonstrably works in
    # this shell, and the probe cannot possibly have touched a real command.
    cat > "$_mi_d/__mock_canary__" <<'CANARYEOF'
#!/bin/sh
echo "MOCK_OK"
CANARYEOF
    chmod +x "$_mi_d/__mock_canary__"

    # Shims re-read the directory variable at CALL time (see USAGE above).
    # Deliberately NOT skipped when a mock file is missing: a shim pointing at
    # a missing file fails loudly in verify() instead of silently falling
    # through to a real binary.
    for _mi_c in $MOCK_ISOLATION_CMDS __mock_canary__; do
        eval "$_mi_c() { \"\$$MOCK_ISOLATION_VAR\"/$_mi_c \"\$@\"; }"
    done
    unset _mi_c

    # Deliberate-breakage hook for the safety regression tests. Simulates the
    # exact pre-fix condition: shims gone and mocks removed, so bare names
    # would fall through to BusyBox applets or real host binaries.
    if [ "${MOCK_ISOLATION_BREAK:-0}" = "1" ]; then
        for _mi_c in $MOCK_ISOLATION_CMDS __mock_canary__; do
            unset -f "$_mi_c" 2>/dev/null || true
        done
        unset _mi_c
        rm -f "$_mi_d"/* 2>/dev/null
    fi

    mock_isolation_verify
}

# Re-checkable proof. Safe to call again at any point, e.g. after a suite
# rebuilds its stubs or adds a mock in a later stage.
mock_isolation_verify() {
    _mi_v_d=$(_mock_isolation_dir)

    # 1. Prove function-shim dispatch works at all, using a name that has no
    #    host binary and no applet behind it. Cannot reach a real command.
    _mi_out=$(__mock_canary__ "$MOCK_ISOLATION_SENTINEL" 2>/dev/null)
    [ "$_mi_out" = "MOCK_OK" ] || \
        mock_isolation_abort "function-shim dispatch not working (canary='$_mi_out')"

    # 2. Every required mock must exist and be executable. Checked WITHOUT
    #    invoking anything, so a broken setup cannot reach real ifdown/ifup
    #    at this stage.
    for _mi_c in $MOCK_ISOLATION_CMDS; do
        [ -f "$_mi_v_d/$_mi_c" ] && [ -x "$_mi_v_d/$_mi_c" ] || \
            mock_isolation_abort "missing or non-executable mock: $_mi_v_d/$_mi_c"
    done

    # 3. Only now -- dispatch proven (1), every mock present (2) -- invoke each
    #    bare command name the way production code does, and require the mock's
    #    sentinel. Steps 1 and 2 guarantee this cannot reach a real binary.
    for _mi_c in $MOCK_ISOLATION_CMDS; do
        _mi_out=$($_mi_c "$MOCK_ISOLATION_SENTINEL" 2>/dev/null)
        [ "$_mi_out" = "MOCK_OK" ] || \
            mock_isolation_abort "'$_mi_c' does not resolve to $_mi_v_d (got '$_mi_out')"
    done
    unset _mi_c _mi_out _mi_v_d
}
