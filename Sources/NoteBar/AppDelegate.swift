import AppKit
import NoteBarCore
import NoteBarStore
import NoteBarPanel
import NoteBarEditor
import NoteBarUI
import NoteBarIntegrations
import NoteBarSettings

/// Creates every module, wires them through `AppEnvironment`, and implements `AppController`.
///
/// Order:
/// - `applicationWillFinishLaunching`: data store, backups, themes, environment, integrations
///   (the URL Apple Event handler must be installed before launch finishes).
/// - `applicationDidFinishLaunching`: notes UI, panel, hotkeys, status item, Settings, main menu,
///   daily backups. Requests that arrived early (URL / AppleScript / Services) run right after this.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, AppController {
    private var env: AppEnvironment!
    private var database: GRDBNoteStore!
    private var backupService: FileBackupService?
    private var panel: PanelController!
    private var root: NotesRootViewController!
    private var hotkeys: HotkeyCenter!
    private var statusItem: StatusItemController!
    private var integrations: IntegrationsController!
    private var settingsWindow: SettingsWindowController!
    /// True when the database did not exist before this launch.
    private var isFirstLaunch = false
    private var problemObservers: [NSObjectProtocol] = []
    /// One "can't save" alert per launch; later episodes only set the status-item badge.
    private var didAlertSaveFailure = false

    // MARK: Launch

    func applicationWillFinishLaunching(_ notification: Notification) {
        AppPaths.ensureDirectories()
        // One process per data folder: a second one would overwrite this one's notes.
        switch InstanceLock.acquire() {
        case .acquired: break
        case .heldByOther(let pid): InstanceLock.handOffAndExit(ownerPID: pid) // does not return
        case .failed(let reason): NSLog("NoteBar: could not lock the data folder (%@); continuing", reason)
        }
        InstanceLock.listenForShowRequests { [weak self] in self?.showPanel() }
        let settings = AppSettings.shared
        isFirstLaunch = !FileManager.default.fileExists(atPath: AppPaths.databaseURL.path)

        let db: GRDBNoteStore
        do {
            db = try GRDBNoteStore(directory: AppPaths.supportDirectory)
        } catch {
            Self.failToOpenDatabase(error) // does not return
        }
        database = db
        let backups = FileBackupService(store: db, settings: settings)
        backupService = backups
        if isFirstLaunch { seedWelcomeNote(in: db, settings: settings) }

        let themes = ThemeManager(settings: settings, store: db)
        env = AppEnvironment(store: db, backups: backups, settings: settings, themes: themes,
                             editorFactory: MarkdownEditorFactory())
        env.controller = self // must be set before any integration request runs

        integrations = IntegrationsController(env: env)
        integrations.install()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = MainMenu.make(target: self)

        root = NotesRootViewController(env: env)
        env.presenter = root
        panel = PanelController(env: env)
        panel.setContent(root)

        _ = HotkeyRegistrationStatus.shared // observes before the first registration pass
        hotkeys = HotkeyCenter(settings: env.settings)
        hotkeys.onAction = { [weak self] in self?.handle($0) }
        HotkeyRegistrationStatus.shared.update(failed: hotkeys.failedActions)
        statusItem = StatusItemController(env: env)
        statusItem.hotkeyCenter = hotkeys
        settingsWindow = SettingsWindowController(env: env)
        installProblemObservers()

        backupService?.startDailySchedule()
        LaunchAtLogin.repairLaunchAgentIfNeeded()
        // Promised files of deleted file tiles (Received Files/<uuid>/), after the launch work.
        DispatchQueue.main.async { [weak self] in
            guard let store = self?.env?.store else { return }
            DroppedFileStorage.pruneUnreferenced(store: store)
        }

        if isFirstLaunch {
            // Let the user see where NoteBar lives. Async: the status item and screens are ready then.
            DispatchQueue.main.async { [weak self] in self?.showPanel() }
        }
    }

    /// Last chance to save: if some changes still cannot be written, say so before they are lost.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let database else { return .terminateNow }
        env?.presenter?.panelWillHide() // commits a pending soft delete
        database.flush()
        guard database.hasPendingChanges, database.writeFailing || database.lastError != nil else { return .terminateNow }
        NSApp.activate()
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "Some changes are not saved"
        alert.informativeText = """
            NoteBar can't write to its database\(database.lastError.map { " (\($0.localizedDescription))" } ?? ""). \
            If you quit now, your latest edits are lost.

            Free some disk space or check the data folder, then try again.
            Data folder: \(AppPaths.supportDirectory.path)
            """
        alert.addButton(withTitle: "Don't Quit")
        alert.addButton(withTitle: "Quit Anyway")
        return alert.runModal() == .alertSecondButtonReturn ? .terminateNow : .terminateCancel
    }

    func applicationWillTerminate(_ notification: Notification) {
        env?.presenter?.panelWillHide() // commits a pending soft delete
        env?.store.flush()
        backupService?.stopDailySchedule()
    }

    /// Launching the app again (Finder, Spotlight, `open`) shows the panel.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showPanel()
        return false
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    // MARK: Problems (write failures, backups)

    private func installProblemObservers() {
        let nc = NotificationCenter.default
        problemObservers.append(nc.addObserver(forName: .noteStoreWriteFailed, object: nil, queue: .main) { [weak self] n in
            let err = n.userInfo?[NoteStoreWriteFailureKey.error] as? Error
            MainActor.assumeIsolated { self?.saveFailed(err) }
        })
        problemObservers.append(nc.addObserver(forName: .noteStoreWriteRecovered, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.statusItem?.setWarning(nil, for: "save") }
        })
        problemObservers.append(nc.addObserver(forName: .backupDidFail, object: nil, queue: .main) { [weak self] n in
            let err = n.userInfo?[NoteStoreWriteFailureKey.error] as? Error
            MainActor.assumeIsolated {
                let reason = err.map { " (\($0.localizedDescription))" } ?? ""
                self?.statusItem?.setWarning("The daily backup failed\(reason)", for: "backup")
            }
        })
        // A later good backup clears the backup warning.
        problemObservers.append(nc.addObserver(forName: .backupsDidChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.backupService?.lastError == nil else { return }
                self.statusItem?.setWarning(nil, for: "backup")
            }
        })
        // The store may already be failing (for example a write during launch).
        if database.writeFailing { saveFailed(database.lastError) }
    }

    private func saveFailed(_ error: Error?) {
        let reason = error?.localizedDescription ?? "unknown error"
        statusItem?.setWarning("NoteBar can't save changes (\(reason))", for: "save")
        guard !didAlertSaveFailure else { return }
        didAlertSaveFailure = true
        // Async: never run a modal loop inside the store's write path.
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "NoteBar can't save changes"
            alert.informativeText = """
                \(reason)

                Your edits are kept in memory and NoteBar keeps trying to save them. \
                The menu bar icon shows a dot until saving works again. Do not quit NoteBar until then.
                """
            alert.addButton(withTitle: "OK")
            NSApp.activate()
            alert.runModal()
        }
    }

    // MARK: Startup helpers

    private static func failToOpenDatabase(_ error: Error) -> Never {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "NoteBar could not open its database"
        alert.informativeText = """
            \(error.localizedDescription)

            Database: \(AppPaths.databaseURL.path)

            NoteBar quits now so that no notes are lost. You can restore a backup from \
            \(AppPaths.backupsDirectory.path) (unzip it into the data folder).
            """
        alert.addButton(withTitle: "Quit")
        alert.addButton(withTitle: "Show Data Folder and Quit")
        if alert.runModal() == .alertSecondButtonReturn {
            NSWorkspace.shared.activateFileViewerSelecting([AppPaths.supportDirectory])
        }
        exit(1)
    }

    private func seedWelcomeNote(in store: NoteStore, settings: AppSettings) {
        guard let folder = store.folders().first, store.noteCount(in: folder.id) == 0 else { return }
        let toggle = settings.hotkeys[.togglePanel]?.displayString ?? "the menu bar icon"
        let edgeHint = settings.hotSideEnabled ? ", the menu bar icon or by resting the pointer on the screen edge." : " or the menu bar icon."
        let body = """
            Welcome to NoteBar
            Show or hide this panel with **\(toggle)**\(edgeHint)
            - [ ] Press **+** or ⌘N for a new note
            - [ ] Drop text, images or files on the panel
            - [ ] Use the gear button for colors and *Code* mode
            Settings: ⌘,
            """
        var note = store.createNote(in: folder.id, body: body, mode: .standard, position: .top)
        note.color = .yellow
        store.updateNote(note)
    }

    // MARK: Hotkeys

    private func handle(_ action: HotkeyAction) {
        switch action {
        case .togglePanel: togglePanel()
        case .newNote: createNote(text: nil, folderName: nil, reveal: true)
        case .newNoteFromClipboard:
            // Text, images and files (the UI turns files and image data into attachments).
            panel.show()
            if root.createNote(fromPasteboard: .general) == nil { NSSound.beep() }
        case .search: showSearch()
        case .toggleFloatPanel: toggleFloatPanel()
        }
    }

    // MARK: AppController

    var isPanelVisible: Bool { panel?.isVisible ?? false }
    func showPanel() { panel?.show() }
    func hidePanel() { panel?.hide() }
    func togglePanel() { panel?.toggle() }

    @discardableResult
    func createNote(text: String?, folderName: String?, reveal: Bool) -> Note? {
        let store = env.store
        let folder: Folder
        if let name = folderName?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
            folder = store.folderNamedOrCreate(name)
        } else if let id = root?.currentFolderId ?? env.settings.lastFolderId, let f = store.folder(id: id) {
            folder = f
        } else if let f = store.folders().first {
            folder = f
        } else {
            return nil
        }
        let note = store.createNote(in: folder.id, body: text ?? "", mode: env.settings.defaultNoteMode, position: .top)
        if reveal { revealNote(note.id) }
        return note
    }

    func revealNote(_ id: NoteID) {
        guard let panel, let root else { return }
        panel.show()
        root.reveal(noteId: id, edit: true)
    }

    func showSearch() { showSearch(query: "") }

    func showSearch(query: String) {
        guard let panel, let root else { return }
        panel.show()
        root.beginSearch(query: query)
    }

    func openSettings() { settingsWindow?.show() }

    func toggleFloatPanel() {
        env.settings.pinnedOpen.toggle()
        if env.settings.pinnedOpen && !isPanelVisible {
            panel.show(makeKey: false)
        }
    }

    // MARK: Menu actions

    @objc func showSettingsWindow(_ sender: Any?) { openSettings() }
    @objc func showAbout(_ sender: Any?) { settingsWindow?.show(tab: .about) }
    @objc func togglePanelFromMenu(_ sender: Any?) { togglePanel() }
    @objc func toggleFloatPanelFromMenu(_ sender: Any?) { toggleFloatPanel() }

    /// ⌘W: hides the panel when it is key, otherwise closes the key window (Settings, alerts...).
    @objc func closeKeyWindow(_ sender: Any?) {
        guard let key = NSApp.keyWindow else { return }
        if key === panel?.panelWindow { hidePanel() } else { key.performClose(sender) }
    }
}
