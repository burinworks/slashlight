#!/usr/bin/env bash
# Builds build/Slashlight.app (release) and the example extension.
# Usage: scripts/build-app.sh [--install-example]
# Environment: VERSION (default: the VERSION file + "-dev"), CHANNEL (local | pr | test | beta | stable; default local),
# BUILD_NUMBER (default: scripts/build-number.sh), PR_NUMBER (for CHANNEL=pr), UNIVERSAL=1 for an arm64 + x86_64
# binary, SPARKLE_PUBLIC_KEY (EdDSA public key; without it the app never checks for updates), SPARKLE_FEED_URL.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${VERSION:-$(tr -d "[:space:]" < VERSION)-dev}"
CHANNEL="${CHANNEL:-local}"
BUILD_NUMBER="${BUILD_NUMBER:-$(scripts/build-number.sh)}"
COMMIT="$(git rev-parse --short HEAD 2>/dev/null || echo unknown)"
SPARKLE_FEED_URL="${SPARKLE_FEED_URL:-https://burinworks.github.io/slashlight/appcast.xml}"
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
  SPARKLE="${DIRS[0]}/Sparkle.framework" # the xcframework slice is already universal
else
  swift build -c release
  BIN="$(swift build -c release --show-bin-path)"
  cp "$BIN/Slashlight" "$BIN/hello-extension" build/bin/
  SPARKLE="$BIN/Sparkle.framework"
fi
BIN="build/bin"

APP="build/Slashlight.app"
# Each channel is its own app, so you always see which one is running and macOS never mixes up their permissions,
# Keychain items or settings: local builds are "Slashlight Dev", CI builds of test and pull requests are
# "Slashlight Test", beta and stable releases are "Slashlight" (beta updates to stable in place).
case "$CHANNEL" in
  local) BUNDLE_ID="dev.slashlight.app.dev"; DISPLAY_NAME="Slashlight Dev" ;;
  test|pr) BUNDLE_ID="dev.slashlight.app.test"; DISPLAY_NAME="Slashlight Test" ;;
  beta|stable) BUNDLE_ID="dev.slashlight.app"; DISPLAY_NAME="Slashlight" ;;
  *) echo "Unknown CHANNEL: $CHANNEL" >&2; exit 1 ;;
esac
# The executable carries the name too, so Activity Monitor and `ps` show which one is running.
EXECUTABLE="$DISPLAY_NAME"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
cp "$BIN/Slashlight" "$APP/Contents/MacOS/$EXECUTABLE"
ditto "$SPARKLE" "$APP/Contents/Frameworks/Sparkle.framework"
install_name_tool -add_rpath @executable_path/../Frameworks "$APP/Contents/MacOS/$EXECUTABLE"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>${BUNDLE_ID}</string>
  <key>CFBundleName</key><string>${DISPLAY_NAME}</string>
  <key>CFBundleDisplayName</key><string>${DISPLAY_NAME}</string>
  <key>CFBundleExecutable</key><string>${EXECUTABLE}</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleShortVersionString</key><string>${VERSION%%-*}</string>
  <key>CFBundleVersion</key><string>${BUILD_NUMBER}</string>
  <key>SlashlightChannel</key><string>${CHANNEL}</string>
  <key>SlashlightCommit</key><string>${COMMIT}</string>
  <key>SlashlightPullRequest</key><string>${PR_NUMBER:-}</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSAppleEventsUsageDescription</key><string>Slashlight runs your commands in Terminal and your AppleScript commands.</string>
  <key>SUFeedURL</key><string>${SPARKLE_FEED_URL}</string>
  <key>SUPublicEDKey</key><string>${SPARKLE_PUBLIC_KEY:-}</string>
  <key>SUEnableAutomaticChecks</key><true/>
</dict>
</plist>
PLIST

# A stable identity keeps macOS permission grants across rebuilds and updates. Releases use "Slashlight"
# (scripts/release-signing-identity.sh, imported in CI); local builds use "Slashlight Dev" (scripts/dev-signing-identity.sh).
IDENTITY="${SIGNING_IDENTITY:-Slashlight Dev}"
if security find-identity -p codesigning 2>/dev/null | grep -q "\"$IDENTITY\""; then
  codesign --force --deep --sign "$IDENTITY" "$APP"
  echo "Signed with \"$IDENTITY\""
else
  codesign --force --deep --sign - "$APP"
  echo "Note: ad-hoc signed. Run scripts/dev-signing-identity.sh once so permissions survive rebuilds."
fi
echo "Built $APP: $DISPLAY_NAME $VERSION, $CHANNEL build $BUILD_NUMBER ($COMMIT)"

if [[ "${1:-}" == "--install-example" ]]; then
  DEST="$HOME/Library/Application Support/$DISPLAY_NAME/Extensions/hello"
  mkdir -p "$DEST"
  cp "$BIN/hello-extension" "$DEST/hello-extension"
  cp Examples/HelloExtension/manifest.json "$DEST/manifest.json"
  echo "Installed example extension to $DEST"
fi
