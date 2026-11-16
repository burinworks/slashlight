#!/usr/bin/env bash
# Runs the app on its own, with nobody at the keyboard, to check the panel and the Settings window.
#
#   scripts/dev-suite.sh                    build, then the standard checks
#   scripts/dev-suite.sh query "his"        the main search for "his": rows printed, panel saved as a PNG
#   scripts/dev-suite.sh open clipboard     an extension's screen
#   scripts/dev-suite.sh settings Hotkeys   a Settings tab as a PNG (General, Hotkeys, Extensions, Permissions, About)
#
# Each run uses a fresh folder (SLASHLIGHT_ISOLATED_HOME, see Sources/Slashlight/Host/DevSuite.swift): no settings,
# history or extensions of yours, no Keychain (so no password prompt), no global hotkeys, menu bar icon, Dock icon,
# update checks or welcome tour. The build is signed ad hoc, so codesign never asks for the keychain either.
#
# Environment: OUT (where PNGs go; default build/dev-suite), NO_BUILD=1 to reuse build/Slashlight.app,
# DARK=1 for dark mode, DELAY (seconds before the capture; default 2), TIMEOUT (seconds per run; default 40).
set -euo pipefail
cd "$(dirname "$0")/.."

OUT="${OUT:-build/dev-suite}"
DELAY="${DELAY:-2}"
TIMEOUT="${TIMEOUT:-40}"
APP="build/Slashlight.app"
mkdir -p "$OUT"

if [[ "${NO_BUILD:-}" != 1 ]]; then
  SIGNING_IDENTITY=- scripts/build-app.sh >/dev/null 2>&1
fi
EXE="$APP/Contents/MacOS/$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$APP/Contents/Info.plist")"

# One isolated run of the app; prints what it printed. Never waits longer than TIMEOUT.
run() {
  local home
  home="$(mktemp -d "${TMPDIR:-/tmp}/slashlight-suite.XXXXXX")"
  local extra=()
  [[ "${DARK:-}" == 1 ]] && extra+=(--dark)
  SLASHLIGHT_ISOLATED_HOME="$home" perl -e 'alarm shift; exec @ARGV' "$TIMEOUT" "$EXE" "$@" ${extra[@]+"${extra[@]}"} 2>/dev/null \
    || { local code=$?; [[ $code == 142 ]] && echo "!! timed out after ${TIMEOUT}s: $*" >&2; return "$code"; }
  rm -rf "$home"
}

slug() { tr -cs '[:alnum:]' '-' <<<"$1" | sed 's/^-//; s/-$//'; }

query() {
  local q="$1" png
  png="$OUT/query-$(slug "$q").png"
  echo "── search \"$q\" → $png"
  run --dump --snapshot "$png" --query "$q" --delay "$DELAY"
}

open_ext() {
  local id="$1" png
  png="$OUT/open-$(slug "$id").png"
  echo "── open $id → $png"
  run --dump --snapshot "$png" --open "$id" --delay "$DELAY"
}

settings() {
  local tab="$1" png
  png="$OUT/settings-$(slug "$tab").png"
  echo "── Settings → $tab → $png"
  run --settings --tab "$tab" --snapshot-settings "$png"
}

case "${1:-all}" in
  query) query "${2:?query text}" ;;
  open) open_ext "${2:?extension id}" ;;
  settings) settings "${2:?tab name}" ;;
  all)
    query "his"
    query "settings"
    query "saf"
    query "2+2"
    open_ext clipboard
    for tab in General Hotkeys Extensions Permissions About; do settings "$tab"; done
    ;;
  *) sed -n '2,13p' "$0"; exit 2 ;;
esac
