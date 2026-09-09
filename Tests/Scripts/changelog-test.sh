#!/usr/bin/env bash
# Guards the changelog's structure. Runs in CI on every PR.
#
# This exists because folding duplicate headings by hand does not stick. Sections accumulate
# them whenever two branches each add, say, a `### Fixed` under `[Unreleased]` and both get
# merged — git appends cleanly, so nothing conflicts and nothing complains. It happened three
# times across one stack, and then again in the very PR that folded the first three: the fold
# ran, and the entry describing the fold was prepended above the section it had just merged.
#
# A person cannot reliably notice this in a diff. A check can.
#
#   ./Tests/Scripts/changelog-test.sh
set -uo pipefail

cd "$(dirname "$0")/../.."
CHANGELOG="CHANGELOG.md"
FAIL=0

fail() { FAIL=$((FAIL + 1)); echo "  ✗ $1"; }
ok()   { echo "  ✓ $1"; }

echo "Checking ${CHANGELOG}"

# 1. No release section may repeat a `### ` heading. Keep a Changelog groups entries under one
#    heading per kind; two `### Fixed` in a release is a merge artefact, not a structure.
DUPES="$(awk '
    /^## \[/ { section = $0; delete seen; next }
    /^### / { if (seen[$0]++) print section " → " $0 }
' "${CHANGELOG}")"
if [ -n "${DUPES}" ]; then
    fail "duplicate headings within a release section:"
    echo "${DUPES}" | sed 's/^/      /'
    echo "      fold the later block's entries into the first heading of that kind."
else
    ok "no release section repeats a heading"
fi

# 2. Every entry must sit under a `### ` heading. A bullet directly under `## [x.y.z]` renders
#    outside any category and is invisible to anything that parses the file by section.
ORPHANS="$(awk '
    /^## \[/ { section = $0; kind = ""; next }
    /^### /  { kind = $0; next }
    /^- /    { if (kind == "") print section " → " substr($0, 1, 60) "..." }
' "${CHANGELOG}")"
if [ -n "${ORPHANS}" ]; then
    fail "entries not under any ### heading:"
    echo "${ORPHANS}" | sed 's/^/      /'
else
    ok "every entry sits under a heading"
fi

# 3. `## [Unreleased]` must exist: Scripts/release.sh promotes it by exact match, and without
#    it a release would bump the versions and quietly ship no changelog section at all.
if grep -qx '## \[Unreleased\]' "${CHANGELOG}"; then
    ok "[Unreleased] heading present and exactly matched"
else
    fail "no line reading exactly '## [Unreleased]' — Scripts/release.sh needs it to promote"
fi

echo
if [ "${FAIL}" -eq 0 ]; then
    echo "✓ changelog structure is sound"
else
    echo "✗ ${FAIL} problem(s)"
    exit 1
fi
