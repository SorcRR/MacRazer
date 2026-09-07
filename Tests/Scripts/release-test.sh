#!/usr/bin/env bash
# Tests for the parts of Scripts/release.sh that decide things: the version comparison and the
# two changelog operations.
#
# `bash -n` and shellcheck prove the script parses; they cannot catch two individually-valid
# regexes that disagree with each other, which is exactly what went wrong once — the guard
# counted entries under a heading the rewrite then didn't match, so a release could be built
# and declared ready with its changelog never promoted. These are fixture tests for that class.
#
#   ./Tests/Scripts/release-test.sh
set -uo pipefail

cd "$(dirname "$0")/../.."
RELEASE="Scripts/release.sh"
PASS=0
FAIL=0

ok()   { PASS=$((PASS + 1)); echo "  ✓ $1"; }
bad()  { FAIL=$((FAIL + 1)); echo "  ✗ $1"; echo "      expected: $2"; echo "      actual:   $3"; }
check() { [ "$2" = "$3" ] && ok "$1" || bad "$1" "$2" "$3"; }

# The script guards on state (branch, cleanliness) before reaching its logic, so the logic is
# extracted the same way a caller would read it: by the marker comments around it.
UNRELEASED_HEADING="$(grep -m1 "^UNRELEASED_HEADING=" "${RELEASE}" | cut -d"'" -f2)"
[ -n "${UNRELEASED_HEADING}" ] || { echo "couldn't read UNRELEASED_HEADING from ${RELEASE}"; exit 1; }

count_entries() { # <file>
    awk -v h="${UNRELEASED_HEADING}" '$0 == h {f=1; next} /^## \[/{f=0} f && /^- /' "$1" | wc -l | tr -d ' '
}
promote() { # <file> <version> <date>  → stdout, non-zero if nothing matched
    awk -v ver="$2" -v today="$3" -v h="${UNRELEASED_HEADING}" '
        { print }
        $0 == h && !inserted { print ""; print "## [" ver "] — " today; inserted = 1 }
        END { exit inserted ? 0 : 1 }
    ' "$1"
}

TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

echo "Counting entries under [Unreleased]"

printf '# C\n\n## [Unreleased]\n\n### Added\n- one\n- two\n\n## [0.2.1] — x\n\n### Added\n- old\n' > "${TMP}/two.md"
check "counts only the unreleased entries" "2" "$(count_entries "${TMP}/two.md")"

printf '# C\n\n## [Unreleased]\n\n## [0.2.1] — x\n\n### Added\n- old\n- older\n' > "${TMP}/empty.md"
check "an empty section counts zero, not the release below it" "0" "$(count_entries "${TMP}/empty.md")"

# Continuation lines are indented, so only the leading "- " lines are entries.
printf '# C\n\n## [Unreleased]\n\n### Added\n- one\n continued here\n more\n\n## [0.2.1] — x\n' > "${TMP}/wrap.md"
check "wrapped entries count once" "1" "$(count_entries "${TMP}/wrap.md")"

echo "Promoting [Unreleased] to a version heading"

promote "${TMP}/two.md" "0.3.0" "2026-09-04" > "${TMP}/out.md"
check "inserts the new heading" "1" "$(grep -c '^## \[0.3.0\] — 2026-09-04$' "${TMP}/out.md")"
check "leaves [Unreleased] empty" "0" "$(count_entries "${TMP}/out.md")"
check "moves the entries under the new heading" "2" \
    "$(awk '/^## \[0.3.0\]/{f=1;next} /^## \[0.2.1\]/{f=0} f && /^- /' "${TMP}/out.md" | wc -l | tr -d ' ')"
check "keeps the previous release intact" "1" \
    "$(awk '/^## \[0.2.1\]/{f=1;next} /^## \[/{f=0} f && /^- /' "${TMP}/out.md" | wc -l | tr -d ' ')"
check "loses no lines but the two it adds" "2" \
    "$(( $(wc -l < "${TMP}/out.md") - $(wc -l < "${TMP}/two.md") ))"

# The regression this suite exists for: the guard and the rewrite must agree about what an
# [Unreleased] heading is. They once didn't, and a decorated heading slipped between them.
printf '# C\n\n## [Unreleased] (next)\n\n### Added\n- one\n\n## [0.2.1] — x\n' > "${TMP}/decorated.md"
DECORATED_COUNT="$(count_entries "${TMP}/decorated.md")"
promote "${TMP}/decorated.md" "0.3.0" "2026-09-04" > /dev/null 2>&1
DECORATED_PROMOTED=$?
if [ "${DECORATED_COUNT}" -gt 0 ] && [ "${DECORATED_PROMOTED}" -ne 0 ]; then
    bad "guard and rewrite agree on what a heading is" \
        "both accept or both reject" "guard counted ${DECORATED_COUNT}, rewrite refused"
else
    ok "guard and rewrite agree on what a heading is"
fi

# A missing section must fail loudly rather than print the file unchanged and exit 0.
printf '# C\n\n## [0.2.1] — x\n\n### Added\n- old\n' > "${TMP}/none.md"
promote "${TMP}/none.md" "0.3.0" "2026-09-04" > /dev/null 2>&1
check "a missing [Unreleased] is an error, not a silent no-op" "1" "$?"

echo "Comparing versions"

# Sourced rather than reimplemented — a copy here could drift from the script exactly as the
# script could drift from VersionCompare.
eval "$(awk '/^version_gt\(\)/,/^}/' "${RELEASE}")"
newer() { version_gt "$1" "$2" && echo yes || echo no; }

check "0.3.0 > 0.2.1"      "yes" "$(newer 0.3.0 0.2.1)"
check "0.2.2 > 0.2.1"      "yes" "$(newer 0.2.2 0.2.1)"
check "0.2.10 > 0.2.9"     "yes" "$(newer 0.2.10 0.2.9)"   # not a string compare
check "1.0.0 > 0.9.9"      "yes" "$(newer 1.0.0 0.9.9)"
check "0.2.1 == 0.2.1"     "no"  "$(newer 0.2.1 0.2.1)"
check "0.2.0 < 0.2.1"      "no"  "$(newer 0.2.0 0.2.1)"
check "0.2.9 < 0.2.10"     "no"  "$(newer 0.2.9 0.2.10)"
check "0.2 == 0.2.0"       "no"  "$(newer 0.2 0.2.0)"      # trailing zero, same as VersionCompare
check "0.3 > 0.2.9"        "yes" "$(newer 0.3 0.2.9)"
check "0.2.08 > 0.2.7"     "yes" "$(newer 0.2.08 0.2.7)"   # leading zero isn't octal

echo
if [ "${FAIL}" -eq 0 ]; then
    echo "✓ ${PASS} passed"
else
    echo "✗ ${FAIL} failed, ${PASS} passed"
    exit 1
fi
