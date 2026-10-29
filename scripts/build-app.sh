#!/usr/bin/env bash
# Builds build/My Spotlight.app (release, ad-hoc signed) and the example extension.
# Usage: scripts/build-app.sh [--install-example]
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release
BIN="$(swift build -c release --show-bin-path)"

APP="build/My Spotlight.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/MySpotlight" "$APP/Contents/MacOS/MySpotlight"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>dev.myspotlight.app</string>
  <key>CFBundleName</key><string>My Spotlight</string>
  <key>CFBundleDisplayName</key><string>My Spotlight</string>
  <key>CFBundleExecutable</key><string>MySpotlight</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSAppleEventsUsageDescription</key><string>My Spotlight runs your commands in Terminal and your AppleScript commands.</string>
</dict>
</plist>
PLIST

codesign --force --deep --sign - "$APP"
echo "Built $APP"

if [[ "${1:-}" == "--install-example" ]]; then
  DEST="$HOME/Library/Application Support/MySpotlight/Extensions/hello"
  mkdir -p "$DEST"
  cp "$BIN/hello-extension" "$DEST/hello-extension"
  cp Examples/HelloExtension/manifest.json "$DEST/manifest.json"
  echo "Installed example extension to $DEST"
fi
