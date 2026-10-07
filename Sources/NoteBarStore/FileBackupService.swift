import AppKit
import Foundation
import GRDB
import NoteBarCore

/// Zip backups of the database + attachments in `backupsDirectory` (default `AppPaths.backupsDirectory`).
///
/// Archive layout (zip root):
///   notebar.sqlite      consistent snapshot (SQLite online backup API, includes pending edits)
///   attachments/        copy of the attachments folder
///   manifest.json       format version, date, counts
@MainActor
public final class FileBackupService: BackupService {
    public let store: GRDBNoteStore
    public let settings: AppSettings
    public let backupsDirectory: URL
    /// Clock used for backup names and the "already backed up today" check (overridable for checks).
    public var now: () -> Date = { Date() }
    /// How often the daily schedule checks whether a backup is due.
    public var scheduleInterval: TimeInterval = 3600
    /// Last error from an automatic (scheduled) backup. Manual calls throw instead.
    public private(set) var lastError: Error?

    public static let filePrefix = "NoteBar-"
    static let manifestName = "manifest.json"
    static let formatVersion = 1

    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []

    public init(store: GRDBNoteStore, settings: AppSettings, backupsDirectory: URL? = nil) {
        self.store = store
        self.settings = settings
        self.backupsDirectory = (backupsDirectory ?? AppPaths.backupsDirectory).standardizedFileURL
    }

    /// Date of the newest backup, if any.
    public var lastBackupDate: Date? { backups().first?.date }

    // MARK: - Naming

