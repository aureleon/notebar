#!/bin/bash
# Builds NoteBar.app and installs it in ~/Applications.
#   scripts/build-app.sh            release build + install
#   scripts/build-app.sh --no-install   build into ./build only
set -euo pipefail
cd "$(dirname "$0")/.."

INSTALL=1
[[ "${1:-}" == "--no-install" ]] && INSTALL=0

swift build -c release --product NoteBar
BIN="$(swift build -c release --show-bin-path)"

APP="build/NoteBar.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/NoteBar" "$APP/Contents/MacOS/NoteBar"
cp Resources/Info.plist "$APP/Contents/Info.plist"
# Everything else in Resources/ (sdef, icons...) goes into Contents/Resources.
find Resources -maxdepth 1 -type f ! -name Info.plist -exec cp {} "$APP/Contents/Resources/" \;
# SwiftPM resource bundles, if any.
find "$BIN" -maxdepth 1 -name '*.bundle' -exec cp -R {} "$APP/Contents/Resources/" \;

codesign -s - --force --deep "$APP"
echo "Built $APP"

if [[ $INSTALL == 1 ]]; then
    mkdir -p ~/Applications
    pkill -x NoteBar 2>/dev/null || true
    rm -rf ~/Applications/NoteBar.app
    cp -R "$APP" ~/Applications/NoteBar.app
    /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f ~/Applications/NoteBar.app
    echo "Installed ~/Applications/NoteBar.app"
fi
