#!/bin/bash
# Resolve a requested numeric app tag, optionally requiring a previously
# validated commit. Every release workflow stage uses the same check.
set -euo pipefail
cd "$(dirname "$0")/.."
fail() { echo "Release refused: $*" >&2; exit 1; }
TAG="${1:?usage: Scripts/validate-release-tag.sh vX.Y.Z [expected-commit]}"
EXPECTED_COMMIT="${2:-}"
[[ $# -le 2 ]] || fail "unexpected arguments"
VERSION="$(plutil -extract CFBundleShortVersionString raw Support/Info.plist)"
[[ "$TAG" == "v$VERSION" ]] || fail "requested tag must match the application version v$VERSION"
COMMIT="$(Scripts/release-preflight.sh "$VERSION")" || exit $?
if [ -n "$EXPECTED_COMMIT" ]; then
  [[ "$COMMIT" == "$EXPECTED_COMMIT" ]] || fail "requested tag moved after validation"
fi
printf '%s\n' "$COMMIT"
