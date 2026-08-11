#!/bin/sh
# tests/test-prefix-helpers.sh
#
# Phase 1 / 1B review harness: tests addr_in_prefix(), get_lan_pd_src(),
# is_link_local(), is_ula(), and the wan6 pending-grace timestamp lifecycle
# against the actual helper logic extracted from ipv6-watchdog.
#
# Extracts only the helper functions (not the whole script) to avoid
# running the watchdog's top-level recovery logic.
#
# Usage: sh tests/test-prefix-helpers.sh
# Exit:  0 = all pass, 1 = any fail

TEST_SCRIPT="$0"
SCRIPT_DIR="$(cd "$(dirname "$TEST_SCRIPT")/.." && pwd)"
TEST_ROOT="$(mktemp -d 2>/dev/null || { D="/tmp/pfxtest-$$"; mkdir -p "$D"; echo "$D"; })"

cleanup() { rm -rf "$TEST_ROOT"; }
trap cleanup EXIT
trap 'cleanup; exit 130' INT
trap 'cleanup; exit 143' TERM

PASS=0
FAIL=0

# ================================================================
# Extract helper functions from ipv6-watchdog into a sourcable file.
# We extract from the "PD-FIRST SOURCE-AWARE CONTEXT" comment block
# down through the end of wan128_internet_ok(). This captures:
#   get_pd_addr, get_pd_mask, get_wan_dev, wan6_pending, wan6_up,
#   get_wan128, addr_in_prefix, is_link_local, is_ula, get_lan_pd_src,
#   pending_state_tick, pending_state_reset, populate_pd_context,
#   pd_internet_ok, wan128_internet_ok
# We define a log() stub that appends to a test log file so the pending
# helper's log() calls can be asserted by the tests.
# ================================================================

EXTRACT="$TEST_ROOT/helpers.sh"

awk '
/PD-FIRST SOURCE-AWARE CONTEXT/ { start=1 }
start { print }
start && /^wan128_internet_ok\(\)/ { saw_wan128=1 }
saw_wan128 && /^}/ { start=0; saw_wan128=0 }
' "$SCRIPT_DIR/ipv6-watchdog" > "$EXTRACT"

# Sanity: the extract must contain our key functions.
for fn in addr_in_prefix get_lan_pd_src pd_internet_ok is_link_local is_ula pending_state_tick pending_state_reset; do
    if ! grep -q "^${fn}()" "$EXTRACT"; then
        echo "FATAL: could not extract $fn from ipv6-watchdog" >&2
        exit 2
    fi
done

# log() stub: appends to PENDING_LOG so tests can assert log output.
PENDING_LOG="$TEST_ROOT/pending_log"
: > "$PENDING_LOG"
printf 'log() { echo "$1" >> "%s"; }\n' "$PENDING_LOG" > "$TEST_ROOT/preamble.sh"

# Source the extracted helpers.
# shellcheck disable=SC1090
. "$TEST_ROOT/preamble.sh"

# Set pending-state variables required by pending_state_tick/reset before
# sourcing the extracted helpers. These point at a per-test temp directory so
# tests can reset state between ticks.
PENDING_STATE_DIR="$TEST_ROOT/pending_state"
mkdir -p "$PENDING_STATE_DIR"
WAN6_PENDING_SEEN_FILE="$PENDING_STATE_DIR/wan6_pending_seen"
WAN6_PENDING_EXPIRED_FILE="$PENDING_STATE_DIR/wan6_pending_expired"
WAN6_PENDING_GRACE=180

# shellcheck disable=SC1090
. "$EXTRACT"

# ================================================================
# Test helpers
# ================================================================

assert_match() {
    desc="$1"; addr="$2"; prefix="$3"; mask="$4"; expected="$5"
    if addr_in_prefix "$addr" "$prefix" "$mask"; then
        result="MATCH"
    else
        result="NO_MATCH"
    fi
    if [ "$result" = "$expected" ]; then
        PASS=$((PASS + 1))
        echo "  PASS: $desc -> $result"
    else
        FAIL=$((FAIL + 1))
        echo "  FAIL: $desc -> got $result, expected $expected"
    fi
}

