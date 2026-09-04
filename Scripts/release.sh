#!/usr/bin/env bash
# Cut a release: bump the version everywhere it is recorded, close off the changelog, build
# the DMGs, and check the result is self-consistent.
#
#   ./Scripts/release.sh 0.3.0             # do it
#   ./Scripts/release.sh 0.3.0 --dry-run   # show what it would do, touch nothing
#
# The version lives in three places and the changelog in a fourth, and they have to agree.
# That mattered little when a stale version was cosmetic; since the in-app updater compares
# the GitHub tag against the running bundle's own version, a release tagged v0.3.0 whose
# bundle still says 0.2.1 leaves every user with an update badge they can never clear — the
# app installs the update, still reports the old version, and finds the same release "newer"
# on every check. `UpdateInstaller`'s notNewer guard stops it looping, so it fails safe, but
# the badge never goes away. This script exists so that can't be forgotten.
#
# It deliberately stops before `git commit`, `git tag` and `gh release create`: it makes the
# error-prone edits and leaves the outward-facing, hard-to-undo steps to you, with the exact
# commands printed at the end. Review the diff first, as you would any other change.
set -euo pipefail

cd "$(dirname "$0")/.."

PLIST="Packaging/Info.plist"
CHANGELOG="CHANGELOG.md"
SITE="docs/index.html"

DRY_RUN=0
VERSION=""
for arg in "$@"; do
    case "${arg}" in
        --dry-run) DRY_RUN=1 ;;
        -*) echo "Usage: $0 <version> [--dry-run]" >&2; exit 64 ;;
        *)
            if [ -n "${VERSION}" ]; then
                echo "Usage: $0 <version> [--dry-run]" >&2; exit 64
            fi
            VERSION="${arg}"
            ;;
    esac
done
[ -n "${VERSION}" ] || { echo "Usage: $0 <version> [--dry-run]" >&2; exit 64; }

fail() { echo "✗ $*" >&2; exit 1; }
step() { echo "▸ $*"; }

# --- Preconditions ------------------------------------------------------------------------
# Every one of these has a failure mode that is worse to discover after the tag is pushed.

# Dotted integers only: `VersionCompare` in the app parses exactly this shape, and anything
# else (a `v` prefix, a `-beta` suffix) compares in ways the updater does not intend.
echo "${VERSION}" | grep -Eq '^[0-9]+(\.[0-9]+)*$' \
    || fail "version must be dotted integers, e.g. 0.3.0 — got '${VERSION}'"

CURRENT="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "${PLIST}")"
CURRENT_BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "${PLIST}")"

# Same comparison the app makes, so the script can't approve a release the updater would
# refuse to install.
version_gt() {
    local IFS=.
    local -a a=($1) b=($2)
    local i x y
    for ((i = 0; i < ${#a[@]} || i < ${#b[@]}; i++)); do
        x=${a[i]:-0}; y=${b[i]:-0}
        ((10#$x > 10#$y)) && return 0
        ((10#$x < 10#$y)) && return 1
    done
    return 1
}
version_gt "${VERSION}" "${CURRENT}" \
    || fail "${VERSION} is not newer than the current ${CURRENT}; the updater would refuse it"

[ -z "$(git status --porcelain)" ] \
    || fail "working tree is dirty — commit or stash first, so the release diff is only the release"

BRANCH="$(git rev-parse --abbrev-ref HEAD)"
[ "${BRANCH}" = "master" ] \
    || fail "on '${BRANCH}', not master — releases are cut from master"

git fetch -q origin master
[ "$(git rev-parse HEAD)" = "$(git rev-parse origin/master)" ] \
    || fail "master is not in sync with origin/master — pull or push first"

# An empty Unreleased section means there is nothing to release, and would silently produce a
# version heading with no entries under it.
UNRELEASED_ENTRIES="$(awk '/^## \[Unreleased\]/{f=1; next} /^## \[/{f=0} f && /^- /' "${CHANGELOG}" | wc -l | tr -d ' ')"
[ "${UNRELEASED_ENTRIES}" -gt 0 ] \
    || fail "CHANGELOG has no entries under [Unreleased] — nothing to release"

NEXT_BUILD=$((CURRENT_BUILD + 1))
TODAY="$(date +%Y-%m-%d)"

echo
echo "  ${CURRENT} (build ${CURRENT_BUILD})  →  ${VERSION} (build ${NEXT_BUILD})"
echo "  ${UNRELEASED_ENTRIES} changelog entries move under '## [${VERSION}] — ${TODAY}'"
echo

if [ "${DRY_RUN}" -eq 1 ]; then
    echo "(dry run — nothing written)"
    exit 0
fi

# --- Edits --------------------------------------------------------------------------------

step "Bumping ${PLIST}…"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString ${VERSION}" "${PLIST}"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion ${NEXT_BUILD}" "${PLIST}"

step "Closing off ${CHANGELOG}…"
# Insert the new heading directly under [Unreleased]: everything already written falls under
# it, and [Unreleased] is left empty for the next cycle.
awk -v ver="${VERSION}" -v today="${TODAY}" '
    { print }
    /^## \[Unreleased\]$/ && !done { print ""; print "## [" ver "] — " today; done = 1 }
' "${CHANGELOG}" > "${CHANGELOG}.tmp" && mv "${CHANGELOG}.tmp" "${CHANGELOG}"

step "Updating ${SITE}…"
# Only the structured-data field is hardcoded; the visible version tags fetch the latest tag
# from the GitHub API at page load, so they follow on their own.
sed -i '' "s/\"softwareVersion\": \"${CURRENT}\"/\"softwareVersion\": \"${VERSION}\"/" "${SITE}"
grep -q "\"softwareVersion\": \"${VERSION}\"" "${SITE}" \
    || fail "couldn't update softwareVersion in ${SITE} — is it still there?"

step "Building the DMGs…"
./Scripts/make-dmg.sh

# --- Verify -------------------------------------------------------------------------------
# The point of the whole script: prove the artifact actually carries the version being tagged.

BUILT="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' MacRazer.app/Contents/Info.plist)"
[ "${BUILT}" = "${VERSION}" ] \
    || fail "built app reports ${BUILT}, not ${VERSION} — do not tag this"

for asset in "dist/MacRazer.dmg" "dist/MacRazer-${VERSION}.dmg"; do
    [ -f "${asset}" ] || fail "expected ${asset} — make-dmg.sh did not produce it"
done

echo
echo "✓ ${VERSION} (build ${NEXT_BUILD}) is ready, and the built app agrees."
echo
echo "  Review, then:"
echo "    git diff"
echo "    git commit -am 'Release v${VERSION}'"
echo "    git push"
echo "    git tag v${VERSION} && git push origin v${VERSION}"
echo "    gh release create v${VERSION} \\"
echo "      dist/MacRazer.dmg dist/MacRazer-${VERSION}.dmg \\"
echo "      --title 'v${VERSION}' --notes-from-tag"
echo
echo "  Attach BOTH assets: the in-app updater fetches the fixed 'MacRazer.dmg' name, and the"
echo "  versioned copy is what makes the Releases page self-describing."
