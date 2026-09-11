#!/usr/bin/env bash
# Tests for Scripts/release-notes.sh — the draft of the GitHub release body.
#
# Worth testing because both halves fail silently. A changelog section extracted one heading
# too far produces a body that quietly carries the previous release's entries; a contributor
# missed produces a release that credits nobody, and neither looks wrong on the page. The
# credit half is also the only thing here that reads git history, so it gets a real repository
# with real merge commits rather than a fixture of strings.
#
#   ./Tests/Scripts/release-notes-test.sh
set -uo pipefail

cd "$(dirname "$0")/../.."
SOURCE="$(pwd)/Scripts/release-notes.sh"
PASS=0
FAIL=0

ok()    { PASS=$((PASS + 1)); echo "  ✓ $1"; }
bad()   { FAIL=$((FAIL + 1)); echo "  ✗ $1"; echo "      expected: $2"; echo "      actual:   $3"; }
check() { [ "$2" = "$3" ] && ok "$1" || bad "$1" "$2" "$3"; }

TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

# --- A repository with a history worth reading ----------------------------------------------
# The script resolves the repository from its own location (`cd "$(dirname "$0")/.."`), the
# way every script in Scripts/ does, so testing it against a fixture repository means putting
# a copy inside that repository — running the original would quietly read this one.
REPO="${TMP}/repo"
mkdir -p "${REPO}/Scripts"
cp "${SOURCE}" "${REPO}/Scripts/release-notes.sh"
DRAFT="${REPO}/Scripts/release-notes.sh"
cd "${REPO}"
git init -q -b master
git config user.email "owner@example.com"
git config user.name "theowner"
git remote add origin "git@github.com:theowner/Thing.git"

cat > CHANGELOG.md <<'MD'
# Changelog

## [Unreleased]

## [0.3.0] — 2026-09-07

### Added
- **A new thing.** It does something.
- **Another thing.** It does something else.

### Fixed
- **A bug.** It is gone.

## [0.2.1] — 2026-08-01

### Added
- **An older thing.** From the release before.
MD
git add -A && git commit -qm "Initial"
git tag v0.2.1

# A contributor's PR, merged the way GitHub merges one.
git checkout -q -b contribution
echo one > one.txt && git add -A
git -c user.email="c@example.com" -c user.name="Casey Contributor" commit -qm "Add one"
git checkout -q master
# Two -m flags, because that is what makes a subject and a separate body — a single -m with
# an embedded newline is folded into one subject line, and then there is no PR title to read.
git merge -q --no-ff contribution \
    -m "Merge pull request #5 from caseyc/contribution" -m "Add support for the thing"

# The maintainer's own PR, merged the same way. Must not be credited.
git checkout -q -b ownwork
echo two > two.txt && git add -A && git commit -qm "Add two"
git checkout -q master
git merge -q --no-ff ownwork \
    -m "Merge pull request #6 from theowner/ownwork" -m "Tidy something up"

# A merge with the right prefix and the wrong shape. Its handle can't be read, and printing
# the whole subject as one would put "@Merge pull request #7 from somebody" in the credits.
git checkout -q -b handmade
echo three > three.txt && git add -A && git commit -qm "Add three"
git checkout -q master
git merge -q --no-ff handmade -m "Merge pull request #7 from somebody" -m "No branch in the subject"

# A squash-merged PR: someone else's work landing directly on master with no merge commit.
# This is the one case the uncredited warning exists for.
echo four > four.txt && git add -A
git -c user.email="s@example.com" -c user.name="Sam Squash" commit -qm "Add four (#9)"

cd - >/dev/null

run() { (cd "${REPO}" && "${DRAFT}" "$@" 2>/dev/null); }
runerr() { (cd "${REPO}" && "${DRAFT}" "$@" 2>&1 >/dev/null); }

echo "Extracting the changelog section"

OUT="$(run 0.3.0 --since v0.2.1)"
check "takes the entries for the version asked for" "1" "$(echo "${OUT}" | grep -c 'A new thing')"
check "takes every section, not just the first" "1" "$(echo "${OUT}" | grep -c 'A bug')"
check "stops at the next release heading" "0" "$(echo "${OUT}" | grep -c 'An older thing')"
check "does not carry the version headings into the body" "0" "$(echo "${OUT}" | grep -c '^## \[')"

check "refuses a version that isn't in the changelog" "1" \
    "$( (cd "${REPO}" && "${DRAFT}" 9.9.9 >/dev/null 2>&1); echo $? )"
check "says which version it couldn't find" "1" \
    "$(runerr 9.9.9 | grep -c '9.9.9')"

echo "Crediting contributors"

check "credits the contributor by handle" "1" "$(echo "${OUT}" | grep -c '@caseyc')"
check "uses the PR title and number" "1" "$(echo "${OUT}" | grep -c 'Add support for the thing (#5)')"
# A merge made by hand can have no body at all, and "@caseyc:  (#5)" reads as a mistake.
check "no dangling colon when the merge has no PR title" "0" "$(echo "${OUT}" | grep -c -- ': *(#')"
# The draft has to survive the check this same script applies to it. Credits used an em dash
# until --check started rejecting them, which made the script reject its own output.
check "the draft it writes has no em dashes" "0" "$(echo "${OUT}" | grep -c -- '—')"
check "does not credit the repo owner in their own notes" "0" "$(echo "${OUT}" | grep -c '@theowner')"
check "leaves out the owner's PR title too" "0" "$(echo "${OUT}" | grep -c 'Tidy something up')"

