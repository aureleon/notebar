#!/bin/bash
# End-to-end smoke test of the integrations (URL scheme, AppleScript, Services) against a BUILT app.
# It launches NoteBar with a throwaway data directory, so your real notes are never touched.
#
#   scripts/build-app.sh --no-install          # or a full install
#   scripts/smoke-integrations.sh [path/to/NoteBar.app]   (default: build/NoteBar.app)
#
# Notes:
# - The panel may slide in on screen for a moment (notebar://show, reveal). Nothing else is shown.
# - The first osascript call may make macOS ask whether Terminal may control NoteBar (Automation).
# - NoteBar must not be running already (URLs would go to that instance and its real data).
#   Pass --kill to quit a running NoteBar first.
# - The Services check needs the app installed + registered (scripts/build-app.sh does that).
#   It is reported as SKIP if the service is not registered yet.
# - AppSettings uses the real user defaults domain (lastFolderId etc. may change).
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

KILL=0
APP=""
for a in "$@"; do
    case "$a" in
        --kill) KILL=1 ;;
        *) APP="$a" ;;
    esac
done
APP="${APP:-build/NoteBar.app}"
[[ -d "$APP" ]] || { echo "No app at $APP (run scripts/build-app.sh --no-install first)"; exit 1; }
APP="$(cd "$APP" && pwd)"
BIN="$APP/Contents/MacOS/NoteBar"

if pgrep -x NoteBar >/dev/null; then
    if [[ $KILL == 1 ]]; then
        osascript -e 'tell application id "local.dhguz.NoteBar" to quit' >/dev/null 2>&1 || pkill -x NoteBar
        for _ in $(seq 1 50); do pgrep -x NoteBar >/dev/null || break; sleep 0.1; done
        pgrep -x NoteBar >/dev/null && { echo "Could not quit the running NoteBar"; exit 1; }
    else
        echo "NoteBar is running. Quit it first or pass --kill."; exit 1
    fi
fi

DATA="$(mktemp -d "${TMPDIR:-/tmp}/notebar-smoke.XXXXXX")"
DB="$DATA/notebar.sqlite"
LOG="$DATA/notebar.log"
PASS=0; FAIL=0; SKIP=0
ok()   { PASS=$((PASS + 1)); echo "  ok    $*"; }
bad()  { FAIL=$((FAIL + 1)); echo "  FAIL  $*"; }
skip() { SKIP=$((SKIP + 1)); echo "  skip  $*"; }
check() { # check "label" expected actual
    if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1: expected [$2], got [$3]"; fi
}
ascript() { osascript -e "tell application \"$APP\"" -e "$1" -e "end tell" 2>&1; }
url() { open -g -a "$APP" "$1"; sleep "${2:-0.6}"; }
sql() { [[ -f "$DB" ]] && sqlite3 -readonly "$DB" "$1" 2>/dev/null; }

cleanup() {
    if kill -0 "$PID" 2>/dev/null; then
        ascript "quit" >/dev/null
        for _ in $(seq 1 50); do kill -0 "$PID" 2>/dev/null || break; sleep 0.1; done
        kill "$PID" 2>/dev/null
    fi
}

echo "== launching $APP (NOTEBAR_DATA_DIR=$DATA)"
NOTEBAR_DATA_DIR="$DATA" "$BIN" >"$LOG" 2>&1 &
PID=$!
trap cleanup EXIT
for _ in $(seq 1 100); do
    [[ "$(ascript 'name')" == "NoteBar" ]] && break
    sleep 0.1
done
kill -0 "$PID" 2>/dev/null || { echo "NoteBar exited during launch; log:"; cat "$LOG"; exit 1; }
check "AppleScript responds" "NoteBar" "$(ascript 'name')"
# A first launch (empty data folder) reveals the panel once; start the checks from a hidden panel.
sleep 0.5; ascript 'hide notebar' >/dev/null; sleep 0.5

echo "== URL scheme"
STAMP="smoke$$"
url "notebar://new?text=URL+${STAMP}%20%E2%9C%93%0Asecond%20line&folder=Smoke+Inbox&show=0"
IDS="$(ascript "search notes for \"URL $STAMP\"")"
check "notebar://new created one note" "1" "$(echo "$IDS" | tr ',' '\n' | grep -c '[0-9]')"
URL_ID="$(echo "$IDS" | tr -dc '0-9')"
check "body percent-decoded (+, %20, UTF-8, newline)" "URL $STAMP ✓
second line" "$(ascript "get note text id ${URL_ID:-0}")"
check "folder created" "1" "$(ascript 'list folders' | tr ',' '\n' | sed 's/^ *//' | grep -cx 'Smoke Inbox')"
check "show=0 keeps the panel hidden" "false" "$(ascript 'panel visible')"
if [[ -f "$DB" ]]; then
    sleep 1 # debounce
    check "sqlite: note row" "URL $STAMP ✓" "$(sql "select body from note where body like 'URL $STAMP%';" | head -1)"
    check "sqlite: folder row" "1" "$(sql "select count(*) from folder where name = 'Smoke Inbox';")"
