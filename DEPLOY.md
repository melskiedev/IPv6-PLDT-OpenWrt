# IPv6 PLDT OpenWrt — Deploy & Ops Reference

Living ops doc for **this repo only**. README = user guide; **this file** = production state, gates, AI triage, backlog. Update after each deploy or major review.

**Last updated:** 2026-06-19

---

## Production baseline

| Item | Value |
|------|-------|
| **Watchdog release** | v3.9.5 |
| **Watchdog commit** | `6f86d73` (logic); `710ce2b` adds `.gitattributes` only |
| **Git tag** | `v3.9.5` |
| **Line endings** | LF (`.gitattributes` enforces on deploy scripts) |
| **Stop rule** | No v3.9.6+ unless Kamuning/Lumban logs show a real failure |

### Routers (GL-MT6000, OpenWrt 25.12.2, PLDT bridge mode)

| Router | Hostname | Watchdog | Sticky GW | Discord | Notes |
|--------|----------|----------|-----------|---------|-------|
| Kamuning | KamuningFlint2 | v3.9.5 | `STICKY_GATEWAY=1` | Yes | Dual gateway: `8404` (good), `57d9` (STALE alt) |
| Lumban | LumbanFlint2 | v3.9.5 | `STICKY_GATEWAY=1` | Yes | Single gateway typical: `8604` |

**Conf:** `/etc/ipv6-watchdog.conf` — `chmod 600` (webhooks are secrets).

---

## File map (deploy order)

| File | Path on router | Role |
|------|----------------|------|
| `98-wan6-delay` | `/etc/hotplug.d/iface/` | 15s wan6 boot delay |
| `99-ipv6-setup` | `/etc/hotplug.d/iface/` | Hotplug gateway scan + route install |
| `ipv6-watchdog` | `/usr/bin/` | Cron recovery (versioned) |
| `97-garp` | `/etc/hotplug.d/iface/` | Gratuitous ARP on LAN ifup |
| `ipv6-discord-logger` | `/usr/bin/` | Forward `#ipv6-logs` |
| `init.d-ipv6-discord-logger` | `/etc/init.d/` | procd service for logger |

**Versioning:** Only `ipv6-watchdog` carries `# vX.Y.Z` in header. Hotplug scripts are not semver-tagged.

---

## Pre-deploy gate (watchdog)

Run on router **before** `mv` to live path:

```sh
BASE="https://raw.githubusercontent.com/melskiedev/IPv6-PLDT-OpenWrt/main"
wget -q "$BASE/ipv6-watchdog" -O /tmp/ipv6-watchdog.new

LINES=$(wc -l < /tmp/ipv6-watchdog.new)
[ "$LINES" -gt 600 ] || { echo "REJECT: collapsed file ($LINES lines)"; exit 1; }

grep -qE '^(Enforces|But since|A second|If keep_gateway|Centralized|Replay every)' /tmp/ipv6-watchdog.new && \
  { echo "REJECT: uncommented prose in script"; exit 1; }

sh -n /tmp/ipv6-watchdog.new || { echo "REJECT: syntax failed"; exit 1; }
grep -m1 '^# v' /tmp/ipv6-watchdog.new
```

Expected header: `# v3.9.5: ...`

Optional backup:

```sh
cp /usr/bin/ipv6-watchdog /usr/bin/ipv6-watchdog.bak.$(date +%Y%m%d-%H%M%S)
```

---

## Deploy commands

### Watchdog only (most common)

```sh
wget -q "$BASE/ipv6-watchdog" -O /tmp/ipv6-watchdog.new \
  && sh -n /tmp/ipv6-watchdog.new \
  && mv /tmp/ipv6-watchdog.new /usr/bin/ipv6-watchdog \
  && chmod +x /usr/bin/ipv6-watchdog
grep -m1 '^# v' /usr/bin/ipv6-watchdog
```

No reboot. Cron picks up next tick (~1 min).

### Full stack (fresh install)

See README **Quick Deploy**. Order: UCI → 98 → 99 → watchdog → cron → 97 → reboot.

### Discord logger (when patched)

```sh
wget -q "$BASE/ipv6-discord-logger" -O /tmp/ipv6-discord-logger.new \
  && sh -n /tmp/ipv6-discord-logger.new \
  && mv /tmp/ipv6-discord-logger.new /usr/bin/ipv6-discord-logger \
  && chmod +x /usr/bin/ipv6-discord-logger
/etc/init.d/ipv6-discord-logger restart
```

---

## Do NOT use

| Avoid | Why |
|-------|-----|
| **v3.9.1** | Function-order bug (ash forward references) |
| Hostname probes (`ping6 dns.google`) | Couples DNS to routing check |
| Deploy if `wc -l` < 600 | Collapsed/corrupt download |
| `accept_ra='2'` + `defaultroute='0'` on wan6 | Breaks wan6 init (README) |
| Restart LAN while odhcpd holds PD | Use `network reload` + `odhcpd restart` |

---