# An empty Thanks heading is worse than none: it reads as "nobody helped" rather than as a
# section that didn't apply.
ONLY_OWNER="$(cd "${REPO}" && "${DRAFT}" 0.3.0 --since HEAD 2>/dev/null)"
check "no Thanks section when nobody outside contributed" "0" "$(echo "${ONLY_OWNER}" | grep -c '### Thanks')"

# The warning is the only thing standing between a squash-merged PR and an uncredited
# contributor, so it has to be believable. Matching git display names against GitHub handles
# warned about people it had just credited, and about the maintainer whenever their user.name
# wasn't their handle — which is most setups.
WARNED="$(runerr 0.3.0 --since v0.2.1)"
check "warns about a squash-merged contributor" "1" "$(echo "${WARNED}" | grep -c 'Sam Squash')"
check "does not warn about someone it just credited" "0" "$(echo "${WARNED}" | grep -c 'Casey Contributor')"
check "does not warn the maintainer about their own commits" "0" "$(echo "${WARNED}" | grep -c 'theowner')"
check "reports the merge it could not parse" "1" "$(echo "${WARNED}" | grep -c "doesn't parse")"
# This fixture has both a warning to give and a merge it can't parse, and warnings are not
# failures — release.sh runs this and aborts the release on a non-zero exit. It did abort:
# a warning loop whose body ended on a failing test returned that failure and `set -e` took
# the script down with it, after the draft had already been written.
check "warnings are not failures" "0" \
    "$( (cd "${REPO}" && "${DRAFT}" 0.3.0 --since v0.2.1 >/dev/null 2>&1); echo $? )"
check "does not credit an unparsable subject as a handle" "0" \
    "$(echo "${OUT}" | grep -c '@Merge pull request')"

echo "Reading the repository from any remote spelling"

# `ssh://` left the owner as "ssh:", which credited the maintainer in their own notes and
# pointed the changelog link at github.com/ssh://git@github.com/… — both without a word.
for url in "git@github.com:theowner/Thing.git" \
           "https://github.com/theowner/Thing.git" \
           "ssh://git@github.com/theowner/Thing.git" \
           "https://github.com/theowner/Thing"; do
    ( cd "${REPO}" && git remote set-url origin "${url}" )
    check "reads owner/repo from ${url}" "1" \
        "$(run 0.3.0 --since v0.2.1 | grep -c 'github.com/theowner/Thing/blob/master/CHANGELOG.md')"
done
( cd "${REPO}" && git remote set-url origin "git@github.com:theowner/Thing.git" )

check "refuses a remote it cannot read as owner/repo" "1" \
    "$( (cd "${REPO}" && "${DRAFT}" 0.3.0 --repo "not-a-repo" >/dev/null 2>&1); echo $? )"

echo "The parts that must always be there"

check "leaves a placeholder for the summary" "1" "$(echo "${OUT}" | grep -c '^TODO:')"
check "includes the install note" "1" "$(echo "${OUT}" | grep -c '^### Install')"
check "links the full changelog at the repo it was run in" "1" \
    "$(echo "${OUT}" | grep -c 'github.com/theowner/Thing/blob/master/CHANGELOG.md')"

echo "The shape ReleaseNotes.swift is written against"

# The Swift side has a matching test, `testTheShapeReleaseNotesShDraftsParsesAsIntended`, but
# it can only assert against a copy of this template — there is no compiler between a shell
# script and a Swift struct. These assertions are the half that fails when the template moves,
# so a rename here can't silently change what the app renders.
check "the credits heading is exactly '### Thanks'" "1" "$(echo "${OUT}" | grep -c '^### Thanks$')"
check "the install heading is exactly '### Install'" "1" "$(echo "${OUT}" | grep -c '^### Install$')"
check "the footer keeps the '**Full changelog:' prefix" "1" \
    "$(echo "${OUT}" | grep -c '^\*\*Full changelog:')"
check "credits are bullets with a bold handle" "1" \
    "$(echo "${OUT}" | grep -c '^- \*\*@caseyc\*\*')"
# The parser reads everything above the first heading as the summary, so the placeholder must
# be above it and the first heading must be a heading.
check "the summary sits above the first heading" "1" \
    "$(echo "${OUT}" | awk '/^#/{exit} /^TODO:/{n++} END{print n+0}')"

echo "Refusing to publish a draft that is still a draft"

echo "${OUT}" > "${TMP}/unedited.md"
check "--check refuses the placeholder" "1" \
    "$( "${DRAFT}" --check "${TMP}/unedited.md" >/dev/null 2>&1; echo $? )"

# What an edited one looks like: the placeholder replaced by a real summary.
{ echo "It starts at login now."; echo; echo "${OUT}" | tail -n +4; } > "${TMP}/edited.md"
check "--check accepts an edited draft" "0" \
    "$( "${DRAFT}" --check "${TMP}/edited.md" >/dev/null 2>&1; echo $? )"

# No summary at all is the other way to lose it: the app shows nothing above the first heading.
echo "${OUT}" | tail -n +4 > "${TMP}/nosummary.md"
check "--check refuses a draft with no summary" "1" \
    "$( "${DRAFT}" --check "${TMP}/nosummary.md" >/dev/null 2>&1; echo $? )"

check "--check refuses a file that isn't there" "1" \
    "$( "${DRAFT}" --check "${TMP}/nope.md" >/dev/null 2>&1; echo $? )"

echo
if [ "${FAIL}" -eq 0 ]; then
    echo "✓ ${PASS} passed"
else
    echo "✗ ${FAIL} failed, ${PASS} passed"
    exit 1
fi
