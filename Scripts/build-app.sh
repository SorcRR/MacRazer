#!/usr/bin/env bash
# Build a standalone "MacRazer.app" menu bar bundle from the SwiftPM executable.
#
#   ./Scripts/build-app.sh           # release build → ./MacRazer.app
#   open "MacRazer.app"           # launch it
#
# Needs Xcode, not just the Command Line Tools: a build for two architectures goes through
# Xcode's build system. (`swift build` / `swift run` for development work with either.)
#
# The bundle is ad-hoc codesigned so it has a stable identity — important so macOS
# remembers the Input Monitoring grant across launches (unsigned binaries get a fresh,
# unstable TCC identity and re-prompt every time).
set -euo pipefail

cd "$(dirname "$0")/.."

APP="MacRazer.app"
EXEC_NAME="MacRazer"

# Universal: one binary for Apple Silicon and Intel. Nothing in the app is tied to either, and
# macOS 14 still runs on Intel Macs. The two-arch build lands in .build/apple/, not the usual
# .build/release/, so the bin path has to be asked with the same flags.
ARCHS=(--arch arm64 --arch x86_64)
echo "▸ Building universal release binary (arm64 + x86_64)…"
swift build -c release "${ARCHS[@]}"
BIN="$(swift build -c release "${ARCHS[@]}" --show-bin-path)/${EXEC_NAME}"
# Fail here rather than ship a release that quietly lost Intel (or Apple Silicon) support,
# say after a toolchain change.
if ! lipo "${BIN}" -verify_arch arm64 x86_64; then
    echo "✗ ${BIN} is not universal: $(lipo -archs "${BIN}")" >&2
    exit 1
fi

echo "▸ Assembling ${APP}…"
rm -rf "${APP}"
mkdir -p "${APP}/Contents/MacOS" "${APP}/Contents/Resources"
cp "${BIN}" "${APP}/Contents/MacOS/${EXEC_NAME}"
cp Packaging/Info.plist "${APP}/Contents/Info.plist"
[ -f Packaging/AppIcon.icns ] && cp Packaging/AppIcon.icns "${APP}/Contents/Resources/AppIcon.icns"

# The Worker behind Send and the usage stats. Its address comes from DOMAIN in the private
# settings file worker/README.md sets up, never from the repository, so a build from anyone
# else's checkout has no Worker: those features are hidden and nothing is sent anywhere.
# See `WorkerEndpoint` in Sources/MacRazer/AppInfo.swift.
WORKER_DOMAIN="$(./Scripts/worker-domain.sh)"
if [ -n "${WORKER_DOMAIN}" ]; then
    # Delete first: Add refuses a key that's already there.
    /usr/libexec/PlistBuddy -c "Delete :MacRazerWorkerURL" "${APP}/Contents/Info.plist" 2>/dev/null || true
    /usr/libexec/PlistBuddy -c "Add :MacRazerWorkerURL string https://${WORKER_DOMAIN}" "${APP}/Contents/Info.plist"
    echo "▸ Worker: https://${WORKER_DOMAIN} (Send and usage stats on)"
else
    echo "▸ No Worker configured, so Send and usage stats are hidden in this build."
fi

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
