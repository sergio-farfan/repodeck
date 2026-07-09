#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
swift build -c release
APP="dist/RepoDeck.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/RepoDeck "$APP/Contents/MacOS/RepoDeck"
cp Support/Info.plist "$APP/Contents/Info.plist"
mkdir -p "$APP/Contents/Resources"
cp Sources/RepoDeck/Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
if [ -d ".build/release/RepoDeck_RepoDeck.bundle" ]; then
  cp -R ".build/release/RepoDeck_RepoDeck.bundle" "$APP/Contents/Resources/"
fi
codesign --force --sign - "$APP"
echo "Built $APP"
if [[ "${1:-}" == "--open" ]]; then open "$APP"; fi
