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
    # Signing normally takes well under a second. When it doesn't, it is because macOS has
    # put up a GUI keychain prompt for the private key that a background or CI build has
    # nobody to click — and from the outside that is indistinguishable from a hang. So say so,
    # but only once it is actually happening: printing the advice on every build would be
    # noise, and worse, would still be telling people to run a fix they had already run.
    # A sentinel the watchdog polls for, rather than `kill -0` on the signing PID: a PID that
    # has been recycled by another process answers `kill -0` just as happily, which would print
    # "still signing" about a build that finished in half a second. The file existing means
    # codesign has not returned — nothing else can claim it.
    DONE_FLAG="$(mktemp -t macrazer-codesign)"
    # The explicit `rm -f` below is what stops the watchdog promptly; this is the safety net
    # for the paths that never reach it — Ctrl-C while waiting on the keychain prompt, which
    # is the exact situation this watchdog exists for. `:-` because the trap is script-wide
    # and `set -u` would fire on the ad-hoc branch, where DONE_FLAG is never set.
    trap 'rm -f "${DONE_FLAG:-}"' EXIT
    codesign --force --sign "${SIGN_ID}" --identifier com.macrazer.menubar --timestamp=none "${APP}" &
    CODESIGN_PID=$!
    (
        # Polled in short steps rather than one `sleep 5`: killing the watchdog while it sits
        # in a long sleep orphans that sleep, so the script would leave a stray process behind
        # for seconds after it returned.
        WAITED=0
        while [ "${WAITED}" -lt 50 ] && [ -e "${DONE_FLAG}" ]; do
            sleep 0.1
            WAITED=$((WAITED + 1))
        done
        if [ -e "${DONE_FLAG}" ]; then
            echo ""
            echo "  ⏳ Still signing after 5s — macOS is probably asking for keychain access."
            echo "     Click 'Always Allow' in the dialog, then run this once to stop it asking:"
            echo "       ./Scripts/setup-signing.sh --repair"
        fi
    ) &
    HINT_PID=$!
    # `wait` on a failed child would trip `set -e` before the watchdog is cleaned up.
    CODESIGN_STATUS=0
    wait "${CODESIGN_PID}" || CODESIGN_STATUS=$?
    rm -f "${DONE_FLAG}"          # stops the watchdog within 100ms, and tells it not to print
    wait "${HINT_PID}" 2>/dev/null || true
    if [ "${CODESIGN_STATUS}" -ne 0 ]; then
        echo "✗ codesign failed (status ${CODESIGN_STATUS})" >&2
        exit "${CODESIGN_STATUS}"
    fi
else
    echo "▸ Ad-hoc codesigning (run Scripts/setup-signing.sh for a stable identity)…"
    codesign --force --sign - --identifier com.macrazer.menubar --timestamp=none "${APP}"
fi

echo "✓ Built ${APP}"
echo "  Launch:  open \"${APP}\""
echo "  First run will prompt for Input Monitoring — grant it in"
echo "  System Settings → Privacy & Security → Input Monitoring, then relaunch."
