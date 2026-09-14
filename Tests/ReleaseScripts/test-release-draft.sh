#!/bin/bash
# Exercise the complete draft command with local Git and fake packaging/hosting
# tools. This never builds Swift, signs, mounts an image, or contacts GitHub.
set -euo pipefail
SOURCE="$(cd "$(dirname "$0")/../.." && pwd)"
FIXTURE="$(mktemp -d)"
trap 'rm -rf "$FIXTURE"' EXIT
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
export SIGN_IDENTITY='' NOTARY_PROFILE=''
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_CONFIG_COUNT GIT_CONFIG_PARAMETERS GIT_TEMPLATE_DIR
mkdir -p "$FIXTURE/work/Scripts" "$FIXTURE/work/Support" "$FIXTURE/work/Sources/RepoDeck/Resources" "$FIXTURE/bin"
cp "$SOURCE/Scripts/make-dmg.sh" "$SOURCE/Scripts/release-preflight.sh" "$SOURCE/Scripts/validate-release-tag.sh" "$SOURCE/Scripts/changelog-section.sh" "$FIXTURE/work/Scripts/"
cp "$SOURCE/Support/Info.plist" "$FIXTURE/work/Support/"
plutil -replace CFBundleShortVersionString -string 1.2.3 "$FIXTURE/work/Support/Info.plist"
printf '## [1.2.3]\n\nFixture release notes.\n' > "$FIXTURE/work/CHANGELOG.md"
printf 'dist/\n' > "$FIXTURE/work/.gitignore"
: > "$FIXTURE/work/Sources/RepoDeck/Resources/AppIcon.icns"
export FAKE_ARGS="$FIXTURE/gh-args" FAKE_NOTES="$FIXTURE/notes" FAKE_BUNDLE_LOG="$FIXTURE/bundle-log"
export FAKE_ORIGIN="$FIXTURE/origin.git"
cat > "$FIXTURE/work/Scripts/bundle.sh" <<'SH'
#!/bin/bash
set -euo pipefail
printf 'build\n' >> "$FAKE_BUNDLE_LOG"
mkdir -p dist/RepoDeck.app/Contents/MacOS
: > dist/RepoDeck.app/Contents/MacOS/RepoDeck
if [ -n "${FAKE_FUTURE_COMMIT:-}" ]; then
  git --git-dir "$FAKE_ORIGIN" update-ref refs/tags/v1.2.3 "$FAKE_FUTURE_COMMIT"
fi
SH
cat > "$FIXTURE/bin/gh" <<'SH'
#!/bin/bash
set -euo pipefail
case "$1 $2" in
  'release view') [[ "${FAKE_RELEASE_EXISTS:-0}" = 1 ]] ;;
  'release create')
    printf '%s\0' "$@" > "$FAKE_ARGS"
    previous=""
    for argument in "$@"; do
      if [ "$previous" = --notes-file ]; then cp "$argument" "$FAKE_NOTES"; fi
      previous="$argument"
    done
    ;;
  *) echo "Unexpected GitHub command" >&2; exit 1 ;;
esac
SH
cat > "$FIXTURE/bin/swift" <<'SH'
#!/bin/bash
set -euo pipefail
if [ "$1" = --version ]; then echo 'Fixture Swift toolchain'; exit; fi
for argument in "$@"; do output="$argument"; done
: > "$output"
SH
cat > "$FIXTURE/bin/hdiutil" <<'SH'
#!/bin/bash
set -euo pipefail
for argument in "$@"; do output="$argument"; done
case "$1" in
  create) : > "$output" ;;
  attach) printf '/dev/fixture\tApple_HFS\t/Volumes/RepoDeck fixture\n' ;;
  detach) ;;
  convert) printf 'Fixture disk image\n' > "$output" ;;
  verify) test -f "$2" ;;
  *) echo "Unexpected disk-image command" >&2; exit 1 ;;
esac
SH
for command in sips osascript SetFile; do
  printf '#!/bin/bash\nexit 0\n' > "$FIXTURE/bin/$command"
done
cat > "$FIXTURE/bin/sleep" <<'SH'
#!/bin/bash
# Keep the layout watchdog alive until its fake AppleScript exits.
if [ "$1" = 45 ]; then exec /bin/sleep 1; fi
SH
chmod +x "$FIXTURE/bin/"* "$FIXTURE/work/Scripts/"*.sh
export PATH="$FIXTURE/bin:$PATH"
cd "$FIXTURE/work"
git init -q -b main
git config user.name 'Release tests'
git config user.email tests@example.invalid
git config commit.gpgsign false
git init -q --bare "$FAKE_ORIGIN"
git remote add origin "$FAKE_ORIGIN"
git add .
git commit -qm fixture
git tag -a v1.2.3 -m fixture
git push -q origin refs/tags/v1.2.3
fail() { echo "$*" >&2; cat "$FIXTURE/output" >&2; exit 1; }
run() {
  Scripts/make-dmg.sh "$@" > "$FIXTURE/output" 2>&1 || fail 'Draft packaging failed'
}
refuse() {
  if Scripts/make-dmg.sh "$@" > "$FIXTURE/output" 2>&1; then fail 'Unsafe release command was accepted'; fi
}
has_argument() {
  local argument
  while IFS= read -r -d '' argument; do
    if [ "$argument" = "$1" ]; then return 0; fi
  done < "$FAKE_ARGS"
  return 1
}
refuse --prerelease
refuse --release --unknown
[[ ! -e "$FAKE_BUNDLE_LOG" && ! -e "$FAKE_ARGS" ]] || fail 'Invalid options reached packaging'
run --release
for argument in release create v1.2.3 --verify-tag --draft --repo "$FAKE_ORIGIN"; do
  has_argument "$argument" || fail "Missing draft argument: $argument"
done
if has_argument --prerelease; then fail 'Stable draft unexpectedly marked prerelease'; fi
cmp dist/RepoDeck-1.2.3.dmg dist/RepoDeck.dmg
(cd dist && shasum -a 256 -c RepoDeck-1.2.3.dmg.sha256) > "$FIXTURE/checksum"
run --prerelease --release
for argument in --prerelease --latest=false --draft --verify-tag; do
  has_argument "$argument" || fail "Missing prerelease argument: $argument"
done
[[ "$(cat "$FAKE_NOTES")" == *'Channel: prerelease (beta)'* ]] || fail 'Prerelease notes missing'
rm -f "$FAKE_ARGS" "$FAKE_BUNDLE_LOG"
export FAKE_RELEASE_EXISTS=1
refuse --release --prerelease
[[ ! -e "$FAKE_BUNDLE_LOG" && ! -e "$FAKE_ARGS" ]] || fail 'Existing release reached packaging or upload'
unset FAKE_RELEASE_EXISTS
FAKE_FUTURE_COMMIT="$(printf 'Future source\n' | git commit-tree 'HEAD^{tree}' -p HEAD)"
export FAKE_FUTURE_COMMIT
git push -q origin "$FAKE_FUTURE_COMMIT:refs/heads/future"
refuse --release --prerelease
[[ -e "$FAKE_BUNDLE_LOG" && ! -e "$FAKE_ARGS" ]] || fail 'Moved tag was uploaded or pre-build verification did not run'
[[ "$(cat "$FIXTURE/output")" == *'origin/v1.2.3 differs'* ]] || fail 'Expected moved-tag rejection'
printf 'Draft/prerelease packaging checks passed.\n'
