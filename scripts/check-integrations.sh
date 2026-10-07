#!/bin/bash
# Offline checks for the NoteBarIntegrations module. Shows no window and does not launch NoteBar.
#   1. Builds the NoteBarIntegrations target and runs scripts/checks/IntegrationChecks.swift
#      (URL parser, x-callback helpers, action layer against InMemoryNoteStore).
#   2. Lints Resources/Info.plist and Resources/NoteBar.sdef.
#   3. Compiles sample AppleScripts against the sdef, using a stub bundle that only holds the
#      dictionary (other bundle id, no URL scheme, no services; its executable just exits).
#
# Usage: scripts/check-integrations.sh [scratch-path]   (default .build-agents/integrations)
set -euo pipefail
cd "$(dirname "$0")/.."

SCRATCH="${1:-.build-agents/integrations}"
WORK="$SCRATCH/check-integrations"
rm -rf "$WORK"; mkdir -p "$WORK"

echo "== build NoteBarIntegrations"
swift build --target NoteBarIntegrations --scratch-path "$SCRATCH" 2>&1 | grep -E "error|Compiling|Build complete" || true
BIN="$SCRATCH/debug"
[[ -f "$BIN/NoteBarIntegrations.o" ]] || { echo "build failed"; exit 1; }

echo "== IntegrationChecks"
# NoteBarIntegrations.o / NoteBarCore.o are SwiftPM's per-target merged objects.
swiftc -swift-version 5 -I "$BIN" -o "$WORK/IntegrationChecks" scripts/checks/IntegrationChecks.swift \
    "$BIN/NoteBarCore.o" "$BIN/NoteBarIntegrations.o" -framework AppKit -framework Carbon 2>&1 \
    | grep -v "search path" || true
"$WORK/IntegrationChecks"

echo "== plist / sdef lint"
plutil -lint Resources/Info.plist
xmllint --noout Resources/NoteBar.sdef && echo "Resources/NoteBar.sdef: OK"
# Every cocoa class named in the sdef must be an @objc(...) name in ScriptCommands.swift.
for cls in $(grep -o 'cocoa class="NB[A-Za-z]*"' Resources/NoteBar.sdef | sed 's/.*="\(.*\)"/\1/' | sort -u); do
    grep -q "@objc($cls)" Sources/NoteBarIntegrations/ScriptCommands.swift || { echo "missing @objc($cls)"; exit 1; }
done
echo "sdef command classes: OK"
# Every NSMessage in Info.plist must be a services provider method.
for msg in $(/usr/libexec/PlistBuddy -c "Print :NSServices" Resources/Info.plist | grep NSMessage | awk '{print $3}'); do
    grep -q "@objc func $msg(_ pboard: NSPasteboard" Sources/NoteBarIntegrations/ServicesProvider.swift || { echo "missing service method $msg"; exit 1; }
done
echo "services methods: OK"

echo "== AppleScript terminology (osacompile against a stub bundle)"
STUB="$WORK/NoteBarTerminologyStub.app"
mkdir -p "$STUB/Contents/MacOS" "$STUB/Contents/Resources"
cp Resources/NoteBar.sdef "$STUB/Contents/Resources/"
printf '#!/bin/sh\nexit 0\n' > "$STUB/Contents/MacOS/Stub"; chmod +x "$STUB/Contents/MacOS/Stub"
cat > "$STUB/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>local.dhguz.NoteBarTerminologyStub</string>
<key>CFBundleName</key><string>NoteBarTerminologyStub</string>
<key>CFBundleExecutable</key><string>Stub</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>LSUIElement</key><true/>
<key>NSAppleScriptEnabled</key><true/>
<key>OSAScriptingDefinition</key><string>NoteBar.sdef</string>
</dict></plist>
PLIST
ABS_STUB="$(cd "$STUB/.." && pwd)/$(basename "$STUB")"
cat > "$WORK/sample.applescript" <<OSA
tell application "$ABS_STUB"
    set n to new note with text "Buy milk" in folder "Inbox" show false
    set n2 to new note "Direct text" without show
    set t to get note text id n
    set t2 to get note text n2
    set ids to search notes for "milk"
    set foundBodies to search notes for "milk" in folder "Inbox" returning bodies
    set foundTitles to search notes "milk" returning titles
    set allNotes to search notes
    set fs to list folders
    show notebar
    hide notebar
    toggle notebar
    reveal note id n
    search notebar for "milk"
    open notebar settings
    set v to panel visible
    set nm to name
    quit
end tell
OSA
osacompile -o "$WORK/sample.scpt" "$WORK/sample.applescript"
# Decompile and make sure the commands kept their meaning (not parsed as generic 'get' / 'show').
osadecompile "$WORK/sample.scpt" > "$WORK/sample.decompiled.applescript"
grep -q 'get note text id n' "$WORK/sample.decompiled.applescript"
grep -q 'new note with text "Buy milk" in folder "Inbox" show false' "$WORK/sample.decompiled.applescript" \
    || grep -q 'new note with text "Buy milk" in folder "Inbox" without show' "$WORK/sample.decompiled.applescript"
# Without the dictionary, osadecompile shows raw codes: verify each command maps to our event.
mv "$STUB" "$WORK/stub-hidden.app"
osadecompile "$WORK/sample.scpt" > "$WORK/sample.raw.applescript" 2>/dev/null || true
mv "$WORK/stub-hidden.app" "$STUB"
for code in NBarNewN NBarGtxt NBarSrch NBarLsFd NBarShow NBarHide NBarTogl NBarRevl NBarOSrc NBarSett; do
    grep -q "event $code" "$WORK/sample.raw.applescript" || { echo "command code $code not found in compiled script"; cat "$WORK/sample.raw.applescript"; exit 1; }
done
[[ $(grep -c "event NBarGtxt" "$WORK/sample.raw.applescript") == 2 ]] || { echo "'get note text' did not compile to NBarGtxt twice"; exit 1; }
echo "AppleScript terminology: OK"

echo "== Cocoa Scripting + URL event runtime (in-process harness, no windows)"
HAR="$WORK/NoteBarScriptingHarness.app"
mkdir -p "$HAR/Contents/MacOS" "$HAR/Contents/Resources"
cp Resources/NoteBar.sdef "$HAR/Contents/Resources/"
sed -e 's#<string>local.dhguz.NoteBarTerminologyStub</string>#<string>local.dhguz.NoteBarScriptingHarness</string>#' \
    -e 's#<string>NoteBarTerminologyStub</string>#<string>NoteBarScriptingHarness</string>#' \
    -e 's#<string>Stub</string>#<string>Harness</string>#' "$STUB/Contents/Info.plist" > "$HAR/Contents/Info.plist"
swiftc -swift-version 5 -I "$BIN" -o "$HAR/Contents/MacOS/Harness" scripts/checks/ScriptingHarness.swift \
    "$BIN/NoteBarCore.o" "$BIN/NoteBarIntegrations.o" -framework AppKit -framework Carbon 2>&1 \
    | grep -v "search path" || true
"$HAR/Contents/MacOS/Harness"
# Forget the stub bundles in Launch Services (osacompile / launching may have registered them).
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
"$LSREGISTER" -u "$ABS_STUB" >/dev/null 2>&1 || true
"$LSREGISTER" -u "$(cd "$HAR" && pwd)" >/dev/null 2>&1 || true
echo "All integration checks passed."
