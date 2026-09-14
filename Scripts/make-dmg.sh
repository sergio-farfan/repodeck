#!/bin/bash
set -euo pipefail

# Package dist/RepoDeck.app into a styled, compressed DMG installer.
#
# Usage: Scripts/make-dmg.sh [--release [--prerelease]]
# --release validates existing local/remote tags and creates a GitHub draft.
# --prerelease marks that draft as a prerelease and excludes it from latest.
# Optional environment:
#   SIGN_IDENTITY  existing Developer ID keychain identity; enables timestamp
#                  and hardened runtime signing in bundle.sh.
#   NOTARY_PROFILE existing notarytool keychain profile; requires SIGN_IDENTITY
#                  and notarizes/staples both app and final disk image.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

RELEASE=0
PRERELEASE=0
for argument in "$@"; do
  case "$argument" in
    --release) RELEASE=1 ;;
    --prerelease) PRERELEASE=1 ;;
    *) echo "Usage: Scripts/make-dmg.sh [--release [--prerelease]]" >&2; exit 2 ;;
  esac
done
if [ "$PRERELEASE" -eq 1 ] && [ "$RELEASE" -ne 1 ]; then
  echo "--prerelease requires --release." >&2
  exit 2
fi
VER="$(plutil -extract CFBundleShortVersionString raw Support/Info.plist)"
RELEASE_COMMIT=""
RELEASE_REPO=""
if [ "$RELEASE" -eq 1 ]; then
  RELEASE_COMMIT="$(Scripts/validate-release-tag.sh "v$VER")" || exit $?
  RELEASE_REPO="$(git remote get-url origin)"
  command -v gh >/dev/null || { echo "GitHub CLI is required for --release" >&2; exit 1; }
  # Refuse existing releases instead of replacing published binaries.
  if gh release view "v$VER" --repo "$RELEASE_REPO" >/dev/null 2>&1; then
    echo "Release v$VER already exists. Bump the version; assets are never replaced." >&2
    exit 1
  fi
fi
if [ -n "${NOTARY_PROFILE:-}" ] && [ -z "${SIGN_IDENTITY:-}" ]; then
  echo "NOTARY_PROFILE requires a Developer ID SIGN_IDENTITY." >&2
  exit 1
fi

APP_NAME="RepoDeck"
DIST="$ROOT/dist"
APP_BUNDLE="$DIST/${APP_NAME}.app"
VOL_NAME="RepoDeck"

echo "==> Building ${APP_BUNDLE}..."
Scripts/bundle.sh

# Notarize and staple the app before it is placed in the image. The profile
# refers to credentials already stored by the developer in their keychain.
if [ -n "${NOTARY_PROFILE:-}" ]; then
  NOTARY_DIR="$(mktemp -d -t repodeck-notary)"
  NOTARY_ZIP="$NOTARY_DIR/RepoDeck.zip"
  trap 'rm -rf "$NOTARY_DIR"' EXIT
  ditto -c -k --keepParent "$APP_BUNDLE" "$NOTARY_ZIP"
  xcrun notarytool submit "$NOTARY_ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$APP_BUNDLE"
  xcrun stapler validate "$APP_BUNDLE"
  rm -rf "$NOTARY_DIR"
  trap - EXIT
fi

DMG_FINAL="$DIST/${APP_NAME}-${VER}.dmg"
DMG_TMP="$DIST/${APP_NAME}-tmp.dmg"

echo "==> Staging DMG contents..."
mkdir -p "$DIST"
STAGING="$(mktemp -d "$DIST/stage.XXXXXX")"
MOUNT_DIR=""

