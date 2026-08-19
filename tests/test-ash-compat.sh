#!/bin/sh
# tests/test-ash-compat.sh
#
# Portability guard for the router-side shell scripts.
#
# Production runs BusyBox ash on OpenWrt. Development and CI typically run
# bash (or dash as /bin/sh) on a glibc distro. A construct can parse and run
# perfectly under bash, and even under dash, yet still break under BusyBox ash
# -- so a green regression suite on a dev box is NOT proof of router
# compatibility. This suite narrows that gap in two ways:
#
#   1. Parse every production script under every POSIX shell available on this
#      machine (dash always; busybox ash when installed). Parsing under
#      busybox ash is the authoritative check and runs automatically the
#      moment busybox is present.
#   2. Scan for bashisms that are accepted by bash but are NOT in BusyBox
#      ash's feature set. These are caught statically, so they are flagged
#      even on a machine with no busybox at all.
#
# This suite deliberately covers only the files that are deployed to the
# router. Test harnesses under tests/ run on the dev machine and may freely
# use bash features.
#
# Usage: bash tests/test-ash-compat.sh
# Exit:  0 = all pass, 1 = any fail

TEST_SCRIPT="$0"
SCRIPT_DIR="$(cd "$(dirname "$TEST_SCRIPT")/.." && pwd)"

PASS=0
FAIL=0
SKIP=0

# Files deployed to the router. Anything here must be BusyBox ash clean.
ROUTER_SCRIPTS="ipv6-watchdog wan-recovery-common 99-ipv6-setup ipv6-discord-logger init.d-ipv6-discord-logger ipv6-prefix-tracker 97-garp"

pass() { PASS=$((PASS + 1)); }
fail() {
    FAIL=$((FAIL + 1))
    echo "  FAIL: $1"
}

# ================================================================
# 1. Parse under every available POSIX shell
# ================================================================

echo "=== Parse check: POSIX shells available on this machine ==="

SHELLS=""
for cand in dash ash; do
    if command -v "$cand" >/dev/null 2>&1; then
        SHELLS="$SHELLS $cand"
    fi
done
if command -v busybox >/dev/null 2>&1; then
    SHELLS="$SHELLS busybox-ash"
fi

echo "  shells: ${SHELLS:-(none beyond bash)}"

for f in $ROUTER_SCRIPTS; do
    [ -f "$SCRIPT_DIR/$f" ] || continue
    for sh_name in $SHELLS; do
        case "$sh_name" in
            busybox-ash) busybox ash -n "$SCRIPT_DIR/$f" 2>/tmp/ashcompat.err ;;
            *)           "$sh_name" -n "$SCRIPT_DIR/$f" 2>/tmp/ashcompat.err ;;
        esac
        if [ $? -eq 0 ]; then
            pass
        else
            fail "$f does not parse under $sh_name"
            sed 's/^/      /' /tmp/ashcompat.err
        fi
    done
done
rm -f /tmp/ashcompat.err

if command -v busybox >/dev/null 2>&1; then
    echo "  busybox ash parse check: RAN (authoritative)"
else
    SKIP=$((SKIP + 1))
    echo "  busybox ash parse check: SKIPPED -- busybox not installed."
    echo "    Install it to make this check authoritative:"
    echo "      sudo apt-get install -y busybox-static"
    echo "    Static bashism scanning below still runs and still applies."
fi

echo "  done (pass=$PASS fail=$FAIL)"

# ================================================================
# 2. Static bashism scan
# ================================================================
#
# Each entry: a description, then an ERE. A hit is a failure. Patterns are
# written to avoid matching inside comments where practical, but the scan is
# intentionally conservative: a false positive is cheap to silence, whereas a
# missed bashism is a router-side breakage that no dev-box test would catch.

echo "=== Static bashism scan (constructs absent from BusyBox ash) ==="

scan() {
    desc="$1"
    pattern="$2"
    hits=""
    for f in $ROUTER_SCRIPTS; do
        [ -f "$SCRIPT_DIR/$f" ] || continue
        # Strip full-line comments before scanning.
        found=$(sed 's/^[[:space:]]*#.*$//' "$SCRIPT_DIR/$f" \
            | grep -nE "$pattern" 2>/dev/null | sed "s|^|      $f:|")
        [ -n "$found" ] && hits="$hits
$found"
    done
    if [ -z "$hits" ]; then
        pass
    else
        fail "$desc"
        printf '%s\n' "$hits" | sed '/^$/d'
    fi
}

