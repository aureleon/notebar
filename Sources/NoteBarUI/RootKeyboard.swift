import AppKit
import NoteBarCore

/// Keyboard-first navigation and panel shortcuts.
extension NotesRootViewController {
    private enum Key {
        static let returnKey: UInt16 = 36, enter: UInt16 = 76, tab: UInt16 = 48, space: UInt16 = 49
        static let delete: UInt16 = 51, forwardDelete: UInt16 = 117, escape: UInt16 = 53
        static let left: UInt16 = 123, right: UInt16 = 124, down: UInt16 = 125, up: UInt16 = 126
        static let leftBracket: UInt16 = 33
        static let home: UInt16 = 115, end: UInt16 = 119
    }

    private var notesVisible: Bool { search != nil || screen != .folders }

    func rootFocusChanged(_ focused: Bool) {
        notesList?.showsSelection = focused
        folderList?.showsSelection = focused
    }

    // MARK: Plain keys (root view is first responder)

    func handleKeyDown(_ event: NSEvent) -> Bool {
        let mods = event.modifierFlags.intersection([.command, .shift, .option, .control])
        guard mods.isEmpty || mods == [.shift] else { return false }
        switch event.keyCode {
        case Key.escape:
            handleEscape(); return true
        case Key.up:
            moveSelection(-1); return true
        case Key.down:
            moveSelection(1); return true
        case Key.home:
            moveSelection(-10_000); return true
        case Key.end:
            moveSelection(10_000); return true
        case Key.returnKey, Key.enter:
            activateSelection(); return true
        case Key.right:
            if !notesVisible { folderList.openSelected(); return true }
            return false
        case Key.left:
            if notesVisible && search == nil { goBack(); return true }
            return false
        case Key.space:
            if notesVisible, let id = notesList.selectedNoteID {
                actions.toggleFold(id)
                return true
            }
            return false
        case Key.delete, Key.forwardDelete:
            if notesVisible, let id = notesList.selectedNoteID { actions.delete(id, confirm: true); return true }
            return false
        case Key.tab:
            if search != nil { header.focusSearchField(); return true }
            return false
        default:
            // Typing while the folder list or the search results have focus: type into the search field.
            if let ch = event.characters, ch.count == 1, let scalar = ch.unicodeScalars.first,
               CharacterSet.alphanumerics.union(.punctuationCharacters).contains(scalar),
               search != nil || screen == .folders {
                let text = (search?.query ?? "") + ch
                beginSearch()
                header.searchField.stringValue = text
                searchQueryChanged(text)
                let len = (text as NSString).length
                header.searchField.currentEditor()?.selectedRange = NSRange(location: len, length: 0)
                return true
            }
            return false
        }
    }

    func handleEscape() {
        if header.isSearchFieldFocused { searchFieldEscape(); return }
        if isEditingText {
            // Text view that did not handle Escape itself: stop editing.
            if let id = focusedNoteID { notesList.selectedNoteID = id }
            focusRoot()
            return
        }
        if search != nil { endSearch(restore: true, focusRoot: true); return }
        if case .folder = screen { showFolderList(); focusRoot(); return }
        env.controller?.hidePanel()
    }

    func moveSelection(_ delta: Int) {
        if notesVisible {
            let ids = notesList.noteIDs
            guard !ids.isEmpty else { return }
            var next: NoteID
            if let sel = notesList.selectedNoteID, let i = ids.firstIndex(of: sel) {
                next = ids[max(0, min(ids.count - 1, i + delta))]
            } else {
                next = delta >= 0 ? ids[0] : ids[ids.count - 1]
            }
            if delta == 10_000 { next = ids[ids.count - 1] } else if delta == -10_000 { next = ids[0] }
            select(next)
        } else {
            folderList.moveSelection(delta)
        }
    }

    func activateSelection() {
        if notesVisible {
            guard let id = notesList.selectedNoteID, let note = store.note(id: id) else {
                if let first = notesList.cards.first { select(first.note.id) }
                return
            }
            if note.isFolded && search == nil {
                actions.setFolded(false, id: id)
                rootView.layoutSubtreeIfNeeded()
            }
            guard let card = notesList.card(for: id) else { return }
            notesList.scrollToCard(card)
            card.focusEditor(atEnd: true)
        } else {
            if folderList.selectedFolderID == nil { folderList.moveSelection(1) } else { folderList.openSelected() }
        }
    }

    // MARK: Shortcuts with modifiers

    func handleKeyEquivalent(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown else { return false }
        let mods = event.modifierFlags.intersection([.command, .shift, .option, .control])
        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
        let code = event.keyCode

        switch mods {
        case [.command]:
            switch code {
            case Key.leftBracket:
                goBack(); return true
            case Key.delete:
                // ⌘⌫ deletes the selected note; inside text it keeps its text meaning.
                guard !isEditingText, notesVisible, let id = activeNoteID else { return false }
                actions.delete(id, confirm: true); return true
            case Key.returnKey, Key.enter:
                guard isEditingText, let id = focusedNoteID else { return false }
                notesList.selectedNoteID = id
                focusRoot(); return true
            default: break
            }
            switch key {
            case "n":
                createNoteFromShortcut(); return true
            case "f":
                beginSearch(); return true
            case "v":
                guard !isEditingText else { return false }
                pasteAsNewNote(); return true
            case "1", "2", "3", "4", "5", "6", "7", "8", "9":
                // The root runs before its subviews. While text is being edited, the editor gets ⌘digit
                // first (⌘1–⌘3 = headings in Standard mode). Only keys it does not use switch folders.
                if isEditingText, let editor = view.window?.firstResponder as? NSView,
                   editor.performKeyEquivalent(with: event) {
                    return true
                }
                openFolder(atShortcutIndex: Int(key)! - 1); return true
            default: return false
            }
        case [.command, .shift]:
            switch key {
            case "m":
                guard let id = activeNoteID else { NSSound.beep(); return true }
                showMoveMenu(for: id); return true
            case "n":
                actions.newFolder(); return true
            default: return false
            }
        case [.command, .option]:
            if key == "m" || code == 46 {
                guard let id = activeNoteID else { NSSound.beep(); return true }
                actions.moveToNewFolder(id); return true
            }
            return false
        case [.command, .option, .shift]:
            guard code == Key.up || code == Key.down else { return false }
            guard search == nil, let id = activeNoteID else { NSSound.beep(); return true }
            actions.move(id, code == Key.up ? .up : .down)
            return true
        default:
            return false
        }
    }

    /// ⌘N: a new note in the open folder (at the folder list: in the selected / last folder).
    func createNoteFromShortcut() {
        createNewNote()
    }

    func showMoveMenu(for id: NoteID) {
        guard let note = store.note(id: id), let card = notesList.card(for: id) else { return }
        notesList.scrollToCard(card)
        let menu = MenuBuilder.moveMenu(for: note, actions: actions)
        let r = card.cardRect
        menu.popUp(positioning: nil, at: NSPoint(x: r.minX + 12, y: min(r.maxY - 8, r.minY + 40)), in: card)
    }
}
