#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

MASTER="dist/repodeck-icon-master.png"
ICONSET="dist/AppIcon.iconset"
DEST="Sources/RepoDeck/Resources/AppIcon.icns"

mkdir -p dist
rm -rf "$ICONSET"
mkdir -p "$ICONSET"

echo "Rendering master icon..."
swift Scripts/make-icon.swift "$MASTER"

declare -a SIZES=(
  "icon_16x16.png:16"
  "icon_16x16@2x.png:32"
  "icon_32x32.png:32"
  "icon_32x32@2x.png:64"
  "icon_128x128.png:128"
  "icon_128x128@2x.png:256"
  "icon_256x256.png:256"
  "icon_256x256@2x.png:512"
  "icon_512x512.png:512"
  "icon_512x512@2x.png:1024"
)

for entry in "${SIZES[@]}"; do
  name="${entry%%:*}"
  px="${entry##*:}"
  sips -z "$px" "$px" "$MASTER" --out "$ICONSET/$name" >/dev/null
done

mkdir -p "$(dirname "$DEST")"
iconutil -c icns "$ICONSET" -o "$DEST"

rm -rf "$ICONSET" "$MASTER"

echo "Wrote $DEST"
