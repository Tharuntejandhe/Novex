#!/usr/bin/env bash
# Install Crux as a LaunchAgent so it starts at login (and restarts if it crashes).
# Reads HOME so it works for any user when shipped as part of the repo.

set -euo pipefail

LABEL="com.tarun.crux"
APP_PATH="${HOME}/Applications/Crux.app"
EXEC_PATH="${APP_PATH}/Contents/MacOS/Crux"
PLIST_DIR="${HOME}/Library/LaunchAgents"
PLIST_PATH="${PLIST_DIR}/${LABEL}.plist"
LOG_PATH="${HOME}/Library/Logs/Crux.log"

if [ ! -x "${EXEC_PATH}" ]; then
    echo "Crux.app not found at ${APP_PATH}"
    echo "Run Scripts/make-app.sh first."
    exit 1
fi

mkdir -p "${PLIST_DIR}"
mkdir -p "$(dirname "${LOG_PATH}")"

cat > "${PLIST_PATH}" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>${LABEL}</string>
    <key>ProgramArguments</key>
    <array>
        <string>${EXEC_PATH}</string>
    </array>
    <!--
      launchd ignores the app bundle's Info.plist LSEnvironment, so the
      Swift-runtime executor workaround must be repeated here. Without it,
      SwiftUI Button taps can crash this login-item instance with EXC_BAD_ACCESS
      in swift_task_isCurrentExecutor. See make-app.sh for the full explanation.
    -->
    <key>EnvironmentVariables</key>
    <dict>
        <key>SWIFT_IS_CURRENT_EXECUTOR_LEGACY_MODE_OVERRIDE</key>
        <string>legacy</string>
    </dict>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <dict>
        <key>SuccessfulExit</key>
        <false/>
        <key>Crashed</key>
        <true/>
    </dict>
    <key>ThrottleInterval</key>
    <integer>10</integer>
    <key>StandardOutPath</key>
    <string>${LOG_PATH}</string>
    <key>StandardErrorPath</key>
    <string>${LOG_PATH}</string>
    <key>ProcessType</key>
    <string>Interactive</string>
</dict>
</plist>
EOF

# Stop any currently running Crux so launchd takes ownership cleanly.
pkill -f Crux 2>/dev/null || true
sleep 0.4

# If the agent is already loaded, unload it first so the new plist takes effect.
launchctl bootout "gui/$(id -u)/${LABEL}" 2>/dev/null || true

launchctl bootstrap "gui/$(id -u)" "${PLIST_PATH}"
launchctl enable "gui/$(id -u)/${LABEL}"
launchctl kickstart -k "gui/$(id -u)/${LABEL}"

sleep 0.6
if pgrep -f Crux > /dev/null; then
    echo "Installed and running."
    echo "  Plist : ${PLIST_PATH}"
    echo "  Logs  : ${LOG_PATH}"
    echo "Crux will now start automatically when you log in."
else
    echo "Loaded the agent but Crux is not running. Check ${LOG_PATH}."
    exit 1
fi
