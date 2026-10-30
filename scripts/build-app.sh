#!/usr/bin/env bash
# Builds build/Slashlight.app (release) and the example extension.
# Usage: scripts/build-app.sh [--install-example]
# Environment: VERSION (default 0.0.0-dev), BUILD_NUMBER, UNIVERSAL=1 for an arm64 + x86_64 binary.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${VERSION:-0.0.0-dev}"
# Products end up in build/bin. A universal build compiles each architecture separately and merges them with lipo
# (`swift build --arch a --arch b` goes through Xcode's build system, which cannot resolve SwiftTerm's build plugin).
mkdir -p build/bin
if [[ "${UNIVERSAL:-}" == "1" ]]; then
  DIRS=()
  for ARCH in arm64 x86_64; do
    swift build -c release --triple "$ARCH-apple-macosx14.0"
    DIRS+=("$(swift build -c release --triple "$ARCH-apple-macosx14.0" --show-bin-path)")
  done
  for PRODUCT in Slashlight hello-extension; do
    lipo -create "${DIRS[0]}/$PRODUCT" "${DIRS[1]}/$PRODUCT" -output "build/bin/$PRODUCT"
  done
else
  swift build -c release
  BIN="$(swift build -c release --show-bin-path)"
  cp "$BIN/Slashlight" "$BIN/hello-extension" build/bin/
fi
BIN="build/bin"

APP="build/Slashlight.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/Slashlight" "$APP/Contents/MacOS/Slashlight"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>dev.slashlight.app</string>
  <key>CFBundleName</key><string>Slashlight</string>
  <key>CFBundleDisplayName</key><string>Slashlight</string>
  <key>CFBundleExecutable</key><string>Slashlight</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${VERSION%%-*}</string>
  <key>CFBundleVersion</key><string>${BUILD_NUMBER:-1}</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSAppleEventsUsageDescription</key><string>Slashlight runs your commands in Terminal and your AppleScript commands.</string>
</dict>
</plist>
PLIST

# A stable identity keeps macOS permission grants across rebuilds; see scripts/dev-signing-identity.sh.
if security find-identity -p codesigning 2>/dev/null | grep -q '"Slashlight Dev"'; then
  codesign --force --deep --sign "Slashlight Dev" "$APP"
else
  codesign --force --deep --sign - "$APP"
  echo "Note: ad-hoc signed. Run scripts/dev-signing-identity.sh once so permissions survive rebuilds."
fi
echo "Built $APP"

if [[ "${1:-}" == "--install-example" ]]; then
  DEST="$HOME/Library/Application Support/Slashlight/Extensions/hello"
  mkdir -p "$DEST"
  cp "$BIN/hello-extension" "$DEST/hello-extension"
  cp Examples/HelloExtension/manifest.json "$DEST/manifest.json"
  echo "Installed example extension to $DEST"
fi