assert_reject_as_lan_src() {
    desc="$1"; ip_output="$2"
    # Write ip_output to a stub and run get_lan_pd_src.
    STUB_DIR="$TEST_ROOT/stubs_$$"
    mkdir -p "$STUB_DIR"
    printf '#!/bin/sh\ncat <<IPSTUB\n%s\nIPSTUB\nexit 0\n' "$ip_output" > "$STUB_DIR/ip"
    chmod +x "$STUB_DIR/ip"
    ORIG_PATH="$PATH"
    LAN_DEV="br-lan"
    PD_ADDR="2001:db8:7e3:7700::"
    PD_MASK="56"
    RESULT=$(PATH="$STUB_DIR:$ORIG_PATH" get_lan_pd_src)
    if [ -n "$RESULT" ]; then
        FAIL=$((FAIL + 1))
        echo "  FAIL: $desc -> should have been rejected, got '$RESULT'"
    else
        PASS=$((PASS + 1))
        echo "  PASS: $desc -> correctly rejected"
    fi
}

assert_lan_pd_src_eq() {
    desc="$1"; ip_output="$2"; expected="$3"
    STUB_DIR="$TEST_ROOT/stubs_$$"
    mkdir -p "$STUB_DIR"
    printf '#!/bin/sh\ncat <<IPSTUB\n%s\nIPSTUB\nexit 0\n' "$ip_output" > "$STUB_DIR/ip"
    chmod +x "$STUB_DIR/ip"
    ORIG_PATH="$PATH"
    LAN_DEV="br-lan"
    PD_ADDR="2001:db8:7e3:7700::"
    PD_MASK="56"
    RESULT=$(PATH="$STUB_DIR:$ORIG_PATH" get_lan_pd_src)
    if [ "$RESULT" = "$expected" ]; then
        PASS=$((PASS + 1))
        echo "  PASS: $desc -> '$RESULT'"
    else
        FAIL=$((FAIL + 1))
        echo "  FAIL: $desc -> expected '$expected', got '$RESULT'"
    fi
}

# ================================================================
# A. Existing prefix-membership tests (remain passing)
# ================================================================

echo "=== A. Prefix-membership tests ==="

echo "--- Test 1: /56 neighbor within prefix ---"
assert_match "2001:db8:7e3:77ff::1 in 2001:db8:7e3:7700::/56" \
    "2001:db8:7e3:77ff::1" "2001:db8:7e3:7700::" "56" "MATCH"

echo "--- Test 2: /56 neighbor in adjacent /56 ---"
assert_match "2001:db8:7e3:7800::1 in 2001:db8:7e3:7700::/56" \
    "2001:db8:7e3:7800::1" "2001:db8:7e3:7700::" "56" "NO_MATCH"

echo "--- Test 3: /48 within prefix ---"
assert_match "2001:db8:abcd:1234::1 in 2001:db8:abcd::/48" \
    "2001:db8:abcd:1234::1" "2001:db8:abcd::" "48" "MATCH"

echo "--- Test 4: /48 adjacent prefix ---"
assert_match "2001:db8:abce::1 in 2001:db8:abcd::/48" \
    "2001:db8:abce::1" "2001:db8:abcd::" "48" "NO_MATCH"

echo "--- Test 5: /64 within prefix ---"
assert_match "2001:db8:abcd:1234::beef in 2001:db8:abcd:1234::/64" \
    "2001:db8:abcd:1234::beef" "2001:db8:abcd:1234::" "64" "MATCH"

echo "--- Test 6: /64 adjacent prefix ---"
assert_match "2001:db8:abcd:1235::1 in 2001:db8:abcd:1234::/64" \
    "2001:db8:abcd:1235::1" "2001:db8:abcd:1234::" "64" "NO_MATCH"

echo "--- Test 7: compressed prefix form 2001:db8:: ---"
assert_match "2001:db8::1 in 2001:db8::/32" \
    "2001:db8::1" "2001:db8::" "32" "MATCH"

