#!/usr/bin/env bash
# One-time: create a stable self-signed code-signing identity so the Input Monitoring
# grant persists across rebuilds (and across app updates shipped to other users).
#
# After running this, every ./Scripts/build-app.sh will sign with this identity, giving
# the app a constant code identity — so you grant Input Monitoring once, not every build.
#
#   ./Scripts/setup-signing.sh            # create the identity (no-op if it exists)
#   ./Scripts/setup-signing.sh --repair   # re-grant codesign access to an existing identity
#
# Run it with no arguments to check or create. `--repair` is the fix when builds start
# stopping on a "codesign wants to use your keychain" prompt; it is kept behind a flag because
# it prompts for your login keychain password and rewrites the key's access list, and a bare
# run should not do either.
#
# If this scripted path gives you trouble, the GUI alternative is just as good:
#   Keychain Access → Certificate Assistant → Create a Certificate…
#     Name: "MacRazer Self-Signed"   Identity Type: Self-Signed Root
#     Certificate Type: Code Signing    → Create
set -euo pipefail

REPAIR=0
case "${1:-}" in
    --repair) REPAIR=1 ;;
    "") ;;
    *) echo "Usage: $0 [--repair]" >&2; exit 64 ;;
esac

CERT_NAME="MacRazer Self-Signed"
# `security default-keychain` prints the path indented and quoted. Strip exactly that —
# deleting every space (an earlier `tr -d ' "'`) mangles any path containing one, which is
# every home directory derived from a full name.
KEYCHAIN="$(security default-keychain | sed -e 's/^[[:space:]]*"//' -e 's/"[[:space:]]*$//')"

# Let codesign use the private key without asking every time.
#
# `security import -T /usr/bin/codesign` below puts codesign on the key's ACL, but since
# macOS 10.12 that is only the first of two gates: the key's *partition list* also has to
# name codesign, and nothing sets that for us. Without it every signing run stops on a GUI
# "codesign wants to use your keychain" prompt — which, in a scripted or CI build with no
# one watching, is indistinguishable from a hang.
#
# Prompts once for the login keychain password. That is the last prompt.
#
# Note `-S` *replaces* the key's partition list rather than adding to it. For an identity this
# script created that list is empty, so nothing is lost; on a key someone else set up with
# extra partitions it would narrow them. There is no way to read the current list back without
# a keychain dump that prompts, so this is the trade — which is part of why it needs --repair.
#
# Returns non-zero on failure so callers can tell.
allow_codesign_access() {
    # Without -k this asks for the keychain password, and with no tty macOS asks with a GUI
    # dialog — so run non-interactively it would block on a prompt nobody can click, which is
    # the exact failure this script exists to remove. Refuse instead of hanging.
    if [ ! -t 0 ]; then
        echo "  ⚠︎ needs an interactive terminal (it asks for your keychain password)." >&2
        echo "    Run './Scripts/setup-signing.sh --repair' by hand." >&2
        return 1
    fi
    echo "▸ Granting codesign access to the key (enter your login keychain password if asked)…"
    if security set-key-partition-list -S apple-tool:,apple:,codesign: -s \
           -l "${CERT_NAME}" "${KEYCHAIN}" >/dev/null; then
        # Deliberately not "you will never be prompted again": this confirms the partition
        # list was written, not that the key it matched is the one codesign reaches for. The
        # next build is the real proof.
        echo "  ✓ partition list updated — the next build should sign without prompting"
        return 0
    fi
    echo "  ⚠︎ couldn't set it automatically. Equivalent manual fix: the next time a build" >&2
    echo "    raises the keychain prompt, click 'Always Allow' rather than 'Allow'." >&2
    return 1
}

if security find-identity -p codesigning 2>/dev/null | grep -q "${CERT_NAME}"; then
    echo "✓ Code-signing identity '${CERT_NAME}' already exists."
    if [ "${REPAIR}" -eq 1 ]; then
        allow_codesign_access   # exit status propagates via the trailing exit below
        exit $?
    fi
    echo "  If builds stop on a 'codesign wants to use your keychain' prompt, run:"
    echo "    ./Scripts/setup-signing.sh --repair"
    exit 0
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/cfg" <<EOF
[req]
distinguished_name = dn
x509_extensions = v3
prompt = no
[dn]
CN = ${CERT_NAME}
[v3]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
EOF

echo "▸ Generating self-signed code-signing certificate…"
openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
    -keyout "$TMP/key.pem" -out "$TMP/cert.pem" -config "$TMP/cfg" >/dev/null 2>&1

# Apple's `security import` only understands the legacy PKCS#12 algorithms. OpenSSL 3.x
# defaults to newer ones whose MAC `security` can't verify ("MAC verification failed"), so
# pass -legacy when the installed openssl supports it. Use a real password too — an empty
# one trips the same MAC bug on some toolchains.
P12PASS="macrazer"
LEGACY=""
if openssl pkcs12 -help 2>&1 | grep -q -- "-legacy"; then LEGACY="-legacy"; fi
openssl pkcs12 -export ${LEGACY} -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
    -out "$TMP/id.p12" -passout "pass:${P12PASS}" -name "${CERT_NAME}" >/dev/null 2>&1

echo "▸ Importing into the login keychain (allow 'codesign' access if prompted)…"
security import "$TMP/id.p12" -P "${P12PASS}" -T /usr/bin/codesign
# Part of creating the identity, so no --repair needed here; a failure is reported but does
# not abort — the identity itself is still usable, just prompt-y.
allow_codesign_access || true

# Best-effort: trust the cert for code signing in the user domain (may prompt once).
security add-trusted-cert -r trustRoot -p codeSign "$TMP/cert.pem" 2>/dev/null || \
    echo "  (trust not set automatically — not required for signing, safe to ignore)"

echo
if security find-identity -p codesigning 2>/dev/null | grep -q "${CERT_NAME}"; then
    echo "✓ Created code-signing identity '${CERT_NAME}'."
    echo "  Next: ./Scripts/build-app.sh  (it will now sign with this identity, unprompted)"
    echo "  Then grant Input Monitoring once — it will persist across future rebuilds."
else
    echo "✗ Could not confirm the identity. Use the Keychain Access GUI method noted at the"
    echo "  top of this script instead."
    exit 1
fi
