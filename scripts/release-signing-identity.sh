#!/usr/bin/env bash
# Run once: creates the self-signed "Slashlight" code-signing certificate that every release is signed with,
# and stores it as the SIGNING_P12 / SIGNING_P12_PASSWORD repository secrets.
#
# Why: macOS remembers Accessibility and Screen Recording grants per signing identity. Ad-hoc builds have a
# new identity every build, so each update looked like a new app. With one certificate, grants survive updates.
# It is not an Apple Developer ID: Gatekeeper still asks on first open, exactly as before.
#
# Keep the printed backup somewhere safe (a password manager). Losing it means users grant permissions once more.
set -euo pipefail
REPO="${1:-burinworks/slashlight}"
NAME="Slashlight"
OPENSSL=$(command -v /opt/homebrew/bin/openssl || command -v openssl)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
cat > "$TMP/cert.cnf" <<CNF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $NAME
[ext]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
CNF
"$OPENSSL" req -x509 -newkey rsa:3072 -nodes -days 7300 -config "$TMP/cert.cnf" \
  -keyout "$TMP/key.pem" -out "$TMP/cert.pem" 2>/dev/null
PASS=$("$OPENSSL" rand -hex 24)
"$OPENSSL" pkcs12 -export -legacy -inkey "$TMP/key.pem" -in "$TMP/cert.pem" -name "$NAME" \
  -out "$TMP/id.p12" -passout "pass:$PASS" 2>/dev/null
base64 -i "$TMP/id.p12" | gh secret set SIGNING_P12 --repo "$REPO"
printf '%s' "$PASS" | gh secret set SIGNING_P12_PASSWORD --repo "$REPO"
BACKUP="$HOME/Desktop/slashlight-signing-backup.p12"
cp "$TMP/id.p12" "$BACKUP"
(umask 077 && printf '%s\n' "$PASS" > "$BACKUP.password.txt")
echo "Set SIGNING_P12 and SIGNING_P12_PASSWORD on $REPO."
echo "Backup: $BACKUP and its password in $BACKUP.password.txt."
echo "Move both into your password manager, then delete the files."
