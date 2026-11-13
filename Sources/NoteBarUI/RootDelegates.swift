import AppKit
import NoteBarCore

// MARK: - Notes list

extension NotesRootViewController: NotesListDelegate {
    func notesList(_ list: NotesListView, card: NoteCardView, editorFocusChanged focused: Bool) {
        let id = card.note.id
        if focused {
            focusedNoteID = id
            list.selectedNoteID = id
        } else if focusedNoteID == id {
            focusedNoteID = nil
        }
        // Typing ended: a Scratch screen left on yesterday moves on to today.
        if !focused, isScratchScreen {
            DispatchQueue.main.async { [weak self] in self?.followTodayIfNeeded() }
        }
    }

    func notesList(_ list: NotesListView, card: NoteCardView, editorEvent event: EditorEvent) {
        switch event {
        case .escape:
            leaveCard()
        case .commit:
            list.selectedNoteID = card.note.id
            focusRoot()
        case .focusPrevious:
            moveEditing(from: card, delta: -1)
        case .focusNext:
            moveEditing(from: card, delta: 1)
        case .vim(let cmd):
            handleVimCommand(cmd, card: card)
        }
    }

    /// ↑ on the first line / ↓ on the last line: continue in the neighbor card.
    private func moveEditing(from card: NoteCardView, delta: Int) {
        let cards = notesList.cards
        guard let i = cards.firstIndex(where: { $0 === card }) else { return }
        let j = i + delta
        guard j >= 0, j < cards.count else { return }
        let target = cards[j]
        notesList.scrollToCard(target)
        if target.isFolded {
            select(target.note.id)
        } else {
            target.focusEditor(atEnd: delta < 0)
            notesList.selectedNoteID = target.note.id
        }
    }

    func notesList(_ list: NotesListView, menuFor card: NoteCardView) -> NSMenu? {
        if let role = card.scratchRole { return MenuBuilder.scratchContextMenu(for: card.currentNote, actions: actions, role: role) }
        return MenuBuilder.cardContextMenu(for: card.currentNote, actions: actions, inSearch: search != nil)
    }

    func notesList(_ list: NotesListView, clicked card: NoteCardView, event: NSEvent) {
        let id = card.note.id
        if card.isFolded {
            actions.setFolded(false, id: id)
            select(id)
        } else {
            list.selectedNoteID = id
            card.focusEditor(atEnd: true)
        }
    }

    func notesListBackgroundClicked(_ list: NotesListView) {
        list.selectedNoteID = nil
        focusRoot()
    }

    func notesListBackgroundMenu(_ list: NotesListView) -> NSMenu? {
        if isScratchScreen { return nil }
        let m = NSMenu()
        m.autoenablesItems = false
        m.addItem(ClosureMenuItem("New Note", key: "n", symbol: "square.and.pencil") { [weak self] in self?.createNewNote() })
        m.addItem(ClosureMenuItem("Paste as New Note", key: "v", symbol: "doc.on.clipboard",
                                  enabled: PasteboardImport.canImport(.general)) { [weak self] in self?.pasteAsNewNote() })
        m.addItem(.separator())
        m.addItem(ClosureMenuItem("Search", key: "f", symbol: "magnifyingglass") { [weak self] in self?.beginSearch() })
        return m
    }

    func notesList(_ list: NotesListView, dropOnBackground payload: ImportPayload) {
        // Scratch: a drop below the card goes into today's note.
        if isScratchScreen, let card = list.cards.first {
            if !card.isReadOnly { _ = notesList(list, drop: payload, on: card) } else { NSSound.beep() }
            return
        }
        createNote(from: payload)
    }

    func notesList(_ list: NotesListView, drop payload: ImportPayload, on card: NoteCardView) -> Bool {
        if !card.isFolded { card.ensureEditor(); list.layoutCards(animated: false) }
        let ok = PasteboardImport.add(payload, to: card.note.id, editor: card.isFolded ? nil : card.editor, env: env)
        if !ok { showToast("Could not add that item") }
        return ok
    }

    func notesList(_ list: NotesListView, setFolded folded: Bool, note id: NoteID) {
        setFoldedKeepingSelection(folded, id: id)
    }

    func notesList(_ list: NotesListView, moveNote id: NoteID, toGap gap: Int) {
        guard let note = store.note(id: id) else { return }
        let displayed = list.noteIDs
        let all = store.notes(in: note.folderId)
        guard let from = all.firstIndex(where: { $0.id == id }) else { return }
        var dest: Int
        if gap < displayed.count, let neighborIndex = all.firstIndex(where: { $0.id == displayed[gap] }) {
            dest = neighborIndex > from ? neighborIndex - 1 : neighborIndex
        } else {
            dest = all.count - 1
        }
        let zone = actions.zone(for: note, in: all)
        dest = max(zone.lowerBound, min(zone.upperBound, dest))
        guard dest != from else { return }
        actions.reorderNote(id, toIndex: dest)
    }
}
