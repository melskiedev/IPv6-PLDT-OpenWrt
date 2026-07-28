# IPv6 Fix Guide: GL.iNet GL-MT6000 (Flint 2) on PLDT Fiber (Bridge Mode)

[![OpenWrt](https://img.shields.io/badge/OpenWrt-25.x-blue)](#)
[![ISP](https://img.shields.io/badge/ISP-PLDT%20Fiber-informational)](#)
[![Status](https://img.shields.io/badge/Status-Production--Ready-success)](#)
[![Release](https://img.shields.io/badge/Release-v3.9.8-blue)](#)

**Device:** GL.iNet GL-MT6000 (Flint 2) | **Firmware:** OpenWrt 25.12.2 (vanilla OpenWrt) | **ISP:** PLDT Fiber (Bridge mode) | **WAN:** `eth1` | **Mode:** DHCPv6 + Prefix Delegation | **Current repo release:** v3.9.8 | **Components:** `ipv6-watchdog` v3.9.9 (unreleased, planned), `ipv6-discord-logger` v3.9.6

A production-grade, self-healing IPv6 setup for PLDT Fiber subscribers running OpenWrt in bridge mode.
Includes root-cause analysis, startup fixes, runtime recovery, escalating failure handling, and real-world edge cases observed in production use.

> **Personal use, shared openly.** This is my own home network fix that I'm sharing in case it helps someone else. I run this on my own routers daily. Use it at your own risk, adapt it as needed, and always take a sysupgrade backup before applying anything.

---

## TL;DR

PLDT Fiber, bridge mode, IPv6 broken: apply UCI config, deploy the scripts (`98-wan6-delay`, `99-ipv6-setup`, `ipv6-watchdog`, `ipv6-prefix-tracker`, `97-garp`), add cron, reboot, verify with `ping6 2001:4860:4860::8888`. The watchdog self-heals runtime failures; the prefix tracker logs prefix initialization and changes, refreshes odhcpd on change, and suppresses no-prefix spam during recovery hold. Full instructions below.

---

## Read Before Applying

> **This is not a generic IPv6 guide.** It targets a specific failure pattern observed on PLDT Fiber in bridge mode. Applying it to a different setup may break working IPv6.

Use this guide only if:

- You are on PLDT Fiber (or an ISP with similar IA_NA + RA behavior)
- Your ONT is in bridge mode and OpenWrt is the first-hop edge router
- You observe broken `/128` WAN address behavior, incorrect RA gateway selection, or intermittent IPv6 loss after boot

**Assumptions:**

- WAN interface is `eth1` (verify with `ip link` before applying)
- Default `fw4` firewall configuration, no custom ICMPv6 rules
- DHCPv6 with prefix delegation, not PPPoE
- Single-router setup, no cascaded routers or double NAT

**This guide is not designed for:**

- PPPoE WAN
- VLAN-tagged WAN interfaces
- Double NAT setups where OpenWrt is not the edge device
- Non-standard interface naming

All timing values (`sleep`, retry intervals, cooldown durations) are field-tuned for PLDT behavior. Other ISPs may require adjustments.

---

## Post-Deploy Verification

Run these checks after reboot to confirm the fix is working correctly.

**1. No global /128 on WAN**

```sh
ip -6 addr show dev eth1
```

Good: no `scope global` address with `/128`

**2. Prefix assigned**

```sh
ubus call network.interface.wan6 status | jsonfilter -e '@["ipv6-prefix"][0].address'
```

Good: returns a global prefix

**3. Default route correct**

```sh
ip -6 route show default
```

Good: single route via `fe80::...` on `eth1`

**4. Gateway reachable**

```sh
ip -6 neigh show dev eth1 | grep router
```

Good: state is `REACHABLE` or `STALE`, not `INCOMPLETE`

**5. Connectivity works**

```sh
ping6 -c 4 2001:4860:4860::8888
ping6 -c 4 2606:4700:4700::1111
```

**6. LAN clients have IPv6**

Clients should receive global IPv6 addresses, not just `fe80::` link-local addresses.

**7. Logs are clean**

```sh
logread | grep ipv6-setup
logread | grep ipv6-watchdog
```

**8. Watchdog has DHCPv6 renew tier**

```sh
grep -n "dhcpv6_renew" /usr/bin/ipv6-watchdog
```

Good: returns at least one line confirming the renew tier is present.

**9. Prefix tracker deployed and scheduled**

```sh
sh -n /usr/bin/ipv6-prefix-tracker
ls -l /usr/bin/ipv6-prefix-tracker
crontab -l | grep ipv6-prefix
grep -n ipv6-prefix-tracker /etc/sysupgrade.conf
```

Good: syntax passes, file is executable, cron entry exists every 5 minutes, sysupgrade persistence listed.

**10. Prefix tracker producing logs**

```sh
logread | grep ipv6-prefix
```

Good: `Prefix initialized: <prefix>` on first run after deploy, then silent until the prefix changes.

**11. Recovery hold state inspection (if hold has been triggered)**

```sh
# Check if hold latch exists
ls -l /tmp/ipv6-watchdog/recovery_hold

# Check last detected passive state
cat /tmp/ipv6-watchdog/hold_status

# Check if ONT alert was sent
ls -l /tmp/ipv6-watchdog/ont_notified

# Check WAN restart count
cat /tmp/ipv6-watchdog/wan_restart_count
```

If none of these files exist, the hold has not been triggered this boot (normal on a healthy router).

---

## Table of Contents

- [TL;DR](#tldr)
- [Read Before Applying](#read-before-applying)
- [Post-Deploy Verification](#post-deploy-verification)
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
- [Step 6 - Gratuitous ARP (Router Swap Recovery)](#step-6---gratuitous-arp-router-swap-recovery)
- [IPv6 Prefix Tracker](#ipv6-prefix-tracker)
- [Recovery Hold Detail](#recovery-hold-detail)
- [Troubleshooting and Debug Commands](#troubleshooting-and-debug-commands)
- [Validated Behavior](#validated-behavior)
- [Final Result](#final-result)
- [Preserving Scripts Across Firmware Upgrades](#preserving-scripts-across-firmware-upgrades)
- [Known Edge Cases](#known-edge-cases)
- [Advanced Notes: DUID and ULA](#advanced-notes-duid-and-ula)
- [Optional: Discord Notifications](#optional-discord-notifications)

---

## Quick Deploy

Apply in this order, then reboot:

1. Complete [Step 1 - UCI Config](#step-1---uci-config)
2. Deploy `98-wan6-delay`
3. Deploy `99-ipv6-setup`
4. Deploy `ipv6-watchdog`
5. Add the watchdog cron job
6. Deploy `97-garp`
7. Deploy `ipv6-prefix-tracker`
8. Add the prefix-tracker cron job
9. Reboot

The commands below deploy Steps 2 through 6. Step 1 must be completed first because the scripts read the UCI network settings at runtime.

Optional: set up Discord notifications (see [Optional: Discord Notifications](#optional-discord-notifications)).

### Before running the commands

Install required packages first. Only `iputils-arping` is required for `97-garp`. `curl` is optional and only needed if `wget` fails or if Discord notifications are enabled.

```sh
apk update
apk add iputils-arping
apk add curl
```

IPv4 internet must be working to run `apk`. A fresh OpenWrt flash provides it via the default DHCP WAN.

### One-command script deploy (recommended)

```sh
BASE="https://raw.githubusercontent.com/melskiedev/IPv6-PLDT-OpenWrt/main"

# Step 2 - wan6 startup delay
wget -q "$BASE/98-wan6-delay" -O /etc/hotplug.d/iface/98-wan6-delay \
  && chmod +x /etc/hotplug.d/iface/98-wan6-delay

# Step 3 - IPv6 route fix engine
wget -q "$BASE/99-ipv6-setup" -O /etc/hotplug.d/iface/99-ipv6-setup \
  && chmod +x /etc/hotplug.d/iface/99-ipv6-setup

# Step 4 - IPv6 watchdog (safe deploy: syntax check before replacing live script)
wget -q "$BASE/ipv6-watchdog" -O /tmp/ipv6-watchdog.new \
  && sh -n /tmp/ipv6-watchdog.new \
  && mv /tmp/ipv6-watchdog.new /usr/bin/ipv6-watchdog \
  && chmod +x /usr/bin/ipv6-watchdog && echo "watchdog deployed ok" \
  || echo "syntax check failed, not deployed"

# Step 5 - cron (command only, no file needed)
grep -qxF '*/1 * * * * /usr/bin/ipv6-watchdog' /etc/crontabs/root || \
  echo '*/1 * * * * /usr/bin/ipv6-watchdog' >> /etc/crontabs/root
/etc/init.d/cron restart

# Step 6 - gratuitous ARP
wget -q "$BASE/97-garp" -O /etc/hotplug.d/iface/97-garp \
  && chmod +x /etc/hotplug.d/iface/97-garp

# Step 7 - IPv6 prefix tracker (safe deploy: syntax check before replacing)
wget -q "$BASE/ipv6-prefix-tracker" -O /tmp/ipv6-prefix-tracker.new \
  && sh -n /tmp/ipv6-prefix-tracker.new \
  && mv /tmp/ipv6-prefix-tracker.new /usr/bin/ipv6-prefix-tracker \
  && chmod +x /usr/bin/ipv6-prefix-tracker && echo "prefix-tracker deployed ok" \
  || echo "syntax check failed, not deployed"

# Step 8 - prefix-tracker cron (idempotent, safe to run multiple times)
grep -qxF '*/5 * * * * /usr/bin/ipv6-prefix-tracker' /etc/crontabs/root || \
  echo '*/5 * * * * /usr/bin/ipv6-prefix-tracker' >> /etc/crontabs/root

# Restart cron once after all cron edits are done
/etc/init.d/cron restart

# Add tracker to sysupgrade persistence
grep -qxF '/usr/bin/ipv6-prefix-tracker' /etc/sysupgrade.conf || \
  echo '/usr/bin/ipv6-prefix-tracker' >> /etc/sysupgrade.conf
```

> The watchdog deploy uses a temp file and `sh -n` syntax check before replacing the live script. A bad download or interrupted transfer will not overwrite a working watchdog.

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

```text
  PLDT Fiber             ONT / Modem            GL.iNet Flint 2           LAN Clients        Internet
  ┌──────────────┐       ┌──────────────────┐     ┌──────────────────────┐    ┌──────────────┐    ┌──────────────┐
  │ Fiber ISP    │ fiber │ no NAT           │eth1 │ reqaddress=none      │    │ PC / Phone   │    │ IPv6 native  │
  │              │──────▶│ no routing       │────▶│ reqprefix=56         │───▶│ IPv6 SLAAC   │───▶│ 2001:4860::  │
  │ IPv6 /56 PD  │       │ WAN session      │     │ accept_ra=1          │    ├──────────────┤    │ 2606:4700::  │
  │ RA + DHCPv6  │       │ passed directly  │     │ LAN /64 delegated    │    │ IoT / Server │    ├──────────────┤
  │ CGNAT IPv4   │       │ to router        │     │ watchdog active      │    │ IPv6 SLAAC   │    │ IPv4 CGNAT   │
  │              │       ├──────────────────┤     │                      │    └──────────────┘    └──────────────┘
  └──────────────┘       │ ONT bridge mode  │     │ IPv6: native DHCPv6  │
                         └──────────────────┘     │ not NAT6 / no tunnel │
                                                  └──────────────────────┘

  ──▶ active WAN path    ···▶ routed traffic    █ this guide applies here (edge device)
  guide scope: native DHCPv6 + prefix delegation only; not applicable to NAT6, static IPv6, or tunnel setups
```

May work on:
- Other ISPs with similar IA_NA + RA gateway issues (common with CGNAT providers)

> **If your ISP does not exhibit the exact failure modes listed in the Root Causes section, do not apply this guide directly. Adapt the logic to your environment instead.**

Not designed for:
- Double NAT setups where OpenWrt is not the first hop
- Non-OpenWrt firmware

Expected to work on:
- OpenWrt 24.x and newer (fw4-based builds)

This was tested on OpenWrt 25.12.2 only. Older builds, custom images, and non-default environments may behave differently.

Core components used by the scripts:

- `odhcp6c` - DHCPv6 client (critical for prefix delegation)
- `netifd` - network interface management and hotplug system
- `busybox` - shell environment (`awk`, `grep`, etc.)
- `ip` - IPv6 routing and neighbor commands
- `ubus` and `jsonfilter` - interface status and prefix detection
- `ping6` - connectivity checks
- `curl` - required only if Discord notifications are enabled (`apk add curl`)

These are included in standard OpenWrt builds but may be missing in minimal or custom images. Tested on the default OpenWrt image with no additional packages required for the core setup.

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

The ISP assigns a `/128` WAN address via IA_NA alongside the delegated `/56` prefix. Linux source address selection prefers the `/128` global address for all outbound traffic. PLDT silently drops every packet originating from it. Removing the `/128` immediately restores connectivity.

This is the dominant failure. Everything else amplifies or destabilizes it.

```text
  PLDT ISP          OpenWrt                          Internet
  ┌─────────────┐   ┌────────────────────┐             ┌──────────────┐
  │ RA + DHCPv6 │──▶│ wan6 / eth1        │────────────▶│ IPv6 global  │
  └─────────────┘   └────────────────────┘             └──────────────┘
         │                    │
         │                    └─────────────────────────────────┐
         │                                                      │
         ▼                                                      ▼
  ┌──────────────────────────┐              ┌────────────────────────────────────────┐
  │ FAIL 2 - dead RA gateway │              │ PRIMARY - /128 IA_NA drop              │
  │ ISP sends 2 gateways     │              │ Linux prefers /128 as source address   │
  │ OpenWrt picks first -    │              │ PLDT silently drops ALL outbound       │
  │ it's dead (INCOMPLETE)   │              │ traffic from it                        │
  └──────────────────────────┘              └────────────────────────────────────────┘

  ─────────────────────────── RUNTIME / STARTUP ISSUES ──────────────────────────────

  ┌──────────────────────────┐  ┌─────────────────────────┐  ┌────────────────────────┐  ┌───────────────────────────┐
  │ FAIL 3 - race condition  │  │ FAIL 4 - RA override    │  │ FAIL 5 - accept_ra=2   │  │ FAIL 6 - NoPrefixAvail   │
  │ wan6 starts before LLA   │  │ New RA reinstalls dead  │  │ Removes RA fallback    │  │ ISP refuses prefix        │
  │ ready, DHCPv6 fails,     │  │ gateway. Works at boot, │  │ from wan6. Complete    │  │ delegation. Stale lease   │
  │ no default route         │  │ breaks silently later   │  │ IPv6 fail every boot   │  │ - ISP-side issue          │
  └──────────────────────────┘  └─────────────────────────┘  └────────────────────────┘  └───────────────────────────┘

  ───────────────────────────────── FIXES APPLIED ───────────────────────────────────

  ┌──────────────────┐  ┌────────────────────────────┐  ┌───────────────────┐  ┌────────────────────┐  ┌──────────────────────┐
  │ reqaddress=none  │  │ 99-ipv6-setup              │  │ 98-wan6-delay     │  │ ipv6-watchdog      │  │ renew + bootstrap    │
  │ blocks /128 IA_NA│  │ best GW + MAC pin + LAN RA │  │ 15s delay + reset │  │ GW fix + escalation│  │ prefix recovery      │
  └──────────────────┘  └────────────────────────────┘  └───────────────────┘  └────────────────────┘  └──────────────────────┘
```

### Secondary issues

**2. Multiple RA gateways, wrong one selected** - The ISP advertises two gateways via Router Advertisement. OpenWrt selects the first, which is dead. Neighbor table shows `INCOMPLETE` state.

**3. wan6 startup race condition** - `wan6` starts before the link-local address is ready on `eth1`, causing DHCPv6 to fail inconsistently after reboots.

**4. RA runtime override** - Even after fixing the route at boot, the dead gateway returns via a later RA and silently breaks connectivity again.

**5. Incorrect RA tuning** - Using `accept_ra='2'` with `defaultroute='0'` removes the fallback behavior `wan6` needs during initialization, causing complete IPv6 failure on every boot.

> **Warning:** Do not use `accept_ra='2'` with `defaultroute='0'`. This breaks `wan6` initialization and removes fallback routing, causing complete IPv6 failure on boot.

---

## Fix Architecture

**Startup flow:**

```
WAN up -> delay (15s, clean start) -> wan6 starts -> prefix acquired -> route fix engine runs
```

**Runtime flow:**

```
Watchdog (every 1 min) -> check connectivity -> fix route -> escalate if needed -> notify if unrecoverable
Prefix tracker (every 5 min) -> observe prefix -> log init/change -> refresh odhcpd -> suppress spam during hold
```

The prefix tracker is purely observational. It never restarts `wan`, `wan6`, the LAN bridge, or the router. It has no recovery logic and no interaction with the watchdog's escalation ladder. Its only write to system state is refreshing odhcpd after a prefix change so LAN clients receive updated RA without waiting for the next RA interval.

**Layers:**

| Layer | File | Purpose |
|---|---|---|
| A - UCI config | `network` UCI | Disables `/128`, stabilizes RA, delegates prefix |
| B - Delay script | `98-wan6-delay` | Fixes link-local race condition at boot |
| C - Route engine | `99-ipv6-setup` | Selects working gateway, pins MAC, removes /128 |
| D - Watchdog | `ipv6-watchdog` | Self-heals runtime failures every 1 min |
| E - Bootstrap recovery | `ipv6-watchdog` | Recovers DHCPv6 prefix failures automatically |
| F - Prefix tracker | `ipv6-prefix-tracker` | Observational: logs prefix init/change, refreshes odhcpd, suppresses no-prefix spam during hold |
| G - Notifications | `ipv6-discord-logger` | Optional Discord alerts and log forwarding |

```text
  STEP 1          STEP 2 - FIX B        STEP 3 - FIX B       STEP 4              STEP 5 - FIX C
  ┌────────────┐  ┌──────────────────┐  ┌───────────────┐    ┌──────────────────┐  ┌────────────────────────┐
  │  WAN up    │  │   reset wan6     │  │   15s delay   │    │  wan6 starts     │  │   route engine         │
  │            │─▶│                  │─▶│               │───▶│                  │─▶│                        │
  │ eth1 online│  │ ifdown if early  │  │ WAN + ISP     │    │ clean DHCPv6     │  │ best GW selected       │
  │            │  │ clears pending   │  │ ready         │    │ /56 prefix       │  │ + pinned               │
  └────────────┘  │ session          │  │ 98-wan6-delay │    │ acquired         │  │ default route          │
  boot event      └──────────────────┘  └───────────────┘    └──────────────────┘  │ installed              │
                  state correction      timing control        prefix delegation     │ /128 removed           │
                                                                                    └────────────────────────┘
                                                                                     GW select + MAC pin

                                    ┌────────────────────────────────┐
                                    │  IPv6 online, steady state     │
                                    └────────────────────────────────┘
                                                    │
                        ┌───────────────────────────┘
                        │
                        ▼
              ┌──────────────────────────────────────────────┐
              │  watchdog - runtime monitoring - flock + jitter  │
              └──────────────────────────────────────────────┘

  ────────────────── RUNTIME RECOVERY LADDER (no prefix) ─────────────────────────

  ┌───────────────────┐  ┌──────────────────────┐  ┌──────────────────┐  ┌──────────────────────────────────┐
  │ 1. restart wan6   │  │ 2. DHCPv6 renew      │  │ 3. /128 bootstrap│  │ 4. WAN restart → ONT alert       │
  │ backoff 10 min    │  │ verify + backoff      │  │ backoff 30 min   │  │ cooldown 20 min, limit 3,        │
  └───────────────────┘  │ 20 min               │  └──────────────────┘  │ then notify                      │
                         └──────────────────────┘                         └──────────────────────────────────┘
```

---

## Step 1 - UCI Config

Apply this first. Everything else depends on it.

```sh
# wan6
uci set network.wan6.reqaddress='none'
uci set network.wan6.reqprefix='56'
uci delete network.wan6.norelease
uci delete network.wan6.ip6assign
uci set network.wan6.device='@wan'
uci set network.wan6.accept_ra='1'
uci set network.wan6.force_link='1'
uci set network.wan6.multipath='off'
uci set network.wan6.sourcefilter='0'

# LAN prefix delegation
uci set network.lan.ip6assign='64'
uci set network.lan.ip6class='wan6'

# globals
uci set network.globals.rpfilter='0'
uci set network.globals.ipv6_sourcefilter='1'

uci commit network

# LAN DHCPv6 and RA
uci set dhcp.lan.dhcpv6='server'
uci set dhcp.lan.ra='server'
uci set dhcp.lan.ra_slaac='1'
uci set dhcp.lan.ra_default='1'
uci set dhcp.lan.ra_preference='medium'
uci set dhcp.lan.force='1'
uci set dhcp.lan.ndp='relay'

uci commit dhcp
```

What each setting does:

| Setting | Value | Why |
|---|---|---|
| `reqaddress` | `none` | Prevents ISP from assigning a broken `/128` WAN address |
| `reqprefix` | `56` | Explicitly requests the delegated `/56` block |
| `accept_ra` | `1` | Keeps RA processing on so `wan6` initializes correctly |
| `device` | `@wan` | Ties `wan6` to the `wan` interface lifecycle, not a hardcoded device name |
| `force_link` | `1` | Keeps `wan6` up even when link-local state is temporarily absent |
| `multipath` | `off` | Prevents multipath routing from interfering with gateway selection |
| `sourcefilter` | `0` | Allows DHCPv6 PD on asymmetric routes; required for PLDT bridge mode |
| `ip6assign` | `64` | LAN gets a `/64` from the delegated prefix |
| `ip6class` | `wan6` | Binds LAN prefix delegation to the `wan6` interface |
| `rpfilter` | `0` | Disables reverse-path filtering; required for DHCPv6 PD on PLDT |
| `ipv6_sourcefilter` | `1` | Enables IPv6 source address selection per interface |
| `dhcpv6` | `server` | Enables stateful DHCPv6 server on LAN |
| `ra` | `server` | Enables Router Advertisement on LAN so clients get IPv6 default gateway |
| `ra_slaac` | `1` | Enables SLAAC so clients auto-configure their own global IPv6 address |
| `ra_default` | `1` | Includes default route in RA so clients know how to reach IPv6 internet |
| `ra_preference` | `medium` | Sets RA preference level; prevents lower-priority RAs from overriding |
| `force` | `1` | Forces DHCPv6 server to run even when no clients are present yet |
| `ndp` | `relay` | Relays Neighbor Discovery Protocol between WAN and LAN; required for IPv6 NDP to reach LAN clients |

> **Important:** Never restart the LAN interface (`ifdown lan` / `ifup lan` or `/etc/init.d/network restart`) while `wan6` is up and odhcpd has an active delegated prefix. This causes odhcpd to mark the prefix as stale and set `ra_lifetime=0`, withdrawing IPv6 from all LAN clients. To apply LAN config changes without disrupting IPv6, use:
>
> ```sh
> ubus call network reload
> sleep 10
> /etc/init.d/odhcpd restart
> ```

---

## Step 2 - wan6 Startup Delay

**File:** [`98-wan6-delay`](98-wan6-delay) → `/etc/hotplug.d/iface/98-wan6-delay`

Waits for WAN to be fully ready before starting `wan6`, eliminating early DHCPv6 startup failures that can leave the interface stuck in a `pending` state. Ensures a clean start by resetting any prematurely started session and delaying until the ISP is ready.

**Deploy:**

```sh
wget -q https://raw.githubusercontent.com/melskiedev/IPv6-PLDT-OpenWrt/main/98-wan6-delay \
  -O /etc/hotplug.d/iface/98-wan6-delay && chmod +x /etc/hotplug.d/iface/98-wan6-delay
```

---

## Step 3 - IPv6 Route Fix Engine

**File:** [`99-ipv6-setup`](99-ipv6-setup) → `/etc/hotplug.d/iface/99-ipv6-setup`

Runs whenever `wan6` comes up. This is the authoritative startup fix. It ensures a working gateway is selected, its MAC address is pinned to prevent re-introduction of the dead gateway, and the `/128` is removed once connectivity is confirmed.

**Dual gateway sourcing.** Combines the neighbor table (`ip -6 neigh`) and existing default routes (`ip -6 route`) to build the candidate list. The neighbor table alone can miss gateways if NDP discovery was incomplete. Combining both sources ensures no reachable gateway is overlooked.

**MAC pinning via `ip -6 neigh replace ... nud stale`.** After selecting the working gateway, the script pins its MAC address in the neighbor table. Without this, the kernel treats the neighbor entry as transient and may evict it under memory pressure or after the NDP lifetime expires. When the entry is evicted, the kernel re-runs NDP discovery and PLDT's dead gateway can be reintroduced at that point. Pinning with `nud stale` keeps the correct entry stable while still allowing the kernel to revalidate it naturally.

**LLA failure exit.** If no link-local address appears on the WAN interface after 20 seconds, the script exits immediately with a logged error rather than proceeding with an incomplete interface state.

**Per-gateway internet reachability testing.** For each candidate gateway, the script installs the route temporarily and tests connectivity to both Google (`2001:4860:4860::8888`) and Cloudflare (`2606:4700:4700::1111`) before accepting the candidate. A gateway that responds locally but does not forward internet traffic is rejected and the next candidate is tried. This matches `fix_gateway()` in the watchdog and is the correct defense against PLDT's dead gateway failure mode.

**Lock mechanism.** Prevents overlapping executions on rapid `wan6` hotplug events using `flock` with `mkdir` fallback, matching the watchdog's approach. The script can run for over 2 minutes during gateway scan and WAN recovery.

**Defers to watchdog on missing prefix.** If no prefix is assigned after 45 seconds, the script logs a warning and exits cleanly. Prefix recovery (DHCPv6 renew, /128 bootstrap, WAN restart escalation) is the watchdog's responsibility, not the hotplug script's.

**Deploy:**

```sh
wget -q https://raw.githubusercontent.com/melskiedev/IPv6-PLDT-OpenWrt/main/99-ipv6-setup \
  -O /etc/hotplug.d/iface/99-ipv6-setup && chmod +x /etc/hotplug.d/iface/99-ipv6-setup
```

---

## Step 4 - IPv6 Watchdog

**File:** [`ipv6-watchdog`](ipv6-watchdog) → `/usr/bin/ipv6-watchdog`

Runs every 1 minute via cron, with jitter and `flock` to prevent overlap. Checks connectivity using layered validation (prefix, route, then reachability), fixes a broken gateway if one exists, and escalates through a controlled recovery ladder if the prefix is missing. DHCPv6 renew may recover the prefix within the same cron cycle due to the post-renew check. After boot grace and counter reads, a global same-boot recovery hold runs before Tier 0 and all disruptive paths.

**Same-boot full WAN restart budget:**

The watchdog allows a maximum of **3 actual full WAN restarts per router boot**. The count is cumulative for the boot, not consecutive and not per incident. If IPv6 recovers after restart #1 or #2, `WAN_RESTARTS` stays at 1 or 2 until the router reboots. A real router reboot clears `/tmp/ipv6-watchdog` and restores the three-restart budget.

After `WAN_RESTARTS` reaches `WAN_RESTART_LIMIT` (default 3), or the explicit `recovery_hold` latch file is touched, the watchdog enters **global recovery hold** for the remainder of that boot. Hold mode is passive monitoring only: it detects one of six states each tick, logs only on first entry or state change, sends the ONT alert once, and detects spontaneous recovery. All disruptive recovery is blocked, including Tier 0 soft `wan6` flaps, DHCPv6 renew, `/128` bootstrap, network reload, and further full WAN restarts. Spontaneous IPv6 recovery during hold does not restore the WAN restart budget.

Hold uses three state files under `/tmp/ipv6-watchdog`:

| File | Meaning |
|---|---|
| `recovery_hold` | Explicit same-boot latch. Touched on first hold entry. Once set, `recovery_hold_active()` returns true even if `WAN_RESTARTS` is somehow reset. Cleared only by router reboot. |
| `ont_notified` | Critical 3/3 ONT intervention alert already sent this boot (suppresses duplicate red alerts) |
| `hold_status` | Last detected passive state string. Written only on first hold entry or state transition, not every tick. Values: `wan6-down`, `wan6-up-no-device`, `no-prefix`, `prefix-present-no-route`, `prefix-present-unreachable`, `recovered`. |

See [Recovery Hold Detail](#recovery-hold-detail) for the full state machine, state-transition matrix, and expected log patterns.

**Failure domains:**

| Condition | Recovery path |
|---|---|
| `WAN_RESTARTS >= WAN_RESTART_LIMIT` (default 3/3) | Global recovery hold: passive monitoring only until router reboot clears `/tmp` state |
| `wan6` fully down (budget remaining) | Tier 0: soft `wan6` restart on attempts 1–2; after 3 failures, `maybe_wan_restart()` (full WAN restart with shared limit + cooldown) |
| Dead RA gateway (prefix present, connectivity broken) | `keep_gateway()` (if sticky enabled) + `fix_gateway()` with MAC pin; after 3 consecutive failures, `maybe_wan_restart()` (same limit + cooldown) |
| Missing prefix (DHCPv6 failure) | Escalating ladder: wan6 restart, DHCPv6 renew, `/128` bootstrap, full WAN restart via `maybe_wan_restart()` |
| Persistent prefix failure after 3 WAN restarts | Enter global recovery hold; notify once, wait for manual ONT powercycle or router reboot |

**Escalation timeline for persistent NoPrefixAvail:**

```
Each tick: boot grace -> read counters -> global recovery hold check -> jitter
  If hold active (3/3 full WAN restarts used this boot):
    passive monitoring only; no disruptive recovery until router reboot

  If budget remains and wan6 is fully down, Tier 0 runs before all other checks.
  Attempts 1–2: soft ifdown/ifup wan6
  Attempt 3+:   maybe_wan_restart() (subject to WAN_RESTART_LIMIT and cooldown)

Tick 1  (0 min)   No prefix. Restart wan6. Backoff 10 min.
Tick 3  (10 min)  Still no prefix. DHCPv6 renew. Backoff 20 min.
Tick 7  (30 min)  Still no prefix. /128 bootstrap. Backoff 30 min.
Tick 13 (60 min)  Still no prefix. Full WAN restart #1. Cooldown 20 min.
Tick 17 (80 min)  Out of cooldown. Ladder continues. Budget still counts restarts used this boot.
...
After 3 actual full WAN restarts this boot: global recovery hold.
  Passive monitoring only. ONT alert once. Spontaneous recovery does not restore budget.
  Router reboot clears /tmp/ipv6-watchdog and restores the three-restart budget.
```

**Why backoff matters:** Rapid reconnects worsen stale lease conditions on PLDT's DHCPv6 server (see Edge Case 6). The spacing gives the ISP time between attempts.

**Deploy from repo (recommended):**

```sh
wget -q https://raw.githubusercontent.com/melskiedev/IPv6-PLDT-OpenWrt/main/ipv6-watchdog \
  -O /tmp/ipv6-watchdog.new && sh -n /tmp/ipv6-watchdog.new \
  && mv /tmp/ipv6-watchdog.new /usr/bin/ipv6-watchdog \
  && chmod +x /usr/bin/ipv6-watchdog && echo "watchdog deployed ok" \
  || echo "syntax check failed, not deployed"
```

The watchdog deploy downloads to a temp file first, runs a shell syntax check (`sh -n`), and only replaces the live script if the check passes. A bad download or interrupted transfer will not overwrite a working watchdog.

### Watchdog configuration (`/etc/ipv6-watchdog.conf`)

The watchdog sources this file on every cron tick. Scripts that share behavior (`99-ipv6-setup`, `97-garp`) also read it where noted below.

**Versioning:** Git tags (`v3.9.x`) mark repo/deploy bundle releases. Versioned components carry `# vX.Y.Z` headers for router-side inspection (`grep -m1 '^# v' /usr/bin/ipv6-watchdog`). Current repo release: `ipv6-watchdog` **v3.9.8** (tagged); development header in source is **v3.9.9** (unreleased, planned). `ipv6-discord-logger` **v3.9.6** (paired with `init.d-ipv6-discord-logger`, no separate header), `99-ipv6-setup` **v3.9.6**. Simple glue (`97-garp`, `98-wan6-delay`) have no version headers. `ipv6-prefix-tracker` has no separate version header.

Restrict permissions whenever this file exists (required if it contains Discord webhook URLs):

```sh
chmod 600 /etc/ipv6-watchdog.conf
```

**WAN restart limits** (optional overrides; defaults shown):

```sh
WAN_RESTART_COOLDOWN=1200   # seconds between full WAN restarts (20 minutes)
WAN_RESTART_LIMIT=3         # full WAN restarts per router boot before global recovery hold
```

All full WAN restarts go through `maybe_wan_restart()`, which enforces these limits for Tier 0 escalation, no-prefix escalation, and connectivity-failure escalation. Successful IPv6 recovery does **not** reset `WAN_RESTARTS`; only a router reboot clears the same-boot budget. After `WAN_RESTART_LIMIT` is reached, the global recovery hold blocks all disruptive recovery for the remainder of the boot.

### Optional: Sticky Gateway (PLDT routers only)

The watchdog includes an optional sticky gateway feature that re-pins the last known-good gateway when PLDT's RA replaces it with a dead one. It is disabled by default (`STICKY_GATEWAY=0`) so the script is safe on all routers. Enable it only on PLDT routers where dead gateway advertisements are a known issue.

The setting lives in `/etc/ipv6-watchdog.conf`, which the watchdog sources on every tick. This keeps the script itself identical across all routers while allowing per-router behavior.

**Enable sticky gateway via SSH:**

```sh
grep -q '^STICKY_GATEWAY=' /etc/ipv6-watchdog.conf \
  && sed -i 's/^STICKY_GATEWAY=.*/STICKY_GATEWAY=1/' /etc/ipv6-watchdog.conf \
  || echo 'STICKY_GATEWAY=1' >> /etc/ipv6-watchdog.conf
```

**Disable sticky gateway via SSH:**

```sh
sed -i 's/^STICKY_GATEWAY=.*/STICKY_GATEWAY=0/' /etc/ipv6-watchdog.conf
```

**Check current value:**

```sh
grep '^STICKY_GATEWAY=' /etc/ipv6-watchdog.conf
```

**Check what the running watchdog sees (reads conf on every tick, no restart needed):**

```sh
/usr/bin/ipv6-watchdog
logread | grep ipv6-watchdog | tail -5
```

Changes to `/etc/ipv6-watchdog.conf` take effect on the next cron tick. No watchdog restart is required.

**Expected log patterns when sticky gateway is active:**

| Log line | Meaning |
|---|---|
| `Sticky gateway baseline set: fe80::...` | First tick after enabling, current gateway verified and saved as known-good |
| `Sticky gateway baseline not set: current gateway fe80::... has no internet reachability` | First tick, current gateway is already dead, baseline deferred until next good tick |
| `Sticky gateway check: current gateway changed fe80::old -> fe80::new` | PLDT RA swapped the gateway |
| `Sticky gateway restored: fe80::old (mac ..., internet verified)` | Old gateway still works, re-pinned |
| `Sticky gateway preferred fe80::old failed internet test, restoring current fe80::new` | Old gateway is dead, new one accepted as known-good |
| `preferred ... has no MAC, accepting verified current ...` | Preferred gateway lost MAC; current gateway passed internet test |
| `preferred ... has no MAC, current ... not verified, keeping baseline` | Neither gateway verified; baseline unchanged |
| `In post-restart cooldown, ... skipping Tier 0 recovery` | Tier 0 deferred during WAN restart cooldown |
| `Recovery hold entered: 3/3 full WAN restarts used this boot; passive monitoring only` | First hold tick: budget exhausted, hold latch set |
| `Recovery hold passive status: wan6-down` | Initial passive state detected on first hold tick |
| `Recovery hold state change: no-prefix -> recovered` | State transition during hold (logged once per change) |
| `Recovery hold: IPv6 spontaneously recovered; preserving WAN restart budget until reboot` | IPv6 healthy during hold, but budget remains consumed until reboot |

---

## Step 5 - Cron Setup

**File:** `/etc/crontabs/root`

Add the watchdog (idempotent, safe to run multiple times):

```sh
grep -qxF '*/1 * * * * /usr/bin/ipv6-watchdog' /etc/crontabs/root || \
echo '*/1 * * * * /usr/bin/ipv6-watchdog' >> /etc/crontabs/root

/etc/init.d/cron restart
```

---

## Step 6 - Gratuitous ARP (Router Swap Recovery)

**File:** `/etc/hotplug.d/iface/97-garp`

Fires on LAN bridge ifup and sends a gratuitous ARP broadcast, forcing all LAN clients to update their ARP cache with the router's current MAC address. Without this, swapping routers on the same ONT with the same LAN IP but a different MAC leaves LAN clients sending traffic to the old MAC, resulting in internet loss at Layer 2 that no watchdog can detect.

Reads LAN IP dynamically via UCI. Uses `LAN_DEV` from `/etc/ipv6-watchdog.conf` (default `br-lan`). Portable across routers with non-default bridge names.

First verify `arping` is available (included in standard OpenWrt builds):

```sh
which arping
```

If not found:

```sh
apk add iputils-arping
```

Then deploy:

```sh
cat > /etc/hotplug.d/iface/97-garp << 'SCRIPT'
#!/bin/sh
CONF="/etc/ipv6-watchdog.conf"
[ -f "$CONF" ] && . "$CONF"
LAN_DEV="${LAN_DEV:-br-lan}"
[ "$ACTION" = "ifup" ] || exit 0
[ "$DEVICE" = "$LAN_DEV" ] || exit 0
sleep 3
LAN_IP=$(uci get network.lan.ipaddr 2>/dev/null)
[ -n "$LAN_IP" ] && arping -A -I "$LAN_DEV" -c 3 "$LAN_IP"
SCRIPT
chmod +x /etc/hotplug.d/iface/97-garp
```

Alternatively, deploy from repo:

```sh
wget -q https://raw.githubusercontent.com/melskiedev/IPv6-PLDT-OpenWrt/main/97-garp \
  -O /etc/hotplug.d/iface/97-garp && chmod +x /etc/hotplug.d/iface/97-garp
```

Add to sysupgrade preserve list:

```sh
echo '/etc/hotplug.d/iface/97-garp' >> /etc/sysupgrade.conf
```

Test manually:

```sh
ACTION=ifup DEVICE=br-lan /etc/hotplug.d/iface/97-garp
```

---

## IPv6 Prefix Tracker

**File:** [`ipv6-prefix-tracker`](ipv6-prefix-tracker) → `/usr/bin/ipv6-prefix-tracker`

An observational component that monitors delegated IPv6 prefix changes on `wan6`. It is separate from the watchdog's disruptive recovery ladder and never restarts `wan`, `wan6`, the LAN bridge, or the router.

| Property | Value |
|---|---|
| Repository filename | `ipv6-prefix-tracker` |
| Router destination | `/usr/bin/ipv6-prefix-tracker` |
| Cron schedule | Every 5 minutes (`*/5 * * * *`) |
| Configuration file | `/etc/ipv6-watchdog.conf` (shared with watchdog; reads `DISCORD_WEBHOOK`) |
| Persistent state file | `/etc/ipv6-prefix-current` (survives reboots; stores last seen prefix) |
| Syslog tag | `ipv6-prefix` |

**Behavior by state:**

| Condition | What happens |
|---|---|
| First run (no state file) | Logs `Prefix initialized: <prefix>`, sends Discord notification, saves prefix to `/etc/ipv6-prefix-current` |
| Prefix unchanged | Silent exit. No log, no notification, no write. |
| Prefix changed | Logs `Prefix changed: <old> -> <new>`, reloads odhcpd (or sends SIGHUP as fallback), sends Discord notification, updates state file |
| No prefix, no hold active | Logs `No delegated prefix currently available on wan6`. Repeats each invocation until prefix returns. |
| No prefix, hold active | Silent exit. Suppresses the no-prefix log to avoid spamming every 5 minutes while the watchdog is in recovery hold. |
| Prefix returns during hold | Prefix initialization or change behavior operates normally. Hold suppression only affects the no-prefix log path; it does not suppress prefix init/change notifications. |

**odhcpd reload:** On a prefix change, the tracker runs `/etc/init.d/odhcpd reload`. If that fails, it sends `killall -HUP odhcpd` as a fallback. This refreshes LAN RA immediately so clients receive the new prefix without waiting for the next RA interval.

**Hold-aware suppression:** The tracker checks for `/tmp/ipv6-watchdog/recovery_hold` before logging the no-prefix message. This file is created by the watchdog when it enters recovery hold. The tracker does not create or remove this file — it only reads it.

**Deploy from repo (recommended):**

```sh
wget -q https://raw.githubusercontent.com/melskiedev/IPv6-PLDT-OpenWrt/main/ipv6-prefix-tracker \
  -O /tmp/ipv6-prefix-tracker.new && sh -n /tmp/ipv6-prefix-tracker.new \
  && mv /tmp/ipv6-prefix-tracker.new /usr/bin/ipv6-prefix-tracker \
  && chmod +x /usr/bin/ipv6-prefix-tracker && echo "prefix-tracker deployed ok" \
  || echo "syntax check failed, not deployed"
```

**Cron entry (idempotent):**

```sh
grep -qxF '*/5 * * * * /usr/bin/ipv6-prefix-tracker' /etc/crontabs/root || \
  echo '*/5 * * * * /usr/bin/ipv6-prefix-tracker' >> /etc/crontabs/root
/etc/init.d/cron restart
```

**Sysupgrade persistence:**

```sh
grep -qxF '/usr/bin/ipv6-prefix-tracker' /etc/sysupgrade.conf || \
  echo '/usr/bin/ipv6-prefix-tracker' >> /etc/sysupgrade.conf
```

Optional: preserve `/etc/ipv6-prefix-current` to avoid a re-initialization log after firmware upgrade.

---

## Recovery Hold Detail

The watchdog's global recovery hold is a same-boot safety latch that prevents disruptive recovery cycles from repeating indefinitely. Once activated, it persists until a real router reboot clears `/tmp/ipv6-watchdog`.

**Activation:**

The hold activates when either:
- `WAN_RESTARTS >= WAN_RESTART_LIMIT` (default 3/3 full WAN restarts used this boot), or
- The explicit `recovery_hold` latch file exists under `/tmp/ipv6-watchdog/`

Once the latch file is touched on the first hold tick, `recovery_hold_active()` returns true even if the restart count file is somehow cleared. The latch is cleared only by router reboot (which recreates `/tmp`).

**Six passive states:**

Each hold tick detects exactly one state using quiet checks (no `ipv6_ok()` logging):

| State | Condition | Detection method |
|---|---|---|
| `wan6-down` | wan6 interface not up | `ubus ... @["up"]` returns false |
| `wan6-up-no-device` | wan6 up but no l3_device | `jsonfilter @["l3_device"]` empty |
| `no-prefix` | wan6 up, device found, no delegated prefix | `has_prefix()` returns false |
| `prefix-present-no-route` | prefix exists but no default route | `ip -6 route show default` empty |
| `prefix-present-unreachable` | prefix + route exist but ping fails | `internet_ok_now()` returns false |
| `recovered` | prefix + route + internet all pass | `internet_ok_now()` returns true |

**State-change-only logging:**

- **First hold tick:** Logs `Recovery hold entered: N/N full WAN restarts used this boot; passive monitoring only` and `Recovery hold passive status: <state>`. Writes `hold_status`. Sends ONT alert if state is not `recovered`.
- **Unchanged tick:** No log output. No file write. Completely silent.
- **State transition:** Logs `Recovery hold state change: <old> -> <new>`. Writes `hold_status`. If transitioning to `recovered`, sends one recovery Discord notification and calls `cleanup_deprecated_v6`.
- **ONT alert:** One-shot. Sent on the first non-recovered tick where `ont_notified` does not exist. Never repeated, even across state transitions.

**Spontaneous recovery during hold:**

When IPv6 recovers during hold (transition to `recovered`):
- One recovery Discord notification is sent (if `ont_notified` exists from the prior critical alert)
- `cleanup_deprecated_v6` removes deprecated LAN addresses
- `reset_recovery_state()` is **not** called
- `WAN_RESTARTS` stays at the limit (budget remains exhausted)
- `ont_notified` stays set
- `recovery_hold` stays set
- `hold_status` is updated to `recovered`

The hold remains active. Automatic recovery remains disabled until router reboot. If IPv6 degrades again later, the state transition is logged but no new ONT alert is sent (one-shot).

**ONT power cycling:**

Power-cycling the ONT may restore IPv6 connectivity (the ISP clears the stale lease), but it does **not** clear the recovery hold or re-arm the WAN restart budget. Only a router reboot clears `/tmp` and restores full recovery capability. This is by design: once three full WAN restarts have been attempted this boot, the router should be rebooted to ensure a clean state.

**State-transition matrix:**

| Previous → New | Log output | Side effects |
|---|---|---|
| (empty) → any | Hold entry + initial status | ONT alert if not recovered; `hold_status` written |
| any → same | *(silent)* | *(none)* |
| non-recovered → non-recovered | State change logged | `hold_status` updated |
| non-recovered → recovered | State change + recovery logged | Recovery Discord; cleanup_deprecated_v6; `hold_status` updated |
| recovered → non-recovered | State change logged | ONT alert only if `ont_notified` not yet set; `hold_status` updated |
| recovered → recovered | *(silent)* | *(none)* |

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

Check watchdog state files:

```sh
ls /tmp/ipv6-watchdog/
cat /tmp/ipv6-watchdog/prefix_fail_count
cat /tmp/ipv6-watchdog/wan_restart_count
cat /tmp/ipv6-watchdog/last_wan_restart
```

Manual gateway probe:

```sh
ip -6 neigh show dev eth1 | grep router
ping6 -c 3 -I eth1 <gateway-address>
```

Force NDP discovery (if neighbor table is empty and fix_gateway has no candidates):

```sh
ping6 -c 1 -I eth1 ff02::2%eth1
sleep 2
ip -6 neigh show dev eth1 | grep router
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

Run watchdog manually:

```sh
/usr/bin/ipv6-watchdog
```

Safe LAN config reload (use instead of restarting LAN interface):

```sh
ubus call network reload
sleep 10
/etc/init.d/odhcpd restart
```

---

## Validated Behavior

Confirmed during real-world testing:

- Hotplug correctly selects the working gateway on each boot
- Dead gateway occasionally returns via RA, watchdog catches and replaces it within 1 minute
- ONT power cycling (technician visit) handled cleanly, wan6 recovered automatically without intervention
- Manual `ip -6 route replace` restores IPv6 instantly, confirming the issue is route selection, not prefix delegation
- `accept_ra='2'` + `defaultroute='0'` is confirmed unstable for this ISP
- Tier 0 wan6 down recovery fires automatically when wan6 fails to come up after boot
- Watchdog escalation ladder fires correctly across prefix failure scenarios
- DHCPv6 renew recovers prefix in same cron cycle when ISP just needs a re-request
- Layered `ipv6_ok` validation classifies failures by type in logs for faster debugging
- Backoff prevents DHCPv6 hammering during NoPrefixAvail conditions
- ONT powercycle notification fires once per incident and resets cleanly on recovery
- Router identity in Discord alerts reads dynamically from system, no hardcoded values
- `fix_gateway()` correctly rejects gateways that respond locally but fail internet reachability

---

## Final Result

| Issue | Fix | Status |
|---|---|---|
| Broken `/128` WAN address used as source | `reqaddress='none'` | Fixed |
| Dead gateway selected at startup | Route fix engine via hotplug | Fixed |
| Stable prefix delegation | `reqprefix='56'` + RA enabled | Fixed |
| Dead gateway returns via RA at runtime | Watchdog + cron every 1 min | Fixed |
| Race condition on boot | `98-wan6-delay` script | Fixed |
| Prefix delegation failure (NoPrefixAvail) | Escalating recovery ladder with backoff | Fixed |
| Persistent ISP-side lease failure | ONT powercycle notification after 3 WAN restarts | Escalated to human |
| LAN clients not receiving IPv6 | `dhcp.lan` DHCPv6 + RA + NDP relay config | Fixed |

---

## Preserving Scripts Across Firmware Upgrades

Add all core scripts to the sysupgrade preserve list so they survive firmware flashes:

```sh
cat >> /etc/sysupgrade.conf << 'EOF'
/etc/hotplug.d/iface/98-wan6-delay
/etc/hotplug.d/iface/99-ipv6-setup
/usr/bin/ipv6-watchdog
/usr/bin/ipv6-prefix-tracker
/etc/crontabs/root
/etc/sysctl.conf
EOF
```

Optional: preserve the prefix tracker's state file so it does not re-log `Prefix initialized` after a firmware upgrade (the prefix is usually the same):

```sh
echo '/etc/ipv6-prefix-current' >> /etc/sysupgrade.conf
```

Do not include `router-pulls/` or any local-only working directories.

If using Discord notifications, also add:

```sh
cat >> /etc/sysupgrade.conf << 'EOF'
/usr/bin/ipv6-discord-logger
/etc/init.d/ipv6-discord-logger
/etc/ipv6-watchdog.conf
EOF
```

Then generate a backup via LuCI: **System -> Backup / Flash Firmware -> Generate archive**.

---

## Known Edge Cases

These are real-world scenarios observed during testing with PLDT and OpenWrt. They are not part of normal operation but may occur under unstable ISP or initialization conditions.

---

### 1. wan6 fails to come up after reboot (no prefix acquired)

In rare cases, `wan6` may fail to initialize properly with `reqaddress='none'`. The watchdog now handles this automatically via the `/128` bootstrap on the second consecutive prefix failure.

Symptoms:
- `wan6` shows `up: false` or stuck state
- No IPv6 prefix assigned

**Automatic handling:** The watchdog escalation ladder covers this. On the first failure it restarts `wan6`. On the second failure it attempts a DHCPv6 renew. On the third failure it performs the `/128` bootstrap. No manual intervention is needed unless the watchdog has reached the restart limit.

**Manual recovery if needed:**

Phase 1: temporarily allow `/128` to force DHCPv6 initialization:

```sh
uci set network.wan6.reqaddress='try'
uci commit network
ifdown wan6; sleep 5; ifup wan6
```

Wait for `wan6` to come up:

```sh
ubus call network.interface.wan6 status | jsonfilter -e '@["up"]'
```

Phase 2: remove `/128` and restore correct config:

```sh
ip -6 addr show dev eth1 | awk '/\/128 scope global/{print $2}' \
| while read -r addr; do ip -6 addr del "$addr" dev eth1; done

uci set network.wan6.reqaddress='none'
uci commit network
```

If `wan6` comes up but no prefix is assigned, see Edge Case 6 (`NoPrefixAvail`).

---

### 2. IPv6 works initially, then stops after some time

Symptoms:
- IPv6 works after reboot
- Stops working 1-10 minutes later
- Prefix still exists

Cause: ISP Router Advertisement reintroduces a dead default gateway at runtime.

Resolution: Automatically handled by `ipv6-watchdog` every 1 minute. Manual fix:

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

Cause: ISP DHCPv6 server refused to assign a prefix. Common reasons:
- Stale lease on ISP side from previous session
- Prefix pool exhaustion on PLDT's network
- Session not fully released after fast reconnect

**This is not a router misconfiguration. This is an ISP-side issue.**

**Automatic handling:** The watchdog escalation ladder handles this fully. It will restart `wan6`, attempt a DHCPv6 renew, try the `/128` bootstrap, and escalate to full WAN restarts with exponential backoff between attempts to avoid worsening the stale lease condition. After 3 full WAN restarts with no recovery it stops retrying and notifies you to power cycle the ONT.

If you receive the ONT powercycle notification:

1. Turn off ONT
2. Wait 15-30 minutes
3. Turn ONT back on

This forces the ISP to release the previous prefix allocation. Do not attempt rapid WAN restarts during this condition as fast reconnects may worsen it.

> **Note:** In rare cases on certain OpenWrt builds, prefix delegation may fail due to firmware-level issues rather than ISP behavior. This can present similarly but may not be resolved by ONT power cycling. See [OpenWrt issue #22309](https://github.com/openwrt/openwrt/issues/22309) for reference.

---

## Advanced Notes: DUID and ULA

This section is informational only and not required for the core setup.

### DUID (DHCPv6 Unique Identifier)

OpenWrt automatically generates a DUID on first boot. PLDT uses this to identify the DHCPv6 client and anchor prefix delegation leases.

**OpenWrt 25.12 DUID change:** OpenWrt 25.12 changed the default DUID type from DUID-LL (Type 3, MAC-based) to DUID-UUID (Type 4, random). The new DUID-UUID is persistent across reboots and sysupgrades when settings are kept. On a fresh flash with no settings preserved, a new random DUID is generated on first boot.

**Why DUID pinning matters on PLDT:** Without a pinned DUID, every `wan6` restart that generates a new DUID is treated by PLDT as a new client. PLDT may assign a different prefix, delay assignment, or withhold the prefix entirely until the previous lease expires. This is the underlying cause of prefix rotation observed during wan6 recovery events. Pinning the DUID gives PLDT a stable client identity to anchor lease renewal against, which significantly reduces prefix rotation across restarts.

**How to pin the DUID:**

First, capture your current DUID before it changes:

```sh
# Read the DUID currently presented by odhcp6c on wan6
uci get network.wan6.clientid 2>/dev/null || \
    strings /var/lib/odhcp6c.*.clientid 2>/dev/null | head -1
```

Note: `strings` may not be available on all OpenWrt builds. If the command is not found, check the running odhcp6c process instead:

```sh
cat /proc/$(pidof odhcp6c)/cmdline 2>/dev/null | tr '\0' '\n' | grep -A1 "\-c"
```

Once you have the value, pin it:

```sh
# Replace with your actual DUID value
# Example only. Replace with your router's own DUID. Do not copy another router's DUID.
uci set network.wan6.clientid='0004xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx'
uci commit network
```

**Critical rules for DUID:**

- Capture and record your DUID before any firmware flash
- Never copy a DUID from one router to another; each device must have a unique DUID
- After a fresh flash with no settings preserved, a new DUID is generated; re-pin it after first boot
- Add `network.wan6.clientid` to your sysupgrade backup or document the value externally

**Add to sysupgrade preserve list:**

```sh
# The clientid is stored in /etc/config/network, which is preserved by default.
# Confirm it survives sysupgrade by checking after flash:
uci get network.wan6.clientid
```

In rare cases, a DUID change may result in loss of prefix delegation or delayed assignment until the ISP releases the previous lease. This presents as `wan6` up but no prefix assigned, similar to Edge Case 6 (`NoPrefixAvail`).

### ULA (Unique Local Address)

Not used in this setup. All LAN IPv6 addressing comes from the ISP-delegated prefix (`/56 -> /64`).

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
| DUID pin | Recommended for prefix stability | No, but strongly advised |
| ULA | Not used | No |

This guide focuses on ISP-provided global IPv6 with self-healing routing. The design philosophy is to fix ISP behavior dynamically rather than compensate with alternate addressing schemes.

### LAN Interface IPv6 Suffix

By default, OpenWrt assigns the router's own LAN IPv6 address using suffix `::1` from the delegated prefix (e.g. `2001:4451:xxxx:xxxx::1/64`). This is the address the router presents on `br-lan`.

The suffix can be changed in LuCI under **Network -> Interfaces -> lan -> Edit -> Advanced Settings -> IPv6 suffix**. Options are:

| Value | Behavior |
|---|---|
| (unset) | Defaults to `::1` |
| `::1` | Static suffix, same across reboots and prefix changes |
| `eui64` | Derived from the router MAC address, stable but device-specific |
| `random` | Random suffix generated by `odhcpd`, changes on interface restart or prefix rotation |

When the suffix changes, the old address remains on `br-lan` as `deprecated` until its lifetime expires. The `cleanup_deprecated_v6()` function in `ipv6-watchdog` removes these stale deprecated addresses automatically after IPv6 is confirmed healthy, so they do not linger indefinitely.

---

## Optional: Discord Notifications

This section is entirely optional. The core IPv6 fix works without it. If you skip this section, the watchdog still self-heals and logs everything locally via `logread`.

If you want real-time visibility on your phone or desktop, you can wire up two Discord webhook channels.

**What you get:**

| Channel | What it receives |
|---|---|
| `#ipv6-alerts` | ONT powercycle alert (red embed, once per incident) and recovery notice (green embed) |
| `#ipv6-logs` | All tagged syslog lines in real time: gateway fixes, prefix failures, bootstrap attempts, cooldown skips, WAN restarts |

**Prerequisite: install curl**

```sh
apk update && apk add curl
```

### Step A - Create the config file

**File:** `/etc/ipv6-watchdog.conf`

```sh
# Primary webhook: ONT alerts and recovery notices only.
DISCORD_WEBHOOK="https://discord.com/api/webhooks/YOUR_ALERTS_WEBHOOK_HERE"

# Log webhook: all tagged syslog lines in real time.
# Falls back to DISCORD_WEBHOOK if unset.
DISCORD_LOG_WEBHOOK="https://discord.com/api/webhooks/YOUR_LOGS_WEBHOOK_HERE"

chmod 600 /etc/ipv6-watchdog.conf
```

Keep this file out of public repositories as the webhook URLs are secrets.

To create Discord webhooks: open your server, go to Server Settings, then Integrations, then Webhooks, and create one webhook per channel.

### Step B - Deploy the log forwarder

**File:** [`ipv6-discord-logger`](ipv6-discord-logger) → `/usr/bin/ipv6-discord-logger`

Tails `logread -f` and forwards any line tagged with your script names to Discord. No existing scripts need to be modified. Any future scripts using `logger -t` with a watched tag are picked up automatically.

```sh
wget -q https://raw.githubusercontent.com/melskiedev/IPv6-PLDT-OpenWrt/main/ipv6-discord-logger \
  -O /tmp/ipv6-discord-logger.new \
  && sh -n /tmp/ipv6-discord-logger.new \
  && mv /tmp/ipv6-discord-logger.new /usr/bin/ipv6-discord-logger \
  && chmod +x /usr/bin/ipv6-discord-logger
```

The default `WATCH_TAGS` covers this repo's scripts only, including `ipv6-prefix` for the prefix tracker. To forward logs from additional scripts (e.g. `tailscale-watchdog`), add this to `/etc/ipv6-watchdog.conf`:

```sh
WATCH_TAGS="ipv6-setup|ipv6-watchdog|ipv6-prefix|tailscale-watchdog|discord-logger"
```

Then restart the logger to pick up the change:

```sh
/etc/init.d/ipv6-discord-logger restart
```

### Step C - Deploy the init.d service

**File:** [`init.d-ipv6-discord-logger`](init.d-ipv6-discord-logger) → `/etc/init.d/ipv6-discord-logger`

Manages the log forwarder as a procd service with automatic restart. Deploy together with `ipv6-discord-logger` — both ship in the same repo release.

```sh
wget -q https://raw.githubusercontent.com/melskiedev/IPv6-PLDT-OpenWrt/main/init.d-ipv6-discord-logger \
  -O /tmp/init.d-ipv6-discord-logger.new \
  && sh -n /tmp/init.d-ipv6-discord-logger.new \
  && mv /tmp/init.d-ipv6-discord-logger.new /etc/init.d/ipv6-discord-logger \
  && chmod +x /etc/init.d/ipv6-discord-logger
/etc/init.d/ipv6-discord-logger enable
/etc/init.d/ipv6-discord-logger start
```

### Step D - Verify

```sh
ps | grep ipv6-discord-logger
logread | grep discord-logger
```

You should see the process running and a `Log forwarder started` line in the logs. Send a test message to confirm the pipe is working:

```sh
logger -t ipv6-watchdog "Test message from router"
```

This should appear in `#ipv6-logs` within a few seconds.

### Discord sysupgrade additions

If using Discord notifications, add these to your preserve list in addition to the core files:

```sh
cat >> /etc/sysupgrade.conf << 'EOF'
/usr/bin/ipv6-discord-logger
/etc/init.d/ipv6-discord-logger
/etc/ipv6-watchdog.conf
EOF
```

---

## Changelog

### Unreleased — planned v3.9.9

**ipv6-watchdog:**

- Added `REACHABILITY_CONFIRM_DELAY` configuration (default 3 seconds, non-numeric falls back to 3, capped at 30). When the first external-reachability check in `ipv6_ok()` fails, the watchdog waits this delay and re-tests before declaring a Layer-3 failure. Suppresses false-positive transient IPv6 reachability alerts from brief ISP drops that recover within a few seconds.
- `ipv6_ok()` now returns healthy with no log when the delayed confirmation succeeds (transient miss). When both checks fail, it returns failure without logging the external-reachability failure; the confirmed-failure log is emitted later in the main connectivity-failure path only after gateway recovery also fails.
- `fix_gateway()` current-gateway-good path is now silent: when the current gateway passes the follow-up Internet test, it updates `GOOD_GW_FILE` and returns success without the previous "Current gateway ... has internet reachability, no fix needed" notice. This path represents a transient initial miss that would otherwise forward a spurious notice to Discord.
- Main connectivity-failure path: after `fix_gateway()` and the post-fix `ipv6_ok()` validation both fail, emits one confirmed validation log "Validation failed after confirmation: prefix and route exist but internet unreachable" before the existing `FAILS` increment and three-consecutive-failure escalation. The log is gated on both prefix and route still being present, so missing-prefix and missing-route paths retain their existing specific messages without an additional confirmed-failure log.
- The `internet_ok_now()` helper is now used consistently inside `ipv6_ok()` (replacing the previous inline `ping6` pair), keeping the dual-target Google + Cloudflare reachability test identical.

**Repository:**

- Added `tests/test-reachability-confirmation.sh`: dedicated test harness (28 assertions across 9 scenarios) for the reachability confirmation delay behavior, using stateful `ping6` and a recording `sleep` stub. Test 8 verifies the production sanitize/cap logic end-to-end by running the actual watchdog source with four separate configs (unset, non-numeric, 99, 0) and inspecting the recorded confirmation-delay sleep values. Does not modify the existing recovery-hold suite.

### v3.9.8

**ipv6-watchdog:**

- `recovery_hold_active()` now checks an explicit `recovery_hold` file latch in addition to `WAN_RESTARTS >= WAN_RESTART_LIMIT`, ensuring the hold persists even if the restart count is somehow reset mid-boot.
- Hold branch replaced per-tick repeated logging with state-change-only logging: detects 6 passive states (`wan6-down`, `wan6-up-no-device`, `no-prefix`, `prefix-present-no-route`, `prefix-present-unreachable`, `recovered`) and logs only on first entry or state transition.
- `hold_status` file written only on initialization or state change, not every tick.
- `ipv6_ok()` no longer called from hold branch; uses `has_prefix()`, `ip -6 route show`, and `internet_ok_now()` for quiet passive detection.
- `reset_recovery_state()` no longer called from hold mode; WAN restart budget, `ONT_FLAG`, and `recovery_hold` all preserved on spontaneous recovery until router reboot.
- Removed `HOLD_RECOVERED_FLAG` (replaced by `hold_status` state tracking).

**ipv6-prefix-tracker** (new component, added to repo):

- Added as canonical baseline from live router copies (byte-for-byte identical on both routers).
- Hold-aware suppression: when `recovery_hold` file exists, suppresses the repeated "No delegated prefix currently available" log. Does not suppress prefix initialization or change notifications.

**Repository:**

- Added `tests/test-recovery-hold.sh`: portable test harness that stubs router commands and exercises the actual hold logic across 10 scenarios (44 assertions).

### v3.9.6

**ipv6-watchdog:**

- Added same-boot global recovery hold: after `WAN_RESTARTS >= WAN_RESTART_LIMIT` (`3/3` by default), the watchdog performs passive monitoring only until `/tmp/ipv6-watchdog` is cleared by a real router reboot.
- Preserved `WAN_RESTART_FILE` on IPv6 recovery so the full WAN restart budget remains same-boot scoped; non-budget recovery counters still reset.

**ipv6-discord-logger** (component v3.9.6) / **init.d-ipv6-discord-logger:**

- Removed `killall logread` from init.d start/stop; procd owns the logger process without killing unrelated `logread -f` sessions.
- Hardened Discord embed JSON: `tr -d '\n\r\t'` on message, hostname, and tag fields; resolve hostname once before the logread loop.

**README:**

- Clarified repo-release vs per-component versioning (Option A).

### v3.9.5

**ipv6-watchdog:**

- `fix_gateway()` snapshots the full pre-scan default route set (generic and source-specific `default from` routes) before STEP 1 or candidate testing; restores all saved routes when the gateway scan fails.
- Replaced prefix backoff bit-shift with an explicit `PREFIX_FAILS >= 3` guard to avoid 32-bit signed overflow bypassing the 1800s cap.
- `on_exit()` removes stale `fix_gateway_routes.*` snapshot files if the script is killed mid-scan.

### v3.9.4

**ipv6-watchdog:**

- Added `sanitize_int()` for all counter state reads (`FAILS`, `PREFIX_FAILS`, `WAN_RESTARTS`, `PREFIX_NEXT`, `TIER0_FAILS`). Empty or corrupt state files no longer cause silent wrong-branch selection in `-ge`/`-lt` comparisons.
- Added `BOOTSTRAP_UCI_STAGED` flag with unified `on_exit` trap (composes with mkdir lock cleanup) so staged `reqaddress='try'` is reverted if `try_128_bootstrap` is killed mid-run.
- `fix_gateway()` snapshots the pre-scan default gateway and restores it when the candidate loop exhausts without a working gateway.
- Moved cron jitter `sleep` to after the boot grace check so early boot ticks exit immediately without a 5-10s delay.

**README:**

- Document `chmod 600 /etc/ipv6-watchdog.conf` in the watchdog config and Discord setup sections.

### v3.9.3

**ipv6-watchdog:**

- Restored inline documentation from v3.9 (function behavior, PLDT routing notes, bootstrap sequencing, ash function-order note) on top of v3.9.2 logic; no IPv6 behavior changes.
- Added `tr -d '\n\r\t'` to all six Discord JSON escape lines (`MODEL_ESC`, `HOST_ESC`, `FW_ESC`, `REC_*_ESC`) to prevent malformed embeds from stray whitespace in router identity fields.

### v3.9.2

**ipv6-watchdog:**

- Reordered script so all functions are defined before Tier 0 and main recovery logic (BusyBox `ash` safety; fixes v3.9.1 forward-reference bug).
- Added `maybe_wan_restart()` to centralize `WAN_RESTART_LIMIT`, post-restart cooldown, and ONT notification across all full WAN restart paths.
- Tier 0: added `TIER0_FAIL_FILE`; respects global cooldown; escalates to `maybe_wan_restart()` after 3 consecutive soft `wan6` recovery failures.
- Connectivity failure path (`FAILS >= 3`) and no-prefix WAN escalation now call `maybe_wan_restart()` instead of `do_wan_restart()` directly.
- `keep_gateway()` no-MAC fallback requires `internet_ok_now()` before accepting current gateway as baseline; fallback path pins MAC for `current_gw`.
- `fix_gateway()` candidate loop uses `gateway_mac()` (unicast NDP probe) instead of skipping gateways with no immediate MAC entry.
- Added `-W 3` timeout on `ff02::2` all-routers multicast probe.
- `WAN_RESTART_COOLDOWN` and `WAN_RESTART_LIMIT` overridable via `/etc/ipv6-watchdog.conf`.
- `in_cooldown()` validates timestamp is numeric before arithmetic.
- Recovery Discord notice logs curl success or failure.

**97-garp:**

- Reads `LAN_DEV` from `/etc/ipv6-watchdog.conf` (default `br-lan`) for non-default LAN bridge names.

**99-ipv6-setup:**

- Aligned `ff02::2` multicast probe timeout to `-W 3` (matches `ipv6-watchdog`).

### v3.9

**ipv6-watchdog:**

- Added optional sticky gateway feature controlled by `STICKY_GATEWAY` in `/etc/ipv6-watchdog.conf`. Disabled by default (`STICKY_GATEWAY=0`). When enabled on PLDT routers, re-pins the last known-good gateway whenever PLDT's RA replaces it with an alternative. If the preferred gateway fails internet reachability, the current gateway is accepted and saved as the new known-good. Safe to enable independently per router without modifying the script.
- Added `GOOD_GW_FILE="$STATE_DIR/good_gateway"` state file to persist the known-good gateway across cron ticks. Intentionally excluded from `reset_recovery_state()` so the baseline survives prefix failures, WAN restarts, and all other recovery events.
- Added `keep_gateway()` function: runs proactively before `ipv6_ok()` on every tick so it can intercept PLDT's RA gateway swaps before connectivity breaks. Reads known-good gateway from state file, detects route changes, attempts to restore the preferred gateway via `ip -6 route replace` and MAC re-pin, falls back to current gateway if the preferred one fails internet reachability. Baseline seeding is guarded by `internet_ok_now()` to prevent saving a dead gateway as known-good.
- Added `current_default_gw()`, `gateway_mac()`, and `internet_ok_now()` helper functions to support `keep_gateway()` and reduce inline logic duplication.
- Added `sleep 3` settle delay inside `keep_gateway()` after both the successful restore path and the fallback-to-current path, giving the restored route time to stabilize before `ipv6_ok()` runs its reachability ping.
- Fixed `fix_gateway()` current-gateway-good path: now writes `echo "$current" > "$GOOD_GW_FILE"` when the current gateway has internet reachability, seeding the sticky baseline immediately rather than waiting for the next tick.
- Fixed `fix_gateway()` candidate-swap success path: now writes `echo "$gw" > "$GOOD_GW_FILE"` when a replacement gateway is accepted and internet-verified, keeping the sticky baseline in sync with the route table after every successful fix.
- Removed ISP-specific reference from `CLEANUP_WAN128` comment; now describes the condition generically.

### v3.8

**ipv6-watchdog:**

- Fixed `try_128_bootstrap()` sequencing: prefix acquisition loop now runs before `uci revert`, so the check window is active while `reqaddress='try'` is still in effect. Removed the second `ifdown/ifup` flap after revert, which was disrupting a prefix that had just been acquired. `ubus call network reload` alone applies the revert without tearing the interface down again. Replaced `seq`-based loop with `while` loop and extended check window from ~30 seconds to 60 seconds.
- Fixed `try_128_bootstrap()`: added post-revert prefix check after `uci revert` and settle delay to confirm the prefix survived the revert before proceeding to connectivity verification. On PLDT, PD and IA_NA are independent so this should always pass, but the check is cheap insurance against non-standard ISP behavior.
- Fixed `fix_gateway()` success path: now resets all recovery counters including `WAN_RESTART_FILE`, `LAST_WAN_RESTART_FILE`, `ONT_FLAG`, and `PREFIX_BACKOFF_FILE`. Previously only `FAIL_FILE` and `PREFIX_FAIL_FILE` were reset, leaving stale WAN restart counts that could incorrectly advance a recovered router toward the ONT notification limit.
- Added `reset_recovery_state()` helper function: centralizes the full counter reset used in the happy path and gateway fix success path, eliminating duplicated reset blocks.
- Bootstrap success path now calls `reset_recovery_state()` and `cleanup_deprecated_v6()` immediately on return 0, consistent with all other recovery success paths. Previously stale `PREFIX_FAIL_FILE` and `PREFIX_BACKOFF_FILE` state persisted until the next cron tick.
- `in_cooldown()` rewritten to be self-contained: reads `LAST_WAN_RESTART_FILE` internally rather than relying on a top-level variable. Uses `[ -s ]` to distinguish an empty file (written on state reset) from a real timestamp, eliminating the semantic ambiguity of using `0` as a sentinel.
- Cooldown log `REMAINING` calculation now reads the file directly with whitespace stripping and a negative-value guard, matching what `in_cooldown()` sees.
- `/128` address removal in `try_128_bootstrap()` now gates the log line on successful deletion (`2>/dev/null &&`), consistent with how `cleanup_deprecated_v6()` handles address removal.
- Explicit `exit 0` added after `do_wan_restart()` in the connectivity failure path. Every other action path in the script exits explicitly; this was the only implicit fall-through.

**99-ipv6-setup (route fix engine):**

- Added `flock`/`mkdir` lock to prevent overlapping hotplug executions on rapid `wan6` events. The script can run for over 2 minutes during gateway scan; without a lock, repeated `wan6` events could stack up concurrent instances.
- Replaced `seq`-based loops with `while` loops for BusyBox ash portability, matching the watchdog pattern.
- Implemented per-gateway internet reachability testing: installs each candidate route temporarily, tests Google and Cloudflare connectivity, accepts or rejects before moving to the next candidate. Matches `fix_gateway()` behavior in the watchdog. This is the behavior the README had claimed since v3.0 but was not actually implemented until now.
- Added keyword-based `awk` route extraction using `via`/`from` field scanning to handle source-specific route formats correctly, replacing fixed field-position `awk '{print $3}'`.
- Added `CLEANUP_WAN128` toggle sourced from `/etc/ipv6-watchdog.conf` for compatibility with non-PLDT ISPs where a WAN `/128` is a legitimate persistent address.
- Fixed missing prefix handling: script now exits cleanly and defers prefix recovery to `ipv6-watchdog` instead of continuing into gateway selection with no prefix assigned.
- Fixed competing route cleanup to preserve only the winning generic default route, removing source-specific routes pointing to other gateways to leave a clean route state.

**ipv6-discord-logger:**

- Added `--connect-timeout 3 --max-time 8` to `curl` to prevent hangs during network outages, matching the watchdog's Discord `curl` pattern. Without this, a Discord outage during a network failure blocked the log forwarding loop indefinitely.
- Reordered `color_for()` patterns so `"Prefix acquired via bootstrap"` is colored green and `"Bootstrap failed"` is colored red, before the generic `"bootstrap"` orange rule. Previously both matched the orange catch-all.

### v3.7

- Fixed `ipv6-discord-logger` MSG extraction: replaced `cut`-based field splitting and generic `sed` strip with an `extract_msg()` function that strips only known syslog tag prefixes. The old approach stripped legitimate message content like `WAN device:` and `LLA ready:` on single-digit syslog days (e.g. `Jun  3`) due to field count shifting.
- Made `WATCH_TAGS` configurable via `/etc/ipv6-watchdog.conf`. Repo default is `ipv6-setup|ipv6-watchdog|discord-logger`. Override in conf to add tags from other scripts (e.g. `tailscale-watchdog`, `ipv6-prefix`) without modifying the script. `extract_msg()` reads `WATCH_TAGS` dynamically so both grep filtering and tag stripping stay in sync automatically.
- Added `ipv6-discord-logger` and `init.d-ipv6-discord-logger` as separate repo files with wget deploy commands. Optional Discord section moved to the bottom of the README before Changelog.
- Updated disclaimer to personal use tone.

### v3.6

- Added `wget` one-command deploy for `98-wan6-delay`, `99-ipv6-setup`, `ipv6-watchdog`, and optionally `97-garp` via raw GitHub URLs. Scripts download to temp file with `sh -n` syntax check before replacing live files (watchdog only). Cron setup remains a direct command with no file needed.
- Added consolidated one-liner block in Quick Deploy section covering all scripts in order.
- Fixed `try_128_bootstrap()` connectivity check: now accepts Google OR Cloudflare (`2606:4700:4700::1111`), matching `ipv6_ok()` and `fix_gateway()`. Previously only checked Google, which could cause a false connectivity failure during a transient Google-only outage.
- Fixed `fix_gateway()` STEP 1: hoisted external reachability check once before the route-removal loop instead of re-running the same ping pair per route entry. Corrected comment from "unconditionally" to accurately describe conditional behavior.
- Updated recovery Discord payload: now includes Router and Hostname as inline fields, with firmware shown in the footer, matching the identity style used by the ONT alert. Previously the recovery embed was a static string with no device identity, making it ambiguous across multiple routers.

### v3.5

- Added `LAN_DEV="${LAN_DEV:-br-lan}"` configurable LAN bridge device variable, overridable via `/etc/ipv6-watchdog.conf` for portability across routers with different LAN bridge names.
- Added `CLEANUP_WAN128="${CLEANUP_WAN128:-1}"` toggle to guard `/128` cleanup in `try_128_bootstrap()`. Set to `0` on routers where WAN `/128` is a legitimate persistent address rather than a temporary bootstrap artifact.
- Added `CLEANUP_DEPRECATED_LAN="${CLEANUP_DEPRECATED_LAN:-1}"` toggle to control deprecated LAN GUA cleanup behavior per deployment.
- Added `cleanup_deprecated_v6()` function: removes deprecated global IPv6 addresses from the LAN bridge after `ipv6_ok()` confirms IPv6 is healthy. Prevents stale deprecated router-owned LAN addresses from lingering after prefix rotation or LAN suffix changes (e.g. after changing the LAN interface IPv6 suffix from `::1` to `random` or `eui64` in LuCI Advanced Settings). Called in both the initial happy path and after successful `fix_gateway()` recovery.
- Fixed prefix backoff timer surviving full WAN restart: `do_wan_restart()` now removes `PREFIX_BACKOFF_FILE` so the next recovery cycle is not delayed by a stale backoff timestamp.
- Added `rm -f "$PREFIX_BACKOFF_FILE"` to the happy path to clear stale backoff on full IPv6 recovery.
- Updated Advanced Notes DUID section: pinning `network.wan6.clientid` is now documented as recommended practice for PLDT prefix stability, with capture instructions, per-router uniqueness warning, and sysupgrade guidance.

### v3.4

- Added `flock`/`mkdir` lock fallback: when `flock` is unavailable, a `mkdir`-based lock is used with a `cleanup_lock` function and per-signal traps (`EXIT`, `INT 130`, `TERM 143`) for correct BusyBox ash behavior on OpenWrt images where `flock` may be absent.
- Hardened `fix_gateway()` route parsing to keyword-based `via`/`from` extraction using `awk` loops, replacing fixed field positions that could break on non-standard route output shapes.
- Fixed `try_128_bootstrap()` restore: replaced `uci set network.wan6.reqaddress='none'` with `uci revert network.wan6.reqaddress` to correctly discard the staged `try` delta without issuing a commit from within the watchdog.
- Added `--connect-timeout 3 --max-time 8` to both Discord `curl` calls to prevent network stalls from holding the lock and blocking cron cycles during outage conditions.

### v3.3

- Fixed `fix_gateway()` false failure counter: healthy-gateway path now resets `FAIL_FILE` and returns `0` instead of `1`, preventing a spurious `Connectivity failure 1` log entry after the current gateway was already confirmed reachable.
- Fixed `fix_gateway()` NDP timing: candidate list is now built after the all-routers multicast probe instead of before it, so gateways that respond to `ff02::2` are captured in the initial scan. Candidates are rebuilt a second time after unicast probes, giving NDP a full two-pass window to populate MAC entries before the scan runs.
- Added direct unicast probe to each candidate gateway between the multicast probe and the final scan, triggering per-gateway neighbor solicitation to reduce false "no MAC, skipping" cycles after PLDT prefix changes.
- Added `echo 0 > "$FAIL_FILE"` to the successful gateway replacement path inside the scan loop, ensuring the counter resets immediately on success.

### v3.2

- Added all-routers multicast probe (`ping6 ff02::2`) inside `fix_gateway()` before the candidate scan, refreshing NDP/MAC state to reduce false "no MAC" skip results after PLDT RA/NDP flaps.
- Expanded `fix_gateway()` candidate loop to combine neighbor table (`router` flag entries) and existing route table gateways, matching the dual-source approach already used in `99-ipv6-setup`. Prevents overlooking a gateway that exists in the route table but is not currently flagged `router` in the neighbor table.

### v3.1

- Updated Step 1 UCI config: `device='eth1'` changed to `device='@wan'` to tie `wan6` to the `wan` interface lifecycle rather than a hardcoded device name.
- Added `force_link='1'`, `multipath='off'`, and `sourcefilter='0'` to `network.wan6`. These were confirmed required during multi-unit replication testing.
- Added `network.globals` settings: `rpfilter='0'` and `ipv6_sourcefilter='1'`.
- Added full `dhcp.lan` IPv6 block to Step 1: `dhcpv6`, `ra`, `ra_slaac`, `ra_default`, `ra_preference`, `force`, `ndp`.
- Added safe LAN reload note: never restart LAN interface while odhcpd holds an active delegated prefix; use `ubus call network reload` and `odhcpd restart` instead.
- Added Force NDP discovery command to Troubleshooting section.
- Added Safe LAN config reload command to Troubleshooting section.
- Added `fix_gateway()` internet reachability validation note to Validated Behavior.
- Added LAN clients IPv6 row to Final Result table.

### v3.0

- Rewrote `fix_gateway()` to validate internet reachability per candidate gateway instead of trusting local link-local ping. PLDT gateways may respond locally but fail to forward internet traffic, so each candidate is temporarily installed and accepted only if external IPv6 reachability succeeds.
- Added 120-second boot grace period to `ipv6-watchdog` to prevent Tier 0 from racing with `98-wan6-delay` and `99-ipv6-setup` during boot initialization.
- `fix_gateway()` now removes dead PLDT prefix-specific routes before checking the generic default gateway.
- `99-ipv6-setup` upgraded with dual-target connectivity check (Google + Cloudflare) before removing the `/128`. The check runs once after selecting the first locally-responsive gateway. Per-gateway internet reachability testing (install route, test, accept/reject per candidate) was added in v3.8.
- Added `97-garp` hotplug script to send gratuitous ARP on `br-lan` ifup, forcing LAN clients to update ARP cache after router swap.
- Updated `ipv6-discord-logger`: timestamp changed to 12-hour AM/PM format, syslog prefix stripped from embed, hostname shown in footer.
- Improved wan6 startup delay: replaced 5s fixed delay with 15s and added forced `ifdown wan6` reset before delay to prevent DHCPv6 pending state at boot.

### v2.0

- Added layered `ipv6_ok` validation: checks prefix, default route, and reachability in sequence. Logs specific failure reason for faster debugging.
- Added `dhcpv6_renew` as new escalation tier between wan6 restart and `/128` bootstrap. Sends DHCPv6 Renew to ISP without tearing down interface state.
- Escalation ladder expanded from three to four tiers: wan6 restart, DHCPv6 renew, `/128` bootstrap, full WAN restart.
- Added `flock` to watchdog to prevent overlapping cron executions during bootstrap or WAN restart.
- MAC pinning via `ip -6 neigh replace ... nud stale` added to both `99-ipv6-setup` and watchdog `fix_gateway`.
- `99-ipv6-setup` upgraded with dual gateway sourcing, detailed logging, and dual-target connectivity check.
- `notify_ont_powercycle` now reads router model, hostname, and firmware dynamically with `/proc/cpuinfo` fallback.
- Added optional Discord notification system through `ipv6-discord-logger`.
- Added ONT powercycle notification with notify-once flag to prevent Discord spam.
- Added post-restart cooldown and per-step exponential backoff to avoid DHCPv6 hammering.
- Added Tier 0 wan6 down recovery before prefix or route checks execute.
- Replaced wan6 already-up guard with forced reset and extended delay to prevent DHCPv6 pending state at boot.

### v1.0

- Initial release: UCI config, `98-wan6-delay`, `99-ipv6-setup`, `ipv6-watchdog`, cron setup.
- Fixes PLDT `/128` IA_NA drop, dead RA gateway selection, wan6 startup race condition, and RA runtime override.
