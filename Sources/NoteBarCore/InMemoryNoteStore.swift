import Foundation
import UniformTypeIdentifiers

/// Reference implementation of `NoteStore` kept entirely in memory. Use it for UI development,
/// checks, and as the semantic reference for `GRDBNoteStore`. Attachment files are NOT copied:
/// images keep their source path in `relativePath` as an absolute path.
@MainActor
public final class InMemoryNoteStore: NoteStore {
    private var folderMap: [FolderID: Folder] = [:]
    private var noteMap: [NoteID: Note] = [:]
    private var attachmentMap: [AttachmentID: Attachment] = [:]
    private var themes: [String: Theme] = [:]
    private var nextID: Int64 = 1

    public init(seed: Bool = false) {
        if seed { seedSampleData() } else { ensureFolder() }
    }

    private func newID() -> Int64 { defer { nextID += 1 }; return nextID }

    private func ensureFolder() {
        if folders().isEmpty { _ = createFolder(name: "Notes") }
    }

    /// Not trashed (a note: neither the note nor its folder).
    private func isLive(_ f: Folder) -> Bool { f.deletedAt == nil }
    private func isLive(_ n: Note) -> Bool { n.deletedAt == nil && folderMap[n.folderId].map(isLive) == true }
    private var liveNotes: [Note] { noteMap.values.filter(isLive) }

    // MARK: Folders
    public func folders() -> [Folder] {
        folderMap.values.filter(isLive)
            .sorted { ($0.isPinned ? 0 : 1, $0.sortIndex, $0.id) < ($1.isPinned ? 0 : 1, $1.sortIndex, $1.id) }
    }
    public func folder(id: FolderID) -> Folder? { folderMap[id].flatMap { isLive($0) ? $0 : nil } }
    public func noteCount(in folderId: FolderID) -> Int { liveNotes.filter { $0.folderId == folderId }.count }

    @discardableResult public func createFolder(name: String) -> Folder {
        let f = Folder(id: newID(), name: name, sortIndex: SortIndex.between(folders().last?.sortIndex, nil))
        folderMap[f.id] = f
        postStoreChange(.folders, sender: self)
        return f
    }

    public func updateFolder(_ folder: Folder) {
        guard let old = self.folder(id: folder.id) else { return }
        var f = folder
        f.deletedAt = old.deletedAt
        folderMap[folder.id] = f
        postStoreChange(.folders, sender: self)
    }

    public func deleteFolder(id: FolderID) {
        guard let f = folderMap[id], !isLive(f) || folders().count > 1 else { return }
        for n in noteMap.values where n.folderId == id { removeNote(n.id) }
        folderMap[id] = nil
        postStoreChange(.notes(folderId: id), sender: self)
        postStoreChange(.folders, sender: self)
    }

    public func moveFolder(id: FolderID, toIndex index: Int) {
        guard var f = folder(id: id) else { return }
        let others = folders().filter { $0.id != id }
        let list = others.filter { $0.isPinned == f.isPinned }   // same zone only (pinned sort first)
        let i = max(0, min(index - (f.isPinned ? 0 : others.count - list.count), list.count))
        f.sortIndex = SortIndex.between(i > 0 ? list[i - 1].sortIndex : nil, i < list.count ? list[i].sortIndex : nil)
        folderMap[id] = f
        postStoreChange(.folders, sender: self)
    }

    // MARK: Notes
    public func notes(in folderId: FolderID) -> [Note] {
        liveNotes.filter { $0.folderId == folderId }
            .sorted { ($0.isPinned ? 0 : 1, $0.sortIndex, $0.id) < ($1.isPinned ? 0 : 1, $1.sortIndex, $1.id) }
    }
    public func note(id: NoteID) -> Note? { noteMap[id].flatMap { isLive($0) ? $0 : nil } }

