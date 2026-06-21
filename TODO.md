# dockhelper — TODO

## Verify the dock/undock behavior (needs a physical wired link + root)

`ipoff` actuation needs root (`networksetup` writes), so test the installed LaunchDaemon
(`sudo dist/install.sh`) or `sudo .build/debug/dockhelper run`. Record results below.

**Observation one-liners** (second terminal):

```sh
ipconfig getifaddr en0                                                # Wi-Fi IPv4 (empty == suppressed)
ifconfig en0 | grep 'inet6 fe80'                                      # link-local only while suppressed
scutil <<< 'show State:/Network/Interface/en0/AirPort' | grep BSSID  # still associated
scutil <<< 'show State:/Network/Global/IPv4'          | grep PrimaryInterface
ifconfig awdl0 | grep status                                         # AWDL alive
dockhelper status ; ls -l /var/db/dockhelper/capture.json            # daemon view + capture presence
```

The live SSID is unreadable programmatically on macOS 26 — read the **menu bar** to confirm
Wi-Fi never leaves its network.

### A. Dock → suppress
- [ ] Dock. Log shows `desired normal→suppressed` then `suppress(settled)`.
- [ ] `ipconfig getifaddr en0` empty; `inet6` is link-local only; BSSID still present (associated).
- [ ] PrimaryInterface = the wired `enN`; default route not via en0.
- [ ] `/var/db/dockhelper/capture.json` present.

### B. AWDL peer services survive (the whole point)
- [ ] `ifconfig awdl0` → `status: active`
- [ ] AirDrop — discoverable / can send
- [ ] Handoff / Universal Clipboard to an iPhone; Sidecar to an iPad
- [ ] AirPlay to an Apple TV / HomePod

### C. Undock → restore
- [ ] Unplug, several times. Wi-Fi regains a routable IPv4; PrimaryInterface flips back to en0.
- [ ] `capture.json` cleared; log shows `restore(...)`. Menu bar shows Wi-Fi never changed network.

### D. ★ Reboot while docked (the load-bearing case)
- [ ] Suppress (dock), then reboot **still docked**. After boot: `capture.json` present,
      `dockhelper status` desired=suppressed, and **`ipconfig getifaddr en0` still empty**.
      Log shows `suppress-resume(startup)`. (The daemon re-applies suppression on launch, so
      this holds even if the OS didn't persist IPv4-off across the reboot.)

### E. Fail-closed on a non-standard config
- [ ] Temporarily set Wi-Fi to a static IP (System Settings), then dock. Log shows
      `skip-nonstandard`, NO suppression, and the static IP stays intact. Revert to DHCP.

### F. Flap suppression
- [ ] Re-seat the cable a few times quickly → at most one suppress/restore action
      (debounce = 5 s). Watch for thrash. If the dock's Ethernet drops link for one long
      gap (~25 s) rather than bouncing, expect a single restore→re-suppress cycle per dock —
      raise `debounce_seconds` if undesired.

### G. Override
- [ ] `dockhelper override on` while docked → Wi-Fi restored (override wins). `override off`
      → reconciles back to suppressed.
```
