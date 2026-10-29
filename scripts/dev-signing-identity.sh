#!/usr/bin/env bash
# Creates a self-signed "Slashlight Dev" code-signing identity in your login keychain (run once).
# Ad-hoc signatures change on every build, so macOS forgets the Accessibility and Screen Recording
# grants after each rebuild. With a stable identity, scripts/build-app.sh signs every build the same
# way and the grants survive rebuilds.
set -euo pipefail
NAME="Slashlight Dev"
if security find-identity -p codesigning | grep -q "\"$NAME\""; then
  echo "\"$NAME\" already exists"
  exit 0
fi

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
"$OPENSSL" req -x509 -newkey rsa:2048 -nodes -days 3650 -config "$TMP/cert.cnf" \
  -keyout "$TMP/key.pem" -out "$TMP/cert.pem" 2>/dev/null
"$OPENSSL" pkcs12 -export -legacy -inkey "$TMP/key.pem" -in "$TMP/cert.pem" -name "$NAME" \
  -out "$TMP/id.p12" -passout pass:slashlight 2>/dev/null
security import "$TMP/id.p12" -k "$HOME/Library/Keychains/login.keychain-db" -P slashlight -T /usr/bin/codesign >/dev/null
echo "Created code-signing identity \"$NAME\". Rebuild with scripts/build-app.sh, then grant permissions once more."
