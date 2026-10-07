# NoteBar — Scope (a side-panel notes app for macOS)

**Constraints:** personal tool, this Mac only (macOS 26.7, Apple Silicon/arm64).
No sync, no iOS app, no distribution.

## 1. What NoteBar is

A notes panel that slides in from the edge of the screen. It floats above all
apps, including full-screen apps and Stage Manager. You open it with a hotkey,
a small "Open Bar" tab on the edge, or by moving the cursor to the edge
("Hot Side"). Notes are cards in a scrolling list, grouped into folders.

Feature list, with scope:

| Area | Features | NoteBar |
|---|---|---|
| Access | Always-on-top side panel, hotkey, Open Bar tab, Hot Side (mouse to edge), works over full screen / Stage Manager | In |
| Organize | Folders, note colors, drag reorder, pin notes & folders, fold notes, move to folder (⌘⇧M), search | In |
| Content | Invisible Markdown, formatting toolbar, checklists, images, file & folder shortcuts, `#rrggbb` preview, code mode, snippets | In |
| Look | Themes, light/dark mode | Light/dark + 1–2 built-in themes. Custom theme editor is optional. |
| Data | Automatic backups, export note as image | In |
| Data | iCloud sync | **Out** |
| Integrations | URL scheme, AppleScript | In |
| Integrations | Share extension, native Shortcuts actions | **Out** (need Xcode). The Services menu and URL scheme cover the same needs. |
| Platform | Intel, macOS 13+, iOS app | **Out**. Build for arm64 on macOS 26 only. |

## 1a. Design

### Panel layout
- About 280–300 pt wide. Inset from the screen edge and the menu bar by about 8–10 pt.
  There is no window frame. Cards float over the desktop with gaps between them.
- **Header pill** (separate rounded bar at the top): back chevron, folder title
  (bold, accent color), search button, `+` button.
- **Open Bar:** a thin vertical pill on the inner side of the panel (left side when
  the panel is on the right). Click to toggle. Right-click to change sides.
- **Root view = folder list:** folder icon, name, note count on the right. Tap a folder
  to open it. The back chevron returns to the list.
- On macOS 26, try `NSGlassEffectView` (Liquid Glass) for the header pill and toolbar.

### Note card
- Rounded corners (about 16 pt), soft shadow, about 16 pt padding.
- **Title = first line**, bold, tinted with a darker shade of the note color.
- Body about 13 pt system font. Links are blue.
- **Footer** (on hover or focus): left group `Aa` (format) · share · gear;
  center calendar icon + date (`20/05/2026, 17:02`); right group export · trash.
- **Pin** button in the top-right corner on hover.
- **Folded:** only the title row, with a "+ N lines" badge on the right. Click to expand.
- **Colors:** none (white/dark) by default. Pastels: purple, yellow, blue, green, red/pink, cream.
  Show the color as the full background or as a left bar (setting).

### Content rendering
- Markdown styles: *italic*, **bold**, ***bold italic***, ~~strike~~, inline `code`
  (blue, monospaced), ==marked== (yellow-green highlight), quote (italic, brown),
  headers, code block (tinted rounded box, monospaced).
- Checklist: round checkbox. Checked = blue check mark in the circle.
- Image: inline, full card width, rounded corners.
- File shortcut: a rounded tile with a Quick Look thumbnail (`QLThumbnailGenerator`)
  and the file name below. Click to open.
- `#rrggbb`: a small filled circle in that color.

### Menus and toolbar
- **Formatting toolbar** (pill above the selection): copy · list | text color · heading |
  **B** · *I* · highlight · ~~S~~ · U · link | inline code · code block | clear formatting.
- **Gear menu:** a row of color circles, then note mode: *Standard (Markdown)*,
  *Plain Text*, *Code*.
- **Move menu:** Move to a New Folder (⌥⌘M); Within Folder: Move to Top, Move Up (⌥⇧⌘↑),
  Move Down (⌥⇧⌘↓), Move to Bottom; Move to Folder › submenu.

