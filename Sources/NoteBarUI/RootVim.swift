import AppKit
import NoteBarCore

/// Vim keys outside the editor (`env.settings.vimKeybinds`), and the card commands the editor sends
/// (`EditorEvent.vim`).
///
/// Root view (no text being edited):
/// - Folder list: j / k select, l / ↩ open, R / r / cw rename, o new folder, gg / G first / last,
///   gp pin, gc color menu, gx / dd delete (with the usual alert, undoable). Letters no longer type
///   into search.
/// - Notes list and search results: j / k select, l / ↩ edit, h goes back (like ←), gg / G, and the
///   card keys on the selected note without editing it: gp gc gm gy gx dd za zc zo.
/// - Everywhere: ⌃W J / ⌃W K edit the next / previous card, ⌃[ goes up (like ⌘[), / starts search.
extension NotesRootViewController {
    static let vimWindowChordTimeout: TimeInterval = 1.5

    var vimEnabled: Bool { env.settings.vimKeybinds }

    // MARK: Root keys

    /// Plain and ⌃ keys while the root view has focus. True = used.
    func handleVimRootKey(_ event: NSEvent) -> Bool {
        guard vimEnabled else { return false }
        let mods = event.modifierFlags.intersection([.command, .shift, .option, .control])
        let lower = event.charactersIgnoringModifiers?.lowercased() ?? ""
        if let armed = vimWindowArmedAt {
            vimWindowArmedAt = nil
            if Date().timeIntervalSince(armed) <= Self.vimWindowChordTimeout, mods.isEmpty || mods == [.control] {
                if lower == "j" { vimFocusCard(from: activeNoteIDForVim, delta: 1); return true }
                if lower == "k" { vimFocusCard(from: activeNoteIDForVim, delta: -1); return true }
            }
            if mods == [.control], lower == "w" { vimWindowArmedAt = Date(); return true }
        }
        if mods == [.control] {
            if event.keyCode == 33 { goBack(); return true }
            if lower == "w" { vimWindowArmedAt = Date(); return true }
            return false
        }
        guard mods.isEmpty || mods == [.shift], let ch = event.characters, ch.count == 1 else {
            vimListPrefix = nil
            return false
        }
        if let prefix = vimListPrefix {
            vimListPrefix = nil
            if Date().timeIntervalSince(prefix.at) <= Self.vimWindowChordTimeout,
               ch.unicodeScalars.allSatisfy({ CharacterSet.letters.contains($0) }) {
                if !runVimListChord(prefix.key + ch) { NSSound.beep() }
                return true
            }
        }
        if ch == "/" { beginSearch(); return true }
        if ["g", "d", "z"].contains(ch) || (ch == "c" && !notesVisible) {
            vimListPrefix = (ch, Date())
            return true
        }
        if ch == "G" { moveSelection(10_000); return true }
        if notesVisible {
            switch ch {
            case "j": moveSelection(1); return true
            case "k": moveSelection(-1); return true
            case "l": activateSelection(); return true
            case "h":
                if search == nil { goBack() }
                return true
            default: break
            }
        } else {
            switch ch {
            case "j": moveSelection(1); return true
            case "k": moveSelection(-1); return true
            case "l": activateSelection(); return true
            case "R", "r":
                guard let id = folderList.selectedFolderID else { NSSound.beep(); return true }
                beginRenameFolder(id)
                return true
            case "o", "O":
                actions.newFolder()
                return true
            default: break
            }
        }
        // Other letters do nothing (they no longer start a search on the folder list / in results).
        if let scalar = ch.unicodeScalars.first, CharacterSet.alphanumerics.union(.punctuationCharacters).contains(scalar) {
            return true
        }
        return false
    }

    /// Two-key commands on the selected note / folder. False: not a command here (beep).
    func runVimListChord(_ chord: String) -> Bool {
        if chord == "gg" { moveSelection(-10_000); return true }
        if notesVisible {
            guard let id = notesList.selectedNoteID, let note = store.note(id: id) else { return false }
            switch chord {
            case "gp": actions.togglePin(id)
            case "gc": popUpCardMenu(MenuBuilder.gearMenu(for: note, actions: actions), for: id)
            case "gm": showMoveMenu(for: id)
            case "gy": actions.copyText(id)
            case "gx", "dd": actions.delete(id, confirm: false)
            case "za": actions.toggleFold(id)
            case "zc": actions.setFolded(true, id: id)
            case "zo": actions.setFolded(false, id: id)
            default: return false
            }
            return true
        }
        guard let id = folderList.selectedFolderID, let folder = store.folder(id: id) else { return false }
        switch chord {
        case "gp": actions.togglePinFolder(id)
        case "gc":
            let m = NSMenu()
            m.autoenablesItems = false
            m.addItem(.sectionHeader(title: "Color"))
            m.addItem(MenuBuilder.colorRowItem(current: folder.color, env: env) { [weak self] c in
                self?.actions.setFolderColor(c, id)
            })
            popUpFolderMenu(m, for: id)
        case "gx", "dd": actions.deleteFolder(id)
        case "cw": beginRenameFolder(id)
        default: return false
        }
        return true
    }