cleanup() {
  if [ -n "$MOUNT_DIR" ] && [ -d "$MOUNT_DIR" ]; then
    hdiutil detach "$MOUNT_DIR" >/dev/null 2>&1 || true
  fi
  rm -rf "$STAGING"
  rm -f "$DMG_TMP"
  if [ -n "${NOTES:-}" ]; then rm -f "$NOTES"; fi
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

cp -R "$APP_BUNDLE" "$STAGING/"
ln -s /Applications "$STAGING/Applications"

mkdir -p "$STAGING/.background"
swift Scripts/make-icon.swift --dmg-background "$STAGING/.background/background@2x.png"
sips -z 400 600 "$STAGING/.background/background@2x.png" --out "$STAGING/.background/background.png" >/dev/null

cp Sources/RepoDeck/Resources/AppIcon.icns "$STAGING/.VolumeIcon.icns"

echo "==> Creating writable image..."
rm -f "$DMG_TMP" "$DMG_FINAL"
SIZE_MB=$(( $(du -sm "$STAGING" | awk '{print $1}') + 20 )) # content + slack for .DS_Store/background
hdiutil create -srcfolder "$STAGING" -volname "$VOL_NAME" \
    -fs HFS+ -format UDRW -size "${SIZE_MB}m" -ov "$DMG_TMP" >/dev/null

echo "==> Mounting..."
ATTACH_OUT="$(hdiutil attach "$DMG_TMP" -readwrite -noverify -noautoopen)"
MOUNT_DIR="$(printf '%s\n' "$ATTACH_OUT" | grep -Eo '/Volumes/.*' | tail -1)"
sleep 2

echo "==> Applying Finder layout (best effort -- needs Automation -> Finder permission)..."
apply_layout() {
    exec osascript <<APPLESCRIPT
tell application "Finder"
    tell disk "${VOL_NAME}"
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set the bounds of container window to {200, 120, 800, 520}
        set theViewOptions to the icon view options of container window
        set arrangement of theViewOptions to not arranged
        set icon size of theViewOptions to 128
        set background picture of theViewOptions to file ".background:background.png"
        set position of item "${APP_NAME}.app" of container window to {150, 190}
        set position of item "Applications" of container window to {450, 190}
        update without registering applications
        delay 1
        close
    end tell
end tell
APPLESCRIPT
}

# Run in the background with a timeout so packaging never hangs on a TCC prompt.
apply_layout & OSA_PID=$!
( sleep 45; kill "$OSA_PID" 2>/dev/null ) & WATCHER=$!
if wait "$OSA_PID" 2>/dev/null; then
    kill "$WATCHER" 2>/dev/null || true
    echo "    Layout applied."
else
    echo "    Warning: Finder layout not applied (Automation denied or timed out)."
    echo "    The DMG is still valid. Grant your terminal 'Automation -> Finder' in"
    echo "    System Settings -> Privacy & Security, then re-run for the styled window."
fi

# Volume icon (best effort -- layout/background still work without it)
if [ -f "$STAGING/.VolumeIcon.icns" ] && command -v SetFile >/dev/null 2>&1; then
    SetFile -a C "$MOUNT_DIR" || true
fi

sync
echo "==> Detaching..."
hdiutil detach "$MOUNT_DIR" >/dev/null
MOUNT_DIR=""

echo "==> Converting to compressed image ${DMG_FINAL}..."
hdiutil convert "$DMG_TMP" -format UDZO -imagekey zlib-level=9 -o "$DMG_FINAL" >/dev/null
rm -f "$DMG_TMP"

echo "==> Verifying..."
hdiutil verify "$DMG_FINAL"

if [ -n "${SIGN_IDENTITY:-}" ]; then
  codesign --force --sign "$SIGN_IDENTITY" --timestamp "$DMG_FINAL"
fi
if [ -n "${NOTARY_PROFILE:-}" ]; then
  xcrun notarytool submit "$DMG_FINAL" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$DMG_FINAL"
  xcrun stapler validate "$DMG_FINAL"
fi

echo "==> Writing checksum..."
( cd "$DIST" && shasum -a 256 "$(basename "$DMG_FINAL")" | tee "$(basename "$DMG_FINAL").sha256" )

echo "==> Done! Created ${DMG_FINAL}"

if [ "$RELEASE" -eq 1 ]; then
    echo "==> Preparing GitHub release v${VER}..."
    NOTES="$(mktemp)"
    Scripts/changelog-section.sh "$VER" > "$NOTES"
    {
        echo ""
        echo "---"
        echo "Source commit: $RELEASE_COMMIT"
        if [ "$PRERELEASE" -eq 1 ]; then
          echo "Channel: prerelease (beta); excluded from latest downloads."
        fi
        echo "Architecture: universal (Apple silicon and Intel)."
        echo ""
        if [ -n "${NOTARY_PROFILE:-}" ]; then
          echo "Developer ID signed and notarized."
        else
          echo "### Development build"
          echo "Not notarized. Review the signing status before publishing this draft."
        fi
        echo ""
        echo 'Build toolchain:'
        swift --version
    } >> "$NOTES"

    SHA="$DMG_FINAL.sha256"
    # A stably-named copy alongside the versioned asset, so
    # .../releases/latest/download/RepoDeck.dmg is an evergreen direct link
    # (the versioned name changes every release and would break it).
    DMG_STABLE="$(dirname "$DMG_FINAL")/RepoDeck.dmg"
    cp "$DMG_FINAL" "$DMG_STABLE"
    # Recheck immediately before upload in case the checkout or remote tag
    # changed during packaging. gh must use that existing tag, never auto-tag.
    # Explicit failure handling also works with macOS Bash 3.2, whose
    # errexit behavior does not reliably stop on a failed [[ ... ]] test.
    Scripts/validate-release-tag.sh "v$VER" "$RELEASE_COMMIT" >/dev/null || exit $?
    RELEASE_OPTIONS=(--repo "$RELEASE_REPO" --verify-tag --draft --title "RepoDeck $VER" --notes-file "$NOTES")
    if [ "$PRERELEASE" -eq 1 ]; then
      RELEASE_OPTIONS+=(--prerelease --latest=false)
    fi
    gh release create "v$VER" "$DMG_FINAL" "$SHA" "$DMG_STABLE" "${RELEASE_OPTIONS[@]}"
    echo "Draft release created. Verify its assets and signing status before publication."
fi
