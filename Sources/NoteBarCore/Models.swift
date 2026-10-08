import Foundation

public typealias FolderID = Int64
public typealias NoteID = Int64
public typealias AttachmentID = Int64

public enum NoteColor: String, CaseIterable, Codable, Sendable {
    case none, purple, yellow, blue, green, pink, cream

    public var displayName: String {
        switch self {
        case .none: "None"
        case .purple: "Purple"
        case .yellow: "Yellow"
        case .blue: "Blue"
        case .green: "Green"
        case .pink: "Pink"
        case .cream: "Cream"
        }
    }
}

public enum NoteMode: String, CaseIterable, Codable, Sendable {
    /// Markdown with live styling.
    case standard
    /// No styling at all.
    case plain
    /// Monospaced, no smart quotes / autocorrect.
    case code

    public var displayName: String {
        switch self {
        case .standard: "Standard (Markdown)"
        case .plain: "Plain Text"
        case .code: "Code"
        }
    }
}

public struct Folder: Identifiable, Hashable, Codable, Sendable {
    public var id: FolderID
    public var name: String
    /// Gap-based / fractional ordering. Smaller = higher in the list.
    public var sortIndex: Double
    public var isPinned: Bool
    public var color: NoteColor
    public var createdAt: Date
    /// Set while the folder is in the trash (soft delete). Store queries hide trashed folders and
    /// their notes. Only `NoteStore.trashFolder` / `restoreFolder` change it.
    public var deletedAt: Date?

    public init(id: FolderID, name: String, sortIndex: Double, isPinned: Bool = false,
                color: NoteColor = .none, createdAt: Date = Date(), deletedAt: Date? = nil) {
        self.id = id; self.name = name; self.sortIndex = sortIndex
        self.isPinned = isPinned; self.color = color; self.createdAt = createdAt; self.deletedAt = deletedAt
    }
}

public struct Note: Identifiable, Hashable, Codable, Sendable {
    public var id: NoteID
    public var folderId: FolderID
    /// Markdown source. Attachments are referenced by `AttachmentLink` tokens.
    public var body: String
    public var color: NoteColor
    /// Smaller = higher in the list. Pinned notes are always listed first.
    public var sortIndex: Double
    public var isPinned: Bool
    public var isFolded: Bool
    public var mode: NoteMode
    public var createdAt: Date
    public var updatedAt: Date
    /// Set while the note is in the trash (soft delete). Only `NoteStore.trashNote` / `restoreNote`
    /// change it.
    public var deletedAt: Date?
    /// Set while the note is in the archive. It keeps its folder and place; `notes(in:)` and search hide
    /// it. Only `NoteStore.archiveNote` / `unarchiveNote` change it.
    public var archivedAt: Date?

    public init(id: NoteID, folderId: FolderID, body: String, color: NoteColor = .none,
                sortIndex: Double, isPinned: Bool = false, isFolded: Bool = false,
                mode: NoteMode = .standard, createdAt: Date = Date(), updatedAt: Date = Date(), deletedAt: Date? = nil,
                archivedAt: Date? = nil) {
        self.id = id; self.folderId = folderId; self.body = body; self.color = color
        self.sortIndex = sortIndex; self.isPinned = isPinned; self.isFolded = isFolded
        self.mode = mode; self.createdAt = createdAt; self.updatedAt = updatedAt; self.deletedAt = deletedAt
        self.archivedAt = archivedAt
    }

    public var isArchived: Bool { archivedAt != nil }

    /// Title = first non-empty line with leading markdown markers removed.
    public var title: String { NoteText.title(of: body) }
    /// Number of lines after the title line (for the folded "+ N lines" badge).
    public var linesAfterTitle: Int { NoteText.linesAfterTitle(in: body) }
}

public enum AttachmentKind: String, Codable, Sendable {
    /// Copied into the attachments folder. `relativePath` is set.
    case image
    /// A shortcut to a file/folder anywhere on disk. `bookmarkData` is set (plain, not security-scoped).
    case fileBookmark
}

public struct Attachment: Identifiable, Hashable, Codable, Sendable {
    public var id: AttachmentID
    public var noteId: NoteID
    public var kind: AttachmentKind
    /// Path relative to `AppPaths.attachmentsDirectory` (images).
    public var relativePath: String?
    /// Bookmark data (file shortcuts).
    public var bookmarkData: Data?
    /// Original file name, used for display.
    public var displayName: String
    public var createdAt: Date