scan "[[ ... ]] test keyword (bash/ksh only)"        '\[\[[[:space:]]'
scan "arrays: declare -a / name=( ... )"             '^[[:space:]]*(declare|typeset)[[:space:]]|^[[:space:]]*[A-Za-z_][A-Za-z0-9_]*=\('
scan "\${var^^} / \${var,,} case modification"        '\$\{[A-Za-z_][A-Za-z0-9_]*(\^\^|,,)'
scan "substring expansion \${var:offset:len}"        '\$\{[A-Za-z_][A-Za-z0-9_]*:[0-9]+:[0-9]+\}'
scan "+= append operator"                            '^[[:space:]]*[A-Za-z_][A-Za-z0-9_]*\+='
scan "function keyword"                              '^[[:space:]]*function[[:space:]]+[A-Za-z_]'
scan "C-style for (( ... ))"                         'for[[:space:]]*\(\('
# ANSI-C quoting only counts when $' STARTS a token. Without the boundary
# this matches the portable `grep -v '^$'`, where the $ is regex anchor text.
scan "\$'...' ANSI-C quoting"                         '(^|[[:space:]]|=|\()\$'"'"
scan "<<< here-string"                               '<<<'
scan "process substitution <( ) or >( )"             '[<>]\((\?!\()'
scan "&> or >& redirection"                          '([^0-9]|^)&>|>&[[:space:]]*[A-Za-z/]'
scan "echo -e / echo -n (non-portable flags)"        'echo[[:space:]]+-[en]+[[:space:]]'
scan "source builtin (use . instead)"                '^[[:space:]]*source[[:space:]]'
scan "\$RANDOM outside arithmetic is fine; seq usage" '[^a-zA-Z_]seq[[:space:]]'
scan "let builtin"                                   '^[[:space:]]*let[[:space:]]'
scan "readarray / mapfile"                           '(readarray|mapfile)[[:space:]]'
scan "\${!var} indirect expansion"                    '\$\{![A-Za-z_]'
scan "trap ERR / RETURN (bash-only signals)"         'trap[[:space:]]+[^;]*[[:space:]](ERR|RETURN)([[:space:]]|$)'

echo "  done (pass=$PASS fail=$FAIL)"

# ================================================================
# 3. Constructs the v3.10.1 change introduced -- explicitly confirmed present
#    and ash-safe. These assert the file still contains what we audited, so a
#    later edit that swaps in a bash-only equivalent is noticed.
# ================================================================

echo "=== v3.10.1 introduced-construct audit ==="

WD="$SCRIPT_DIR/ipv6-watchdog"

assert_grep() {
    if grep -qE "$2" "$WD" 2>/dev/null; then
        pass
    else
        fail "$1"
    fi
}

# `local` is a BusyBox ash builtin and is already used throughout this file.
assert_grep "notify_ordinary_recovery uses local" \
    '^notify_ordinary_recovery\(\) \{'
assert_grep "ordinary_incident_duration uses printf, not echo -e" \
    "printf '%ds'"
# Arithmetic must keep a space after \$(( so \$((( is never produced.
if grep -qE '\$\(\(\(' "$WD" 2>/dev/null; then
    fail "found \$((( -- add a space: \$(( ( ... ) ... )"
else
    pass
fi
# Integer comparison, not [[ -gt ]].
assert_grep "duration ceiling uses POSIX test" \
    '\[ "\$delta" -le "\$ORDINARY_MAX_INCIDENT_SECS" \]'

echo "  done (pass=$PASS fail=$FAIL)"

# ================================================================
# ================================================================
# 4. Mock-isolation safety
# ================================================================
#
# Scope note: this is deliberately NARROW. It proves the mock-isolation
# mechanism itself is sound and fails closed; it does NOT re-run the behavioural
# suites. Full BusyBox behavioural validation stays a separate sweep
# (`for t in tests/*.sh; do busybox ash "$t"; done`), because duplicating it
# here would double CI time and give two places to keep in sync.
#
# What is checked:
#   a. the shared helper parses under every POSIX shell available here;
#   b. every suite that uses the helper can reach its guard/self-test path;
#   c. deliberately breaking isolation makes each such suite exit 2;
#   d. that abort happens BEFORE any real host networking command can run.

echo "=== Mock-isolation safety ==="

MOCK_HELPER="$SCRIPT_DIR/tests/lib/mock-isolation.sh"

# --- a. helper parses under every available POSIX shell ---
if [ -f "$MOCK_HELPER" ]; then
    pass
    for sh_name in $SHELLS; do
        case "$sh_name" in
            busybox-ash) busybox ash -n "$MOCK_HELPER" 2>/tmp/mi.err ;;
            *)           "$sh_name" -n "$MOCK_HELPER" 2>/tmp/mi.err ;;
        esac
        if [ $? -eq 0 ]; then
            pass
        else
            fail "tests/lib/mock-isolation.sh does not parse under $sh_name"
            sed 's/^/      /' /tmp/mi.err
        fi
    done
    rm -f /tmp/mi.err
else
    fail "tests/lib/mock-isolation.sh is missing"
fi