echo "--- Test 8: ::1 in ::/0 ---"
assert_match "::1 in ::/0" \
    "::1" "::" "0" "MATCH"

echo "--- Test 9: full address in /128 ---"
assert_match "2001:db8::1 in 2001:db8::1/128" \
    "2001:db8::1" "2001:db8::1" "128" "MATCH"

echo "--- Test 10: different address in /128 ---"
assert_match "2001:db8::2 in 2001:db8::1/128" \
    "2001:db8::2" "2001:db8::1" "128" "NO_MATCH"

# ================================================================
# 5. Hardened prefix mask input
# ================================================================

echo ""
echo "=== 5. Hardened prefix mask input ==="

echo "--- Test 5a: mask=129 -> NO_MATCH ---"
assert_match "2001:db8::1 in 2001:db8::/129" \
    "2001:db8::1" "2001:db8::" "129" "NO_MATCH"

echo "--- Test 5b: mask=abc -> NO_MATCH ---"
assert_match "2001:db8::1 in 2001:db8::/abc" \
    "2001:db8::1" "2001:db8::" "abc" "NO_MATCH"

echo "--- Test 5c: mask=-1 -> NO_MATCH ---"
assert_match "2001:db8::1 in 2001:db8::/-1" \
    "2001:db8::1" "2001:db8::" "-1" "NO_MATCH"

echo "--- Test 5d: mask empty -> NO_MATCH ---"
assert_match "2001:db8::1 in 2001:db8::/ (empty mask)" \
    "2001:db8::1" "2001:db8::" "" "NO_MATCH"

# ================================================================
# B. ULA exclusion (get_lan_pd_src rejects ULA candidates)
# ================================================================

echo ""
echo "=== B. ULA exclusion ==="

PD_ADDR="2001:db8:7e3:7700::"
PD_MASK="56"

echo "--- Test B1: fd12:... compressed rejected ---"
assert_reject_as_lan_src "fd12:3456:789a:1::1 (compressed)" \
    "inet6 fd12:3456:789a:1::1/64 scope global dynamic"
echo "   valid_lft 86400sec preferred_lft 14400sec"

echo "--- Test B2: fd12:... fully written rejected ---"
assert_reject_as_lan_src "fd12:3456:789a:1:1111:2222:3333:4444 (full)" \
    "inet6 fd12:3456:789a:1:1111:2222:3333:4444/64 scope global dynamic"
echo "   valid_lft 86400sec preferred_lft 14400sec"

echo "--- Test B3: fc00:... rejected ---"
assert_reject_as_lan_src "fc00:1234:5678:9abc::1" \
    "inet6 fc00:1234:5678:9abc::1/64 scope global dynamic"
echo "   valid_lft 86400sec preferred_lft 14400sec"

# ================================================================
# C. Link-local range exclusion
# ================================================================

echo ""
echo "=== C. Link-local range exclusion ==="

echo "--- Test C1: fe80::1 rejected ---"
assert_reject_as_lan_src "fe80::1" \
    "inet6 fe80::1/64 scope global"
echo "   valid_lft foreversec preferred_lft foreversec"

echo "--- Test C2: fe80:0:0:0:1:2:3:4 rejected ---"
assert_reject_as_lan_src "fe80:0:0:0:1:2:3:4 (full)" \
    "inet6 fe80:0:0:0:1:2:3:4/64 scope global"
echo "   valid_lft 86400sec preferred_lft 14400sec"

echo "--- Test C3: febf:1:2:3:4:5:6:7 rejected ---"
assert_reject_as_lan_src "febf:1:2:3:4:5:6:7 (full)" \
    "inet6 febf:1:2:3:4:5:6:7/64 scope global"
echo "   valid_lft 86400sec preferred_lft 14400sec"

# ================================================================
# C2. is_link_local() / is_ula() numeric-range boundary tests
# ================================================================
# Direct unit tests against the simplified numeric-range helpers, covering
# the exact boundary values required by Phase 1C.
echo ""
echo "=== C2. is_link_local / is_ula numeric-range boundaries ==="

