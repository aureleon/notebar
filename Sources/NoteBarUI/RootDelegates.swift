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
        MenuBuilder.cardContextMenu(for: card.currentNote, actions: actions, inSearch: search != nil)
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
        createNote(from: payload)
    }

    func notesList(_ list: NotesListView, drop payload: ImportPayload, on card: NoteCardView) -> Bool {
        if !card.isFolded { card.ensureEditor(); list.layoutCards(animated: false) }
        let ok = PasteboardImport.add(payload, to: card.note.id, editor: card.isFolded ? nil : card.editor, env: env)
        if !ok { showToast("Could not add that item") }
        return ok
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

// MARK: - Folder list

extension NotesRootViewController: FolderListDelegate {
    func folderList(_ list: FolderListView, open folderId: FolderID) {
        list.selectedFolderID = folderId
        showFolder(folderId)
    }

    func folderListMenu(for folder: Folder?) -> NSMenu {
        MenuBuilder.folderContextMenu(for: folder, actions: actions)
    }

    func folderList(_ list: FolderListView, rename folderId: FolderID, to name: String) {
        actions.renameFolder(folderId, to: name)
    }

    func folderList(_ list: FolderListView, dropNote noteId: NoteID, on folderId: FolderID) {
        actions.move(noteId, toFolder: folderId)
    }

    func folderList(_ list: FolderListView, drop payload: ImportPayload, on folderId: FolderID) {
        createNote(from: payload, in: folderId)
    }

    func folderListDidEndRename(_ list: FolderListView, hadFocus: Bool) {
        reloadFolderList()
        if hadFocus { focusRoot() }
    }
}
