#!/usr/bin/env bash
# Writes Resources/ThirdPartyNotices.txt from the licenses of what ships inside Slashlight.app (SwiftTerm, linked
# into the binary, and Sparkle.framework). Run after `swift package resolve` when a dependency changes.
set -euo pipefail
cd "$(dirname "$0")/.."
SWIFTTERM=.build/checkouts/SwiftTerm/LICENSE
SPARKLE=.build/checkouts/Sparkle/LICENSE
[[ -f "$SWIFTTERM" && -f "$SPARKLE" ]] || swift package resolve >/dev/null
{
  cat <<'HEAD'
Slashlight — Third-Party Notices

Slashlight is © 2026 Alexander Ikonnikov and released under the MIT License (see LICENSE).
It includes the software below. Each part is used under the license reproduced here.

Slashlight is not affiliated with Raycast Technologies Ltd or Apple Inc. Raycast is a trademark of
Raycast Technologies Ltd. Apple, macOS and Spotlight are trademarks of Apple Inc.

Currency rates: Rates By Exchange Rate API (https://www.exchangerate-api.com), fetched from
open.er-api.com when you convert currencies and cached on this Mac only.

HEAD
  printf '%s\n' "================================================================================" \
    "SwiftTerm — https://github.com/migueldeicaza/SwiftTerm (MIT License)" \
    "================================================================================" ""
  cat "$SWIFTTERM"
  printf '\n%s\n' "================================================================================" \
    "Sparkle — https://sparkle-project.org (MIT License; includes bsdiff, sais-lite and ed25519)" \
    "================================================================================" ""
  cat "$SPARKLE"
} > Resources/ThirdPartyNotices.txt
echo "Wrote Resources/ThirdPartyNotices.txt"
