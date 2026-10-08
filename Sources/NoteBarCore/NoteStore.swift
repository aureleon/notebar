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
    /// Deletes the folder and all its notes + attachments for good (also a trashed folder). Never
    /// deletes the last folder. The UI uses `trashFolder` (undoable) instead.
    func deleteFolder(id: FolderID)
    /// Moves the folder to `index` in the `folders()` order. The folder stays in its pinned/unpinned
    /// zone: the index is clamped to that zone and only same-zone neighbors define the new sortIndex.
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
    /// Deletes the note and its attachments for good (also a trashed note). The UI uses `trashNote`.
    func deleteNote(id: NoteID)
    /// Moves the note to `index` in the `notes(in:)` order of its folder. Like `moveFolder`, the note
    /// stays in its pinned/unpinned zone (index clamped to the zone, same-zone neighbors only).
    func moveNote(id: NoteID, toIndex index: Int)
    /// Moves the note to another folder.
    func moveNote(id: NoteID, toFolder folderId: FolderID, position: InsertPosition)

    // MARK: Trash (soft delete)
    // A trashed note or folder is hidden from every query above (`folders`, `folder(id:)`, `notes`,
    // `note(id:)`, `noteCount`, `search`) until it is restored or purged. Its attachments stay.
    // Changes post `.folders` and `.notes(folderId:)`.

    /// Moves a note to the trash.
    func trashNote(id: NoteID)
    /// Moves a folder to the trash; its notes are hidden with it. Never trashes the last folder.
    func trashFolder(id: FolderID)
    /// Brings a trashed note back. When its folder is in the trash too, the folder comes back first.
    @discardableResult func restoreNote(id: NoteID) -> Bool
    /// Brings a trashed folder back with its notes (notes trashed on their own stay in the trash).
    /// A name that is taken now gets a number ("Work 2").
    @discardableResult func restoreFolder(id: FolderID) -> Bool
    /// Trashed notes whose folder is not trashed, most recently deleted first.
    func trashedNotes() -> [Note]
    /// Trashed folders, most recently deleted first.
    func trashedFolders() -> [Folder]
    /// Notes that come back with a trashed folder (its notes that were not trashed on their own).
    func noteCount(inTrashedFolder id: FolderID) -> Int
    /// Deletes for good every trashed item deleted before `date` (`.distantFuture` = everything).
    func purgeTrash(deletedBefore date: Date)

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

    /// The error of the current write-failure episode; nil while everything is saved (or can be).
    var lastError: Error? { get }
    /// True when some changes are not in the database yet (debounced edits or failed writes).
    var hasPendingChanges: Bool { get }
}

public extension NoteStore {
    var lastError: Error? { nil }
    var hasPendingChanges: Bool { false }

    func folder(named name: String) -> Folder? {
        folders().first { $0.name.compare(name, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame }
    }

    /// `base`, or `base 2`, `base 3` ... when a (visible) folder already has that name.
    func availableFolderName(_ base: String) -> String {
        let names = Set(folders().map { $0.name.lowercased() })
        if !names.contains(base.lowercased()) { return base }
        var i = 2
        while names.contains("\(base) \(i)".lowercased()) { i += 1 }
        return "\(base) \(i)"
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

public extension Notification.Name {
    /// Posted (main thread) by the backup service after a backup was created or old backups were pruned.
    static let backupsDidChange = Notification.Name("NoteBar.backupsDidChange")
    /// Posted (object: the store) when a database write fails and the store enters the
    /// "unsaved changes" state. Posted once per failure episode, not for every retry.
    /// `userInfo[NoteStoreWriteFailureKey.error]` holds the `Error`, `.operation` a short description.
    static let noteStoreWriteFailed = Notification.Name("NoteBar.noteStoreWriteFailed")
    /// Posted (object: the store) when all changes that failed earlier are saved again.
    static let noteStoreWriteRecovered = Notification.Name("NoteBar.noteStoreWriteRecovered")
    /// Posted (object: the backup service) when an automatic (daily) backup fails.
    /// `userInfo[NoteStoreWriteFailureKey.error]` holds the `Error`.
    static let backupDidFail = Notification.Name("NoteBar.backupDidFail")
}

/// `userInfo` keys of `noteStoreWriteFailed` / `backupDidFail`.
public enum NoteStoreWriteFailureKey {
    public static let error = "error"
    public static let operation = "operation"
}

@MainActor
public protocol BackupService: AnyObject {
    /// Date of the newest backup, if any.
    var lastBackupDate: Date? { get }
    /// True while a (background) backup is running.
    var isBackingUp: Bool { get }
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

public extension BackupService {
    /// The error of the last failed backup; nil after a successful one.
    var lastError: Error? { nil }
    var lastBackupDate: Date? { backups().first?.date }
    var isBackingUp: Bool { false }
}
