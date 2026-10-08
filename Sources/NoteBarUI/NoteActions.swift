import AppKit
import NoteBarCore
import UniformTypeIdentifiers

/// Every note / folder operation the UI can trigger (menus, footer buttons, shortcuts).
/// Always re-reads the note from the store before changing it, so a stale copy never reverts the body.
@MainActor
final class NoteActions {
    let env: AppEnvironment
    weak var root: NotesRootViewController?

    init(env: AppEnvironment) { self.env = env }

    /// Checks answer the folder delete alert with this (nil = show the alert).
    var confirmDestructiveAlert: ((NSAlert) -> Bool)?

    var store: NoteStore { env.store }

    // MARK: Undo
    // Every action registers its reverse in the panel's undo history (⌘Z / ⇧⌘Z on the list). The
    // reverse is an action too, so it registers the redo. Text edits keep their own per-note undo.

    var undoManager: UndoManager? { root?.panelUndo }
    /// Counts registrations (the delete toast checks that its delete is still the last action).
    private(set) var undoRegistrations = 0

    func registerUndo(_ name: String, _ reverse: @escaping @MainActor (NoteActions) -> Void) {
        guard let u = undoManager else { return }
        undoRegistrations += 1
        u.registerUndo(withTarget: self) { target in MainActor.assumeIsolated { reverse(target) } }
        u.setActionName(name)
    }

    /// Trash / restore pairs used by undo (new note, new folder, delete).
    func trashNoteUndoably(_ id: NoteID, name: String) {
        guard store.note(id: id) != nil else { return }
        store.trashNote(id: id)
        registerUndo(name) { $0.restoreNoteUndoably(id, name: name) }
    }

    func restoreNoteUndoably(_ id: NoteID, name: String) {
        guard store.restoreNote(id: id) else { return }
        registerUndo(name) { $0.trashNoteUndoably(id, name: name) }
        root?.noteRestored(id)
    }

    func trashFolderUndoably(_ id: FolderID, name: String) {
        guard store.folder(id: id) != nil, store.folders().count > 1 else { return }
        store.trashFolder(id: id)
        if env.settings.lastFolderId == id { env.settings.lastFolderId = nil }
        registerUndo(name) { $0.restoreFolderUndoably(id, name: name) }
    }

    func restoreFolderUndoably(_ id: FolderID, name: String) {
        guard store.restoreFolder(id: id) else { return }
        registerUndo(name) { $0.trashFolderUndoably(id, name: name) }
    }

    /// A note created in the panel (⌘N, +, paste, drop): ⌘Z on the list removes it again.
    func noteCreated(_ id: NoteID, name: String = "New Note") {
        registerUndo(name) { $0.trashNoteUndoably(id, name: name) }
    }

    // MARK: Note metadata

    func setColor(_ color: NoteColor, for id: NoteID) {
        guard var n = store.note(id: id), n.color != color else { return }
        let old = n.color
        n.color = color
        store.updateNote(n)
        registerUndo("Color") { $0.setColor(old, for: id) }
    }

    func setMode(_ mode: NoteMode, for id: NoteID) {
        guard var n = store.note(id: id), n.mode != mode else { return }
        let old = n.mode
        n.mode = mode
        store.updateNote(n)
        registerUndo("Change Mode") { $0.setMode(old, for: id) }
    }

    func toggleFold(_ id: NoteID) {
        guard let n = store.note(id: id) else { return }
        setFolded(!n.isFolded, id: id)
    }

    func setFolded(_ folded: Bool, id: NoteID) {
        guard var n = store.note(id: id), n.isFolded != folded else { return }
        if folded, root?.notesList.expandedNoteID == id {
            root?.notesList.setExpandedNoteID(nil, animated: false)
        }
        n.isFolded = folded
        store.updateNote(n)
        registerUndo(folded ? "Fold" : "Unfold") { $0.setFolded(!folded, id: id) }
    }

    func toggleExpand(_ id: NoteID) {
        root?.toggleExpand(id)
    }

    func togglePin(_ id: NoteID) {
        guard var n = store.note(id: id) else { return }
        n.isPinned.toggle()
        store.updateNote(n)
        registerUndo(n.isPinned ? "Pin" : "Unpin") { $0.togglePin(id) }
    }

    // MARK: Ordering

    enum MoveTarget { case top, up, down, bottom }

    /// Index range of the notes that share the pinned state of `note` (pinned notes always sort first).
    func zone(for note: Note, in list: [Note]) -> ClosedRange<Int> {
        let pinnedCount = list.filter(\.isPinned).count
        if note.isPinned { return 0...max(0, pinnedCount - 1) }
        return pinnedCount...max(pinnedCount, list.count - 1)
    }

