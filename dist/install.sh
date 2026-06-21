#!/usr/bin/env bash
# Build, install, and load the dockhelper LaunchDaemon. Run with sudo.
set -euo pipefail

LABEL="me.gormley.dockhelper"
BIN_DST="/usr/local/sbin/dockhelper"
CFG_DIR="/usr/local/etc/dockhelper"
PLIST_DST="/Library/LaunchDaemons/${LABEL}.plist"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"

if [[ $EUID -ne 0 ]]; then echo "run with sudo: sudo $0"; exit 1; fi
USER_NAME="${SUDO_USER:-$(logname)}"

echo "building (release) as ${USER_NAME}…"
sudo -u "$USER_NAME" swift build -c release --package-path "$ROOT"
BIN_SRC="$ROOT/.build/release/dockhelper"

echo "installing binary → $BIN_DST"
install -d -m 755 /usr/local/sbin
install -m 755 "$BIN_SRC" "$BIN_DST"

echo "installing default config → $CFG_DIR/config.json (kept if present)"
install -d -m 755 "$CFG_DIR"
[[ -f "$CFG_DIR/config.json" ]] || install -m 644 "$ROOT/dist/config.example.json" "$CFG_DIR/config.json"

echo "creating durable state dir → /var/db/dockhelper (survives reboot; holds the capture file)"
install -d -m 755 /var/db/dockhelper
chown root:wheel /var/db/dockhelper

echo "installing plist → $PLIST_DST"
install -m 644 "$HERE/${LABEL}.plist" "$PLIST_DST"
chown root:wheel "$PLIST_DST"

echo "loading daemon…"
launchctl bootout system "$PLIST_DST" 2>/dev/null || true
launchctl bootstrap system "$PLIST_DST"
launchctl enable "system/${LABEL}"

echo "done. logs: tail -f /var/log/dockhelper.log ; status: dockhelper status"