    /// Pops a menu up at the left of a folder row.
    func popUpFolderMenu(_ menu: NSMenu, for id: FolderID) {
        if let hook = menuPopUpHook { hook(menu); return }
        guard let row = folderList.row(for: id) else { return }
        folderList.scrollToVisible(row)
        menu.popUp(positioning: nil, at: NSPoint(x: 12, y: row.isFlipped ? row.bounds.maxY - 4 : row.bounds.minY + 4), in: row)
    }

    /// The card ⌃W J / K starts from: the edited card, else the selected one (nil: none).
    var activeNoteIDForVim: NoteID? {
        if let f = focusedNoteID, notesList.card(for: f) != nil { return f }
        if let s = notesList.selectedNoteID, notesList.card(for: s) != nil { return s }
        return nil
    }

    /// ⌃W J / ⌃W K: edit the neighbor card (in Normal mode). A folded card unfolds first.
    func vimFocusCard(from id: NoteID?, delta: Int) {
        guard notesVisible else { NSSound.beep(); return }
        let cards = notesList.cards
        guard !cards.isEmpty else { NSSound.beep(); return }
        let i = id.flatMap { cid in cards.firstIndex { $0.note.id == cid } }
        let j = i.map { $0 + delta } ?? (delta > 0 ? 0 : cards.count - 1)
        guard j >= 0, j < cards.count else { NSSound.beep(); return }
        let target = cards[j]
        setMouseHoverSuppressed(true)
        if target.isFolded {
            actions.setFolded(false, id: target.note.id)
            rootView.layoutSubtreeIfNeeded()
        }
        notesList.scrollToCard(target)
        target.focusEditor(atEnd: false)
        notesList.selectedNoteID = target.note.id
    }

    // MARK: Card commands from the editor

    func handleVimCommand(_ cmd: VimCardCommand, card: NoteCardView) {
        let id = card.note.id
        switch cmd {
        case .togglePin:
            actions.togglePin(id)
        case .toggleFold:
            setFoldedKeepingSelection(!(store.note(id: id)?.isFolded ?? false), id: id)
        case .setFolded(let folded):
            setFoldedKeepingSelection(folded, id: id)
        case .showColorMenu:
            popUpCardMenu(MenuBuilder.gearMenu(for: card.currentNote, actions: actions), for: id)
        case .setColor(let c):
            actions.setColor(c, for: id)
        case .setMode(let m):
            actions.setMode(m, for: id)
        case .showMoveMenu:
            showMoveMenu(for: id)
        case .moveToFolder(let name):
            vimMove(id, toFolderNamed: name)
        case .copyNote:
            actions.copyText(id)
        case .showFormatMenu:
            popUpCardMenu(MenuBuilder.formatMenu { [weak card] a in card?.performFormat(a) }, for: id)
        case .delete:
            actions.delete(id, confirm: false)
        case .quit:
            notesList.selectedNoteID = id
            focusRoot()
        case .focusNextCard:
            vimFocusCard(from: id, delta: 1)
        case .focusPreviousCard:
            vimFocusCard(from: id, delta: -1)
        case .navigateUp:
            goBack()
        case .message(let text):
            showToast(text)
        }
    }

    /// Folding the edited card ends editing; the card stays selected so j / k / ⌃W / ⌥⌘→ keep working.
    func setFoldedKeepingSelection(_ folded: Bool, id: NoteID) {
        actions.setFolded(folded, id: id)
        if folded, search == nil { select(id) }
    }

    /// `:move <name>`: exact name first (any case), then a name that starts with / contains it.
    func vimMove(_ id: NoteID, toFolderNamed raw: String) {
        guard let note = store.note(id: id) else { return }
        let name = raw.trimmingCharacters(in: .whitespaces).lowercased()
        let folders = store.folders()
        let match = folders.first { $0.name.lowercased() == name }
            ?? folders.first { $0.name.lowercased().hasPrefix(name) }
            ?? folders.first { $0.name.lowercased().contains(name) }
        guard let folder = match else { showToast("No folder “\(raw)”"); return }
        guard folder.id != note.folderId else { showToast("Already in “\(folder.name)”"); return }
        // The card leaves this list: end editing first (as for deletes).
        if let card = notesList.card(for: id), card.isEditorFocused { focusRoot() }
        actions.move(id, toFolder: folder.id)
    }

    /// Pops a menu up at the top-left of the card (like ⇧⌘M).
    func popUpCardMenu(_ menu: NSMenu, for id: NoteID) {
        if let hook = menuPopUpHook { hook(menu); return }
        guard let card = notesList.card(for: id) else { return }
        notesList.scrollToCard(card)
        let r = card.cardRect
        menu.popUp(positioning: nil, at: NSPoint(x: r.minX + 12, y: min(r.maxY - 8, r.minY + 40)), in: card)
    }

    /// ⌘/: search all folders from anywhere.
    func beginGlobalSearch() {
        beginSearch()
        if search?.allFolders == false { setSearchAllFolders(true) }
        header.focusSearchField()
    }
}
