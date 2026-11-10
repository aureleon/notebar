import AppKit
import NoteBarCore

/// Vim keys outside the editor (`env.settings.vimKeybinds`), and the card commands the editor sends
/// (`EditorEvent.vim`).
///
/// Root view (no text being edited):
/// - Notes list and search results: j / k select, l / ↩ edit, h goes back (like ←), gg / G, and the
///   card keys on the selected note without editing it: gp gc gm gy ge ga gx dd za zc zo. Deletes ask first.
///   gj / gk move the selected note down / up in its folder (like ⌥⇧⌘↓ / ↑; not in search results).
///   Letters do not type into search.
/// - gt / gT: the next / previous folder chip of the header (like ⌃Tab / ⌃⇧Tab).
/// - Everywhere: ⌃W J / ⌃W K edit the next / previous card, ⌃[ goes up (like ⌘[), / starts search.
///
/// Folders have no keyboard selection. From an editor: gt / gT too, `:folder <name>` (Tab completes),
/// `:scratch`, and on the open folder `:newfolder`, `:rename`, `:pinfolder`, `:archivefolder`,
/// `:deletefolder`. Color is in the chip's menu only.
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
        if ["g", "d", "z"].contains(ch) {
            vimListPrefix = (ch, Date())
            return true
        }
        if ch == "G" { moveSelection(10_000); return true }
        switch ch {
        case "j": moveSelection(1); return true
        case "k": moveSelection(-1); return true
        case "l": activateSelection(); return true
        case "h":
            // Back from the archive (like ←). A folder has nothing above it.
            if search == nil, isArchiveScreen { goBack() }
            return true
        default: break
        }
        // Other letters do nothing (they do not start a search in the results).
        if let scalar = ch.unicodeScalars.first, CharacterSet.alphanumerics.union(.punctuationCharacters).contains(scalar) {
            return true
        }
        return false
    }

    /// Two-key commands: gg, gt / gT, and those on the selected note. False: not a command here (beep).
    func runVimListChord(_ chord: String) -> Bool {
        if chord == "gg" { moveSelection(-10_000); return true }
        if chord == "gt" || chord == "gT" { stepFolderTab(chord == "gt" ? 1 : -1); return true }
        guard let id = notesList.selectedNoteID, let note = store.note(id: id) else { return false }
        switch chord {
        case "gp": actions.togglePin(id)
        case "gc": popUpCardMenu(MenuBuilder.gearMenu(for: note, actions: actions), for: id)
        case "gm": showMoveMenu(for: id)
        case "gj", "gk":
            // Reorder within the folder; search results are not a folder order.
            guard search == nil, !store.isInArchive(note) else { return false }
            actions.move(id, chord == "gj" ? .down : .up)
        case "gy": actions.copyText(id)
        case "ge": toggleExpand(id)
        case "ga": actions.toggleArchive(id)
        case "gx", "dd": actions.delete(id)
        case "za": actions.toggleFold(id)
        case "zc": actions.setFolded(true, id: id)
        case "zo": actions.setFolded(false, id: id)
        default: return false
        }
        return true
    }

    /// The card ⌃W J / K starts from: the edited card, else the selected one (nil: none).
    var activeNoteIDForVim: NoteID? {
        if let f = focusedNoteID, notesList.card(for: f) != nil { return f }
        if let s = notesList.selectedNoteID, notesList.card(for: s) != nil { return s }
        return nil
    }

    /// ⌃W J / ⌃W K: edit the neighbor card (in Normal mode). A folded card unfolds first.
    func vimFocusCard(from id: NoteID?, delta: Int) {
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
        if card.scratchRole != nil {
            switch cmd {
            case .togglePin, .toggleFold, .setFolded, .toggleArchive, .setArchived:
                showToast("Not available in Scratch"); return
            case .showColorMenu, .setColor, .setMode, .showFormatMenu where card.isReadOnly:
                showToast("Earlier days are read-only"); return
            default: break
            }
        }
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
        case .toggleExpand:
            toggleExpand(id)
        case .toggleArchive:
            actions.toggleArchive(id)
        case .setArchived(let archived):
            if store.note(id: id)?.isArchived != archived { setArchived(archived, id: id) }
        case .showFormatMenu:
            // Formatting exists in Standard notes only.
            guard card.currentNote.mode == .standard else { NSSound.beep(); return }
            popUpCardMenu(MenuBuilder.formatMenu { [weak card] a in card?.performFormat(a) }, for: id)
        case .delete:
            actions.delete(id)
        case .quit:
            notesList.selectedNoteID = id
            focusRoot()
        case .focusNextCard:
            vimFocusCard(from: id, delta: 1)
        case .focusPreviousCard:
            vimFocusCard(from: id, delta: -1)
        case .navigateUp:
            goBack()
        case .stepFolder(let delta):
            stepFolderTab(delta)
        case .openFolder(let name):
            guard let folder = vimFolder(named: name) else { showToast("No folder “\(name)”"); return }
            showFolder(folder.id)
            focusRoot()
        case .openScratch:
            guard env.settings.scratchEnabled else { showToast("Scratch is off"); return }
            showScratch(edit: true)
        case .newFolder(let name):
            actions.newFolder(named: name.isEmpty ? nil : name)
        case .renameFolder(let name):
            guard let fid = currentFolderId else { showToast("No folder is open"); return }
            if name.isEmpty { beginRenameFolder(fid) } else { actions.renameFolder(fid, to: name) }
        case .toggleFolderPin:
            guard let fid = currentFolderId else { showToast("No folder is open"); return }
            actions.togglePinFolder(fid)
        case .archiveFolder, .deleteFolder:
            guard let fid = currentFolderId else { showToast("No folder is open"); return }
            guard store.folders().count > 1 else { showToast("The last folder stays"); return }
            focusRoot()
            if cmd == .archiveFolder { actions.toggleArchiveFolder(fid) } else { actions.deleteFolder(fid) }
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
    /// The folder a `:` command names: the exact name, else the first that starts with it, else the
    /// first that contains it (any case).
    func vimFolder(named raw: String) -> Folder? {
        let name = raw.trimmingCharacters(in: .whitespaces).lowercased()
        let folders = store.folders()
        return folders.first { $0.name.lowercased() == name }
            ?? folders.first { $0.name.lowercased().hasPrefix(name) }
            ?? folders.first { $0.name.lowercased().contains(name) }
    }

    func vimMove(_ id: NoteID, toFolderNamed raw: String) {
        guard let note = store.note(id: id), !store.isInArchive(note) else { NSSound.beep(); return }
        guard let folder = vimFolder(named: raw) else { showToast("No folder “\(raw)”"); return }
        guard folder.id != note.folderId else { showToast("Already in “\(folder.name)”"); return }
        // The card leaves this list: end editing first (as for deletes). Scratch keeps its note (a copy is saved).
        if !note.isScratch, let card = notesList.card(for: id), card.isEditorFocused { focusRoot() }
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
