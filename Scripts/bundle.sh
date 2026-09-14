#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
case "${1:-}" in ""|--open) ;; *) echo "Usage: Scripts/bundle.sh [--open]" >&2; exit 2 ;; esac

# Build both architectures explicitly; SwiftPM's universal product directory is
# different from its single-architecture directory, so query it rather than guess.
swift build -c release --arch arm64 --arch x86_64
BIN_DIR="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)"
APP="dist/RepoDeck.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/RepoDeck" "$APP/Contents/MacOS/RepoDeck"
lipo "$APP/Contents/MacOS/RepoDeck" -verify_arch arm64 x86_64
cp Support/Info.plist "$APP/Contents/Info.plist"
cp Sources/RepoDeck/Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
if [ -d "$BIN_DIR/RepoDeck_RepoDeck.bundle" ]; then
  cp -R "$BIN_DIR/RepoDeck_RepoDeck.bundle" "$APP/Contents/Resources/"
fi
if [ -n "${SIGN_IDENTITY:-}" ]; then
  codesign --force --sign "$SIGN_IDENTITY" --options runtime --timestamp "$APP"
else
  codesign --force --sign - "$APP"
fi
codesign --verify --strict --verbose=2 "$APP"
echo "Built universal $APP"
if [[ "${1:-}" == "--open" ]]; then open "$APP"; fi
