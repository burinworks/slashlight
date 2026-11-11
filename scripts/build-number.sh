#!/usr/bin/env bash
# Prints the build number of HEAD: every pull request merged into test adds one. It is the length of test's
# first-parent history up to the newest test commit that HEAD contains, so a beta or stable release promoted
# from test keeps that test build's number, and a pull request build shows the number of the test it is based on.
# Needs the test branch (origin/test, or a local test); without it, counts HEAD's own first-parent history.
set -euo pipefail
cd "$(dirname "$0")/.."
REF=""
for r in origin/test test; do git rev-parse -q --verify "$r^{commit}" >/dev/null && { REF="$r"; break; }; done
if [[ -z "$REF" ]]; then git rev-list --count --first-parent HEAD 2>/dev/null || echo 0; exit 0; fi
for c in $(git rev-list --first-parent "$REF"); do
  if git merge-base --is-ancestor "$c" HEAD; then git rev-list --count --first-parent "$c"; exit 0; fi
done
echo 0
