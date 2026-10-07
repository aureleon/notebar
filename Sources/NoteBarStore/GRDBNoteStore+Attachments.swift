import Foundation
import GRDB
import NoteBarCore
import UniformTypeIdentifiers

// MARK: - Attachments

extension GRDBNoteStore {
    public func attachments(for noteId: NoteID) -> [Attachment] {
        attachmentMap.values.filter { $0.noteId == noteId }.sorted { $0.id < $1.id }
    }

    public func attachment(id: AttachmentID) -> Attachment? { attachmentMap[id] }

    /// Images are copied into `attachments/<uuid>.<ext>`; other files and folders become plain bookmarks.
    public func addAttachment(to noteId: NoteID, fileURL: URL) throws -> Attachment {
        guard noteMap[noteId] != nil else { throw NoteStoreError.notFound }
        let url = fileURL.standardizedFileURL.resolvingSymlinksInPath()
        var isDir: ObjCBool = false
        guard url.isFileURL, FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else {
            throw NoteStoreError.invalidFile(fileURL)
        }
        let displayName = fileURL.lastPathComponent
        if !isDir.boolValue && Self.isImageFile(url) {
            let name = Self.newImageFileName(extension: url.pathExtension)
            let dest = attachmentsDirectory.appendingPathComponent(name)
            do {
                try FileManager.default.createDirectory(at: attachmentsDirectory, withIntermediateDirectories: true)
                try FileManager.default.copyItem(at: url, to: dest)
            } catch {
                throw NoteStoreError.io("Cannot copy \(displayName): \(error.localizedDescription)")
            }
            return try insertAttachment(Attachment(id: 0, noteId: noteId, kind: .image, relativePath: name,
                                                   displayName: displayName), cleanupOnFailure: dest)
        }
        let data: Data
        do {
            data = try url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
        } catch {
            throw NoteStoreError.invalidFile(fileURL)
        }
        return try insertAttachment(Attachment(id: 0, noteId: noteId, kind: .fileBookmark, bookmarkData: data,
                                               displayName: displayName), cleanupOnFailure: nil)
    }

    public func addImageAttachment(to noteId: NoteID, data: Data, fileExtension: String,
                                   displayName: String?) throws -> Attachment {
        guard noteMap[noteId] != nil else { throw NoteStoreError.notFound }
        guard !data.isEmpty else { throw NoteStoreError.io("The image is empty.") }
        let name = Self.newImageFileName(extension: fileExtension)
        let dest = attachmentsDirectory.appendingPathComponent(name)
        do {
            try FileManager.default.createDirectory(at: attachmentsDirectory, withIntermediateDirectories: true)
            try data.write(to: dest, options: .atomic)
        } catch {
            throw NoteStoreError.io("Cannot save the image: \(error.localizedDescription)")
        }
        let ext = (name as NSString).pathExtension
        let shown = displayName.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
            ?? "Image.\(ext)"
        return try insertAttachment(Attachment(id: 0, noteId: noteId, kind: .image, relativePath: name,
                                               displayName: shown), cleanupOnFailure: dest)
    }

    private func insertAttachment(_ attachment: Attachment, cleanupOnFailure file: URL?) throws -> Attachment {
        var a = attachment
        a.createdAt = a.createdAt.storeNormalized
        guard let pool else {
            if let file { try? FileManager.default.removeItem(at: file) }
            throw NoteStoreError.io("The database is closed.")
        }
        do {
            a.id = try pool.write { db -> Int64 in
                try db.execute(sql: SQL.insertAttachment, arguments: SQL.attachmentInsertArgs(a))
                return db.lastInsertedRowID
            }
        } catch {
            if let file { try? FileManager.default.removeItem(at: file) }
            throw NoteStoreError.io("Cannot save the attachment: \(error.localizedDescription)")
        }
        attachmentMap[a.id] = a
        postStoreChange(.attachments(noteId: a.noteId), sender: self)
        return a
    }

