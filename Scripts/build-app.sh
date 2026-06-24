#!/usr/bin/env bash
# Build a standalone "MacRazer.app" menu bar bundle from the SwiftPM executable.
#
#   ./Scripts/build-app.sh           # release build → ./MacRazer.app
#   open "MacRazer.app"           # launch it
#
# The bundle is ad-hoc codesigned so it has a stable identity — important so macOS
# remembers the Input Monitoring grant across launches (unsigned binaries get a fresh,
# unstable TCC identity and re-prompt every time).
set -euo pipefail

cd "$(dirname "$0")/.."

APP="MacRazer.app"
EXEC_NAME="MacRazer"

echo "▸ Building release binary…"
swift build -c release
BIN="$(swift build -c release --show-bin-path)/${EXEC_NAME}"

echo "▸ Assembling ${APP}…"
rm -rf "${APP}"
mkdir -p "${APP}/Contents/MacOS" "${APP}/Contents/Resources"
cp "${BIN}" "${APP}/Contents/MacOS/${EXEC_NAME}"
cp Packaging/Info.plist "${APP}/Contents/Info.plist"
[ -f Packaging/AppIcon.icns ] && cp Packaging/AppIcon.icns "${APP}/Contents/Resources/AppIcon.icns"

# Prefer a stable self-signed identity (created by Scripts/setup-signing.sh) so the
# Input Monitoring grant persists across rebuilds. Fall back to ad-hoc otherwise.
SIGN_ID="MacRazer Self-Signed"
if security find-identity -p codesigning 2>/dev/null | grep -q "${SIGN_ID}"; then
    echo "▸ Codesigning with stable identity '${SIGN_ID}'…"
    codesign --force --sign "${SIGN_ID}" --identifier com.macrazer.menubar --timestamp=none "${APP}"
else
    echo "▸ Ad-hoc codesigning (run Scripts/setup-signing.sh for a stable identity)…"
    codesign --force --sign - --identifier com.macrazer.menubar --timestamp=none "${APP}"
fi

echo "✓ Built ${APP}"
echo "  Launch:  open \"${APP}\""
echo "  First run will prompt for Input Monitoring — grant it in"
echo "  System Settings → Privacy & Security → Input Monitoring, then relaunch."
