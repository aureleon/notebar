# NoteBar

NoteBar is a notes panel for macOS. The panel slides in from the edge of the screen and floats above
all apps, including full-screen apps. Notes are cards in a list, and folders hold the cards.

NoteBar is a personal tool. It runs on macOS 26 on Apple Silicon only. It has no sync and no iOS app.

## Features

- **Ways to open the panel:**
  - the global hotkey (⌥⌘N by default)
  - the menu bar icon
  - Hot Side: move the pointer to the panel edge of the screen
  - the URL scheme and AppleScript
- **Notes:** the first line is the title. The editor hides the Markdown marks (bold, italic, code,
  highlight, headings, quotes, lists and checklists). Each note has a mode: Standard (Markdown),
  Plain Text or Code.
- **Attachments:** paste or drop images and files on the panel or on a card. Files show as tiles with a
  Quick Look thumbnail.
- **Organization:** folders, note colors, pinned notes and folders, folded notes, drag to reorder,
  move to a different folder (⌘⇧M), search in one folder or in all folders.
- **Look:** light and dark mode, themes, and Liquid Glass cards. To use solid cards, turn off
  Settings › Appearance › Glass cards.
- **Data:** a local SQLite database and automatic backups.

## Requirements

- macOS 26 on Apple Silicon.
- The Xcode Command Line Tools (Swift 6.4). The full Xcode app is not necessary.

## Build and run

Build the app into `build/NoteBar.app` and test it with an empty data folder:

```bash
scripts/build-app.sh --no-install
pkill -x NoteBar
NOTEBAR_DATA_DIR=$(mktemp -d) open build/NoteBar.app
```

Build the app and install it in `~/Applications` as your normal copy:

```bash
scripts/build-app.sh
open ~/Applications/NoteBar.app
```

The install step stops the NoteBar that runs now and replaces `~/Applications/NoteBar.app`. Only one
NoteBar can run at a time.

## Use

| Action | How |
|---|---|
| Show or hide the panel | ⌥⌘N, the menu bar icon, or Hot Side |
| New note | `+`, ⌘N, or ⌃⌥⌘N from any app |
| New note from the clipboard | ⌃⌥⌘V from any app |
| Search | ⌘F, or ⌃⌥⌘F from any app |
| Leave a note, then hide the panel | Esc |
| Go back to the folder list | ⌘[ or the back button |
| Settings | ⌘, |

You can change the global hotkeys in Settings › Shortcuts. You can move the panel to the left or right
side from the menu bar icon or in Settings › General.

When the pointer is on a card, the card shows these controls:

- The date and the pin button, in the top-right corner.
- A column of actions, in the bottom-right corner: format (`Aa`), copy the text, color and mode (gear),
  and delete. On a short card, the actions that do not fit go into a `…` menu.

## URL scheme and AppleScript

```text
notebar://new?text=…&folder=…&color=yellow&mode=code&show=1
notebar://show    notebar://hide    notebar://toggle
notebar://search?q=…
notebar://open?note=<id>
notebar://open?folder=<name>
```

The AppleScript commands are in `Resources/NoteBar.sdef`. They include `new note`, `search notes`,
`get note text`, `reveal note` and `list folders`. The Services menu has "New Note from Selection" and
"New Note with Files".

## Data

NoteBar keeps its data in `~/Library/Application Support/NoteBar`:

- `notebar.sqlite`, the database
- `attachments/`
- `Backups/`

If you set `NOTEBAR_DATA_DIR`, NoteBar uses that folder instead. Use a temporary folder for tests,
so that your real notes do not change.

## Project layout

The project uses Swift Package Manager. Each module depends only on `NoteBarCore` and on system
frameworks.

| Module | Contents |
|---|---|
| `NoteBarCore` | Models, the store and editor contracts, settings, themes |
| `NoteBarStore` | The GRDB store, backups, Markdown export |
| `NoteBarPanel` | The panel window, Hot Side, auto-hide, hotkeys, the menu bar icon |
| `NoteBarEditor` | The Markdown editor, attachments, the formatting toolbar |
| `NoteBarUI` | The panel content: header, folder list, note cards, search |
| `NoteBarIntegrations` | The URL scheme, Services, AppleScript |
| `NoteBarSettings` | The Settings window |
| `NoteBar` | The app: `AppDelegate`, the main menu, the single-instance lock |

The only dependency is [GRDB.swift](https://github.com/groue/GRDB.swift).

## Tests

XCTest is not available with only the Command Line Tools. The tests are executables:

```bash
swift run CoreChecks
swift run StoreChecks
swift run EditorChecks
swift run UISnapshot "$(mktemp -d)"         # renders PNGs offscreen and runs UI checks
swift run SettingsSnapshot "$(mktemp -d)"
scripts/smoke-integrations.sh                # URL scheme and AppleScript, with a temporary data folder
```

Before you run `scripts/smoke-integrations.sh`, quit NoteBar. Otherwise, the URLs go to the running
copy and its real data.

The offscreen snapshots cannot show these items. Test them by hand on the real screen:

- Liquid Glass and the blur behind the panel
- the panel over full-screen apps, and on all Spaces
- more than one display
- Hot Side, and focus
