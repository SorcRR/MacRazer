#!/usr/bin/env bash
# Draft the GitHub release body for a version, printed to stdout.
#
#   ./Scripts/release-notes.sh 0.3.1 > dist/RELEASE_NOTES-0.3.1.md
#   ./Scripts/release-notes.sh 0.3.0 --since v0.2.1   # redo a past one
#
# The release body and CHANGELOG.md are different documents for different readers, and the
# body is the one the app shows: `UpdateChecker` fetches it and the popover's "What's new"
# page is built from it. So a release published with no body makes that page quietly not
# appear, and a release that forgets a contributor forgets them in the place users read.
#
# This drafts the parts that are mechanical and easy to forget — every changelog entry in the
# release, everyone whose PR is in it, the install note, the changelog link — and leaves the
# writing to you. It does not invent copy: the entries come out verbatim, for you to tighten.
# The body you publish should be shorter than what comes out of here.
set -euo pipefail

cd "$(dirname "$0")/.."

VERSION=""
SINCE=""
CHANGELOG="CHANGELOG.md"
REPO=""

CHECK=""

usage() {
    echo "Usage: $0 <version> [--since <ref>] [--changelog <file>] [--repo <owner/repo>]" >&2
    echo "       $0 --check <file>" >&2
    exit 64
}

while [ $# -gt 0 ]; do
    case "$1" in
        --since)     [ $# -ge 2 ] || usage; SINCE="$2"; shift 2 ;;
        --changelog) [ $# -ge 2 ] || usage; CHANGELOG="$2"; shift 2 ;;
        --repo)      [ $# -ge 2 ] || usage; REPO="$2"; shift 2 ;;
        --check)     [ $# -ge 2 ] || usage; CHECK="$2"; shift 2 ;;
        -*)          usage ;;
        *)           [ -z "${VERSION}" ] || usage; VERSION="$1"; shift ;;
    esac
done

fail() { echo "✗ $*" >&2; exit 1; }
note() { echo "  $*" >&2; }

# --- --check: is this draft finished? --------------------------------------------------------
# The one mistake this whole script makes possible: publishing the draft as written. The
# placeholder would become the release's first paragraph, which is exactly what the app shows
# as the summary. Cheap to check, so check rather than remember.
if [ -n "${CHECK}" ]; then
    [ -f "${CHECK}" ] || fail "no such file: ${CHECK}"
    if grep -q '^TODO:' "${CHECK}"; then
        fail "${CHECK} still has the TODO placeholder — that would be the release's first paragraph"
    fi
    # `/^#/`, not an interval expression: not every awk supports `{1,6}`, and in markdown
    # nothing but a heading starts a line with a hash anyway.
    SUMMARY="$(awk '/^#/{exit} {print}' "${CHECK}" | tr -d '[:space:]')"
    [ -n "${SUMMARY}" ] \
        || fail "${CHECK} has nothing above its first heading — the app would show no summary"
    echo "✓ ${CHECK} looks publishable" >&2
    exit 0
fi

[ -n "${VERSION}" ] || usage

[ -f "${CHANGELOG}" ] || fail "no ${CHANGELOG}"

# --- Who owns the repo ---------------------------------------------------------------------
# Needed only to tell the maintainer's own merges from everyone else's. Read from the remote
# rather than hardcoded, so a fork or a rename doesn't silently credit the wrong person.
if [ -z "${REPO}" ]; then
    ORIGIN="$(git remote get-url origin 2>/dev/null || true)"
    REPO="$(echo "${ORIGIN}" | sed -E 's#^(git@[^:]+:|https?://[^/]+/)##; s#\.git$##')"
fi
OWNER="${REPO%%/*}"
[ -n "${OWNER}" ] || fail "couldn't work out the repo owner — pass --repo owner/repo"

# --- The changelog section for this version -------------------------------------------------
SECTION="$(awk -v want="## [${VERSION}]" '
    index($0, want) == 1 { f = 1; next }
    f && /^## \[/        { exit }
    f                    { print }
' "${CHANGELOG}")"

# Entries, not just lines: a section holding only blank lines is as empty as no section.
echo "${SECTION}" | grep -q '^- ' \
    || fail "${CHANGELOG} has no entries under '## [${VERSION}]' — run this after release.sh has closed off the changelog"

