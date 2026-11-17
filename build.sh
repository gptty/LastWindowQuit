#!/bin/bash
# Builds LastWindowQuit.app from main.swift and installs it to ~/Applications.
#   ./build.sh            build + install
#   ./build.sh --login    build + install + start at login (LaunchAgent)
#   ./build.sh --remove   stop it and remove the app and LaunchAgent
# Requires the Xcode Command Line Tools (xcode-select --install).
set -euo pipefail

NAME="LastWindowQuit"
BUNDLE_ID="local.lastwindowquit"
HERE="$(cd "$(dirname "$0")" && pwd)"
APP="$HOME/Applications/$NAME.app"
AGENT="$HOME/Library/LaunchAgents/$BUNDLE_ID.plist"

stop_running() {
    launchctl bootout "gui/$(id -u)/$BUNDLE_ID" 2>/dev/null || true
    pkill -x "$NAME" 2>/dev/null || true
}

if [[ "${1:-}" == "--remove" ]]; then
    stop_running
    rm -rf "$APP" "$AGENT"
    echo "Removed. Settings remain in ~/.config/lastwindowquit, log in ~/Library/Logs/$NAME.log"
    exit 0
fi

BUILD="$(mktemp -d)"
trap 'rm -rf "$BUILD"' EXIT
mkdir -p "$BUILD/$NAME.app/Contents/MacOS"

swiftc -O -swift-version 5 -o "$BUILD/$NAME.app/Contents/MacOS/$NAME" "$HERE/main.swift"

cat > "$BUILD/$NAME.app/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>$NAME</string>
    <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
    <key>CFBundleName</key><string>$NAME</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>12.0</string>
    <key>LSUIElement</key><true/>
</dict>
</plist>
EOF

codesign --force --sign - "$BUILD/$NAME.app"

stop_running
mkdir -p "$HOME/Applications"
rm -rf "$APP"
cp -R "$BUILD/$NAME.app" "$APP"
echo "Installed $APP"

if [[ "${1:-}" == "--login" ]]; then
    mkdir -p "$(dirname "$AGENT")"
    cat > "$AGENT" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>$BUNDLE_ID</string>
    <key>ProgramArguments</key>
    <array><string>$APP/Contents/MacOS/$NAME</string></array>
    <key>RunAtLoad</key><true/>
    <key>ProcessType</key><string>Interactive</string>
</dict>
</plist>
EOF
    launchctl bootstrap "gui/$(id -u)" "$AGENT"
    echo "Started, and will start at login."
else
    open "$APP"
    echo "Started. Run './build.sh --login' to also start it at login."
fi

echo "First run: allow $NAME under System Settings > Privacy & Security > Device Control and Data Access."
echo "After a rebuild, remove the old $NAME entry there and add it again."
