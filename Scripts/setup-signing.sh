#!/usr/bin/env bash
# One-time: create a stable self-signed code-signing identity so the Input Monitoring
# grant persists across rebuilds (and across app updates shipped to other users).
#
# After running this, every ./Scripts/build-app.sh will sign with this identity, giving
# the app a constant code identity — so you grant Input Monitoring once, not every build.
#
#   ./Scripts/setup-signing.sh
#
# If this scripted path gives you trouble, the GUI alternative is just as good:
#   Keychain Access → Certificate Assistant → Create a Certificate…
#     Name: "MacRazer Self-Signed"   Identity Type: Self-Signed Root
#     Certificate Type: Code Signing    → Create
set -euo pipefail

CERT_NAME="MacRazer Self-Signed"
KEYCHAIN="$(security default-keychain | tr -d ' "')"

if security find-identity -p codesigning 2>/dev/null | grep -q "${CERT_NAME}"; then
    echo "✓ Code-signing identity '${CERT_NAME}' already exists. Nothing to do."
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
openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
    -out "$TMP/id.p12" -passout pass: -name "${CERT_NAME}" >/dev/null 2>&1

echo "▸ Importing into the login keychain (allow 'codesign' access if prompted)…"
security import "$TMP/id.p12" -P "" -T /usr/bin/codesign

# Best-effort: trust the cert for code signing in the user domain (may prompt once).
security add-trusted-cert -r trustRoot -p codeSign "$TMP/cert.pem" 2>/dev/null || \
    echo "  (trust not set automatically — not required for signing, safe to ignore)"

echo
if security find-identity -p codesigning 2>/dev/null | grep -q "${CERT_NAME}"; then
    echo "✓ Created code-signing identity '${CERT_NAME}'."
    echo "  Next: ./Scripts/build-app.sh  (it will now sign with this identity)"
    echo "  Then grant Input Monitoring once — it will persist across future rebuilds."
else
    echo "✗ Could not confirm the identity. Use the Keychain Access GUI method noted at the"
    echo "  top of this script instead."
    exit 1
fi