    public init(id: AttachmentID, noteId: NoteID, kind: AttachmentKind, relativePath: String? = nil,
                bookmarkData: Data? = nil, displayName: String, createdAt: Date = Date()) {
        self.id = id; self.noteId = noteId; self.kind = kind; self.relativePath = relativePath
        self.bookmarkData = bookmarkData; self.displayName = displayName; self.createdAt = createdAt
    }
}

/// Where to insert a new note / moved note inside a folder.
public enum InsertPosition: Sendable, Hashable {
    case top
    case bottom
}

public enum NoteText {
    /// First non-empty line, with leading `#`, `>`, `- [ ]`, `- `, `* `, `1. ` and inline `*`, `_`, `~`, `=`, `` ` `` stripped.
    public static func title(of body: String) -> String {
        guard let line = body.split(separator: "\n", omittingEmptySubsequences: false)
            .first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) else { return "" }
        var s = line.trimmingCharacters(in: .whitespaces)
        let prefixes = ["- [ ] ", "- [x] ", "- [X] ", "* [ ] ", "* [x] ", "### ", "## ", "# ", "> ", "- ", "* ", "+ "]
        var changed = true
        while changed {
            changed = false
            for p in prefixes where s.hasPrefix(p) { s.removeFirst(p.count); changed = true }
            while s.hasPrefix("#") { s.removeFirst(); changed = true }
        }
        if let r = s.range(of: #"^\d+\.\s"#, options: .regularExpression) { s.removeSubrange(r) }
        s = s.replacingOccurrences(of: #"!\[[^\]]*\]\([^)]*\)"#, with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: #"\[([^\]]*)\]\([^)]*\)"#, with: "$1", options: .regularExpression)
        for m in ["***", "**", "~~", "==", "`", "*", "_"] { s = s.replacingOccurrences(of: m, with: "") }
        return s.trimmingCharacters(in: .whitespaces)
    }

    public static func linesAfterTitle(in body: String) -> Int {
        let lines = body.split(separator: "\n", omittingEmptySubsequences: false)
        guard let idx = lines.firstIndex(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) else { return 0 }
        let rest = lines[(idx + 1)...]
        // Ignore trailing empty lines.
        var count = rest.count
        for l in rest.reversed() {
            if l.trimmingCharacters(in: .whitespaces).isEmpty { count -= 1 } else { break }
        }
        return max(0, count)
    }
}

/// Markdown tokens that reference attachments inside `Note.body`.
///   image: `![name](attachment:42)`
///   file:  `[name](attachment:42)`
public enum AttachmentLink {
    public static let scheme = "attachment"

    public static func markdown(for attachment: Attachment) -> String {
        let name = attachment.displayName.replacingOccurrences(of: "]", with: ")")
        switch attachment.kind {
        case .image: return "![\(name)](\(scheme):\(attachment.id))"
        case .fileBookmark: return "[\(name)](\(scheme):\(attachment.id))"
        }
    }

    public struct Match: Hashable, Sendable {
        public var range: Range<String.Index>
        public var nsRange: NSRange
        public var isImage: Bool
        public var name: String
        public var attachmentID: AttachmentID
    }

    /// Regex: optional `!`, `[name]`, `(attachment:ID)`.
    public static let pattern = #"(!?)\[([^\]\n]*)\]\(attachment:(\d+)\)"#

    public static func matches(in text: String) -> [Match] {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = text as NSString
        return re.matches(in: text, range: NSRange(location: 0, length: ns.length)).compactMap { m in
            guard let r = Range(m.range, in: text), let id = Int64(ns.substring(with: m.range(at: 3))) else { return nil }
            return Match(range: r, nsRange: m.range, isImage: m.range(at: 1).length > 0,
                         name: ns.substring(with: m.range(at: 2)), attachmentID: id)
        }
    }

    public static func attachmentIDs(in text: String) -> [AttachmentID] { matches(in: text).map(\.attachmentID) }
}

/// Fractional ordering helpers. Smaller sorts first.
public enum SortIndex {
    public static let gap: Double = 1024

    /// A value strictly between `a` and `b`. Either may be nil (list ends).
    public static func between(_ a: Double?, _ b: Double?) -> Double {
        switch (a, b) {
        case (nil, nil): return 0
        case (let a?, nil): return a + gap
        case (nil, let b?): return b - gap
        case (let a?, let b?): return (a + b) / 2
        }
    }

    /// True when neighbors are so close that the list should be renumbered.
    public static func needsRebalance(_ a: Double, _ b: Double) -> Bool { abs(b - a) < 1e-6 }

    /// Evenly spaced values for `count` items.
    public static func rebalanced(count: Int) -> [Double] { (0..<count).map { Double($0) * gap } }
}
