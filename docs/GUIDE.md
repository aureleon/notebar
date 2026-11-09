# NoteBar user guide

This guide tells you about all the features of NoteBar. For a short introduction, see the
[README](../README.md).

## Open the panel

- Push ⌥⌘N (Option-Command-N). You can change this key in Settings › Shortcuts.
- Click the NoteBar icon in the menu bar.
- Swipe to edge: move the pointer to the edge of the screen. This is off by default. To turn it on,
  go to Settings › General › Swipe to edge. You can select the part of the edge that opens the panel:
  - **Corner**: the top 120 points of the edge.
  - **Quadrant**: the upper half of the edge.
  - **Edge**: all of the edge, except the menu bar and the bottom corner.
  - **Dynamic**: the part of the edge next to the notes that show in the panel.
- Use a link or a script. See [Automation](AUTOMATION.md).

When you open the panel with swipe to edge or when you drag a file to the edge, NoteBar does not
take the keyboard from the app you use. The panel closes again when the pointer goes away from it.
Click the panel to type in it.

To move the panel to the left or the right side of the screen, use the menu bar icon or
Settings › General.

## Keyboard shortcuts

| Action | How |
|---|---|
| Show or hide the panel | ⌥⌘N, the menu bar icon, or swipe to edge (if it is on) |
| New note | `+`, ⌘N, or ⌃⌥⌘N from any app |
| New note from the clipboard | ⌃⌥⌘V from any app |
| Search | ⌘F (⌘/ searches all folders), or ⌃⌥⌘F from any app |
| Scratch note | ⌃⌥⌘S from any app, or the Scratch button on the folder list |
| Earlier or later Scratch day | ⇧⌘[ and ⇧⌘], or ◀ and ▶ in the header |
| Go through the search results | Tab and ⇧Tab (from the search field, through the results, back to the field) |
| Leave a note, then hide the panel | Esc |
| Go back to the folder list | ⌘[ or the back button |
| Fold or unfold a note | ⌥⌘← and ⌥⌘→ (also while you type), or the fold button |
| Archive or unarchive a note | ⌥⌘A (also while you type), or the archive button on the card |
| Archive a folder | ⌥⌘A on the selected folder, or Archive Folder in its menu |
| Move a note to a different folder | ⌘⇧M |
| Settings | ⌘, |

You can change the shortcuts that work from any app in Settings › Shortcuts. For a list of all keys,
see [Keybindings](KEYBINDINGS.md).

## Notes

- The first line of a note is its title.
- Each note has a mode:
  - **Standard**: Markdown. The editor hides the Markdown marks and shows the styles (bold, italic,
    code, highlight, headings, quotes, lists and checklists). To see the marks, turn off
    Settings › Appearance › Hide Markdown markup.
  - **Plain Text**: no styles.
  - **Code**: a monospaced font.
- To add a picture or a file, paste it, or drop it on the panel or on a card. A file shows as a tile
  with a preview.
- Text such as `#ff8800` shows a small sample of the color.
- When you check an item in a checklist, it moves below the open items. Click **N completed** under
  the open items to hide or show the checked items. Each note keeps this setting. To keep items
  where they are, turn off Settings › Appearance › Move checked items to the bottom.
- To add lines under a list or checklist item without starting a new item, press ⇧↩. The lines
  line up with the item's text and move with the item. Press ↩ on an empty one to go back to a new
  item.
- An item with lines or items under it shows a small arrow after its text. Click it
  to hide or show them; each note remembers this. When you check an item, the lines under it are
  struck through and hidden. Click the arrow to see them again.

## The controls on a card

![A note card with its controls](images/note-actions.webp)

When the pointer is on a card, the card shows these controls:

- In the top-right corner: the date and the pin button. Below the pin are the expand and fold
  buttons. A pinned note always shows its pin. An expanded note always shows its collapse button.
- In the bottom-right corner: copy the text, archive, and delete.
- A folded note shows a `+ N lines` button. Click it to unfold the note.

The bottom-left corner of an unfolded card always shows two buttons:

- `Aa` opens the formatting menu. Only Standard notes have it.
- The Color & Mode button sets the color and the mode of the note. Its icon shows the mode: ¶ for
  Standard, `{ }` for Code, and ≡ for Plain. On Code and Plain notes, it takes the place of `Aa`.

## Folders

- Folders hold your notes. You can give a folder a color, and pin it to the top of the list.
- Drag notes and folders to change their order.
- Search finds notes in the open folder. Click **All Folders** above the results to search all
  folders.

![Search in all folders](images/search.webp)

## Undo and deleted items

- ⌘Z and ⇧⌘Z undo and redo note and folder actions: color, mode, fold, pin, order, move, rename,
  new note, new folder and delete. While you type in a note, ⌘Z undoes the text only.
- Before NoteBar deletes an item, it asks you. This is true for keys, for the trash button on a card,
  and for menus. A deleted note or folder goes to the trash. To get it back, click Undo on the
  message, or push ⌘Z.
- Settings › Data › Keep deleted items sets how long deleted items stay: until NoteBar quits, for
  1 hour (the default), or for 30 days. Until then, you can find them in **Recently Deleted**, a row
  at the end of the folder list. Click it to restore an item, to delete it now, or to empty the list.
  Delete Now also asks you first.

## Archive

- To move a note to the archive, push ⌥⌘A or click the archive button. To get it back, click Undo
  on the message, or push ⌘Z.
- The **Archive** row at the end of the folder list shows the archived notes of all folders. The
  most recently archived note is first. Each card shows its folder. To put a note back in its folder,
  at its old position, push ⌥⌘A or click the button again.
- Search does not show archived notes. To find them too, turn on the **Archive** chip above the
  results. A search in the Archive finds only archived notes.
- You cannot move an archived note to a different folder. Unarchive it first.

### Archived folders

- To archive a folder, right-click it and choose **Archive Folder**, or select it and push ⌥⌘A
  (`ga` with vim keys). The folder and its notes leave the folder list. Undo on the message, or ⌘Z,
  brings it back. You cannot archive the last folder.
- While a folder is archived, a click on the **Archive** row opens a menu: **Archived Notes** opens
  the archived notes, and each archived folder has **Open**, **Unarchive**, and **Delete Folder…**.
- An open archived folder shows its notes. You can edit them, but you cannot add notes or move them
  to a different folder.
- Unarchive puts the folder back in the folder list with its notes. If another folder has the same
  name now, the folder gets a number ("Work 2"). Notes that you archived on their own stay archived.
- Search finds the notes of archived folders only with the **Archive** chip, or in the Archive.
- A deleted archived folder goes to Recently Deleted. If you restore it, it goes back to the archive.

## Scratch

The Scratch note is a throwaway note for the day: quick notes, a phone number, a to-do for this
afternoon. Every day it starts empty. To keep something, save it as a note.

- To open it, push ⌃⌥⌘S from any app, click the Scratch button (the pencil) on the folder list, or
  choose **Scratch Note** in the menu bar icon's menu. NoteBar opens today's note, ready to type.
- The note is a log of entries, newest at the end. Each time you open it to type, a new entry starts
  below a thin line. The line shows the time when 30 minutes or more passed since the last time
  shown. If your last edit is less than 2 minutes old, you continue the last entry instead. An entry
  you leave empty goes away.
- To change an earlier entry, click into it. That does not start a new entry. Backspace at the start
  of an entry joins it with the entry above.
- Older entries are dimmer, so the newest one stands out. The entry you edit shows in full.
- Right-click in an entry for **Save Entry as Note**, **Copy Entry**, **Mark Entry Done** (the entry
  is struck through) and **Delete Entry**.
- ◀ and ▶ in the header (⇧⌘[ and ⇧⌘]) go to the earlier days that still have text. You can read and
  copy earlier days, but you cannot change them.
- **Save as Note** (the button on the card, or right-click) puts a copy in a folder you choose.
  The Scratch note keeps its text. In the copy, a rule (`---`) stands for each line between
  entries, with the time below it where the line showed one.
- On today's card, the eraser button clears the note (Undo brings the text back). On an earlier day,
  the trash button deletes that day.
- Search, the archive, pins and folds do not apply to Scratch notes. The card shows no date: the
  header names the day and the entries show their times.
- Settings › General › Scratch:
  - **Daily Scratch note** turns the feature on (the default) or off. When it is off, the button, the
    menu item and the shortcut go away. The notes stay until they expire.
  - **Keep earlier days** (1 to 30, 7 by default): older days go to Recently Deleted as normal notes
    in your last folder, with their date as the first line. Settings › Data › Keep deleted items sets
    how long they stay there. If you restore one, it is a normal note. Empty days are not kept.
  - **New day starts at** (4 AM by default): until this hour, you still write in the day before.

## Look

- NoteBar has light and dark mode, and themes. You can make your own theme in Settings › Appearance.
- Cards use Liquid Glass. To use solid cards, turn off Settings › Appearance › Glass cards.
- A note color can fill the card, or show as a bar on the left side of the card.

![The Appearance settings](images/settings-appearance.webp)

## Vim keys

Vim keys are off by default. To turn them on, go to Settings › Shortcuts › Use Vim keys.

- A note opens in Normal mode, with a block cursor. A new, empty note opens in Insert mode.
- These standard vim keys work: motions, counts, operators (`d` `c` `y`), `p` `P` `u` `⌃R` `r` `.`,
  Visual mode (`v` `V`), search (`/` `?` `n` `N`) and `:` commands.
- ⌃W J and ⌃W K edit the next and the previous note. A folded note unfolds.
- On a selected note that you do not edit, `gp` `gc` `gm` `gy` `ge` `ga` `gx` `dd` `za` `zc` `zo`
  also work. `gg` and `G` select the first and the last note.

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
| Archive or unarchive the note | `ga`, `:archive`, `:unarchive` |
| Delete the note (with the usual alert, undoable) | `gx`, `:delete` (`dd` on a selected note) |
| Stop editing | `:q` |
| Go up to the folder list | ⌃[ (in Insert mode, ⌃[ is Esc) |
| Folder list | `j` `k` select, `gg` `G` first and last, `l` or Return opens, `o` new folder |
| Selected folder | `R` or `cw` rename, `gp` pin, `gc` color, `gx` or `dd` delete (with the usual alert) |

## Your data

NoteBar keeps your notes on your Mac only, in `~/Library/Application Support/NoteBar`:

- `notebar.sqlite`: the database with your notes
- `attachments/`: your pictures and files
- `Backups/`: automatic backups

You can make a backup, restore a backup, and export all notes as Markdown files in Settings › Data.
