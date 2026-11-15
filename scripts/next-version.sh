#!/usr/bin/env bash
# Prints the tag the next release on a channel gets, or nothing when there is nothing new to release.
#
#   scripts/next-version.sh beta     → vCORE.STABLE.(MINOR+1)   e.g. v0.4.1, v0.4.2…
#   scripts/next-version.sh stable   → vCORE.(STABLE+1).0       e.g. v0.5.0
#
# Versions are CORE.STABLE.MINOR: every promotion to beta adds one to MINOR, every promotion to main adds one to
# STABLE and starts MINOR over at 0, so a stable release always ends in .0 and a beta never does. CORE (and a
# STABLE jump) come from the VERSION file: the next release is never lower than it, and a VERSION nobody has
# released yet (1.0.0, say) is what the next stable release is called. Older tags with a hyphen
# (v0.4.0-beta.1) are ignored.
set -euo pipefail
CHANNEL="${1:?usage: next-version.sh beta|stable}"

IFS=. read -r FX FY _ <<<"$(tr -d '[:space:]' < VERSION)"
FLOOR="$FX.$FY.0"
tags() { git tag -l 'v*' | sed -n 's/^v\([0-9]*\.[0-9]*\.[0-9]*\)$/\1/p' | sort -V; }
LATEST="$(tags | tail -1)"
LATEST_STABLE="$(tags | grep '\.0$' | tail -1 || true)"
BASE="$(printf '%s\n%s\n' "${LATEST:-0.0.0}" "$FLOOR" | sort -V | tail -1)"
IFS=. read -r X Y Z <<<"$BASE"

unchanged() { [[ -n "$1" ]] && git diff --quiet "v$1" HEAD; }

case "$CHANNEL" in
  beta)
    if unchanged "$LATEST"; then echo "::notice::Nothing changed since v$LATEST." >&2; exit 0; fi
    echo "v$X.$Y.$((Z + 1))"
    ;;
  stable)
    if unchanged "$LATEST_STABLE"; then echo "::notice::Nothing changed since v$LATEST_STABLE." >&2; exit 0; fi
    if [[ "$BASE" == "$FLOOR" ]] && ! git rev-parse -q --verify "refs/tags/v$FLOOR" >/dev/null; then
      echo "v$FLOOR"
    else
      echo "v$X.$((Y + 1)).0"
    fi
    ;;
  *) echo "usage: next-version.sh beta|stable" >&2; exit 2 ;;
esac