else
    skip "sqlite checks ($DB does not exist: the app is not using the GRDB store)"
fi

url "notebar://show"
check "notebar://show" "true" "$(ascript 'panel visible')"
url "notebar://hide"
check "notebar://hide" "false" "$(ascript 'panel visible')"
url "notebar://toggle"
check "notebar://toggle (on)" "true" "$(ascript 'panel visible')"
url "notebar://toggle"
check "notebar://toggle (off)" "false" "$(ascript 'panel visible')"
url "notebar://open?note=${URL_ID:-0}"
check "notebar://open?note=<id> shows the panel" "true" "$(ascript 'panel visible')"
url "notebar://search?q=$STAMP"
check "notebar://search keeps the panel shown" "true" "$(ascript 'panel visible')"
url "notebar://hide"
url "notebar://new?text=Default+show+${STAMP}"
check "notebar://new shows the panel by default" "true" "$(ascript 'panel visible')"
url "notebar://hide"
BEFORE="$(ascript 'search notes' | tr ',' '\n' | grep -c '[0-9]')"
url "notebar://bogus?text=x"
url "notebar://new?text=x&show=maybe"
check "bad URLs create nothing" "$BEFORE" "$(ascript 'search notes' | tr ',' '\n' | grep -c '[0-9]')"

echo "== AppleScript"
AS_ID="$(ascript "new note with text \"AS $STAMP\" in folder \"Smoke Script\" show false")"
[[ "$AS_ID" =~ ^[0-9]+$ ]] && ok "new note returns an integer id ($AS_ID)" || bad "new note returned [$AS_ID]"
check "get note text id" "AS $STAMP" "$(ascript "get note text id $AS_ID")"
check "search notes returning bodies" "AS $STAMP" "$(ascript "search notes for \"as $STAMP\" returning bodies")"
check "search notes in folder" "$AS_ID" "$(ascript "search notes in folder \"Smoke Script\"")"
check "list folders has the new folder" "1" "$(ascript 'list folders' | tr ',' '\n' | sed 's/^ *//' | grep -cx 'Smoke Script')"
ascript 'show notebar' >/dev/null; sleep 0.5
check "show notebar" "true" "$(ascript 'panel visible')"
ascript 'hide notebar' >/dev/null; sleep 0.5
check "hide notebar" "false" "$(ascript 'panel visible')"
ascript 'toggle notebar' >/dev/null; sleep 0.5
check "toggle notebar" "true" "$(ascript 'panel visible')"
ascript 'hide notebar' >/dev/null; sleep 0.5
ERR="$(ascript 'get note text id 987654321')"
[[ "$ERR" == *"-1728"* || "$ERR" == *"not found"* ]] && ok "missing note gives an error" || bad "missing note: [$ERR]"

echo "== Services"
SVC="$DATA/perform-service"
cat > "$SVC.swift" <<'SWIFT'
import AppKit
let pb = NSPasteboard(name: NSPasteboard.Name("NoteBarSmoke"))
pb.clearContents()
pb.setString(CommandLine.arguments[1], forType: .string)
exit(NSPerformService("NoteBar/New Note from Selection", pb) ? 0 : 1)
SWIFT
if swiftc -o "$SVC" "$SVC.swift" >/dev/null 2>&1 && "$SVC" "Service $STAMP"; then
    sleep 1
    check "service created a note" "Service $STAMP" "$(ascript "search notes for \"Service $STAMP\" returning bodies")"
    ascript 'hide notebar' >/dev/null
else
    skip "NSPerformService failed (install the app with scripts/build-app.sh, then run /System/Library/CoreServices/pbs -update)"
fi

echo "== quit"
ascript 'quit' >/dev/null
for _ in $(seq 1 50); do kill -0 "$PID" 2>/dev/null || break; sleep 0.1; done
kill -0 "$PID" 2>/dev/null && bad "quit via AppleScript" || ok "quit via AppleScript"
if [[ -f "$DB" ]]; then
    check "sqlite: AppleScript note persisted after quit" "AS $STAMP" "$(sql "select body from note where id = $AS_ID;")"
fi

echo
echo "passed $PASS, failed $FAIL, skipped $SKIP   (data: $DATA, log: $LOG)"
[[ $FAIL == 0 ]]