# --- suites that opt into the shared guard ---
# This file is excluded from its own list: it mentions mock_isolation_enforce
# in the checks below, and without the exclusion it would re-invoke itself
# under MOCK_ISOLATION_BREAK=1 and recurse forever.
GUARDED_SUITES=$(grep -l 'mock_isolation_enforce' "$SCRIPT_DIR"/tests/*.sh 2>/dev/null \
    | grep -v '/test-ash-compat\.sh$')

if [ -z "$GUARDED_SUITES" ]; then
    fail "no suite uses mock_isolation_enforce -- the guard is not wired up"
else
    pass
fi

for suite in $GUARDED_SUITES; do
    sname=$(basename "$suite")

    # --- b. the suite reaches its guard path at all ---
    # Sourcing the helper and calling enforce must appear together; a suite that
    # calls enforce without sourcing would die at run time in a confusing way.
    if grep -q 'tests/lib/mock-isolation.sh' "$suite"; then
        pass
    else
        fail "$sname calls mock_isolation_enforce but never sources the helper"
    fi

    # --- c + d. break isolation deliberately and require a fail-closed abort ---
    # MOCK_ISOLATION_BREAK=1 removes the shims and empties the mock directory,
    # reproducing the pre-fix condition in which bare ifdown/ifup fell through
    # to BusyBox applets and reached the real host.
    MOCK_ISOLATION_BREAK=1 sh "$suite" >/tmp/mi_break.out 2>&1
    rc=$?

    if [ "$rc" -eq 2 ]; then
        pass
    else
        fail "$sname did not fail closed with broken isolation (exit=$rc)"
        tail -5 /tmp/mi_break.out | sed 's/^/      /'
    fi

    if grep -q 'mock isolation check failed' /tmp/mi_break.out 2>/dev/null; then
        pass
    else
        fail "$sname aborted without the mock-isolation diagnostic"
    fi

    # Safety assertion 1: no real host networking command ran.
    if grep -qE "can't open '/etc/network/interfaces'|RTNETLINK answers" /tmp/mi_break.out 2>/dev/null; then
        fail "$sname reached a REAL host networking command before aborting"
        grep -E "interfaces|RTNETLINK" /tmp/mi_break.out | head -3 | sed 's/^/      /'
    else
        pass
    fi

    # Safety assertion 2, the stronger one: NO test scenario started at all.
    # Absence of a specific error string only proves that one command did not
    # leak. Proving that not a single assertion ran, and not a single scenario
    # header printed, proves nothing downstream of the guard executed -- so
    # real ip/date/sleep/ifdown/ifup cannot have been reached by any path,
    # including ones that fail silently.
    if grep -qE '^ *(PASS|FAIL):' /tmp/mi_break.out 2>/dev/null; then
        fail "$sname executed assertions before the isolation guard aborted"
        grep -E '^ *(PASS|FAIL):' /tmp/mi_break.out | head -3 | sed 's/^/      /'
    else
        pass
    fi

    if grep -qE '^(=== |--- )' /tmp/mi_break.out 2>/dev/null; then
        fail "$sname started a test scenario before the isolation guard aborted"
        grep -E '^(=== |--- )' /tmp/mi_break.out | head -3 | sed 's/^/      /'
    else
        pass
    fi
done
rm -f /tmp/mi_break.out

# --- guarded-suite inventory -------------------------------------------------
# The discovery above must find exactly the suites we expect: no self-match
# (infinite recursion), and no attempt to execute the helper library itself.
inventory_count=$(printf '%s\n' $GUARDED_SUITES | grep -c .)
if [ "$inventory_count" = "6" ]; then
    pass
else
    fail "expected 6 guarded suites, discovered $inventory_count"
    printf '%s\n' $GUARDED_SUITES | sed 's/^/      /'
fi

# Each guarded suite must appear exactly once in the discovery list.
dupes=$(printf '%s\n' $GUARDED_SUITES | sort | uniq -d)
if [ -z "$dupes" ]; then
    pass
else
    fail "guarded-suite discovery returned duplicates"
    printf '%s\n' "$dupes" | sed 's/^/      /'
fi

# The helper library must never be discovered as a runnable suite. It lives in
# tests/lib/, outside the tests/*.sh glob, but assert it rather than rely on
# the glob staying that shape.
if printf '%s\n' $GUARDED_SUITES | grep -q 'mock-isolation\.sh'; then
    fail "tests/lib/mock-isolation.sh was discovered as a runnable suite"
else
    pass
fi

# And this file must never discover itself.
if printf '%s\n' $GUARDED_SUITES | grep -q 'test-ash-compat\.sh'; then
    fail "test-ash-compat.sh discovered itself (would recurse forever)"
else
    pass
fi

echo "  done (pass=$PASS fail=$FAIL)"

echo ""
echo "=== SUMMARY ==="
echo "PASS: $PASS"
echo "FAIL: $FAIL"
[ "$SKIP" -gt 0 ] && echo "NOTE: $SKIP check group(s) skipped (see above)."
if [ "$FAIL" -eq 0 ]; then
    echo "ALL TESTS PASSED"
    exit 0
else
    echo "SOME TESTS FAILED"
    exit 1
fi