## Probe targets (current)

Hardcoded in watchdog + `99-ipv6-setup` (no DNS):

- Google: `2001:4860:4860::8888`
- Cloudflare: `2606:4700:4700::1111`

Logic: **either** success = reachable. Future: `PROBE_TARGETS` in conf (backlog).

---

## Health checks

```sh
# Routing
ip -6 route show default dev eth1
ip -6 neigh show dev eth1 | grep router
cat /tmp/ipv6-watchdog/good_gateway 2>/dev/null

# Reachability
ping6 -c 2 2001:4860:4860::8888

# Logs
logread | grep ipv6-watchdog | tail -20
logread | grep ipv6-setup | tail -10
```

**Good sticky log (Kamuning validated):**

```text
Sticky gateway check: current gateway changed fe80::...8404 -> fe80::...57d9
Sticky gateway restored: fe80::1225:48ff:fe81:8404
```

**v3.9.5-only log (failed gateway scan):**

```text
Restored pre-scan default route set
```

---

## Sysupgrade preserve

```
/etc/hotplug.d/iface/98-wan6-delay
/etc/hotplug.d/iface/99-ipv6-setup
/usr/bin/ipv6-watchdog
/etc/crontabs/root
/etc/hotplug.d/iface/97-garp
/etc/ipv6-watchdog.conf
/usr/bin/ipv6-discord-logger
/etc/init.d/ipv6-discord-logger
```

---

## v3.9.5 watchdog features (quick ref)

- `sanitize_int()` on all counter reads
- `fix_gateway()` full route snapshot + `restore_route_snapshot()`
- `PREFIX_FAILS >= 3` backoff guard (no bit-shift overflow)
- Boot grace 120s, then jitter `sleep`
- `BOOTSTRAP_UCI_STAGED` + unified `on_exit` (UCI revert + stale snapshot cleanup)
- Sticky gateway: `keep_gateway()` before `ipv6_ok()`

---

## AI review triage (consolidated)

### Fixed / shipped

| Finding | Where | Status |
|---------|-------|--------|
| Function order (v3.9.1 bug) | watchdog | Fixed v3.9.2 |
| `maybe_wan_restart()` centralization | watchdog | v3.9.2+ |
| Counter empty-file reads | watchdog | v3.9.4 `sanitize_int` |
| Route restore on failed scan | watchdog | v3.9.5 snapshot |
| Backoff overflow | watchdog | v3.9.5 guard |
| Bootstrap UCI trap | watchdog | v3.9.4/5 `on_exit` |
| CRLF on GitHub raw | repo | `.gitattributes` |

### Deferred (backlog)

| Finding | File | Priority |
|---------|------|----------|
| `SAFE` missing `tr -d '\n\r\t'` | `ipv6-discord-logger` | **Medium** (user uses Discord) |
| `HOST` uci inside loop | `ipv6-discord-logger` | Low |
| `killall logread` too broad | `init.d-ipv6-discord-logger` | Low |
| WAN restart bypasses cooldown | `99-ipv6-setup` L137-146 | Low (hotplug one-shot) |
| No route snapshot on hotplug fail | `99-ipv6-setup` | Low |
| `PROBE_TARGETS` configurable | watchdog + setup | Future v4.0 |
| README L853 "second" bootstrap | README | Cosmetic (L859 correct) |

### Rejected / wrong reviews

| Claim | Verdict |
|-------|---------|
| GitHub raw 44-line collapsed file | **False** (768 lines LF; verify with `wc -l`) |
| Hostname-based probes | **Reject** (adds DNS dependency) |

---

## Escalation ladder (watchdog, no prefix)

| PREFIX_FAILS | Action |
|--------------|--------|
| 1 | Restart wan6 |
| 2 | DHCPv6 renew |
| 3 | `/128` bootstrap (`try_128_bootstrap`) |
| 4+ | Full WAN restart via `maybe_wan_restart()` |

Cooldown: `WAN_RESTART_COOLDOWN=1200`, limit `WAN_RESTART_LIMIT=3`, then ONT alert.

---

## Discord channels

| Channel | Source | JSON hardening |
|---------|--------|----------------|
| `#ipv6-alerts` | watchdog embeds | v3.9.3+ (`MODEL/HOST/FW` escaped) |
| `#ipv6-logs` | `ipv6-discord-logger` | **Pending** `SAFE` tr fix |

---

## Changelog pointer

Full history: README **Changelog**. Recent:

- **v3.9.5** — route snapshot restore, backoff guard, `on_exit` snapshot cleanup
- **v3.9.4** — sanitize_int, bootstrap trap, jitter after grace, generic route restore
- **v3.9.3** — comments restored, Discord escape on watchdog embeds

---

## When to bump version

Only change `# vX.Y.Z` in `ipv6-watchdog` when **behavior** changes. Docs-only / logger-only / `.gitattributes` do not require watchdog version bump.

**Bar for v3.9.6+:** observed failure on Kamuning or Lumban logs, not theoretical review alone.
