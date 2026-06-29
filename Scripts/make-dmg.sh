#!/usr/bin/env bash
# Package "MacRazer.app" into a drag-to-install DMG for distribution.
#
#   ./Scripts/make-dmg.sh            # builds the app, then writes ./dist/MacRazer.dmg
#                                     # plus a versioned copy, e.g. ./dist/MacRazer-0.1.5.dmg
#
# Both files have identical contents. "MacRazer.dmg" is the canonical name every fixed
# "latest" link (the website, the in-app update checker, README/CONTRIBUTING) downloads by
# name via GitHub's /releases/latest/download/<name> shortcut — that trick only works if the
# filename is the same on every release, so it must keep this exact name. The versioned copy
# is just so the filename is self-describing for anyone browsing the Releases page directly;
# attach both as separate assets on the GitHub release.
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

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Packaging/Info.plist)"
VERSIONED_DMG="${OUT_DIR}/MacRazer-${VERSION}.dmg"

echo "▸ Staging DMG contents…"
STAGE="$(mktemp -d)"
cp -R "${APP}" "${STAGE}/"
ln -s /Applications "${STAGE}/Applications"

mkdir -p "${OUT_DIR}"
rm -f "${OUT_DMG}" "${VERSIONED_DMG}"

echo "▸ Writing ${OUT_DMG}…"
hdiutil create -volname "${VOLNAME}" -srcfolder "${STAGE}" -ov -format UDZO "${OUT_DMG}"
cp "${OUT_DMG}" "${VERSIONED_DMG}"

rm -rf "${STAGE}"

echo "✓ Built ${OUT_DMG} and ${VERSIONED_DMG}"
echo "  This app is unsigned/self-signed — first launch will trigger a Gatekeeper warning."
echo "  See the 'Install' section in README.md for the bypass steps to include in release notes."
