# IPv6 Fix Guide: GL.iNet GL-MT6000 (Flint 2) on PLDT Fiber (Bridge Mode)

[![OpenWrt](https://img.shields.io/badge/OpenWrt-25.x-blue)](#)
[![ISP](https://img.shields.io/badge/ISP-PLDT%20Fiber-informational)](#)
[![Status](https://img.shields.io/badge/Status-Production--Ready-success)](#)

**Device:** GL.iNet GL-MT6000 (Flint 2) | **Firmware:** OpenWrt 25.12.2 (vanilla OpenWrt) | **ISP:** PLDT Fiber (Bridge mode) | **WAN:** `eth1` | **Mode:** DHCPv6 + Prefix Delegation

A production-grade, self-healing IPv6 setup for PLDT Fiber subscribers running OpenWrt in bridge mode.
Includes root-cause analysis, startup fixes, runtime recovery, and real-world edge cases observed in production use.

---

## Table of Contents

- [Quick Deploy](#quick-deploy)
- [Compatibility](#compatibility)
- [Caution: Bridge Mode and Third-Party Router Setups](#caution-bridge-mode-and-third-party-router-setups)
- [Root Causes](#root-causes)
- [Fix Architecture](#fix-architecture)
- [Step 1 - UCI Config](#step-1---uci-config)
- [Step 2 - wan6 Startup Delay](#step-2---wan6-startup-delay)
- [Step 3 - IPv6 Route Fix Engine](#step-3---ipv6-route-fix-engine)
- [Step 4 - IPv6 Watchdog](#step-4---ipv6-watchdog)
- [Step 5 - Cron Setup](#step-5---cron-setup)
- [Troubleshooting and Debug Commands](#troubleshooting-and-debug-commands)
- [Validated Behavior](#validated-behavior)
- [Final Result](#final-result)
- [Preserving Scripts Across Firmware Upgrades](#preserving-scripts-across-firmware-upgrades)
- [Known Edge Cases](#known-edge-cases)
- [Advanced Notes: DUID and ULA](#advanced-notes-duid-and-ula)
- [Disclaimer](#disclaimer)

---

## Quick Deploy

Apply in this order, then reboot:

1. Apply UCI config
2. Create `/etc/hotplug.d/iface/98-wan6-delay`
3. Create `/etc/hotplug.d/iface/99-ipv6-setup`
4. Create `/usr/bin/ipv6-watchdog`
5. Add cron job and restart cron
6. Reboot

Test after reboot:

```sh
ping6 2001:4860:4860::8888
```

Check logs:

```sh
logread | grep ipv6-setup
logread | grep ipv6-watchdog
```

---

## Compatibility

Tested on:
- PLDT Fiber in bridge mode
- OpenWrt 25.12.2 (vanilla OpenWrt, not GL.iNet stock firmware)
- GL.iNet GL-MT6000 (Flint 2)

![Network Topology](diagram-network-topology.svg)

May work on:
- Other ISPs with similar IA_NA + RA gateway issues (common with CGNAT providers)

Not designed for:
- Double NAT setups where OpenWrt is not the first hop
- Non-OpenWrt firmware

Expected to work on:
- OpenWrt 24.x and newer (fw4-based builds)

This was tested on OpenWrt 25.12.2 only. Older builds, custom images, and non-default environments may behave differently.

Core components used by the scripts:

- `odhcp6c` - DHCPv6 client (critical for prefix delegation)
- `netifd` - network interface management and hotplug system
- `busybox` - shell environment (`awk`, `grep`, `seq`, etc.)
- `ip` - IPv6 routing and neighbor commands
- `ubus` and `jsonfilter` - interface status and prefix detection
- `ping6` - connectivity checks

These are included in standard OpenWrt builds but may be missing in minimal or custom images. Tested on the default OpenWrt image with no additional packages required.

Troubleshooting commands assume standard OpenWrt CLI tools are available.

---

## Caution: Bridge Mode and Third-Party Router Setups

This guide assumes your ONT/modem is in **bridge mode**, passing the session directly to your OpenWrt router as the edge device.

If you have a **third-party router behind the main OpenWrt router** (double NAT), be aware:

- IPv6 prefix delegation (`IA_PD`) may not pass cleanly downstream
- The hotplug scripts must run on whichever device holds the actual WAN interface
- If your ISP assigns a `/128` via `IA_NA` and your router is not the edge device, the `/128` fix still applies on that edge device
- PLDT ONT firmware quirks can cause link-local addresses to flap, making the race condition in Step 2 more likely to trigger

---

## Root Causes

### Primary root cause

**Broken /128 WAN address (IA_NA)**

The ISP assigns a `/128` WAN address via IA_NA alongside the delegated `/56` prefix. OpenWrt prefers the `/128` as the source address for all outbound traffic. PLDT silently drops packets using it as the source address. Removing the `/128` immediately restores connectivity.

This is the dominant failure. Everything else amplifies or destabilizes it.

![Failure Points](diagram-failure-points.svg)

### Secondary issues

**2. Multiple RA gateways, wrong one selected.** The ISP advertises two gateways via Router Advertisement. OpenWrt selects the first, which is dead. Neighbor table shows `INCOMPLETE` state.

**3. `wan6` startup race condition.** `wan6` starts before the link-local address is ready on `eth1`, causing DHCPv6 to fail inconsistently after reboots.

**4. RA runtime override.** Even after fixing the route at boot, the dead gateway returns via a later RA and silently breaks connectivity again.

**5. Incorrect RA tuning.** Using `accept_ra='2'` with `defaultroute='0'` removes the fallback behavior `wan6` needs during initialization, causing complete IPv6 failure on every boot.

> **Warning:** Do not use `accept_ra='2'` with `defaultroute='0'`. This breaks `wan6` initialization and removes fallback routing, causing complete IPv6 failure on boot.

---

## Fix Architecture

**Startup flow:**

```
WAN up -> delay (5s) -> wan6 starts -> prefix acquired -> route fix engine runs
```

**Runtime flow:**

```
Watchdog (every 5 min) -> check connectivity -> fix route -> restart WAN only if needed
```

**Layers:**

| Layer | File | Purpose |
|---|---|---|
| A - UCI config | `network` UCI | Disables `/128`, stabilizes RA, delegates prefix |
| B - Delay script | `98-wan6-delay` | Fixes link-local race condition at boot |
| C - Route engine | `99-ipv6-setup` | Selects working gateway at startup |
| D - Watchdog | `ipv6-watchdog` | Self-heals runtime route overrides every 5 min |

![Boot Sequence](diagram-boot-sequence.svg)

---

## Step 1 - UCI Config

Apply this first. Everything else depends on it.

```sh
uci set network.wan6.reqaddress='none'
uci set network.wan6.reqprefix='56'
uci delete network.wan6.norelease
uci delete network.wan6.ip6assign
uci set network.wan6.device='eth1'
uci set network.wan6.accept_ra='1'

uci set network.lan.ip6assign='64'
uci set network.lan.ip6class='wan6'

uci commit network
```

What each setting does:

| Setting | Value | Why |
|---|---|---|
| `reqaddress` | `none` | Prevents ISP from assigning a broken `/128` WAN address |
| `reqprefix` | `56` | Explicitly requests the delegated `/56` block |
| `accept_ra` | `1` | Keeps RA processing on so `wan6` initializes correctly |
| `ip6assign` | `64` | LAN gets a `/64` from the delegated prefix |
| `ip6class` | `wan6` | Binds LAN prefix delegation to the `wan6` interface |

---

## Step 2 - wan6 Startup Delay

**File:** `/etc/hotplug.d/iface/98-wan6-delay`

Waits for WAN to be fully ready before starting `wan6`, eliminating the link-local race condition.

```sh
#!/bin/sh
[ "$ACTION" = "ifup" ] || exit 0
[ "$INTERFACE" = "wan" ] || exit 0

sleep 5
ifup wan6
```

```sh
chmod +x /etc/hotplug.d/iface/98-wan6-delay
```

---

## Step 3 - IPv6 Route Fix Engine

**File:** `/etc/hotplug.d/iface/99-ipv6-setup`

Runs whenever `wan6` comes up. Detects the working gateway via NDP, enforces the correct default route, and removes any stale `/128` addresses after confirming connectivity.

```sh
#!/bin/sh
[ "$ACTION" = "ifup" ] || exit 0
[ "$INTERFACE" = "wan6" ] || exit 0

LOGTAG="ipv6-setup"
log() { logger -t "$LOGTAG" "$1"; }

WAN_DEV=$(ubus call network.interface.wan6 status 2>/dev/null \
    | jsonfilter -e '@["l3_device"]')

[ -z "$WAN_DEV" ] && { log "ERROR: no WAN device"; exit 1; }

# Wait for link-local
for i in $(seq 1 10); do
    lla=$(ip -6 addr show dev "$WAN_DEV" | awk '/fe80.*scope link/{print $2}')
    [ -n "$lla" ] && break
    sleep 2
done

# Wait for prefix
for i in $(seq 1 15); do
    PREFIX=$(ubus call network.interface.wan6 status 2>/dev/null \
        | jsonfilter -e '@["ipv6-prefix"][0].address')
    [ -n "$PREFIX" ] && break
    sleep 3
done

# Trigger NDP discovery
ping6 -c 3 -W 1 -I "$WAN_DEV" ff02::2 >/dev/null 2>&1
sleep 3

BEST_GW=""

for gw in $(ip -6 neigh show dev "$WAN_DEV" | awk '/router/{print $1}' | sort -u); do
    ping6 -c 2 -W 2 -I "$WAN_DEV" "$gw" >/dev/null 2>&1 || continue
    BEST_GW="$gw"
    break
done

[ -z "$BEST_GW" ] && {
    log "No gateway found, restarting WAN"
    ifdown wan6; ifdown wan
    sleep 20
    ifup wan; sleep 40; ifup wan6
    exit 0
}

# Replace dead routes with working one
ip -6 route show default dev "$WAN_DEV" | awk '{print $3}' \
| while read old; do
    [ "$old" = "$BEST_GW" ] || ip -6 route del default via "$old" dev "$WAN_DEV"
done

ip -6 route replace default via "$BEST_GW" dev "$WAN_DEV" metric 512

# Verify connectivity and remove /128 if successful
sleep 3
if ping6 -c 2 2001:4860:4860::8888 >/dev/null 2>&1; then
    ip -6 addr show dev "$WAN_DEV" | awk '/\/128 scope global/{print $2}' \
    | while read addr; do
        ip -6 addr del "$addr" dev "$WAN_DEV"
    done
fi
```

```sh
chmod +x /etc/hotplug.d/iface/99-ipv6-setup
```

---

## Step 4 - IPv6 Watchdog

**File:** `/usr/bin/ipv6-watchdog`

Runs every 5 minutes via cron. Checks connectivity against Google and Cloudflare IPv6, fixes the route if broken, and restarts the full WAN stack only after 3 consecutive failures.

```sh
#!/bin/sh
LOGTAG="ipv6-watchdog"
STATE_DIR="/tmp/ipv6-watchdog"
mkdir -p "$STATE_DIR"

log() { logger -t "$LOGTAG" "$1"; }

WAN_DEV=$(ubus call network.interface.wan6 status 2>/dev/null \
    | jsonfilter -e '@["l3_device"]')

ipv6_ok() {
    ping6 -c 2 -W 3 2001:4860:4860::8888 >/dev/null 2>&1 && return 0
    ping6 -c 2 -W 3 2606:4700:4700::1111 >/dev/null 2>&1 && return 0
    return 1
}

has_prefix() {
    ubus call network.interface.wan6 status 2>/dev/null \
    | jsonfilter -e '@["ipv6-prefix"][0].address' | grep -q .
}

fix_gateway() {
    current=$(ip -6 route show default dev "$WAN_DEV" | awk 'NR==1{print $3}')
    ping6 -c 2 -W 2 -I "$WAN_DEV" "$current" >/dev/null 2>&1 && return 1

    for gw in $(ip -6 neigh show dev "$WAN_DEV" | awk '/router/{print $1}'); do
        ping6 -c 2 -W 2 -I "$WAN_DEV" "$gw" >/dev/null 2>&1 || continue
        ip -6 route replace default via "$gw" dev "$WAN_DEV" metric 512
        return 0
    done
    return 1
}

FAIL_FILE="$STATE_DIR/fail_count"
FAILS=$(cat "$FAIL_FILE" 2>/dev/null || echo 0)

if ipv6_ok; then
    echo 0 > "$FAIL_FILE"
    exit 0
fi

if ! has_prefix; then
    log "No prefix found, restarting wan6"
    ifdown wan6; sleep 10; ifup wan6
    exit 0
fi

if fix_gateway; then
    sleep 5
    ipv6_ok && { echo 0 > "$FAIL_FILE"; exit 0; }
fi

FAILS=$((FAILS+1))
echo "$FAILS" > "$FAIL_FILE"

if [ "$FAILS" -ge 3 ]; then
    log "3 consecutive failures, restarting WAN stack"
    ifdown wan6; ifdown wan
    sleep 30
    ifup wan; sleep 20; ifup wan6
    echo 0 > "$FAIL_FILE"
fi
```

```sh
chmod +x /usr/bin/ipv6-watchdog
```

---

## Step 5 - Cron Setup

**File:** `/etc/crontabs/root`

Add the watchdog (idempotent, safe to run multiple times):

```sh
grep -qxF '*/5 * * * * /usr/bin/ipv6-watchdog' /etc/crontabs/root || \
echo '*/5 * * * * /usr/bin/ipv6-watchdog' >> /etc/crontabs/root

/etc/init.d/cron restart
```

---

## Troubleshooting and Debug Commands

### ICMPv6 and firewall

This guide assumes the default OpenWrt `fw4` firewall configuration. Custom firewall rules may affect IPv6 behavior.

IPv6 requires ICMPv6 to function. If you use custom firewall rules that block ICMPv6, Neighbor Discovery, Router Advertisements, and prefix-related behavior may fail regardless of this fix.

This is only relevant if you have modified the default firewall rules.

---

Check current IPv6 state:

```sh
ip -6 addr show dev eth1
ip -6 route
ip -6 neigh
ubus call network.interface.wan6 status
```

Check script logs:

```sh
logread | grep ipv6-setup
logread | grep ipv6-watchdog
```

Manual gateway probe:

```sh
ip -6 neigh show dev eth1 | grep router
ping6 -c 3 -I eth1 <gateway-address>
```

Force route fix without rebooting:

```sh
# Must be run as root - simulates a hotplug ifup event on wan6
ACTION=ifup INTERFACE=wan6 /etc/hotplug.d/iface/99-ipv6-setup
```

Manually replace default route:

```sh
ip -6 route replace default via <working-gateway> dev eth1 metric 512
ping6 -c 3 2001:4860:4860::8888
```

---

## Validated Behavior

Confirmed during real-world testing:

- Hotplug correctly selects the working gateway on each boot
- Dead gateway occasionally returns via RA - watchdog catches and replaces it within 5 minutes
- ONT power cycling (technician visit) handled cleanly - wan6 recovered automatically without intervention
- Manual `ip -6 route replace` restores IPv6 instantly, confirming the issue is route selection, not prefix delegation
- `accept_ra='2'` + `defaultroute='0'` is confirmed unstable for this ISP

---

## Final Result

| Issue | Fix | Status |
|---|---|---|
| Broken `/128` WAN address used as source | `reqaddress='none'` | Fixed |
| Dead gateway selected at startup | Route fix engine via hotplug | Fixed |
| Stable prefix delegation | `reqprefix='56'` + RA enabled | Fixed |
| Dead gateway returns via RA at runtime | Watchdog + cron every 5 min | Fixed |
| Race condition on boot | `98-wan6-delay` script | Fixed |

---

## Preserving Scripts Across Firmware Upgrades

Add all scripts to the sysupgrade preserve list so they survive firmware flashes:

```sh
cat >> /etc/sysupgrade.conf << 'EOF'
/etc/hotplug.d/iface/98-wan6-delay
/etc/hotplug.d/iface/99-ipv6-setup
/usr/bin/ipv6-watchdog
/etc/crontabs/root
/etc/sysctl.conf
EOF
```

Then generate a backup via LuCI: **System -> Backup / Flash Firmware -> Generate archive**.

---

## Known Edge Cases

These are real-world scenarios observed during testing with PLDT and OpenWrt. They are not part of normal operation but may occur under unstable ISP or initialization conditions.

---

### 1. wan6 fails to come up after reboot (no prefix acquired)

In rare cases, `wan6` may fail to initialize properly with `reqaddress='none'`. This is effectively a manual workaround for a startup race condition that the hotplug delay does not always resolve.

Symptoms:
- `wan6` shows `up: false` or stuck state
- No IPv6 prefix assigned
- Watchdog cannot recover it

**Phase 1 - temporarily allow /128 to force DHCPv6 initialization:**

```sh
uci set network.wan6.reqaddress='try'
uci commit network
ifdown wan6; sleep 5; ifup wan6
```

Wait for `wan6` to come up:

```sh
ubus call network.interface.wan6 status | jsonfilter -e '@["up"]'
```

You should see `true` with a prefix assigned.

**Phase 2 - remove /128 and restore correct config:**

```sh
ip -6 addr show dev eth1 | awk '/\/128 scope global/{print $2}' \
| while read addr; do ip -6 addr del "$addr" dev eth1; done

uci set network.wan6.reqaddress='none'
uci commit network
```

Why this works: `reqaddress='try'` allows IA_NA, forcing DHCPv6 to fully initialize. Once the interface is active, prefix delegation stabilizes. The `/128` is then removed to prevent the routing issue caused by ISP behavior.

This is a manual recovery procedure only. The hotplug and watchdog scripts handle standard failures automatically.

If `wan6` comes up but no prefix is assigned, see Edge Case 6 (`NoPrefixAvail`).

---

### 2. IPv6 works initially, then stops after some time

Symptoms:
- IPv6 works after reboot
- Stops working 1-10 minutes later
- Prefix still exists

Cause: ISP Router Advertisement reintroduces a dead default gateway at runtime.

Resolution: Automatically handled by `ipv6-watchdog` every 5 minutes. Manual fix:

```sh
ip -6 route replace default via <working-gateway> dev eth1 metric 512
```

---

### 3. Multiple IPv6 gateways observed on WAN

Symptoms:
- `ip -6 neigh show dev eth1` shows multiple routers
- One is unreachable (`INCOMPLETE` state)

Cause: ISP advertises multiple gateways via RA, not all functional.

Resolution: Automatically handled by `99-ipv6-setup` hotplug at startup. No manual action required.

---

### 4. IPv6 temporarily fails after ONT reset or line disturbance

Symptoms:
- Both IPv4 and IPv6 drop briefly
- WAN reconnects but IPv6 behaves inconsistently

Cause: Physical link flap resets DHCPv6 and RA state.

Resolution: Automatically recovered by `98-wan6-delay` (startup timing) and `ipv6-watchdog` (runtime correction).

---

### 5. Browser shows "IPv6 available but not used"

Symptoms:
- Test sites warn that IPv6 is being avoided by the browser

Cause: Browser Happy Eyeballs algorithm temporarily prefers IPv4, or a cached failed IPv6 attempt.

Resolution: Refresh or restart the browser. No router-side issue.

---

### 6. IA_PD NoPrefixAvail error (no IPv6 prefix assigned)

Example log entry:

```
odhcp6c[xxxx]: Server returned IA_PD status 'No Prefix Available (NoPrefixAvail)'
```

Symptoms:
- `wan6` may appear up
- No IPv6 prefix assigned
- LAN has no IPv6 connectivity
- Watchdog repeatedly restarts `wan6`

Cause: ISP DHCPv6 server refused to assign a prefix. Common reasons:
- Stale lease on ISP side from previous session
- Prefix pool exhaustion on PLDT's network
- Session not fully released after fast reconnect

**This is not a router misconfiguration. This is an ISP-side issue.**

If `wan6` itself fails to come up or stays stuck rather than coming up with no prefix, see Edge Case 1 instead.

Automatic handling: `ipv6-watchdog` will retry `wan6` and escalate to full WAN restart after repeated failures. However it cannot force the ISP to release a stale lease.

Manual recovery if persistent:

1. Turn off ONT
2. Wait 10-15 minutes
3. Turn ONT back on

This forces the ISP to release the previous prefix allocation. Avoid rapid WAN restarts during this condition as fast reconnects may worsen it.

> **Note:** In rare cases on certain OpenWrt builds, prefix delegation may fail due to firmware-level issues rather than ISP behavior. This can present similarly but may not be resolved by ONT power cycling. See [OpenWrt issue #22309](https://github.com/openwrt/openwrt/issues/22309) for reference.

---

## Advanced Notes: DUID and ULA

This section is informational only and not required for the core setup.

### DUID (DHCPv6 Unique Identifier)

OpenWrt automatically generates a DUID and PLDT accepts it without issues. No manual configuration is needed for this setup.

However, in some environments a persistent or custom DUID may be required, particularly if the ISP assigns inconsistent prefixes or sessions across reconnects.

In some cases, resetting the default DUID after flashing may help clear stale ISP leases and restore prefix delegation. This setup uses the default auto-generated DUID, which works reliably with PLDT in testing.

**OpenWrt 25.12 DUID change:** OpenWrt 25.12 changed the default DUID type from DUID-LL (Type 3, MAC-based) to DUID-UUID (Type 4, random). The new DUID-UUID is persistent across reboots and sysupgrades when settings are kept. On a fresh flash with no settings preserved, a new random DUID is generated on first boot. Some ISPs that expect a MAC-based DUID may not immediately update the lease. In those cases, the old lease may need to expire first, or a manual DUID override may be required.

In rare cases, a DUID change may result in loss of prefix delegation or delayed assignment until the ISP releases the previous lease. This presents as `wan6` up but no prefix assigned, similar to Edge Case 6 (`NoPrefixAvail`).

### ULA (Unique Local Address)

Not used in this setup. All LAN IPv6 addressing comes from the ISP-delegated prefix (`/56 → /64`).

Removing ULA means LAN IPv6 depends entirely on ISP prefix delegation. If the WAN drops, LAN devices lose their IPv6 addresses. This is intentional for a clean, global-only setup.

**With ULA enabled:** devices have stable internal IPv6 (e.g. `fdxx::/48`) independent of the ISP. Internal services remain reachable even if WAN IPv6 is down. Useful for homelabs, servers, and segmented networks.

**Without ULA (this guide):** devices use only ISP-provided global IPv6. Addresses may change if the prefix changes. Simpler, cleaner setup focused on fixing ISP routing issues.

ULA may be useful if:
- You want stable internal IPv6 independent of the ISP prefix
- LAN devices must keep IPv6 addresses even during WAN outages
- You run internal services that must not depend on WAN prefix availability
- You use multi-router or segmented networks

> **Note:** This guide was tested without ULA. Enabling ULA should not affect the WAN-side routing fixes, but this combination was not explicitly validated.

### Summary

| Feature | Used in this setup | Required |
|---|---|---|
| DUID | Auto-generated by OpenWrt | No |
| ULA | Not used | No |

This guide focuses on ISP-provided global IPv6 with self-healing routing. The design philosophy is to fix ISP behavior dynamically rather than compensate with alternate addressing schemes.

---

## Disclaimer

This guide is provided as-is based on real-world testing on a specific setup. Results may vary depending on your ISP configuration, firmware version, or hardware.

Always back up your router configuration before making changes.
