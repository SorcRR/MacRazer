#!/usr/bin/env bash
# Render the README and website screenshots from preview data, no mouse needed.
#
#   ./Scripts/render-screenshots.sh                 # into dist/screenshots/
#   ./Scripts/render-screenshots.sh out/ 0.11.0     # another folder, another version
#
# Every shot is a `render-*` command (see main.swift) in the solid Dark theme, captured from
# the window server, so it shows what the app draws on screen. The version in the popover's
# footer is the latest tag unless one is given.
#
# The renders run from a throwaway app bundle opened with `open`, not from the bare binary:
# only an app launched that way may make itself active, and an inactive app draws its switches
# grey whether they're on or off. So each render takes focus for a moment, then gives it back.
# The bundle has its own defaults domain, which this script sets, so a render never depends on
# the popover sections you happen to have open in your own MacRazer.
#
# Then copy what changed:
#   README:   popover, buttons, battery-usage, popover-accessories, settings-general,
#             theme-light, theme-green, dpi-stages, device-test  → .github/screenshots/
#   Website:  the same, plus the card-* crops                    → macrazer-worker site/public/assets/
set -euo pipefail
cd "$(dirname "$0")/.."

OUT="${1:-dist/screenshots}"
VERSION="${2:-$(git describe --tags --abbrev=0 | sed 's/^v//')}"
mkdir -p "$OUT"
OUT="$(cd "$OUT" && pwd)" # absolute: the bundle runs with / as its working directory

echo "▸ Building…"
swift build >/dev/null 2>&1
BIN="$(swift build --show-bin-path)/MacRazer"

BUNDLE_ID="com.macrazer.render"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"; defaults delete "$BUNDLE_ID" 2>/dev/null || true' EXIT
APP="$WORK/MacRazer.app"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN" "$APP/Contents/MacOS/MacRazer"
cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleExecutable</key><string>MacRazer</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleName</key><string>MacRazer</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>LSUIElement</key><true/>
</dict></plist>
EOF
codesign -f -s - "$APP" 2>/dev/null

# What's open in the popover: Lighting, and the keyboard's card in the accessories shot.
defaults delete "$BUNDLE_ID" 2>/dev/null || true
defaults write "$BUNDLE_ID" popoverExpandedSections -string lighting
defaults write "$BUNDLE_ID" popoverAccessoryExpanded.554 -bool true # 0x022A, the Cynosa Chroma

render() { # render <file> <command> [args…]
  local file="$1"; shift
  rm -f "$OUT/$file"
  open -W -n --stdout "$WORK/log" --stderr "$WORK/log" "$APP" --args "$@" "version=$VERSION" "$OUT/$file"
  [[ -s "$OUT/$file" ]] || { echo "✗ $file: render failed" >&2; cat "$WORK/log" >&2; exit 1; }
}

# The card crops (`crop=x,y,width,height`, in points) frame one part of a full render. A layout
# change moves that part, so a full render whose size isn't the one the crops were measured on
# stops the script instead of shipping a crop of the wrong thing. Re-measure, then update.
expect_size() { # expect_size <file> <width> <height>, in pixels of the 2x render
  local w h
  w=$(sips -g pixelWidth "$OUT/$1" | awk '/pixelWidth/ {print $2}')
  h=$(sips -g pixelHeight "$OUT/$1" | awk '/pixelHeight/ {print $2}')
  if [[ "$w" != "$2" || "$h" != "$3" ]]; then
    echo "✗ $1 is ${w}x${h}, the crops were measured on ${2}x${3}. Check the crops, then update." >&2
    exit 1
  fi
}

echo "▸ Rendering v$VERSION into $OUT/ (each render takes focus for a moment)"
render popover.png             render-ui hosted
render popover-accessories.png render-ui hosted three follow wave
render battery-usage.png       render-ui hosted usage
render buttons.png             render-remap
render settings-general.png    render-settings reversed
render theme-light.png         render-ui hosted light
render theme-green.png         render-ui hosted green
render dpi-stages.png          render-ui hosted stages
render device-test.png         render-device-test dpi ran

echo "▸ Cropping for the feature cards"
expect_size dpi-stages.png 760 1360
render card-dpi-stages.png         render-ui hosted stages crop=0,178,380,145
expect_size device-test.png 880 882
render card-device-test.png        render-device-test dpi ran crop=0,0,440,200
expect_size settings-general.png 1560 1080
render card-settings-scrolling.png render-settings reversed crop=230,165,540,95
# The three themes side by side, each the top of its popover: header, battery and DPI.
for f in popover theme-light theme-green; do expect_size "$f.png" 760 1298; done
render card-theme-dark.png         render-ui hosted crop=0,0,380,290
render card-theme-light.png        render-ui hosted light crop=0,0,380,290
render card-theme-green.png        render-ui hosted green crop=0,0,380,290

ls -1 "$OUT"
