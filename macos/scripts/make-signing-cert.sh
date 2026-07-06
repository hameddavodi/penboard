#!/bin/bash
# One-time setup: creates a self-signed code-signing certificate named
# "PenBoard Dev" in the login keychain.
#
# Why (risk R5): an ad-hoc signature (`codesign --sign -`) has no stable
# identity, so every rebuild can produce a different designated requirement
# and macOS treats it as a "new" app for TCC purposes — Bluetooth and
# Accessibility grants would need to be re-approved after every build.
# Signing with a real (even self-signed) certificate gives the app a stable
# identity across rebuilds, so TCC grants persist. build-app.sh automatically
# picks up this certificate once it exists; until then it falls back to
# ad-hoc signing.
#
# NOT executed by the implementer that wrote this file — it prompts
# interactively (keychain password, and macOS "codesign wants to sign using
# your key" access dialogs the first few times codesign uses it). Run it
# yourself, once, from a real Terminal:
#
#   ./scripts/make-signing-cert.sh
#
# Recovery / re-running: if TCC grants are ever lost anyway (identity
# changed, keychain rebuilt, etc.), reset with:
#   tccutil reset Bluetooth it.aisma.penboard.mac
#   tccutil reset Accessibility it.aisma.penboard.mac
set -euo pipefail

IDENTITY_NAME="PenBoard Dev"
KEYCHAIN="${1:-$HOME/Library/Keychains/login.keychain-db}"

if security find-identity -v -p codesigning 2>/dev/null | grep -q "$IDENTITY_NAME"; then
	echo "Certificate \"$IDENTITY_NAME\" already exists in the keychain — nothing to do."
	echo "(To replace it, delete the old one first: Keychain Access.app -> search \"$IDENTITY_NAME\" -> delete both the certificate and its private key.)"
	exit 0
fi

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

KEY_PEM="$WORK_DIR/penboard-dev-key.pem"
CERT_PEM="$WORK_DIR/penboard-dev-cert.pem"
P12_FILE="$WORK_DIR/penboard-dev.p12"

echo "==> generating self-signed code-signing certificate (RSA 2048, 10-year validity)"
openssl req -x509 -newkey rsa:2048 -sha256 -days 3650 -nodes \
	-keyout "$KEY_PEM" -out "$CERT_PEM" \
	-subj "/CN=$IDENTITY_NAME" \
	-addext "extendedKeyUsage=critical,codeSigning" \
	-addext "basicConstraints=critical,CA:false" \
	-addext "keyUsage=critical,digitalSignature"

echo "==> packaging as PKCS#12 for keychain import"
openssl pkcs12 -export \
	-out "$P12_FILE" \
	-inkey "$KEY_PEM" -in "$CERT_PEM" \
	-name "$IDENTITY_NAME" \
	-passout pass:

echo "==> importing into $KEYCHAIN (may prompt for the keychain password)"
security import "$P12_FILE" -k "$KEYCHAIN" -P "" -T /usr/bin/codesign -T /usr/bin/security

echo "==> trusting the certificate for code signing (may show a confirmation dialog)"
security add-trusted-cert -d -r trustAsRoot -p codeSign -k "$KEYCHAIN" "$CERT_PEM"

echo "==> allowing codesign to use the key without re-prompting every time"
echo "    (may prompt for the login keychain password)"
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "" "$KEYCHAIN" >/dev/null 2>&1 || \
	echo "    (skipped automatic partition-list update — if codesign keeps prompting, run:" \
	     "security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k <password> \"$KEYCHAIN\")"

echo "==> done. Verifying:"
security find-identity -v -p codesigning | grep "$IDENTITY_NAME"

echo
echo "Next: ./scripts/build-app.sh will now sign PenBoard.app with \"$IDENTITY_NAME\"."
