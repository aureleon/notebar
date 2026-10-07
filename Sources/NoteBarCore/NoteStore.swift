import Foundation

/// What changed in the store. Posted as `Notification.Name.noteStoreDidChange`
/// with `userInfo[StoreChange.userInfoKey] as? StoreChange`.
public enum StoreChange: Sendable, Hashable {
    /// Folder list changed (create/rename/delete/reorder/pin, or note counts changed).
    case folders
    /// The set or order of notes in a folder changed (create/delete/move/reorder/pin).
    case notes(folderId: FolderID)
    /// Note metadata changed (color, mode, fold, pin...). Body may also have changed.
    case note(id: NoteID)
    /// Only the body text changed via `updateNoteBody`. The editor that is typing should ignore it.
    case noteBody(id: NoteID)
    /// Attachments for a note changed.
    case attachments(noteId: NoteID)
    /// Everything (e.g. after a backup restore). Reload all.
    case all

    public static let userInfoKey = "change"
}

public extension Notification.Name {
    static let noteStoreDidChange = Notification.Name("NoteBar.noteStoreDidChange")
}

public extension Notification {
    var storeChange: StoreChange? { userInfo?[StoreChange.userInfoKey] as? StoreChange }
}

public enum NoteStoreError: Error, LocalizedError {
    case notFound
    case invalidFile(URL)
    case io(String)

    public var errorDescription: String? {
        switch self {
        case .notFound: "Item not found."
        case .invalidFile(let u): "Cannot use file \(u.path)."
        case .io(let s): s
        }
    }
}

/// The single source of truth for folders, notes and attachments.
/// All calls are synchronous and main-actor. Writes post `.noteStoreDidChange` on the main thread.
///
/// Ordering rules:
/// - `folders()`: pinned first, then `sortIndex` ascending.
/// - `notes(in:)`: pinned first, then `sortIndex` ascending ("top" = first).
/// - There is always at least one folder (the store creates "Notes" if empty).
@MainActor
public protocol NoteStore: AnyObject {
    // MARK: Folders
    func folders() -> [Folder]
    func folder(id: FolderID) -> Folder?
    func noteCount(in folderId: FolderID) -> Int
    @discardableResult func createFolder(name: String) -> Folder
    func updateFolder(_ folder: Folder)
    /// Deletes the folder and all its notes + attachments. Never deletes the last folder.
    func deleteFolder(id: FolderID)
    /// Moves the folder to `index` in the `folders()` order.
    func moveFolder(id: FolderID, toIndex index: Int)

    // MARK: Notes
    func notes(in folderId: FolderID) -> [Note]
    func note(id: NoteID) -> Note?
    /// Case-insensitive substring search over bodies. `folderId == nil` searches everything.
    func search(_ query: String, in folderId: FolderID?) -> [Note]
    @discardableResult func createNote(in folderId: FolderID, body: String, mode: NoteMode, position: InsertPosition) -> Note
    /// Called on every keystroke. Implementations debounce persistence and post `.noteBody`.
    func updateNoteBody(id: NoteID, body: String)
    /// Updates metadata (color, mode, isFolded, isPinned, body). Posts `.note` (+ `.notes` if pin changed).
    func updateNote(_ note: Note)
    func deleteNote(id: NoteID)
    /// Moves the note to `index` in the `notes(in:)` order of its folder.
    func moveNote(id: NoteID, toIndex index: Int)
    /// Moves the note to another folder.
    func moveNote(id: NoteID, toFolder folderId: FolderID, position: InsertPosition)

    // MARK: Attachments
    func attachments(for noteId: NoteID) -> [Attachment]
    func attachment(id: AttachmentID) -> Attachment?
    /// Images (UTType .image) are copied into the attachments folder; other files/folders become bookmarks.
    /// Does NOT edit the note body: the caller inserts `AttachmentLink.markdown(for:)`.
    func addAttachment(to noteId: NoteID, fileURL: URL) throws -> Attachment
    /// Pasted / dragged image data (e.g. from a browser). `fileExtension` like "png".
    func addImageAttachment(to noteId: NoteID, data: Data, fileExtension: String, displayName: String?) throws -> Attachment
    /// Resolved file URL (image file inside the attachments folder, or resolved bookmark).
    func url(for attachment: Attachment) -> URL?
    func deleteAttachment(id: AttachmentID)

    // MARK: Custom themes (built-ins live in `Theme.builtIn`)
    func customThemes() -> [Theme]
    func saveTheme(_ theme: Theme)
    func deleteTheme(id: String)

    /// Writes any pending debounced changes now (call on quit / panel hide).
    func flush()
}

public extension NoteStore {
    func folder(named name: String) -> Folder? {
        folders().first { $0.name.compare(name, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame }
    }

    /// Finds the folder by name or creates it.
    func folderNamedOrCreate(_ name: String) -> Folder { folder(named: name) ?? createFolder(name: name) }

    @discardableResult
    func createNote(in folderId: FolderID, body: String = "") -> Note {
        createNote(in: folderId, body: body, mode: .standard, position: .top)
    }
}

/// Helper for implementations: post a change on the main thread.
@MainActor
public func postStoreChange(_ change: StoreChange, sender: AnyObject?) {
    NotificationCenter.default.post(name: .noteStoreDidChange, object: sender,
                                    userInfo: [StoreChange.userInfoKey: change])
}

// MARK: - Backups

public struct BackupInfo: Hashable, Sendable, Identifiable {
    public var id: URL { url }
    public var url: URL
    public var date: Date
    public var sizeBytes: Int64
    public init(url: URL, date: Date, sizeBytes: Int64) { self.url = url; self.date = date; self.sizeBytes = sizeBytes }
}

@MainActor
public protocol BackupService: AnyObject {
    /// Zips database + attachments into `AppPaths.backupsDirectory/NoteBar-YYYY-MM-DD-HHmmss.zip`.
    @discardableResult func backupNow() throws -> BackupInfo
    /// Newest first.
    func backups() -> [BackupInfo]
    /// Makes a safety backup first, replaces the database + attachments, reloads the store, posts `.all`.
    func restore(_ backup: BackupInfo) throws
    /// Creates a backup if none was made today (and `AppSettings.backupsEnabled`). Prunes to `backupRetention`.
    func performDailyBackupIfNeeded()
    /// One `.md` file per note in one subfolder per folder. Images/files are copied next to them.
    func exportAllAsMarkdown(to directory: URL) throws
}
