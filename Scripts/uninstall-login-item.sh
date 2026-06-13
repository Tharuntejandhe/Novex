#!/usr/bin/env bash
# Remove the Novex LaunchAgent so it no longer starts at login.
# Does NOT remove Novex.app or your FDA grants.

set -euo pipefail

LABEL="com.tarun.novex"
PLIST_PATH="${HOME}/Library/LaunchAgents/${LABEL}.plist"

launchctl bootout "gui/$(id -u)/${LABEL}" 2>/dev/null || true
rm -f "${PLIST_PATH}"
pkill -f Novex 2>/dev/null || true

echo "Uninstalled login item. Novex will not start at next login."
echo "Novex.app and FDA grant are still in place; remove them manually if you want."
