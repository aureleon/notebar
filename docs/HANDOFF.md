# NoteBar — Handoff: fix round 2

Status on 2026-10-07: the app builds, all checks pass, and the app runs. The work so far is in jj
(`NoteBar: integrate modules, audit fixes`). This file lists the next round of work:
three changes the user asked for (part A) and the open problems from the last verification (part B).

Read `docs/SCOPE.md` first. Where this file and SCOPE.md disagree, this file wins.

## 0. How to work in this repo

**Layout.** One SwiftPM module per area. All modules depend only on `NoteBarCore`.

| Module | Folder | Contents |
|---|---|---|
| Core | `Sources/NoteBarCore/` | Models, `NoteStore` and `NoteEditing` contracts, `AppSettings`, themes |
| Store | `Sources/NoteBarStore/` | GRDB store, backups, Markdown export |
| Panel | `Sources/NoteBarPanel/` | Panel window, Hot Side, auto-hide, hotkeys, status item |
| Editor | `Sources/NoteBarEditor/` | Markdown editor, attachments, formatting toolbar |
| UI | `Sources/NoteBarUI/` | Panel content: header, folder list, note cards, search |
| Integrations | `Sources/NoteBarIntegrations/` | URL scheme, Services, AppleScript |
| Settings | `Sources/NoteBarSettings/` | Settings window |
| App | `Sources/NoteBar/` | `AppDelegate`, main menu, `--snapshot` mode, single-instance lock |

**Build and check:**
```
swift build
swift run CoreChecks
swift run StoreChecks
swift run EditorChecks
swift run UISnapshot /tmp/nb-ui            # offscreen PNGs plus behavior checks
swift run SettingsSnapshot /tmp/nb-set
scripts/build-app.sh --no-install          # build/NoteBar.app
NOTEBAR_DATA_DIR=$(mktemp -d) build/NoteBar.app/Contents/MacOS/NoteBar --snapshot /tmp/nb-app   # real UI to PNG
scripts/smoke-integrations.sh              # URL scheme and AppleScript, runs a temporary app copy
```

**Toolchain limits.** Only Command Line Tools are installed (Swift 6.4, macOS 26 SDK).
- SwiftUI `@State` and `#Preview` do not compile. Use `ObservableObject` with `@ObservedObject`.
- XCTest and swift-testing are not available. Tests are the `*Checks` executables, which use `NoteBarCore.Check`.
- KeyboardShortcuts does not build. Hotkeys use Carbon directly (`NoteBarPanel/HotkeyCenter.swift`).

**Rules:**
- If several agents work at the same time:
  - Each agent edits only its own module.
  - Each agent builds with its own `--scratch-path .build-agents/<name>`.
- **Data:**
  - Always set `NOTEBAR_DATA_DIR` to a temporary folder when you run the app.
  - Never touch `~/Library/Application Support/NoteBar`.
- **The user's screen:**
  - Do not show windows on the user's screen. Render offscreen to PNG instead.
  - Do not use `screencapture`.
  - Kill every app process that you start.
- **Version control:**
  - Commit with jj only when the user asks.
  - Before you start, run `jj st` and check that no other agent is still writing files.
  - A pi restart (for example, a VS Code update) stops workflows, but it can leave partial edits.
- **Cannot be tested offscreen:** behind-window blur, the panel over full-screen apps, Spaces, multiple
  displays, Hot Side and focus. Write these down in the final report for a manual check.

---

## A. Changes the user asked for (do these first)

### A1. Remove the Open Bar completely

The user does not like the Open Bar. It looks like a badly designed scroll bar. Remove the feature;
do not only hide it.

**Ways to open the panel after this change:**
- the global hotkey
- the menu bar icon
- Hot Side
- URL scheme and AppleScript

The user changes the panel side in the status-item menu ("Move to Left/Right Side",
`StatusItemController.swift:105`) and in Settings › General. The Open Bar right-click menu goes away.

**Steps:**
1. Delete `Sources/NoteBarPanel/OpenBar.swift` (`OpenBarController`, `OpenBarWindow`).
2. `PanelController.swift`:
   - Remove the `openBar` property and its wiring at lines 31, 48, 61 and 70–95.
   - Remove all `openBar.update(...)` calls (lines 145, 203, 285, 332, 335).
   - Remove `toggleFromOpenBar()` (line 237).
   - Remove the union with the Open Bar frame (lines 175–178).
   - Remove `"showOpenBar"` from the settings switch (line 313).
