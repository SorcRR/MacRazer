#!/usr/bin/env bash
# Package "MacRazer.app" into a drag-to-install DMG for distribution.
#
#   ./Scripts/make-dmg.sh            # builds the app, then writes ./dist/MacRazer.dmg
#
# The app is unsigned/self-signed (no paid Apple Developer ID), so macOS Gatekeeper will
# warn on first launch. That is expected; see the "Install" section in README.md for the
# one-time bypass instructions to put in the release notes.
set -euo pipefail

cd "$(dirname "$0")/.."

APP="MacRazer.app"
VOLNAME="MacRazer"
OUT_DIR="dist"
OUT_DMG="${OUT_DIR}/MacRazer.dmg"

echo "▸ Building ${APP}…"
./Scripts/build-app.sh

echo "▸ Staging DMG contents…"
STAGE="$(mktemp -d)"
cp -R "${APP}" "${STAGE}/"
ln -s /Applications "${STAGE}/Applications"

mkdir -p "${OUT_DIR}"
rm -f "${OUT_DMG}"

echo "▸ Writing ${OUT_DMG}…"
hdiutil create -volname "${VOLNAME}" -srcfolder "${STAGE}" -ov -format UDZO "${OUT_DMG}"

rm -rf "${STAGE}"

echo "✓ Built ${OUT_DMG}"
echo "  This app is unsigned/self-signed — first launch will trigger a Gatekeeper warning."
echo "  See the 'Install' section in README.md for the bypass steps to include in release notes."
