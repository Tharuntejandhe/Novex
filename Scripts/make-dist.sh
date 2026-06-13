#!/usr/bin/env bash
# Package Novex.app into a shareable zip a stranger can download and run.
# Builds + installs via make-app.sh, then `ditto`-zips the bundle (which
# preserves the code signature and bundle structure that a plain `zip` mangles).
#
# Output: dist/Novex.zip
# Run:    Scripts/make-dist.sh

set -euo pipefail
cd "$(dirname "$0")/.."

APP="${HOME}/Applications/Novex.app"
OUT_DIR="dist"
ZIP="${OUT_DIR}/Novex.zip"

echo "==> building + installing the app"
Scripts/make-app.sh >/dev/null

if [ ! -d "${APP}" ]; then
    echo "error: ${APP} not found after build" >&2
    exit 1
fi

mkdir -p "${OUT_DIR}"
rm -f "${ZIP}"
echo "==> zipping ${APP} → ${ZIP}"
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "${APP}" "${ZIP}"

SIZE=$(du -h "${ZIP}" | cut -f1)
echo ""
echo "Done: ${ZIP} (${SIZE})"
echo ""
echo "Share it with this note:"
echo "  1. Unzip and move Novex.app to /Applications"
echo "  2. Right-click Novex.app → Open → Open  (first launch only — it's not notarized)"
echo "  3. Grant Full Disk Access when asked, so it can read Mail on-device"
