#!/usr/bin/env bash
# CI: puts the release code-signing identity into a temporary keychain so scripts/build-app.sh can use it.
# Reads SIGNING_P12 (base64 .p12) and SIGNING_P12_PASSWORD; writes SIGNING_IDENTITY to $GITHUB_ENV.
# Without the secret (forks, first setup) the build stays ad-hoc signed and says so.
set -euo pipefail
NAME="Slashlight"
if [[ -z "${SIGNING_P12:-}" ]]; then
  echo "::warning::No SIGNING_P12 secret: this build is ad-hoc signed, so macOS asks for permissions again after updating. Run scripts/release-signing-identity.sh once."
  exit 0
fi
KEYCHAIN="$RUNNER_TEMP/signing.keychain-db"
PASS=$(uuidgen)
P12="$RUNNER_TEMP/signing.p12"
(umask 077 && printf '%s' "$SIGNING_P12" | base64 --decode > "$P12")
security create-keychain -p "$PASS" "$KEYCHAIN"
security set-keychain-settings -lut 3600 "$KEYCHAIN"
security unlock-keychain -p "$PASS" "$KEYCHAIN"
security import "$P12" -k "$KEYCHAIN" -P "${SIGNING_P12_PASSWORD:-}" -T /usr/bin/codesign >/dev/null
security set-key-partition-list -S apple-tool:,apple: -s -k "$PASS" "$KEYCHAIN" >/dev/null
security list-keychains -d user -s "$KEYCHAIN" $(security list-keychains -d user | tr -d '"')
rm -f "$P12"
echo "SIGNING_IDENTITY=$NAME" >> "$GITHUB_ENV"
echo "Signing with \"$NAME\""