3. `PanelGeometry.swift`:
   - Remove the `openBar*` constants (lines 13–23), `openBarFrame`, `clampedOpenBarCenterY` and `clampOpenBarOffset`.
   - In `width`, the "fit" computation must no longer subtract the Open Bar width.
4. `AutoHideMonitor.swift:166`: remove `OpenBarWindow` from the check.
5. `StatusItemController.swift:107–108`: remove the "Show Open Bar" item.
6. `NoteBarSettings/GeneralPane.swift:71`: remove the "Show Open Bar" toggle.
7. `NoteBarCore/Settings.swift`: remove `showOpenBar`. Also remove the old UserDefaults keys
   `showOpenBar` and `openBarOffset` once at launch.
8. Update `docs/SCOPE.md` (§1 Access, §1a Panel layout, §1a Ways to open, §3.2, phase 1) so that it
   does not ask for the Open Bar again.
9. Run `rg -i "open ?bar"` over `Sources/`, `scripts/` and `docs/SCOPE.md`. It must return no
   results, except for this file.

**Check:** the build passes, and the panel still opens with the hotkey, the menu bar icon and the URL scheme.

### A2. Blurred backdrop behind the whole panel (like Notification Center)

**Problem.** The panel is transparent. Cards float over the desktop and the app windows, so with a
busy background it is hard to see what is going on. The user wants a blur behind the whole panel area,
like the macOS Notification Center and widget panel. There, a soft blurred and slightly darkened area
fills the screen edge behind the widgets and fades out toward the center of the screen.

**Design:**
- **Window.** Use a separate borderless *backdrop window* per panel, one level below the panel:
  - Use the same `collectionBehavior` as the panel, so the backdrop shows over full-screen apps and on all Spaces.
  - Set `ignoresMouseEvents = true`. Clicks outside the panel must still reach other apps, and auto-hide
    must still work.
  - Set `isOpaque = false`, a clear background and `hasShadow = false`.
- **Size.**
  - Height: the full height of the screen (`screen.frame`).
  - Width: from the screen edge on the panel side to about 100–140 pt beyond the inner edge of the panel.
- **Content.**
  - Use `NSVisualEffectView` with `blendingMode = .behindWindow` and `state = .active`.
  - The material must look like Notification Center. Try `.hudWindow`, `.fullScreenUI` and `.underWindowBackground`,
    then pick by eye. On macOS 26 also try `NSGlassEffectView` if it can blur large areas.
  - Set a `maskImage` with a horizontal gradient: fully opaque from the screen edge to the inner edge of
    the panel, then a smooth fade to transparent over the extra 100–140 pt. No hard edge.
  - Add a light tint that follows the appearance. Dark mode: black at about 15–25 %. Light mode: white
    or black at about 5–10 %. Pick by eye, so the cards stand out.
- **Animation.** The backdrop fades in and out (alpha) together with the panel slide (same duration,
  `PanelMetrics.animationDuration`). It must not slide.
- **Updates.** The backdrop follows the panel: screen changes, side changes, width changes and
  `didChangeScreenParametersNotification`.
- **Reduce Transparency.** When `NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency` is on,
  use a solid tinted fill and no blur.
- **Setting.** Add an AppSettings toggle "Blur background behind panel", on by default, in Settings ›
  Appearance.
- **Inside the panel.** Do not change how the cards look. The panel keeps its near-invisible
  hit-test fill (`PanelContentView.hitTestFill`). Gaps between cards must still take clicks, scrolls and drops.

**Where:** a new file `Sources/NoteBarPanel/PanelBackdrop.swift`. Drive it from `PanelController`
`show`/`hide`/`layout`, next to the panel frame code.

**Check:**
- An offscreen snapshot cannot show a behind-window blur. Check only the gradient mask and the tint in a PNG.
- Ask the user to check the real look on screen.

### A3. Make the notes larger: wider panel, bigger text

