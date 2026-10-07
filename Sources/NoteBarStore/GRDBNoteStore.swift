import Foundation
import GRDB
import NoteBarCore

// STUB — owned by the Store agent. Keep these public entry points:
//   public final class GRDBNoteStore: NoteStore { public init(directory: URL = AppPaths.supportDirectory) throws }
//   public final class FileBackupService: BackupService { public init(store: GRDBNoteStore, settings: AppSettings) }
@MainActor
public final class GRDBNoteStore {
    public init(directory: URL = AppPaths.supportDirectory) throws {}
}

@MainActor
public final class FileBackupService {
    public init(store: GRDBNoteStore, settings: AppSettings) {}
}
