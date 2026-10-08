import Foundation
import GRDB
import NoteBarCore

/// Database layout + versioned migrations.
///
/// Dates are stored as REAL seconds since 1970 so that values round-trip exactly
/// (the in-memory cache and the database always agree).
enum StoreSchema {
    static let databaseFileName = "notebar.sqlite"
    static let attachmentsFolderName = "attachments"
    /// Files SQLite may create next to the database in WAL mode.
    static let databaseSidecarSuffixes = ["", "-wal", "-shm"]

    static var migrator: DatabaseMigrator {
        var m = DatabaseMigrator()

        m.registerMigration("v1-initial") { db in
            try db.create(table: "folder") { t in
                // AUTOINCREMENT: ids are never reused (attachment links / settings refer to ids).
                t.autoIncrementedPrimaryKey("id")
                t.column("name", .text).notNull()
                t.column("sortIndex", .double).notNull().defaults(to: 0)
                t.column("isPinned", .boolean).notNull().defaults(to: false)
                t.column("color", .text).notNull().defaults(to: NoteColor.none.rawValue)
                t.column("createdAt", .double).notNull()
            }
            try db.create(table: "note") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("folderId", .integer).notNull().indexed()
                    .references("folder", onDelete: .cascade)
                t.column("body", .text).notNull().defaults(to: "")
                t.column("color", .text).notNull().defaults(to: NoteColor.none.rawValue)
                t.column("sortIndex", .double).notNull().defaults(to: 0)
                t.column("isPinned", .boolean).notNull().defaults(to: false)
                t.column("isFolded", .boolean).notNull().defaults(to: false)
                t.column("mode", .text).notNull().defaults(to: NoteMode.standard.rawValue)
                t.column("createdAt", .double).notNull()
                t.column("updatedAt", .double).notNull()
            }
            try db.create(table: "attachment") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("noteId", .integer).notNull().indexed()
                    .references("note", onDelete: .cascade)
                t.column("kind", .text).notNull()
                t.column("relativePath", .text)
                t.column("bookmarkData", .blob)
                t.column("displayName", .text).notNull().defaults(to: "")
                t.column("createdAt", .double).notNull()
            }
            try db.create(table: "theme") { t in
                t.primaryKey("id", .text)
                t.column("name", .text).notNull()
                t.column("json", .blob).notNull()
                t.column("updatedAt", .double).notNull()
            }
        }

        // Soft delete: a trashed note / folder has `deletedAt` (seconds since 1970) until it is
        // restored or purged.
        m.registerMigration("v2-trash") { db in
            try db.alter(table: "folder") { t in t.add(column: "deletedAt", .double) }
            try db.alter(table: "note") { t in t.add(column: "deletedAt", .double) }
        }

        // Archive: an archived note has `archivedAt` (seconds since 1970) until it is unarchived.
        m.registerMigration("v3-archive") { db in
            try db.alter(table: "note") { t in t.add(column: "archivedAt", .double) }
        }

        // Future migrations go here: m.registerMigration("v4-...") { db in ... }
        return m
    }

    static func configuration(readonly: Bool = false) -> Configuration {
        var c = Configuration()
        c.foreignKeysEnabled = true
        c.readonly = readonly
        c.label = "NoteBar"
        c.busyMode = .timeout(5)
        c.prepareDatabase { db in
            if !db.configuration.readonly {
                // WAL + NORMAL is crash-safe (a crash may lose the last transaction, never corrupts).
                try db.execute(sql: "PRAGMA synchronous = NORMAL")
            }
        }
        return c
    }
}

// MARK: - Row mapping

extension Date {
    /// The value exactly as it reads back from the database (dates are stored as REAL seconds since
    /// 1970, which rounds differently from `Date`'s reference-date storage). Cached dates use this so
    /// that the cache and freshly loaded records compare equal.
    var storeNormalized: Date { Date(timeIntervalSince1970: timeIntervalSince1970) }
    static var storeNow: Date { Date().storeNormalized }
}

extension Folder {
    init(row: Row) {
        let colorRaw: String = row["color"] ?? ""
        self.init(id: row["id"], name: row["name"], sortIndex: row["sortIndex"], isPinned: row["isPinned"],
                  color: NoteColor(rawValue: colorRaw) ?? .none,
                  createdAt: Date(timeIntervalSince1970: row["createdAt"]),
                  deletedAt: (row["deletedAt"] as Double?).map(Date.init(timeIntervalSince1970:)))
    }
}

extension Note {
    init(row: Row) {
        let colorRaw: String = row["color"] ?? ""
        let modeRaw: String = row["mode"] ?? ""
        self.init(id: row["id"], folderId: row["folderId"], body: row["body"],
                  color: NoteColor(rawValue: colorRaw) ?? .none,
                  sortIndex: row["sortIndex"], isPinned: row["isPinned"], isFolded: row["isFolded"],
                  mode: NoteMode(rawValue: modeRaw) ?? .standard,
                  createdAt: Date(timeIntervalSince1970: row["createdAt"]),
                  updatedAt: Date(timeIntervalSince1970: row["updatedAt"]),
                  deletedAt: (row["deletedAt"] as Double?).map(Date.init(timeIntervalSince1970:)),
                  archivedAt: (row["archivedAt"] as Double?).map(Date.init(timeIntervalSince1970:)))
    }
}

extension Attachment {
    init?(row: Row) {
        let kindRaw: String = row["kind"] ?? ""
        guard let kind = AttachmentKind(rawValue: kindRaw) else { return nil }
        self.init(id: row["id"], noteId: row["noteId"], kind: kind, relativePath: row["relativePath"],
                  bookmarkData: row["bookmarkData"], displayName: row["displayName"],
                  createdAt: Date(timeIntervalSince1970: row["createdAt"]))
    }
}

/// SQL used by the store. Kept in one place so column order stays consistent.
enum SQL {
    static let insertFolder = "INSERT INTO folder (name, sortIndex, isPinned, color, createdAt) VALUES (?, ?, ?, ?, ?)"
    static let insertNote = """
        INSERT INTO note (folderId, body, color, sortIndex, isPinned, isFolded, mode, createdAt, updatedAt)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
        """
    static let insertAttachment = """
        INSERT INTO attachment (noteId, kind, relativePath, bookmarkData, displayName, createdAt)
        VALUES (?, ?, ?, ?, ?, ?)
        """

    static func folderInsertArgs(_ f: Folder) -> StatementArguments {
        [f.name, f.sortIndex, f.isPinned, f.color.rawValue, f.createdAt.timeIntervalSince1970]
    }
    static func noteInsertArgs(_ n: Note) -> StatementArguments {
        [n.folderId, n.body, n.color.rawValue, n.sortIndex, n.isPinned, n.isFolded, n.mode.rawValue,
         n.createdAt.timeIntervalSince1970, n.updatedAt.timeIntervalSince1970]
    }
    static func attachmentInsertArgs(_ a: Attachment) -> StatementArguments {
        [a.noteId, a.kind.rawValue, a.relativePath, a.bookmarkData, a.displayName, a.createdAt.timeIntervalSince1970]
    }
}
