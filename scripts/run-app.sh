#!/bin/bash
# Builds GSComposer with SwiftPM, wraps it in "3DGS Composer.app" and launches it.
# A bare `swift run` executable is not a proper app bundle, so macOS may not route clicks/keys to it.
set -euo pipefail

cd "$(dirname "$0")/.."
CONFIG="${CONFIG:-release}"

swift build -c "$CONFIG" --product GSComposer
BIN_DIR="$(swift build -c "$CONFIG" --show-bin-path)"

APP="build/3DGS Composer.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/GSComposer" "$APP/Contents/MacOS/GSComposer"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>GSComposer</string>
    <key>CFBundleIdentifier</key><string>com.inai17ibar.GSComposer</string>
    <key>CFBundleName</key><string>3DGS Composer</string>
    <key>CFBundleDisplayName</key><string>3DGS Composer</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>15.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP" >/dev/null 2>&1 || true

if [ "${NO_OPEN:-0}" != "1" ]; then
    open "$APP"
fi
echo "$APP"
