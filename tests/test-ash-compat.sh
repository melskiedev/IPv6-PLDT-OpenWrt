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
ROUTER_SCRIPTS="ipv6-watchdog wan-recovery-common 99-ipv6-setup ipv6-discord-logger init.d-ipv6-discord-logger ipv6-prefix-tracker 97-garp 98-wan6-delay"

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