    /// Image: the file inside `attachments/`. Bookmark: the resolved target (stale bookmarks are refreshed
    /// and saved). nil if the bookmark cannot be resolved.
    public func url(for attachment: Attachment) -> URL? {
        switch attachment.kind {
        case .image:
            guard let path = attachment.relativePath, !path.isEmpty else { return nil }
            if path.hasPrefix("/") { return URL(fileURLWithPath: path) }
            return attachmentsDirectory.appendingPathComponent(path)
        case .fileBookmark:
            guard let data = attachment.bookmarkData else { return nil }
            var stale = false
            guard let url = try? URL(resolvingBookmarkData: data, options: [.withoutUI],
                                     relativeTo: nil, bookmarkDataIsStale: &stale) else { return nil }
            if stale { refreshBookmark(id: attachment.id, url: url) }
            return url
        }
    }

    private func refreshBookmark(id: AttachmentID, url: URL) {
        guard var a = attachmentMap[id],
              let fresh = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
        else { return }
        a.bookmarkData = fresh
        attachmentMap[id] = a
        pendingAttachmentIDs.insert(id)
        flush()
    }

    public func deleteAttachment(id: AttachmentID) {
        guard let a = attachmentMap[id] else { return }
        attachmentMap[id] = nil
        pendingAttachmentIDs.remove(id)
        pendingAttachmentDeletes.insert(id)
        pendingFileRemovals.append(a)
        flush()
        postStoreChange(.attachments(noteId: a.noteId), sender: self)
    }

    // MARK: Files

    /// Deletes the image files of removed attachments (unless another row still uses the same file).
    func deleteImageFiles(of removed: [Attachment]) {
        let stillUsed = Set(attachmentMap.values.compactMap(\.relativePath))
        for a in removed where a.kind == .image {
            guard let rel = a.relativePath, !rel.isEmpty, !rel.hasPrefix("/"), !stillUsed.contains(rel) else { continue }
            try? FileManager.default.removeItem(at: attachmentsDirectory.appendingPathComponent(rel))
        }
    }

    /// Deletes files in `attachments/` that no attachment row references. Runs at open.
    /// Returns the number of deleted files.
    @discardableResult
    public func cleanupOrphanedAttachmentFiles() -> Int {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(at: attachmentsDirectory, includingPropertiesForKeys: nil,
                                                      options: [.skipsHiddenFiles]) else { return 0 }
        let referenced = Set(attachmentMap.values.compactMap(\.relativePath))
        var count = 0
        for item in items where !referenced.contains(item.lastPathComponent) {
            if (try? fm.removeItem(at: item)) != nil { count += 1 }
        }
        return count
    }

    /// Deletes attachment rows (and their image files) that no note body links to any more, e.g. the user
    /// deleted the image from the text in an earlier session. Rows newer than `age` are kept.
    /// Returns the number of deleted rows.
    @discardableResult
    public func pruneUnreferencedAttachments(olderThan age: TimeInterval) -> Int {
        // A link may have been copied into another note, so any body counts.
        var linked = Set<AttachmentID>()
        for n in noteMap.values where n.body.contains("](attachment:") {
            linked.formUnion(AttachmentLink.attachmentIDs(in: n.body))
        }
        let cutoff = Date().addingTimeInterval(-age)
        let victims = attachmentMap.values.filter { !linked.contains($0.id) && $0.createdAt < cutoff }
        guard !victims.isEmpty else { return 0 }
        let ids = victims.map(\.id)
        for id in ids { attachmentMap[id] = nil; pendingAttachmentIDs.remove(id) }
        pendingAttachmentDeletes.formUnion(ids)
        pendingFileRemovals += victims
        flush()
        return victims.count
    }

    static func isImageFile(_ url: URL) -> Bool {
        let type = (try? url.resourceValues(forKeys: [.contentTypeKey]).contentType)
            ?? UTType(filenameExtension: url.pathExtension)
        return type?.conforms(to: .image) ?? false
    }

    static func newImageFileName(extension ext: String) -> String {
        var e = ext.lowercased().filter { $0.isASCII && ($0.isLetter || $0.isNumber) }
        if e.isEmpty || e.count > 10 { e = "png" }
        if e == "jpeg" { e = "jpg" }
        return UUID().uuidString + "." + e
    }
}
