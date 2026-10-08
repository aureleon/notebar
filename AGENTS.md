# AGENTS.md — Developer & Agent Guide for NoteBar

Welcome! NoteBar is a native macOS notes panel designed for Apple Silicon (macOS 26+). It floats over all windows (including full-screen spaces and Stage Manager), sliding in from the screen edge.

---

## 1. Toolchain & Build Constraints

> **CRITICAL**: The environment runs with **Xcode Command Line Tools only** (Swift 6.4, Swift 5 language mode). Full Xcode is **not** installed.

- **No SwiftUI `@State` or `#Preview` macros**: These will fail to compile. Use `ObservableObject` + `@ObservedObject` or `@Binding`.
- **No `XCTest` or `swift-testing`**: Unit and integration tests are standalone Swift CLI executables using `NoteBarCore.Check` (e.g. `Check.equal`, `Check.expect`).
- **No `KeyboardShortcuts` framework**: Carbon hotkeys are registered directly via Carbon APIs (`RegisterEventHotKey`).
- **External Dependency**: Only `GRDB.swift` (v7.0.0+) via SwiftPM.

---

## 2. Quick Commands

### Build
```bash
swift build                                  # Debug build
scripts/build-app.sh --no-install            # Production app in build/NoteBar.app
scripts/build-app.sh                         # Install to ~/Applications/NoteBar.app
```

### Run Checks & Tests
```bash
swift run CoreChecks                         # Models, settings, contracts
swift run StoreChecks                        # SQLite/GRDB storage, backups, migrations
swift run EditorChecks                       # Markdown parser, codec, text styling
swift run SettingsSnapshot /tmp/nb-settings  # Settings UI checks & offscreen PNGs
swift run UISnapshot /tmp/nb-ui              # Notes UI checks & offscreen PNGs
scripts/check-integrations.sh                # URL scheme & AppleScript, offline (no app launch)
```

### Safe Manual Execution
```bash
NOTEBAR_DATA_DIR=$(mktemp -d) build/NoteBar.app/Contents/MacOS/NoteBar
```

---

## 3. Architecture & Module Map

The codebase is split into modular Swift Package Manager targets. Every target depends only on `NoteBarCore` and system frameworks.

```
                  ┌────────────────┐
                  │    NoteBar     │ (App target: AppDelegate, MainMenu, Lock)
                  └───────┬────────┘
     ┌───────────┬────────┼────────┬───────────┬────────────┐
     ▼           ▼        ▼        ▼           ▼            ▼
NoteBarUI  NoteBarEditor  │  NoteBarSettings NoteBarStore NoteBarIntegrations
     │           │        │        │           │            │
     └───────────┴────────┼────────┴───────────┴────────────┘
                          ▼
                    NoteBarPanel
                          │
                          ▼
                    NoteBarCore (Contracts, Models, Settings, Theme)
```

| Module | Location | Purpose | Key Types |
|---|---|---|---|
| `NoteBarCore` | `Sources/NoteBarCore/` | Domain models, persistence & editing contracts, settings, themes. | `Note`, `Folder`, `NoteStore`, `NotesPresenting`, `AppSettings`, `HotSideArea` |
| `NoteBarStore` | `Sources/NoteBarStore/` | SQLite database via GRDB (WAL mode), migrations, zip backups. | `GRDBNoteStore`, `FileBackupService`, `MarkdownExporter` |
| `NoteBarPanel` | `Sources/NoteBarPanel/` | Floating panel window, edge trigger (Hot Side), auto-hide, hotkeys. | `PanelController`, `NoteBarPanelWindow`, `HotSideController`, `PassiveOpenTracker`, `AutoHideMonitor`, `HotkeyCenter` |
| `NoteBarEditor` | `Sources/NoteBarEditor/` | Markdown editor with hidden markup, attachments, formatting toolbar. | `MarkdownNoteEditor`, `MarkdownCodec`, `MarkdownStyler`, `FormattingToolbar` |
| `NoteBarUI` | `Sources/NoteBarUI/` | Notes list, folder view, header pill, card layout, glass cards. | `NotesRootViewController`, `HeaderView`, `NotesListView`, `NoteCardView`, `FolderListView` |
| `NoteBarSettings` | `Sources/NoteBarSettings/` | SwiftUI settings window (General, Appearance, Shortcuts, Data, About). | `SettingsWindowController`, `GeneralPane`, `AppearancePane`, `LaunchAtLogin` |
| `NoteBarIntegrations` | `Sources/NoteBarIntegrations/` | URL scheme (`notebar://`), Services menu, AppleScript support. | `URLSchemeHandler`, `ServicesProvider`, `ScriptCommands` |
| `NoteBar` | `Sources/NoteBar/` | Application entry point and lifecycle. | `AppDelegate`, `InstanceLock`, `SnapshotMode` |

