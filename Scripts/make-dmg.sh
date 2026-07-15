#!/bin/bash
set -euo pipefail

# Package dist/RepoDeck.app into a styled, compressed DMG installer.
#
# Mechanics borrowed from nosleep's package-dmg.sh: staging layout, a UDRW
# (writable) image, attach -> osascript Finder layout under a 45s watchdog
# (a TCC "Automation -> Finder" prompt must never hang packaging) -> detach,
# then hdiutil convert to a compressed UDZO image.
#
# Discipline borrowed from alttab's package-dmg.sh: SIGN_IDENTITY re-signing
# and a `.sha256` checksum sidecar, plus its changelog-driven release notes
# for --release.
#
# Usage: Scripts/make-dmg.sh [--release]
# Optional env:
#   SIGN_IDENTITY  codesigning identity (SHA-1 or common name). If set, the
#                  app built by bundle.sh (ad-hoc signed) is re-signed with
#                  it under the hardened runtime before packaging. If unset,
#                  the app ships with bundle.sh's ad-hoc seal.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

RELEASE=0
if [[ "${1:-}" == "--release" ]]; then
  RELEASE=1
fi

APP_NAME="RepoDeck"
DIST="$ROOT/dist"
APP_BUNDLE="$DIST/${APP_NAME}.app"
VOL_NAME="RepoDeck"

echo "==> Building ${APP_BUNDLE}..."
Scripts/bundle.sh

if [ -n "${SIGN_IDENTITY:-}" ]; then
  echo "==> Re-signing with SIGN_IDENTITY ($SIGN_IDENTITY)..."
  codesign --force --deep -s "$SIGN_IDENTITY" --options runtime "$APP_BUNDLE"
  codesign --verify --strict --verbose=2 "$APP_BUNDLE"
fi

VER="$(plutil -extract CFBundleShortVersionString raw Support/Info.plist)"
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
}
trap cleanup EXIT INT TERM

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
    osascript <<APPLESCRIPT
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
        echo "### Unsigned build"
        echo "Not yet notarized. On first launch, right-click **RepoDeck.app -> Open**, or clear quarantine:"
        echo ""
        echo "    xattr -dr com.apple.quarantine /Applications/RepoDeck.app"
    } >> "$NOTES"

    SHA="$DMG_FINAL.sha256"
    # A stably-named copy alongside the versioned asset, so
    # .../releases/latest/download/RepoDeck.dmg is an evergreen direct link
    # (the versioned name changes every release and would break it).
    DMG_STABLE="$(dirname "$DMG_FINAL")/RepoDeck.dmg"
    cp "$DMG_FINAL" "$DMG_STABLE"
    if gh release view "v$VER" >/dev/null 2>&1; then
        gh release upload "v$VER" "$DMG_FINAL" "$SHA" "$DMG_STABLE" --clobber
    else
        gh release create "v$VER" "$DMG_FINAL" "$SHA" "$DMG_STABLE" --title "RepoDeck $VER" --notes-file "$NOTES"
    fi
fi
