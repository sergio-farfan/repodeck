#!/bin/bash
# Compile the actual locator and exercise copied executables without SwiftPM's
# generated accessor or a build-directory fallback. No app launch or signing.
set -euo pipefail
SOURCE="$(cd "$(dirname "$0")/../.." && pwd)"
FIXTURE="$(mktemp -d)"
trap 'rm -rf "$FIXTURE"' EXIT
mkdir -p "$FIXTURE/build" "$FIXTURE/unrelated working directory"
cat > "$FIXTURE/build/main.swift" <<'SWIFT'
import Foundation

func resolvedPath(_ url: URL) -> String { url.resolvingSymlinksInPath().path }

let expectedResource = CommandLine.arguments[1]
let expectedBundle = URL(fileURLWithPath: CommandLine.arguments[2])
precondition(resolvedPath(Bundle.main.bundleURL) == resolvedPath(expectedBundle),
             "Unexpected main bundle: \(Bundle.main.bundleURL.path)")
let actual = AppResourceLocator.dockIconURL()
if expectedResource == "missing" {
    precondition(actual == nil, "Missing icon unexpectedly resolved to \(String(describing: actual))")
} else {
    precondition(actual.map(resolvedPath) == resolvedPath(URL(fileURLWithPath: expectedResource)),
                 "Wrong icon: \(String(describing: actual)); expected \(expectedResource)")
}
print("App resource fixture passed: \(CommandLine.arguments[3])")
SWIFT
xcrun swiftc -swift-version 6 -sdk "${SDKROOT:-$(xcrun --sdk macosx --show-sdk-path)}" \
  -module-cache-path "$FIXTURE/module-cache" \
  "$SOURCE/Sources/RepoDeck/AppResourceLocator.swift" "$FIXTURE/build/main.swift" \
  -o "$FIXTURE/build/ResourceProbe"

APP="$FIXTURE/Packaged App.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$FIXTURE/build/ResourceProbe" "$APP/Contents/MacOS/ResourceProbe"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>ResourceProbe</string>
<key>CFBundleIdentifier</key><string>invalid.example.RepoDeckResourceTest</string>
<key>CFBundlePackageType</key><string>APPL</string>
</dict></plist>
PLIST
NESTED="$APP/Contents/Resources/RepoDeck_RepoDeck.bundle"
mkdir -p "$NESTED/Contents/Resources"
printf '%s' '<?xml version="1.0"?><plist version="1.0"><dict><key>CFBundleIdentifier</key><string>invalid.example.RepoDeckResources</string><key>CFBundlePackageType</key><string>BNDL</string></dict></plist>' > "$NESTED/Contents/Info.plist"
cp "$SOURCE/Sources/RepoDeck/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
cp "$SOURCE/Sources/RepoDeck/Resources/AppIcon.icns" "$NESTED/Contents/Resources/AppIcon.icns"
cd "$FIXTURE/unrelated working directory"
"$APP/Contents/MacOS/ResourceProbe" "$APP/Contents/Resources/AppIcon.icns" "$APP" 'main app resource takes precedence'
rm "$APP/Contents/Resources/AppIcon.icns"
"$APP/Contents/MacOS/ResourceProbe" "$NESTED/Contents/Resources/AppIcon.icns" "$APP" 'packaged nested resource bundle'
rm "$NESTED/Contents/Resources/AppIcon.icns"
"$APP/Contents/MacOS/ResourceProbe" missing "$APP" 'resource bundle without an icon is nonfatal'
rm -rf "$NESTED"
"$APP/Contents/MacOS/ResourceProbe" missing "$APP" 'app without a resource bundle is nonfatal'

CLI="$FIXTURE/command line/debug"
mkdir -p "$CLI/RepoDeck_RepoDeck.bundle"
cp "$FIXTURE/build/ResourceProbe" "$CLI/ResourceProbe"
cp "$SOURCE/Sources/RepoDeck/Resources/AppIcon.icns" "$CLI/RepoDeck_RepoDeck.bundle/AppIcon.icns"
"$CLI/ResourceProbe" "$CLI/RepoDeck_RepoDeck.bundle/AppIcon.icns" "$CLI" 'SwiftPM executable-adjacent resource bundle'
rm "$CLI/RepoDeck_RepoDeck.bundle/AppIcon.icns"
"$CLI/ResourceProbe" missing "$CLI" 'SwiftPM resource bundle without an icon is nonfatal'
rm -rf "$CLI/RepoDeck_RepoDeck.bundle"
"$CLI/ResourceProbe" missing "$CLI" 'executable without a resource bundle is nonfatal'
