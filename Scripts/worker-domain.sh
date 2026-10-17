#!/usr/bin/env bash
# Prints the Worker's hostname, DOMAIN from the maintainer's private settings file, or nothing
# when there's no file or no DOMAIN in it. Exits 1 with a message when DOMAIN is there but
# isn't a hostname, so a typo fails the build instead of quietly building an app without Send.
#
#   ./Scripts/worker-domain.sh                 # ~/.config/macrazer-reports/settings.env
#   MACRAZER_REPORTS_SETTINGS=/path ./Scripts/worker-domain.sh
#
# Reads the file the way worker/scripts/local-config.mjs does (KEY=value lines, # comments,
# optional quotes), so the app and the deployed Worker always agree on the address. Used by
# build-app.sh and release.sh.
set -euo pipefail

SETTINGS="${MACRAZER_REPORTS_SETTINGS:-${HOME}/.config/macrazer-reports/settings.env}"
[ -f "${SETTINGS}" ] || exit 0

DOMAIN="$(awk '
    { sub(/\r$/, ""); line = $0; gsub(/^[ \t]+|[ \t]+$/, "", line) }
    line == "" || line ~ /^#/ { next }
    {
        eq = index(line, "="); if (eq < 2) next
        key = substr(line, 1, eq - 1); gsub(/[ \t]+$/, "", key)
        value = substr(line, eq + 1); gsub(/^[ \t]+/, "", value)
        if (value ~ /^".*"$/) value = substr(value, 2, length(value) - 2)
        if (key == "DOMAIN") domain = value
    }
    END { printf "%s", domain }
' "${SETTINGS}")"

[ -n "${DOMAIN}" ] || exit 0
# The same rule as HOSTNAME in local-config.mjs: a name, no scheme, path or port.
if ! printf '%s' "${DOMAIN}" | grep -Eq '^([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,63}$'; then
    echo "✗ DOMAIN in ${SETTINGS} isn't a hostname: ${DOMAIN}" >&2
    exit 1
fi
printf '%s\n' "${DOMAIN}"