### Ways to create a note
`+` button · drag and drop onto the panel (text, image, file) · paste clipboard · global shortcut.
Dropping a file or image on an existing card adds it to that card.

### Ways to open
Click the Open Bar · global shortcut (⌃⌥⌘ + key) · menu bar icon · Hot Side.

## 2. Stack

- **Swift + AppKit for the shell, SwiftUI for the simple views.** The panel,
  the hot edge, and the text editor need AppKit. Settings can be SwiftUI.
- **Agent app** (`LSUIElement = YES`): no Dock icon. Add a menu bar item (`NSStatusItem`).
- **Deployment target: macOS 26.** Use the newest APIs freely. Do not add availability checks.
- **Storage:** local SQLite via GRDB (see 3.5).
- **Dependencies:** `GRDB.swift`, `KeyboardShortcuts` (sindresorhus). Nothing else.
- **No sandbox, no notarization, no Sparkle, no Apple Developer account.**

### Toolchain: SwiftPM only, no Xcode

Only Command Line Tools are installed (Swift 6.4). That is enough for the full scope.

- `Package.swift` with one executable target.
- `scripts/build-app.sh`: `swift build -c release`, assemble
  `NoteBar.app/Contents/{MacOS,Resources,Info.plist}`, ad-hoc sign
  (`codesign -s - --force --deep`), copy to `~/Applications/`.
- `Info.plist` holds `LSUIElement`, `CFBundleURLTypes` (URL scheme),
  `NSServices` (Services menu), and `OSAScriptingDefinition` (AppleScript).
- Ad-hoc signing is fine here. NoteBar needs no privacy permissions (the hotkey
  and hot edge need no Accessibility access), so the signature changing on each rebuild causes no problems.
- Launch at login: `SMAppService.mainApp.register()`. If that fails with an ad-hoc
  signature, fall back to a LaunchAgent plist in `~/Library/LaunchAgents/`.

## 3. Hard parts (where the effort goes)

### 3.1 The floating side panel (medium)
- Subclass `NSPanel`: `.borderless` + `.nonactivatingPanel`, `canBecomeKey = true`
  so you can type without the app taking focus from the frontmost app.
- `level = .statusBar` (or `.floating`).
- `collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]`
  to show over full-screen apps and on all Spaces.
- Slide in/out with `NSAnimationContext` on the frame. Use `NSScreen.visibleFrame`.
  Pick the screen that has the cursor (external displays). Watch `didChangeScreenParametersNotification`.
- Left or right edge, user-set width, auto-hide when focus goes elsewhere (optional pin-open mode).

### 3.2 Hot Side and Open Bar (low–medium)
- Put a 1–2 px transparent window on the edge with an `NSTrackingArea`.
  This needs no permissions. (A global `mouseMoved` monitor also works but costs more CPU.)
- Add a short delay so the panel does not open by accident. Ignore the edge while a mouse button is down (window drags).
- Open Bar = a small visible tab window on the same edge.

### 3.3 Global hotkey (low)
- Carbon `RegisterEventHotKey` (via `KeyboardShortcuts`). This needs no Accessibility permission.

