import Foundation
import GRDB
import NoteBarCore

// Notification names (`.noteStoreWriteFailed`, `.noteStoreWriteRecovered`, `.backupDidFail`) and
// `NoteStoreWriteFailureKey` live in NoteBarCore (NoteStore.swift) so every module can observe them.

// MARK: - Write-behind with retry

/// How persistence works: every mutation updates the cache first and records the changed ids in the
/// `pending*` sets. `flush()` writes all pending records from the cache in ONE transaction
/// (full-record upserts, so a record whose INSERT failed earlier is inserted on retry). When the
/// transaction fails, nothing is removed from the pending sets, `writeFailing` turns on, observers
/// get `.noteStoreWriteFailed`, and a retry timer with backoff runs `flush()` again.
extension GRDBNoteStore {
    /// Runs a write transaction. Returns nil (and records `lastError`) on failure.
    @discardableResult
    func write<T>(_ what: String, _ updates: (Database) throws -> T) -> T? {
        guard let pool else {
            // Closed on purpose (restore in progress): not a failure episode. The change stays in
            // the cache; `reopen()` replaces the cache anyway.
            lastError = NoteStoreError.io("The database is closed (\(what)).")
            NSLog("NoteBarStore: database closed, not persisted: %@", what)
            return nil
        }
        do {
            return try pool.write(updates)
        } catch {
            recordWriteFailure(error, operation: what)
            return nil
        }
    }

    func recordWriteFailure(_ error: Error, operation: String) {
        lastError = error
        NSLog("NoteBarStore: %@ failed: %@", operation, String(describing: error))
        scheduleRetry()
        guard !writeFailing else { return }
        writeFailing = true
        NotificationCenter.default.post(name: .noteStoreWriteFailed, object: self, userInfo: [
            NoteStoreWriteFailureKey.error: error, NoteStoreWriteFailureKey.operation: operation,
        ])
    }

    /// Ends a failure episode once nothing is waiting to be saved.
    func noteWriteSucceededIfDrained() {
        guard writeFailing, !hasPendingChanges else { return }
        writeFailing = false
        lastError = nil
        retryTimer?.invalidate(); retryTimer = nil
        retryDelay = Self.initialRetryDelay
        NSLog("NoteBarStore: pending changes saved again")
        NotificationCenter.default.post(name: .noteStoreWriteRecovered, object: self)
    }

    static var initialRetryDelay: TimeInterval { 2 }
    static var maxRetryDelay: TimeInterval { 60 }

