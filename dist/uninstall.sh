#!/usr/bin/env bash
# Stop and remove the dockhelper LaunchDaemon. Run with sudo.
set -euo pipefail

LABEL="me.gormley.dockhelper"
PLIST_DST="/Library/LaunchDaemons/${LABEL}.plist"

if [[ $EUID -ne 0 ]]; then echo "run with sudo: sudo $0"; exit 1; fi

launchctl bootout system "$PLIST_DST" 2>/dev/null || true

# If the daemon was suppressing Wi-Fi when removed, restore it BEFORE deleting state — otherwise the
# Wi-Fi service is left with no routable IP and nothing remains to reconcile it. The capture file
# exists only if we suppressed a plain-DHCP service. Re-check the live config first: if the user has
# since set a static IP, leave it untouched (never clobber a non-standard config).
CAP="/var/db/dockhelper/capture.json"
if [[ -f "$CAP" ]]; then
  SVC="$(/usr/bin/plutil -extract service raw "$CAP" 2>/dev/null || true)"
  if [[ -n "${SVC}" ]]; then
    INFO="$(/usr/sbin/networksetup -getinfo "${SVC}" 2>/dev/null || true)"
    if grep -qi 'Manual Configuration' <<< "${INFO}"; then
      echo "Wi-Fi service '${SVC}' is now manually configured; leaving it as-is."
    else
      echo "restoring Wi-Fi service '${SVC}' to DHCP (it was suppressed)…"
      /usr/sbin/networksetup -setdhcp "${SVC}" || true
      /usr/sbin/networksetup -setv6automatic "${SVC}" || true
    fi
  fi
fi

rm -f "$PLIST_DST" /usr/local/sbin/dockhelper
rm -rf /var/run/dockhelper /var/db/dockhelper
echo "removed daemon, binary, runtime + durable state."
echo "left in place: /usr/local/etc/dockhelper (config), /var/log/dockhelper.log"
