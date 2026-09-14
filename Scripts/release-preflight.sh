#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
fail() { echo "Release refused: $*" >&2; exit 1; }
VERSION="${1:-$(plutil -extract CFBundleShortVersionString raw Support/Info.plist)}"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "version must be X.Y.Z"
TAG="v$VERSION"
[[ -z "$(git status --porcelain --untracked-files=normal)" ]] || fail "commit or remove all uncommitted files before releasing"
HEAD_COMMIT="$(git rev-parse HEAD)"
TAG_COMMIT="$(git rev-parse --verify "refs/tags/$TAG^{commit}" 2>/dev/null)" || fail "create and push $TAG first"
[[ "$TAG_COMMIT" == "$HEAD_COMMIT" ]] || fail "$TAG does not identify the current checkout"
REMOTE_TAGS="$(git ls-remote --exit-code origin "refs/tags/$TAG" "refs/tags/$TAG^{}")" || fail "$TAG must already exist on origin"
REMOTE_COMMIT="$(printf '%s\n' "$REMOTE_TAGS" | awk -v tag="refs/tags/$TAG" '$2 == tag { direct=$1 } $2 == tag "^{}" { peeled=$1 } END { print peeled ? peeled : direct }')"
[[ "$REMOTE_COMMIT" == "$HEAD_COMMIT" ]] || fail "origin/$TAG differs from the current checkout"
printf '%s\n' "$HEAD_COMMIT"
