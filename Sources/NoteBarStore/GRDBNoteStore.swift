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
/// Failed writes are never dropped: the changed records stay pending and are retried with backoff
/// (see `GRDBNoteStore+Persistence.swift`). `.noteStoreWriteFailed` / `.noteStoreWriteRecovered`
/// tell the app about a failure episode; `lastError` / `hasPendingChanges` describe the current state.
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

    /// The error of the current failure episode (nil once all failed changes are saved again).
    /// Writes never throw through the `NoteStore` API.
    public internal(set) var lastError: Error?
    /// True from a failed write until every pending change is saved again.
    public internal(set) var writeFailing = false
    /// False between `close()` and `reopen()`. Reads keep working from the cache while closed.
    public var isOpen: Bool { pool != nil }
    /// True when changes are not in the database yet (debounced body edits, or writes waiting for a retry).
    public var hasPendingChanges: Bool { pendingCount > 0 }

    // MARK: State
    var pool: DatabasePool?
    var folderMap: [FolderID: Folder] = [:]
    var noteMap: [NoteID: Note] = [:]
    var attachmentMap: [AttachmentID: Attachment] = [:]
    var themeMap: [String: Theme] = [:]

    private var sortedFoldersCache: [Folder]?
    private var sortedNotesCache: [FolderID: [Note]] = [:]

    // Pending changes (written from the cache by `flush()`).
    var pendingNoteIDs: Set<NoteID> = []
    var pendingFolderIDs: Set<FolderID> = []
    var pendingAttachmentIDs: Set<AttachmentID> = []
    var pendingThemeIDs: Set<String> = []
    var pendingNoteDeletes: Set<NoteID> = []
    var pendingFolderDeletes: Set<FolderID> = []
    var pendingAttachmentDeletes: Set<AttachmentID> = []
    var pendingThemeDeletes: Set<String> = []
    var pendingFileRemovals: [Attachment] = []

    var debounceTimer: Timer?
    var retryTimer: Timer?
    var retryDelay: TimeInterval = GRDBNoteStore.initialRetryDelay
    var firstPendingAt: Date?
    private var terminationObserver: NSObjectProtocol?
    /// Ids for objects whose INSERT failed. Negative, so they never collide with AUTOINCREMENT ids;
    /// the record is inserted with this id by a later `flush()`.
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
        transientID = min(-1, (noteMap.keys.min() ?? 0) - 1, (folderMap.keys.min() ?? 0) - 1)
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
        cancelTimers()
        guard let pool else { return }
        // Fold the WAL into the main file so the database file alone is complete.
        _ = try? pool.writeWithoutTransaction { db in try db.checkpoint(.truncate) }
        try pool.close()
        self.pool = nil
    }

    /// Closes (if open) and opens the database in `directory` again, reloads the cache and posts `.all`.
    public func reopen() throws {
        if pool != nil { try close() }
        discardPending()
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
        if let id { f.id = id } else { f.id = nextTransientID(); pendingFolderIDs.insert(f.id) }
        folderMap[f.id] = f
        sortedFoldersCache = nil
        postStoreChange(.folders, sender: self)
        return f
    }

    public func updateFolder(_ folder: Folder) {
        guard let old = folderMap[folder.id] else { return }
        var f = folder
        f.createdAt = old.createdAt
        folderMap[f.id] = f
        pendingFolderIDs.insert(f.id)
        flush()
        sortedFoldersCache = nil
        postStoreChange(.folders, sender: self)
    }

    public func deleteFolder(id: FolderID) {
        guard folderMap.count > 1, folderMap[id] != nil else { return }
        let noteIDs = Set(noteMap.values.filter { $0.folderId == id }.map(\.id))
        let (removed, newOwners) = detachAttachments(ofDeleted: noteIDs)
        for nid in noteIDs { noteMap[nid] = nil; pendingNoteIDs.remove(nid) }
        folderMap[id] = nil
        pendingFolderIDs.remove(id)
        // The folder DELETE cascades to its notes and their remaining attachments.
        pendingFolderDeletes.insert(id)
        pendingFileRemovals += removed
        invalidateAll()
        flush()
        postStoreChange(.notes(folderId: id), sender: self)
        postStoreChange(.folders, sender: self)
        for owner in newOwners.sorted() { postStoreChange(.attachments(noteId: owner), sender: self) }
    }

    public func moveFolder(id: FolderID, toIndex index: Int) {
        let all = folders()
        guard let f0 = all.first(where: { $0.id == id }) else { return }
        // Pinned folders always sort first: place the folder among its own zone only, so a move to
        // the pinned/unpinned boundary uses same-zone neighbors.
        let others = all.filter { $0.id != id }
        var list = others.filter { $0.isPinned == f0.isPinned }
        let offset = f0.isPinned ? 0 : others.count - list.count
        var f = f0
        let i = max(0, min(index - offset, list.count))
        let p = Self.placement(at: i, in: list.map(\.sortIndex))
        f.sortIndex = p.value
        var changed = [f]
        for (k, v) in p.renumbered where list[k].sortIndex != v {
            list[k].sortIndex = v; changed.append(list[k])
        }
        for r in changed { folderMap[r.id]?.sortIndex = r.sortIndex; pendingFolderIDs.insert(r.id) }
        sortedFoldersCache = nil
        flush()
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
        // A folder whose INSERT failed earlier must reach the database first (foreign key).
        if pendingFolderIDs.contains(fid) { flush() }
        let id = write("create note") { db -> Int64 in
            try db.execute(sql: SQL.insertNote, arguments: SQL.noteInsertArgs(n))
            return db.lastInsertedRowID
        }
        if let id { n.id = id } else { n.id = nextTransientID(); pendingNoteIDs.insert(n.id) }
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
        pendingNoteIDs.insert(id)
        scheduleBodySave()
        postStoreChange(.noteBody(id: id), sender: self)
    }

    public func updateNote(_ note: Note) {
        guard let old = noteMap[note.id] else { return }
        var n = note
        if folderMap[n.folderId] == nil { n.folderId = old.folderId }
        n.createdAt = n.createdAt.storeNormalized
        n.updatedAt = .storeNow
        noteMap[n.id] = n
        // The full record (incl. a pending body edit) is written now; on failure it stays pending.
        pendingNoteIDs.insert(n.id)
        flush()
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
        let (removed, newOwners) = detachAttachments(ofDeleted: [id])
        noteMap[id] = nil
        pendingNoteIDs.remove(id)
        // The note DELETE cascades to its remaining attachments.
        pendingNoteDeletes.insert(id)
        pendingFileRemovals += removed
        invalidateNotes(in: n.folderId)
        flush()
        postStoreChange(.notes(folderId: n.folderId), sender: self)
        postStoreChange(.folders, sender: self)
        for owner in newOwners.sorted() { postStoreChange(.attachments(noteId: owner), sender: self) }
    }

    public func moveNote(id: NoteID, toIndex index: Int) {
        guard let n0 = noteMap[id] else { return }
        // Pinned notes always sort first: place the note among its own zone only (see moveFolder).
        let others = notes(in: n0.folderId).filter { $0.id != id }
        var list = others.filter { $0.isPinned == n0.isPinned }
        let offset = n0.isPinned ? 0 : others.count - list.count
        var n = n0
        let i = max(0, min(index - offset, list.count))
        let p = Self.placement(at: i, in: list.map(\.sortIndex))
        n.sortIndex = p.value
        var changed = [n]
        for (k, v) in p.renumbered where list[k].sortIndex != v {
            list[k].sortIndex = v; changed.append(list[k])
        }
        for r in changed { noteMap[r.id]?.sortIndex = r.sortIndex; pendingNoteIDs.insert(r.id) }
        invalidateNotes(in: n.folderId)
        flush()
        postStoreChange(.notes(folderId: n.folderId), sender: self)
    }

    public func moveNote(id: NoteID, toFolder folderId: FolderID, position: InsertPosition) {
        guard var n = noteMap[id], folderMap[folderId] != nil else { return }
        let old = n.folderId
        let list = notes(in: folderId).filter { !$0.isPinned && $0.id != id }
        n.folderId = folderId
        n.sortIndex = position == .top ? SortIndex.between(nil, list.first?.sortIndex)
                                       : SortIndex.between(list.last?.sortIndex, nil)
        noteMap[id] = n
        pendingNoteIDs.insert(id)
        invalidateNotes(in: old); invalidateNotes(in: folderId)
        flush()
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
        // During a failure episode the retry timer (with backoff) saves the edits.
        if writeFailing { scheduleRetry(); return }
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
}
