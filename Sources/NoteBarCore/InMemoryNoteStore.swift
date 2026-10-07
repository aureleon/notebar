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
        if folderMap.isEmpty { _ = createFolder(name: "Notes") }
    }

    // MARK: Folders
    public func folders() -> [Folder] {
        folderMap.values.sorted { ($0.isPinned ? 0 : 1, $0.sortIndex, $0.id) < ($1.isPinned ? 0 : 1, $1.sortIndex, $1.id) }
    }
    public func folder(id: FolderID) -> Folder? { folderMap[id] }
    public func noteCount(in folderId: FolderID) -> Int { noteMap.values.filter { $0.folderId == folderId }.count }

    @discardableResult public func createFolder(name: String) -> Folder {
        let f = Folder(id: newID(), name: name, sortIndex: SortIndex.between(folders().last?.sortIndex, nil))
        folderMap[f.id] = f
        postStoreChange(.folders, sender: self)
        return f
    }

    public func updateFolder(_ folder: Folder) {
        guard folderMap[folder.id] != nil else { return }
        folderMap[folder.id] = folder
        postStoreChange(.folders, sender: self)
    }

    public func deleteFolder(id: FolderID) {
        guard folderMap.count > 1, folderMap[id] != nil else { return }
        for n in noteMap.values where n.folderId == id { removeNote(n.id) }
        folderMap[id] = nil
        postStoreChange(.folders, sender: self)
    }

    public func moveFolder(id: FolderID, toIndex index: Int) {
        var list = folders()
        guard let from = list.firstIndex(where: { $0.id == id }) else { return }
        var f = list.remove(at: from)
        let i = max(0, min(index, list.count))
        f.sortIndex = SortIndex.between(i > 0 ? list[i - 1].sortIndex : nil, i < list.count ? list[i].sortIndex : nil)
        folderMap[id] = f
        postStoreChange(.folders, sender: self)
    }

    // MARK: Notes
    public func notes(in folderId: FolderID) -> [Note] {
        noteMap.values.filter { $0.folderId == folderId }
            .sorted { ($0.isPinned ? 0 : 1, $0.sortIndex, $0.id) < ($1.isPinned ? 0 : 1, $1.sortIndex, $1.id) }
    }
    public func note(id: NoteID) -> Note? { noteMap[id] }

    public func search(_ query: String, in folderId: FolderID?) -> [Note] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return [] }
        let pool = folderId.map { notes(in: $0) } ?? folders().flatMap { notes(in: $0.id) }
        return pool.filter { $0.body.range(of: q, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
    }

    @discardableResult
    public func createNote(in folderId: FolderID, body: String, mode: NoteMode, position: InsertPosition) -> Note {
        let fid = folderMap[folderId] != nil ? folderId : folders()[0].id
        let list = notes(in: fid).filter { !$0.isPinned }
        let idx = position == .top ? SortIndex.between(nil, list.first?.sortIndex) : SortIndex.between(list.last?.sortIndex, nil)
        let n = Note(id: newID(), folderId: fid, body: body, sortIndex: idx, mode: mode)
        noteMap[n.id] = n
        postStoreChange(.notes(folderId: fid), sender: self)
        postStoreChange(.folders, sender: self)
        return n
    }

    public func updateNoteBody(id: NoteID, body: String) {
        guard var n = noteMap[id], n.body != body else { return }
        n.body = body; n.updatedAt = Date()
        noteMap[id] = n
        postStoreChange(.noteBody(id: id), sender: self)
    }

    public func updateNote(_ note: Note) {
        guard let old = noteMap[note.id] else { return }
        var n = note; n.updatedAt = Date()
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
        guard let n0 = noteMap[id] else { return }
        var list = notes(in: n0.folderId)
        guard let from = list.firstIndex(where: { $0.id == id }) else { return }
        var n = list.remove(at: from)
        let i = max(0, min(index, list.count))
        n.sortIndex = SortIndex.between(i > 0 ? list[i - 1].sortIndex : nil, i < list.count ? list[i].sortIndex : nil)
        noteMap[id] = n
        postStoreChange(.notes(folderId: n.folderId), sender: self)
    }

    public func moveNote(id: NoteID, toFolder folderId: FolderID, position: InsertPosition) {
        guard var n = noteMap[id], folderMap[folderId] != nil else { return }
        let old = n.folderId
        let list = notes(in: folderId).filter { !$0.isPinned }
        n.folderId = folderId
        n.sortIndex = position == .top ? SortIndex.between(nil, list.first?.sortIndex) : SortIndex.between(list.last?.sortIndex, nil)
        noteMap[id] = n
        postStoreChange(.notes(folderId: old), sender: self)
        postStoreChange(.notes(folderId: folderId), sender: self)
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
