import Foundation
import NoteBarCore
import NoteBarStore
import SQLite3

// Owned by the Store agent. Run: swift run --scratch-path .build-agents/store StoreChecks
// Every check runs in a fresh temporary directory; nothing touches the real Application Support data.

let fm = FileManager.default
let root = fm.temporaryDirectory.appendingPathComponent("StoreChecks-\(UUID().uuidString)", isDirectory: true)
try! fm.createDirectory(at: root, withIntermediateDirectories: true)

func freshDir(_ name: String) -> URL {
    let d = root.appendingPathComponent(name, isDirectory: true)
    try? fm.removeItem(at: d)
    try! fm.createDirectory(at: d, withIntermediateDirectories: true)
    return d
}

func spin(_ seconds: TimeInterval) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }

/// Records store notifications posted while `body` runs.
@MainActor
func changes(_ body: () -> Void) -> [StoreChange] {
    var seen: [StoreChange] = []
    let o = NotificationCenter.default.addObserver(forName: .noteStoreDidChange, object: nil, queue: nil) { n in
        if let c = n.storeChange { seen.append(c) }
    }
    body()
    NotificationCenter.default.removeObserver(o)
    return seen
}

/// A tiny valid 1x1 PNG.
let pngData = Data(base64Encoded:
    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==")!

func fileCount(_ dir: URL) -> Int {
    ((try? fm.contentsOfDirectory(atPath: dir.path)) ?? []).filter { !$0.hasPrefix(".") }.count
}

@MainActor
func makeSettings() -> AppSettings {
    let suite = "NoteBarStoreChecks-\(UUID().uuidString)"
    let d = UserDefaults(suiteName: suite)!
    d.removePersistentDomain(forName: suite)
    return AppSettings(defaults: d)
}

/// Runs SQL on the store's database file from a separate SQLite connection (simulates failures).
func rawSQL(_ dir: URL, _ sql: String) {
    var db: OpaquePointer?
    guard sqlite3_open(dir.appendingPathComponent("notebar.sqlite").path, &db) == SQLITE_OK else {
        Check.expect(false, "raw sqlite open"); return
    }
    sqlite3_busy_timeout(db, 5000)
    var err: UnsafeMutablePointer<CChar>?
    if sqlite3_exec(db, sql, nil, nil, &err) != SQLITE_OK {
        Check.expect(false, "raw sql failed: \(err.map { String(cString: $0) } ?? "?")")
        sqlite3_free(err)
    }
    sqlite3_close(db)
}

/// Makes every write to note/folder/attachment/theme fail (like a full disk) until `allowWrites`.
func failWrites(_ dir: URL) {
    var sql = ""
    for table in ["note", "folder", "attachment", "theme"] {
        for op in ["INSERT", "UPDATE", "DELETE"] {
            sql += "CREATE TRIGGER fail_\(table)_\(op) BEFORE \(op) ON \(table) BEGIN SELECT RAISE(ABORT, 'simulated disk full'); END;\n"
        }
    }
    rawSQL(dir, sql)
}

func allowWrites(_ dir: URL) {
    var sql = ""
    for table in ["note", "folder", "attachment", "theme"] {
        for op in ["INSERT", "UPDATE", "DELETE"] { sql += "DROP TRIGGER IF EXISTS fail_\(table)_\(op);\n" }
    }
    rawSQL(dir, sql)
}

/// Counts notifications with `name` posted while `body` runs.
@MainActor
func count(_ name: Notification.Name, _ body: () -> Void) -> Int {
    var n = 0
    let o = NotificationCenter.default.addObserver(forName: name, object: nil, queue: nil) { _ in n += 1 }
    body()
    NotificationCenter.default.removeObserver(o)
    return n
}

MainActor.assumeIsolated {

// MARK: - Open, default folder, WAL
do {
    let dir = freshDir("basic")
    let store = try! GRDBNoteStore(directory: dir)
    Check.equal(store.folders().map(\.name), ["Notes"], "empty store creates Notes")
    Check.equal(store.journalMode(), "wal", "WAL mode")
    Check.expect(fm.fileExists(atPath: dir.appendingPathComponent("notebar.sqlite").path), "database file exists")
    Check.expect(fm.fileExists(atPath: dir.appendingPathComponent("attachments").path), "attachments folder exists")
    Check.equal(store.directory.standardizedFileURL.path, dir.standardizedFileURL.path, "directory")
    Check.expect(store.isOpen, "isOpen")

    // MARK: Folder CRUD + ordering
    let notesFolder = store.folders()[0]
    var c = changes { _ = store.createFolder(name: "Work") }
    Check.equal(c, [.folders], "createFolder posts .folders")
    let work = store.folders().first { $0.name == "Work" }!
    let ideas = store.createFolder(name: "Ideas")
    Check.equal(store.folders().map(\.name), ["Notes", "Work", "Ideas"], "folders appended at bottom")

    var renamed = ideas; renamed.name = "Ideas & Plans"; renamed.color = .blue
    store.updateFolder(renamed)
    Check.equal(store.folder(id: ideas.id)?.name, "Ideas & Plans", "rename folder")
    Check.equal(store.folder(id: ideas.id)?.color, .blue, "folder color")
    Check.equal(store.folder(named: "ideas & plans")?.id, ideas.id, "folder(named:) case-insensitive")

    var pinnedIdeas = store.folder(id: ideas.id)!; pinnedIdeas.isPinned = true
    store.updateFolder(pinnedIdeas)
    Check.equal(store.folders().map(\.id), [ideas.id, notesFolder.id, work.id], "pinned folder first")
    store.moveFolder(id: work.id, toIndex: 1)
    Check.equal(store.folders().map(\.id), [ideas.id, work.id, notesFolder.id], "moveFolder")
    store.moveFolder(id: notesFolder.id, toIndex: 99)
    Check.equal(store.folders().map(\.id), [ideas.id, work.id, notesFolder.id], "moveFolder clamps index")

    // MARK: Note CRUD + ordering
    c = changes { _ = store.createNote(in: notesFolder.id, body: "First") }
    Check.expect(c.contains(.notes(folderId: notesFolder.id)) && c.contains(.folders), "createNote posts .notes + .folders")
    let first = store.notes(in: notesFolder.id)[0]
    let second = store.createNote(in: notesFolder.id, body: "Second", mode: .code, position: .top)
    let third = store.createNote(in: notesFolder.id, body: "Third", mode: .plain, position: .bottom)
    Check.equal(store.notes(in: notesFolder.id).map(\.body), ["Second", "First", "Third"], "top/bottom insert")
    Check.equal(store.note(id: second.id)?.mode, .code, "mode stored")
    Check.equal(store.noteCount(in: notesFolder.id), 3, "noteCount")
    let stray = store.createNote(in: 999_999, body: "Stray", mode: .standard, position: .top)
    Check.equal(stray.folderId, store.folders()[0].id, "createNote with unknown folder uses first folder")
    store.deleteNote(id: stray.id)
    Check.expect(store.note(id: stray.id) == nil, "deleteNote")

    // Pin: pinned first; new top notes go below pinned notes.
    var pinned = store.note(id: third.id)!; pinned.isPinned = true; pinned.color = .yellow
    c = changes { store.updateNote(pinned) }
    Check.expect(c.contains(.note(id: third.id)) && c.contains(.notes(folderId: notesFolder.id)), "pin posts .note + .notes")
    Check.equal(store.notes(in: notesFolder.id).map(\.body), ["Third", "Second", "First"], "pinned note first")
    let newTop = store.createNote(in: notesFolder.id, body: "New top", mode: .standard, position: .top)
    Check.equal(store.notes(in: notesFolder.id).map(\.id), [third.id, newTop.id, second.id, first.id],
                "new top note goes below pinned")
    var folded = store.note(id: first.id)!; folded.isFolded = true
    c = changes { store.updateNote(folded) }
    Check.equal(c, [.note(id: first.id)], "metadata-only update posts only .note")
    Check.equal(store.note(id: first.id)?.isFolded, true, "fold stored")

    // Reorder.
    store.moveNote(id: first.id, toIndex: 1)
    Check.equal(store.notes(in: notesFolder.id).map(\.id), [third.id, first.id, newTop.id, second.id], "moveNote toIndex")
    store.moveNote(id: first.id, toIndex: 100)
    Check.equal(store.notes(in: notesFolder.id).last?.id, first.id, "moveNote clamps to end")
    // Zone-aware: an unpinned note cannot move above pinned notes, and lands just below them.
    store.moveNote(id: first.id, toIndex: 0)
    Check.equal(store.notes(in: notesFolder.id).map(\.id), [third.id, first.id, newTop.id, second.id],
                "moveNote clamps to the unpinned zone")
    store.moveNote(id: third.id, toIndex: 3)
    Check.equal(store.notes(in: notesFolder.id).first?.id, third.id, "pinned note stays in the pinned zone")

    // Move between folders.
    let w1 = store.createNote(in: work.id, body: "Work 1")
    c = changes { store.moveNote(id: second.id, toFolder: work.id, position: .bottom) }
    Check.expect(c.contains(.notes(folderId: notesFolder.id)) && c.contains(.notes(folderId: work.id))
                 && c.contains(.folders), "move to folder posts both folders + .folders")
    Check.equal(store.notes(in: work.id).map(\.id), [w1.id, second.id], "moved to bottom")
    Check.equal(store.noteCount(in: notesFolder.id), 3, "source count")
    store.moveNote(id: first.id, toFolder: work.id, position: .top)
    Check.equal(store.notes(in: work.id).map(\.id), [first.id, w1.id, second.id], "moved to top")
    Check.equal(store.note(id: first.id)?.folderId, work.id, "folderId updated")

    // Persistence of all of the above after close/reopen of the same instance.
    let beforeFolders = store.folders()
    let beforeWork = store.notes(in: work.id)
    let beforeNotes = store.notes(in: notesFolder.id)
    try! store.close()
    Check.expect(!store.isOpen, "closed")
    Check.equal(store.notes(in: work.id).map(\.id), beforeWork.map(\.id), "reads work while closed")
    var all = false
    let o = NotificationCenter.default.addObserver(forName: .noteStoreDidChange, object: store, queue: nil) { n in
        if n.storeChange == .all { all = true }
    }
    try! store.reopen()
    NotificationCenter.default.removeObserver(o)
    Check.expect(all, "reopen posts .all")
    Check.equal(store.folders(), beforeFolders, "folders persisted exactly")
    Check.equal(store.notes(in: work.id), beforeWork, "work notes persisted exactly")
    Check.equal(store.notes(in: notesFolder.id), beforeNotes, "notes persisted exactly")

    // A completely new instance sees the same.
    let store2 = try! GRDBNoteStore(directory: dir)
    Check.equal(store2.folders(), beforeFolders, "second instance folders")
    Check.equal(store2.notes(in: work.id), beforeWork, "second instance notes")
    Check.equal(store2.note(id: third.id)?.color, .yellow, "color persisted")
    Check.equal(store2.note(id: third.id)?.isPinned, true, "pin persisted")
    try! store2.close()

    // Delete folder: never the last one; deletes notes.
    store.deleteFolder(id: work.id)
    Check.expect(store.folder(id: work.id) == nil, "deleteFolder")
    Check.expect(store.note(id: w1.id) == nil && store.note(id: second.id) == nil, "folder notes deleted")
    store.deleteFolder(id: ideas.id)
    let last = store.folders()
    Check.equal(last.count, 1, "one folder left")
    store.deleteFolder(id: last[0].id)
    Check.equal(store.folders().count, 1, "never deletes the last folder")
    try! store.reopen()
    Check.expect(store.note(id: w1.id) == nil, "deleted note stays deleted after reopen")
    Check.equal(store.folders().count, 1, "folder count after reopen")
    try! store.close()
}

// MARK: - Rebalance of collapsed gaps
do {
    let dir = freshDir("rebalance")
    let store = try! GRDBNoteStore(directory: dir)
    let fid = store.folders()[0].id
    for i in 0..<5 { _ = store.createNote(in: fid, body: "n\(i)", mode: .standard, position: .bottom) }
    var expected = store.notes(in: fid).map(\.id)
    // Always move the last note between the first two: the gap halves every time and would
    // collapse below double precision after ~60 moves without a rebalance.
    for _ in 0..<200 {
        let id = expected.removeLast()
        expected.insert(id, at: 1)
        store.moveNote(id: id, toIndex: 1)
    }
    let list = store.notes(in: fid)
    Check.equal(list.map(\.id), expected, "order correct after 200 squeezing moves")
    let idx = list.map(\.sortIndex)
    Check.expect(zip(idx, idx.dropFirst()).allSatisfy { $1 - $0 > 1e-6 }, "sort indexes strictly increasing with real gaps")
    try! store.reopen()
    Check.equal(store.notes(in: fid).map(\.id), expected, "rebalanced order persisted")

    // Folders as well.
    for i in 0..<4 { _ = store.createFolder(name: "F\(i)") }
    var fexp = store.folders().map(\.id)
    for _ in 0..<200 {
        let id = fexp.removeLast()
        fexp.insert(id, at: 1)
        store.moveFolder(id: id, toIndex: 1)
    }
    Check.equal(store.folders().map(\.id), fexp, "folder order correct after squeezing moves")
    try! store.reopen()
    Check.equal(store.folders().map(\.id), fexp, "folder order persisted")
    try! store.close()
}

// MARK: - Debounced body saves, flush, reopen
do {
    let dir = freshDir("debounce")
    let store = try! GRDBNoteStore(directory: dir)
    let fid = store.folders()[0].id
    let n = store.createNote(in: fid, body: "Hello")
    let createdUpdatedAt = n.updatedAt
    usleep(20_000)

    var c = changes { store.updateNoteBody(id: n.id, body: "Hello w") }
    Check.equal(c, [.noteBody(id: n.id)], "updateNoteBody posts only .noteBody")
    store.updateNoteBody(id: n.id, body: "Hello world")
    c = changes { store.updateNoteBody(id: n.id, body: "Hello world") }
    Check.equal(c, [], "unchanged body posts nothing")
    Check.equal(store.note(id: n.id)?.body, "Hello world", "read reflects pending edit")
    Check.equal(store.notes(in: fid).first?.body, "Hello world", "notes(in:) reflects pending edit")
    Check.equal(store.search("world", in: nil).map(\.id), [n.id], "search reflects pending edit")
    Check.expect(store.note(id: n.id)!.updatedAt > createdUpdatedAt, "updatedAt bumped")
    Check.expect(store.hasPendingChanges, "edit is pending")

    let peek1 = try! GRDBNoteStore(directory: dir)
    Check.equal(peek1.note(id: n.id)?.body, "Hello", "not persisted before the debounce fires")
    try! peek1.close()

    spin(0.8)
    Check.expect(!store.hasPendingChanges, "debounce fired")
    let peek2 = try! GRDBNoteStore(directory: dir)
    Check.equal(peek2.note(id: n.id)?.body, "Hello world", "persisted after the debounce")
    Check.equal(peek2.note(id: n.id)?.updatedAt, store.note(id: n.id)?.updatedAt, "updatedAt persisted exactly")
    try! peek2.close()

    store.updateNoteBody(id: n.id, body: "Flushed now")
    store.flush()
    Check.expect(!store.hasPendingChanges, "flush clears pending")
    let peek3 = try! GRDBNoteStore(directory: dir)
    Check.equal(peek3.note(id: n.id)?.body, "Flushed now", "flush persists immediately")
    try! peek3.close()

    // Pending edit + updateNote (metadata) keeps the latest body.
    store.updateNoteBody(id: n.id, body: "Typed then colored")
    var colored = store.note(id: n.id)!; colored.color = .pink
    store.updateNote(colored)
    // Pending edit, then close (must flush) and reopen.
    store.updateNoteBody(id: n.id, body: "Saved by close")
    try! store.close()
    try! store.reopen()
    Check.equal(store.note(id: n.id)?.body, "Saved by close", "close flushes pending edits")
    Check.equal(store.note(id: n.id)?.color, .pink, "metadata kept")

    // Deleting a note with a pending edit must not resurrect it.
    let doomed = store.createNote(in: fid, body: "doomed")
    store.updateNoteBody(id: doomed.id, body: "doomed edit")
    store.deleteNote(id: doomed.id)
    store.flush()
    try! store.reopen()
    Check.expect(store.note(id: doomed.id) == nil, "deleted note with pending edit stays deleted")
    try! store.close()
}

// MARK: - Search
do {
    let store = try! GRDBNoteStore(directory: freshDir("search"))
    let a = store.folders()[0]
    let b = store.createFolder(name: "B")
    let n1 = store.createNote(in: a.id, body: "Café crème\nwith sugar")
    let n2 = store.createNote(in: b.id, body: "CAFE in B")
    _ = store.createNote(in: b.id, body: "tea")
    Check.equal(Set(store.search("cafe", in: nil).map(\.id)), [n1.id, n2.id], "diacritic + case insensitive")
    Check.equal(store.search("CRÈME", in: nil).map(\.id), [n1.id], "uppercase accented query")
    Check.equal(store.search("cafe", in: b.id).map(\.id), [n2.id], "scoped search")
    Check.equal(store.search("  sugar ", in: nil).map(\.id), [n1.id], "query trimmed, matches later lines")
    Check.equal(store.search("   ", in: nil).count, 0, "blank query gives nothing")
    Check.equal(store.search("coffee", in: nil).count, 0, "no match")
    try! store.close()
}

// MARK: - Attachments
do {
    let dir = freshDir("attachments")
    let src = freshDir("attachment-sources")
    let store = try! GRDBNoteStore(directory: dir)
    let attDir = dir.appendingPathComponent("attachments")
    let fid = store.folders()[0].id
    let note = store.createNote(in: fid, body: "with files")

    let imgSrc = src.appendingPathComponent("photo.PNG")
    try! pngData.write(to: imgSrc)
    var c: [StoreChange] = []
    var img: Attachment!
    c = changes { img = try! store.addAttachment(to: note.id, fileURL: imgSrc) }
    Check.equal(c, [.attachments(noteId: note.id)], "addAttachment posts .attachments")
    Check.equal(img.kind, .image, "image kind")
    Check.equal(img.displayName, "photo.PNG", "display name")
    Check.expect(img.relativePath?.hasSuffix(".png") == true && img.relativePath?.contains("/") == false,
                 "relativePath is <uuid>.png")
    let imgURL = store.url(for: img)!
    Check.equal(imgURL.deletingLastPathComponent().standardizedFileURL.path, attDir.standardizedFileURL.path,
                "image copied into attachments/")
    Check.equal(try? Data(contentsOf: imgURL), pngData, "image content copied")
    Check.expect(fm.fileExists(atPath: imgSrc.path), "source left in place")

    let pasted = try! store.addImageAttachment(to: note.id, data: pngData, fileExtension: "jpeg", displayName: nil)
    Check.expect(pasted.relativePath?.hasSuffix(".jpg") == true, "jpeg normalized to jpg")
    Check.equal(pasted.displayName, "Image.jpg", "default display name")
    Check.equal(try? Data(contentsOf: store.url(for: pasted)!), pngData, "pasted data written")
    let named = try! store.addImageAttachment(to: note.id, data: pngData, fileExtension: "png", displayName: "Shot")
    Check.equal(named.displayName, "Shot", "given display name")

    let docSrc = src.appendingPathComponent("report.txt")
    try! Data("report".utf8).write(to: docSrc)
    let doc = try! store.addAttachment(to: note.id, fileURL: docSrc)
    Check.equal(doc.kind, .fileBookmark, "file becomes bookmark")
    Check.expect(doc.bookmarkData != nil && doc.relativePath == nil, "bookmark data stored")
    Check.equal(store.url(for: doc)?.standardizedFileURL.resolvingSymlinksInPath().path,
                docSrc.standardizedFileURL.resolvingSymlinksInPath().path, "bookmark resolves")
    let folderSrc = freshDir("attachment-sources/Project")
    let folderAtt = try! store.addAttachment(to: note.id, fileURL: folderSrc)
    Check.equal(folderAtt.kind, .fileBookmark, "folder becomes bookmark")
    Check.equal(fileCount(attDir), 3, "only images are copied")

    // Bookmarks follow a renamed file.
    let movedDoc = src.appendingPathComponent("report-renamed.txt")
    try! fm.moveItem(at: docSrc, to: movedDoc)
    Check.equal(store.url(for: doc)?.lastPathComponent, "report-renamed.txt", "bookmark follows rename")

    // Errors.
    var threw = false
    do { _ = try store.addAttachment(to: note.id, fileURL: src.appendingPathComponent("missing.txt")) } catch { threw = true }
    Check.expect(threw, "missing file throws")
    threw = false
    do { _ = try store.addAttachment(to: 424242, fileURL: imgSrc) } catch { threw = true }
    Check.expect(threw, "unknown note throws")
    threw = false
    do { _ = try store.addImageAttachment(to: note.id, data: Data(), fileExtension: "png", displayName: nil) } catch { threw = true }
    Check.expect(threw, "empty image throws")
    Check.equal(fileCount(attDir), 3, "failed adds leave no files")

    Check.equal(store.attachments(for: note.id).map(\.id), [img.id, pasted.id, named.id, doc.id, folderAtt.id],
                "attachments(for:) in creation order")
    Check.equal(store.attachment(id: doc.id)?.displayName, "report.txt", "attachment(id:)")

    // Persistence.
    try! store.reopen()
    Check.equal(store.attachments(for: note.id).count, 5, "attachments persisted")
    Check.equal(store.attachment(id: img.id), img, "image attachment persisted exactly")

    // Delete one attachment: file removed.
    c = changes { store.deleteAttachment(id: pasted.id) }
    Check.equal(c, [.attachments(noteId: note.id)], "deleteAttachment posts .attachments")
    Check.expect(!fm.fileExists(atPath: attDir.appendingPathComponent(pasted.relativePath!).path), "deleted image file removed")
    Check.equal(fileCount(attDir), 2, "two image files left")

    // Delete note: its image files are removed, rows cascade.
    store.deleteNote(id: note.id)
    Check.equal(fileCount(attDir), 0, "note deletion removes image files")
    Check.expect(store.attachment(id: img.id) == nil && store.attachment(id: doc.id) == nil, "attachment rows gone")
    try! store.reopen()
    Check.expect(store.attachment(id: doc.id) == nil, "attachment rows cascade-deleted in the database")

    // Delete folder: image files of all its notes are removed.
    let f2 = store.createFolder(name: "Pictures")
    let pn = store.createNote(in: f2.id, body: "pic")
    let pa = try! store.addImageAttachment(to: pn.id, data: pngData, fileExtension: "png", displayName: "x")
    Check.equal(fileCount(attDir), 1, "image added")
    store.deleteFolder(id: f2.id)
    Check.equal(fileCount(attDir), 0, "folder deletion removes image files")
    try! store.reopen()
    Check.expect(store.attachment(id: pa.id) == nil, "folder attachments cascade-deleted")

    // Launch cleanup of files no row references.
    let keepNote = store.createNote(in: store.folders()[0].id, body: "keep")
    let keep = try! store.addImageAttachment(to: keepNote.id, data: pngData, fileExtension: "png", displayName: "keep")
    store.updateNoteBody(id: keepNote.id, body: "keep " + AttachmentLink.markdown(for: keep))
    try! Data("junk".utf8).write(to: attDir.appendingPathComponent("orphan.png"))
    try! store.reopen()
    Check.expect(!fm.fileExists(atPath: attDir.appendingPathComponent("orphan.png").path), "orphan file removed at open")
    Check.expect(fm.fileExists(atPath: store.url(for: keep)!.path), "referenced file kept at open")

    // Old attachment rows that no body links to are pruned; linked ones stay.
    let unlinked = try! store.addImageAttachment(to: keepNote.id, data: pngData, fileExtension: "png", displayName: "u")
    Check.equal(store.pruneUnreferencedAttachments(olderThan: 3600), 0, "recent unlinked attachment kept")
    Check.equal(store.pruneUnreferencedAttachments(olderThan: 0), 1, "old unlinked attachment pruned")
    Check.expect(store.attachment(id: unlinked.id) == nil && store.attachment(id: keep.id) != nil, "only the unlinked one")
    Check.equal(fileCount(attDir), 1, "pruned image file removed")
    try! store.close()
}

// MARK: - Themes
do {
    let dir = freshDir("themes")
    let store = try! GRDBNoteStore(directory: dir)
    Check.equal(store.customThemes().count, 0, "no custom themes")
    var t = Theme.defaultTheme
    t.id = "custom-1"; t.name = "Zebra"; t.cornerRadius = 8
    var t2 = Theme.defaultTheme
    t2.id = "custom-2"; t2.name = "Apple"; t2.fontSize = 15
    store.saveTheme(t); store.saveTheme(t2)
    Check.equal(store.customThemes().map(\.id), ["custom-2", "custom-1"], "sorted by name")
    t.name = "Zebra 2"; t.light.accent = "#FF0000"
    store.saveTheme(t)
    Check.equal(store.customThemes().count, 2, "save updates in place")
    try! store.reopen()
    Check.equal(store.customThemes(), [t2, t], "themes persisted exactly")
    store.deleteTheme(id: "custom-2")
    try! store.reopen()
    Check.equal(store.customThemes().map(\.id), ["custom-1"], "theme deleted")
    try! store.close()
}

// MARK: - Backups: backup -> modify -> restore round trip
do {
    let dir = freshDir("backup-data")
    let backupsDir = freshDir("backup-zips")
    let settings = makeSettings()
    let store = try! GRDBNoteStore(directory: dir)
    let service = FileBackupService(store: store, settings: settings, backupsDirectory: backupsDir)
    let fid = store.folders()[0].id
    let keep = store.createNote(in: fid, body: "Keep me")
    let img = try! store.addImageAttachment(to: keep.id, data: pngData, fileExtension: "png", displayName: "pic")
    store.updateNoteBody(id: keep.id, body: "Keep me " + AttachmentLink.markdown(for: img)) // pending edit
    var theme = Theme.defaultTheme; theme.id = "bk"; theme.name = "Backup theme"
    store.saveTheme(theme)
    let other = store.createFolder(name: "Other")
    let o1 = store.createNote(in: other.id, body: "Other note")

    let info = try! service.backupNow()
    Check.expect(info.url.lastPathComponent.range(of: #"^NoteBar-\d{4}-\d{2}-\d{2}-\d{6}\.zip$"#,
                                                  options: .regularExpression) != nil, "backup file name format")
    Check.expect(info.sizeBytes > 0, "backup has size")
    Check.equal(service.backups().map(\.url), [info.url], "backups() lists it")
    let snapshotBody = store.note(id: keep.id)!.body
    Check.equal(try! service.validate(info).notes, 2, "validate counts notes (pending edit included)")
    let second = try! service.backupNow()
    Check.expect(second.url != info.url, "second backup in the same second gets a unique name")
    Check.equal(service.backups().first?.url, second.url, "newest first")
    try? fm.removeItem(at: second.url)

    // Modify everything.
    store.updateNoteBody(id: keep.id, body: "Changed")
    store.deleteAttachment(id: img.id)
    store.deleteFolder(id: other.id)
    let added = store.createNote(in: fid, body: "Added after backup")
    store.deleteTheme(id: "bk")
    Check.expect(!fm.fileExists(atPath: store.url(for: img)?.path ?? "/nope"), "image gone before restore")

    var sawAll = false
    let o = NotificationCenter.default.addObserver(forName: .noteStoreDidChange, object: nil, queue: nil) { n in
        if n.storeChange == .all { sawAll = true }
    }
    do { try service.restore(info) } catch { Check.expect(false, "restore threw \(error)") }
    NotificationCenter.default.removeObserver(o)
    Check.expect(sawAll, "restore posts .all")
    Check.expect(store.isOpen, "store open after restore")
    Check.equal(store.journalMode(), "wal", "restored database back in WAL mode")
    Check.equal(store.note(id: keep.id)?.body, snapshotBody, "body restored (including the edit pending at backup time)")
    Check.expect(store.note(id: added.id) == nil, "note added after backup is gone")
    Check.equal(store.folder(id: other.id)?.name, "Other", "deleted folder restored")
    Check.equal(store.note(id: o1.id)?.body, "Other note", "deleted folder's note restored")
    Check.expect(store.attachment(id: img.id) != nil, "attachment row restored")
    Check.equal(try? Data(contentsOf: store.url(for: img)!), pngData, "image file restored")
    Check.equal(store.customThemes().map(\.id), ["bk"], "theme restored")
    let afterRestore = service.backups()
    Check.equal(afterRestore.count, 2, "safety backup made before restore")

    // The safety backup holds the pre-restore state: restoring it brings "Changed" back.
    let safety = afterRestore.first { $0.url != info.url }!
    try! service.restore(safety)
    Check.equal(store.note(id: keep.id)?.body, "Changed", "safety backup restores the pre-restore state")
    Check.expect(store.note(id: added.id) != nil, "added note back from safety backup")
    Check.expect(store.folder(id: other.id) == nil, "deleted folder deleted again")

    // A fresh store instance on the same directory sees the restored data.
    let peek = try! GRDBNoteStore(directory: dir)
    Check.equal(peek.note(id: keep.id)?.body, "Changed", "restored data on disk")
    try! peek.close()

    // Invalid backups are rejected without touching data.
    let bogus = backupsDir.appendingPathComponent("NoteBar-2001-01-01-000000.zip")
    try! Data("not a zip".utf8).write(to: bogus)
    let bogusInfo = BackupInfo(url: bogus, date: Date(timeIntervalSince1970: 978_307_200), sizeBytes: 9)
    var threw = false
    do { try service.restore(bogusInfo) } catch { threw = true }
    Check.expect(threw, "invalid zip rejected")
    let emptyZipSrc = freshDir("empty-zip-src")
    try! Data("x".utf8).write(to: emptyZipSrc.appendingPathComponent("readme.txt"))
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
    p.arguments = ["-c", "-k", emptyZipSrc.path, bogus.path]
    try! fm.removeItem(at: bogus)
    try! p.run(); p.waitUntilExit()
    threw = false
    do { try service.restore(bogusInfo) } catch { threw = true }
    Check.expect(threw, "zip without database rejected")
    Check.equal(store.note(id: keep.id)?.body, "Changed", "data untouched after rejected restores")
    Check.expect(store.isOpen, "store still open after rejected restores")
    try? fm.removeItem(at: bogus)
    try! store.close()
}

// MARK: - Daily backups + retention
do {
    let dir = freshDir("daily-data")
    let backupsDir = freshDir("daily-zips")
    let settings = makeSettings()
    settings.backupRetention = 3
    let store = try! GRDBNoteStore(directory: dir)
    _ = store.createNote(in: store.folders()[0].id, body: "daily")
    let service = FileBackupService(store: store, settings: settings, backupsDirectory: backupsDir)
    service.archivesInBackground = false
    let cal = Calendar.current
    let base = cal.date(from: DateComponents(year: 2026, month: 3, day: 1, hour: 10))!

    service.now = { base }
    service.performDailyBackupIfNeeded()
    Check.equal(service.backups().count, 1, "first daily backup")
    service.performDailyBackupIfNeeded()
    Check.equal(service.backups().count, 1, "no second backup on the same day")
    service.now = { base.addingTimeInterval(5 * 3600) }
    service.performDailyBackupIfNeeded()
    Check.equal(service.backups().count, 1, "still the same day later on")

    for day in 1...4 {
        service.now = { cal.date(byAdding: .day, value: day, to: base)! }
        service.performDailyBackupIfNeeded()
    }
    let list = service.backups()
    Check.equal(list.count, 3, "pruned to retention")
    Check.equal(list.map { cal.component(.day, from: $0.date) }, [5, 4, 3], "newest kept, newest first")
    Check.equal(service.lastBackupDate.map { cal.component(.day, from: $0) }, 5, "lastBackupDate")

    settings.backupsEnabled = false
    service.now = { cal.date(byAdding: .day, value: 10, to: base)! }
    service.performDailyBackupIfNeeded()
    Check.equal(service.backups().count, 3, "disabled: no backup")

    // Non-backup files in the folder are ignored and never pruned.
    try! Data("x".utf8).write(to: backupsDir.appendingPathComponent("notes.txt"))
    settings.backupsEnabled = true
    settings.backupRetention = 1
    service.performDailyBackupIfNeeded()
    Check.equal(service.backups().count, 1, "retention 1")
    Check.expect(fm.fileExists(atPath: backupsDir.appendingPathComponent("notes.txt").path), "foreign files untouched")

    // The schedule runs once immediately.
    service.now = { cal.date(byAdding: .day, value: 11, to: base)! }
    service.startDailySchedule()
    Check.equal(service.backups().first.map { cal.component(.day, from: $0.date) }, 12, "schedule backs up at start")
    service.stopDailySchedule()

    // Background archiving (the default): completes asynchronously, no duplicate while running.
    service.archivesInBackground = true
    settings.backupRetention = 5
    service.now = { cal.date(byAdding: .day, value: 12, to: base)! }
    var done = false
    var notified = false
    let bo = NotificationCenter.default.addObserver(forName: FileBackupService.backupsDidChangeNotification,
                                                    object: service, queue: nil) { _ in notified = true }
    service.performDailyBackupIfNeeded { done = true }
    Check.expect(service.isBackingUp, "background backup running")
    service.performDailyBackupIfNeeded() // ignored while running
    let deadline = Date().addingTimeInterval(20)
    while !done && Date() < deadline { spin(0.05) }
    NotificationCenter.default.removeObserver(bo)
    Check.expect(done && !service.isBackingUp, "background backup finished")
    Check.expect(notified, "backupsDidChange posted")
    Check.equal(service.backups().count, 2, "exactly one background backup added")
    Check.equal(service.backups().first.map { cal.component(.day, from: $0.date) }, 13, "background backup is newest")
    Check.equal(fileCount(backupsDir), 3, "two zips + notes.txt, nothing else")
    let hidden = ((try? fm.contentsOfDirectory(atPath: backupsDir.path)) ?? []).filter { $0.hasPrefix(".") }
    Check.equal(hidden, [], "no hidden partial archives")

    // Default directory parameter keeps the init(store:settings:) call shape.
    let defaultService = FileBackupService(store: store, settings: settings)
    Check.equal(defaultService.backupsDirectory.standardizedFileURL.path,
                AppPaths.backupsDirectory.standardizedFileURL.path, "default backups directory")
    try! store.close()
}

// MARK: - Markdown export
do {
    let dir = freshDir("export-data")
    let out = freshDir("export-out")
    let src = freshDir("export-src")
    let store = try! GRDBNoteStore(directory: dir)
    let inbox = store.folders()[0]
    let slash = store.createFolder(name: "Work/Projects: 2026")
    let n1 = store.createNote(in: inbox.id, body: "# Shopping list\n- milk", mode: .standard, position: .bottom)
    _ = store.createNote(in: inbox.id, body: "Shopping list\nsecond one", mode: .standard, position: .bottom)
    _ = store.createNote(in: inbox.id, body: "", mode: .standard, position: .bottom)
    let img = try! store.addImageAttachment(to: n1.id, data: pngData, fileExtension: "png", displayName: "My Photo.png")
    let docSrc = src.appendingPathComponent("spec sheet.pdf")
    try! Data("%PDF-1.4".utf8).write(to: docSrc)
    let doc = try! store.addAttachment(to: n1.id, fileURL: docSrc)
    store.updateNoteBody(id: n1.id, body: "# Shopping list\n- milk\n\(AttachmentLink.markdown(for: img))\n"
                         + AttachmentLink.markdown(for: doc) + "\n[gone](attachment:987654)") // pending edit
    _ = store.createNote(in: slash.id, body: "Plan\n**bold**")

    let service = FileBackupService(store: store, settings: makeSettings(), backupsDirectory: freshDir("export-zips"))
    do { try service.exportAllAsMarkdown(to: out) } catch { Check.expect(false, "export threw \(error)") }

    let folders = Set((try? fm.contentsOfDirectory(atPath: out.path)) ?? [])
    Check.equal(folders, ["Notes", "Work-Projects- 2026"], "one sanitized folder per Folder")
    let inboxDir = out.appendingPathComponent("Notes")
    let files = Set((try? fm.contentsOfDirectory(atPath: inboxDir.path)) ?? [])
    Check.equal(files, ["Shopping list.md", "Shopping list 2.md", "Untitled.md", "attachments"], "deduplicated note files")
    let md = (try? String(contentsOf: inboxDir.appendingPathComponent("Shopping list.md"), encoding: .utf8)) ?? ""
    Check.expect(md.contains("![My Photo.png](attachments/My%20Photo.png)"), "image link rewritten: \(md)")
    Check.expect(md.contains("[spec sheet.pdf](attachments/spec%20sheet.pdf)"), "file link rewritten")
    Check.expect(md.contains("gone (missing attachment)"), "missing attachment marked")
    Check.expect(md.hasPrefix("# Shopping list\n- milk"), "body exported (pending edit included)")
    Check.equal(try? Data(contentsOf: inboxDir.appendingPathComponent("attachments/My Photo.png")), pngData, "image copied")
    Check.expect(fm.fileExists(atPath: inboxDir.appendingPathComponent("attachments/spec sheet.pdf").path), "file copied")
    let plan = try? String(contentsOf: out.appendingPathComponent("Work-Projects- 2026/Plan.md"), encoding: .utf8)
    Check.equal(plan, "Plan\n**bold**", "second folder note")

    // Exporting again into the same directory never overwrites.
    try! service.exportAllAsMarkdown(to: out)
    let again = Set((try? fm.contentsOfDirectory(atPath: out.path)) ?? [])
    Check.equal(again.count, 4, "second export goes into new folder names")
    try! store.close()
}


// MARK: - Linked attachments survive the deletion of their owner note / folder
do {
    let dir = freshDir("linked-attachments")
    let store = try! GRDBNoteStore(directory: dir)
    let fid = store.folders()[0].id
    let a = store.createNote(in: fid, body: "A")
    let b = store.createNote(in: fid, body: "B")
    let shared = try! store.addImageAttachment(to: a.id, data: pngData, fileExtension: "png", displayName: "s.png")
    let own = try! store.addImageAttachment(to: a.id, data: pngData, fileExtension: "png", displayName: "o.png")
    store.updateNoteBody(id: a.id, body: "A " + AttachmentLink.markdown(for: shared) + AttachmentLink.markdown(for: own))
    // The link was copied/dragged into B (same attachment id).
    store.updateNoteBody(id: b.id, body: "B " + AttachmentLink.markdown(for: shared))
    let sharedFile = store.url(for: shared)!, ownFile = store.url(for: own)!
    let c = changes { store.deleteNote(id: a.id) }
    Check.expect(c.contains(.attachments(noteId: b.id)), "new owner gets .attachments")
    Check.equal(store.attachment(id: shared.id)?.noteId, b.id, "linked attachment moved to B")
    Check.expect(fm.fileExists(atPath: sharedFile.path), "linked image file kept")
    Check.expect(store.attachment(id: own.id) == nil, "unlinked attachment of A removed")
    Check.expect(!fm.fileExists(atPath: ownFile.path), "unlinked image file of A removed")
    try! store.reopen()
    Check.equal(store.attachment(id: shared.id)?.noteId, b.id, "relink persisted")
    Check.equal(store.attachments(for: b.id).map(\.id), [shared.id], "B lists the attachment")
    Check.expect(fm.fileExists(atPath: sharedFile.path), "file survives reopen (orphan cleanup)")

    // Folder delete: the link lives in a note of another folder.
    let other = store.createFolder(name: "Other")
    let x = store.createNote(in: other.id, body: "X")
    let img = try! store.addImageAttachment(to: x.id, data: pngData, fileExtension: "png", displayName: nil)
    store.updateNoteBody(id: x.id, body: AttachmentLink.markdown(for: img))
    let y = store.createNote(in: fid, body: "see " + AttachmentLink.markdown(for: img))
    let imgFile = store.url(for: img)!
    store.deleteFolder(id: other.id)
    Check.equal(store.attachment(id: img.id)?.noteId, y.id, "folder delete relinks to surviving note")
    Check.expect(fm.fileExists(atPath: imgFile.path), "folder delete keeps linked file")
    try! store.reopen()
    Check.equal(store.attachment(id: img.id)?.noteId, y.id, "folder relink persisted")
    // Deleting the last linking note finally removes the image.
    store.deleteNote(id: y.id)
    Check.expect(store.attachment(id: img.id) == nil && !fm.fileExists(atPath: imgFile.path), "last link gone -> image gone")
    try! store.close()
}

// MARK: - Failed writes stay pending, are retried and reported
do {
    let dir = freshDir("write-failures")
    let store = try! GRDBNoteStore(directory: dir)
    let fid = store.folders()[0].id
    let n = store.createNote(in: fid, body: "start")
    store.flush()
    Check.expect(!store.writeFailing && store.lastError == nil, "healthy at start")

    failWrites(dir)
    var failed = 0
    failed += count(.noteStoreWriteFailed) {
        store.updateNoteBody(id: n.id, body: "typed while disk full")
        store.flush()
    }
    Check.equal(failed, 1, "failure posts .noteStoreWriteFailed")
    Check.expect(store.writeFailing && store.lastError != nil, "failure state + lastError")
    Check.expect(store.hasPendingChanges, "body edit still pending after failed flush")

    // updateNote must not drop the pending body when its write fails.
    var colored = store.note(id: n.id)!; colored.color = .blue
    failed += count(.noteStoreWriteFailed) { store.updateNote(colored) }
    Check.equal(failed, 1, "no second notification in the same episode")
    Check.expect(store.hasPendingChanges, "updateNote failure keeps changes pending")

    // Creates during the failure get transient (negative) ids and are inserted later.
    let folder2 = store.createFolder(name: "Made offline")
    Check.expect(folder2.id < 0, "transient folder id")
    let t = store.createNote(in: folder2.id, body: "new while failing")
    Check.expect(t.id < 0, "transient note id")
    store.updateNoteBody(id: t.id, body: "new while failing, edited")
    // Delete during failure is retried too.
    let gone = store.createNote(in: fid, body: "delete me")
    store.deleteNote(id: gone.id)
    var offlineTheme = Theme.defaultTheme
    offlineTheme.id = "offline"; offlineTheme.name = "Offline theme"
    store.saveTheme(offlineTheme)
    store.flush()
    Check.expect(store.hasPendingChanges, "still pending while writes fail")

    // Writes work again: the retry timer saves everything without any user action.
    allowWrites(dir)
    var recovered = 0
    recovered += count(.noteStoreWriteRecovered) { spin(4.5) }
    Check.equal(recovered, 1, "retry timer recovers and posts .noteStoreWriteRecovered")
    Check.expect(!store.hasPendingChanges && !store.writeFailing && store.lastError == nil, "drained")

    let peek = try! GRDBNoteStore(directory: dir)
    Check.equal(peek.note(id: n.id)?.body, "typed while disk full", "failed body edit persisted on retry")
    Check.equal(peek.note(id: n.id)?.color, .blue, "failed updateNote persisted on retry")
    Check.equal(peek.folder(id: folder2.id)?.name, "Made offline", "transient folder persisted")
    Check.equal(peek.note(id: t.id)?.body, "new while failing, edited", "transient note + edits persisted")
    Check.equal(peek.note(id: t.id)?.folderId, folder2.id, "transient note in transient folder")
    Check.expect(peek.note(id: gone.id) == nil, "failed delete retried")
    Check.expect(peek.customThemes().contains { $0.name == "Offline theme" }, "failed theme save retried")
    try! peek.close()

    // New transient ids never collide with persisted negative ids.
    try! store.reopen()
    failWrites(dir)
    let t2 = store.createNote(in: fid, body: "second offline note")
    Check.expect(t2.id < min(t.id, folder2.id), "transient ids continue below persisted ones")
    allowWrites(dir)
    store.flush()
    Check.expect(!store.hasPendingChanges, "second offline note saved")
    try! store.reopen()
    Check.equal(store.note(id: t2.id)?.body, "second offline note", "second offline note persisted")

    // Restore refuses to discard unsaved changes.
    failWrites(dir)
    store.updateNoteBody(id: n.id, body: "unsaved")
    let settings = makeSettings()
    let backups = FileBackupService(store: store, settings: settings,
                                    backupsDirectory: dir.appendingPathComponent("backups", isDirectory: true))
    allowWrites(dir)
    let info = try! backups.backupNow()
    failWrites(dir)
    store.updateNoteBody(id: n.id, body: "unsaved 2")
    var refused = false
    do { try backups.restore(info) } catch { refused = true }
    Check.expect(refused, "restore refuses while changes cannot be saved")
    Check.equal(store.note(id: n.id)?.body, "unsaved 2", "unsaved edit kept in memory")
    allowWrites(dir)
    store.flush()
    try! store.close()
}


// MARK: - Trash (soft delete), both stores

@MainActor func trashChecks(_ store: NoteStore, _ label: String) {
    let home = store.folders()[0]
    let work = store.createFolder(name: "Work")
    let a = store.createNote(in: home.id, body: "alpha note", mode: .standard, position: .bottom)
    let b = store.createNote(in: home.id, body: "beta note", mode: .standard, position: .bottom)
    let w = store.createNote(in: work.id, body: "work note", mode: .standard, position: .bottom)

    // Note: hidden everywhere, restorable.
    let posted = changes { store.trashNote(id: a.id) }
    Check.expect(posted.contains(.notes(folderId: home.id)) && posted.contains(.folders), "\(label): trash posts .notes + .folders")
    Check.equal(store.note(id: a.id), nil, "\(label): trashed note hidden from note(id:)")
    Check.equal(store.notes(in: home.id).map(\.id), [b.id], "\(label): trashed note hidden from notes(in:)")
    Check.equal(store.noteCount(in: home.id), 1, "\(label): trashed note not counted")
    Check.equal(store.search("alpha", in: nil).count, 0, "\(label): trashed note not found by search")
    Check.equal(store.trashedNotes().map(\.id), [a.id], "\(label): trashedNotes lists it")
    Check.expect(store.trashedNotes().first?.deletedAt != nil, "\(label): deletedAt is set")
    var edited = b; edited.body = "changed"
    store.updateNote(edited)
    Check.equal(store.note(id: b.id)?.deletedAt, nil, "\(label): updateNote cannot trash")
    var ghost = store.trashedNotes()[0]; ghost.body = "edited while trashed"
    store.updateNote(ghost)
    store.updateNoteBody(id: a.id, body: "typed while trashed")
    Check.expect(store.restoreNote(id: a.id), "\(label): restoreNote")
    Check.equal(store.note(id: a.id)?.body, "alpha note", "\(label): trashed notes cannot be edited")
    Check.equal(store.notes(in: home.id).map(\.id), [a.id, b.id], "\(label): restored note keeps its place")
    Check.expect(!store.restoreNote(id: a.id), "\(label): restoring a live note does nothing")

    // Folder: hides its notes; restore brings them back; individually trashed notes stay trashed.
    let w2 = store.createNote(in: work.id, body: "second work note", mode: .standard, position: .bottom)
    store.trashNote(id: w2.id)
    store.trashFolder(id: work.id)
    Check.equal(store.folder(id: work.id), nil, "\(label): trashed folder hidden")
    Check.expect(!store.folders().contains { $0.id == work.id }, "\(label): trashed folder not listed")
    Check.equal(store.note(id: w.id), nil, "\(label): notes of a trashed folder hidden")
    Check.equal(store.search("work", in: nil).count, 0, "\(label): notes of a trashed folder not searched")
    Check.equal(store.trashedFolders().map(\.id), [work.id], "\(label): trashedFolders lists it")
    Check.equal(store.noteCount(inTrashedFolder: work.id), 1, "\(label): note count of the trashed folder")
    Check.expect(!store.trashedNotes().contains { $0.id == w2.id }, "\(label): notes inside a trashed folder are listed with it")
    let into = store.createNote(in: work.id, body: "into trashed folder", mode: .standard, position: .top)
    Check.equal(into.folderId, home.id, "\(label): a new note never goes into a trashed folder (first folder instead)")
    let taken = store.createFolder(name: "Work")
    Check.expect(store.restoreFolder(id: work.id), "\(label): restoreFolder")
    Check.equal(store.folder(id: work.id)?.name, "Work 2", "\(label): restored folder gets a free name")
    Check.equal(store.note(id: w.id)?.body, "work note", "\(label): folder notes come back")
    Check.equal(store.note(id: w2.id), nil, "\(label): a note trashed on its own stays trashed")
    store.deleteFolder(id: taken.id)

    // Restoring a note whose folder is trashed restores the folder.
    store.trashFolder(id: work.id)
    store.restoreNote(id: w2.id)
    Check.expect(store.folder(id: work.id) != nil, "\(label): restoreNote brings its folder back")
    Check.equal(store.note(id: w2.id)?.body, "second work note", "\(label): and the note")

    // The last folder is never trashed.
    store.trashFolder(id: work.id)
    store.trashFolder(id: home.id)
    Check.expect(store.folder(id: home.id) != nil, "\(label): the last folder cannot be trashed")
    store.restoreFolder(id: work.id)

    // Purge.
    store.trashNote(id: b.id)
    store.purgeTrash(deletedBefore: Date.distantPast)
    Check.equal(store.trashedNotes().map(\.id), [b.id], "\(label): purge keeps newer items")
    store.trashFolder(id: work.id)
    store.purgeTrash(deletedBefore: Date.distantFuture)
    Check.expect(store.trashedNotes().isEmpty && store.trashedFolders().isEmpty, "\(label): purge empties the trash")
    Check.expect(!store.restoreNote(id: b.id), "\(label): a purged note is gone")
    Check.expect(!store.restoreFolder(id: work.id), "\(label): a purged folder is gone")
    Check.equal(store.notes(in: home.id).map(\.id), [into.id, a.id], "\(label): live notes untouched by purge")
}

trashChecks(InMemoryNoteStore(), "memory")
do {
    let dir = freshDir("trash")
    let store = try! GRDBNoteStore(directory: dir)
    trashChecks(store, "grdb")
    // Persisted: the trash survives a reopen.
    let f = store.createFolder(name: "Gone")
    let n = store.createNote(in: f.id, body: "kept in the trash", mode: .standard, position: .top)
    let solo = store.createNote(in: store.folders()[0].id, body: "solo", mode: .standard, position: .top)
    store.trashNote(id: solo.id)
    store.trashFolder(id: f.id)
    try! store.reopen()
    Check.equal(store.trashedFolders().map(\.id), [f.id], "grdb: trashed folder persisted")
    Check.equal(store.trashedNotes().map(\.id), [solo.id], "grdb: trashed note persisted")
    Check.equal(store.note(id: n.id), nil, "grdb: still hidden after reopen")
    store.restoreFolder(id: f.id)
    try! store.reopen()
    Check.equal(store.note(id: n.id)?.body, "kept in the trash", "grdb: restore persisted")
    try! store.close()
}

// MARK: - Archive, both stores

@MainActor func archiveChecks(_ store: NoteStore, _ label: String) {
    let home = store.folders()[0]
    let other = store.createFolder(name: "Other")
    let a = store.createNote(in: home.id, body: "apple one", mode: .standard, position: .bottom)
    let b = store.createNote(in: home.id, body: "apple two", mode: .standard, position: .bottom)
    let c = store.createNote(in: home.id, body: "cherry", mode: .standard, position: .bottom)
    let o = store.createNote(in: other.id, body: "apple other", mode: .standard, position: .bottom)

    let posted = changes { store.archiveNote(id: b.id) }
    Check.expect(posted.contains(.notes(folderId: home.id)) && posted.contains(.folders), "\(label): archive posts .notes + .folders")
    Check.equal(store.notes(in: home.id).map(\.id), [a.id, c.id], "\(label): archived note hidden from notes(in:)")
    Check.equal(store.noteCount(in: home.id), 2, "\(label): archived note not counted")
    Check.expect(store.note(id: b.id)?.isArchived == true, "\(label): note(id:) still returns an archived note")
    Check.equal(store.search("apple", in: nil).map(\.id), [a.id, o.id], "\(label): search skips archived notes")
    Check.equal(store.search("apple", in: nil, includeArchived: true).map(\.id), [a.id, b.id, o.id],
                "\(label): search with includeArchived finds them (after the folder's other notes)")
    Check.equal(store.search("apple", in: home.id, includeArchived: true).map(\.id), [a.id, b.id], "\(label): folder search with archived")

    store.archiveNote(id: o.id)
    Check.equal(store.archivedNotes().map(\.id), [o.id, b.id], "\(label): archivedNotes, most recent first")
    store.updateNoteBody(id: b.id, body: "apple two edited")
    Check.equal(store.note(id: b.id)?.body, "apple two edited", "\(label): archived notes can be edited")
    var edited = store.note(id: b.id)!; edited.archivedAt = nil; edited.color = .blue
    store.updateNote(edited)
    Check.expect(store.note(id: b.id)?.isArchived == true, "\(label): updateNote cannot unarchive")
    Check.equal(store.note(id: b.id)?.color, .blue, "\(label): updateNote changes an archived note")

    store.unarchiveNote(id: b.id)
    Check.equal(store.notes(in: home.id).map(\.id), [a.id, b.id, c.id], "\(label): unarchive puts it back at its place")
    Check.equal(store.archivedNotes().map(\.id), [o.id], "\(label): unarchived note leaves the archive")

    // Trash: an archived note in the trash is not in the archive; restored, it is archived again.
    store.trashNote(id: o.id)
    Check.equal(store.archivedNotes().map(\.id), [], "\(label): trashed archived note not in the archive")
    store.restoreNote(id: o.id)
    Check.equal(store.archivedNotes().map(\.id), [o.id], "\(label): restored, it is archived again")
    store.trashFolder(id: other.id)
    Check.equal(store.archivedNotes().map(\.id), [], "\(label): notes of a trashed folder leave the archive")
    store.restoreFolder(id: other.id)
    Check.equal(store.archivedNotes().map(\.id), [o.id], "\(label): and come back with it")
    store.deleteFolder(id: other.id)
    Check.equal(store.archivedNotes().map(\.id), [], "\(label): a deleted folder deletes its archived notes")
    for n in [a, b, c] { store.deleteNote(id: n.id) }
}

archiveChecks(InMemoryNoteStore(), "memory")
do {
    let dir = freshDir("archive")
    let store = try! GRDBNoteStore(directory: dir)
    archiveChecks(store, "grdb")
    let n = store.createNote(in: store.folders()[0].id, body: "archived for good", mode: .standard, position: .top)
    store.archiveNote(id: n.id)
    try! store.reopen()
    Check.expect(store.note(id: n.id)?.isArchived == true, "grdb: archive persisted")
    Check.equal(store.notes(in: store.folders()[0].id).count, 0, "grdb: still hidden after reopen")
    store.unarchiveNote(id: n.id)
    try! store.reopen()
    Check.expect(store.note(id: n.id)?.isArchived == false, "grdb: unarchive persisted")
    try! store.close()
}

// v1 database (before the trash): migrates, keeps the data, nothing is trashed.
do {
    let dir = freshDir("migrate-v1")
    rawSQL(dir, """
        CREATE TABLE grdb_migrations (identifier TEXT NOT NULL PRIMARY KEY);
        INSERT INTO grdb_migrations VALUES ('v1-initial');
        CREATE TABLE folder (id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT NOT NULL, sortIndex DOUBLE NOT NULL DEFAULT 0,
            isPinned BOOLEAN NOT NULL DEFAULT 0, color TEXT NOT NULL DEFAULT 'none', createdAt DOUBLE NOT NULL);
        CREATE TABLE note (id INTEGER PRIMARY KEY AUTOINCREMENT, folderId INTEGER NOT NULL REFERENCES folder(id) ON DELETE CASCADE,
            body TEXT NOT NULL DEFAULT '', color TEXT NOT NULL DEFAULT 'none', sortIndex DOUBLE NOT NULL DEFAULT 0,
            isPinned BOOLEAN NOT NULL DEFAULT 0, isFolded BOOLEAN NOT NULL DEFAULT 0, mode TEXT NOT NULL DEFAULT 'standard',
            createdAt DOUBLE NOT NULL, updatedAt DOUBLE NOT NULL);
        CREATE TABLE attachment (id INTEGER PRIMARY KEY AUTOINCREMENT, noteId INTEGER NOT NULL REFERENCES note(id) ON DELETE CASCADE,
            kind TEXT NOT NULL, relativePath TEXT, bookmarkData BLOB, displayName TEXT NOT NULL DEFAULT '', createdAt DOUBLE NOT NULL);
        CREATE TABLE theme (id TEXT PRIMARY KEY, name TEXT NOT NULL, json BLOB NOT NULL, updatedAt DOUBLE NOT NULL);
        INSERT INTO folder (name, createdAt) VALUES ('Old', 1);
        INSERT INTO note (folderId, body, createdAt, updatedAt) VALUES (1, 'old note', 1, 1);
        """)
    let store = try! GRDBNoteStore(directory: dir)
    Check.equal(store.folders().map(\.name), ["Old"], "v1 → v2: folder kept")
    Check.equal(store.notes(in: store.folders()[0].id).map(\.body), ["old note"], "v1 → v2: note kept and not trashed")
    store.trashNote(id: store.notes(in: store.folders()[0].id)[0].id)
    try! store.reopen()
    Check.equal(store.trashedNotes().count, 1, "v1 → v2: trash works after the migration")
    Check.expect(store.archivedNotes().isEmpty, "v1 → v3: nothing is archived after the migration")
    try! store.close()
}
}

try? fm.removeItem(at: root)
Check.finish()
