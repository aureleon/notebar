import AppKit
import Foundation
import GRDB
import NoteBarCore

/// SQLite-backed `NoteStore` (GRDB, WAL mode).
///
/// All data lives in an in-memory cache that is loaded on open, so every read is synchronous and
/// cheap. Writes update the cache first, then the database. Metadata writes are persisted at once;
/// body edits from `updateNoteBody` are persisted with a short debounce (`bodySaveDelay`) and at
/// the latest after `maxBodySaveDelay` of continuous typing. `flush()` writes them immediately.
///
/// Semantics follow `InMemoryNoteStore` (the reference implementation).
@MainActor
public final class GRDBNoteStore: NoteStore {
    /// The data directory: `notebar.sqlite` + `attachments/`.
    public let directory: URL
    public var databaseURL: URL { directory.appendingPathComponent(StoreSchema.databaseFileName) }
    public var attachmentsDirectory: URL {
        directory.appendingPathComponent(StoreSchema.attachmentsFolderName, isDirectory: true)
    }

    /// Debounce for `updateNoteBody` persistence.
    public var bodySaveDelay: TimeInterval = 0.4
    /// Upper bound for how long a body edit may stay unsaved while the user keeps typing.
    public var maxBodySaveDelay: TimeInterval = 2.0
    /// Attachment rows that no note body links to are removed at launch once they are older than this.
    public var unreferencedAttachmentGracePeriod: TimeInterval = 24 * 3600

    /// The last persistence error (writes never throw through the `NoteStore` API).
    public private(set) var lastError: Error?
    /// False between `close()` and `reopen()`. Reads keep working from the cache while closed.
    public var isOpen: Bool { pool != nil }
    /// True when body edits are waiting for the debounce timer.
    public var hasPendingChanges: Bool { !pendingBodyIDs.isEmpty }

    // MARK: State
    var pool: DatabasePool?
    var folderMap: [FolderID: Folder] = [:]
    var noteMap: [NoteID: Note] = [:]
    var attachmentMap: [AttachmentID: Attachment] = [:]
    var themeMap: [String: Theme] = [:]

    private var sortedFoldersCache: [Folder]?
    private var sortedNotesCache: [FolderID: [Note]] = [:]

    private var pendingBodyIDs: Set<NoteID> = []
    private var debounceTimer: Timer?
    private var firstPendingAt: Date?
    private var terminationObserver: NSObjectProtocol?
    /// Fallback ids for objects created while the database is unavailable (never persisted).
    private var transientID: Int64 = -1