    func move(_ id: NoteID, _ target: MoveTarget) {
        guard let note = store.note(id: id) else { return }
        let list = store.notes(in: note.folderId)
        guard let idx = list.firstIndex(where: { $0.id == id }) else { return }
        let z = zone(for: note, in: list)
        let dest: Int
        switch target {
        case .top: dest = z.lowerBound
        case .up: dest = max(z.lowerBound, idx - 1)
        case .down: dest = min(z.upperBound, idx + 1)
        case .bottom: dest = z.upperBound
        }
        guard dest != idx else { NSSound.beep(); return }
        reorderNote(id, toIndex: dest)
        root?.noteDidMoveByKeyboard(id)
    }

    /// Moves a note to `dest` (final index in `notes(in:)` order). The store keeps the note inside its
    /// pinned/unpinned zone and places it between same-zone neighbors.
    func reorderNote(_ id: NoteID, toIndex dest: Int) {
        guard let n = store.note(id: id), let old = store.notes(in: n.folderId).firstIndex(where: { $0.id == id }) else { return }
        store.moveNote(id: id, toIndex: dest)
        registerUndo("Move Note") { $0.reorderNote(id, toIndex: old) }
    }

    /// Folder equivalent of `reorderNote` (pinned folders sort first).
    func reorderFolder(_ id: FolderID, toIndex dest: Int) {
        guard let old = store.folders().firstIndex(where: { $0.id == id }) else { return }
        store.moveFolder(id: id, toIndex: dest)
        registerUndo("Move Folder") { $0.reorderFolder(id, toIndex: old) }
    }

    /// Puts a note back into `folderId` at `index` (undo of a move to another folder).
    func place(_ id: NoteID, inFolder folderId: FolderID, at index: Int) {
        guard let n = store.note(id: id), store.folder(id: folderId) != nil,
              let curIndex = store.notes(in: n.folderId).firstIndex(where: { $0.id == id }) else { return }
        let curFolder = n.folderId
        if curFolder != folderId { store.moveNote(id: id, toFolder: folderId, position: .top) }
        store.moveNote(id: id, toIndex: index)
        registerUndo("Move to Folder") { $0.place(id, inFolder: curFolder, at: curIndex) }
    }

    func move(_ id: NoteID, toFolder folderId: FolderID) {
        guard let note = store.note(id: id), note.folderId != folderId, store.folder(id: folderId) != nil,
              let oldIndex = store.notes(in: note.folderId).firstIndex(where: { $0.id == id }) else { return }
        store.moveNote(id: id, toFolder: folderId, position: .top)
        registerUndo("Move to Folder") { $0.place(id, inFolder: note.folderId, at: oldIndex) }
        let name = store.folder(id: folderId)?.name ?? "folder"
        root?.showToast("Moved to “\(name)”", actionTitle: "Show", action: { [weak self] in
            self?.root?.reveal(noteId: id, edit: false)
        })
    }

    /// Creates a folder, moves the note there and starts renaming the new folder.
    func moveToNewFolder(_ id: NoteID) {
        guard let note = store.note(id: id),
              let oldIndex = store.notes(in: note.folderId).firstIndex(where: { $0.id == id }) else { return }
        let folder = store.createFolder(name: uniqueFolderName("New Folder", in: store))
        store.moveNote(id: id, toFolder: folder.id, position: .top)
        // One undo step: the note goes back (runs first), then the new folder goes away.
        registerUndo("Move to New Folder") { $0.trashFolderUndoably(folder.id, name: "Move to New Folder") }
        registerUndo("Move to New Folder") { $0.place(id, inFolder: note.folderId, at: oldIndex) }
        root?.showFolderList()
        root?.beginRenameFolder(folder.id)
    }

    // MARK: Delete

    func delete(_ id: NoteID, confirm: Bool) {
        guard let note = store.note(id: id) else { return }
        if confirm {
            let alert = NSAlert()
            let title = note.title.isEmpty ? "this note" : "“\(note.title.prefix(60))”"
            alert.messageText = "Delete \(title)?"
            alert.informativeText = "You can undo this."
            alert.addButton(withTitle: "Delete").hasDestructiveAction = true
            alert.addButton(withTitle: "Cancel")
            guard ModalSupport.run(alert) == .alertFirstButtonReturn else { return }
        }
        root?.softDelete(id)
    }

