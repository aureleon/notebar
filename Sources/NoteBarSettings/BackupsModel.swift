import AppKit
import SwiftUI
import NoteBarCore

/// Backups list and the actions of the Data pane.
@MainActor
final class BackupsModel: ObservableObject {
    private unowned let models: SettingsModels
    @Published private(set) var backups: [BackupInfo] = []
    @Published private(set) var isWorking = false
    @Published private(set) var statusMessage: String?
    /// "NoteBar can't save changes: …" while the store's writes fail (nil when all is saved).
    @Published private(set) var saveProblem: String?
    /// The error of the last failed backup (nil after a good one).
    @Published private(set) var backupProblem: String?

    private var storeObserver: NSObjectProtocol?
    private var backupsObserver: NSObjectProtocol?
    private var problemObservers: [NSObjectProtocol] = []

    init(models: SettingsModels) {
        self.models = models
        storeObserver = NotificationCenter.default.addObserver(forName: .noteStoreDidChange, object: nil, queue: .main) { [weak self] n in
            guard n.storeChange == .all else { return }
            MainActor.assumeIsolated { self?.refresh() }
        }
        // The daily backup runs in the background; refresh the list when it is done.
        backupsObserver = NotificationCenter.default.addObserver(forName: .backupsDidChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        for name in [Notification.Name.noteStoreWriteFailed, .noteStoreWriteRecovered, .backupDidFail] {
            problemObservers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            })
        }
        refresh()
    }

    deinit {
        if let storeObserver { NotificationCenter.default.removeObserver(storeObserver) }
        if let backupsObserver { NotificationCenter.default.removeObserver(backupsObserver) }
        for o in problemObservers { NotificationCenter.default.removeObserver(o) }
    }

    private var service: BackupService? { models.env.backups }
    var isAvailable: Bool { service != nil }

    func refresh() {
        backups = service?.backups() ?? []
        saveProblem = models.env.store.lastError.map {
            "NoteBar can't save changes (\($0.localizedDescription)). Your edits are kept in memory and saving is retried."
        }
        backupProblem = service?.lastError.map { "The last backup failed (\($0.localizedDescription))." }
    }

    var lastBackupText: String {
        guard let b = backups.first else { return "No backups yet" }
        return "Last backup: \(SettingsFormat.backupDate.string(from: b.date))"
    }

    var totalSizeText: String? {
        guard !backups.isEmpty else { return nil }
        let total = backups.reduce(Int64(0)) { $0 + $1.sizeBytes }
        return "\(backups.count) backup\(backups.count == 1 ? "" : "s"), \(SettingsFormat.bytes(total))"
    }

    // MARK: Actions

    func backUpNow() {
        guard let service, !isWorking else { return }
        isWorking = true
        defer { isWorking = false }
        models.env.store.flush()
        do {
            let info = try service.backupNow()
            statusMessage = "Backed up \(SettingsFormat.bytes(info.sizeBytes)) at \(SettingsFormat.backupDate.string(from: info.date))."
        } catch {
            models.showError(error, title: "Backup failed")
        }
        refresh()
    }

    func confirmRestore(_ backup: BackupInfo) {
        let date = SettingsFormat.backupDate.string(from: backup.date)
        models.confirm(
            "Restore the backup from \(date)?",
            message: "All notes, folders and attachments are replaced by the contents of this backup. "
                + "NoteBar first makes a safety backup of your current notes, so you can restore them again later.",
            confirmTitle: "Restore", destructive: true) { [weak self] in
                self?.restore(backup)
            }
    }

    private func restore(_ backup: BackupInfo) {
        guard let service, !isWorking else { return }
        isWorking = true
        defer { isWorking = false }
        models.env.store.flush()
        do {
            try service.restore(backup)
            // Custom themes live in the database too.
            models.env.themes.reload()
            let date = SettingsFormat.backupDate.string(from: backup.date)
            statusMessage = "Restored the backup from \(date)."
            refresh()
            models.showInfo("Backup restored", "Your notes now match the backup from \(date). "
                            + "The safety backup of the previous state is at the top of the list.")
        } catch {
            refresh()
            models.showError(error, title: "Restore failed")
        }
    }

    func reveal(_ backup: BackupInfo) {
        NSWorkspace.shared.activateFileViewerSelecting([backup.url])
    }

    func openBackupsFolder() {
        AppPaths.ensureDirectories()
        NSWorkspace.shared.open(AppPaths.backupsDirectory)
    }

    func openDataFolder() {
        AppPaths.ensureDirectories()
        NSWorkspace.shared.open(AppPaths.supportDirectory)
    }

    func exportAllAsMarkdown() {
        guard service != nil else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Export"
        panel.message = "Choose a folder. NoteBar puts a new “NoteBar Export” folder inside it."
        panel.directoryURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        let handle: (NSApplication.ModalResponse) -> Void = { [weak self] r in
            guard r == .OK, let url = panel.url else { return }
            MainActor.assumeIsolated { self?.export(into: url) }
        }
        if let w = models.window, w.isVisible { panel.beginSheetModal(for: w, completionHandler: handle) }
        else { handle(ModalSupport.run(panel)) }
    }

    private func export(into parent: URL) {
        guard let service else { return }
        isWorking = true
        defer { isWorking = false }
        models.env.store.flush()
        let fm = FileManager.default
        let base = "NoteBar Export \(SettingsFormat.fileDate.string(from: Date()))"
        var target = parent.appendingPathComponent(base, isDirectory: true)
        var i = 2
        while fm.fileExists(atPath: target.path) {
            target = parent.appendingPathComponent("\(base) \(i)", isDirectory: true); i += 1
        }
        do {
            try fm.createDirectory(at: target, withIntermediateDirectories: true)
            try service.exportAllAsMarkdown(to: target)
            statusMessage = "Exported to \(SettingsFormat.abbreviatedPath(target))."
            NSWorkspace.shared.activateFileViewerSelecting([target])
        } catch {
            // Do not leave an empty folder behind.
            if let items = try? fm.contentsOfDirectory(atPath: target.path), items.isEmpty { try? fm.removeItem(at: target) }
            models.showError(error, title: "Export failed")
        }
    }
}
