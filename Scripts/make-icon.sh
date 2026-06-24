#!/usr/bin/env bash
# Generate Packaging/AppIcon.icns from the in-app icon renderer. Run after changing the
# icon design; build-app.sh then bundles the .icns.
set -euo pipefail
cd "$(dirname "$0")/.."

ICONSET="$(mktemp -d)/MacRazer.iconset"
mkdir -p "$ICONSET"
swift run MacRazer iconset "$ICONSET"
iconutil -c icns "$ICONSET" -o Packaging/AppIcon.icns
echo "Wrote Packaging/AppIcon.icns"
