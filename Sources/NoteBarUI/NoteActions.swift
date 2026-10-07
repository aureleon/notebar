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

    var store: NoteStore { env.store }

    // MARK: Note metadata

    func setColor(_ color: NoteColor, for id: NoteID) {
        guard var n = store.note(id: id), n.color != color else { return }
        n.color = color
        store.updateNote(n)
    }

    func setMode(_ mode: NoteMode, for id: NoteID) {
        guard var n = store.note(id: id), n.mode != mode else { return }
        n.mode = mode
        store.updateNote(n)
    }

    func toggleFold(_ id: NoteID) {
        guard let n = store.note(id: id) else { return }
        setFolded(!n.isFolded, id: id)
    }

    func setFolded(_ folded: Bool, id: NoteID) {
        guard var n = store.note(id: id), n.isFolded != folded else { return }
        n.isFolded = folded
        store.updateNote(n)
    }

    func togglePin(_ id: NoteID) {
        guard var n = store.note(id: id) else { return }
        n.isPinned.toggle()
        store.updateNote(n)
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

    /// Moves a note to `dest` (final index in `notes(in:)` order, inside its pinned/unpinned zone).
    /// `NoteStore.moveNote(toIndex:)` places the note between its raw neighbors, which is wrong at the
    /// pinned/unpinned boundary (the neighbor on the other side has an unrelated sortIndex). There the
    /// sort index is computed from same-zone neighbors and written with `updateNote`.
    func reorderNote(_ id: NoteID, toIndex dest: Int) {
        guard let note = store.note(id: id) else { return }
        let remaining = store.notes(in: note.folderId).filter { $0.id != id }
        let i = max(0, min(dest, remaining.count))
        let prev = i > 0 ? remaining[i - 1] : nil
        let next = i < remaining.count ? remaining[i] : nil
        let crossesZone = (prev.map { $0.isPinned != note.isPinned } ?? false) || (next.map { $0.isPinned != note.isPinned } ?? false)
        guard crossesZone else { store.moveNote(id: id, toIndex: i); return }
        let a = prev.flatMap { $0.isPinned == note.isPinned ? $0.sortIndex : nil }
        let b = next.flatMap { $0.isPinned == note.isPinned ? $0.sortIndex : nil }
        if let a, let b, SortIndex.needsRebalance(a, b) { store.moveNote(id: id, toIndex: i); return }
        var n = note
        n.sortIndex = SortIndex.between(a, b)
        store.updateNote(n)
    }

    /// Folder equivalent of `reorderNote` (pinned folders sort first).
    func reorderFolder(_ id: FolderID, toIndex dest: Int) {
        guard let folder = store.folder(id: id) else { return }
        let remaining = store.folders().filter { $0.id != id }
        let i = max(0, min(dest, remaining.count))
        let prev = i > 0 ? remaining[i - 1] : nil
        let next = i < remaining.count ? remaining[i] : nil
        let crossesZone = (prev.map { $0.isPinned != folder.isPinned } ?? false) || (next.map { $0.isPinned != folder.isPinned } ?? false)
        guard crossesZone else { store.moveFolder(id: id, toIndex: i); return }
        let a = prev.flatMap { $0.isPinned == folder.isPinned ? $0.sortIndex : nil }
        let b = next.flatMap { $0.isPinned == folder.isPinned ? $0.sortIndex : nil }
        if let a, let b, SortIndex.needsRebalance(a, b) { store.moveFolder(id: id, toIndex: i); return }
        var f = folder
        f.sortIndex = SortIndex.between(a, b)
        store.updateFolder(f)
    }

    func move(_ id: NoteID, toFolder folderId: FolderID) {
        guard let note = store.note(id: id), note.folderId != folderId, store.folder(id: folderId) != nil else { return }
        store.moveNote(id: id, toFolder: folderId, position: .top)
        let name = store.folder(id: folderId)?.name ?? "folder"
        root?.showToast("Moved to “\(name)”", actionTitle: "Show", action: { [weak self] in
            self?.root?.reveal(noteId: id, edit: false)
        })
    }

    /// Creates a folder, moves the note there and starts renaming the new folder.
    func moveToNewFolder(_ id: NoteID) {
        guard store.note(id: id) != nil else { return }
        let folder = store.createFolder(name: uniqueFolderName("New Folder", in: store))
        store.moveNote(id: id, toFolder: folder.id, position: .top)
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
            alert.informativeText = "You can undo this for a few seconds."
            alert.addButton(withTitle: "Delete").hasDestructiveAction = true
            alert.addButton(withTitle: "Cancel")
            guard ModalSupport.run(alert) == .alertFirstButtonReturn else { return }
        }
        root?.softDelete(id)
    }

    // MARK: Export / share

    func copyImage(_ id: NoteID) {
        guard let image = renderImage(id) else { NSSound.beep(); return }
        let pb = NSPasteboard.general
        pb.clearContents()
        if let png = image.representation(using: .png, properties: [:]) { pb.setData(png, forType: .png) }
        if let tiff = image.tiffRepresentation { pb.setData(tiff, forType: .tiff) }
        root?.showToast("Image copied")
    }

    func saveImage(_ id: NoteID) {
        guard let note = store.note(id: id), let image = renderImage(id),
              let png = image.representation(using: .png, properties: [:]) else { NSSound.beep(); return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = UIFormat.fileName(for: note) + ".png"
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        guard ModalSupport.run(panel) == .OK, let url = panel.url else { return }
        do { try png.write(to: url) } catch { root?.showToast("Could not save image") }
    }

    private func renderImage(_ id: NoteID) -> NSBitmapImageRep? {
        guard let note = store.note(id: id) else { return nil }
        let ctx = root?.exportContext() ?? (width: 278, appearance: NSApp.effectiveAppearance)
        return NoteImageExporter.render(note: note, width: ctx.width, appearance: ctx.appearance, env: env)
    }

    func share(_ id: NoteID, from view: NSView) {
        guard let note = store.note(id: id) else { return }
        let text = Self.shareText(for: note, store: store)
        let picker = NSSharingServicePicker(items: [text])
        SharePickerDelegate.shared.begin()
        picker.delegate = SharePickerDelegate.shared
        picker.show(relativeTo: view.bounds, of: view, preferredEdge: .minY)
    }

    /// Body with attachment tokens replaced by file names/paths (readable outside NoteBar).
    static func shareText(for note: Note, store: NoteStore) -> String {
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
        root?.showFolderList()
        root?.beginRenameFolder(f.id)
    }

    func renameFolder(_ id: FolderID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, var f = store.folder(id: id), f.name != trimmed else { return }
        f.name = trimmed
        store.updateFolder(f)
    }

    func togglePinFolder(_ id: FolderID) {
        guard var f = store.folder(id: id) else { return }
        f.isPinned.toggle()
        store.updateFolder(f)
    }

    func setFolderColor(_ color: NoteColor, _ id: FolderID) {
        guard var f = store.folder(id: id), f.color != color else { return }
        f.color = color
        store.updateFolder(f)
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
        alert.informativeText = count == 0 ? "The folder is empty."
            : "Its \(count == 1 ? "note" : "\(count) notes") will be deleted too. This cannot be undone."
        alert.addButton(withTitle: "Delete").hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")
        guard ModalSupport.run(alert) == .alertFirstButtonReturn else { return }
        root?.commitPendingDeletion()
        store.deleteFolder(id: id)
        if env.settings.lastFolderId == id { env.settings.lastFolderId = nil }
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

/// Balances the auto-hide suspension around the share picker.
@MainActor
final class SharePickerDelegate: NSObject, @preconcurrency NSSharingServicePickerDelegate {
    static let shared = SharePickerDelegate()
    private var active = false

    func begin() {
        if !active { active = true; ModalSupport.suspend(true) }
    }

    func sharingServicePicker(_ picker: NSSharingServicePicker, didChoose service: NSSharingService?) {
        // Keep the panel open a moment longer: the chosen service may show its own window.
        DispatchQueue.main.asyncAfter(deadline: .now() + (service == nil ? 0 : 1.5)) {
            MainActor.assumeIsolated {
                if self.active { self.active = false; ModalSupport.suspend(false) }
            }
        }
    }
}
