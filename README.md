# NoteBar

NoteBar is a notes panel for macOS. The panel slides in from the edge of the screen and floats above
all apps, including full-screen apps. Notes are cards in a list, and folders hold the cards.

NoteBar is a personal tool. It runs on macOS 26 on Apple Silicon only. It has no sync and no iOS app.

## Features

- **Ways to open the panel:**
  - the global hotkey (⌥⌘N by default)
  - the menu bar icon
  - Swipe to edge (Hot Side): move the pointer to the panel edge of the screen (opt-in; enable in Settings › General)
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
| Show or hide the panel | ⌥⌘N, the menu bar icon, or swipe to edge (if enabled) |
| New note | `+`, ⌘N, or ⌃⌥⌘N from any app |
| New note from the clipboard | ⌃⌥⌘V from any app |
| Search | ⌘F (⌘/ searches all folders), or ⌃⌥⌘F from any app |
| Go through the search results | Tab and ⇧Tab (from the search field, through the results, back to the field) |
| Leave a note, then hide the panel | Esc |
| Go back to the folder list | ⌘[ or the back button |
| Fold or unfold a note | ⌥⌘← and ⌥⌘→ (also while you type), or the fold button |
| Settings | ⌘, |

You can change the global hotkeys in Settings › Shortcuts. You can move the panel to the left or right
side from the menu bar icon or in Settings › General.

When the pointer is on a card, the card shows these controls:

- The date and the pin button in the top-right corner, with the expand and fold buttons below the
  pin. A pinned note always shows its pin, and an expanded note always shows its collapse button. A folded
  note shows a `+ N lines` button: click it to unfold the note.
- A row of actions in the bottom-right corner: copy the text, color and mode (gear), and delete.

The format button (`Aa`) is always shown in the bottom-left corner of an unfolded card.

### Undo and deleted items

- ⌘Z and ⇧⌘Z undo and redo note and folder actions: color, mode, fold, pin, order, move, rename,
  new note, new folder and delete. While you type in a note, ⌘Z undoes the text only.
- A deleted note or folder goes to the trash. Undo on the toast, or ⌘Z, brings it back.
- Settings › Data › Keep deleted items sets how long deleted items stay: until NoteBar quits, for
  1 hour (the default), or 30 days in Recently Deleted. Recently Deleted is a row at the end of the
  folder list. Click it to restore an item, delete it now, or empty the list.

### Vim keys

Vim keys are off by default. To turn them on, go to Settings › Shortcuts › Use Vim keys.

- A note opens in Normal mode, with a block cursor. A new, empty note opens in Insert mode.
- These standard vim keys work: motions, counts, operators (`d` `c` `y`), `p` `P` `u` `⌃R` `r` `.`,
  Visual mode (`v` `V`), search (`/` `?` `n` `N`) and `:` commands.
- ⌃W J and ⌃W K edit the next and the previous note. A folded note unfolds.
- On a selected note that you are not editing, `gp` `gc` `gm` `gy` `ge` `gx` `dd` `za` `zc` `zo` work
  too, and `gg` `G` select the first and the last note.

NoteBar adds these keys:

| Action | Keys |
|---|---|
| Pin the note | `gp`, `:pin` |
| Fold the note | `za` `zc` `zo`, `:fold`, `:unfold` |
| Color and mode | `gc`, `:color [name]`, `:mode [standard\|code\|plain]` |
| Move to a folder | `gm`, `:move [folder]` |
| Copy the note | `gy`, `:copy` |
| Expand or collapse the card | `ge` (like ⇧⌘E) |
| Formatting menu | `gf` |
| Delete the note (with the usual alert, undoable) | `gx`, `:delete` (`dd` on a selected note) |
| Stop editing | `:q` |
| Go up to the folder list | ⌃[ (in Insert mode, ⌃[ is Esc) |
| Folder list | `j` `k` select, `gg` `G` first and last, `l` or Return opens, `o` new folder |
| Selected folder | `R` or `cw` rename, `gp` pin, `gc` color, `gx` or `dd` delete (with the usual alert) |

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
scripts/check-integrations.sh                # URL scheme and AppleScript, offline (does not launch NoteBar)
```

The offscreen snapshots cannot show these items. Test them by hand on the real screen:

- Liquid Glass and the blur behind the panel
- the panel over full-screen apps, and on all Spaces
- more than one display
- Hot Side, and focus
