#!/usr/bin/env bash
# Remove the Crux LaunchAgent so it no longer starts at login.
# Does NOT remove Crux.app or your FDA grants.

set -euo pipefail

LABEL="com.tarun.crux"
PLIST_PATH="${HOME}/Library/LaunchAgents/${LABEL}.plist"

launchctl bootout "gui/$(id -u)/${LABEL}" 2>/dev/null || true
rm -f "${PLIST_PATH}"
pkill -f Crux 2>/dev/null || true

echo "Uninstalled login item. Crux will not start at next login."
echo "Crux.app and FDA grant are still in place; remove them manually if you want."
