# IPv6 Fix Guide: GL.iNet GL-MT6000 (Flint 2) on PLDT Fiber (Bridge Mode)

[![OpenWrt](https://img.shields.io/badge/OpenWrt-25.x-blue)](#)
[![ISP](https://img.shields.io/badge/ISP-PLDT%20Fiber-informational)](#)
[![Status](https://img.shields.io/badge/Status-Production--Ready-success)](#)
[![Version](https://img.shields.io/badge/Version-v3.10.2-blue)](#)

**Device:** GL.iNet GL-MT6000 (Flint 2) | **Firmware:** OpenWrt 25.12.5 (vanilla OpenWrt) | **ISP:** PLDT Fiber (Bridge mode) | **WAN:** `eth1` | **Mode:** DHCPv6 + Prefix Delegation | **Version:** v3.10.2

A production-grade IPv6 setup for PLDT Fiber subscribers running OpenWrt in bridge mode, with bounded self-healing: it recovers from transient faults on its own, and stops rather than looping when a fault is not on the router.

Includes root-cause analysis, startup fixes, runtime route and gateway repair, router source selection policy, coordinated recovery, and real-world edge cases observed in production use.

> **Personal use, shared openly.** This is my own home network fix that I'm sharing in case it helps someone else. I run this on my own routers daily. Use it at your own risk, adapt it as needed, and always take a sysupgrade backup before applying anything.

---

## TL;DR

Fiber in bridge mode, IPv6 unstable or broken: apply UCI config, deploy the core scripts, add cron, reboot, verify.

Health is decided by the delegated prefix (`IA_PD`), not by the WAN `/128`. A WAN `/128` is optional and its presence is not a fault. Where the router picks an unusable `/128` as its own source address, source policy corrects the source instead of deleting the address.

The three core v3.10.0 components:

- **`wan-recovery-common`** coordinates any disruptive WAN action. Install it first; the watchdog fails closed without it.
- **`99-ipv6-setup`** repairs routes and gateway on `wan6` ifup, without ever restarting an interface.
- **`ipv6-watchdog`** runs every minute, decides health, applies source policy, and escalates only as far as it must.

Recovery is bounded: it is serialized by a shared lock, limited by a per-boot disruption budget, spaced by a cooldown, and latches into a passive hold rather than restarting WAN forever.

Optional and supporting pieces (`97-garp`, `ipv6-prefix-tracker`, the Discord logger) are covered further down. Full instructions below.

---

## Read Before Applying

> **This is not a generic IPv6 guide.** It targets a specific failure pattern observed on PLDT Fiber in bridge mode. Applying it to a different setup may break working IPv6.

Use this guide only if:

- You are on PLDT Fiber (or an ISP with similar RA gateway and prefix delegation behavior)
- Your ONT is in bridge mode and OpenWrt is the first-hop edge router
- You observe one or more of: incorrect or dead RA gateway selection, intermittent IPv6 loss after boot, delegated prefix acquisition failures, or working LAN IPv6 while the router's own IPv6 tests fail

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

> **Installation integrity is not health.** Every file can be installed
> correctly, with the right modes and a running cron job, while IPv6 is still
> broken. Section A proves the software is in place. Sections B onward prove the
> network actually works. Run both.

### Shared context

Several checks need the same values. Collect them once. These are read the same
way the implementation reads them.

```sh
WAN_DEV="$(ubus call network.interface.wan6 status 2>/dev/null \
  | jsonfilter -e '@["l3_device"]')"
PD_ADDR="$(ubus call network.interface.wan6 status 2>/dev/null \
  | jsonfilter -e '@["ipv6-prefix"][0].address')"
PD_MASK="$(ubus call network.interface.wan6 status 2>/dev/null \
  | jsonfilter -e '@["ipv6-prefix"][0].mask')"
LAN_DEV="br-lan"

echo "WAN_DEV = ${WAN_DEV:-<none>}"
echo "PD      = ${PD_ADDR:-<none>}/${PD_MASK:-<none>}"
```

Example output, using RFC 3849 documentation space:

```
WAN_DEV = eth1
PD      = 2001:db8:abcd:ee00::/56
```

If `WAN_DEV` is empty, `wan6` is not up and nothing below will pass.

---

### A. Installation integrity

Proves the software is installed. Proves nothing about connectivity.

```sh
# Files present, with modes
ls -l /usr/bin/wan-recovery-common \
      /usr/bin/ipv6-watchdog \
      /etc/hotplug.d/iface/99-ipv6-setup

# Expected: coordinator 0644 (sourced library), other two 0755

# Syntax of the installed copies
sh -n /usr/bin/wan-recovery-common       && echo "coordinator syntax ok"
sh -n /usr/bin/ipv6-watchdog             && echo "watchdog syntax ok"
sh -n /etc/hotplug.d/iface/99-ipv6-setup && echo "hotplug syntax ok"
```

The coordinator interface the watchdog requires:

```sh
for fn in wan_recovery_full_begin \
          wan_recovery_full_execute_locked \
          wan_recovery_wan6_begin \
          wan_recovery_wan6_record_locked \
          wan_recovery_end \
          wan_recovery_cleanup; do
    grep -q "^${fn}()" /usr/bin/wan-recovery-common \
      && echo "ok      $fn" \
      || echo "MISSING $fn"
done
```

Any `MISSING` line means the watchdog will fail closed: it keeps monitoring and
repairing routes, but performs no disruptive recovery.

Cron, present exactly once and running:

```sh
grep -c '^\*/1 \* \* \* \* /usr/bin/ipv6-watchdog$' /etc/crontabs/root
# Expected: 1   (0 means missing, 2+ means duplicated)

/etc/init.d/cron status || ps | grep '[c]rond'
```

---

### B. Network health (the decisive checks)

Household IPv6 health is decided by the delegated prefix and by traffic sourced
from it. Work through these in order; each depends on the one before.

#### B1. IA_PD is present

```sh
ubus call network.interface.wan6 status | jsonfilter -e '@["ipv6-prefix"][0].address'
ubus call network.interface.wan6 status | jsonfilter -e '@["ipv6-prefix"][0].mask'
```

**Pass:** both return a value, for example `2001:db8:abcd:ee00` and `56`.
**Fail:** empty output means no delegated prefix. Nothing downstream can pass.

Do not confuse this with IA_NA. They come from different parts of the same
DHCPv6 status:

```sh
# Delegated prefix (IA_PD) -> what LAN IPv6 is built from
ubus call network.interface.wan6 status | jsonfilter -e '@["ipv6-prefix"]'

# Address assigned to the router itself (IA_NA) -> optional
ubus call network.interface.wan6 status | jsonfilter -e '@["ipv6-address"]'
```

`ipv6-prefix` is required. `ipv6-address` is optional and may legitimately be
empty.

#### B2. A PD-derived LAN global source exists

This address is what the health model tests with. It must be a global address
on the LAN bridge that falls **inside the delegated prefix**, and must not be
link-local, unique-local, deprecated, tentative, or dadfailed.

The simplest reliable way to see the exact value the watchdog selected is to
read it from the source-policy cache key, which stores it as field 3:

```sh
cut -d'|' -f3 /tmp/ipv6-watchdog/src_policy_key 2>/dev/null
```

If that file does not exist yet (the watchdog has not classified since boot),
inspect the candidates directly:

```sh
ip -6 addr show dev "$LAN_DEV" scope global \
  | grep -v -e deprecated -e tentative -e dadfailed
```

Example output:

```
inet6 2001:db8:abcd:ee00::1/64 scope global dynamic noprefixroute
```

**Pass:** at least one global address whose prefix matches `PD_ADDR/PD_MASK`.
**Fail:** only `fe80::` (link-local) or `fd00::/8` (unique-local) addresses.
Those are never valid PD sources, so a grep for any global LAN address is not a
sufficient test.

Capture it for the checks below:

```sh
LAN_PD_SRC="$(cut -d'|' -f3 /tmp/ipv6-watchdog/src_policy_key 2>/dev/null)"
echo "LAN_PD_SRC = ${LAN_PD_SRC:-<not set, fill in manually>}"
```

#### B3. A generic default route exists

```sh
ip -6 route show default
```

Example output:

```
default via fe80::1 dev eth1 proto static metric 512 pref medium
default from 2001:db8:abcd:ee00::/56 via fe80::1 dev eth1 metric 512
```

**Do not require exactly one line.** Both lines above are fine.

- The **generic default** is the line that begins `default via` with **no**
  `from` clause. This one is required.
- A line beginning `default from <prefix>` is a **source-specific** default.
  It is optional. Where one exists it is maintained; it is never required and
  never created from nothing.

To isolate the generic default:

```sh
ip -6 route show default | grep -v ' from '
```

**Pass:** at least one generic default on the WAN device.
**Fail:** no output.

Route shape alone does not prove health. B4 is the real test.

#### B4. Effective routing from the PD source

This is the decisive routing check. It asks the kernel how a packet **from the
PD-derived source** would actually be routed, rather than inspecting the table.

```sh
ip -6 route get 2001:4860:4860::8888 from "$LAN_PD_SRC"
```

Example output:

```
2001:4860:4860::8888 from 2001:db8:abcd:ee00::1 via fe80::1 dev eth1 src 2001:db8:abcd:ee00::1 metric 512
```

Inspect three things:

- **`dev`** must be the WAN device from `$WAN_DEV`. If it shows the LAN bridge
  or a tunnel, routing is wrong.
- **`via`** is the gateway in use. Its presence is normal; the exact value is
  your provider's link-local gateway.
- **`src`** is the source the kernel will use for that path.

**Fail** if the output contains `unreachable`, `prohibit`, `blackhole`, or
`throw`, or if `dev` is not the WAN device.

`2606:4700:4700::1111` works equally well as the probe target. Both are public
anycast DNS addresses used by the implementation itself.

#### B5. PD-source reachability (decisive)

```sh
ping6 -c 2 -W 3 -I "$LAN_PD_SRC" 2001:4860:4860::8888
ping6 -c 2 -W 3 -I "$LAN_PD_SRC" 2606:4700:4700::1111
```

`-I` binds the probe to the PD-derived source, which is the whole point. An
unbound `ping6` proves nothing about household health, because the kernel may
choose a different source address for it.

**Pass:** either target replies. This is the decisive test for household IPv6.
**Fail:** both fail. IPv6 is unhealthy regardless of anything else on this page.

---

### C. IA_NA and router source policy

#### C1. Is a WAN /128 present at all?

```sh
ip -6 addr show dev "$WAN_DEV" | grep '/128 scope global'
```

Empty output means no IA_NA. **That is perfectly acceptable** and needs no
action.

#### C2. If present, is it usable?

```sh
WAN128="$(ip -6 addr show dev "$WAN_DEV" \
  | awk '/inet6 .*\/128 scope global/{print $2}' | sed 's|/128$||' | head -1)"
echo "WAN128 = ${WAN128:-<none>}"

[ -n "$WAN128" ] && ping6 -c 2 -W 3 -I "$WAN128" 2001:4860:4860::8888
```

Interpretation:

| IA_NA state | Meaning | Expected policy |
|---|---|---|
| Absent | Acceptable. Health rests on the PD path | `native` |
| Present and usable | Acceptable. The kernel is already choosing well | `native` |
| Present, unusable, PD path passes | Acceptable after correction. Router source selection is the only problem | `pd-preferred` |
| Present, unusable, PD path also fails | Not a source-policy problem. Diagnose the PD path using section B | no policy action |

An IA_NA failure on its own is never a full-stack failure and never consumes
recovery budget.

#### C3. Router-default reachability

This is the unbound test, deliberately separate from B5:

```sh
ping6 -c 2 -W 3 2001:4860:4860::8888
```

This can fail while B5 passes. That is the exact situation source policy exists
to fix: the kernel selected an unusable IA_NA as the router's source. Once
`pd-preferred` is in effect, the router uses the PD-derived source and this test
should pass too.

#### C4. Source-policy state

```sh
cat /tmp/ipv6-watchdog/src_policy_mode         # native | pd-preferred
cat /tmp/ipv6-watchdog/src_policy_managed_src  # source the watchdog installed
cat /tmp/ipv6-watchdog/src_policy_ts           # last classification, epoch seconds
cut -d'|' -f1-4 /tmp/ipv6-watchdog/src_policy_key
```

The cache key is `WAN128|PD_CIDR|LAN_PD_SRC|gateway`. Any change to those four
forces immediate reclassification.

Expected combinations:

| Mode | `src_policy_managed_src` | Meaning |
|---|---|---|
| `native` | empty or absent | Normal. No source is imposed |
| `pd-preferred` | matches the PD-derived source | The watchdog installed and owns that source |
| `pd-preferred` | empty | The route already carried the right source, so the watchdog did **not** claim ownership. Also normal |

That last row is deliberate. If an administrator already set the source, the
watchdog uses it but never claims it.

Confirm the source is actually in effect:

```sh
ip -6 route show default | grep -v ' from '
ip -6 route get 2001:4860:4860::8888
```

In `pd-preferred` the generic default carries a `src` matching the PD-derived
address, and the unbound route lookup selects it.

#### C5. Ownership safety (advanced)

If `src_policy_managed_src` is non-empty, the generic default route's `src`
should match it.

If they differ, something outside the watchdog changed the route. The ownership
rules are designed for exactly this: the watchdog **preserves the external
change and releases its own claim** rather than overwriting it. A mismatch is
therefore evidence the safety rule worked, not a fault to repair.

Do not delete source-policy state files as part of routine verification.

---

### D. Recovery coordination state

```sh
ls -l /tmp/wan-recovery/ 2>/dev/null || echo "no shared state yet"
```

**An empty or missing directory is normal** on a healthy router that has never
needed disruptive recovery.

```sh
cat /tmp/wan-recovery/disruption_count         2>/dev/null || echo "0 (none yet)"
cat /tmp/wan-recovery/last_full_wan_disruption 2>/dev/null || echo "never"
cat /tmp/wan-recovery/last_wan6_action         2>/dev/null || echo "never"
cat /tmp/wan-recovery/last_full_wan_reason     2>/dev/null || echo "none"
cat /tmp/wan-recovery/last_wan6_reason         2>/dev/null || echo "none"

[ -f /tmp/wan-recovery/disruption_hold ] \
  && echo "HOLD ACTIVE: disruptive recovery is blocked until reboot" \
  || echo "no hold (expected on a healthy router)"
```

On a healthy fresh deployment:

- `disruption_count` absent or `0`, and **not rising** over time
- no hold file
- timestamps absent

A rising `disruption_count` means full-WAN recovery is actually firing, which
points at a real connectivity problem rather than an installation issue.

---

### E. Logs

```sh
logread | grep ipv6-watchdog | tail -20
logread | grep ipv6-setup | tail -20
logread | grep -i "Router source policy" | tail -10
```

Useful lines look like:

```
Router source policy: native -> pd-preferred (WAN128 Internet failed, PD Internet OK)
Router source policy: installed preferred src ... on default via ...
Router source policy: restored preferred src ... (silently removed by route refresh)
```

> **BusyBox cron logs job launches at `cron.err` priority.** Seeing
> `ipv6-watchdog` lines at that priority is normal cron behavior, not a
> watchdog error. Judge health by the watchdog's own messages, not by the
> priority cron used to announce the job.

---

### F. Health result matrix

This summary covers layers 1, 2 and 5 plus IA_NA state. It assumes the generic
default route check in B3 and the effective route check in B4 also pass. If
either of those fails, the verdict is unhealthy regardless of the row below,
and B3 or B4 identifies what to repair.

| IA_PD | LAN PD source | PD-source Internet | IA_NA | Interpretation |
|---|---|---|---|---|
| absent | n/a | n/a | any | **Unhealthy.** No delegated prefix. Route repair cannot help |
| present | absent | n/a | any | **Unhealthy.** No PD-derived LAN source; check `ip6assign` and `ip6class` |
| present | present | FAIL | any | **Unhealthy.** The PD path is broken. IA_NA state is irrelevant |
| present | present | PASS | absent | **Healthy.** Policy `native`. A missing `/128` is not a fault |
| present | present | PASS | present, usable | **Healthy.** Policy `native`. The kernel is already choosing correctly |
| present | present | PASS | present, unusable | **Healthy PD path.** Policy should be `pd-preferred` so router-originated traffic uses the PD source |

The decisive column is PD-source Internet. IA_NA never changes a healthy verdict
into an unhealthy one, and never rescues an unhealthy one.

---

## Table of Contents

**Getting started**

- [TL;DR](#tldr)
- [Read Before Applying](#read-before-applying)
- [Post-Deploy Verification](#post-deploy-verification)
- [Quick Deploy (Core v3.10)](#quick-deploy-core-v310)
- [Optional and Supporting Components](#optional-and-supporting-components)
- [Upgrading an Existing Installation](#upgrading-an-existing-installation)
- [Rollback](#rollback)
- [Compatibility](#compatibility)
- [Caution: Bridge Mode and Third-Party Router Setups](#caution-bridge-mode-and-third-party-router-setups)

**Architecture (v3.10.0)**

- [Root Causes](#root-causes)
- [Architecture Overview (v3.10.0)](#architecture-overview-v3100)
- [PD-First Health Model](#pd-first-health-model)
- [Router Source Policy](#router-source-policy)
- [Gateway and Route Repair](#gateway-and-route-repair)
- [Recovery Coordination](#recovery-coordination)
- [Startup and Steady State](#startup-and-steady-state)
- [State Ownership](#state-ownership)

**Setup and reference**

- [Configuration](#configuration)
- [Component Reference](#component-reference)
- [Optional and Supporting Component Behavior](#optional-and-supporting-component-behavior)

**Operations and reference**

- [Recovery Hold Detail](#recovery-hold-detail)
- [Troubleshooting](#troubleshooting)
- [State File Reference](#state-file-reference)
- [Validated Behavior](#validated-behavior)
- [Regression Tests](#regression-tests)
- [Preserving Scripts Across Firmware Upgrades](#preserving-scripts-across-firmware-upgrades)
- [Known Edge Cases](#known-edge-cases)
- [Advanced Notes: DUID and ULA](#advanced-notes-duid-and-ula)
- [Optional: Discord Notifications](#optional-discord-notifications)
- [Changelog](#changelog)

---

## Quick Deploy (Core v3.10)

Installing files is non-disruptive. Nothing in this section restarts WAN,
`wan6`, or the network, and nothing reboots the router. Bringing the new
behavior into effect is covered by verification later on.

### Prerequisites

The core stack needs **no extra packages**. Everything it uses (`ip`, `ubus`,
`jsonfilter`, `ping6`, `logger`, BusyBox `wget`) is present in a standard
OpenWrt image.

Install these only if you want the thing they support:

```sh
apk update

# Only if you plan to use the curl download examples,
# the Discord logger, or prefix-change notifications
apk add curl

# Only if you plan to install 97-garp
apk add iputils-arping
```

Working IPv4 is required for `apk`. A fresh OpenWrt flash provides it over the
default DHCP WAN.

### Download source

Define these once per shell session. Every block below reuses them.

```sh
OWNER="melskiedev"
REPO="IPv6-PLDT-OpenWrt"

# main tracks the latest published code:
REF="main"

# Or pin to an existing release tag for a reproducible install:
# REF="<release-tag>"

BASE="https://raw.githubusercontent.com/$OWNER/$REPO/$REF"
echo "$BASE"
```

`main` tracks the latest published code. For a reproducible deployment, set
`REF` to an existing release tag instead, so the same files can be installed
again later. Do not install from a development or feature branch.

### Install order, and why it matters

```
  1. wan-recovery-common   ->  /usr/bin/wan-recovery-common
  2. 99-ipv6-setup         ->  /etc/hotplug.d/iface/99-ipv6-setup
  3. ipv6-watchdog         ->  /usr/bin/ipv6-watchdog
  4. watchdog cron entry
  5. installation integrity check
```

Step 1 must come before step 3. At startup `ipv6-watchdog` sources
`/usr/bin/wan-recovery-common` and verifies the coordinator interface it needs
is complete. If the coordinator is missing, unreadable, or incomplete, the
watchdog marks disruptive recovery unavailable and **fails closed**: it keeps
monitoring, logging, and repairing routes, but it will not restart an
interface on its own.

Installing the watchdog first is not dangerous, it simply leaves it in
monitoring-only mode until the coordinator appears. Installing in the order
above avoids that window entirely.

`99-ipv6-setup` has no dependency on the coordinator (it is non-disruptive by
design), so its position is a convention rather than a constraint.

### Core install, wget (primary)

Each block downloads to `/tmp`, validates, sets the mode, then moves the file
into place. A failed download or a failed check leaves the existing installed
file untouched.

```sh
# 1. wan-recovery-common  (sourced library, not executable)
wget -q -O /tmp/wan-recovery-common.new "$BASE/wan-recovery-common" \
  && sh -n /tmp/wan-recovery-common.new \
  && chmod 0644 /tmp/wan-recovery-common.new \
  && mv /tmp/wan-recovery-common.new /usr/bin/wan-recovery-common \
  && echo "coordinator installed" \
  || echo "FAILED: coordinator not installed"
```

```sh
# 2. 99-ipv6-setup  (hotplug script, executable)
wget -q -O /tmp/99-ipv6-setup.new "$BASE/99-ipv6-setup" \
  && sh -n /tmp/99-ipv6-setup.new \
  && chmod 0755 /tmp/99-ipv6-setup.new \
  && mv /tmp/99-ipv6-setup.new /etc/hotplug.d/iface/99-ipv6-setup \
  && echo "hotplug helper installed" \
  || echo "FAILED: hotplug helper not installed"
```

```sh
# 3. ipv6-watchdog  (cron script, executable)
wget -q -O /tmp/ipv6-watchdog.new "$BASE/ipv6-watchdog" \
  && sh -n /tmp/ipv6-watchdog.new \
  && chmod 0755 /tmp/ipv6-watchdog.new \
  && mv /tmp/ipv6-watchdog.new /usr/bin/ipv6-watchdog \
  && echo "watchdog installed" \
  || echo "FAILED: watchdog not installed"
```

```sh
# 4. watchdog cron entry (idempotent)
grep -qxF '*/1 * * * * /usr/bin/ipv6-watchdog' /etc/crontabs/root \
  || echo '*/1 * * * * /usr/bin/ipv6-watchdog' >> /etc/crontabs/root
/etc/init.d/cron restart
```

### Core install, curl (alternative)

Identical except for the download command. `-f` makes curl fail on an HTTP
error instead of writing an error page to disk, and `-L` follows redirects.

```sh
curl -fL "$BASE/wan-recovery-common" -o /tmp/wan-recovery-common.new \
  && sh -n /tmp/wan-recovery-common.new \
  && chmod 0644 /tmp/wan-recovery-common.new \
  && mv /tmp/wan-recovery-common.new /usr/bin/wan-recovery-common \
  && echo "coordinator installed" \
  || echo "FAILED: coordinator not installed"

curl -fL "$BASE/99-ipv6-setup" -o /tmp/99-ipv6-setup.new \
  && sh -n /tmp/99-ipv6-setup.new \
  && chmod 0755 /tmp/99-ipv6-setup.new \
  && mv /tmp/99-ipv6-setup.new /etc/hotplug.d/iface/99-ipv6-setup \
  && echo "hotplug helper installed" \
  || echo "FAILED: hotplug helper not installed"

curl -fL "$BASE/ipv6-watchdog" -o /tmp/ipv6-watchdog.new \
  && sh -n /tmp/ipv6-watchdog.new \
  && chmod 0755 /tmp/ipv6-watchdog.new \
  && mv /tmp/ipv6-watchdog.new /usr/bin/ipv6-watchdog \
  && echo "watchdog installed" \
  || echo "FAILED: watchdog not installed"
```

### Why the coordinator gets an extra check

`sh -n` proves the library parses. It does not prove the library still exposes
the interface the watchdog requires. Check that separately, without executing
the file:

```sh
for fn in wan_recovery_full_begin \
          wan_recovery_full_execute_locked \
          wan_recovery_wan6_begin \
          wan_recovery_wan6_record_locked \
          wan_recovery_end \
          wan_recovery_cleanup; do
    if grep -q "^${fn}()" /usr/bin/wan-recovery-common; then
        echo "ok      $fn"
    else
        echo "MISSING $fn"
    fi
done
```

Any `MISSING` line means the watchdog will fail closed and perform no
disruptive recovery. This is a text inspection: it never sources or runs the
library.

### Installation integrity check

This confirms the files are installed correctly. It says nothing about whether
IPv6 is working; that is a separate matter covered under verification.

```sh
# Files present, with modes
ls -l /usr/bin/wan-recovery-common \
      /usr/bin/ipv6-watchdog \
      /etc/hotplug.d/iface/99-ipv6-setup

# Expected:
#   wan-recovery-common      rw-r--r--  (0644, sourced library)
#   ipv6-watchdog            rwxr-xr-x  (0755)
#   99-ipv6-setup            rwxr-xr-x  (0755)

# Syntax of installed copies
sh -n /usr/bin/wan-recovery-common && echo "coordinator syntax ok"
sh -n /usr/bin/ipv6-watchdog       && echo "watchdog syntax ok"
sh -n /etc/hotplug.d/iface/99-ipv6-setup && echo "hotplug syntax ok"

# Cron entry present and cron running
grep -n 'ipv6-watchdog' /etc/crontabs/root
/etc/init.d/cron status || ps | grep '[c]rond'

# Component versions, useful when reporting problems
grep -m1 '^# v' /usr/bin/ipv6-watchdog /etc/hotplug.d/iface/99-ipv6-setup
```

Once cron is running, the watchdog executes every minute and its activity
appears in the system log:

```sh
logread | grep ipv6-watchdog | tail -20
logread | grep ipv6-setup | tail -20
```

---

## Optional and Supporting Components

These are separate from the core stack. Install only what you want.

### 97-garp (OPTIONAL)

Sends a gratuitous ARP on LAN bridge ifup so LAN clients refresh their ARP
cache after a router swap. Useful only if you replace routers and reuse the
same LAN IP.

**Destination:** `/etc/hotplug.d/iface/97-garp`, executable
**Requires:** `iputils-arping` (`arping`); reads optional `LAN_DEV` from
`/etc/ipv6-watchdog.conf`, defaulting to `br-lan`

```sh
apk add iputils-arping

# wget
wget -q -O /tmp/97-garp.new "$BASE/97-garp" \
  && sh -n /tmp/97-garp.new \
  && chmod 0755 /tmp/97-garp.new \
  && mv /tmp/97-garp.new /etc/hotplug.d/iface/97-garp \
  && echo "97-garp installed" \
  || echo "FAILED: 97-garp not installed"

# curl
curl -fL "$BASE/97-garp" -o /tmp/97-garp.new \
  && sh -n /tmp/97-garp.new \
  && chmod 0755 /tmp/97-garp.new \
  && mv /tmp/97-garp.new /etc/hotplug.d/iface/97-garp \
  && echo "97-garp installed" \
  || echo "FAILED: 97-garp not installed"
```

No cron or service step. It runs from hotplug on LAN bridge ifup.

### ipv6-prefix-tracker (SUPPORTING)

Observational only. Logs when the delegated prefix is first seen or changes,
and reloads odhcpd on a change so LAN clients get updated RA without waiting
for the next interval. It performs no recovery and never restarts an interface.

**Destination:** `/usr/bin/ipv6-prefix-tracker`, executable
**State file:** `/etc/ipv6-prefix-current`
**Schedule:** every 5 minutes
**Requires:** nothing mandatory; uses `curl` only if a webhook is configured

```sh
# wget
wget -q -O /tmp/ipv6-prefix-tracker.new "$BASE/ipv6-prefix-tracker" \
  && sh -n /tmp/ipv6-prefix-tracker.new \
  && chmod 0755 /tmp/ipv6-prefix-tracker.new \
  && mv /tmp/ipv6-prefix-tracker.new /usr/bin/ipv6-prefix-tracker \
  && echo "prefix tracker installed" \
  || echo "FAILED: prefix tracker not installed"

# curl
curl -fL "$BASE/ipv6-prefix-tracker" -o /tmp/ipv6-prefix-tracker.new \
  && sh -n /tmp/ipv6-prefix-tracker.new \
  && chmod 0755 /tmp/ipv6-prefix-tracker.new \
  && mv /tmp/ipv6-prefix-tracker.new /usr/bin/ipv6-prefix-tracker \
  && echo "prefix tracker installed" \
  || echo "FAILED: prefix tracker not installed"

# cron entry (idempotent)
grep -qxF '*/5 * * * * /usr/bin/ipv6-prefix-tracker' /etc/crontabs/root \
  || echo '*/5 * * * * /usr/bin/ipv6-prefix-tracker' >> /etc/crontabs/root
/etc/init.d/cron restart
```

### ipv6-discord-logger and its service (OPTIONAL)

Forwards tagged syslog lines to a webhook in real time.

**Destinations:** `/usr/bin/ipv6-discord-logger` and
`/etc/init.d/ipv6-discord-logger`, both executable
**Requires:** `curl`, plus a webhook configured in `/etc/ipv6-watchdog.conf`

Create the config first. The logger exits immediately if no webhook is set.

```sh
touch /etc/ipv6-watchdog.conf
chmod 0600 /etc/ipv6-watchdog.conf
```

Then add your own webhook values to that file. Use placeholders here and
substitute your real values locally:

```sh
# /etc/ipv6-watchdog.conf
DISCORD_WEBHOOK="<your-webhook-url>"
DISCORD_LOG_WEBHOOK="<your-log-webhook-url>"   # optional, falls back to the above
```

> Never publish this file, paste it into an issue, or include it in a shared
> backup. Keep it at mode `0600`.

```sh
# wget
wget -q -O /tmp/ipv6-discord-logger.new "$BASE/ipv6-discord-logger" \
  && sh -n /tmp/ipv6-discord-logger.new \
  && chmod 0755 /tmp/ipv6-discord-logger.new \
  && mv /tmp/ipv6-discord-logger.new /usr/bin/ipv6-discord-logger \
  && echo "logger installed" \
  || echo "FAILED: logger not installed"

wget -q -O /tmp/init-discord.new "$BASE/init.d-ipv6-discord-logger" \
  && sh -n /tmp/init-discord.new \
  && chmod 0755 /tmp/init-discord.new \
  && mv /tmp/init-discord.new /etc/init.d/ipv6-discord-logger \
  && echo "logger service installed" \
  || echo "FAILED: logger service not installed"

# curl
curl -fL "$BASE/ipv6-discord-logger" -o /tmp/ipv6-discord-logger.new \
  && sh -n /tmp/ipv6-discord-logger.new \
  && chmod 0755 /tmp/ipv6-discord-logger.new \
  && mv /tmp/ipv6-discord-logger.new /usr/bin/ipv6-discord-logger \
  && echo "logger installed" \
  || echo "FAILED: logger not installed"

curl -fL "$BASE/init.d-ipv6-discord-logger" -o /tmp/init-discord.new \
  && sh -n /tmp/init-discord.new \
  && chmod 0755 /tmp/init-discord.new \
  && mv /tmp/init-discord.new /etc/init.d/ipv6-discord-logger \
  && echo "logger service installed" \
  || echo "FAILED: logger service not installed"
```

Enable and start:

```sh
/etc/init.d/ipv6-discord-logger enable
/etc/init.d/ipv6-discord-logger restart
```

Use `restart` rather than a manual `kill` followed by `start`. The service is
procd-managed and manual process handling can produce duplicate instances.

---

## Upgrading an Existing Installation

Upgrading is file replacement. It does not require restarting WAN, `wan6`, or
the network, and no step below does so.

### 1. Back up what is installed

```sh
TS="$(date +%Y%m%d-%H%M%S)"
BACKUP="/root/ipv6-recovery-backup-$TS"
mkdir -p "$BACKUP"

for f in /usr/bin/wan-recovery-common \
         /usr/bin/ipv6-watchdog \
         /etc/hotplug.d/iface/99-ipv6-setup \
         /etc/hotplug.d/iface/97-garp \
         /usr/bin/ipv6-prefix-tracker \
         /usr/bin/ipv6-discord-logger \
         /etc/init.d/ipv6-discord-logger; do
    [ -f "$f" ] && cp -p "$f" "$BACKUP/" && echo "backed up $f"
done

cp -p /etc/crontabs/root "$BACKUP/crontabs-root" 2>/dev/null

echo "backup directory: $BACKUP"
ls -l "$BACKUP"
```

`cp -p` preserves modes and timestamps, so a restore puts back the exact file
that was running.

`/etc/ipv6-watchdog.conf` is deliberately excluded. It may contain webhook
secrets. Back it up separately if you want to, and keep that copy private.

### 2. Upgrade in dependency order

Install the coordinator first, then the hotplug helper, then the watchdog.
This ordering matters when the coordinator interface has changed between
versions: a new watchdog paired with an old coordinator would find the
interface incomplete and fail closed until the coordinator caught up.

```sh
# 1. coordinator
wget -q -O /tmp/wan-recovery-common.new "$BASE/wan-recovery-common" \
  && sh -n /tmp/wan-recovery-common.new \
  && chmod 0644 /tmp/wan-recovery-common.new \
  && mv /tmp/wan-recovery-common.new /usr/bin/wan-recovery-common \
  && echo "coordinator upgraded" \
  || echo "FAILED: coordinator unchanged"

# 2. hotplug helper
wget -q -O /tmp/99-ipv6-setup.new "$BASE/99-ipv6-setup" \
  && sh -n /tmp/99-ipv6-setup.new \
  && chmod 0755 /tmp/99-ipv6-setup.new \
  && mv /tmp/99-ipv6-setup.new /etc/hotplug.d/iface/99-ipv6-setup \
  && echo "hotplug helper upgraded" \
  || echo "FAILED: hotplug helper unchanged"

# 3. watchdog
wget -q -O /tmp/ipv6-watchdog.new "$BASE/ipv6-watchdog" \
  && sh -n /tmp/ipv6-watchdog.new \
  && chmod 0755 /tmp/ipv6-watchdog.new \
  && mv /tmp/ipv6-watchdog.new /usr/bin/ipv6-watchdog \
  && echo "watchdog upgraded" \
  || echo "FAILED: watchdog unchanged"
```

Each block is self-contained. If one fails, the file it targets keeps its
previous contents and the others are unaffected.

### 3. Verify the upgrade

Re-run the coordinator interface check and the installation integrity check
from the Quick Deploy section, then watch a few watchdog ticks:

```sh
logread -f | grep ipv6-watchdog
```

No configuration migration is required. Existing `/etc/ipv6-watchdog.conf`
settings continue to apply, and runtime state under `/tmp` is rebuilt as
needed.

---

## Rollback

Use this if an upgrade misbehaves. It restores files only. It does not restart
WAN or `wan6`.

Cron runs the watchdog every minute, so a replacement can land midway through a
tick. Stopping cron briefly avoids starting a new tick while files are being
swapped.

```sh
# 1. Choose the backup to restore
BACKUP="/root/ipv6-recovery-backup-<timestamp>"
ls -l "$BACKUP"

# 2. Pause the scheduler
/etc/init.d/cron stop

# 3. Restore, coordinator first so the watchdog never sees a newer
#    coordinator interface than it expects
[ -f "$BACKUP/wan-recovery-common" ] \
  && cp -p "$BACKUP/wan-recovery-common" /usr/bin/wan-recovery-common \
  && echo "coordinator restored"

[ -f "$BACKUP/99-ipv6-setup" ] \
  && cp -p "$BACKUP/99-ipv6-setup" /etc/hotplug.d/iface/99-ipv6-setup \
  && echo "hotplug helper restored"

[ -f "$BACKUP/ipv6-watchdog" ] \
  && cp -p "$BACKUP/ipv6-watchdog" /usr/bin/ipv6-watchdog \
  && echo "watchdog restored"

# 4. Validate before resuming
sh -n /usr/bin/wan-recovery-common && echo "coordinator syntax ok"
sh -n /usr/bin/ipv6-watchdog       && echo "watchdog syntax ok"
sh -n /etc/hotplug.d/iface/99-ipv6-setup && echo "hotplug syntax ok"

# 5. Confirm the coordinator interface is intact
for fn in wan_recovery_full_begin \
          wan_recovery_full_execute_locked \
          wan_recovery_wan6_begin \
          wan_recovery_wan6_record_locked \
          wan_recovery_end \
          wan_recovery_cleanup; do
    grep -q "^${fn}()" /usr/bin/wan-recovery-common \
      && echo "ok      $fn" \
      || echo "MISSING $fn"
done

# 6. Resume the scheduler
/etc/init.d/cron start
grep -n 'ipv6-watchdog' /etc/crontabs/root
```

If the cron file itself was changed and needs restoring:

```sh
/etc/init.d/cron stop
cp -p "$BACKUP/crontabs-root" /etc/crontabs/root
/etc/init.d/cron start
```

Restore the coordinator and the watchdog together. Running a new watchdog
against an old coordinator, or the reverse, is not a supported combination; the
watchdog detects an incomplete interface and fails closed rather than
misbehaving, but recovery stays disabled until the pair matches again.

---

## Compatibility

Tested on:
- PLDT Fiber in bridge mode
- OpenWrt 25.12.2 (vanilla OpenWrt, not GL.iNet stock firmware)
- GL.iNet GL-MT6000 (Flint 2)

```
  DIAGRAM 1 - SUPPORTED TOPOLOGY

  +---------------+
  | Provider      |   fiber
  | IPv6 via      |
  | RA + DHCPv6   |
  +-------+-------+
          |
          v
  +---------------+
  | ONT / modem   |   bridge mode:
  | no NAT        |   no routing, no NAT,
  | no routing    |   session passed through
  +-------+-------+
          |
          v  WAN device (for example eth1)
  +--------------------------------------------+
  | OpenWrt router (the edge device)           |
  |                                            |
  |  wan6 receives, from the provider:         |
  |                                            |
  |    IA_PD  delegated prefix    REQUIRED     |
  |           |                                |
  |           +--> /64 assigned to LAN         |
  |           +--> LAN global source address   |
  |                                            |
  |    IA_NA  WAN /128            OPTIONAL     |
  |           |                                |
  |           +--> may be present or absent    |
  |           +--> neither state is a fault    |
  |                                            |
  |  99-ipv6-setup   route / gateway repair    |
  |  ipv6-watchdog   health + source policy    |
  |  wan-recovery-   bounded WAN recovery      |
  |    common        coordination              |
  +---------------------+----------------------+
                        |
                        v  LAN bridge
  +--------------------------------------------+
  | LAN clients                                |
  |                                            |
  |  address via SLAAC from the delegated /64  |
  |  default route via RA from the router      |
  +--------------------------------------------+

  Scope: native DHCPv6 with prefix delegation, router is the first hop.
  Not applicable to NAT6, static IPv6, or tunnelled setups.
  This diagram is configuration-neutral. Specific UCI values are
  provider-dependent and are covered in the configuration section.
```

May work on:
- Other ISPs with similar IA_NA + RA gateway issues (common with CGNAT providers)

> **If your ISP does not exhibit the failure modes listed in the Root Causes section, do not apply this guide directly. Adapt the logic to your environment instead.** Provider behavior varies, and several settings in this guide are provider-dependent rather than universal.

Not designed for:
- Double NAT setups where OpenWrt is not the first hop
- Non-OpenWrt firmware

Expected to work on:
- OpenWrt 24.x and newer (fw4-based builds)

The current development and test baseline is OpenWrt 25.12.5. Earlier work in this repository was validated on 25.12.2, which is retained as historical context in the changelog. Older builds, custom images, and non-default environments may behave differently.

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
- Health detection, source policy, and route repair all act on the device that actually holds the WAN session, so they belong on the edge device rather than on a downstream router
- PLDT ONT firmware quirks can cause link-local addresses to flap, making the startup race described in the component reference more likely to trigger

---

## Root Causes

IPv6 on a bridged fiber connection can fail in several independent ways. This
project targets the combination below, observed in production over an extended
period. Not every deployment sees every failure.

### 1. Gateway selection and gateway death

The provider may advertise more than one router via Router Advertisement.
OpenWrt installs a default route through whichever it learns first, and that
gateway can be dead or become dead later. The neighbor entry goes
`INCOMPLETE` or `FAILED` and IPv6 stops, even though the delegated prefix is
still valid and another usable gateway is present on the same link.

A later RA can also reinstall a dead gateway at runtime, so a fix applied once
at boot does not stay applied.

### 2. Router source address selection

The provider may hand out a WAN address via `IA_NA` (a `/128`) alongside the
delegated prefix. When that happens, the Linux kernel will normally prefer the
`/128` as the source address for traffic the router itself originates.

On some deployments that works fine. On others the `/128` is present but not
usable for reaching the Internet, while traffic sourced from the delegated
prefix works normally. The visible symptom is confusing: LAN clients have
working IPv6, but the router's own unbound test pings fail.

This is a source selection problem, not proof that the address is inherently
broken. See "What this project does not claim" below.

### 3. Prefix delegation failures

`odhcp6c` can fail to obtain `IA_PD`, or the provider can answer with
`NoPrefixAvail`. Without a delegated prefix there is no LAN IPv6 at all, and no
amount of route repair helps.

### 4. Startup races

`wan6` can start before the link-local address on the WAN device is ready,
leaving DHCPv6 in a pending state and producing no default route until
something restarts the interface.

### 5. Configuration that removes fallback behavior

Using `accept_ra='2'` together with `defaultroute='0'` on `wan6` removes the
fallback path the interface needs while initializing, and can cause complete
IPv6 failure on every boot.

> **Warning:** Do not use `accept_ra='2'` with `defaultroute='0'`. This breaks
> `wan6` initialization and removes fallback routing.

### What this project does not claim

Earlier versions of this guide treated the `IA_NA` `/128` as inherently broken
and made its removal the primary fix. Longer observation across more than one
deployment showed that was too strong a conclusion, so it has been withdrawn.

The current position:

- A WAN `/128` is **optional**. Its presence is not a fault.
- Its absence is not a fault either, as long as the delegated prefix is healthy.
- On some deployments the `/128` is perfectly usable for router-originated
  traffic. On others it is not.
- Where it is not usable, the correct response is to change which source the
  router selects, not to delete the address.
- `reqaddress='none'` is therefore **not** a universal requirement. It is one
  provider-dependent option among others.

Removing a `/128` may still resolve symptoms on a specific line. That is a
local workaround, not a general rule, and this project no longer encodes it as
one.

---

## Architecture Overview (v3.10.0)

Three core components divide the work. The split exists so that health
decisions, non-disruptive repair, and disruptive recovery never sit in the same
place.

```
  DIAGRAM 2 - COMPONENT OWNERSHIP

  scheduled tick (cron)                       wan6 ifup (hotplug)
          |                                            |
          v                                            v
  +---------------------------+          +---------------------------+
  | ipv6-watchdog             |          | 99-ipv6-setup             |
  |                           |          |                           |
  | + IPv6 health detection   |          | + route / gateway repair  |
  | + PD-first decisions      |          | + PD-aware selection      |
  | + source-policy decisions |          | + snapshot and rollback   |
  | + escalation decisions    |          |                           |
  |                           |          | NON-DISRUPTIVE ONLY:      |
  | non-disruptive repair     |          | no ifdown / ifup          |
  | done in-process           |          | no UCI writes             |
  +-------------+-------------+          | no counters, no hold      |
                |                        +---------------------------+
                | request to disrupt
                | (wan6-only or full WAN)
                v
  +--------------------------------------------------+
  | wan-recovery-common                              |
  |                                                  |
  | + shared serialization lock                      |
  | + disruption budget and cooldown                 |
  | + disruption hold                                |
  | + accounting before any destructive command      |
  | + the ONLY place ifdown / ifup wan is executed   |
  +--------------------------------------------------+
```

The boundary that matters: `ipv6-watchdog` decides *whether* a disruptive
action is warranted, and `wan-recovery-common` decides *whether it is allowed
right now* and performs it. Neither one does the other's job. `99-ipv6-setup`
never participates in disruption at all.

### Component classification

| Component | Class | Role |
|---|---|---|
| `wan-recovery-common` | CORE | WAN recovery coordination layer (sourced library) |
| `99-ipv6-setup` | CORE | wan6-ifup hotplug route and gateway repair, non-disruptive |
| `ipv6-watchdog` | CORE | Health detection, source policy, escalation decisions |
| `97-garp` | OPTIONAL | Gratuitous ARP on LAN bridge ifup, for router swaps |
| `ipv6-discord-logger` | OPTIONAL | Forwards tagged syslog lines to a webhook |
| `init.d-ipv6-discord-logger` | OPTIONAL | procd service wrapper for the logger |
| `ipv6-prefix-tracker` | SUPPORTING | Observational prefix logging, refreshes odhcpd on change |

---

## PD-First Health Model

Household IPv6 health is decided by the delegated prefix and the path taken by
traffic sourced from it. Nothing else substitutes for that.

```
  DIAGRAM 3 - PD-FIRST HEALTH MODEL

     +--------------------------------------------+
     | LAYER 1  IA_PD delegated prefix present     |
     +----------------------+---------------------+
                            |
     +----------------------v---------------------+
     | LAYER 2  current PD-derived LAN global      |
     |          source address exists              |
     +----------------------+---------------------+
                            |
     +----------------------v---------------------+
     | LAYER 3  generic IPv6 default route exists  |
     |          on the WAN device                  |
     +----------------------+---------------------+
                            |
     +----------------------v---------------------+
     | LAYER 4  kernel resolves a packet FROM the  |
     |          PD source out through the WAN      |
     +----------------------+---------------------+
                            |
     +----------------------v---------------------+
     | LAYER 5  PD-source-bound Internet probe     |
     |          succeeds (decisive)                |
     +----------------------+---------------------+
                            |
                            v
                 +---------------------+
                 | LAN IPv6 is HEALTHY |
                 +---------------------+

     - - - - - - - - - - - - - - - - - - - - - - - - - - - -

     +---------------------------------------------+
     | IA_NA /128 on the WAN device                |
     |                                             |
     | OPTIONAL. Sits beside the chain above,      |
     | never inside it.                            |
     |                                             |
     | present    -> not a fault                   |
     | absent     -> not a fault                   |
     | reachable  -> does not prove LAN health     |
     | failing    -> does not prove LAN failure    |
     +---------------------------------------------+
```

All five layers must pass. Any one failing means IPv6 is not healthy, and the
failing layer identifies what to repair.

**Layer 4 is effective routing, not route shape.** The check asks the kernel
how a packet from the PD-derived source would actually be routed, rather than
looking for a particular rule in the table. A generic default route on its own
is a perfectly healthy configuration. An explicit `default from <PD_CIDR>` rule
is optional; where one already exists it is maintained, but it is never
required and never manufactured.

**Layer 5 is source-bound.** The probe is sent from the PD-derived LAN source
to a public IPv6 target. An unbound ping from the router is not equivalent,
because the kernel may select a different source address for it.

**Transient failures are confirmed before acting.** A failed reachability check
is retried after a short delay before the watchdog treats it as a real failure,
which suppresses alerts from brief provider-side drops.

### The IA_NA contract

| Situation | Meaning |
|---|---|
| `/128` present, reachable | Fine. Nothing to do. |
| `/128` present, not reachable, PD source works | Router source selection problem. Handled by source policy, below. |
| `/128` absent, PD source works | Fine. Fully healthy. |
| `/128` present or absent, PD source fails | Unhealthy. Cause is the PD path, not the `/128`. |

An `IA_NA` failure on its own never counts as a household health failure, never
increments a recovery counter, and never consumes disruption budget.

### Two kinds of reachability

These are different questions and the README uses them precisely:

- **Router-default reachability**: can the router reach the Internet using
  whatever source the kernel picks? This can fail while the LAN is perfectly
  healthy, because the kernel may pick a `/128` that does not work.
- **PD-source-bound reachability**: can the router reach the Internet using the
  PD-derived LAN source? This is the decisive household health test.

---

## Router Source Policy

Source policy is a **router-local** correction. It changes which source address
the router uses for its own unbound traffic. It is not a health input, and it
never triggers interface recovery.

It has two states: `native` and `pd-preferred`.

```
  DIAGRAM 4 - SOURCE POLICY DECISION TREE

   start
     |
     v
   Is a WAN /128 (IA_NA) present?
     |
     +-- no ---------------------------------> NATIVE
     |                                         (no src is imposed;
     |                                          kernel selection kept)
     |
     +-- yes
          |
          v
        Is the /128 usable for reaching the Internet?
          |
          +-- yes ----------------------------> NATIVE
          |                                     (kernel is already
          |                                      choosing correctly)
          |
          +-- no
               |
               v
             Does the PD-derived source reach the Internet?
               |
               +-- yes ------------------------> PD-PREFERRED
               |                                 (install preferred src
               |                                  on the generic default)
               |
               +-- no -------------------------> NO POLICY ACTION
                                                 (PD path itself is broken;
                                                  normal health and recovery
                                                  logic owns this case)
```

The last branch matters: when the PD path is unhealthy, source policy stays
out of the way entirely. It does not mutate routes and it does not offer an
opinion. Recovery is driven by the PD-first health model instead.

### What pd-preferred does

It sets a preferred source address on the **generic default route** so the
kernel uses the PD-derived address for router-originated traffic.

It is deliberately conservative:

- The existing gateway is preserved. Source policy never changes which gateway
  is in use.
- `dev`, `proto`, `metric` and `pref` on that route are preserved. Only the
  source attribute is added or replaced.
- Source-specific `default from <PD_CIDR>` routes are never modified.
- The route is only mutated when classification actually requires it.

### Ownership, and why it is strict

The watchdog records ownership of a source address **only after a route change
it made actually succeeded**. Classification alone never records ownership.

This distinction exists so the watchdog can never remove something it did not
install:

- If the route already carries the intended source when the watchdog looks,
  it assumes an administrator put it there. It leaves the route alone and does
  **not** record ownership.
- If a route change fails, no ownership is recorded, so a later cleanup pass
  will not strip an address the watchdog never successfully set.
- Before removing a source it believes it owns, the watchdog re-checks that the
  route still carries exactly that address. If somebody has changed it in the
  meantime, the watchdog releases its claim and leaves the route untouched.
- If the delegated prefix changes, any ownership recorded against the old
  prefix is stale. It is released safely, again without touching a route that
  somebody else has since modified.

The practical guarantee: **an administrator-set source attribute is never
silently claimed, overwritten, or removed.**

### Restoring a source that disappears

Route refreshes triggered by RA or `netifd` can silently drop the source
attribute while leaving the gateway untouched. When source policy is already in
`pd-preferred` and the watchdog owns the source, it restores it on the next
tick.

That restore path is cheap on purpose. It re-checks the route and reinstates
the source without re-running reachability probes, so a flapping route does not
consume probe budget on every tick. Classification is refreshed periodically
(every 600 seconds by default) and immediately whenever the prefix, the LAN
source, the `/128`, or the current gateway changes.

### What source policy never does

- It never restarts `wan6` or WAN.
- It never consumes disruption budget.
- It never increments recovery counters or triggers recovery hold.
- It never defines household health.

A source-policy failure is logged and retried. It cannot escalate.

---

## Gateway and Route Repair

Gateway repair is **non-disruptive**. It changes routes and neighbor entries
only. It never restarts an interface.

### Selection

Candidate gateways are discovered from the neighbor table and from the routing
table. Each candidate is verified before being accepted, using two independent
signals:

1. The kernel resolves a packet from the PD-derived source through the WAN
   device via **that specific candidate**.
2. A PD-source-bound probe to a public IPv6 target succeeds.

Reachability of the router's unbound path is not used for acceptance, and
neither is the `/128`.

### Minimum mutation

When routing is already effective and the PD source can reach the Internet,
nothing is changed at all. A generic-default-only routing table is a fully
valid steady state and is accepted with zero route churn.

When a change is required, the smallest one is made:

- The generic default route is pointed at the chosen gateway.
- A source-specific `default from <PD_CIDR>` route is corrected **only if one
  already exists**. It is never created where none was present.

The gateway's MAC address is pinned in the neighbor table so a stale or
incomplete entry does not immediately undo the repair.

### Snapshot and exact rollback

Before any mutation, the complete set of default routes is captured verbatim.

If a candidate fails, the captured routes are replayed exactly as they were.
This matters because a repair can fail halfway: deleting only what the failed
attempt installed would not restore the original state. Replaying the snapshot
does.

Where there was no prior route to snapshot, rollback removes only the routes
that attempt created, and only when they still point at that candidate. A
pre-existing rule that the attempt did not create is left alone.

### Link-local gateways need interface context

Provider gateways are normally link-local addresses. A link-local next hop is
meaningless without knowing which interface it is on, so any route referring to
one must carry its `dev` token.

This interacts with a real `iproute2` behavior that is easy to miss:

```
  Querying with a device selector:

    ip -6 route show default dev <wandev>

  can emit:

    default via <link-local-gw> proto static metric 512 pref medium
                                                    ^
                                        no "dev <wandev>" token here

  The selector is treated as implied and is not echoed back in the output.
```

Replaying such a line to add a source attribute produces a route with no
interface context, and the kernel rejects it because the link-local next hop
cannot be resolved.

The implementation therefore reads generic default routes **without** a device
selector and filters on the `dev` token afterwards, so the line it replays
always carries interface context. Deterministic tests reproduce the selector
behavior to keep this from regressing.

---

## Recovery Coordination

Recovery is layered, and each layer is more disruptive than the last. The
watchdog only escalates when the layer below has not resolved the failure.

```
  DIAGRAM 5 - RECOVERY ESCALATION

   health check fails
          |
          v
   +-------------------------------------------+
   | LEVEL 1  non-disruptive repair            |
   |                                           |
   | + restore known-good gateway              |
   | + re-select gateway from candidates       |
   | + apply source policy                     |
   | + routes only, no interface restart       |
   +--------------------+----------------------+
                        |
                    recheck
                        |
                 still failing
                        |
                        v
   +-------------------------------------------+
   | LEVEL 2  coordinated wan6-only action     |
   |                                           |
   | + asks the coordinator for permission     |
   | + rechecks health after acquiring lock    |
   | + does NOT spend full-WAN budget          |
   | + IS blocked by an active hold            |
   +--------------------+----------------------+
                        |
                    recheck
                        |
                 still failing
                        |
                        v
   +-------------------------------------------+
   | gate: budget / cooldown / hold / lock     |
   |                                           |
   | blocked -> log and wait, take no action   |
   +--------------------+----------------------+
                        |
                    permitted
                        |
                        v
   +-------------------------------------------+
   | LEVEL 3  coordinated full-WAN recovery    |
   |                                           |
   | + accounting written BEFORE any teardown  |
   | + full wan + wan6 lifecycle               |
   | + latches hold when budget is exhausted   |
   +-------------------------------------------+
```

### Bounded, not unlimited

Full-WAN recovery is deliberately finite. It is bounded by four independent
mechanisms:

| Mechanism | Default | Effect |
|---|---|---|
| Shared lock | n/a | Only one disruptive action at a time, ever |
| Disruption budget | 3 per boot | Hard ceiling on full-WAN cycles |
| Cooldown | 1200 s | Minimum spacing between full-WAN cycles |
| Disruption hold | latched at budget | Stops all disruptive action until reboot |

Once the budget is exhausted, the hold latches and the system switches to
passive monitoring. It keeps checking health and keeps logging, but it stops
cycling interfaces. Repeatedly restarting WAN against a provider-side outage
helps nobody, so it stops rather than looping.

This is why the guide describes **bounded** self-healing. The system recovers
from transient faults on its own; it does not pretend it can fix a fault that
is not on the router.

### The full-WAN sequence

```
  DIAGRAM 6 - COORDINATED FULL-WAN RECOVERY

  caller (ipv6-watchdog)                coordinator
  ----------------------                -----------
  request full-WAN recovery  ------->   acquire shared lock
                                              |
                                        check, while holding the lock:
                                          + hold latched?
                                          + inside cooldown?
                                          + recent wan6 action?
                                          + lock busy?
                                              |
                              +---------------+---------------+
                              |                               |
                          blocked                        permitted
                              |                               |
                     release lock, no action          lock is held
                              |                               |
                              v                               v
                           caller                    caller rechecks health
                          logs and                           |
                          gives up               +-----------+-----------+
                                                 |                       |
                                            recovered               still failing
                                                 |                       |
                                          release lock,                  v
                                          NO accounting        ACCOUNTING FIRST
                                                               + increment count
                                                               + write timestamp
                                                               + write reason
                                                               + latch hold if
                                                                 budget reached
                                                                       |
                                                                       v
                                                               LIFECYCLE
                                                               + ifdown wan6
                                                               + ifdown wan
                                                               + wait
                                                               + ifup wan
                                                               + wait
                                                               + ifup wan6
                                                                       |
                                                                       v
                                                               release lock
```

Two details are deliberate and worth calling out.

**The health recheck happens after the lock is acquired, not before.** Waiting
for a lock takes time, and the fault may clear while waiting. Rechecking
afterwards means a system that recovered on its own is not torn down for no
reason, and no disruption is recorded against it.

**Accounting is written before the first destructive command, not after.** If
the router loses power or the script is killed midway through a WAN cycle, the
disruption has still happened from the network's point of view. Recording it
first means a crash cannot produce an unbounded restart loop across reboots.

### Fail-closed

`ipv6-watchdog` loads the coordinator at startup and verifies its public
interface is complete. If the coordinator is missing, unreadable, or
incomplete, the watchdog marks disruptive recovery unavailable.

In that state it keeps running: health checks, logging, diagnostics, and
non-disruptive route and gateway repair all continue. What it will not do is
fall back to restarting interfaces on its own.

The reason is that the coordinator owns the budget, the cooldown, and the hold.
A watchdog that restarted WAN without it would have no ceiling and no spacing.
Refusing to act is the safer failure.

**Deployment consequence:** install `wan-recovery-common` before
`ipv6-watchdog`, and keep it across firmware upgrades. Without it, the watchdog
runs in a monitoring-only mode.

### Missing prefix escalation

When there is no delegated prefix at all, route repair cannot help, so a
separate escalation applies with increasing backoff between attempts:

| Attempt | Action |
|---|---|
| 1 | Coordinated `wan6` restart |
| 2 | DHCPv6 renew, no interface teardown |
| 3 | Coordinated full-WAN recovery |
| 4+ | Coordinated full-WAN recovery, subject to budget, cooldown and hold |

An experimental `IA_NA`-assisted bootstrap stage also exists in the code. It is
**disabled by default** and is skipped entirely unless explicitly enabled, in
which case it occupies attempt 3 and full-WAN recovery moves to attempt 4. Its
effectiveness is an untested hypothesis, which is why it does not run unless
somebody opts in.

---

## Startup and Steady State

```
  DIAGRAM 7 - STARTUP TO STEADY STATE

  boot / WAN event
        |
        v
  wan6 comes up
        |
        v
  +------------------------------------------+
  | 99-ipv6-setup (hotplug, on wan6 ifup)    |
  |                                          |
  | + waits for PD context                   |
  | + accepts already-working routing        |
  |   with no changes                        |
  | + otherwise selects a verified gateway   |
  | + snapshot / rollback on failure         |
  |                                          |
  | defers to the watchdog if there is       |
  | still no prefix                          |
  +--------------------+---------------------+
                       |
                       v
             +-------------------+
             | IPv6 steady state |
             +---------+---------+
                       |
        scheduled tick every minute
                       |
                       v
  +------------------------------------------+
  | ipv6-watchdog                            |
  |                                          |
  |   keep known-good gateway                |
  |            |                              |
  |            v                              |
  |   apply source policy                    |
  |            |                              |
  |            v                              |
  |   evaluate PD-first health                |
  |            |                              |
  |     +------+------+                       |
  |     |             |                       |
  |  healthy      unhealthy                   |
  |     |             |                       |
  |     v             v                       |
  |  reset       escalate through             |
  |  counters    LEVEL 1 / 2 / 3              |
  +------------------------------------------+
```

The watchdog applies source policy before evaluating health, so the health
check reflects the source the router will actually use.

---

## State Ownership

Runtime state lives in two directories with a clear split. Both are on `tmpfs`
and are cleared by a reboot, which is intentional: the same-boot disruption
budget resets when the router reboots.

```
  DIAGRAM 8 - STATE OWNERSHIP

  +--------------------------------+   +--------------------------------+
  | /tmp/ipv6-watchdog/            |   | /tmp/wan-recovery/             |
  |                                |   |                                |
  | IPv6-specific state            |   | Shared coordination state      |
  |                                |   |                                |
  | + health failure counters      |   | + disruption count             |
  | + prefix retry and backoff     |   | + last full-WAN timestamp      |
  | + known-good gateway           |   | + last wan6 action timestamp   |
  | + source-policy mode           |   | + reason accounting            |
  | + source-policy cache key      |   | + disruption hold latch        |
  | + owned source address record  |   | + serialization lock           |
  | + per-script execution lock    |   |                                |
  |                                |   | owned by:                      |
  | owned by:                      |   |   wan-recovery-common          |
  |   ipv6-watchdog                |   |                                |
  +--------------------------------+   +--------------------------------+
             |                                        ^
             |  requests disruptive action            |
             +----------------------------------------+

  The watchdog reads shared state to answer "am I allowed to act",
  but the coordinator is the only writer of it.
```

Individual filenames are listed in the state file reference later in this
document.


---

## Configuration

Not every setting here is universal. Provider behavior varies, so this section
separates what IPv6 genuinely needs from what is simply the configuration this
project was tested against.

### How settings are classified

| Class | Meaning |
|---|---|
| REQUIRED | IPv6 prefix delegation will not work correctly without it |
| RECOMMENDED BASELINE | The tested configuration. Safe default, not a protocol requirement |
| PROVIDER-DEPENDENT | Correct value depends on your ISP. Do not copy blindly |
| LEAVE EXISTING VALUE UNCHANGED | Do not set this as part of installation |
| TROUBLESHOOTING-ONLY | Change only while diagnosing a specific symptom |

Importantly, **no core script requires any particular value** of `reqaddress`,
`reqprefix`, `sourcefilter`, or `norelease`. The health model reads the
delegated prefix and the resulting LAN source from the running system; it does
not enforce a configuration shape.

### Tested baseline example

This is the configuration this project is developed and tested against. It is
an **example**, not a mandatory block. Read the classification table below
before applying it, particularly the provider-dependent lines.

```sh
# wan6 interface
uci set network.wan6.device='@wan'
uci set network.wan6.accept_ra='1'
uci set network.wan6.force_link='1'
uci set network.wan6.multipath='off'

# Provider-dependent. Review the notes below before setting these.
uci set network.wan6.reqprefix='56'
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

Note what is **not** in that block: `reqaddress` and `norelease`. Both are
discussed below and neither belongs in a universal install.

### Setting reference

| Setting | Baseline | Class | Notes |
|---|---|---|---|
| `network.wan6.device` | `@wan` | REQUIRED | Ties `wan6` to the `wan` interface lifecycle instead of a hardcoded device name |
| `network.wan6.accept_ra` | `1` | REQUIRED | RA processing must stay on for `wan6` to initialize. See the warning below |
| `network.lan.ip6assign` | `64` | REQUIRED | LAN receives a `/64` from the delegated prefix. Without it there is no LAN PD-derived source, and health cannot pass |
| `network.lan.ip6class` | `wan6` | REQUIRED | Binds LAN delegation to the `wan6` interface |
| `dhcp.lan.ra` | `server` | REQUIRED | LAN clients need RA to learn a default route |
| `dhcp.lan.ra_slaac` | `1` | REQUIRED | Lets clients autoconfigure a global address from the delegated `/64` |
| `dhcp.lan.ra_default` | `1` | REQUIRED | Advertises a default route to LAN clients |
| `network.wan6.force_link` | `1` | RECOMMENDED BASELINE | Keeps `wan6` up while link-local state is briefly absent |
| `network.wan6.multipath` | `off` | RECOMMENDED BASELINE | Keeps multipath routing out of gateway selection |
| `network.globals.rpfilter` | `0` | RECOMMENDED BASELINE | Reverse-path filtering can drop DHCPv6 PD traffic on asymmetric paths. Tested baseline, not a universal rule |
| `network.globals.ipv6_sourcefilter` | `1` | RECOMMENDED BASELINE | Per-interface IPv6 source filtering |
| `dhcp.lan.dhcpv6` | `server` | RECOMMENDED BASELINE | Stateful DHCPv6 on LAN alongside SLAAC |
| `dhcp.lan.ra_preference` | `medium` | RECOMMENDED BASELINE | Router preference in RA |
| `dhcp.lan.force` | `1` | RECOMMENDED BASELINE | Serve DHCPv6 even with no clients present yet |
| `dhcp.lan.ndp` | `relay` | RECOMMENDED BASELINE | NDP relay between WAN and LAN |
| `network.wan6.reqprefix` | `56` | PROVIDER-DEPENDENT | See below |
| `network.wan6.sourcefilter` | `0` | PROVIDER-DEPENDENT | See below |
| `network.wan6.reqaddress` | not set here | PROVIDER-DEPENDENT | See below |
| `network.wan6.norelease` | not set here | LEAVE EXISTING VALUE UNCHANGED | See below |

> **Warning:** do not combine `accept_ra='2'` with `defaultroute='0'` on `wan6`.
> That removes the fallback path the interface needs while initializing and can
> cause complete IPv6 failure on every boot.

### reqaddress (PROVIDER-DEPENDENT)

Earlier versions of this guide told everyone to set `reqaddress='none'` to stop
the ISP handing out a WAN `/128`. **That rule has been withdrawn.**

What the current model says:

- A WAN `/128` (IA_NA) is **optional**. Its presence is not unhealthy.
- Its absence is not unhealthy either.
- Household health is decided by the delegated prefix, not by IA_NA.
- `reqaddress='none'` is a reasonable choice on provider paths where the `/128`
  is not usable and you would rather not have one at all.
- `reqaddress='try'` is also a valid choice and has been observed working in a
  healthy deployment.
- Where a `/128` exists but is not usable for router-originated traffic, source
  policy corrects which source the router selects. Removing the address is not
  required.

**If your delegated prefix and LAN IPv6 are already healthy, do not change
`reqaddress`.** There is nothing to fix, and changing it forces a DHCPv6
re-negotiation for no benefit.

Only if you are actively diagnosing a prefix acquisition problem:

```sh
# TROUBLESHOOTING-ONLY. Inspect the current value first.
uci get network.wan6.reqaddress
```

Changing it requires the interface to re-negotiate with the provider before the
new value takes effect. That is a deliberate, disruptive step, so it is not
part of normal configuration. See the troubleshooting section rather than
applying it as routine.

### reqprefix (PROVIDER-DEPENDENT)

`reqprefix='56'` is this project's baseline: it asks for a `/56` explicitly,
which makes what you receive predictable.

It is **not** a protocol requirement and not a guarantee:

- Providers differ. Many delegate a `/56`, others a `/60` or `/64`.
- Asking for a size does not oblige the provider to grant it.
- `reqprefix='auto'` is a legitimate alternative and has historically obtained
  a `/56` on this provider path. It is not invalid.
- The health model does not require any particular prefix length. It requires a
  delegated prefix, and a LAN `/64` derived from it.

Set it to match what your provider actually delegates, or leave it at `auto` if
that already works.

### sourcefilter (PROVIDER-DEPENDENT)

`sourcefilter='0'` on `wan6` is part of the tested baseline for this provider
path, where source filtering interfered with DHCPv6 prefix delegation over
asymmetric routing.

It is not a universal recommendation for OpenWrt IPv6, and it is not required
by anything in this project's code. Leave your existing value alone unless you
are specifically diagnosing prefix delegation failures.

### norelease (LEAVE EXISTING VALUE UNCHANGED)

Earlier versions instructed `uci delete network.wan6.norelease`. **That
instruction has been removed.**

Project policy is deliberately neutral. Provider behavior on DHCPv6 Release
varies, the evidence for any single value being better is not conclusive, and
**no script in this project reads or modifies `norelease`.**

Guidance: **leave whatever value your router already has.** Do not set it, do
not delete it, and do not add it to an install script. Change it only inside a
specific troubleshooting procedure that calls for testing a different value,
and change it back afterwards if it makes no difference.

```sh
# Inspect only. No action needed for a normal install.
uci get network.wan6.norelease
```

### Applying configuration safely

> **Never restart the LAN interface** (`ifdown lan`, `ifup lan`, or
> `/etc/init.d/network restart`) while `wan6` is up with an active delegated
> prefix. odhcpd marks the prefix stale and advertises `ra_lifetime=0`, which
> withdraws IPv6 from every LAN client.

To apply changes without disrupting IPv6:

```sh
uci commit network
uci commit dhcp
ubus call network reload
```

If LAN RA or DHCPv6 settings changed, refresh odhcpd afterwards:

```sh
sleep 10
/etc/init.d/odhcpd restart
```

`ubus call network reload` applies interface configuration without tearing down
the whole network. Nothing in this section restarts WAN or `wan6`, and nothing
reboots the router.

**Settings that need re-negotiation.** `reqaddress`, `reqprefix`, and
`norelease` are DHCPv6 client parameters. A running lease keeps its existing
terms, so a change only takes effect when `wan6` next negotiates with the
provider. That is disruptive to IPv6 while it happens, which is exactly why
these are not part of routine configuration. Treat any such change as a
deliberate troubleshooting action.

---

## Component Reference

Installation is covered in [Quick Deploy](#quick-deploy-core-v310) and
[Optional and Supporting Components](#optional-and-supporting-components). This
section describes what each file does once installed.

### 99-ipv6-setup (CORE)

**File:** [`99-ipv6-setup`](99-ipv6-setup) installed at
`/etc/hotplug.d/iface/99-ipv6-setup`

Runs on `wan6` ifup only. It repairs routing so traffic from the PD-derived LAN
source has a working path, using the smallest change that achieves it.

What it does:

- Waits for PD context (delegated prefix and a LAN source derived from it).
- Accepts an already-working state with **zero route changes**. A
  generic-default-only table is valid and is left alone.
- Otherwise selects a gateway from neighbor and route evidence, accepting a
  candidate only when the kernel resolves a packet from the PD source through
  it **and** a PD-source-bound probe succeeds.
- Pins the chosen gateway's MAC in the neighbor table so a stale entry does not
  immediately undo the repair.
- Snapshots default routes before any change and restores them exactly if a
  candidate fails.
- Defers to the watchdog when no prefix is present, since route repair cannot
  create a delegation.

What it explicitly does **not** do:

- No `ifdown` or `ifup`, ever. It is non-disruptive by construction.
- No WAN restart, and no ownership of restart policy.
- No UCI writes.
- No recovery counters, no disruption budget, no hold.
- **No `/128` removal.** Earlier versions removed the WAN `/128`; the current
  version never touches it.
- It does not install a preferred source. That is source policy, which belongs
  to the watchdog.

See [Gateway and Route Repair](#gateway-and-route-repair) for the model it
implements.

### ipv6-watchdog (CORE)

**File:** [`ipv6-watchdog`](ipv6-watchdog) installed at `/usr/bin/ipv6-watchdog`

Runs every minute from cron. It owns health decisions and decides when recovery
is warranted.

Each tick, in order:

1. Restore the known-good gateway if sticky gateway is enabled.
2. Apply router source policy, so the health check reflects the source the
   router will actually use.
3. Evaluate PD-first health across five layers.
4. On success, reset non-budget counters. On failure, escalate no further than
   necessary.

It owns:

- IPv6 health detection, PD-first (see [PD-First Health Model](#pd-first-health-model))
- Source-policy decisions (see [Router Source Policy](#router-source-policy))
- Non-disruptive gateway and route repair
- Escalation decisions

It does **not** own:

- The disruption budget, cooldown, or hold. Those belong to the coordinator.
- The `ifdown`/`ifup` of `wan` itself. Full-WAN lifecycle exists only inside
  `wan-recovery-common`.

A WAN `/128` is optional to it. IA_NA reachability never defines household
health, never increments a recovery counter, and never consumes budget.

If the coordinator is unavailable, the watchdog keeps monitoring, logging, and
repairing routes, but performs no disruptive recovery. See
[Recovery Coordination](#recovery-coordination).

### wan-recovery-common (CORE)

**File:** [`wan-recovery-common`](wan-recovery-common) installed at
`/usr/bin/wan-recovery-common`

A sourced POSIX shell library, not an executable script, and intentionally
without a shebang. It is the only component that performs disruptive WAN
lifecycle actions, and it decides whether any such action is permitted.

It owns the shared lock, the per-boot disruption budget, the cooldown, the
disruption hold, accounting written before any destructive command, and the
full `wan` and `wan6` lifecycle. See
[Recovery Coordination](#recovery-coordination) for the full model and the
coordinated sequence.


This file is **optional**. The defaults below are the tested baseline and most
deployments never need to change any of them. The watchdog sources the file on
every tick if it exists, and `99-ipv6-setup` and `97-garp` read `LAN_DEV` from
it as well.

Create it only if you actually want to override something:

```sh
touch /etc/ipv6-watchdog.conf
chmod 0600 /etc/ipv6-watchdog.conf
```

Use mode `0600`. If you enable Discord notifications this file holds your
webhook URLs, and it should never be published or shared.

Only the variables listed here are supported settings. Other values inside the
scripts are internal constants, not tunables.

#### A. Watchdog behavior

| Variable | Default | Purpose | Change it? |
|---|---|---|---|
| `LAN_DEV` | `br-lan` | LAN bridge device used to find the PD-derived LAN source | Only if your LAN bridge has a different name |
| `STICKY_GATEWAY` | `0` | Re-pin the last known-good gateway when RA replaces it with a dead one | Enable (`1`) only where dead gateway advertisements are a known problem |
| `REACHABILITY_CONFIRM_DELAY` | `3` | Seconds before the second reachability check. Suppresses alerts from brief provider drops | Rarely. Non-numeric falls back to `3`; values above `30` are capped at `30`; `0` disables confirmation |
| `CLEANUP_DEPRECATED_LAN` | `1` | Remove deprecated LAN addresses left behind after a prefix change | Rarely |
| `CLEANUP_WAN128` | `0` | Remove the WAN `/128` after a successful bootstrap | Leave at `0`. A healthy `/128` is optional and may be kept. See [D](#d-experimental-bootstrap_enabled-and-cleanup_wan128) |
| `BOOTSTRAP_ENABLED` | `0` | Enable the experimental IA_NA-assisted prefix bootstrap stage | Leave at `0` unless you are deliberately testing it. Its effectiveness is unproven. See [D](#d-experimental-bootstrap_enabled-and-cleanup_wan128) |

#### B. Recovery limits

These are read by both the watchdog and the coordinator. The newer
`WAN_DISRUPTION_*` names take precedence; the older `WAN_RESTART_*` names are
still honoured for compatibility.

| Variable | Default | Purpose |
|---|---|---|
| `WAN_DISRUPTION_LIMIT` | `3` | Full-WAN recovery cycles allowed per boot. Reaching it latches the hold |
| `WAN_DISRUPTION_COOLDOWN` | `1200` | Minimum seconds between full-WAN cycles |
| `WAN_RESTART_LIMIT` | `3` | Legacy name for the limit. Used only if `WAN_DISRUPTION_LIMIT` is unset |
| `WAN_RESTART_COOLDOWN` | `1200` | Legacy name for the cooldown. Used only if `WAN_DISRUPTION_COOLDOWN` is unset |

Raising the limit does not make recovery more effective. The budget exists so a
provider-side outage cannot turn into an endless restart loop.

#### C. Coordinator settings

Defaults inside `wan-recovery-common`. Override them in the same file.

| Variable | Default | Purpose |
|---|---|---|
| `WAN_RECOVERY_STATE_DIR` | `/tmp/wan-recovery` | Shared coordination state directory |
| `WAN6_TO_FULL_WAN_GRACE` | `60` | Seconds after a wan6 action during which a full-WAN cycle is held off |
| `WAN_RECOVERY_STALE_LOCK_AGE` | `600` | Age in seconds after which a lock left by a dead process is treated as stale |
| `WAN_DOWN_SLEEP` | `30` | Seconds interfaces stay down during a full-WAN cycle |
| `WAN_UP_SLEEP` | `20` | Seconds between bringing WAN up and bringing wan6 up |
| `WAN_RECOVERY_COMMON` | `/usr/bin/wan-recovery-common` | Path the watchdog loads the coordinator from |

#### D. Experimental: BOOTSTRAP_ENABLED and CLEANUP_WAN128

##### BOOTSTRAP_ENABLED

**`BOOTSTRAP_ENABLED=0` is the default and the recommended production setting.**
Leave it at `0`.

`BOOTSTRAP_ENABLED=1` enables the Phase 3 NO_PD bootstrap stage
(`try_128_bootstrap`) **for controlled testing only**. It is a hypothesis about
prefix acquisition whose live effectiveness has not been demonstrated. It is not
a recommended production configuration, it is not a fix for a router that is
currently healthy, and enabling it will not make recovery faster or more
reliable.

Invalid values **fail safe to `0`**. Anything that is not exactly `1` — `yes`,
`true`, `01`, an empty value, a typo — is treated as disabled:

```sh
BOOTSTRAP_ENABLED="${BOOTSTRAP_ENABLED:-0}"
case "$BOOTSTRAP_ENABLED" in
    1) ;;
    *) BOOTSTRAP_ENABLED=0 ;;
esac
```

The override belongs in **`/etc/ipv6-watchdog.conf`**, which the watchdog sources
on every tick. Do **not** edit `/usr/bin/ipv6-watchdog` — an edited script is
overwritten by the next upgrade, breaks the installation integrity check, and
diverges from the published SHA256.

**Check the effective value.** This reproduces the watchdog's own resolution
and sanitization, so it reports what the watchdog will actually use, not just
what the file says:

```sh
BOOTSTRAP_ENABLED=0; [ -f /etc/ipv6-watchdog.conf ] && . /etc/ipv6-watchdog.conf; case "$BOOTSTRAP_ENABLED" in 1) ;; *) BOOTSTRAP_ENABLED=0 ;; esac; echo "effective BOOTSTRAP_ENABLED=$BOOTSTRAP_ENABLED"
```

**Enable it (controlled testing only).** Removes any existing line first so the
file cannot end up with two conflicting entries:

```sh
sed -i '/^[[:space:]]*BOOTSTRAP_ENABLED=/d' /etc/ipv6-watchdog.conf 2>/dev/null; echo 'BOOTSTRAP_ENABLED=1' >> /etc/ipv6-watchdog.conf; chmod 0600 /etc/ipv6-watchdog.conf
```

**Disable it again (return to the production default):**

```sh
sed -i '/^[[:space:]]*BOOTSTRAP_ENABLED=/d' /etc/ipv6-watchdog.conf 2>/dev/null; echo "disabled (built-in default is 0)"
```

Deleting the line is enough — the built-in default is `0`. Setting
`BOOTSTRAP_ENABLED=0` explicitly is equally valid.

**Verify.** Re-run the effective-value check above, then confirm behavior in the
log. No service restart is needed; the next tick picks the value up:

```sh
logread | grep ipv6-watchdog | tail -50
```

When the no-prefix ladder reaches attempt 3 with the stage **disabled**, you will
see:

```
No prefix (attempt 3), Phase 3 bootstrap disabled -- escalating to full WAN restart
```

With it **enabled** and actually running, you will see:

```
No prefix (attempt 3), attempting bounded IA_NA-assisted bootstrap, backoff 1800s
Attempting bounded temporary IA_NA-assisted DHCPv6 recovery stage
```

##### Only meaningful when committed `reqaddress='none'`

Enabling the experiment is only meaningful on a router whose **committed**
`network.wan6.reqaddress` is `'none'`. The whole point of the stage is to probe
whether temporarily *requesting* an IA_NA persuades the provider to grant an
IA_PD; on a router already committed to `'try'` that is a no-op. If the
committed value is anything other than `'none'` the bootstrap refuses without
touching UCI at all, and logs:

```
Bootstrap refusing: production reqaddress is '<value>', expected 'none' (experimental scope)
```

Check the committed value, and confirm nothing is left staged:

```sh
uci get network.wan6.reqaddress; uci changes network
```

`uci changes network` should print nothing. If it lists a `reqaddress` change,
you have an uncommitted edit that will confuse the check.

> Read [reqaddress (PROVIDER-DEPENDENT)](#reqaddress-provider-dependent) before
> changing this value. If your delegated prefix and LAN IPv6 are healthy, do not
> change `reqaddress` — there is nothing to fix.

##### What the bootstrap does to `reqaddress`

When it runs, the stage **temporarily stages** `reqaddress='try'` and then
**reverts** it:

1. `uci set network.wan6.reqaddress='try'` — staged, never committed.
2. One coordinated `wan6` acquisition cycle, then it waits for an IA_PD.
3. `uci revert network.wan6.reqaddress` — restores the committed value.
4. A post-revert health gate re-checks that IA_PD, the PD-derived LAN source,
   coherent routes, and PD-source Internet reachability all **survive** the
   return to production mode. A prefix that exists only while `'try'` is staged
   is **not** treated as success.

Because the value is staged and never committed, it does not persist across a
reboot. If the watchdog is killed mid-run, its exit handler reverts the staged
value.

##### What the no-prefix ladder does when bootstrap is disabled

With `BOOTSTRAP_ENABLED=0` (the default), the prefix-loss ladder is unchanged and
the bootstrap is skipped entirely — zero UCI mutation, zero `ifdown`/`ifup`, zero
route changes, zero counter resets:

| Attempt | Action | Backoff before the next attempt |
|---|---|---|
| 1 | Coordinated `wan6` restart | 10 min |
| 2 | DHCPv6 renew | 20 min |
| 3 | Escalate to a full WAN restart via the shared coordinator | 30 min (cap) |

Attempt 3 is still subject to the same-boot restart budget, the shared cooldown,
and the recovery hold. This ladder — not the bootstrap — is the normal prefix
recovery path.

##### CLEANUP_WAN128 is a separate setting

`CLEANUP_WAN128` is **not** related to `BOOTSTRAP_ENABLED` and does not enable or
disable anything experimental on its own:

| Value | Meaning |
|---|---|
| `0` (default) | **Retain** the WAN `/128`. A healthy IA_NA `/128` is optional and harmless, and is kept |
| `1` | Opt-in cleanup: remove the WAN `/128` after PD health is confirmed |

Under the v3.10 PD-first health model a WAN `/128` never substitutes for IA_PD
health, and its presence is not a fault, so there is normally nothing to clean
up. Leave it at `0`.

One practical consequence worth knowing: `CLEANUP_WAN128` is only read **inside**
the bootstrap stage. With `BOOTSTRAP_ENABLED=0` it never takes effect at all,
whatever it is set to. Setting `CLEANUP_WAN128=1` on its own does not cause the
watchdog to start removing `/128` addresses during normal operation.

#### D. Timing and source policy

| Variable | Default | Purpose |
|---|---|---|
| `WAN6_PENDING_GRACE` | `180` | Seconds to wait passively while DHCPv6 acquisition is in progress before treating it as failed |
| `SRC_POLICY_REFRESH` | `600` | Seconds between source-policy reclassifications when nothing else changed. A non-numeric value falls back to `600` |

Source policy also reclassifies immediately, ignoring this interval, whenever
the delegated prefix, the LAN source, the WAN `/128`, or the current gateway
changes.

#### E. Notifications (optional)

Only needed if you use the Discord logger. Core operation does not require
notifications, and the watchdog runs normally with no webhook configured.

```sh
# /etc/ipv6-watchdog.conf
DISCORD_WEBHOOK="<your-webhook-url>"
DISCORD_LOG_WEBHOOK="<your-log-webhook-url>"   # optional, falls back to the above
WATCH_TAGS="ipv6-setup|ipv6-watchdog|discord-logger"
```

Never commit this file, paste it into a bug report, or include it in a shared
backup archive.

#### Example

A minimal override file. Every line is optional.

```sh
# /etc/ipv6-watchdog.conf
# Tested baseline example. Omit any line to keep its default.

LAN_DEV="br-lan"
STICKY_GATEWAY=0
WAN_DISRUPTION_LIMIT=3
WAN_DISRUPTION_COOLDOWN=1200
```

All full-WAN recovery is gated by the shared lock, the disruption budget, the
cooldown, and the hold. A successful recovery does not refund budget; only a
reboot clears the same-boot count. Once the limit is reached, the hold blocks
all disruptive recovery for the rest of that boot while monitoring continues.

### Optional: sticky gateway

Disabled by default (`STICKY_GATEWAY=0`). It is **not required**, and normal
gateway repair works without it.

When enabled (`STICKY_GATEWAY=1`), the watchdog remembers the last gateway that
passed verification and, at the start of each tick, restores it if something
replaced it. It targets one specific pattern: a provider that periodically
advertises a gateway which is dead, causing the router to adopt it.

What enabling it changes:

- The watchdog records a verified-good gateway in `/tmp/ipv6-watchdog/good_gateway`.
- At the start of a tick, if the current gateway differs, it attempts to restore
  the remembered one before evaluating health.
- Restoration uses the same minimum-mutation and snapshot/rollback rules as
  normal repair. If restoring fails, the previous routes are put back exactly.

What it does **not** change:

- It does not bypass verification. A remembered gateway is still only kept if
  the kernel resolves the PD source through it and a PD-source-bound probe
  succeeds. A remembered gateway that has since died is rejected like any other
  failing candidate.
- It does not alter candidate discovery. If the sticky gateway fails, the normal
  candidate scan runs.
- It does not interact with source policy. Source policy preserves whatever
  gateway is in use and only adjusts the source attribute, so the two are
  independent.
- It does not consume disruption budget. Restoring a gateway is a route
  operation, not a disruptive one.

Enable it only if you have actually observed a dead gateway being re-advertised.
On a link with a single stable gateway it adds nothing.

```sh
# /etc/ipv6-watchdog.conf
STICKY_GATEWAY=1
```

Inspect the remembered value:

```sh
cat /tmp/ipv6-watchdog/good_gateway
```

The value is a link-local address such as `fe80::1`. It is cleared on reboot
along with the rest of `/tmp`.

---

## Optional and Supporting Component Behavior

Installation for these is in
[Optional and Supporting Components](#optional-and-supporting-components). This
section covers what they do.

### 97-garp (OPTIONAL)

**File:** [`97-garp`](97-garp) installed at `/etc/hotplug.d/iface/97-garp`

Runs on LAN bridge ifup. After a short settle delay it sends gratuitous ARP for
the router's LAN IPv4 address so clients refresh their ARP cache.

This matters only when you swap routers and reuse the same LAN IP: clients would
otherwise keep sending to the old MAC until their cache expires. It is unrelated
to IPv6 health and has no effect on recovery.

It reads `LAN_DEV` from `/etc/ipv6-watchdog.conf` if present, defaulting to
`br-lan`, and requires the `iputils-arping` package.

### ipv6-prefix-tracker (SUPPORTING)

**File:** [`ipv6-prefix-tracker`](ipv6-prefix-tracker) installed at
`/usr/bin/ipv6-prefix-tracker`, run every 5 minutes from cron

**Purely observational. It is not required for core health**, and the health
model does not consult it.

What it does:

- Compares the current delegated prefix against `/etc/ipv6-prefix-current`.
- Logs only on first initialization or on an actual change, so it does not spam.
- On a change, reloads odhcpd so LAN clients receive updated RA without waiting
  for the next interval.
- Optionally sends a notification if a webhook is configured.
- Stores state in `/etc`, so it survives reboots and does not re-announce a
  prefix that has not changed.

What it does not do: no recovery logic, no interface restarts, no interaction
with the escalation ladder, and no writes to recovery state. Its only system
side effect is the odhcpd reload.

It also checks for `/tmp/ipv6-watchdog/recovery_hold` before logging a
no-prefix message, so it stays quiet while the watchdog is already in a hold.
It only reads that file; it never creates or removes it.

### Cron entries

Both cron users are idempotent to add and are covered in the install sections.

| Component | Schedule | Line |
|---|---|---|
| `ipv6-watchdog` | every minute | `*/1 * * * * /usr/bin/ipv6-watchdog` |
| `ipv6-prefix-tracker` | every 5 minutes | `*/5 * * * * /usr/bin/ipv6-prefix-tracker` |

The watchdog uses an execution lock, so a tick that overruns a minute cannot
stack up behind the next one.

```sh
# Inspect what is scheduled
grep -n 'ipv6-' /etc/crontabs/root

# Confirm cron is running
/etc/init.d/cron status || ps | grep '[c]rond'
```
## Recovery Hold Detail

The hold is **shared coordination state owned by `wan-recovery-common`**, not
watchdog-local restart state. Earlier versions tracked restarts inside the
watchdog; that model no longer applies.

### The three limits, which are different things

| Concept | State | Meaning |
|---|---|---|
| Count | `/tmp/wan-recovery/disruption_count` | How many full-WAN cycles have run this boot |
| Cooldown | `/tmp/wan-recovery/last_full_wan_disruption` | Minimum spacing between cycles, default 1200 s |
| Hold | `/tmp/wan-recovery/disruption_hold` | Latched once the budget is spent. Blocks everything disruptive |

A cooldown block is temporary and clears with time. A hold does not clear with
time.

### When the hold latches

During a full-WAN recovery, accounting is written **before** any interface is
touched. If the incremented count reaches `WAN_DISRUPTION_LIMIT` (default 3),
the hold file is created in the same step.

Writing accounting first is deliberate: if power is lost partway through a WAN
cycle, the disruption still happened as far as the network is concerned, and
recording it first means a crash cannot produce an unbounded restart loop.

### What a hold prevents

While the hold file exists:

- Full-WAN recovery is blocked.
- **wan6-only recovery is also blocked.** The hold is checked by both coordinated
  paths, so it is not a partial brake.
- Non-disruptive work continues: health checks, logging, gateway and route
  repair, and source policy all keep running.

The router keeps monitoring and keeps fixing what it can fix without
disruption. It stops cycling interfaces.

### Lifecycle across reboot

All shared state lives under `/tmp`, which is tmpfs. A reboot clears the count,
the timestamps, and the hold. That is the intended reset: the budget is
per-boot by design.

`ifdown`/`ifup` do not reset it. Only an actual reboot does.

### Inspecting a hold

Read-only, safe at any time:

```sh
[ -f /tmp/wan-recovery/disruption_hold ] \
  && echo "HOLD ACTIVE" \
  || echo "no hold"

cat /tmp/wan-recovery/disruption_count         2>/dev/null || echo "0"
cat /tmp/wan-recovery/last_full_wan_disruption 2>/dev/null || echo "never"
cat /tmp/wan-recovery/last_full_wan_reason     2>/dev/null || echo "none"
cat /tmp/wan-recovery/last_wan6_action         2>/dev/null || echo "never"
cat /tmp/wan-recovery/last_wan6_reason         2>/dev/null || echo "none"

logread | grep -iE "recovery hold|disruption" | tail -20
```

The reason files are the useful part. They record why the last action was taken,
which usually points straight at the underlying problem.

### Clearing a hold manually

> **A hold is a protective state, not an error.** It means the router already
> spent its disruption budget without fixing the problem. That is nearly always
> evidence of a fault the router cannot fix: a provider outage, a line fault, or
> an ONT problem. Clearing the hold does not fix any of those.

**Clearing the hold re-arms disruptive recovery.** If the underlying fault is
still present, the router will begin cycling WAN again, which can make an
already-unstable connection worse and will disrupt any working IPv4 alongside it.

Diagnose first. Read the reason files, check the logs, and confirm the provider
side is actually healthy again.

If you have established the cause is resolved and you do not want to wait for a
reboot:

```sh
# Re-arms disruptive recovery. Understand why the hold latched first.
rm -f /tmp/wan-recovery/disruption_hold
rm -f /tmp/wan-recovery/disruption_count
```

Removing only the hold file while leaving the count at or above the limit will
not help: the count alone re-latches the hold on the next evaluation. Clear both
or reboot.

A reboot is the cleaner option in almost every case.

---

## Troubleshooting

Work from symptoms. Every check here is read-only unless a subsection is
explicitly marked otherwise.

Collect the shared context first, exactly as in
[Post-Deploy Verification](#post-deploy-verification):

```sh
WAN_DEV="$(ubus call network.interface.wan6 status 2>/dev/null \
  | jsonfilter -e '@["l3_device"]')"
LAN_PD_SRC="$(cut -d'|' -f3 /tmp/ipv6-watchdog/src_policy_key 2>/dev/null)"
echo "WAN_DEV=${WAN_DEV:-<none>}  LAN_PD_SRC=${LAN_PD_SRC:-<none>}"
```

### Case 1: no IA_PD (no delegated prefix)

```sh
ubus call network.interface.wan6 status | jsonfilter -e '@["ipv6-prefix"]'
ubus call network.interface.wan6 status | jsonfilter -e '@["up"]'
logread | grep -iE "ipv6-watchdog|odhcp6c" | tail -30
```

**Interpretation.** Empty `ipv6-prefix` means the provider is not delegating, or
`wan6` never completed DHCPv6. Nothing downstream can work.

Source policy cannot help here, and neither can route repair. Both operate on a
prefix that does not exist.

**Next.** Confirm `wan6` is up at all. Check whether `reqprefix` matches what
your provider actually delegates (see
[Configuration](#configuration); it is provider-dependent). If the
provider answers `NoPrefixAvail`, that is an upstream condition and the watchdog
will escalate through its ladder with backoff rather than hammering.

### Case 2: IA_PD exists but no LAN PD-derived source

```sh
ip -6 addr show dev br-lan scope global
uci get network.lan.ip6assign
uci get network.lan.ip6class
```

**Interpretation.** Look for an address inside the delegated prefix. Common
causes:

- `ip6assign` or `ip6class` not set, so LAN never receives a `/64`.
- The only global addresses are unique-local (`fd00::/8`), which are never valid
  PD sources.
- Addresses exist but are marked `deprecated`, `tentative`, or `dadfailed`, all
  of which are excluded.

```sh
ip -6 addr show dev br-lan | grep -E "deprecated|tentative|dadfailed"
```

**Next.** Fix LAN delegation config, then apply with `ubus call network reload`.
Do not restart the LAN interface.

### Case 3: PD and LAN source exist, generic default route missing

```sh
ip -6 route show default
ip -6 route show default | grep -v ' from '   # the generic default
ip -6 neigh show dev "$WAN_DEV" | grep router
logread | grep -iE "ipv6-setup|gateway" | tail -20
```

**Interpretation.** No output from the second command means there is no generic
default. A `default from ...` line alone is not sufficient.

**Next.** `99-ipv6-setup` installs this on `wan6` ifup and the watchdog repairs
it within a minute. If neither has, check both are installed and that cron is
running. A gateway in `INCOMPLETE` or `FAILED` state points at Case 10.

### Case 4: generic default exists, effective route from PD source fails

```sh
ip -6 route get 2001:4860:4860::8888 from "$LAN_PD_SRC"
```

**Interpretation** by output:

| Output contains | Meaning |
|---|---|
| `unreachable` | No usable path for that source. Often a missing or wrong default |
| `prohibit` | A policy rule is rejecting it |
| `blackhole` | Traffic is being discarded deliberately |
| `throw` | Lookup escaped the table without resolving |
| `dev` is not `$WAN_DEV` | Routed out the wrong interface, for example the LAN bridge or a tunnel |
| no `via` on a link-local next hop | Missing interface context; see [Gateway and Route Repair](#gateway-and-route-repair) |

**Next.** This is the layer the watchdog repairs. Check the logs for gateway
selection, and confirm a candidate is actually being accepted.

### Case 5: effective route works but PD-source Internet fails

```sh
ip -6 route get 2001:4860:4860::8888 from "$LAN_PD_SRC"   # passes
ping6 -c 2 -W 3 -I "$LAN_PD_SRC" 2001:4860:4860::8888     # fails
ping6 -c 2 -W 3 -I "$LAN_PD_SRC" 2606:4700:4700::1111     # fails
```

**Interpretation.** The kernel has a route but packets are not getting answers.
Routing is correct locally; the problem is beyond the router. Typical causes are
a gateway that answers neighbor discovery but does not forward, or an upstream
outage.

**Next.** Try the other public target to rule out a single-destination problem.
Check the gateway's neighbor state (Case 10). If a different gateway is
available, the watchdog will try it; watch the logs for candidate trials.

### Case 6: IA_NA absent

```sh
ip -6 addr show dev "$WAN_DEV" | grep '/128 scope global'
```

Empty output. **This alone is not a fault.** A WAN `/128` is optional. If your
PD path is healthy, there is nothing to do. Source policy stays `native`.

### Case 7: IA_NA present and usable

```sh
WAN128="$(ip -6 addr show dev "$WAN_DEV" \
  | awk '/inet6 .*\/128 scope global/{print $2}' | sed 's|/128$||' | head -1)"
ping6 -c 2 -W 3 -I "$WAN128" 2001:4860:4860::8888
```

Replies, and the PD path is also healthy. **Healthy.** Source policy should be
`native`: the kernel is already selecting a source that works, so nothing is
imposed.

### Case 8: IA_NA present but unusable while PD works

The `/128` probe fails, the PD-source probe passes. **Expected policy is
`pd-preferred`.**

```sh
cat /tmp/ipv6-watchdog/src_policy_mode
cat /tmp/ipv6-watchdog/src_policy_managed_src
cat /tmp/ipv6-watchdog/src_policy_ts
cut -d'|' -f1-4 /tmp/ipv6-watchdog/src_policy_key
ip -6 route show default | grep -v ' from '
ip -6 route get 2001:4860:4860::8888
logread | grep -i "Router source policy" | tail -10
```

**Interpretation.** In `pd-preferred` the generic default carries a `src`
matching the PD-derived address, and the unbound route lookup selects it.

If the mode is still `native`, the watchdog may not have reclassified yet.
Reclassification is immediate when the prefix, LAN source, `/128`, or gateway
changes, and otherwise happens on the refresh interval (600 s default). Wait a
tick or two before concluding anything is wrong.

### Case 9: pd-preferred is set but the preferred src disappeared

Route refreshes from RA or `netifd` can silently drop the source attribute while
leaving the gateway intact. The watchdog restores it on the next tick without
re-probing.

```sh
ip -6 route show default | grep -v ' from '
cat /tmp/ipv6-watchdog/src_policy_managed_src
logread | grep -i "restored preferred src" | tail -5
```

Distinguish the three ownership situations:

| `managed_src` | Route `src` | Meaning |
|---|---|---|
| matches PD source | matches | Watchdog owns it. It will restore it if removed |
| empty | present and correct | An administrator set it. The watchdog uses it but never claimed it, and will not remove it |
| set, but route `src` differs | differs | Something external changed the route. The watchdog preserves that change and releases its claim |

**Do not delete source-policy state as a first step.** The third row is the
safety rule working correctly, not a fault.

### Case 10: wrong or unusable gateway

```sh
ip -6 route show default | grep -v ' from '
ip -6 neigh show dev "$WAN_DEV" | grep router
ip -6 route get 2001:4860:4860::8888 from "$LAN_PD_SRC"
logread | grep -iE "gateway|candidate" | tail -20
```

**Interpretation.** A gateway in `INCOMPLETE` or `FAILED` state is not usable. If
more than one router appears, the wrong one may have been adopted from RA.

**Next.** The watchdog discovers candidates from neighbor and route evidence
and accepts one only when the kernel resolves the PD source through it and a
PD-source-bound probe succeeds. Before each trial it snapshots the default
routes and restores them exactly if the trial fails, so a failed attempt does not
leave the table worse. If dead gateways keep returning via RA, consider
[sticky gateway](#optional-sticky-gateway).

### Case 11: recovery hold active

```sh
[ -f /tmp/wan-recovery/disruption_hold ] && echo "HOLD ACTIVE"
cat /tmp/wan-recovery/disruption_count     2>/dev/null
cat /tmp/wan-recovery/last_full_wan_reason 2>/dev/null
```

**Interpretation.** The router spent its per-boot disruption budget without
resolving the problem, and deliberately stopped cycling interfaces. Monitoring
and non-disruptive repair continue.

This is protective, not a malfunction. Read the reason file: it records why the
last full-WAN action was taken. See
[Recovery Hold Detail](#recovery-hold-detail) before clearing anything.

### Case 12: disruption limit reached, and what "blocked" means

Three different blocks look similar in logs but mean different things:

| Blocked by | Duration | Clears when |
|---|---|---|
| Cooldown | Temporary, default 1200 s | Enough time passes |
| wan6 grace | Temporary, default 60 s | Enough time passes after a wan6 action |
| Hold | Until reboot | Reboot, or a deliberate manual reset |

```sh
cat /tmp/wan-recovery/disruption_count
cat /tmp/wan-recovery/last_full_wan_disruption   # epoch seconds
date +%s                                          # compare against the above
```

If the elapsed time is under the cooldown, recovery is spaced, not stopped.

### Case 13: coordinator missing or incomplete

```sh
ls -l /usr/bin/wan-recovery-common
sh -n /usr/bin/wan-recovery-common && echo "syntax ok"

for fn in wan_recovery_full_begin \
          wan_recovery_full_execute_locked \
          wan_recovery_wan6_begin \
          wan_recovery_wan6_record_locked \
          wan_recovery_end \
          wan_recovery_cleanup; do
    grep -q "^${fn}()" /usr/bin/wan-recovery-common \
      && echo "ok      $fn" \
      || echo "MISSING $fn"
done
```

**Interpretation.** A missing file or any `MISSING` line means the watchdog
fails closed: health checks, logging, and non-disruptive route repair continue,
but no disruptive recovery will run.

This is the most common consequence of a firmware upgrade that did not preserve
the file. See
[Preserving Scripts Across Firmware Upgrades](#preserving-scripts-across-firmware-upgrades).

**Next.** Reinstall the coordinator, then confirm the interface check passes.

### Case 14: wan6-only action versus full-WAN recovery

```sh
cat /tmp/wan-recovery/last_wan6_action         2>/dev/null || echo "never"
cat /tmp/wan-recovery/last_wan6_reason         2>/dev/null || echo "none"
cat /tmp/wan-recovery/last_full_wan_disruption 2>/dev/null || echo "never"
cat /tmp/wan-recovery/last_full_wan_reason     2>/dev/null || echo "none"
cat /tmp/wan-recovery/disruption_count         2>/dev/null || echo "0"
```

**Interpretation.** A wan6-only action cycles `wan6` alone. It is recorded with
a timestamp and reason, but **does not consume full-WAN budget** and does not
increment `disruption_count`. It is still blocked by an active hold.

A full-WAN action cycles both interfaces, increments the count, and can latch the
hold. If `last_wan6_action` is recent but the count has not moved, only the
lighter action ran. That is the intended behavior.

### Case 15: router-default fails but PD-source passes

```sh
ping6 -c 2 -W 3 2001:4860:4860::8888                  # unbound, fails
ping6 -c 2 -W 3 -I "$LAN_PD_SRC" 2001:4860:4860::8888 # PD-bound, passes
```

**This is a source-selection symptom, not a broken connection.** The kernel is
choosing an unusable source, almost always an IA_NA `/128`, for router-originated
traffic. LAN clients are unaffected and household IPv6 is healthy.

**Do not diagnose this as total IPv6 failure.** Check source policy first
(Case 8). Once `pd-preferred` is in effect, the unbound test should pass too.

### Case 16: cron logs at cron.err

BusyBox cron logs job launches at `cron.err` priority. Seeing `ipv6-watchdog`
lines at that priority is **normal cron behavior and not evidence of failure**.

Judge the watchdog by its own messages:

```sh
logread | grep ipv6-watchdog | grep -v crond | tail -30
logread | grep -i "Router source policy" | tail -10
logread | grep ipv6-setup | tail -20
```

### Case 17: the delegated prefix changed

```sh
ubus call network.interface.wan6 status | jsonfilter -e '@["ipv6-prefix"][0].address'
ip -6 addr show dev br-lan scope global
cut -d'|' -f1-4 /tmp/ipv6-watchdog/src_policy_key
cat /tmp/ipv6-watchdog/src_policy_managed_src
ip -6 route show default
cat /etc/ipv6-prefix-current 2>/dev/null    # if the tracker is installed
logread | grep -i "ipv6-prefix" | tail -10
```

**Interpretation.** A new prefix changes the LAN source, which changes the
source-policy cache key, which forces immediate reclassification.

Any source the watchdog owned under the old prefix is now stale. It releases
that ownership safely: if the route still carries the old source it removes it,
and if something else has changed the route in the meantime it leaves the route
alone and just drops its claim. Deprecated LAN addresses from the old prefix are
cleaned up separately.

**Next.** Expect a brief window where clients still hold old addresses. If the
prefix tracker is installed it reloads odhcpd so RA updates promptly.

### Case 18: Discord logger issues

Notification problems are **entirely separate from IPv6 health and recovery**. A
broken logger does not affect route repair, source policy, or recovery
coordination.

```sh
grep -c DISCORD /etc/ipv6-watchdog.conf 2>/dev/null || echo "no config"
command -v curl >/dev/null && echo "curl present" || echo "curl MISSING"
/etc/init.d/ipv6-discord-logger status 2>/dev/null || ps | grep '[i]pv6-discord'
logread | grep discord-logger | tail -10
```

**Interpretation.** With no webhook configured, the logger exits immediately and
logs that it did. That is expected when notifications are not in use.

`WATCH_TAGS` controls which syslog tags are forwarded. The default is
`ipv6-setup|ipv6-watchdog|discord-logger`.

Use `restart` rather than a manual kill followed by start; the service is
procd-managed and manual handling can leave duplicate instances.

### Commands that change state

Everything above is read-only. The commands below are not. Use them only after
diagnosis, and understand the consequence of each.

> **Never restart the LAN interface** while `wan6` is up with an active
> delegated prefix. odhcpd marks the prefix stale and withdraws IPv6 from all
> LAN clients.

| Action | Consequence |
|---|---|
| `ubus call network reload` | Applies config without tearing down the network. Safest option |
| `/etc/init.d/odhcpd restart` | Refreshes LAN RA and DHCPv6. Brief client-side gap |
| `ifdown wan6; ifup wan6` | Forces DHCPv6 re-negotiation. IPv6 drops while it runs. Uncoordinated: the coordinator neither serializes nor records it |
| `rm /tmp/wan-recovery/disruption_hold` | Re-arms disruptive recovery. See [Recovery Hold Detail](#recovery-hold-detail) |
| Reboot | Clears all `/tmp` state including the disruption budget. Usually the cleanest reset |

Prefer letting the watchdog act. It applies the same operations under a shared
lock, with a budget, a cooldown, and accounting, none of which apply when you run
them by hand.
## State File Reference

Every file below is derived from the current source. Both directories are on
tmpfs, so **a reboot clears all of it**. That is intentional: the disruption
budget is per-boot.

Absence is normal for most of these. A file usually appears only once the
condition it records has occurred.

> **General rule: observe freely, edit nothing.** Reading any of these is safe.
> Deleting them is not equivalent to fixing the condition they record, and for
> a few it re-arms behavior that was deliberately stopped. Files needing
> particular care are marked.

### /tmp/ipv6-watchdog/ (owned by `ipv6-watchdog`)

| File | Purpose | Value | Absent when |
|---|---|---|---|
| `fail_count` | Consecutive health-check failures | integer | No failure recorded since last success |
| `prefix_fail_count` | Consecutive missing-prefix attempts, drives the ladder | integer | Prefix has not been missing |
| `prefix_next_attempt` | Earliest time the next prefix attempt may run (backoff) | epoch seconds | No backoff active |
| `tier0_fail_count` | Consecutive failures of the wan6-down recovery tier | integer | Tier has not fired |
| `good_gateway` | Last verified-good gateway, used by sticky gateway | link-local address | Sticky gateway disabled, or none verified yet |
| `wan6_pending_seen` | First time `wan6` was seen mid-acquisition | epoch seconds | Not pending |
| `wan6_pending_expired` | Marks that a pending grace already expired for this acquisition | marker | Grace has not expired |
| `hold_status` | Last classified hold state, for state-change-only logging | short string | No hold evaluated |
| `ont_notified` | Marks that the escalation notice was already sent | marker | Not sent this incident |
| `src_policy_mode` | Source policy classification | `native` or `pd-preferred` | Not yet classified since boot |
| `src_policy_key` | Cache identity, pipe-separated `WAN128\|PD_CIDR\|LAN_PD_SRC\|gateway` | 4 fields | Not yet classified |
| `src_policy_ts` | Time of last classification | epoch seconds | Not yet classified |
| `src_policy_managed_src` | The source the watchdog **successfully installed** and therefore owns | address, or empty | Watchdog owns no source. Normal in `native`, and also normal in `pd-preferred` when an administrator set the source |
| `watchdog.lock` | Per-run execution lock, prevents overlapping ticks | lock file | Between ticks |
| `watchdog.lock.dir` | Fallback lock when flock is unavailable | lock directory | Between ticks |
| `fix_gateway_routes.*` | Transient route snapshot during a gateway trial | raw route lines | No trial in progress. Cleaned up on exit |
| `c2_migrated` | One-time marker that legacy state was merged into shared state | marker | Migration has not run this boot |
| `wan_restart_count` | Legacy mirror of the shared disruption count | integer | Kept for external tooling. **Not authoritative** |
| `last_wan_restart` | Legacy mirror of the shared timestamp | epoch seconds | Kept for external tooling. **Not authoritative** |
| `recovery_hold` | Legacy mirror of the shared hold latch | marker | Kept for external tooling. **Not authoritative** |

The last three exist only so external tools written against older versions keep
working. The authoritative values live in `/tmp/wan-recovery/`. Do not diagnose
from the mirrors.

**Care needed:** `src_policy_managed_src` records ownership. Deleting it makes
the watchdog forget it installed a source, so it will neither restore nor clean
up that source. It is not a reset button; see
[Case 9](#case-9-pd-preferred-is-set-but-the-preferred-src-disappeared).

### /tmp/wan-recovery/ (owned by `wan-recovery-common`)

| File | Purpose | Value | Absent when |
|---|---|---|---|
| `disruption_count` | Full-WAN cycles used this boot | integer | None yet this boot |
| `last_full_wan_disruption` | When the last full-WAN cycle started, drives cooldown | epoch seconds | Never run this boot |
| `last_full_wan_reason` | Why the last full-WAN cycle ran | short text | Never run this boot |
| `last_wan6_action` | When the last wan6-only action ran, drives the grace window | epoch seconds | Never run this boot |
| `last_wan6_reason` | Why the last wan6-only action ran | short text | Never run this boot |
| `disruption_hold` | Latched once the budget is exhausted. Blocks all disruptive recovery | marker | Budget not exhausted. **Expected absent on a healthy router** |
| `disruption.lock` | Shared serialization lock, flock-based | lock file | No disruptive action in progress |
| `disruption.lock.dir` | Shared lock fallback when flock is unavailable | lock directory | No disruptive action in progress |

**Care needed:** `disruption_hold` and `disruption_count` together bound how
much the router may disrupt the connection. Clearing them re-arms disruptive
recovery, and if the underlying fault persists the router will start cycling WAN
again. Read [Recovery Hold Detail](#recovery-hold-detail) first. A reboot is
usually the better reset.

The lock files are managed automatically, including stale-lock detection for a
lock left behind by a process that died. Do not remove them by hand while the
watchdog may be running.

### Persistent state outside /tmp

| File | Owner | Purpose |
|---|---|---|
| `/etc/ipv6-prefix-current` | `ipv6-prefix-tracker` | Last observed delegated prefix, so a reboot does not re-log initialization |
| `/etc/ipv6-watchdog.conf` | operator | Optional configuration. May contain webhook secrets. Mode `0600` |

---

## Validated Behavior

Two evidence categories are distinguished below. Neither is a claim about how
every provider behaves.

- **Test-validated:** proven by the deterministic regression suites, which mock
  the router interfaces. Reproducible by anyone.
- **Field-observed:** seen on real hardware during development. Indicative, not
  a general rule about any ISP.

### Health model

| Behavior | Evidence |
|---|---|
| Delegated prefix + PD-derived LAN source + PD-source reachability passing is classified healthy | Test-validated |
| A healthy PD path with **no** WAN `/128` is classified healthy, policy `native` | Test-validated |
| A healthy PD path with a **usable** `/128` is classified healthy, policy `native` | Test-validated |
| A healthy PD path with an **unusable** `/128` is classified healthy, with policy `pd-preferred` for router-originated traffic | Test-validated, field-observed |
| A failing PD-source probe is classified unhealthy regardless of `/128` state | Test-validated |
| Generic-default-only routing, with no source-specific rule, is classified healthy | Test-validated, field-observed |
| An IA_NA failure alone never increments a recovery counter or consumes disruption budget | Test-validated |
| Transient reachability failures are re-checked before being treated as real | Test-validated |

### Source policy

| Behavior | Evidence |
|---|---|
| A preferred source is installed on the generic default while gateway, `dev`, `proto`, `metric` and `pref` are preserved | Test-validated, field-observed |
| A source-specific `default from <prefix>` route is never modified by source policy | Test-validated |
| Ownership is recorded only after the route change actually succeeds | Test-validated, field-observed |
| A failed route mutation records no ownership, so a later cleanup cannot strip a source the watchdog never set | Test-validated, field-observed |
| An administrator-set source is used but never claimed, and never removed | Test-validated |
| If the route source is changed externally, the watchdog preserves the change and releases its own claim | Test-validated |
| A silently removed preferred source is restored from cache without re-probing | Test-validated, field-observed |
| Ownership from a previous prefix is released safely when the prefix changes | Test-validated |

### Gateway and route repair

| Behavior | Evidence |
|---|---|
| A candidate is accepted only when the kernel resolves the PD source through it and a PD-source-bound probe passes | Test-validated |
| A gateway that answers locally but cannot reach the Internet is rejected | Test-validated, field-observed |
| Already-effective routing is left completely unchanged | Test-validated |
| After a failed candidate trial, the exact prior routes are restored from snapshot | Test-validated |
| A pre-existing unrelated route survives both failed and successful repair | Test-validated |
| Generic default routes are read without a device selector so the replayed line keeps its interface context | Test-validated, field-observed |

### Recovery coordination

| Behavior | Evidence |
|---|---|
| With the coordinator missing or its interface incomplete, disruptive recovery fails closed while monitoring continues | Test-validated |
| Accounting is written before the first destructive command, so an interrupted cycle is still recorded | Test-validated |
| Health is re-checked after acquiring the lock, so a connection that recovered while waiting is not torn down | Test-validated |
| An exhausted budget latches the hold and blocks further disruptive recovery until reboot | Test-validated |
| A wan6-only action does not consume full-WAN budget but is still blocked by an active hold | Test-validated |
| Only one disruptive action can run at a time, enforced by a shared lock | Test-validated |

### Field observations

Seen on real hardware. Provider behavior varies, so treat these as context
rather than as rules.

- A dead gateway re-advertised by RA was detected and replaced within one tick.
- ONT power cycling was handled without manual intervention.
- `accept_ra='2'` with `defaultroute='0'` was unstable and is documented as a
  configuration to avoid.
- DHCPv6 renew recovered a prefix within the same cycle where the provider
  simply needed a re-request.
- Backoff prevented repeated DHCPv6 requests during a `NoPrefixAvail` condition.

---

## Regression Tests

The repository includes automated regression tests for prefix handling, gateway
repair, source policy, recovery coordination, and related IPv6 logic.

They use mocked network interfaces and are intended to validate changes to the
project. Normal users do not need to run them, and they are not a substitute for
live router health checks.

For live deployments, use
[Post-Deploy Verification](#post-deploy-verification) instead.

If you are changing the project and want to run the full suite:

```sh
for t in tests/*.sh; do
    echo "=== $t ==="
    timeout 600 sh "$t" | tail -3
done
```

Run from a POSIX shell environment.

## Preserving Scripts Across Firmware Upgrades

A sysupgrade wipes `/usr/bin` and `/etc/hotplug.d`. Anything not listed in
`/etc/sysupgrade.conf` is gone after a firmware flash.

### Core v3.10 (always preserve)

```sh
cat >> /etc/sysupgrade.conf << 'EOF'
/usr/bin/wan-recovery-common
/etc/hotplug.d/iface/99-ipv6-setup
/usr/bin/ipv6-watchdog
/etc/crontabs/root
EOF
```

> **`/usr/bin/wan-recovery-common` matters most here.** If the coordinator is
> missing after a flash but the watchdog survives, the watchdog starts in
> monitoring-only mode: it keeps checking health and repairing routes, but it
> will not perform any disruptive recovery. Losing this one file silently
> disables the recovery ladder.

### Conditional entries

Add only the lines matching what you actually installed.

```sh
# If you installed 97-garp
echo '/etc/hotplug.d/iface/97-garp' >> /etc/sysupgrade.conf

# If you installed the prefix tracker
echo '/usr/bin/ipv6-prefix-tracker' >> /etc/sysupgrade.conf

# Optional: keeps the tracker from re-logging "Prefix initialized" after a
# flash, since the prefix is usually unchanged
echo '/etc/ipv6-prefix-current' >> /etc/sysupgrade.conf

# If you use the Discord logger
cat >> /etc/sysupgrade.conf << 'EOF'
/usr/bin/ipv6-discord-logger
/etc/init.d/ipv6-discord-logger
EOF

# If you customized sysctl
echo '/etc/sysctl.conf' >> /etc/sysupgrade.conf

```

### Configuration file

```sh
echo '/etc/ipv6-watchdog.conf' >> /etc/sysupgrade.conf
```

`/etc/ipv6-watchdog.conf` is optional. Preserve it if you created one.

> **This file may contain secrets.** If you use Discord notifications, it holds
> your webhook URLs. Keep it at mode `0600`, never commit it to a repository,
> and treat any backup archive containing it as private. Do not paste its
> contents into issue reports or forums.

### Verify and back up

```sh
# Review the final list, and remove any duplicate lines you may have added
sort -u /etc/sysupgrade.conf

# Confirm every listed path actually exists
while read -r p; do
    case "$p" in ''|\#*) continue ;; esac
    [ -e "$p" ] && echo "ok      $p" || echo "MISSING $p"
done < /etc/sysupgrade.conf
```

Do not add working directories or scratch folders that only exist on your own
machine.

Then generate a backup via LuCI: **System -> Backup / Flash Firmware -> Generate archive**.

---

## Known Edge Cases

Real-world situations observed during development. These are not normal
operation, but they are worth understanding before diagnosing one.

### 1. wan6 fails to acquire a prefix after reboot

`wan6` comes up but no delegated prefix appears. Causes range from a startup
race, to the provider not answering, to a stale lease upstream.

**Automatic handling.** The escalation ladder runs with increasing backoff:

| Attempt | Action |
|---|---|
| 1 | Coordinated `wan6` restart |
| 2 | DHCPv6 renew, no interface teardown |
| 3 | Coordinated full-WAN recovery |
| 4+ | Coordinated full-WAN recovery, subject to budget, cooldown and hold |

The experimental IA_NA-assisted bootstrap is **disabled by default**
(`BOOTSTRAP_ENABLED=0`) and is skipped entirely. It is not a normal recovery
tier. When explicitly enabled it occupies attempt 3 and shifts full-WAN recovery
to attempt 4. Its effectiveness is an untested hypothesis, so enabling it is not
recommended.

Once the per-boot budget is spent the hold latches and the router switches to
passive monitoring rather than cycling WAN indefinitely.

### 2. IPv6 works, then stops later

Usually a gateway that died after being selected, or an RA that reinstalled a
dead gateway. The watchdog detects this within a tick and re-selects a verified
candidate, restoring the previous routes exactly if a candidate fails.

If it recurs on a schedule, consider
[sticky gateway](#optional-sticky-gateway).

### 3. Multiple IPv6 gateways on the WAN link

Normal on some providers. Having more than one router advertise is not itself a
fault; adopting a dead one is. Candidate selection tests each against the PD
source rather than trusting RA order.

### 4. More than one default route present

Also normal. A generic default and a source-specific `default from <prefix>`
route can legitimately coexist.

**Do not treat extra default routes as a fault, and do not delete the
source-specific one.** Where it already exists it is maintained; it is never
required and never manufactured. Health is decided by effective routing, not by
counting lines. See
[Gateway and Route Repair](#gateway-and-route-repair).

### 5. IPv6 fails briefly after an ONT reset or line disturbance

Expected. The delegated prefix may be withdrawn and reissued. The watchdog waits
out the acquisition grace rather than acting immediately, since interrupting
`odhcp6c` mid-acquisition makes recovery slower, not faster.

If the prefix comes back changed, see case 8 below.

### 6. Browser reports IPv6 available but not used

Usually a client-side preference or a DNS result, not a router fault. Confirm
the router side first with
[Post-Deploy Verification](#post-deploy-verification). If the PD-source probe
passes and clients hold addresses from the delegated prefix, the router is doing
its job.

### 7. The route refresh drops the preferred source

`netifd` or an RA-driven refresh can rewrite the generic default and silently
drop the source attribute while leaving the gateway intact. Under `pd-preferred`
the watchdog restores it on the next tick, using the cached classification
without re-probing.

Repeated restore messages in the log indicate something is refreshing the route
frequently. That is worth investigating, but the restore itself is working as
designed.

### 8. The delegated prefix changes

Every downstream value changes with it: the LAN `/64`, the LAN source, and the
source-policy cache key. Reclassification is immediate rather than waiting for
the refresh interval.

Any source the watchdog owned under the old prefix is stale. It is released
safely: removed if the route still carries it, or simply un-claimed if something
else has since modified the route. Deprecated LAN addresses from the old prefix
are cleaned up separately.

Clients may briefly hold addresses from the old prefix until RA updates them.

### 9. An administrator sets a source on the default route

Fully supported. The watchdog will use an existing correct source but never
records ownership of it, so it will never remove it. If the source differs from
what policy would choose, the watchdog preserves the administrator's value and
releases any claim it held.

A mismatch between `src_policy_managed_src` and the route's actual source is
evidence the safety rule worked, not a fault.

### 10. Cached policy state is missing or corrupted

Cleanup is driven by the ownership record together with the current route state,
not by the cached mode alone. If the mode file is deleted or unreadable, the
watchdog still finds a source it owns and cleans it up correctly, and still
refuses to touch one it does not own.

### 11. A reboot clears recovery state

All `/tmp` state, including the disruption count and any hold, is cleared by a
reboot. This is intentional: the budget is per-boot.

A reboot is therefore the cleanest way to clear a hold, and is safer than
deleting state files by hand. See
[Recovery Hold Detail](#recovery-hold-detail).

### 12. The coordinator goes missing after a firmware upgrade

The most likely way to end up with a monitoring-only router. If
`/usr/bin/wan-recovery-common` is not in the sysupgrade preserve list, a flash
removes it while leaving the watchdog installed. The watchdog then fails closed:
it monitors, logs, and repairs routes, but performs no disruptive recovery.

Diagnosis is in
[Case 13](#case-13-coordinator-missing-or-incomplete). Prevention is in
[Preserving Scripts Across Firmware Upgrades](#preserving-scripts-across-firmware-upgrades).

### 13. Provider behavior differs from this guide

Expected. Several settings in
[Configuration](#configuration) are provider-dependent rather than
universal, in particular `reqaddress`, `reqprefix`, `sourcefilter`, and
`norelease`.

If your provider delegates a different prefix length, or hands out a usable
`/128`, or behaves differently on DHCPv6 Release, that is not a fault to correct.
The health model reads what the running system actually has rather than
enforcing a configuration shape.

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

By default, OpenWrt assigns the router's own LAN IPv6 address using suffix `::1` from the delegated prefix (for example `2001:db8:xxxx:xxxx::1/64`, using RFC 3849 documentation space). This is the address the router presents on `br-lan`.

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

**File:** [`ipv6-discord-logger`](ipv6-discord-logger) -> `/usr/bin/ipv6-discord-logger`

Tails `logread -f` and forwards any line tagged with your script names to Discord. No existing scripts need to be modified. Any future scripts using `logger -t` with a watched tag are picked up automatically.

Install it using the wget or curl procedure in
[Optional and Supporting Components](#optional-and-supporting-components),
which downloads to a temporary file, validates it, sets the mode, and moves it
into place.

The default `WATCH_TAGS` is:

```sh
WATCH_TAGS="ipv6-setup|ipv6-watchdog|discord-logger"
```

That covers this repository's core scripts. Other tags, including the prefix
tracker's, are not watched by default. To forward logs from additional scripts,
set your own list in `/etc/ipv6-watchdog.conf`, keeping the tags you still want:

```sh
WATCH_TAGS="ipv6-setup|ipv6-watchdog|discord-logger|ipv6-prefix"
```

Then restart the logger to pick up the change:

```sh
/etc/init.d/ipv6-discord-logger restart
```

### Step C - Deploy the init.d service

**File:** [`init.d-ipv6-discord-logger`](init.d-ipv6-discord-logger) -> `/etc/init.d/ipv6-discord-logger`

Manages the log forwarder as a procd service with automatic restart. Deploy together with `ipv6-discord-logger`; both ship in the same repo release.

Install it using the same procedure in
[Optional and Supporting Components](#optional-and-supporting-components), then
enable and start the service:

```sh
/etc/init.d/ipv6-discord-logger enable
/etc/init.d/ipv6-discord-logger restart
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

### v3.10.2 — 2026-08-19

Maintenance release. Retires the legacy `98-wan6-delay` helper and cleans up the
documentation, test inventory, and Git attributes that referenced it. **No
retained/core router-side script changed**: `ipv6-watchdog`,
`wan-recovery-common`, `99-ipv6-setup`, and every other retained deployed
component are byte-identical to v3.10.1. The only router-side artifact removed is
the retired `98-wan6-delay` helper itself.

**98-wan6-delay retired**

- `98-wan6-delay` has been REMOVED from the repository and from the current
  installation, backup, component, and sysupgrade-preservation instructions.
- It ran on WAN ifup and performed its own `wan6` restart with a fixed delay,
  outside the recovery coordination layer — so that cycle was never serialized
  against, nor recorded by, the coordinator. Since v3.10.0 it had already been
  reclassified as legacy and excluded from the core stack and Quick Deploy.
- Retirement was **production-validated on the two project Flint2 deployments**
  before removal. One had already run healthily without it, including through a
  genuine restart-assisted WAN/IPv6 recovery. The other was validated across a
  full reboot: `wan6` came up normally, `IA_PD` was acquired and delegated to
  LAN, the initial upstream gateway was unusable and `99-ipv6-setup` discovered
  the alternate gateway and verified PD-source reachability, `ipv6-watchdog`
  observed its boot grace and then established the sticky-gateway baseline and
  source policy, and both IPv4 and IPv6 reachability passed. No full WAN restart
  occurred and no recovery state was set.
- **This is not a claim that a boot-timing helper is unnecessary on every
  OpenWrt deployment.** It was validated as unnecessary on these two Flint2
  routers, on this firmware, with this stack. Other hardware or firmware may
  still race on boot.

**Cleanup**

- Removed the `98-wan6-delay` install, backup, component-table, component
  reference, and `sysupgrade.conf` preserve instructions from the README.
- Removed its `.gitattributes` LF entry.
- Removed it from the `ROUTER_SCRIPTS` inventory in
  `tests/test-ash-compat.sh`.
- All historical changelog entries referencing `98-wan6-delay` are preserved
  unchanged as release history.

**Existing deployments**

This release does not modify anything already installed on your router. If a
copy of `98-wan6-delay` exists on your device it stays there until you remove it
yourself. Removal is optional. If your hardware genuinely needs the delay, keep it
— retrieve it from Git history with `git show v3.10.1:98-wan6-delay` and back it
up before changing anything. If you do retire it, also remove its
`/etc/sysupgrade.conf` preserve entry, or the entry will outlive the file it
names.

The active stack is `99-ipv6-setup`, `ipv6-watchdog`, and `wan-recovery-common`.

### v3.10.1

Closes a reporting gap, not a routing gap. No change to the PD-first health
model, source-aware routing, shared recovery coordination, or the same-boot
restart budget.

**Ordinary recovery closure**

- A confirmed connectivity incident that ends *without* a full WAN restart now
  reports itself. Previously `fail_count > 0 -> healthy` reset the counters
  silently: no log line, no Discord message. Only critical incidents (those
  that had already triggered an ONT alert) were ever closed out.
- `notify_ordinary_recovery()` is a **separate** mechanism from
  `notify_ipv6_recovered()`. The latter remains the critical/ONT closure, keeps
  its `ONT_FLAG` gate, and keeps its direct webhook `curl`. The ordinary path
  emits exactly one compact log line and relies on the existing
  `ipv6-watchdog` -> `ipv6-discord-logger` tag forwarding; it never calls
  `curl` itself.
- Both recovery paths are covered: the normal healthy path and the successful
  `fix_gateway` -> `ipv6_ok` path. The latter previously reset state with no
  notification of any kind, so even a critical incident closed silently there.
- Exactly one recovery notice can fire per incident. Ordinary closure is
  suppressed whenever `ONT_FLAG` exists or a recovery hold is active, which is
  precisely when the critical closure owns the incident.

**Restart-assisted recovery closure**

- A confirmed incident that escalated to a full WAN restart and then went
  healthy also closed silently. `do_wan_restart()` zeroes `FAIL_FILE`, so the
  ordinary closure correctly sees `fail_count = 0`, while
  `notify_ipv6_recovered()` stays `ONT_FLAG`-gated and a plain restart never
  sets `ONT_FLAG`. Observed in production on 2026-08-16: failures 1-3,
  `Full WAN restart #1 of 3`, gateway replaced, source policy switched to
  `pd-preferred`, IPv6 healthy -- and no closure line.
- New `restart_incident` state records the incident's restart ordinal.
  Presence of this marker, never the cumulative shared `disruption_count`, is
  what proves the current incident required a restart; a routine healthy tick
  in a boot that saw an earlier restart therefore emits nothing.
- Closure precedence across all positive-health paths is
  critical/hold > restart-assisted > ordinary, so exactly one notice fires per
  incident.
- The marker is cleared only by a positive-health closure or by ownership
  passing to the critical/hold path.
- All three `reset_recovery_state()` call sites now emit a closure first. The
  `try_128_bootstrap()` success path (reachable only with
  `BOOTSTRAP_ENABLED=1`) previously cleared incident state with no
  notification at all; the bootstrap mechanism itself is unchanged and still
  owns no closure policy.

**Incident duration**

- New `incident_start` state file records epoch seconds on the `fail_count`
  `0 -> 1` transition only, and is never overwritten while the incident stays
  open. Cleared by `reset_recovery_state()` and by `do_wan_restart()`, so an
  escalated incident can only ever close through the critical path.
- Duration is reported only when it is reliably derivable: the marker must
  exist, parse as a positive integer, and yield a delta within a 24-hour sanity
  ceiling. Otherwise the clause is omitted entirely rather than guessed.

**Evidence-based failure wording**

- `Connectivity failure N (prefix present, gateway broken or route dead)`
  asserted a root cause the watchdog has not established at that point.
  Replaced with wording limited to what the code has actually proven:

  ```
  IPv6 connectivity failure 1/3 confirmed. Delegated prefix and default route
  are present, but PD-source Internet reachability failed after confirmation
  and gateway recovery attempts. Current gateway: fe80::1. No WAN restart
  performed yet.
  ```

- The gateway clause appears only when `current_default_gw()` actually returns
  one; the restart clause only below the escalation threshold. The escalation
  threshold is now the named `FAIL_LIMIT` so the message and the escalation
  test cannot drift apart.

**Release note**

- The ordinary-recovery behavior was designed for a v3.9.10 that was never
  committed, tagged, or pushed. v3.10.0 was branched directly from v3.9.9
  (`6451d35`'s parent is `7e7566e` = `v3.9.9`) and therefore never contained
  it. This was an integration omission, not a regression: the symbols appear in
  no commit in the repository's history. The design's own safeguard was a
  manual "Discord test D5" that never became an executable test, which is why
  nothing failed. `tests/test-ordinary-recovery.sh` is that missing test.

**Testing**

- `tests/test-ordinary-recovery.sh` (new, 64 assertions) covers both recovery
  paths, the silent `fail_count = 0` cases, marker lifecycle, duplicate
  suppression, duration formatting and all its degenerate inputs, gateway
  provability, single-line output, and budget preservation.
- `tests/test-ash-compat.sh` (new, 30 assertions) parses every router-side
  script under each POSIX shell present and statically scans for bashisms
  absent from BusyBox ash. Runs `busybox ash -n` automatically when busybox is
  installed.
- `tests/test-reachability-confirmation.sh` updated for the new failure wording
  and marker assertions.

### v3.10.0

Architecture change rather than a set of fixes. The health model, the recovery
model, and the router's own source selection were all reworked.

**PD-first health model**

- Household IPv6 health is now decided by the delegated prefix and by traffic
  sourced from it, across five layers: `IA_PD` present, a current PD-derived LAN
  global source, a generic default route, effective kernel routing from that
  source, and PD-source-bound reachability.
- Health is judged by **effective routing**, not by route-table shape. A
  generic-default-only table is valid. An explicit `default from <prefix>` rule
  is optional, maintained where it exists and never manufactured.
- Transient reachability failures are re-checked before being treated as real.

**IA_NA is optional**

- The previous position, that a WAN `/128` is inherently broken and that removing
  it is the primary fix, has been **withdrawn**. Longer observation across more
  than one deployment did not support it.
- A `/128` may be present or absent; neither is a fault. Its reachability never
  defines household health, never increments a recovery counter, and never
  consumes disruption budget.
- `reqaddress='none'` is no longer presented as universally required. It is one
  provider-dependent option; `reqaddress='try'` has also been observed healthy.

**Router source policy (new)**

- Two states, `native` and `pd-preferred`. A preferred PD-derived source is
  installed on the generic default route only when a `/128` is present but
  unusable while the PD path works.
- Gateway, `dev`, `proto`, `metric` and `pref` are preserved; only the source
  attribute changes. Source-specific routes are never modified.
- **Ownership safety:** ownership is recorded only after a route change actually
  succeeds. An administrator-set source is used but never claimed and never
  removed. If the route is changed externally, the watchdog preserves that change
  and releases its own claim. Ownership from a previous prefix is released safely.
- A preferred source silently dropped by a route refresh is restored from cache
  without re-probing.
- Source policy never restarts an interface and never consumes disruption budget.

**Gateway and route repair**

- Candidates are accepted only when the kernel resolves the PD source through
  that specific gateway **and** a PD-source-bound probe succeeds.
- Already-effective routing is left completely untouched.
- Complete default-route snapshot before any mutation, with exact restore on
  failure. Where there was nothing to snapshot, rollback removes only what the
  attempt created.
- Generic default routes are now read **without** a device selector and filtered
  afterwards. Querying with a device selector can cause `iproute2` to omit the
  `dev` token from its output, and replaying such a line loses the interface
  context a link-local next hop requires.

**Shared recovery coordination (new component)**

- New `wan-recovery-common`, a protocol-neutral sourced library that owns the
  shared serialization lock, the per-boot disruption budget, the cooldown, the
  disruption hold, reason and timestamp accounting, and the full WAN lifecycle.
- Accounting is written **before** the first destructive command, so an
  interrupted cycle is still recorded and cannot produce an unbounded loop.
- Health is re-checked **after** the lock is acquired, so a connection that
  recovered while waiting is not torn down.
- wan6-only actions are recorded but do not consume full-WAN budget. They are
  still blocked by an active hold.
- `ipv6-watchdog` no longer performs full-WAN lifecycle itself and delegates all
  disruptive action to the coordinator.
- **Fail-closed:** if the coordinator is missing or its interface is incomplete,
  disruptive recovery is disabled while monitoring, logging, and non-disruptive
  repair continue. Install the coordinator before the watchdog, and preserve it
  across firmware upgrades.

**Recovery is bounded**

- Full-WAN recovery is limited by lock, budget, cooldown, and hold. Once the
  budget is spent the hold latches and the router switches to passive monitoring
  rather than cycling WAN indefinitely.
- The documentation now describes bounded self-healing rather than unqualified
  self-healing.

**99-ipv6-setup**

- Rewritten as a strictly non-disruptive `wan6`-ifup helper: no `ifdown`/`ifup`,
  no UCI writes, no recovery counters, no hold interaction.
- **No longer removes the WAN `/128`.**
- PD-aware gateway selection with the same verification and rollback rules as the
  watchdog.

**Bootstrap**

- The experimental IA_NA-assisted prefix bootstrap is **disabled by default**
  (`BOOTSTRAP_ENABLED=0`) and is inert unless explicitly enabled. Its
  effectiveness remains an untested hypothesis.
- `CLEANUP_WAN128` now defaults to `0`, so a healthy `/128` is retained.

**98-wan6-delay**

- Reclassified as legacy and optional. Retained in the repository, excluded from
  the core stack, and not installed by Quick Deploy, because its `wan6` cycle
  happens outside the coordination layer.

**Documentation**

- Rewritten architecture sections with plain ASCII diagrams.
- New deployment documentation: explicit core install order, `wget` and `curl`
  parity for every installable component, safe download and atomic install,
  upgrade with backups, and rollback.
- Configuration reclassified into required, recommended baseline,
  provider-dependent, and leave-unchanged. The universal `reqaddress='none'` rule
  and the `norelease` deletion instruction were both removed.
- Post-Deploy Verification rebuilt around the PD-first contract, separating
  installation integrity from network health, source policy, and coordination
  state. The old "no global `/128` is good" criterion is gone.
- New state file reference, rewritten troubleshooting organised by symptom, and
  developer test documentation.

**Testing**

- 9 deterministic suites, 772 assertions, all passing.
- New coverage for the coordinator, watchdog and coordinator integration, and
  source policy, including regressions for the `iproute2` device-selector
  behavior described above.

### v3.9.9

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
- Made `WATCH_TAGS` configurable via `/etc/ipv6-watchdog.conf`. Repo default is `ipv6-setup|ipv6-watchdog|discord-logger`. Override in conf to add additional custom tags from other scripts (e.g. `ipv6-prefix`) without modifying the script. `extract_msg()` reads `WATCH_TAGS` dynamically so both grep filtering and tag stripping stay in sync automatically.
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