    // MARK: Copy

    /// Copies the note text (attachment tokens become file paths) and confirms with a toast.
    func copyText(_ id: NoteID) {
        guard let note = store.note(id: id) else { NSSound.beep(); return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(Self.plainText(for: note, store: store), forType: .string)
        root?.showToast("Copied")
    }

    /// Body with attachment tokens replaced by file names/paths (readable outside NoteBar).
    static func plainText(for note: Note, store: NoteStore) -> String {
        var text = note.body
        for m in AttachmentLink.matches(in: text).reversed() {
            let att = store.attachment(id: m.attachmentID)
            let url = att.flatMap { store.url(for: $0) }
            let replacement = url?.path ?? m.name
            text.replaceSubrange(m.range, with: replacement)
        }
        return text
    }

    // MARK: Folders

    func newFolder() {
        let f = store.createFolder(name: uniqueFolderName("New Folder", in: store))
        registerUndo("New Folder") { $0.trashFolderUndoably(f.id, name: "New Folder") }
        root?.showFolderList()
        root?.beginRenameFolder(f.id)
    }

    func renameFolder(_ id: FolderID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, var f = store.folder(id: id), f.name != trimmed else { return }
        let old = f.name
        f.name = trimmed
        store.updateFolder(f)
        registerUndo("Rename Folder") { $0.renameFolder(id, to: old) }
    }

    func togglePinFolder(_ id: FolderID) {
        guard var f = store.folder(id: id) else { return }
        f.isPinned.toggle()
        store.updateFolder(f)
        registerUndo(f.isPinned ? "Pin Folder" : "Unpin Folder") { $0.togglePinFolder(id) }
    }

    func setFolderColor(_ color: NoteColor, _ id: FolderID) {
        guard var f = store.folder(id: id), f.color != color else { return }
        let old = f.color
        f.color = color
        store.updateFolder(f)
        registerUndo("Folder Color") { $0.setFolderColor(old, id) }
    }

    func deleteFolder(_ id: FolderID) {
        guard let f = store.folder(id: id) else { return }
        guard store.folders().count > 1 else {
            root?.showToast("The last folder cannot be deleted")
            return
        }
        let count = store.noteCount(in: id)
        let alert = NSAlert()
        alert.messageText = "Delete folder “\(f.name)”?"
        alert.informativeText = (count == 0 ? "The folder is empty."
            : "Its \(count == 1 ? "note" : "\(count) notes") will be deleted too.") + " You can undo this."
        alert.addButton(withTitle: "Delete").hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")
        guard confirmDestructiveAlert?(alert) ?? (ModalSupport.run(alert) == .alertFirstButtonReturn) else { return }
        trashFolderUndoably(id, name: "Delete Folder")
        root?.folderTrashed(id)
    }
}

extension NoteActions {
    // MARK: Recently Deleted

    /// Delete Now (Recently Deleted menu): gone for good, no undo.
    func deleteForGood(note id: NoteID) {
        store.deleteNote(id: id)
    }

    func deleteForGood(folder id: FolderID) {
        store.deleteFolder(id: id)
    }

    /// Empty Recently Deleted (after a confirmation).
    func emptyTrash() {
        let count = store.trashedNotes().count + store.trashedFolders().count
        guard count > 0 else { return }
        let alert = NSAlert()
        alert.messageText = "Delete \(count == 1 ? "1 item" : "\(count) items") for good?"
        alert.informativeText = "This cannot be undone."
        alert.addButton(withTitle: "Delete").hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")
        guard confirmDestructiveAlert?(alert) ?? (ModalSupport.run(alert) == .alertFirstButtonReturn) else { return }
        store.purgeTrash(deletedBefore: .distantFuture)
    }
}

/// Runs alerts / save panels from the non-activating panel: activates the app, keeps the dialog above
/// the panel, and suspends auto-hide while it is open.
@MainActor
enum ModalSupport {
    static let suspendAutoHide = Notification.Name("NoteBar.suspendAutoHide")

    static func suspend(_ active: Bool) {
        NotificationCenter.default.post(name: suspendAutoHide, object: nil, userInfo: ["active": active])
    }

    static func run(_ alert: NSAlert) -> NSApplication.ModalResponse {
        suspend(true)
        defer { suspend(false) }
        NSApp.activate()
        alert.window.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        return alert.runModal()
    }

    static func run(_ panel: NSSavePanel) -> NSApplication.ModalResponse {
        suspend(true)
        defer { suspend(false) }
        NSApp.activate()
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        return panel.runModal()
    }
}