    /// Keeps one retry timer. The delay doubles (up to `maxRetryDelay`) each time a retry fails;
    /// failures of user-triggered writes do not push the next retry further out.
    func scheduleRetry() {
        guard retryTimer == nil, pool != nil else { return }
        let timer = Timer(timeInterval: retryDelay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.retryTimer = nil
                self.retryDelay = min(self.retryDelay * 2, Self.maxRetryDelay)
                self.flush()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        retryTimer = timer
    }

    func cancelTimers() {
        cancelDebounce()
        retryTimer?.invalidate(); retryTimer = nil
    }

    func cancelDebounce() {
        debounceTimer?.invalidate(); debounceTimer = nil
        firstPendingAt = nil
    }

    /// Forgets all unsaved changes (the cache is about to be replaced by `reopen()`).
    func discardPending() {
        pendingNoteIDs.removeAll()
        pendingFolderIDs.removeAll()
        pendingAttachmentIDs.removeAll()
        pendingThemeIDs.removeAll()
        pendingNoteDeletes.removeAll()
        pendingFolderDeletes.removeAll()
        pendingAttachmentDeletes.removeAll()
        pendingThemeDeletes.removeAll()
        pendingFileRemovals.removeAll()
        cancelTimers()
        writeFailing = false
        lastError = nil
        retryDelay = Self.initialRetryDelay
    }

    var pendingCount: Int {
        pendingNoteIDs.count + pendingFolderIDs.count + pendingAttachmentIDs.count + pendingThemeIDs.count
            + pendingNoteDeletes.count + pendingFolderDeletes.count + pendingAttachmentDeletes.count
            + pendingThemeDeletes.count
    }

    /// Writes every pending change now. On failure everything stays pending and a retry is scheduled.
    public func flush() {
        cancelDebounce()
        guard pool != nil else { return }
        guard hasPendingChanges else {
            deletePendingFiles()
            noteWriteSucceededIfDrained()
            return
        }
        // Sorted by id so transient (negative) parents are written in a stable order; parents
        // (folders) before children (notes) before attachments, upserts before deletes.
        let folders = pendingFolderIDs.compactMap { folderMap[$0] }.sorted { $0.id < $1.id }
        let notes = pendingNoteIDs.compactMap { noteMap[$0] }.sorted { $0.id < $1.id }
        let attachments = pendingAttachmentIDs.compactMap { attachmentMap[$0] }
        let themes = pendingThemeIDs.compactMap { themeMap[$0] }
        let attachmentDeletes = Array(pendingAttachmentDeletes)
        let noteDeletes = Array(pendingNoteDeletes)
        let folderDeletes = Array(pendingFolderDeletes)
        let themeDeletes = Array(pendingThemeDeletes)
        let ok: Void? = write("save changes") { db in
            for f in folders { try db.execute(sql: SQL.upsertFolder, arguments: SQL.folderUpsertArgs(f)) }
            for n in notes { try db.execute(sql: SQL.upsertNote, arguments: SQL.noteUpsertArgs(n)) }
            for a in attachments {
                try db.execute(sql: "UPDATE attachment SET noteId = ?, bookmarkData = ? WHERE id = ?",
                               arguments: [a.noteId, a.bookmarkData, a.id])
            }
            for t in themes {
                let data = try JSONEncoder().encode(t)
                try db.execute(sql: SQL.upsertTheme, arguments: [t.id, t.name, data, Date().timeIntervalSince1970])
            }
            for id in attachmentDeletes { try db.execute(sql: "DELETE FROM attachment WHERE id = ?", arguments: [id]) }
            // Notes + their remaining attachments cascade.
            for id in noteDeletes { try db.execute(sql: "DELETE FROM note WHERE id = ?", arguments: [id]) }
            for id in folderDeletes { try db.execute(sql: "DELETE FROM folder WHERE id = ?", arguments: [id]) }
            for id in themeDeletes { try db.execute(sql: "DELETE FROM theme WHERE id = ?", arguments: [id]) }
        }
        guard ok != nil else { return }
        // The main actor is not re-entered during the synchronous write, so the sets still hold
        // exactly what was written.
        discardPendingRecordsAfterSuccess()
        deletePendingFiles()
        noteWriteSucceededIfDrained()
    }

    private func discardPendingRecordsAfterSuccess() {
        pendingNoteIDs.removeAll()
        pendingFolderIDs.removeAll()
        pendingAttachmentIDs.removeAll()
        pendingThemeIDs.removeAll()
        pendingNoteDeletes.removeAll()
        pendingFolderDeletes.removeAll()
        pendingAttachmentDeletes.removeAll()
        pendingThemeDeletes.removeAll()
    }

    /// Image files of deleted attachment rows are removed only after the rows are gone from the database.
    private func deletePendingFiles() {
        guard !pendingFileRemovals.isEmpty else { return }
        let files = pendingFileRemovals
        pendingFileRemovals.removeAll()
        deleteImageFiles(of: files)
    }

    // MARK: Linked attachments survive their owner

    /// For attachments owned by notes that are about to be deleted: the first surviving note (lowest id)
    /// whose body still links each attachment. Links are copied between notes by copy/cut/paste and
    /// drag and drop, and the link token keeps the attachment id.
    func survivingLinkOwners(of owned: [Attachment], deleting deleted: Set<NoteID>) -> [AttachmentID: NoteID] {
        guard !owned.isEmpty else { return [:] }
        let wanted = Set(owned.map(\.id))
        var result: [AttachmentID: NoteID] = [:]
        let candidates = noteMap.values
            .filter { !deleted.contains($0.id) && $0.body.contains("](attachment:") }
            .sorted { $0.id < $1.id }
        for n in candidates {
            for aid in AttachmentLink.attachmentIDs(in: n.body) where wanted.contains(aid) && result[aid] == nil {
                result[aid] = n.id
            }
            if result.count == wanted.count { break }
        }
        return result
    }

    /// Moves still-linked attachments of `deleted` notes to a surviving note (cache + pending) and
    /// returns the attachments that go away with the notes. Posts `.attachments` for new owners.
    func detachAttachments(ofDeleted deleted: Set<NoteID>) -> (removed: [Attachment], newOwners: Set<NoteID>) {
        let owned = attachmentMap.values.filter { deleted.contains($0.noteId) }
        let owners = survivingLinkOwners(of: owned, deleting: deleted)
        var removed: [Attachment] = []
        var newOwners = Set<NoteID>()
        for a in owned {
            if let owner = owners[a.id] {
                attachmentMap[a.id]?.noteId = owner
                pendingAttachmentIDs.insert(a.id)
                newOwners.insert(owner)
            } else {
                attachmentMap[a.id] = nil
                pendingAttachmentIDs.remove(a.id)
                removed.append(a)
            }
        }
        return (removed, newOwners)
    }
}

// MARK: - Upsert SQL

extension SQL {
    static let upsertFolder = """
        INSERT INTO folder (id, name, sortIndex, isPinned, color, createdAt, deletedAt) VALUES (?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(id) DO UPDATE SET name = excluded.name, sortIndex = excluded.sortIndex,
        isPinned = excluded.isPinned, color = excluded.color, deletedAt = excluded.deletedAt
        """
    static let upsertNote = """
        INSERT INTO note (id, folderId, body, color, sortIndex, isPinned, isFolded, mode, createdAt, updatedAt, deletedAt, archivedAt)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(id) DO UPDATE SET folderId = excluded.folderId, body = excluded.body, color = excluded.color,
        sortIndex = excluded.sortIndex, isPinned = excluded.isPinned, isFolded = excluded.isFolded,
        mode = excluded.mode, createdAt = excluded.createdAt, updatedAt = excluded.updatedAt,
        deletedAt = excluded.deletedAt, archivedAt = excluded.archivedAt
        """
    static let upsertTheme = """
        INSERT INTO theme (id, name, json, updatedAt) VALUES (?, ?, ?, ?)
        ON CONFLICT(id) DO UPDATE SET name = excluded.name, json = excluded.json, updatedAt = excluded.updatedAt
        """

    static func folderUpsertArgs(_ f: Folder) -> StatementArguments {
        [f.id, f.name, f.sortIndex, f.isPinned, f.color.rawValue, f.createdAt.timeIntervalSince1970,
         f.deletedAt?.timeIntervalSince1970]
    }
    static func noteUpsertArgs(_ n: Note) -> StatementArguments {
        [n.id, n.folderId, n.body, n.color.rawValue, n.sortIndex, n.isPinned, n.isFolded, n.mode.rawValue,
         n.createdAt.timeIntervalSince1970, n.updatedAt.timeIntervalSince1970, n.deletedAt?.timeIntervalSince1970,
         n.archivedAt?.timeIntervalSince1970]
    }
}
