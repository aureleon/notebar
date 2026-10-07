import AppKit
import NoteBarCore
import NoteBarStore
import NoteBarPanel
import NoteBarEditor
import NoteBarUI
import NoteBarIntegrations
import NoteBarSettings

// SCAFFOLD — finalized by the Integration step. Currently wired to InMemoryNoteStore.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, AppController {
    private var env: AppEnvironment!
    private var panel: PanelController!
    private var root: NotesRootViewController!
    private var hotkeys: HotkeyCenter!
    private var statusItem: StatusItemController!
    private var integrations: IntegrationsController!
    private var settingsWindow: SettingsWindowController!

    func applicationWillFinishLaunching(_ notification: Notification) {
        AppPaths.ensureDirectories()
        let settings = AppSettings.shared
        let store: NoteStore = InMemoryNoteStore(seed: true)
        let themes = ThemeManager(settings: settings, store: store)
        env = AppEnvironment(store: store, backups: nil, settings: settings, themes: themes,
                             editorFactory: MarkdownEditorFactory())
        env.controller = self
        integrations = IntegrationsController(env: env)
        integrations.install()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        root = NotesRootViewController(env: env)
        env.presenter = root
        panel = PanelController(env: env)
        panel.setContent(root)
        hotkeys = HotkeyCenter(settings: env.settings)
        hotkeys.onAction = { [weak self] in self?.handle($0) }
        statusItem = StatusItemController(env: env)
        settingsWindow = SettingsWindowController(env: env)
    }

    func applicationWillTerminate(_ notification: Notification) { env.store.flush() }

    private func handle(_ action: HotkeyAction) {
        switch action {
        case .togglePanel: togglePanel()
        case .newNote: createNote(text: nil, folderName: nil, reveal: true)
        case .newNoteFromClipboard: createNote(text: NSPasteboard.general.string(forType: .string), folderName: nil, reveal: true)
        case .search: showSearch()
        }
    }

    // MARK: AppController
    var isPanelVisible: Bool { panel?.isVisible ?? false }
    func showPanel() { panel.show() }
    func hidePanel() { panel.hide() }
    func togglePanel() { panel.toggle() }

    @discardableResult
    func createNote(text: String?, folderName: String?, reveal: Bool) -> Note? {
        let store = env.store
        let folder: Folder
        if let folderName, !folderName.isEmpty { folder = store.folderNamedOrCreate(folderName) }
        else if let id = root?.currentFolderId ?? env.settings.lastFolderId, let f = store.folder(id: id) { folder = f }
        else { folder = store.folders()[0] }
        let note = store.createNote(in: folder.id, body: text ?? "", mode: env.settings.defaultNoteMode, position: .top)
        if reveal { revealNote(note.id) }
        return note
    }

    func revealNote(_ id: NoteID) { panel.show(); root.reveal(noteId: id, edit: true) }
    func showSearch() { panel.show(); root.beginSearch() }
    func openSettings() { settingsWindow.show() }
}
