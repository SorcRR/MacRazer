#!/usr/bin/env bash
# One-time: create a stable self-signed code-signing identity so the Input Monitoring
# grant persists across rebuilds (and across app updates shipped to other users).
#
# After running this, every ./Scripts/build-app.sh will sign with this identity, giving
# the app a constant code identity — so you grant Input Monitoring once, not every build.
#
#   ./Scripts/setup-signing.sh
#
# Safe to re-run: if the identity already exists this only re-applies the keychain access
# grant below, which is the fix when builds start stopping on a "codesign wants to use your
# keychain" prompt.
#
# If this scripted path gives you trouble, the GUI alternative is just as good:
#   Keychain Access → Certificate Assistant → Create a Certificate…
#     Name: "MacRazer Self-Signed"   Identity Type: Self-Signed Root
#     Certificate Type: Code Signing    → Create
set -euo pipefail

CERT_NAME="MacRazer Self-Signed"
KEYCHAIN="$(security default-keychain | tr -d ' "')"

# Let codesign use the private key without asking every time.
#
# `security import -T /usr/bin/codesign` below puts codesign on the key's ACL, but since
# macOS 10.12 that is only the first of two gates: the key's *partition list* also has to
# name codesign, and nothing sets that for us. Without it every signing run stops on a GUI
# "codesign wants to use your keychain" prompt — which, in a scripted or CI build with no
# one watching, is indistinguishable from a hang.
#
# Prompts once for the login keychain password. That is the last prompt.
allow_codesign_access() {
    echo "▸ Granting codesign access to the key (enter your login keychain password if asked)…"
    if security set-key-partition-list -S apple-tool:,apple:,codesign: -s \
           -l "${CERT_NAME}" "${KEYCHAIN}" >/dev/null; then
        echo "  ✓ builds will no longer stop on a keychain prompt"
    else
        echo "  ⚠︎ couldn't set it automatically. Equivalent manual fix: the next time a build"
        echo "    raises the keychain prompt, click 'Always Allow' rather than 'Allow'."
    fi
}

if security find-identity -p codesigning 2>/dev/null | grep -q "${CERT_NAME}"; then
    echo "✓ Code-signing identity '${CERT_NAME}' already exists."
    allow_codesign_access
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
allow_codesign_access

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