---

## 4. Key Architectural Patterns

### Coordinates & Flipped Views
- **Global screen coordinates (AppKit)**: Origin is at the **bottom-left** of the screen (`y = 0` is bottom). Used in `PanelGeometry`, `HotSideController`, `PassiveOpenTracker`, `AutoHideMonitor`.
- **Panel view coordinates (`isFlipped: true`)**: Origin is at the **top-left** (`y = 0` is top). Used in `NotesRootView`, `HeaderView`, `NotesListView`, `FolderListView`.

### Panel Lifecycle & Passive Opens
- **Active Open** (`makeKey: true`): Triggered by hotkey (⌥⌘N), menu bar icon, or URL scheme. Takes keyboard focus.
- **Passive Open** (`makeKey: false`): Triggered by swipe to edge (Hot Side) or file drag. Does **not** steal focus from the user's active app.
- **`PassiveOpenTracker`**: Watches mouse position during passive opens.
  - Active hover zone (`passiveZone`): Strictly bounded to the **rendered content region** of the panel (`contentHeight` from `NotesPresenting`) rather than the full screen height.
  - Exit delay: 0.25 s (250 ms) after the cursor leaves the active region, with 50 ms polling.
  - User engagement: If the user clicks the panel, it becomes key and passive mode disengages.

### Hot Side Trigger (Swipe to Edge)
- **Opt-in**: Disabled by default (`settings.hotSideEnabled = false`).
- **Trigger Modes (`HotSideArea`)**:
  - `.corner`: Top 120 pt on the active panel side (upper-right or upper-left).
  - `.quadrant`: Upper half of the side edge.
  - `.edge`: Full side edge (with top menu bar and bottom corners excluded).
  - `.dynamic`: Follows NoteBar's content height (`hi - contentHeight ... hi`).

### Header Pill Controls (`HeaderView`)
- Top-level (folder list): Displays **`settings - search - new`** (`[⚙] [🔍] [+]`).
- Inside a folder: Settings icon is hidden; displays **`[<] Folder Title`** and **`[🔍] [+]`**.

### Settings & State Management
- `AppSettings.shared`: Persisted in `UserDefaults`.
- Posts `Notification.Name.appSettingsDidChange` with `userInfo["key"]`. AppKit components observe this notification or bind to `AppSettings` directly.

---

## 5. Operational Rules for Agents

1. **Never Touch User Data**: Always set `NOTEBAR_DATA_DIR` to a temporary directory when running NoteBar during tests or verification. Never write to `~/Library/Application Support/NoteBar`.
2. **No Interactive Screen Windows**: Do not display windows on the user's screen during test runs. Use `UISnapshot` and `SettingsSnapshot` to render offscreen PNGs.
3. **Clean Up Processes**: Kill any spawned test instances of `NoteBar` after running verification scripts (`pkill -x NoteBar`).
4. **Active Install**: When requested to update the active install, use `scripts/build-app.sh` (which builds the release binary, installs to `~/Applications/NoteBar.app`, and refreshes Launch Services).
5. **Request User Feedback for Design Decisions**: Before making design, UX, visual layout, or architectural decisions that involve trade-offs or multiple valid directions, agents MUST ask the user for feedback and confirmation (e.g. via structured questions) rather than assuming or deciding unilaterally.