assert_is_link_local() {
    desc="$1"; addr="$2"; expected="$3"
    if is_link_local "$addr"; then result="YES"; else result="NO"; fi
    if [ "$result" = "$expected" ]; then
        PASS=$((PASS + 1)); echo "  PASS: $desc -> $result"
    else
        FAIL=$((FAIL + 1)); echo "  FAIL: $desc -> got $result, expected $expected"
    fi
}

assert_is_ula() {
    desc="$1"; addr="$2"; expected="$3"
    if is_ula "$addr"; then result="YES"; else result="NO"; fi
    if [ "$result" = "$expected" ]; then
        PASS=$((PASS + 1)); echo "  PASS: $desc -> $result"
    else
        FAIL=$((FAIL + 1)); echo "  FAIL: $desc -> got $result, expected $expected"
    fi
}

# Link-local fe80::/10 -> first hextet 0xfe80..0xfebf inclusive
assert_is_link_local "fe80::1 is link-local"            "fe80::1"             "YES"
assert_is_link_local "fe80:0:0:0:1:2:3:4 is link-local"  "fe80:0:0:0:1:2:3:4"  "YES"
assert_is_link_local "febf:1:2:3:4:5:6:7 is link-local"  "febf:1:2:3:4:5:6:7"  "YES"
assert_is_link_local "fec0::1 is NOT link-local"         "fec0::1"             "NO"

# ULA fc00::/7 -> first hextet 0xfc00..0xfdff inclusive
assert_is_ula "fc00::1 is ULA"  "fc00::1"  "YES"
assert_is_ula "fcff::1 is ULA"  "fcff::1"  "YES"
assert_is_ula "fd00::1 is ULA"  "fd00::1"  "YES"
assert_is_ula "fdff::1 is ULA"  "fdff::1"  "YES"
assert_is_ula "fe00::1 is NOT ULA" "fe00::1" "NO"

# ================================================================
# D. Stable-vs-temporary: temporary first, stable second
# ================================================================

echo ""
echo "=== D. Stable-vs-temporary (temporary first) ==="

echo "--- Test D1: temporary appears first, stable second -> stable wins ---"
assert_lan_pd_src_eq "temp-first stable-second" \
    "inet6 2001:db8:7e3:7700::1234/64 scope global temporary dynamic
   valid_lft 86400sec preferred_lft 14400sec
inet6 2001:db8:7e3:7700::1/64 scope global dynamic
   valid_lft 86400sec preferred_lft 14400sec" \
    "2001:db8:7e3:7700::1"

# ================================================================
# E. Stable-vs-temporary: reverse ordering (stable first, temporary second)
# ================================================================

echo ""
echo "=== E. Stable-vs-temporary (stable first) ==="

echo "--- Test E1: stable appears first, temporary second -> stable still wins ---"
assert_lan_pd_src_eq "stable-first temp-second" \
    "inet6 2001:db8:7e3:7700::1/64 scope global dynamic
   valid_lft 86400sec preferred_lft 14400sec
inet6 2001:db8:7e3:7700::1234/64 scope global temporary dynamic
   valid_lft 86400sec preferred_lft 14400sec" \
    "2001:db8:7e3:7700::1"

# ================================================================
# F. Deprecated/tentative/dadfailed never selected
# ================================================================

echo ""
echo "=== F. Deprecated/tentative/dadfailed exclusion ==="

echo "--- Test F1: deprecated stable address -> not selected (temp fallback) ---"
# Deprecated stable + healthy temporary: stable is skipped, temp is accepted.
assert_lan_pd_src_eq "deprecated-stable + healthy-temp -> temp" \
    "inet6 2001:db8:7e3:7700::1/64 scope global deprecated dynamic
   valid_lft 86400sec preferred_lft 0sec
inet6 2001:db8:7e3:7700::1234/64 scope global temporary dynamic
   valid_lft 86400sec preferred_lft 14400sec" \
    "2001:db8:7e3:7700::1234"

