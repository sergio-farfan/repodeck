#!/bin/bash
# Runs only against temporary local repositories; never publishes or signs.
set -euo pipefail
SOURCE="$(cd "$(dirname "$0")/../.." && pwd)"
FIXTURE="$(mktemp -d)"
trap 'rm -rf "$FIXTURE"' EXIT
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_CONFIG_COUNT GIT_CONFIG_PARAMETERS GIT_TEMPLATE_DIR
mkdir -p "$FIXTURE/work/Scripts" "$FIXTURE/work/Support"
cp "$SOURCE/Scripts/release-preflight.sh" "$FIXTURE/work/Scripts/"
cp "$SOURCE/Scripts/validate-release-tag.sh" "$FIXTURE/work/Scripts/"
cp "$SOURCE/Support/Info.plist" "$FIXTURE/work/Support/"
plutil -replace CFBundleShortVersionString -string 1.2.3 "$FIXTURE/work/Support/Info.plist"
cd "$FIXTURE/work"
git init -q -b main
git config user.name "Release tests"
git config user.email "tests@example.invalid"
git config commit.gpgsign false
git init -q --bare "$FIXTURE/origin.git"
git remote add origin "$FIXTURE/origin.git"
git add Scripts Support
git commit -qm "fixture"
refuse() {
  if Scripts/release-preflight.sh 1.2.3 >"$FIXTURE/output" 2>&1; then
    echo "Expected rejection: $1" >&2
    exit 1
  fi
}
refuse "missing tag"
git tag -a v1.2.3 -m "fixture"
refuse "tag not on remote"
git push -q origin refs/tags/v1.2.3
[[ "$(Scripts/release-preflight.sh 1.2.3)" == "$(git rev-parse HEAD)" ]] || { echo 'Incorrect source commit' >&2; exit 1; }
VALIDATED_COMMIT="$(Scripts/validate-release-tag.sh v1.2.3)"
[[ "$(Scripts/validate-release-tag.sh v1.2.3 "$VALIDATED_COMMIT")" == "$VALIDATED_COMMIT" ]] || { echo 'Pinned source was not preserved' >&2; exit 1; }
if Scripts/validate-release-tag.sh v9.9.9 >"$FIXTURE/output" 2>&1; then
  echo "A mismatched requested application tag was accepted" >&2
  exit 1
fi
if Scripts/validate-release-tag.sh v1.2.3 0000000000000000000000000000000000000000 >"$FIXTURE/output" 2>&1; then
  echo "An unvalidated source commit was accepted" >&2
  exit 1
fi
printf dirty > untracked
refuse "untracked files"
git add untracked
refuse "staged files"
git commit -qm "new version"
refuse "checkout differs from tag"
git tag -f v1.2.3 >/dev/null
refuse "local and remote tags differ"
git push -q --force origin refs/tags/v1.2.3
if Scripts/validate-release-tag.sh v1.2.3 "$VALIDATED_COMMIT" >"$FIXTURE/output" 2>&1; then
  echo "Moving both tags after validation was accepted" >&2
  exit 1
fi
[[ "$(Scripts/validate-release-tag.sh v1.2.3)" == "$(git rev-parse HEAD)" ]] || { echo 'Incorrect resolved source' >&2; exit 1; }
printf 'Release preflight checks passed.\n'
