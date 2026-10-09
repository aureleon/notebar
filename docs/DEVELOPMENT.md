# NoteBar development

## Requirements

- macOS 26 on Apple Silicon.
- The Xcode Command Line Tools (Swift 6.4). The full Xcode app is not necessary.

Because only the Command Line Tools are necessary, these items are not available: XCTest,
swift-testing, and the SwiftUI `@State` and `#Preview` macros. Use `ObservableObject` with
`@ObservedObject` or `@Binding` in SwiftUI.

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

## Data folder

NoteBar keeps its data in `~/Library/Application Support/NoteBar`:

- `notebar.sqlite`, the database (SQLite, WAL mode)
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
| `NoteBarPanel` | The panel window, Hot Side (swipe to edge), auto-hide, hotkeys, the menu bar icon |
| `NoteBarEditor` | The Markdown editor, attachments, the formatting toolbar |
| `NoteBarUI` | The panel content: header, folder list, note cards, search |
| `NoteBarIntegrations` | The URL scheme, Services, AppleScript |
| `NoteBarSettings` | The Settings window |
| `NoteBar` | The app: `AppDelegate`, the main menu, the single-instance lock, snapshot modes |

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
- Hot Side (swipe to edge), and focus

## README pictures

The pictures in `docs/images/` are rendered from code, offscreen. No window opens, and your real
notes do not change. To make them again after a UI change:

```bash
scripts/readme-images.sh
```

The script builds NoteBar and runs `NoteBar --readme-images` with a new temporary data folder. Then
it converts the PNGs to WebP with `cwebp` (`brew install webp`), to keep the repository small. The sample notes are in `Sources/NoteBar/ReadmeImages.swift`. Each picture shows light mode
on the left and dark mode on the right. Liquid Glass cannot be captured offscreen, so the pictures
show solid cards.

`NoteBar --snapshot <dir>` renders more panel states with the real editor, for visual checks.