echo "--- Test F2: all candidates deprecated -> no source ---"
assert_reject_as_lan_src "all deprecated -> no source" \
    "inet6 2001:db8:7e3:7700::1/64 scope global deprecated dynamic
   valid_lft 86400sec preferred_lft 0sec"

echo "--- Test F3: tentative address -> not selected ---"
assert_reject_as_lan_src "tentative address only" \
    "inet6 2001:db8:7e3:7700::1/64 scope global tentative dynamic
   valid_lft 86400sec preferred_lft 14400sec"

echo "--- Test F4: dadfailed address -> not selected ---"
assert_reject_as_lan_src "dadfailed address only" \
    "inet6 2001:db8:7e3:7700::1/64 scope global dadfailed dynamic
   valid_lft 86400sec preferred_lft 14400sec"

# ================================================================
# G. LAN_PD_SRC has no CIDR suffix
# ================================================================

echo ""
echo "=== G. LAN_PD_SRC no CIDR suffix ==="

echo "--- Test G1: returned address is plain (no /64) ---"
RESULT_IP_OUTPUT="inet6 2001:db8:7e3:7700:abcd::1/64 scope global dynamic
   valid_lft 86400sec preferred_lft 14400sec"
assert_lan_pd_src_eq "plain address, no /64" "$RESULT_IP_OUTPUT" \
    "2001:db8:7e3:7700:abcd::1"

# ================================================================
# H. pd_internet_ok: -I receives plain LAN_PD_SRC
# ================================================================

echo ""
echo "=== H. pd_internet_ok source-bound ping ==="

STUB_DIR="$TEST_ROOT/stubs_ping"
mkdir -p "$STUB_DIR"
cat > "$STUB_DIR/ip" <<'EOF'
#!/bin/sh
echo "inet6 2001:db8:7e3:7700:abcd::1/64 scope global dynamic"
echo "   valid_lft 86400sec preferred_lft 14400sec"
exit 0
EOF
chmod +x "$STUB_DIR/ip"

PING6_LOG="$TEST_ROOT/ping6_args"
cat > "$STUB_DIR/ping6" <<EOF
#!/bin/sh
echo "\$@" >> "$PING6_LOG"
exit 0
EOF
chmod +x "$STUB_DIR/ping6"

LAN_DEV="br-lan"
PD_ADDR="2001:db8:7e3:7700::"
PD_MASK="56"
PD_CIDR="$PD_ADDR/$PD_MASK"
ORIG_PATH="$PATH"

LAN_PD_SRC=$(PATH="$STUB_DIR:$ORIG_PATH" get_lan_pd_src)
: > "$PING6_LOG"
PATH="$STUB_DIR:$ORIG_PATH" pd_internet_ok