    private static let stampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = Calendar(identifier: .gregorian)
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd-HHmmss"
        return f
    }()

    private static let namePattern = try! NSRegularExpression(
        pattern: #"^NoteBar-(\d{4}-\d{2}-\d{2}-\d{6})(?:-(\d+))?\.zip$"#)

    /// Parses `NoteBar-YYYY-MM-DD-HHmmss[-N].zip` → (date, sequence number).
    static func parse(fileName: String) -> (date: Date, sequence: Int)? {
        let ns = fileName as NSString
        guard let m = namePattern.firstMatch(in: fileName, range: NSRange(location: 0, length: ns.length)),
              let date = stampFormatter.date(from: ns.substring(with: m.range(at: 1))) else { return nil }
        let seq = m.range(at: 2).location == NSNotFound ? 1 : Int(ns.substring(with: m.range(at: 2))) ?? 1
        return (date, seq)
    }

    private func uniqueArchiveURL(for date: Date) -> URL {
        let stamp = Self.stampFormatter.string(from: date)
        var n = 1
        while true {
            let name = Self.filePrefix + stamp + (n == 1 ? "" : "-\(n)") + ".zip"
            let url = backupsDirectory.appendingPathComponent(name)
            if !FileManager.default.fileExists(atPath: url.path) { return url }
            n += 1
        }
    }

    // MARK: - Backup

    @discardableResult
    public func backupNow() throws -> BackupInfo {
        let fm = FileManager.default
        try fm.createDirectory(at: backupsDirectory, withIntermediateDirectories: true)
        let work = try fm.url(for: .itemReplacementDirectory, in: .userDomainMask,
                              appropriateFor: backupsDirectory, create: true)
        defer { try? fm.removeItem(at: work) }

        let content = work.appendingPathComponent("NoteBar", isDirectory: true)
        try fm.createDirectory(at: content, withIntermediateDirectories: true)
        try store.writeSnapshot(to: content.appendingPathComponent(StoreSchema.databaseFileName))

        let attachmentsCopy = content.appendingPathComponent(StoreSchema.attachmentsFolderName, isDirectory: true)
        if fm.fileExists(atPath: store.attachmentsDirectory.path) {
            try fm.copyItem(at: store.attachmentsDirectory, to: attachmentsCopy)
        } else {
            try fm.createDirectory(at: attachmentsCopy, withIntermediateDirectories: true)
        }

        let date = now()
        let manifest: [String: Any] = [
            "app": "NoteBar",
            "format": Self.formatVersion,
            "createdAt": ISO8601DateFormatter().string(from: date),
            "folders": store.folders().count,
            "notes": store.folders().reduce(0) { $0 + store.noteCount(in: $1.id) },
        ]
        let manifestData = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
        try manifestData.write(to: content.appendingPathComponent(Self.manifestName))

        let final = uniqueArchiveURL(for: date)
        // Zip to a hidden temporary name first so a half-written archive never looks like a backup.
        let partial = backupsDirectory.appendingPathComponent("." + final.lastPathComponent + ".partial")
        try? fm.removeItem(at: partial)
        do {
            try Ditto.zip(contentsOf: content, to: partial)
            try fm.moveItem(at: partial, to: final)
        } catch {
            try? fm.removeItem(at: partial)
            throw error
        }
        return info(for: final) ?? BackupInfo(url: final, date: date, sizeBytes: 0)
    }

    private func info(for url: URL) -> BackupInfo? {
        guard let parsed = Self.parse(fileName: url.lastPathComponent) else { return nil }
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
        return BackupInfo(url: url, date: parsed.date, sizeBytes: size)
    }

    /// Newest first.
    public func backups() -> [BackupInfo] {
        let items = (try? FileManager.default.contentsOfDirectory(
            at: backupsDirectory, includingPropertiesForKeys: [.fileSizeKey], options: [.skipsHiddenFiles])) ?? []
        return items.compactMap { url -> (BackupInfo, Int)? in
            guard let p = Self.parse(fileName: url.lastPathComponent), let i = info(for: url) else { return nil }
            return (i, p.sequence)
        }
        .sorted { ($0.0.date, $0.1) > ($1.0.date, $1.1) }
        .map(\.0)
    }

    /// Deletes all but the newest `count` backups (at least one is always kept). Returns the deleted URLs.
    @discardableResult
    public func pruneBackups(keeping count: Int) -> [URL] {
        let doomed = backups().dropFirst(max(1, count)).map(\.url)
        return doomed.filter { (try? FileManager.default.removeItem(at: $0)) != nil }
    }

    public func performDailyBackupIfNeeded() {
        guard settings.backupsEnabled else { return }
        let today = now()
        let calendar = Calendar.current
        if !backups().contains(where: { calendar.isDate($0.date, inSameDayAs: today) }) {
            do {
                try backupNow()
                lastError = nil
            } catch {
                lastError = error
                NSLog("NoteBarStore: daily backup failed: %@", String(describing: error))
            }
        }
        pruneBackups(keeping: settings.backupRetention)
    }

    /// Runs `performDailyBackupIfNeeded` now, then every `scheduleInterval`, after wake from sleep,
    /// and when backups get enabled in Settings.
    public func startDailySchedule() {
        stopDailySchedule()
        performDailyBackupIfNeeded()
        let t = Timer(timeInterval: scheduleInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.performDailyBackupIfNeeded() }
        }
        t.tolerance = 60
        RunLoop.main.add(t, forMode: .common)
        timer = t
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.performDailyBackupIfNeeded() }
        })
        observers.append(NotificationCenter.default.addObserver(
            forName: .appSettingsDidChange, object: settings, queue: .main) { [weak self] n in
            guard n.userInfo?["key"] as? String == "backupsEnabled" else { return }
            MainActor.assumeIsolated { self?.performDailyBackupIfNeeded() }
        })
    }

    public func stopDailySchedule() {
        timer?.invalidate()
        timer = nil
        for o in observers {
            NotificationCenter.default.removeObserver(o)
            NSWorkspace.shared.notificationCenter.removeObserver(o)
        }
        observers.removeAll()
    }

    // MARK: - Restore

    /// Checks that `url` is a NoteBar backup whose database opens. Returns (folders, notes) counts.
    @discardableResult
    public func validate(_ backup: BackupInfo) throws -> (folders: Int, notes: Int) {
        let fm = FileManager.default
        let work = try fm.url(for: .itemReplacementDirectory, in: .userDomainMask,
                              appropriateFor: store.directory, create: true)
        defer { try? fm.removeItem(at: work) }
        let extracted = try extract(backup, into: work)
        return try Self.validateDatabase(at: extracted.appendingPathComponent(StoreSchema.databaseFileName))
    }

    public func restore(_ backup: BackupInfo) throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: backup.url.path) else {
            throw BackupError.invalidBackup("\(backup.url.lastPathComponent) does not exist.")
        }
        let work = try fm.url(for: .itemReplacementDirectory, in: .userDomainMask,
                              appropriateFor: store.directory, create: true)
        defer { try? fm.removeItem(at: work) }

        // 1. Unpack and validate before touching anything.
        let extracted = try extract(backup, into: work)
        let newDB = extracted.appendingPathComponent(StoreSchema.databaseFileName)
        try Self.validateDatabase(at: newDB)

        // 2. Safety backup of the current state.
        if !store.isOpen { try? store.reopen() }
        do { try backupNow() } catch {
            throw BackupError.restoreFailed("Could not make a safety backup first: \(error.localizedDescription)")
        }

        // 3. Swap the files.
        try store.close()
        let previous = work.appendingPathComponent("previous", isDirectory: true)
        try fm.createDirectory(at: previous, withIntermediateDirectories: true)
        let liveFiles = StoreSchema.databaseSidecarSuffixes.map {
            store.directory.appendingPathComponent(StoreSchema.databaseFileName + $0)
        } + [store.attachmentsDirectory]

        func moveLiveFilesAside() throws {
            for f in liveFiles where fm.fileExists(atPath: f.path) {
                try fm.moveItem(at: f, to: previous.appendingPathComponent(f.lastPathComponent))
            }
        }
        func rollBack() {
            for f in liveFiles { try? fm.removeItem(at: f) }
            for f in liveFiles {
                let saved = previous.appendingPathComponent(f.lastPathComponent)
                if fm.fileExists(atPath: saved.path) { try? fm.moveItem(at: saved, to: f) }
            }
            try? store.reopen()
        }

        do {
            try moveLiveFilesAside()
            try fm.moveItem(at: newDB, to: store.databaseURL)
            let newAttachments = extracted.appendingPathComponent(StoreSchema.attachmentsFolderName, isDirectory: true)
            if fm.fileExists(atPath: newAttachments.path) {
                try fm.moveItem(at: newAttachments, to: store.attachmentsDirectory)
            } else {
                try fm.createDirectory(at: store.attachmentsDirectory, withIntermediateDirectories: true)
            }
            // 4. Reopen (runs migrations for older backups, reloads the cache, posts `.all`).
            try store.reopen()
        } catch {
            rollBack()
            throw BackupError.restoreFailed(error.localizedDescription)
        }
    }

    /// Unzips the backup into `work/extracted` and returns the folder that holds `notebar.sqlite`.
    private func extract(_ backup: BackupInfo, into work: URL) throws -> URL {
        let fm = FileManager.default
        let out = work.appendingPathComponent("extracted", isDirectory: true)
        try? fm.removeItem(at: out)
        try fm.createDirectory(at: out, withIntermediateDirectories: true)
        do { try Ditto.unzip(backup.url, to: out) } catch {
            throw BackupError.invalidBackup("Cannot unzip \(backup.url.lastPathComponent).")
        }
        if fm.fileExists(atPath: out.appendingPathComponent(StoreSchema.databaseFileName).path) { return out }
        // Accept archives that wrap everything in one top-level folder.
        let subs = (try? fm.contentsOfDirectory(at: out, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        for sub in subs where fm.fileExists(atPath: sub.appendingPathComponent(StoreSchema.databaseFileName).path) {
            return sub
        }
        throw BackupError.invalidBackup("The archive has no \(StoreSchema.databaseFileName).")
    }

    @discardableResult
    static func validateDatabase(at url: URL) throws -> (folders: Int, notes: Int) {
        let queue: DatabaseQueue
        do {
            queue = try DatabaseQueue(path: url.path, configuration: StoreSchema.configuration(readonly: true))
        } catch {
            throw BackupError.invalidBackup("The database does not open (\(error.localizedDescription)).")
        }
        defer { try? queue.close() }
        do {
            return try queue.read { db in
                let check = try String.fetchOne(db, sql: "PRAGMA quick_check") ?? ""
                guard check == "ok" else { throw BackupError.invalidBackup("The database is damaged (\(check)).") }
                guard try db.tableExists("folder"), try db.tableExists("note") else {
                    throw BackupError.invalidBackup("The database has no NoteBar tables.")
                }
                if try StoreSchema.migrator.hasBeenSuperseded(db) {
                    throw BackupError.invalidBackup("The backup was made by a newer version of NoteBar.")
                }
                let folders = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM folder") ?? 0
                let notes = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM note") ?? 0
                return (folders, notes)
            }
        } catch let e as BackupError {
            throw e
        } catch {
            throw BackupError.invalidBackup(error.localizedDescription)
        }
    }

    // MARK: - Export

    public func exportAllAsMarkdown(to directory: URL) throws {
        try MarkdownExporter(store: store).export(to: directory)
    }
}