    public init(directory: URL = AppPaths.supportDirectory) throws {
        self.directory = directory.standardizedFileURL
        try openDatabase()
        terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.flush() }
        }
    }

    // MARK: - Open / close

    private func openDatabase() throws {
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        try fm.createDirectory(at: attachmentsDirectory, withIntermediateDirectories: true)
        let pool = try DatabasePool(path: databaseURL.path, configuration: StoreSchema.configuration())
        do {
            try StoreSchema.migrator.migrate(pool)
            try loadCache(from: pool)
        } catch {
            try? pool.close()
            throw error
        }
        self.pool = pool
        lastError = nil
        ensureFolder()
        pruneUnreferencedAttachments(olderThan: unreferencedAttachmentGracePeriod)
        cleanupOrphanedAttachmentFiles()
    }

    private func loadCache(from pool: DatabasePool) throws {
        let (folders, notes, attachments, themes) = try pool.read { db in
            (try Row.fetchAll(db, sql: "SELECT * FROM folder").map(Folder.init(row:)),
             try Row.fetchAll(db, sql: "SELECT * FROM note").map(Note.init(row:)),
             try Row.fetchAll(db, sql: "SELECT * FROM attachment").compactMap(Attachment.init(row:)),
             try Row.fetchAll(db, sql: "SELECT id, json FROM theme").compactMap { row -> Theme? in
                 let data: Data = row["json"]
                 return try? JSONDecoder().decode(Theme.self, from: data)
             })
        }
        folderMap = Dictionary(uniqueKeysWithValues: folders.map { ($0.id, $0) })
        noteMap = Dictionary(uniqueKeysWithValues: notes.map { ($0.id, $0) })
        attachmentMap = Dictionary(uniqueKeysWithValues: attachments.map { ($0.id, $0) })
        themeMap = Dictionary(themes.map { ($0.id, $0) }, uniquingKeysWith: { _, b in b })
        invalidateAll()
    }

    /// Flushes pending edits and closes the database (e.g. before a restore swaps the files).
    /// Reads keep returning the cached data; writes are kept in memory only until `reopen()`.
    public func close() throws {
        flush()
        debounceTimer?.invalidate(); debounceTimer = nil
        guard let pool else { return }
        // Fold the WAL into the main file so the database file alone is complete.
        _ = try? pool.writeWithoutTransaction { db in try db.checkpoint(.truncate) }
        try pool.close()
        self.pool = nil
    }

    /// Closes (if open) and opens the database in `directory` again, reloads the cache and posts `.all`.
    public func reopen() throws {
        if pool != nil { try close() }
        pendingBodyIDs.removeAll()
        try openDatabase()
        postStoreChange(.all, sender: self)
    }

    /// Writes a consistent copy of the database (including pending edits) to `url` using SQLite's
    /// online backup API. The copy is a standalone file (rollback journal mode).
    public func writeSnapshot(to url: URL) throws {
        flush()
        guard let pool else { throw NoteStoreError.io("The database is closed.") }
        try? FileManager.default.removeItem(at: url)
        let dest = try DatabaseQueue(path: url.path)
        do {
            try pool.backup(to: dest)
            try dest.writeWithoutTransaction { db in try db.execute(sql: "PRAGMA journal_mode = DELETE") }
            try dest.close()
        } catch {
            try? dest.close()
            throw error
        }
    }

    /// SQLite journal mode of the open database ("wal"), nil when closed. Diagnostics / checks.
    public func journalMode() -> String? {
        try? pool?.read { db in try String.fetchOne(db, sql: "PRAGMA journal_mode") }
    }

    // MARK: - Write helpers

    /// Runs a write transaction. Returns nil (and records `lastError`) on failure.
    @discardableResult
    func write<T>(_ what: String, _ updates: (Database) throws -> T) -> T? {
        guard let pool else {
            lastError = NoteStoreError.io("The database is closed (\(what)).")
            NSLog("NoteBarStore: database closed, not persisted: %@", what)
            return nil
        }
        do {
            return try pool.write(updates)
        } catch {
            lastError = error
            NSLog("NoteBarStore: %@ failed: %@", what, String(describing: error))
            return nil
        }
    }

    private func nextTransientID() -> Int64 { defer { transientID -= 1 }; return transientID }

    private func invalidateAll() {
        sortedFoldersCache = nil
        sortedNotesCache.removeAll()
    }

    private func invalidateNotes(in folderId: FolderID) { sortedNotesCache[folderId] = nil }

    private func ensureFolder() {
        if folderMap.isEmpty { _ = createFolder(name: "Notes") }
    }

    // MARK: - Folders

    public func folders() -> [Folder] {
        if let cached = sortedFoldersCache { return cached }
        let list = folderMap.values.sorted {
            ($0.isPinned ? 0 : 1, $0.sortIndex, $0.id) < ($1.isPinned ? 0 : 1, $1.sortIndex, $1.id)
        }
        sortedFoldersCache = list
        return list
    }

    public func folder(id: FolderID) -> Folder? { folderMap[id] }

    public func noteCount(in folderId: FolderID) -> Int { notes(in: folderId).count }

    @discardableResult
    public func createFolder(name: String) -> Folder {
        var f = Folder(id: 0, name: name, sortIndex: SortIndex.between(folders().last?.sortIndex, nil),
                       createdAt: .storeNow)
        let id = write("create folder") { db -> Int64 in
            try db.execute(sql: SQL.insertFolder, arguments: SQL.folderInsertArgs(f))
            return db.lastInsertedRowID
        }
        f.id = id ?? nextTransientID()
        folderMap[f.id] = f
        sortedFoldersCache = nil
        postStoreChange(.folders, sender: self)
        return f
    }

    public func updateFolder(_ folder: Folder) {
        guard let old = folderMap[folder.id] else { return }
        var f = folder
        f.createdAt = old.createdAt
        write("update folder") { db in try db.execute(sql: SQL.updateFolder, arguments: SQL.folderUpdateArgs(f)) }
        folderMap[f.id] = f
        sortedFoldersCache = nil
        postStoreChange(.folders, sender: self)
    }

    public func deleteFolder(id: FolderID) {
        guard folderMap.count > 1, folderMap[id] != nil else { return }
        let noteIDs = Set(noteMap.values.filter { $0.folderId == id }.map(\.id))
        let removed = attachmentMap.values.filter { noteIDs.contains($0.noteId) }
        let deleted = write("delete folder") { db in
            // Notes + attachments cascade.
            try db.execute(sql: "DELETE FROM folder WHERE id = ?", arguments: [id])
        } != nil
        for nid in noteIDs { noteMap[nid] = nil; pendingBodyIDs.remove(nid) }
        for a in removed { attachmentMap[a.id] = nil }
        folderMap[id] = nil
        invalidateAll()
        if deleted { deleteImageFiles(of: removed) }
        postStoreChange(.notes(folderId: id), sender: self)
        postStoreChange(.folders, sender: self)
    }

    public func moveFolder(id: FolderID, toIndex index: Int) {
        var list = folders()
        guard let from = list.firstIndex(where: { $0.id == id }) else { return }
        var f = list.remove(at: from)
        let i = max(0, min(index, list.count))
        let p = Self.placement(at: i, in: list.map(\.sortIndex))
        f.sortIndex = p.value
        var changed = [f]
        for (k, v) in p.renumbered where list[k].sortIndex != v {
            list[k].sortIndex = v; changed.append(list[k])
        }
        write("move folder") { db in
            for r in changed {
                try db.execute(sql: "UPDATE folder SET sortIndex = ? WHERE id = ?", arguments: [r.sortIndex, r.id])
            }
        }
        for r in changed { folderMap[r.id]?.sortIndex = r.sortIndex }
        sortedFoldersCache = nil
        postStoreChange(.folders, sender: self)
    }

    /// The sort index for inserting at position `i` of `values` (a list sorted in display order).
    /// When the neighbors are too close (gaps collapsed after many reorders), the whole list is
    /// renumbered: `renumbered` holds (index in `values`, new value) pairs and `value` fits the new numbering.
    static func placement(at i: Int, in values: [Double]) -> (value: Double, renumbered: [(Int, Double)]) {
        let a = i > 0 ? values[i - 1] : nil
        let b = i < values.count ? values[i] : nil
        let v = SortIndex.between(a, b)
        guard let a, let b, SortIndex.needsRebalance(a, b) || !(v > a && v < b) else { return (v, []) }
        let fresh = SortIndex.rebalanced(count: values.count)
        let value = SortIndex.between(i > 0 ? fresh[i - 1] : nil, i < fresh.count ? fresh[i] : nil)
        return (value, Array(fresh.enumerated()))
    }

    // MARK: - Notes

    public func notes(in folderId: FolderID) -> [Note] {
        if let cached = sortedNotesCache[folderId] { return cached }
        let list = noteMap.values.filter { $0.folderId == folderId }.sorted {
            ($0.isPinned ? 0 : 1, $0.sortIndex, $0.id) < ($1.isPinned ? 0 : 1, $1.sortIndex, $1.id)
        }
        sortedNotesCache[folderId] = list
        return list
    }

    public func note(id: NoteID) -> Note? { noteMap[id] }

    /// Case- and diacritic-insensitive substring search over bodies, in display order
    /// (folders order, then notes order).
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
        let idx = position == .top ? SortIndex.between(nil, list.first?.sortIndex)
                                   : SortIndex.between(list.last?.sortIndex, nil)
        let now = Date.storeNow
        var n = Note(id: 0, folderId: fid, body: body, sortIndex: idx, mode: mode, createdAt: now, updatedAt: now)
        let id = write("create note") { db -> Int64 in
            try db.execute(sql: SQL.insertNote, arguments: SQL.noteInsertArgs(n))
            return db.lastInsertedRowID
        }
        n.id = id ?? nextTransientID()
        noteMap[n.id] = n
        invalidateNotes(in: fid)
        postStoreChange(.notes(folderId: fid), sender: self)
        postStoreChange(.folders, sender: self)
        return n
    }

    public func updateNoteBody(id: NoteID, body: String) {
        guard var n = noteMap[id], n.body != body else { return }
        n.body = body
        n.updatedAt = .storeNow
        noteMap[id] = n
        replaceInSortedCache(n)
        pendingBodyIDs.insert(id)
        scheduleBodySave()
        postStoreChange(.noteBody(id: id), sender: self)
    }

    public func updateNote(_ note: Note) {
        guard let old = noteMap[note.id] else { return }
        var n = note
        if folderMap[n.folderId] == nil { n.folderId = old.folderId }
        n.createdAt = n.createdAt.storeNormalized
        n.updatedAt = .storeNow
        write("update note") { db in try db.execute(sql: SQL.updateNote, arguments: SQL.noteUpdateArgs(n)) }
        // The full record (incl. body) is now persisted.
        pendingBodyIDs.remove(n.id)
        noteMap[n.id] = n
        let orderChanged = old.isPinned != n.isPinned || old.folderId != n.folderId || old.sortIndex != n.sortIndex
        if orderChanged {
            invalidateNotes(in: old.folderId); invalidateNotes(in: n.folderId)
        } else {
            replaceInSortedCache(n)
        }
        postStoreChange(.note(id: n.id), sender: self)
        if orderChanged { postStoreChange(.notes(folderId: n.folderId), sender: self) }
        if old.folderId != n.folderId {
            postStoreChange(.notes(folderId: old.folderId), sender: self)
            postStoreChange(.folders, sender: self)
        }
    }

    public func deleteNote(id: NoteID) {
        guard let n = noteMap[id] else { return }
        let removed = attachmentMap.values.filter { $0.noteId == id }
        let deleted = write("delete note") { db in
            try db.execute(sql: "DELETE FROM note WHERE id = ?", arguments: [id])
        } != nil
        noteMap[id] = nil
        pendingBodyIDs.remove(id)
        for a in removed { attachmentMap[a.id] = nil }
        invalidateNotes(in: n.folderId)
        if deleted { deleteImageFiles(of: removed) }
        postStoreChange(.notes(folderId: n.folderId), sender: self)
        postStoreChange(.folders, sender: self)
    }

    public func moveNote(id: NoteID, toIndex index: Int) {
        guard let n0 = noteMap[id] else { return }
        var list = notes(in: n0.folderId)
        guard let from = list.firstIndex(where: { $0.id == id }) else { return }
        var n = list.remove(at: from)
        let i = max(0, min(index, list.count))
        let p = Self.placement(at: i, in: list.map(\.sortIndex))
        n.sortIndex = p.value
        var changed = [n]
        for (k, v) in p.renumbered where list[k].sortIndex != v {
            list[k].sortIndex = v; changed.append(list[k])
        }
        write("move note") { db in
            for r in changed {
                try db.execute(sql: "UPDATE note SET sortIndex = ? WHERE id = ?", arguments: [r.sortIndex, r.id])
            }
        }
        for r in changed { noteMap[r.id]?.sortIndex = r.sortIndex }
        invalidateNotes(in: n.folderId)
        postStoreChange(.notes(folderId: n.folderId), sender: self)
    }

    public func moveNote(id: NoteID, toFolder folderId: FolderID, position: InsertPosition) {
        guard var n = noteMap[id], folderMap[folderId] != nil else { return }
        let old = n.folderId
        let list = notes(in: folderId).filter { !$0.isPinned && $0.id != id }
        n.folderId = folderId
        n.sortIndex = position == .top ? SortIndex.between(nil, list.first?.sortIndex)
                                       : SortIndex.between(list.last?.sortIndex, nil)
        write("move note to folder") { db in
            try db.execute(sql: "UPDATE note SET folderId = ?, sortIndex = ? WHERE id = ?",
                           arguments: [n.folderId, n.sortIndex, n.id])
        }
        noteMap[id] = n
        invalidateNotes(in: old); invalidateNotes(in: folderId)
        postStoreChange(.notes(folderId: old), sender: self)
        if old != folderId { postStoreChange(.notes(folderId: folderId), sender: self) }
        postStoreChange(.folders, sender: self)
    }

    private func replaceInSortedCache(_ n: Note) {
        guard var list = sortedNotesCache[n.folderId] else { return }
        if let i = list.firstIndex(where: { $0.id == n.id }) {
            list[i] = n
            sortedNotesCache[n.folderId] = list
        } else {
            sortedNotesCache[n.folderId] = nil
        }
    }

    // MARK: - Debounced body persistence

    private func scheduleBodySave() {
        let now = Date()
        if firstPendingAt == nil { firstPendingAt = now }
        let deadline = min(now.addingTimeInterval(bodySaveDelay), firstPendingAt!.addingTimeInterval(maxBodySaveDelay))
        debounceTimer?.invalidate()
        let timer = Timer(fire: deadline, interval: 0, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.flush() }
        }
        RunLoop.main.add(timer, forMode: .common)
        debounceTimer = timer
    }

    public func flush() {
        debounceTimer?.invalidate()
        debounceTimer = nil
        firstPendingAt = nil
        guard !pendingBodyIDs.isEmpty, pool != nil else { return }
        let notes = pendingBodyIDs.compactMap { noteMap[$0] }
        let ok: Void? = write("save note bodies") { db in
            for n in notes {
                try db.execute(sql: SQL.updateNoteBody,
                               arguments: [n.body, n.updatedAt.timeIntervalSince1970, n.id])
            }
        }
        // On failure the edits stay pending and are retried on the next flush.
        if ok != nil { pendingBodyIDs.removeAll() }
    }
}