# --- Who contributed ------------------------------------------------------------------------
# GitHub writes the PR number and the author's handle into every merge commit subject, and the
# PR title into its body, so this needs no network and no API token.
[ -n "${SINCE}" ] || SINCE="$(git describe --tags --abbrev=0 HEAD 2>/dev/null || true)"
RANGE="HEAD"
[ -n "${SINCE}" ] && RANGE="${SINCE}..HEAD"

THANKS=""
CREDITED=""
for sha in $(git log "${RANGE}" --merges --reverse --format='%H' 2>/dev/null || true); do
    subject="$(git log -1 --format='%s' "${sha}")"
    case "${subject}" in
        "Merge pull request #"*)
            pr="$(echo "${subject}" | sed -E 's/^Merge pull request #([0-9]+) from .*$/\1/')"
            # `|` as the delimiter, not `#`: the pattern itself contains the `#` of `#[0-9]+`.
            handle="$(echo "${subject}" | sed -E 's|^Merge pull request #[0-9]+ from ([^/]+)/.*$|\1|')"
            title="$(git log -1 --format='%b' "${sha}" | head -1)"
            # Case-insensitive: GitHub handles are, and "SorcRR" vs "sorcrr" would credit the
            # maintainer in their own release notes.
            [ "$(echo "${handle}" | tr 'A-Z' 'a-z')" = "$(echo "${OWNER}" | tr 'A-Z' 'a-z')" ] && continue
            # A merge made by hand can carry no body, and "@caseyc —  (#5)" reads as a typo.
            if [ -n "${title}" ]; then
                THANKS="${THANKS}- **@${handle}** — ${title} (#${pr})
"
            else
                THANKS="${THANKS}- **@${handle}** (#${pr})
"
            fi
            CREDITED="${CREDITED} ${handle}"
            ;;
    esac
done

# A squash-merged PR leaves no merge commit to read, so its author would go uncredited with
# nothing said about it. Say it — on stderr, so it reaches the person running this and not the
# file they are about to publish.
UNCREDITED="$(git log "${RANGE}" --no-merges --format='%an' 2>/dev/null | sort -u | while read -r name; do
    [ -n "${name}" ] || continue
    lower="$(echo "${name}" | tr 'A-Z' 'a-z' | tr -d ' ')"
    known=" $(echo "${CREDITED} ${OWNER}" | tr 'A-Z' 'a-z' | tr -s ' ' '\n' | tr -d ' \t' | tr '\n' ' ')"
    echo "${known}" | grep -qF " ${lower} " || echo "${name}"
done)"

# --- The draft -------------------------------------------------------------------------------

cat <<EOF
TODO: one line saying what this release is about — the app shows everything above the first
heading as the summary. The entries below are verbatim from the changelog, which is written
for contributors: tighten them for users, expect to cut most of it, and delete these lines.
EOF

# Verbatim. Tightening these is the editorial half, and a script that paraphrased them would
# be inventing copy nobody reviewed.
echo "${SECTION}" | awk 'NF { blank = 0; print; next } { if (!blank) print; blank = 1 }'

# printf, not a heredoc: `${THANKS}` already ends in a newline, and a heredoc terminator is
# matched against the source line, not against what the expansion produced.
if [ -n "${THANKS}" ]; then
    printf '\n### Thanks\n%s' "${THANKS}"
fi

cat <<EOF

### Install
This build is unsigned (no paid Apple Developer ID), so first launch shows the standard
Gatekeeper warning. Right-click **MacRazer.app** in Finder → **Open** → **Open**. Only needed
once. See the README for details.

**Full changelog:** https://github.com/${REPO}/blob/master/${CHANGELOG}
EOF

# --- What the person running this needs to know ----------------------------------------------
note ""
note "Drafted from '## [${VERSION}]' in ${CHANGELOG}, over ${RANGE}."
if [ -n "${THANKS}" ]; then
    note "Credited:$(echo "${CREDITED}" | tr ' ' '\n' | grep -v '^$' | sed 's/^/ @/' | tr '\n' ' ')"
else
    note "No outside contributors in this range."
fi
if [ -n "${UNCREDITED}" ]; then
    note ""
    note "⚠ These authors wrote commits in the range but have no merge commit to credit them by"
    note "  (a squash-merged PR leaves none). Add them to Thanks by hand:"
    echo "${UNCREDITED}" | while read -r n; do note "    ${n}"; done
fi
note ""
note "Edit before publishing. The TODO line at the top is not a release note."
