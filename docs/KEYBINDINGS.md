# NoteBar keybindings (inventory)

Taken from the code.
**Where** = the state that must be active for the key to work.

Contexts:
- **Global**: system-wide Carbon hotkeys. You can change them in Settings → Shortcuts.
- **Panel**: the panel is key (any state inside it).
- **List**: the root view has focus and no text is being edited. This covers the folder list, the notes list, and search results.
- **Editor**: a note's text view has focus. Without vim this is plain editing; with vim it is Insert mode.
- **Vim Normal / Visual / Prompt**: the editor with Settings → Vim keybinds on.

## 1. Global hotkeys (configurable)

| Key | Action | Source |
|---|---|---|
| ⌥⌘N | Show / hide panel | `HotkeyAction.defaults` |
| ⌃⌥⌘N | New note | ″ |
| ⌃⌥⌘V | New note from clipboard | ″ |
| ⌃⌥⌘F | Search notes | ″ |
| ⌥⇧⌘N | Float / stay open (also handled inside the panel) | ″, `NoteBarPanelWindow`, `RootKeyboard` |

## 2. Panel-wide (key equivalents)

| Key | Where | Action | Source |
|---|---|---|---|
| ⌘N | Panel (also while editing) | New note in the open folder | `RootKeyboard.handleKeyEquivalent` |
| ⇧⌘N | Panel | New folder | ″ |
| ⌘F | Panel | Search in the folder | ″ |
| ⌘/ | Panel | Search all folders | ″ |
| ⌘[ | Panel | Back (folder → folder list) | ″ |
| ⇧⌘E | Panel (also while editing) | Expand / collapse the active note | ″ |
| ⇧⌘M | Panel | Move menu for the active note | ″ |
| ⌥⌘M | Panel | Move the active note to a new folder | ″ |
| ⌥⌘← / ⌥⌘→ | Panel, notes visible | Fold / unfold the active note | ″ |
| ⌥⌘A | Panel, notes visible (also while editing) | Archive / unarchive the active note | ″ |
| ⌥⇧⌘↑ / ↓ | Panel, not in search | Move the active note up / down | ″ |
| ⌘⌫ | List | Delete the selected note (alert) | ″ |
| ⌘↩ | Editor | Stop editing, keep the card selected | ″, `MarkdownTextView.keyDown` |
| ⌘V | List | Paste the clipboard as a new note | ″ |
| ⌘Z / ⇧⌘Z | List | Panel undo / redo (note and folder actions) | ″ |
| ⌘Z / ⇧⌘Z | Editor | Text undo / redo | `MainMenu`, `NoteBarPanelWindow` |
| ⌘X ⌘C ⌘V ⌘A | Editor / fields | Cut / copy / paste / select all | ″ |
| ⌥⇧⌘V | Editor | Paste and match style | ″ |
| ⌘W | Panel | Hide the panel | `NoteBarPanelWindow` |
| ⌘, | Panel | Settings | ″, `MainMenu`, status menu |
| ⌘Q | App menu / status menu | Quit | `MainMenu`, `StatusItemController` |

## 3. List (root view, not editing)

| Key | Folder list | Notes list / search results | Source |
|---|---|---|---|
| ↑ / ↓ | Select row (folders, then Archive and Recently Deleted) | Select card | `RootKeyboard.handleKeyDown` |
| Home / End | First / last row | First / last card | ″ |
| ↩ / Enter | Open folder / the archive / the Recently Deleted menu | Edit the card (unfolds it first) | ″ |
| → | Open folder | — | ″ |
| ← | — | Back to the folder list (not in search) | ″ |
| ⌫ / ⌦ | — | Delete the selected card (alert) | ″ |
| Tab / ⇧Tab | — | Search: next / previous result | ″ |
| Esc | Hide panel | Collapse expanded card → close search → clear selection → hide panel | `handleEscape` |
| Letters / punctuation (vim off) | Start a search with that letter | Search results: add to the query | ″ |

## 4. List, vim keys on (`RootVim.handleVimRootKey`)

| Key | Folder list | Notes list / search results |
|---|---|---|
| j / k | Select next / previous | Select next / previous |
| l | Open folder | Edit the card |
| h | — | Back (not in search) |
| gg / G | First / last | First / last |
| / | Search | Search |
| ⌃[ | Back | Back |
| ⌃W J / ⌃W K | — | Edit the next / previous card |
| r, R, cw | Rename folder | — |
| o, O | New folder | — |
| gp | Pin folder | Pin note |
| gc | Folder color menu | Color / Mode menu |
| gx, dd | Delete folder (alert) | Delete note (alert, undoable) |
| gm | — | Move menu |
| gy | — | Copy the note text |
| ge | — | Expand / collapse |
| ga | — | Archive / unarchive |
| za / zc / zo | — | Toggle / fold / unfold |
| Other letters | Swallowed (do nothing) | Swallowed |

## 5. Editor, all modes (plain editing, or vim Insert mode)

| Key | Action | Notes | Source |
|---|---|---|---|
| ⌘B / ⌘I / ⌘U | Bold / italic / underline | Standard mode | `shortcutAction(for:)` |
| ⇧⌘X | Strikethrough | ″ | ″ |
| ⇧⌘H | Highlight | ″ | ″ |
| ⌘K | Link | ″ | ″ |
| ⌘E | Inline code | Standard mode | ″ |
| ⌥⌘C | Code block | ″ | ″ |
| ⌘' | Quote | ″ | ″ |
| ⌘\ | Clear formatting | ″ | ″ |
| ⇧⌘8 | Bulleted list | ″ | ″ |
| ⇧⌘7 | Numbered list | ″ | ″ |
| ⇧⌘L, ⇧⌘9 | Checklist | **Two keys for one action** | ″ |
| ⌘1 / ⌘2 / ⌘3 | Heading 1 / 2 / 3 | Standard mode | `headingShortcutLevel` |
| ⌘0 | Plain paragraph | ″ | ″ |
| ↩ | New line; continues lists and code indent | ⇧↩ = plain line break | `handleCommand` |
| Tab / ⇧Tab | Indent / outdent list items (Code mode: indent lines) | | ″ |
| ↑ on the first line / ↓ on the last line | Edit the previous / next card | | ″ |
| Esc | Plain: leave the card. Vim Insert: go to Normal mode. | | ″, vim |
| ⌃W (vim Insert) | Delete the word before the caret | | `handleInsertKey` |
| ⌃[ (vim Insert) | Same as Esc | | ″ |

## 6. Vim Normal mode (editor)

| Key | Action |
|---|---|
| h j k l, Space, ⌫ | Move (j / k by visual line; gj / gk the same) |
| w W b B e E | Word motions |
| 0 ^ _ $ | Line start / first text / line end |
| gg G {n}G + ↩ | File start / end / line n / next line |
| {count} | Repeat the next command |
| i a I A o O | Insert mode |
| x X s ⌦ | Delete / change characters |
| d{m} c{m} y{m}, dd cc yy | Operators |
| D C S Y | To end of line / whole line |
| r{c} | Replace characters |
| p P | Paste |
| u, ⌃R | Undo / redo |
| . | Repeat the last change |
| v V | Visual / Visual Line |
| / ? n N | Search |
| : | Command line (see section 8) |
| Esc | Clear pending keys → clear search marks → leave the card |
| ⌃[ | Clear pending keys, else **go back a level (like ⌘[)**. Esc leaves the card instead. |
| ⌃W J / ⌃W K / ⌃W ⌃W | Edit the next / previous / next card |
| Tab | Nothing (swallowed) |
| za / zc / zo | Toggle / fold / unfold the card |
| gp gc gm gy ge ga gx | Pin / color menu / move menu / copy / expand / archive / delete (alert) |
| gf | Format menu (Standard notes only). The list has no gf. |
| Other ⌃ keys | Swallowed |
| Arrows, Home/End, PgUp/PgDn | Standard text-view movement; ↑ / ↓ at the first / last line go to the next card |

## 7. Vim Visual / Visual Line

| Key | Action |
|---|---|
| Motions as in Normal (h j k l w b e 0 ^ $ gg G + ↩ ⌫) | Extend the selection |
| v / V | Switch type or exit |
| o / O | Swap the ends |
| d x / D X | Delete (chars / lines) |
| c s / C S R | Change (chars / lines) |
| y / Y | Yank |
| p / P | Paste over (P keeps the register) |
| u / U / ~ | Lowercase / uppercase / toggle case |
| r{c} | Replace every selected character |
| Esc, ⌃[ | Exit |
| Tab, arrows, ⌃ keys | Swallowed |

## 8. Vim prompt and `:` commands

| Key | Action |
|---|---|
| ↩ | Run / search |
| Esc, ⌃[, ⌃C | Cancel (search: back to the start position) |
| ⌫ | Delete a character (empty prompt: close) |
| ⌃U | Clear the line |

| Command | Action |
|---|---|
| :w | Save |
| :q :q! :wq :x :exit | Stop editing, keep the card selected |
| :{n} | Go to line n |
| :noh | Clear search marks |
| :pin :p :unpin | Toggle pin |
| :fold :fo / :unfold :foldopen | Fold / unfold |
| :copy :y :yank :co | Copy the note text |
| :delete :d :del | Delete the note (alert) |
| :archive / :unarchive | Archive / unarchive the note |
| :format :fmt | Format menu |
| :color [name] | Color menu, or set the color |
| :mode [standard\|code\|plain] | Mode menu, or set the mode |
| :move [folder] :m :mv | Move menu, or move to the folder |

## 9. Text fields

| Field | Key | Action |
|---|---|---|
| Search field | Esc | Clear the query; when empty, close search |
| ″ | ↓ | Select the first result |
| ″ | ↩ | Edit the first result |
| ″ | Tab / ⇧Tab | Select the first / last result |
| ″ | ⌃[ (vim) | Back |
| Folder rename | ↩ / Esc | Save / cancel |
| Settings window | ⌘W, ⌘X ⌘C ⌘V ⌘A ⌘Z ⇧⌘Z | Close, editing |

## 10. Overlaps and duplicates

| Action | Keys today | Problem |
|---|---|---|
| Fold / unfold | ⌥⌘← / ⌥⌘→ · za zc zo · :fold / :unfold · fold button / menu | Fixed: Space and Tab no longer fold. |
| Delete note | ⌫ ⌦ · ⌘⌫ · dd / gx · :d | Fixed: every key path shows the alert. |
| Expand | ⇧⌘E · ge | Fixed: ⌘E is Inline code only. |
| ⌘1–⌘3 | Headings while editing | Fixed: ⌘digits no longer open folders. |
| Checklist | ⇧⌘L and ⇧⌘9 | Two keys for one action. |
| Leave / back | Esc (leave card) · ⌃[ (go back a level) · ⌘[ · ← · h | In vim, Esc and ⌃[ differ. In Vim Insert mode, ⌃[ = Esc. |
| Next / previous card while editing | ↑ / ↓ at the text edges · ⌃W J / K | |
| Search | ⌘F · ⌘/ · / (vim) · typing on the folder list (vim off) · ⌃⌥⌘F global | |
| Move note | ⇧⌘M · gm · :move · ⌥⌘M (new folder) · ⌥⇧⌘↑ / ↓ | |
| Float panel | ⌥⇧⌘N global and in the panel | Handled in 2 places (global hotkey + key equivalent). |
| Undo | ⌘Z = panel undo in the list, text undo in the editor | Same key, two histories. |
| ⌘V | Paste in the editor · new note from the clipboard in the list | Same key, two meanings. |