    public func search(_ query: String, in folderId: FolderID?) -> [Note] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return [] }
        let pool = folderId.map { notes(in: $0) } ?? folders().flatMap { notes(in: $0.id) }
        return pool.filter { $0.body.range(of: q, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
    }

    @discardableResult
    public func createNote(in folderId: FolderID, body: String, mode: NoteMode, position: InsertPosition) -> Note {
        let fid = folder(id: folderId) != nil ? folderId : folders()[0].id
        let list = notes(in: fid).filter { !$0.isPinned }
        let idx = position == .top ? SortIndex.between(nil, list.first?.sortIndex) : SortIndex.between(list.last?.sortIndex, nil)
        let n = Note(id: newID(), folderId: fid, body: body, sortIndex: idx, mode: mode)
        noteMap[n.id] = n
        postStoreChange(.notes(folderId: fid), sender: self)
        postStoreChange(.folders, sender: self)
        return n
    }

    public func updateNoteBody(id: NoteID, body: String) {
        guard var n = note(id: id), n.body != body else { return }
        n.body = body; n.updatedAt = Date()
        noteMap[id] = n
        postStoreChange(.noteBody(id: id), sender: self)
    }

    public func updateNote(_ note: Note) {
        guard let old = self.note(id: note.id) else { return }
        var n = note; n.updatedAt = Date()
        n.deletedAt = old.deletedAt
        if folder(id: n.folderId) == nil { n.folderId = old.folderId }
        noteMap[note.id] = n
        postStoreChange(.note(id: note.id), sender: self)
        if old.isPinned != n.isPinned || old.folderId != n.folderId || old.sortIndex != n.sortIndex {
            postStoreChange(.notes(folderId: n.folderId), sender: self)
        }
    }

    private func removeNote(_ id: NoteID) {
        noteMap[id] = nil
        for a in attachmentMap.values where a.noteId == id { attachmentMap[a.id] = nil }
    }

    public func deleteNote(id: NoteID) {
        guard let n = noteMap[id] else { return }
        removeNote(id)
        postStoreChange(.notes(folderId: n.folderId), sender: self)
        postStoreChange(.folders, sender: self)
    }

    public func moveNote(id: NoteID, toIndex index: Int) {
        guard let n0 = note(id: id) else { return }
        var n = n0
        let others = notes(in: n0.folderId).filter { $0.id != id }
        let list = others.filter { $0.isPinned == n0.isPinned }   // same zone only (pinned sort first)
        let i = max(0, min(index - (n0.isPinned ? 0 : others.count - list.count), list.count))
        n.sortIndex = SortIndex.between(i > 0 ? list[i - 1].sortIndex : nil, i < list.count ? list[i].sortIndex : nil)
        noteMap[id] = n
        postStoreChange(.notes(folderId: n.folderId), sender: self)
    }

    public func moveNote(id: NoteID, toFolder folderId: FolderID, position: InsertPosition) {
        guard var n = note(id: id), folder(id: folderId) != nil else { return }
        let old = n.folderId
        let list = notes(in: folderId).filter { !$0.isPinned }
        n.folderId = folderId
        n.sortIndex = position == .top ? SortIndex.between(nil, list.first?.sortIndex) : SortIndex.between(list.last?.sortIndex, nil)
        noteMap[id] = n
        postStoreChange(.notes(folderId: old), sender: self)
        postStoreChange(.notes(folderId: folderId), sender: self)
        postStoreChange(.folders, sender: self)
    }

    // MARK: Trash
    public func trashNote(id: NoteID) {
        guard var n = note(id: id) else { return }
        n.deletedAt = Date()
        noteMap[id] = n
        postStoreChange(.notes(folderId: n.folderId), sender: self)
        postStoreChange(.folders, sender: self)
    }

    public func trashFolder(id: FolderID) {
        guard var f = folder(id: id), folders().count > 1 else { return }
        f.deletedAt = Date()
        folderMap[id] = f
        postStoreChange(.notes(folderId: id), sender: self)
        postStoreChange(.folders, sender: self)
    }

    @discardableResult public func restoreNote(id: NoteID) -> Bool {
        guard var n = noteMap[id], !isLive(n) else { return false }
        if let f = folderMap[n.folderId], !isLive(f) { restoreFolder(id: f.id) }
        if n.deletedAt != nil {
            n.deletedAt = nil
            noteMap[id] = n
            postStoreChange(.notes(folderId: n.folderId), sender: self)
            postStoreChange(.folders, sender: self)
        }
        return true
    }

    @discardableResult public func restoreFolder(id: FolderID) -> Bool {
        guard var f = folderMap[id], !isLive(f) else { return false }
        f.name = availableFolderName(f.name)
        f.deletedAt = nil
        folderMap[id] = f
        postStoreChange(.notes(folderId: id), sender: self)
        postStoreChange(.folders, sender: self)
        return true
    }

    public func trashedNotes() -> [Note] {
        noteMap.values.filter { n in n.deletedAt != nil && folderMap[n.folderId].map(isLive) == true }
            .sorted { ($0.deletedAt!, $0.id) > ($1.deletedAt!, $1.id) }
    }

    public func trashedFolders() -> [Folder] {
        folderMap.values.filter { !isLive($0) }.sorted { ($0.deletedAt!, $0.id) > ($1.deletedAt!, $1.id) }
    }

    public func noteCount(inTrashedFolder id: FolderID) -> Int {
        noteMap.values.filter { $0.folderId == id && $0.deletedAt == nil }.count
    }

    public func purgeTrash(deletedBefore date: Date) {
        for n in noteMap.values where (n.deletedAt.map { $0 < date } ?? false) { removeNote(n.id) }
        for f in folderMap.values where (f.deletedAt.map { $0 < date } ?? false) {
            for n in noteMap.values where n.folderId == f.id { removeNote(n.id) }
            folderMap[f.id] = nil
        }
        postStoreChange(.folders, sender: self)
    }

    // MARK: Attachments
    public func attachments(for noteId: NoteID) -> [Attachment] {
        attachmentMap.values.filter { $0.noteId == noteId }.sorted { $0.id < $1.id }
    }
    public func attachment(id: AttachmentID) -> Attachment? { attachmentMap[id] }

    public func addAttachment(to noteId: NoteID, fileURL: URL) throws -> Attachment {
        guard noteMap[noteId] != nil else { throw NoteStoreError.notFound }
        let isImage = (UTType(filenameExtension: fileURL.pathExtension)?.conforms(to: .image) ?? false)
        let a: Attachment
        if isImage {
            a = Attachment(id: newID(), noteId: noteId, kind: .image, relativePath: fileURL.path, displayName: fileURL.lastPathComponent)
        } else {
            let data = try fileURL.bookmarkData()
            a = Attachment(id: newID(), noteId: noteId, kind: .fileBookmark, bookmarkData: data, displayName: fileURL.lastPathComponent)
        }
        attachmentMap[a.id] = a
        postStoreChange(.attachments(noteId: noteId), sender: self)
        return a
    }

    public func addImageAttachment(to noteId: NoteID, data: Data, fileExtension: String, displayName: String?) throws -> Attachment {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + "." + fileExtension)
        try data.write(to: url)
        var a = try addAttachment(to: noteId, fileURL: url)
        if let displayName { a.displayName = displayName; attachmentMap[a.id] = a }
        return a
    }

    public func url(for attachment: Attachment) -> URL? {
        switch attachment.kind {
        case .image: return attachment.relativePath.map { URL(fileURLWithPath: $0) }
        case .fileBookmark:
            var stale = false
            return attachment.bookmarkData.flatMap { try? URL(resolvingBookmarkData: $0, bookmarkDataIsStale: &stale) }
        }
    }

    public func deleteAttachment(id: AttachmentID) {
        guard let a = attachmentMap.removeValue(forKey: id) else { return }
        postStoreChange(.attachments(noteId: a.noteId), sender: self)
    }

    // MARK: Themes
    public func customThemes() -> [Theme] { themes.values.sorted { $0.name < $1.name } }
    public func saveTheme(_ theme: Theme) { themes[theme.id] = theme }
    public func deleteTheme(id: String) { themes[id] = nil }

    public func flush() {}

    // MARK: Sample data
    private func seedSampleData() {
        let inbox = createFolder(name: "Notes")
        let work = createFolder(name: "Work")
        _ = createFolder(name: "Ideas")
        var n1 = createNote(in: inbox.id, body: "Welcome to NoteBar\nNotes **without** app switching.\n- [ ] Try the hotkey ⌥⌘N\n- [x] Open the panel", mode: .standard, position: .bottom)
        n1.color = .yellow; updateNote(n1)
        var n2 = createNote(in: inbox.id, body: "Shopping\n- milk\n- eggs\n- #ff8800 orange paint", mode: .standard, position: .bottom)
        n2.color = .green; updateNote(n2)
        _ = createNote(in: inbox.id, body: "snippet.swift\nlet x = 42\nprint(x)", mode: .code, position: .bottom)
        var n4 = createNote(in: work.id, body: "# Meeting\n> Remember the *agenda*\n==important== `code`", mode: .standard, position: .bottom)
        n4.color = .purple; n4.isPinned = true; updateNote(n4)
    }
}
