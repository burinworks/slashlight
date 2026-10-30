#!/usr/bin/env bash
# Packs build/Slashlight.app into a drag-to-Applications disk image.
# Usage: scripts/make-dmg.sh [output.dmg]   (default: build/Slashlight.dmg). Run scripts/build-app.sh first.
set -euo pipefail
cd "$(dirname "$0")/.."

APP="build/Slashlight.app"
OUT="${1:-build/Slashlight.dmg}"
VOLUME="Slashlight"
[[ -d "$APP" ]] || { echo "Missing $APP; run scripts/build-app.sh first" >&2; exit 1; }

WORK="$(mktemp -d)"
MOUNT="/Volumes/$VOLUME"
cleanup() {
  [[ -d "$MOUNT" ]] && hdiutil detach "$MOUNT" -quiet -force || true
  rm -rf "$WORK"
}
trap cleanup EXIT
[[ -d "$MOUNT" ]] && hdiutil detach "$MOUNT" -quiet -force

# Contents: the app, a link to /Applications, and the hidden background picture.
mkdir -p "$WORK/stage/.background"
ditto "$APP" "$WORK/stage/Slashlight.app"
ln -s /Applications "$WORK/stage/Applications"
cp scripts/dmg/background.tiff "$WORK/stage/.background/background.tiff"

hdiutil create -quiet -volname "$VOLUME" -srcfolder "$WORK/stage" -fs HFS+ -format UDRW -ov "$WORK/rw.dmg"
hdiutil attach -quiet -readwrite -noverify -noautoopen "$WORK/rw.dmg"

# Window layout: Finder stores it in the volume's .DS_Store. The arrow in the background sits between the two icons.
osascript <<OSA || echo "warning: could not set the window layout (Finder automation unavailable); the image still works" >&2
tell application "Finder"
  tell disk "$VOLUME"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set the bounds of container window to {200, 120, 860, 548}
    set viewOptions to the icon view options of container window
    set arrangement of viewOptions to not arranged
    set icon size of viewOptions to 112
    set text size of viewOptions to 13
    set background picture of viewOptions to file ".background:background.tiff"
    set position of item "Slashlight.app" of container window to {170, 190}
    set position of item "Applications" of container window to {490, 190}
    -- Finder only persists the layout reliably after a close and reopen.
    close
    open
    update without registering applications
    delay 2
    close
  end tell
end tell
OSA

chmod -Rf go-w "$MOUNT" || true
sync
hdiutil detach "$MOUNT" -quiet
mkdir -p "$(dirname "$OUT")"
hdiutil convert -quiet "$WORK/rw.dmg" -format UDZO -imagekey zlib-level=9 -ov -o "$OUT"
echo "Built $OUT"
