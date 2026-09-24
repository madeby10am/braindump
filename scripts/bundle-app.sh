#!/bin/bash
set -euo pipefail

BINARY="${1:-.build/release/open-wispr}"
APP_DIR="${2:-BrainDump.app}"
VERSION="${3:-0.3.0}"

rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS"
mkdir -p "$APP_DIR/Contents/Resources"

cp "$BINARY" "$APP_DIR/Contents/MacOS/open-wispr"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
cp "$REPO_DIR/Resources/AppIcon.icns" "$APP_DIR/Contents/Resources/AppIcon.icns"

cat > "$APP_DIR/Contents/Info.plist" << PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>open-wispr</string>
    <key>CFBundleIdentifier</key>
    <string>com.madeby10am.braindump</string>
    <key>CFBundleName</key>
    <string>BrainDump</string>
    <key>CFBundleDisplayName</key>
    <string>BrainDump</string>
    <key>CFBundleVersion</key>
    <string>${VERSION}</string>
    <key>CFBundleShortVersionString</key>
    <string>${VERSION}</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSMicrophoneUsageDescription</key>
    <string>BrainDump needs microphone access to record speech for transcription.</string>
</dict>
</plist>
PLIST

# A stable identity keeps macOS's Accessibility grant across rebuilds; ad-hoc
# signing changes the signature every build, so macOS asks again each time.
SIGN_ID="-"
if security find-identity -p codesigning 2>/dev/null | grep -q "BrainDump Dev"; then
    SIGN_ID="BrainDump Dev"
fi
codesign --force --sign "$SIGN_ID" --identifier com.madeby10am.braindump "$APP_DIR"

echo "Built $APP_DIR"
