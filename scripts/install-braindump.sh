#!/bin/bash
# Build BrainDump from this checkout, install it to ~/Applications, and run it
# at login. Stops (but does not uninstall) the Homebrew open-wispr service, so
# rolling back is: launchctl bootout gui/$UID ~/Library/LaunchAgents/com.madeby10am.braindump.plist
#                  brew services start open-wispr
set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP="$HOME/Applications/BrainDump.app"
AGENT="$HOME/Library/LaunchAgents/com.madeby10am.braindump.plist"
LOG="$HOME/Library/Logs/braindump.log"

command -v llama-server >/dev/null || brew install llama.cpp
brew list whisper-cpp >/dev/null 2>&1 || brew install whisper-cpp

cd "$REPO_DIR"
echo "Building..."
swift build -c release 2>&1 | tail -1
bash scripts/bundle-app.sh .build/release/open-wispr BrainDump.app "$(git describe --tags --always 2>/dev/null || echo dev)-braindump"

if brew services list 2>/dev/null | grep -q "^open-wispr .*started"; then
    echo "Stopping Homebrew open-wispr service..."
    brew services stop open-wispr
fi
launchctl bootout "gui/$UID" "$AGENT" 2>/dev/null || true
pkill -f "BrainDump.app/Contents/MacOS/open-wispr" 2>/dev/null || true

rm -rf "$APP"
mkdir -p "$HOME/Applications"
mv BrainDump.app "$APP"

cat > "$AGENT" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.madeby10am.braindump</string>
    <key>ProgramArguments</key>
    <array>
        <string>$APP/Contents/MacOS/open-wispr</string>
        <string>start</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <dict>
        <key>SuccessfulExit</key>
        <false/>
    </dict>
    <key>ProcessType</key>
    <string>Interactive</string>
    <key>StandardOutPath</key>
    <string>$LOG</string>
    <key>StandardErrorPath</key>
    <string>$LOG</string>
</dict>
</plist>
PLIST

launchctl bootstrap "gui/$UID" "$AGENT"
echo "BrainDump installed and running. Log: $LOG"
echo "First run: grant Microphone + Accessibility to BrainDump when macOS asks."