### 3.4 The note editor (high — the largest risk)
- Each note is a card with an editable `NSTextView`. SwiftUI `TextEditor` cannot do this.
- **Invisible Markdown:** parse each paragraph on edit. Apply styles. Hide markup
  characters (`**`, `#`, `` ` ``) when the caret is not in that range. TextKit 2
  (`NSTextContentStorage` delegate / custom `NSTextLayoutFragment`) is the clean way.
  TextKit 1 with clear, near-zero-width attributes is the fast hack.
- Checklists: `- [ ]` rendered as a clickable checkbox attachment.
- Inline images and file shortcuts: `NSTextAttachment` + custom view providers.
  No sandbox, so file shortcuts can use plain bookmark data (no security scope).
- `#rrggbb`: draw a swatch next to the text.
- Code mode: monospaced font, no smart quotes, no autocorrect.
- Formatting toolbar: a small child panel that shows on text selection.
- Many text views in one scroll view cost performance. Use lazy loading, fold
  long notes, and keep only visible editors live.

### 3.5 Local storage and backups (low)
- One SQLite database (GRDB) in `~/Library/Application Support/NoteBar/`.
  Attachments go in a sibling `attachments/` folder.
- Save on every edit with a short debounce. Use WAL mode so writes are safe if the app crashes.
- Automatic backups: copy the database and attachments to a dated zip every day.
  Keep the last N copies. Add "Restore from backup" in Settings.
  Time Machine also covers Application Support.
- Optional: "Export all as Markdown" so the data is never locked in.

### 3.6 Integrations (low–medium)
- URL scheme `notebar://new?text=…&folder=…` (`CFBundleURLTypes`). This works with Alfred, Raycast, and
  the Shortcuts "Open URL" action.
- Services menu entry "New NoteBar note from selection" (`NSServices`). Works in
  any app's right-click menu. This replaces the share extension.
- AppleScript: `.sdef` file + `NSScriptCommand` subclasses. Shortcuts can call it with "Run AppleScript".
- No share extension and no App Intents. Both need Xcode and add little for one user.

## 4. Data model (first version)

```
Folder  { id, name, sortIndex, isPinned, color? }
Note    { id, folderId, body (markdown), color?, sortIndex, isPinned,
          isFolded, mode (standard|plain|code), createdAt, updatedAt }
Attachment { id, noteId, kind (image|fileBookmark), path|bookmarkData }
Theme   { id, name, JSON (colors, fonts, card style) }
```

Use fractional or gap-based `sortIndex` so drag reorder does not rewrite every row.

## 5. Phased plan

Estimates are for one experienced Swift/AppKit developer.

| Phase | Deliverable | Estimate |
|---|---|---|
| **0. Setup** | SwiftPM package, `build-app.sh`, menu bar item, agent app, launch at login | 0.5 day |
| **1. Panel MVP** | Inset panel with header pill, slide animation, hotkey, Hot Side, Open Bar (right-click to change sides), multi-display, full-screen support | 3–4 days |
| **2. Notes MVP** | Folder list (with counts) → note cards, plain-text editor, title = first line, card footer, create/delete/reorder, colors, SQLite storage, search, daily backup | 4–6 days |
| **3. Rich editor** | Invisible Markdown, checklists, formatting toolbar, gear menu (color + Standard/Plain/Code mode), fold with "+ N lines", pin, `#rrggbb` circles | 1.5–3 weeks |
| **4. Attachments** | Paste/drag images, file shortcuts with Quick Look thumbnails, drop onto a card or the panel, export note as image | 3–5 days |
| **5. Polish** | Settings window, light/dark themes, keyboard-first navigation, move menu + shortcuts, backup restore | 4–6 days |
| **6. Integrations** | URL scheme, Services menu, AppleScript | 2–4 days |

- **Useful daily-driver MVP (phases 0–2):** about 1.5–2 weeks.
- **Full personal scope (phases 0–6):** about 5–7 weeks.
- You can stop after any phase. Each phase leaves a working app.

## 6. Risks

1. **Editor quality.** Hidden Markdown with stable caret movement, undo, and IME input is hard.
   Prototype this early (spike in phase 2). Fallback: show the Markdown markup in a dimmed color instead of hiding it. This is much easier and still looks clean.
2. **Focus behavior.** Typing in a non-activating panel and then giving focus back to the previous app has edge cases (full screen, Stage Manager, secure input fields).
3. **macOS 26 window behavior.** Test the panel over full-screen apps and Stage Manager early, in phase 1.

## 7. Open decisions

None blocking. Defaults if you do not say otherwise:
- Panel on the right edge, hotkey ⌥⌘N, Hot Side on.
- Visual style follows section 1a. Exact sizes are set by eye.
- Phase 3 starts with the dimmed-markup fallback, then adds hidden markup if time allows.