IF_ARG=$(grep -oE '\-I [^ ]+' "$PING6_LOG" | head -1 | awk '{print $2}')
echo "  LAN_PD_SRC = '$LAN_PD_SRC'"
echo "  ping6 -I argument = '$IF_ARG'"
case "$IF_ARG" in
    */*)
        FAIL=$((FAIL + 1))
        echo "  FAIL: -I argument contains '/' -- invalid for ping6"
        ;;
    *)
        if [ -n "$IF_ARG" ]; then
            PASS=$((PASS + 1))
            echo "  PASS: -I argument is plain address, no slash"
        else
            FAIL=$((FAIL + 1))
            echo "  FAIL: no -I argument captured"
        fi
        ;;
esac

TARGET=$(awk '{print $NF}' "$PING6_LOG" | head -1)
case "$TARGET" in
    2001:4860:4860::8888|2606:4700:4700::1111)
        PASS=$((PASS + 1))
        echo "  PASS: target is a known public IPv6 address ($TARGET)"
        ;;
    *)
        FAIL=$((FAIL + 1))
        echo "  FAIL: unexpected target '$TARGET'"
        ;;
esac

# ================================================================
# N-U. Pending grace lifecycle via the PRODUCTION pending_state_tick
# ================================================================
#
# v3.10.0 Phase 1C: the pending-grace decision is no longer duplicated here.
# These tests invoke the actual production pending_state_tick() and
# pending_state_reset() extracted from ipv6-watchdog. The harness only
# manages the state files (WAN6_PENDING_SEEN_FILE,
# WAN6_PENDING_EXPIRED_FILE) and inspects the helper's return code and
# the PENDING_LOG. The production helper never calls ifdown/ifup.
# ================================================================

echo ""
echo "=== N-U. Pending grace lifecycle (production helper) ==="

# Reset state before each scenario. Helper: count lines in PENDING_LOG.
reset_pending_state() {
    pending_state_reset
    : > "$PENDING_LOG"
}
log_lines() { wc -l < "$PENDING_LOG" | tr -d ' '; }
log_contains() { grep -q "$1" "$PENDING_LOG"; }

# --- Test 1: first pending at t=1000 -- timestamp created, one log, passive

echo "--- Test 1: first pending at t=1000 -- passive wait, one first-pending log ---"
reset_pending_state
pending_state_tick true 1000
rc=$?
if [ "$rc" = "0" ]; then
    PASS=$((PASS + 1)); echo "  PASS: returned 0 (passive wait)"
else
    FAIL=$((FAIL + 1)); echo "  FAIL: expected rc=0, got rc=$rc"
fi
if [ -s "$WAN6_PENDING_SEEN_FILE" ] && [ "$(cat "$WAN6_PENDING_SEEN_FILE")" = "1000" ]; then
    PASS=$((PASS + 1)); echo "  PASS: timestamp created with 1000"
else
    FAIL=$((FAIL + 1)); echo "  FAIL: timestamp not 1000 (got '$(cat "$WAN6_PENDING_SEEN_FILE" 2>/dev/null)')"
fi
if [ "$(log_lines)" = "1" ] && log_contains "wan6 is pending"; then
    PASS=$((PASS + 1)); echo "  PASS: exactly one first-pending log"
else
    FAIL=$((FAIL + 1)); echo "  FAIL: expected one pending log, got $(log_lines) lines"
fi

# --- Test 2: same pending at t=1100 -- passive, no repeated log

echo "--- Test 2: same pending at t=1100 -- passive wait, no repeated log ---"
: > "$PENDING_LOG"
pending_state_tick true 1100
rc=$?
if [ "$rc" = "0" ]; then
    PASS=$((PASS + 1)); echo "  PASS: returned 0 (passive wait)"
else
    FAIL=$((FAIL + 1)); echo "  FAIL: expected rc=0, got rc=$rc"
fi
if [ "$(log_lines)" = "0" ]; then
    PASS=$((PASS + 1)); echo "  PASS: no repeated log"
else
    FAIL=$((FAIL + 1)); echo "  FAIL: expected no log, got $(log_lines) lines"; cat "$PENDING_LOG"
fi
if [ "$(cat "$WAN6_PENDING_SEEN_FILE")" = "1000" ]; then
    PASS=$((PASS + 1)); echo "  PASS: original timestamp preserved (1000)"
else
    FAIL=$((FAIL + 1)); echo "  FAIL: timestamp changed (got '$(cat "$WAN6_PENDING_SEEN_FILE" 2>/dev/null)')"
fi

# --- Test 3: same pending at t=1180 -- grace expired, one expiry log, recovery allowed

echo "--- Test 3: same pending at t=1180 -- grace expired, recovery allowed ---"
: > "$PENDING_LOG"
pending_state_tick true 1180
rc=$?
if [ "$rc" = "1" ]; then
    PASS=$((PASS + 1)); echo "  PASS: returned 1 (recovery allowed)"
else
    FAIL=$((FAIL + 1)); echo "  FAIL: expected rc=1, got rc=$rc"
fi
if [ "$(log_lines)" = "1" ] && log_contains "pending grace expired"; then
    PASS=$((PASS + 1)); echo "  PASS: exactly one grace-expired log"
else
    FAIL=$((FAIL + 1)); echo "  FAIL: expected one expiry log, got $(log_lines) lines"; cat "$PENDING_LOG"
fi
if [ -f "$WAN6_PENDING_EXPIRED_FILE" ]; then
    PASS=$((PASS + 1)); echo "  PASS: expiry marker written"
else
    FAIL=$((FAIL + 1)); echo "  FAIL: expiry marker not written"
fi
if [ "$(cat "$WAN6_PENDING_SEEN_FILE")" = "1000" ]; then
    PASS=$((PASS + 1)); echo "  PASS: original timestamp preserved (not reset on expiry)"
else
    FAIL=$((FAIL + 1)); echo "  FAIL: timestamp reset on expiry (got '$(cat "$WAN6_PENDING_SEEN_FILE" 2>/dev/null)')"
fi

# --- Test 4: same acquisition at t=1200, no restart occurred -- still expired, no fresh grace, no repeated logs

echo "--- Test 4: same acquisition at t=1200, no restart -- still expired, no fresh grace ---"
: > "$PENDING_LOG"
pending_state_tick true 1200
rc=$?
if [ "$rc" = "1" ]; then
    PASS=$((PASS + 1)); echo "  PASS: returned 1 (recovery remains allowed)"
else
    FAIL=$((FAIL + 1)); echo "  FAIL: expected rc=1, got rc=$rc"
fi
if [ "$(log_lines)" = "0" ]; then
    PASS=$((PASS + 1)); echo "  PASS: no repeated first-pending log"
else
    FAIL=$((FAIL + 1)); echo "  FAIL: expected no log, got $(log_lines) lines"; cat "$PENDING_LOG"
fi
if [ ! -s "$WAN6_PENDING_SEEN_FILE" ] || [ "$(cat "$WAN6_PENDING_SEEN_FILE")" = "1000" ]; then
    if [ "$(cat "$WAN6_PENDING_SEEN_FILE" 2>/dev/null)" = "1000" ]; then
        PASS=$((PASS + 1)); echo "  PASS: original timestamp unchanged (no fresh grace)"
    else
        FAIL=$((FAIL + 1)); echo "  FAIL: timestamp unexpectedly absent or changed"
    fi
else
    FAIL=$((FAIL + 1)); echo "  FAIL: timestamp changed (got '$(cat "$WAN6_PENDING_SEEN_FILE" 2>/dev/null)') -- fresh grace granted"
fi
if [ -f "$WAN6_PENDING_EXPIRED_FILE" ]; then
    PASS=$((PASS + 1)); echo "  PASS: expiry marker still present (no fresh grace)"
else
    FAIL=$((FAIL + 1)); echo "  FAIL: expiry marker disappeared"
fi

# --- Test 5: Tier 0 actually starts a new acquisition -- old state removed

echo "--- Test 5: production pending_state_reset removes old state ---"
pending_state_reset
if [ ! -f "$WAN6_PENDING_SEEN_FILE" ]; then
    PASS=$((PASS + 1)); echo "  PASS: timestamp file removed"
else
    FAIL=$((FAIL + 1)); echo "  FAIL: timestamp file survived reset"
fi
if [ ! -f "$WAN6_PENDING_EXPIRED_FILE" ]; then
    PASS=$((PASS + 1)); echo "  PASS: expiry marker removed"
else
    FAIL=$((FAIL + 1)); echo "  FAIL: expiry marker survived reset"
fi

# --- Test 6: new odhcp6c pending at t=1210 -- fresh timestamp, one first-pending log, full grace

echo "--- Test 6: new pending at t=1210 -- fresh timestamp and full grace ---"
: > "$PENDING_LOG"
pending_state_tick true 1210
rc=$?
if [ "$rc" = "0" ]; then
    PASS=$((PASS + 1)); echo "  PASS: returned 0 (passive wait)"
else
    FAIL=$((FAIL + 1)); echo "  FAIL: expected rc=0, got rc=$rc"
fi
if [ -s "$WAN6_PENDING_SEEN_FILE" ] && [ "$(cat "$WAN6_PENDING_SEEN_FILE")" = "1210" ]; then
    PASS=$((PASS + 1)); echo "  PASS: fresh timestamp created (1210)"
else
    FAIL=$((FAIL + 1)); echo "  FAIL: fresh timestamp not 1210 (got '$(cat "$WAN6_PENDING_SEEN_FILE" 2>/dev/null)')"
fi
if [ "$(log_lines)" = "1" ] && log_contains "wan6 is pending"; then
    PASS=$((PASS + 1)); echo "  PASS: exactly one fresh first-pending log"
else
    FAIL=$((FAIL + 1)); echo "  FAIL: expected one pending log, got $(log_lines) lines"
fi
if [ ! -f "$WAN6_PENDING_EXPIRED_FILE" ]; then
    PASS=$((PASS + 1)); echo "  PASS: no stale expiry marker"
else
    FAIL=$((FAIL + 1)); echo "  FAIL: stale expiry marker present"
fi
# Verify full fresh grace: at t=1389 (179s later), still below grace.
_pending_seen=$(cat "$WAN6_PENDING_SEEN_FILE")
_elapsed_at_1389=$((1389 - _pending_seen))
if [ "$_elapsed_at_1389" -lt "$WAN6_PENDING_GRACE" ]; then
    PASS=$((PASS + 1)); echo "  PASS: at t=1389, still within fresh grace (elapsed=${_elapsed_at_1389}s)"
else
    FAIL=$((FAIL + 1)); echo "  FAIL: at t=1389, grace already expired (elapsed=${_elapsed_at_1389}s) -- old state leaked"
fi

# --- Test 7: wan6 becomes up -- pending state cleared

echo "--- Test 7: wan6 becomes up -- pending state cleared ---"
# First establish pending state.
reset_pending_state
pending_state_tick true 1300 >/dev/null 2>&1
[ -s "$WAN6_PENDING_SEEN_FILE" ] || { FAIL=$((FAIL + 1)); echo "  FAIL: setup did not create timestamp"; }
# wan6 up -> pending=false. The helper returns 2 (not pending); caller clears.
: > "$PENDING_LOG"
pending_state_tick false 1310
rc=$?
if [ "$rc" = "2" ]; then
    PASS=$((PASS + 1)); echo "  PASS: returned 2 (not pending)"
else
    FAIL=$((FAIL + 1)); echo "  FAIL: expected rc=2, got rc=$rc"
fi
pending_state_reset
if [ ! -f "$WAN6_PENDING_SEEN_FILE" ] && [ ! -f "$WAN6_PENDING_EXPIRED_FILE" ]; then
    PASS=$((PASS + 1)); echo "  PASS: pending state cleared on wan6 up"
else
    FAIL=$((FAIL + 1)); echo "  FAIL: pending state survived wan6 up"
fi

# --- Test 8: pending=false -- pending state cleared

echo "--- Test 8: pending=false -- pending state cleared ---"
# First establish pending state, then expire grace.
reset_pending_state
pending_state_tick true 1400 >/dev/null 2>&1
pending_state_tick true 1600 >/dev/null 2>&1
[ -f "$WAN6_PENDING_EXPIRED_FILE" ] || { FAIL=$((FAIL + 1)); echo "  FAIL: setup did not create expiry marker"; }
# pending=false -> helper returns 2; caller clears.
pending_state_tick false 1610
rc=$?
if [ "$rc" = "2" ]; then
    PASS=$((PASS + 1)); echo "  PASS: returned 2 (not pending)"
else
    FAIL=$((FAIL + 1)); echo "  FAIL: expected rc=2, got rc=$rc"
fi
pending_state_reset
if [ ! -f "$WAN6_PENDING_SEEN_FILE" ] && [ ! -f "$WAN6_PENDING_EXPIRED_FILE" ]; then
    PASS=$((PASS + 1)); echo "  PASS: pending state cleared on pending=false"
else
    FAIL=$((FAIL + 1)); echo "  FAIL: pending state survived pending=false"
fi

# ================================================================
# SUMMARY
# ================================================================

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