**Problem.** The notes are too small. They should take up more of the screen. Today the panel is 290 pt
wide (about 19 % of a 14" MacBook Pro screen), with 13 pt text.

**Changes (sizes are by eye; show the user and adjust):**
- **Default width depends on the screen.** Use about 27 % of `visibleFrame.width`, clamped to 380…600 pt.
  That is about 410 pt on a 1512 pt wide screen.
  - Keep a user-set width. Implement this as "nil = automatic": make `panelWidth` optional, or add a
    `panelWidthIsAutomatic` flag.
  - When the user resizes with the resize handle (`PanelController.swift:56`), the width becomes fixed.
  - Add a "Default" button next to the width slider in Settings that goes back to automatic.
- **Width limits.** `PanelMetrics.minWidth` becomes 280 and `maxWidth` becomes 720. Change them in the
  same way in `GeneralPane.swift:9–13, 49`.
- **Migration.** A saved `panelWidth` of 290 (the old default) becomes automatic, once.
- **Text.** Theme `fontSize` default goes from 13 to 14 (`Theme.swift:40` and the built-in themes).
  Scale the title, code font, footer date and folder rows with it. Do not hard-code 13 in the UI or the
  editor: run `rg "ofSize: 1[0-9]"` and make the results relative to `env.themes.fontSize`.
- **Spacing.**
  - Card padding: about 18 pt.
  - Gap between cards: about 10 pt.
  - Header pill height: in proportion to the new width.
  - Change these in `NoteBarUI/UIStyle.swift` (`Metrics`).
- **Hard-coded 290.** Replace each one with the new default:
  - `NoteBarPanelWindow.swift:17`
  - `PanelController.swift:43`
  - `PanelGeometry.swift:45`
  - `NoteCardView.swift:69`
  - `HeaderView.swift:40`
  - `NotesRootViewController.swift:71`
  - `UISnapshot/main.swift:88`
  - `SnapshotMode.swift:102`
- Optional: a "Text size" setting (Small 13 / Medium 14 / Large 16) in Settings › Appearance.

**Check:** render the snapshots at the new width and check the proportions by eye.

---

## B. Open problems from the last verification

Each problem was seen in the snapshots or in the test runs. Check the cause first, then fix it.

### B1. `notebar://show` and `toggle` sometimes leave the panel hidden (Panel, Integrations)
- **Symptom.** In `scripts/smoke-integrations.sh`, `notebar://show` or `notebar://toggle (on)` failed in 2 of 3 runs.
- **Likely cause.** `open -g` delivers the URL while another app stays active. Then
  `AutoHideMonitor` (`didResignActive` / `didActivateApplication` observers, lines 100–103, and the
  click logic around line 227) hides the panel right after it opens.
- **Earlier change.** The last fixer only changed the test script, by hiding the panel after launch.
  The race itself is not fixed.
- **Fix.**
  - After a programmatic `show` (URL, AppleScript, hotkey, status item), ignore activation changes for
    a short time (about 0.5 s).
  - Only a real user click outside the panel should hide it.
  - Add a check that runs show → wait 1 s → is it still visible, 10 times in a row, inside
    `smoke-integrations.sh`.

### B2. The spell checker underlines Markdown syntax (Editor)
- **Symptom.** Red dots under `#rrggbb`, inline code, URLs, `<u>` and color tags, and code blocks. They
  also show on cards that are not being edited.
- **Where.** `MarkdownNoteEditor.swift:130–148`.
- **Fix.**
  - Show spell-check dots only in the editor that has focus.
  - In that editor, skip the ranges of code spans, code blocks, URLs, hex colors, tags and attachment
    tokens. Use the `NSTextViewDelegate` `textView(_:shouldSetSpellingState:range:)` method, or remove
    `.spellingState` from those ranges after each check.
  - `.code` mode already turns spell check off. Keep that.

### B3. Search highlights only some matches, and the highlight is too faint (Editor, UI)
- **Symptom.** For the query "list", the title of the first result is marked, but "2. list" in the second
  card is not marked. The highlight is a pale gray. It is hard to see on cream cards.
- **Where.**
  - `MarkdownNoteEditor.highlightSearch` (line 686).
  - `NoteCardView.highlightSearchMatch` (line 251).
  - `NotesListView.swift:149` and `NotesRootViewController.swift:550` call it only for the *first* card.
- **Fix.**
  - Call it for every result card, including cards whose editor loads later.
  - Mark *all* matches with a temporary attribute (for example, a yellow background at the theme
    `highlight` color), not with the selection.
  - Use `showFindIndicator` only for the first match of the first card.
  - Clear the marks when the search ends.

### B4. Cards waste space at the bottom; folded cards are too tall (UI)
- **Symptom.** Each card has about 40–60 px of empty space under its last line, because space for the
  hover footer stays reserved (`NoteCardView.swift:333`). A folded card is about 70 pt tall for a 20 pt
  title row. The folded title is 2 pt smaller and about 2 pt further right than the expanded title.
- **Fix.**
  - Do not reserve space for the footer. Show it on hover or focus as an overlay over the bottom of
    the card, with a short fade.
  - Another way: let the card grow with an animation when the footer shows. Then no other card may move
    while the pointer is on the card.
  - Folded card = title row and padding only.
  - The folded and expanded titles must have the same font, size and x position.
- Also fix: the tall snapshots are about 45 % empty below the last card, because the
  snapshot height is computed wrong in `SnapshotMode.swift`.

### B5. Lines wrap in code blocks and code notes (Editor)
- **Symptom.** In `snippet.swift`, `func greet(_ name: String) -> String {` breaks after `->`.
- **Where.** `EditorStyle.swift:134` sets `.byWordWrapping` for all paragraphs.
- **Fix.**
  - Code blocks and `.code` mode notes must not wrap.
  - Make long lines scroll horizontally inside the code box. Another way: use char-wrapping with a
    visible continuation indent.
  - Pick the way that works with the "no internal scrolling" height contract in `NoteEditing`, and
    explain the choice.

### B6. The formatting toolbar is wider than the panel (Editor)
- **Symptom.** The toolbar is about 372 pt wide and the panel was 290 pt, so it hung out over the other app.
- **Where.** `Toolbar/FormattingToolbar.swift`.
- **Fix.**
  - Keep the toolbar inside the panel frame.
  - If it does not fit, move the rarely used buttons into a "…" overflow menu: text color, code block,
    clear formatting, and copy.
  - After A3 the panel is wider, but the toolbar must still fit at the minimum width (280 pt).

### B7. File-shortcut tile is misaligned, and its thumbnail is useless (Editor)
- **Symptom.** When a tile follows text on the same line, the text sits at the bottom of a line about
  160 px tall. The Quick Look thumbnail of a `.txt` file is a nearly blank white square.
- **Where.** `Attachments/AttachmentCells.swift`.
- **Fix.**
  - Always put a file tile on its own line, like an image. The codec must stay lossless.
  - Center the tile on its line, or use `cellBaselineOffset` so that the text lines up.
  - For text-like files (plain text, source code, Markdown, JSON), show the file icon
    (`NSWorkspace.icon(forFile:)`), not the Quick Look thumbnail. Use Quick Look for images, PDFs and
    other documents.

### B8. Smaller issues seen in the snapshots (UI, Settings)
- **Folder colors.** The folder title in the header was blue in light mode and amber in dark mode, while
  the folder icon in the dark folder list stayed blue. Use one accent per appearance everywhere.
- **Search bar.** The "N results" chip and the Notes / All Folders toggle have different heights. The
  gap above the first result is about 5–10 pt; use the normal card gap.
- **Settings tiles.** The note color style tiles always show light-mode pastels, even in dark mode.

---

## C. Manual checks for the user (agents cannot run these)

After `scripts/build-app.sh` installs the app to `~/Applications`:
1. **Hotkey.** ⌥⌘N opens the panel over a normal app, over a full-screen app, over Stage Manager, and
   on a second display (on the screen with the pointer).
2. **Typing.** You can type in a note without the frontmost app losing focus. Esc and a click outside hide
   the panel. Menus, the Save panel, Quick Look and Settings do not hide it.
3. **Hot Side.** It opens after the delay. It does not open while you drag a window or use the Dock, and
   it does not block hot corners.
4. **Backdrop.** The blur looks right (A2) in light mode, in dark mode and with Reduce Transparency on.
5. **Size.** The new panel size and text size (A3) feel right.
6. **Integrations.** Services › "New Note from Selection" works in Safari and in TextEdit.
7. **Launch at login.** It works after a restart, and NoteBar starts only once.

## D. Definition of done

- Part A done. The build and every check in §0 pass. `smoke-integrations.sh` passes 5 times in a row.
- B1–B7 fixed, or rejected with evidence. B8 fixed.
- The snapshot PNGs were checked again at the new size, in light and dark mode.
- A short report lists what changed, what could not be checked offscreen, and the C items for the user.
