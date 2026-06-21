# dockhelper

When a Mac is docked (a wired Ethernet link is up), macOS keeps Wi-Fi associated and
IP-addressed too — a dual-homed host with two routable interfaces, where mDNS/AirPlay
can bind to the wrong one. `dockhelper` watches wired link state and **strips Wi-Fi's
routable IP while leaving it associated** (IPv4 off, IPv6 link-local), so routed traffic
moves to the wire but AWDL peer services (Handoff, Sidecar, Continuity, AirDrop, AirPlay)
keep working. When the last wired link drops, the Wi-Fi IP config is restored.

macOS only. Swift + SwiftPM, no dependencies beyond the macOS SDK.

---

## Strategy: `ipoff`

An earlier design **disassociated** Wi-Fi while docked. On macOS 26 that proved
unworkable: `CWInterface.disassociate()` registers as a manual disconnect, drops the
network's auto-join score, and the OS then auto-joins a *different* preferred network and
resists rejoining the one you left for 2–13 minutes — with no programmatic lever to
reverse it. (Findings: the project memory `macos26-wifi-disassociate-taint`.)

`ipoff` sidesteps that entirely: **never disassociate.** Keep Wi-Fi associated and strip
only its routable IP — `networksetup -setv4off` + `-setv6LinkLocal` while docked,
`-setdhcp` + `-setv6automatic` on undock. No manual disconnect → no score drop → restore
is trivial (the OS never left the network). Validated on hardware: Wi-Fi stays associated,
`awdl0` stays up, Handoff + AirDrop work, and the host single-homes onto the wire.

The `networksetup` writes need root, so this runs as a root LaunchDaemon. Cosmetic side
effect: the menu-bar Wi-Fi icon shows "no internet" (!) while suppressed (accurate; it
clears on undock, and doubles as a restore-health indicator).

### Design

Three seams from the original spike, simplified:

- **Detection** — `LinkMonitor` (SCDynamicStore, event-driven, zero polling) forwards a
  fresh `NetSnapshot` on every link/IPv4/AirPort change.
- **Read** — `NetProbe` (SCDynamicStore) for live link/association state; `SCNetworkConfig`
  (SCPreferences) reads the Wi-Fi service's configured IPv4/IPv6 method and resolves its
  service name from the BSD — locale-proof, no root, no TCC.
- **Actuation** — `Suppressor` runs `networksetup` off the reconciler's actor.
- **Policy** — `Reconciler`, an actor. Desired = `suppressed` while any wired link is up,
  else `normal`.

`ipoff` is **sticky**: the suppressed IP config holds on its own, so there is no
re-assert / backstop / restore-watchdog (all of which the disassociate strategy needed).

**Capture is DHCP-only and fail-closed.** Suppression only fires when the Wi-Fi service is
plain DHCP + IPv6-automatic; anything else (a static IP, already-off, unreadable) is logged
and left untouched — the tool never clobbers a non-standard config. The captured baseline is
written to `/var/db/dockhelper/capture.json`, whose **presence is the source of truth for
"am I suppressed"**. It is durable (survives reboot), so a machine that reboots while docked
resumes correctly and restores on undock.

### Commands

```sh
dockhelper run              # the daemon (what launchd invokes)
dockhelper status           # print current state (reads the state file)
dockhelper override on|off  # pause / resume suppression
```

Control is file-based, no IPC: `override on` touches a flag file the daemon polls each
observe cycle; `status` reads the JSON state file the daemon publishes every reconcile.

### Configuration

JSON at `/usr/local/etc/dockhelper/config.json` (every key optional — a partial file
overrides only what it sets; missing keys use defaults). See
[`dist/config.example.json`](dist/config.example.json):

| key | default | meaning |
|---|---|---|
| `strategy` | `ipoff` | only `ipoff` is implemented; reserved for a future radio-off fallback |
| `v6_mode` | `link_local` | IPv6 while suppressed: `link_local` or `off` |
| `debounce_seconds` | `5.0` | settle window before **suppressing** (rides a dock's Ethernet bring-up flap) |
| `restore_debounce_seconds` | `0.5` | settle window before **restoring** on undock — short, for fast connectivity recovery |
| `observe_seconds` | `0.5` | state-sampling / override-poll cadence |
| `wifi_service` | (auto) | Wi-Fi service name; omitted ⇒ auto-resolved from the BSD via SystemConfiguration |
| `interface_include` / `interface_exclude` | `[]` | restrict which BSD names count as wired |

### Install (root LaunchDaemon)

```sh
sudo dist/install.sh        # release build → /usr/local/sbin, plist → LaunchDaemons, load
tail -f /var/log/dockhelper.log
dockhelper status
sudo dist/uninstall.sh      # stop + remove (restores Wi-Fi first if it was suppressed)
```

Label `me.gormley.dockhelper`. Runtime state/override under `/var/run/dockhelper/` (cleared
on boot); the durable capture file under `/var/db/dockhelper/` (survives reboot).

### Run without installing (development)

The config/runtime/state paths honor env overrides. The `networksetup` writes need root, so
an unprivileged run reads and decides but cannot actuate — useful only for exercising
detection/decision logic while undocked (where it does nothing to Wi-Fi):

```sh
swift build
DOCKHELPER_CONFIG=/tmp/dh.json DOCKHELPER_RUNTIME_DIR=/tmp/dh DOCKHELPER_STATE_DIR=/tmp/dh \
  .build/debug/dockhelper run
```

Stop with Ctrl-C / `kill -TERM`. Stopping while suppressed leaves Wi-Fi's IP stripped
(sticky); the daemon restores on next launch at undock, or `uninstall.sh` restores on removal.

---

## Verification

The dock/undock behavior needs a physical wired link and root — see [`TODO.md`](TODO.md)
for the runbook (single-homing, AWDL, restoration, reboot-while-docked, fail-closed, flap).
