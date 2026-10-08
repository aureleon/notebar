import AppKit
import NoteBarCore

/// The whole content of the floating panel: header pill, folder list, notes list, search, toasts.
///
/// Wiring (app delegate):
/// ```
/// let root = NotesRootViewController(env: env)
/// env.presenter = root
/// panel.setContent(root)
/// ```
@MainActor
public final class NotesRootViewController: NSViewController, NotesPresenting {
    enum Screen: Equatable { case folders, folder(FolderID) }

    struct SearchState {
        var query: String
        var allFolders: Bool
        /// Where search was started; Esc returns there.
        var origin: Screen
    }

    let env: AppEnvironment
    let actions: NoteActions
    var store: NoteStore { env.store }

    private(set) var screen: Screen = .folders
    var search: SearchState?
    /// A deleted note that can still be restored with the toast's Undo.
    private(set) var pendingDeletion: NoteID?
    /// Identifies the toast that belongs to the current pending deletion.
    private var pendingDeletionToken = 0
    /// Note whose editor has keyboard focus.
    var focusedNoteID: NoteID?
    /// Focus requested before the view was in a window.
    var pendingFocus: (id: NoteID, edit: Bool)?
    private var searchWork: DispatchWorkItem?
    /// Folder whose notes the list currently shows (nil: empty, or search results).
    private var displayedFolder: FolderID?
    private var observers: [NSObjectProtocol] = []
    /// Blur behind the whole content stack (header to the last element), so the desktop does not show
    /// sharp between the glass elements. Only in glass mode (`CardGlass`).
    private let backdrop = StackBackdropView()
    private var clickMonitor: Any?

    /// Where the UI keeps its own state (the screen to restore at launch).
    /// `env.settings.lastFolderId` always means "last opened folder"; it stays set while the
    /// folder list shows, so new notes from hotkeys / URLs / scripts go to that folder.
    public var stateDefaults: UserDefaults = .standard
    static let showsFolderListKey = "NoteBarUI.showsFolderList"
    private var showsFolderListAtLaunch: Bool {
        get { stateDefaults.bool(forKey: Self.showsFolderListKey) }
        set { if newValue != showsFolderListAtLaunch { stateDefaults.set(newValue, forKey: Self.showsFolderListKey) } }
    }

    var rootView: NotesRootView!
    var header: HeaderView!
    var folderList: FolderListView!
    var notesList: NotesListView!
    var scopeBar: SearchScopeBar!
    var toast: ToastView!

    public init(env: AppEnvironment) {
        self.env = env
        self.actions = NoteActions(env: env)
        super.init(nibName: nil, bundle: nil)
        actions.root = self
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: View

    public override func loadView() {
        let v = NotesRootView(frame: NSRect(x: 0, y: 0, width: PanelSizing.defaultWidth, height: 700))
        v.controller = self
        rootView = v
        view = v

        notesList = NotesListView(env: env)
        notesList.delegate = self
        folderList = FolderListView(env: env)
        folderList.delegate = self
        folderList.actions = actions
        header = HeaderView(env: env)
        scopeBar = SearchScopeBar(env: env)
        scopeBar.onToggle = { [weak self] all in self?.setSearchAllFolders(all) }
        toast = ToastView(frame: .zero)
        toast.fontSize = env.themes.fontSize
        for sub in [backdrop, notesList!, folderList!, header!, toast!] as [NSView] { v.addSubview(sub) }
        notesList.onContentExtentChange = { [weak self] in self?.updateBackdrop() }
        folderList.onContentExtentChange = { [weak self] in self?.updateBackdrop() }
        installClickMonitor()
        wireHeader()
        observeChanges()
        restoreInitialScreen()
    }

    private func wireHeader() {
        header.onBack = { [weak self] in self?.goBack() }
        header.onSettings = { [weak self] in self?.env.controller?.openSettings() }
        header.onSearch = { [weak self] in self?.beginSearch() }
        header.onPlus = { [weak self] in self?.plusPressed() }
        header.onQueryChange = { [weak self] q in self?.searchQueryChanged(q) }
        header.onSearchEscape = { [weak self] in self?.searchFieldEscape() }
        header.onCloseSearch = { [weak self] in self?.endSearch(restore: true, focusRoot: true) }
        header.onSearchMoveDown = { [weak self] in self?.focusFirstResult(edit: false) }
        header.onSearchSubmit = { [weak self] in self?.focusFirstResult(edit: true) }
        header.onSpringBack = { [weak self] in
            guard let self, self.search == nil, case .folder = self.screen else { return }
            self.showFolderList()
        }
    }

    private func restoreInitialScreen() {
        if !showsFolderListAtLaunch, let id = env.settings.lastFolderId, store.folder(id: id) != nil {
            showFolder(id)
        } else {
            showFolderList()
        }
    }

    func layoutViews() {
        guard let v = rootView else { return }
        let b = v.bounds
        let m = Metrics.outerMargin
        let pad = HeaderView.shadowPad
        let hh = Metrics.headerHeight
        header.frame = NSRect(x: m - pad, y: m - pad, width: max(0, b.width - 2 * m + 2 * pad), height: hh + 2 * pad)
        // The lists start at the bottom of the header pill; cards fade out in the gap below it.
        let listTop = m + hh
        let listFrame = NSRect(x: 0, y: listTop, width: b.width, height: max(0, b.height - listTop))
        let inset = Metrics.gap
        for list in [notesList!, folderList!] as [NSView] { list.frame = listFrame }
        if notesList.topInset != inset { notesList.topInset = inset }
        if folderList.topInset != inset { folderList.topInset = inset }
        updateBackdrop()
        let ts = toast.preferredSize(maxWidth: b.width - 4 * m)
        toast.frame = NSRect(x: (b.width - ts.width) / 2, y: b.height - m - ts.height - 8, width: ts.width, height: ts.height)
    }

    public override func viewDidAppear() {
        super.viewDidAppear()
        applyPendingFocus()
    }

    // MARK: Store / theme observation

    private func observeChanges() {
        let nc = NotificationCenter.default
        observers.append(nc.addObserver(forName: .noteStoreDidChange, object: nil, queue: nil) { [weak self] n in
            guard let change = n.storeChange else { return }
            MainActor.assumeIsolated { self?.handle(change) }
        })
        observers.append(nc.addObserver(forName: .themeDidChange, object: nil, queue: nil) { [weak self] _ in
            MainActor.assumeIsolated { self?.restyleAll() }
        })
        observers.append(nc.addObserver(forName: .appSettingsDidChange, object: nil, queue: nil) { [weak self] n in
            let key = n.userInfo?["key"] as? String
            guard key == "colorStyle" || key == "blurBackdrop" else { return }
            MainActor.assumeIsolated { self?.updateBackdrop() }
            MainActor.assumeIsolated { self?.restyleAll() }
        })
        observers.append(nc.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: nil) { [weak self] _ in
            MainActor.assumeIsolated { self?.commitPendingDeletion() }
        })
    }

    func handle(_ change: StoreChange) {
        switch change {
        case .folders:
            if case .folder(let id) = screen, store.folder(id: id) == nil {
                if search != nil { search?.origin = .folders }
                showFolderList()
                return
            }
            reloadFolderList()
            updateHeader()
            if search?.allFolders == true { runSearch(animated: false) }
        case .notes(let fid):
            if search != nil {
                runSearch(animated: true)
            } else if case .folder(let id) = screen, id == fid {
                reloadNotes(animated: true)
            }
            if screen == .folders { reloadFolderList() }
        case .note(let id):
            if let n = store.note(id: id) { notesList.noteChanged(n) }
        case .noteBody(let id):
            if let n = store.note(id: id) { notesList.noteBodyChanged(n) }
        case .attachments:
            break
        case .all:
            if let p = pendingDeletion, store.note(id: p) == nil { pendingDeletion = nil }
            clearNotesList()
            if case .folder(let id) = screen, store.folder(id: id) == nil {
                search = nil
                header.setSearching(false)
                showFolderList()
                return
            }
            reloadFolderList()
            updateHeader()
            if search != nil { runSearch(animated: false) } else if case .folder = screen { reloadNotes(animated: false) }
        }
    }

    func restyleAll() {
        guard header != nil else { return }
        header.restyle()
        folderList.restyle()
        notesList.restyleAll()
        scopeBar.restyle()
        rootView.needsDisplay = true
    }

    // MARK: Data → views

    func displayedNotes(in folderId: FolderID) -> [Note] {
        store.notes(in: folderId).filter { $0.id != pendingDeletion }
    }

    func folderCounts() -> [FolderID: Int] {
        var counts: [FolderID: Int] = [:]
        let pendingFolder = pendingDeletion.flatMap { store.note(id: $0)?.folderId }
        for f in store.folders() {
            counts[f.id] = store.noteCount(in: f.id) - (pendingFolder == f.id ? 1 : 0)
        }
        return counts
    }

    func reloadFolderList() {
        folderList.reload(folders: store.folders(), counts: folderCounts())
    }

    func clearNotesList() {
        notesList.removeAll()
        displayedFolder = nil
    }

    func reloadNotes(animated: Bool) {
        guard case .folder(let id) = screen, search == nil else { return }
        displayedFolder = id
        let notes = displayedNotes(in: id)
        notesList.setNotes(notes, animated: animated)
        notesList.allowsReorder = true
        if notes.isEmpty {
            notesList.setEmptyState(title: "No notes yet", subtitle: "Press + or drop something here")
        } else {
            notesList.setEmptyState(title: nil, subtitle: nil)
        }
    }

    func updateHeader() {
        switch screen {
        case .folders:
            header.setTitle("NoteBar", accent: false, showsBack: false, showsSettings: true, plusToolTip: "New Folder")
        case .folder(let id):
            header.setTitle(store.folder(id: id)?.name ?? "Notes", accent: true, showsBack: true, showsSettings: false, plusToolTip: "New Note (⌘N)")
        }
    }

    private func setListVisibility() {
        let showNotes = search != nil || screen != .folders
        notesList.isHidden = !showNotes
        folderList.isHidden = showNotes
    }

    // MARK: NotesPresenting

    public var currentFolderId: FolderID? {
        switch search?.origin ?? screen {
        case .folders: return nil
        case .folder(let id): return id
        }
    }

    public func showFolderList() {
        _ = view
        if search != nil { endSearch(restore: false, focusRoot: false) }
        let previous: FolderID? = { if case .folder(let id) = screen { return id }; return nil }()
        let hadEditorFocus = focusedNoteID != nil
        screen = .folders
        showsFolderListAtLaunch = true
        clearNotesList()
        focusedNoteID = nil
        reloadFolderList()
        updateHeader()
        setListVisibility()
        folderList.selectedFolderID = previous ?? folderList.selectedFolderID
        if let previous, let row = folderList.row(for: previous) { folderList.scrollToVisible(row) }
        if hadEditorFocus || isFocusInsideNotes { focusRoot() }
    }

    public func showFolder(_ id: FolderID) {
        _ = view
        guard store.folder(id: id) != nil else { return }
        if search != nil { endSearch(restore: false, focusRoot: false) }
        if screen != .folder(id) || displayedFolder != id {
            let hadFocus = isFocusInsideNotes
            clearNotesList()
            focusedNoteID = nil
            screen = .folder(id)
            reloadNotes(animated: false)
            notesList.scrollToTop()
            if hadFocus { focusRoot() }
        }
        if env.settings.lastFolderId != id { env.settings.lastFolderId = id }
        showsFolderListAtLaunch = false
        folderList.endRename()
        updateHeader()
        setListVisibility()
        rootView.needsLayout = true
    }

    public func reveal(noteId: NoteID, edit: Bool) {
        _ = view
        if pendingDeletion == noteId { undoDeletion() }
        guard var note = store.note(id: noteId) else { return }
        if search != nil { endSearch(restore: false, focusRoot: false) }
        showFolder(note.folderId)
        if edit && note.isFolded {
            actions.setFolded(false, id: noteId)
            note = store.note(id: noteId) ?? note
        }
        guard view.window != nil else { pendingFocus = (noteId, edit); return }
        rootView.layoutSubtreeIfNeeded()
        guard let card = notesList.card(for: noteId) else { return }
        notesList.scrollToCard(card)
        if edit {
            card.focusEditor(atEnd: true)
            notesList.selectedNoteID = noteId
        } else {
            select(noteId)
        }
    }

    func applyPendingFocus() {
        guard let p = pendingFocus, view.window != nil else { return }
        pendingFocus = nil
        reveal(noteId: p.id, edit: p.edit)
    }

    public func beginSearch() {
        _ = view
        if search == nil {
            folderList.endRename()
            search = SearchState(query: "", allFolders: screen == .folders, origin: screen)
            clearNotesList()
            focusedNoteID = nil
            header.setSearching(true)
            notesList.topAccessory = scopeBar
            notesList.allowsReorder = false
            setListVisibility()
            runSearch(animated: false)
        }
        header.focusSearchField()
    }

    /// Starts search with `query` already typed (URL scheme / AppleScript). A non-blank query searches all folders.
    public func beginSearch(query: String) {
        beginSearch()
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, search != nil else { return }
        searchWork?.cancel()
        header.searchField.stringValue = q
        search?.query = q
        search?.allFolders = true
        runSearch(animated: false)
        header.focusSearchField()
        header.searchField.currentEditor()?.selectedRange = NSRange(location: (q as NSString).length, length: 0)
    }

    public func panelDidShow() {
        _ = view
        applyPendingFocus()
        guard let window = view.window else { return }
        let fr = window.firstResponder
        if fr == nil || fr === window || !(fr is NSView) || !(view.containsDescendant(fr as? NSView)) {
            if search != nil && (search?.query.isEmpty ?? true) { header.focusSearchField() } else { focusRoot() }
        }
        // Dates and counts may be stale if the store changed while hidden.
        if screen == .folders && search == nil { reloadFolderList() }
    }

    public func panelWillHide() {
        folderList?.endRename()
        commitPendingDeletion()
        toast?.dismiss(expired: true)
    }

    // MARK: Navigation

    func goBack() {
        if search != nil { endSearch(restore: true, focusRoot: true); return }
        if case .folder = screen { showFolderList() }
    }

    func openFolder(atShortcutIndex i: Int) {
        let folders = store.folders()
        guard i >= 0, i < folders.count else { NSSound.beep(); return }
        showFolder(folders[i].id)
        focusRoot()
    }

    var isFocusInsideNotes: Bool {
        guard let fr = view.window?.firstResponder as? NSView else { return false }
        return notesList.containsDescendant(fr)
    }

    func focusRoot() {
        guard let w = view.window else { return }
        if w.firstResponder !== rootView { w.makeFirstResponder(rootView) }
    }

    func select(_ id: NoteID?) {
        notesList.selectedNoteID = id
        if let id, let card = notesList.card(for: id) { notesList.scrollToCard(card) }
        focusRoot()
    }

    func beginRenameFolder(_ id: FolderID) {
        if screen != .folders || search != nil { showFolderList() }
        reloadFolderList()
        folderList.beginRename(id)
    }

    // MARK: Creating

    /// Folder for new notes: the open folder, else the selected / last / first folder.
    func targetFolderForNewNote() -> FolderID {
        if let id = currentFolderId, store.folder(id: id) != nil { return id }
        if screen == .folders, let sel = folderList.selectedFolderID, store.folder(id: sel) != nil { return sel }
        if let id = env.settings.lastFolderId, store.folder(id: id) != nil { return id }
        return store.folders()[0].id
    }

    func plusPressed() {
        if search == nil, screen == .folders { actions.newFolder() } else { createNewNote() }
    }

    func createNewNote() {
        let fid = targetFolderForNewNote()
        let note = store.createNote(in: fid, body: "", mode: env.settings.defaultNoteMode, position: .top)
        reveal(noteId: note.id, edit: true)
    }

    func createNote(from payload: ImportPayload, in folderId: FolderID? = nil) {
        let fid = folderId ?? targetFolderForNewNote()
        guard let note = PasteboardImport.createNote(from: payload, in: fid, env: env) else {
            showToast("Could not add that item")
            return
        }
        reveal(noteId: note.id, edit: true)
    }

    func pasteAsNewNote() {
        guard createNote(fromPasteboard: .general) != nil else { NSSound.beep(); return }
    }

    /// Creates a note from the pasteboard (text, image data, or files as attachments), puts it at the
    /// top of `folderId` (default: the open / last folder) and focuses it. Returns nil if the pasteboard
    /// holds nothing usable. Use it for the "New Note from Clipboard" hotkey so images work too.
    @discardableResult
    public func createNote(fromPasteboard pasteboard: NSPasteboard, folderId: FolderID? = nil) -> NoteID? {
        _ = view
        guard let payload = PasteboardImport.payload(from: pasteboard) else { return nil }
        let fid = folderId.flatMap { store.folder(id: $0) != nil ? $0 : nil } ?? targetFolderForNewNote()
        guard let note = PasteboardImport.createNote(from: payload, in: fid, env: env) else {
            showToast("Could not add that item")
            return nil
        }
        reveal(noteId: note.id, edit: true)
        return note.id
    }

    // MARK: Search

    func searchQueryChanged(_ q: String) {
        guard search != nil else { return }
        search?.query = q
        searchWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.runSearch(animated: false) }
        }
        searchWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08, execute: work)
    }

    func setSearchAllFolders(_ all: Bool) {
        guard search != nil else { return }
        search?.allFolders = all
        runSearch(animated: false)
    }

    func runSearch(animated: Bool) {
        guard let s = search else { return }
        let q = s.query.trimmingCharacters(in: .whitespacesAndNewlines)
        var originFolder: FolderID?
        if case .folder(let id) = s.origin { originFolder = id }
        let originName = originFolder.flatMap { store.folder(id: $0)?.name }
        let scope: FolderID? = s.allFolders ? nil : originFolder
        guard !q.isEmpty else {
            notesList.setNotes([], animated: false)
            scopeBar.update(resultCount: nil, allFolders: scope == nil, folderName: originName)
            notesList.setEmptyState(title: "Search notes",
                                    subtitle: scope == nil ? "Type to search all folders" : "Type to search in “\(originName ?? "")”")
            notesList.layoutCards(animated: false)
            return
        }
        let results = store.search(q, in: scope).filter { $0.id != pendingDeletion }
        var names: [FolderID: String]?
        if scope == nil {
            names = Dictionary(uniqueKeysWithValues: store.folders().map { ($0.id, $0.name) })
        }
        notesList.setNotes(results, animated: animated, folderNames: names, forceUnfolded: true, query: q)
        scopeBar.update(resultCount: results.count, allFolders: scope == nil, folderName: originName)
        if results.isEmpty {
            notesList.setEmptyState(title: "No results", subtitle: "Nothing matches “\(q)”")
        } else {
            notesList.setEmptyState(title: nil, subtitle: nil)
        }
        notesList.layoutCards(animated: false)
    }

    func endSearch(restore: Bool, focusRoot shouldFocus: Bool) {
        guard let s = search else { return }
        searchWork?.cancel()
        search = nil
        header.setSearching(false)
        notesList.topAccessory = nil
        clearNotesList()
        notesList.setEmptyState(title: nil, subtitle: nil)
        focusedNoteID = nil
        screen = s.origin
        if restore {
            switch s.origin {
            case .folders: reloadFolderList()
            case .folder: reloadNotes(animated: false)
            }
        }
        updateHeader()
        setListVisibility()
        if shouldFocus { focusRoot() }
    }

    func searchFieldEscape() {
        if !header.query.isEmpty {
            header.searchField.stringValue = ""
            searchQueryChanged("")
        } else {
            endSearch(restore: true, focusRoot: true)
        }
    }

    func focusFirstResult(edit: Bool) {
        guard let first = notesList.cards.first else { return }
        if edit {
            notesList.scrollToCard(first)
            first.focusEditor(atEnd: false)
            first.highlightSearchMatch()
            // Only the first result shows the find indicator and scrolls to its first match.
            first.revealFirstSearchMatch()
        } else {
            select(first.note.id)
        }
    }

    func revealFromSearch(_ id: NoteID) {
        endSearch(restore: false, focusRoot: false)
        reveal(noteId: id, edit: false)
    }

    // MARK: Delete with undo

    func softDelete(_ id: NoteID) {
        commitPendingDeletion()
        guard store.note(id: id) != nil else { return }
        let ids = notesList.noteIDs
        var neighbor: NoteID?
        if let i = ids.firstIndex(of: id) {
            neighbor = i + 1 < ids.count ? ids[i + 1] : (i > 0 ? ids[i - 1] : nil)
        }
        let listHadFocus = isFocusInsideNotes || view.window?.firstResponder === rootView
        if let card = notesList.card(for: id), card.isEditorFocused { focusRoot() }
        if focusedNoteID == id { focusedNoteID = nil }
        pendingDeletion = id
        pendingDeletionToken += 1
        let token = pendingDeletionToken
        refreshAfterPendingChange(animated: true)
        if listHadFocus { notesList.selectedNoteID = neighbor; focusRoot() }
        showToast("Note deleted", actionTitle: "Undo",
                  action: { [weak self] in self?.undoDeletion() },
                  onExpire: { [weak self] in self?.commitPendingDeletion(token: token) })
    }

    func undoDeletion() {
        guard let id = pendingDeletion else { return }
        pendingDeletion = nil
        toast.dismiss(expired: false)
        refreshAfterPendingChange(animated: true)
        if store.note(id: id) != nil, search == nil {
            rootView.layoutSubtreeIfNeeded()
            select(id)
        }
    }

    /// Deletes the pending note for real. `token`: set when called by that deletion's toast on expiry.
    func commitPendingDeletion(token: Int? = nil) {
        guard let p = pendingDeletion, token == nil || token == pendingDeletionToken else { return }
        pendingDeletion = nil
        if token == nil { toast?.dismiss(expired: false) }
        store.deleteNote(id: p)
    }

    private func refreshAfterPendingChange(animated: Bool) {
        if search != nil { runSearch(animated: animated) } else if case .folder = screen { reloadNotes(animated: animated) }
        reloadFolderList()
    }

    // MARK: Toast

    func showToast(_ message: String, actionTitle: String? = nil, action: (() -> Void)? = nil, onExpire: (() -> Void)? = nil) {
        _ = view
        toast.show(message, actionTitle: actionTitle, duration: actionTitle == nil ? 2.2 : 5, onAction: action, onExpire: onExpire)
        layoutViews()
    }

    // MARK: Misc used by actions

    func noteDidMoveByKeyboard(_ id: NoteID) {
        guard let card = notesList.card(for: id) else { return }
        rootView.layoutSubtreeIfNeeded()
        notesList.scrollToCard(card, animated: true)
    }

    /// The note the keyboard commands act on: the one being edited, else the selected card.
    var activeNoteID: NoteID? {
        if let f = focusedNoteID, notesList.card(for: f) != nil { return f }
        if let s = notesList.selectedNoteID, notesList.card(for: s) != nil, !notesList.isHidden { return s }
        return nil
    }

    var isEditingText: Bool { view.window?.firstResponder is NSText }

    public var contentHeight: CGFloat {
        guard let v = rootView else { return 0 }
        let m = Metrics.outerMargin
        let bottom: CGFloat
        if notesList != nil, !notesList.isHidden {
            bottom = notesList.frame.minY + notesList.contentBottom
        } else if folderList != nil, !folderList.isHidden {
            bottom = folderList.frame.minY + folderList.contentBottom
        } else {
            bottom = m + Metrics.headerHeight
        }
        return min(v.bounds.height, max(bottom, m + Metrics.headerHeight) + m)
    }

    /// Fits the backdrop to the visible elements: the header down to the bottom of the shown list's
    /// last element, with `outerMargin` around them.
    func updateBackdrop() {
        NotificationCenter.default.post(name: .contentExtentDidChange, object: self)
        guard let v = rootView, header != nil else { return }
        backdrop.isHidden = !CardGlass.isEnabled(env)
        guard !backdrop.isHidden else { return }
        let m = Metrics.outerMargin
        let bottom: CGFloat
        if !notesList.isHidden {
            bottom = notesList.frame.minY + notesList.contentBottom
        } else if !folderList.isHidden {
            bottom = folderList.frame.minY + folderList.contentBottom
        } else {
            bottom = m + Metrics.headerHeight
        }
        let f = NSRect(x: 0, y: 0, width: v.bounds.width, height: min(v.bounds.height, max(bottom, m + Metrics.headerHeight) + m))
        if backdrop.frame != f { backdrop.frame = f }
    }

    /// A click anywhere in the panel outside the card being edited (header, search bar, gaps, another
    /// element) leaves that card: editing ends, the selection clears and the cursor is reset. Clicks
    /// on another card are left to that card (it starts editing itself).
    private func installClickMonitor() {
        clickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .mouseMoved]) { [weak self] event in
            MainActor.assumeIsolated {
                if event.type == .mouseMoved { self?.resetCursorIfNeeded(event) } else { self?.handleClickOff(event) }
            }
            return event
        }
    }

    /// The view under the event in this panel, if it is part of the notes UI.
    private func hitView(_ event: NSEvent) -> NSView? {
        guard let v = rootView, let w = v.window, event.window === w, let content = w.contentView else { return nil }
        let p = content.superview?.convert(event.locationInWindow, from: nil) ?? event.locationInWindow
        guard let hit = content.hitTest(p), v.containsDescendant(hit) else { return nil }
        return hit
    }

    /// The panel is non-activating, so AppKit's cursor rects do not run while another app is active, and
    /// the editor's I-beam stays after the pointer leaves the text. Outside text, set the arrow.
    private func resetCursorIfNeeded(_ event: NSEvent) {
        guard let hit = hitView(event) else { return }
        var v: NSView? = hit
        while let cur = v {
            if cur is NSText || cur is NSTextField { return }
            v = cur.superview
        }
        NSCursor.arrow.set()
    }

    private func handleClickOff(_ event: NSEvent) {
        guard notesVisible, let hit = hitView(event) else { return }
        if notesList.cards.contains(where: { $0.containsDescendant(hit) }) { return }
        guard focusedNoteID != nil || notesList.selectedNoteID != nil else { return }
        notesList.selectedNoteID = nil
        // Leave a text field the user clicked into (search) alone; end note editing otherwise.
        if isEditingText, !(hit is NSTextField || hit.superview is NSTextField) { focusRoot() }
        NSCursor.arrow.set()
    }

    deinit {
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
        for o in observers { NotificationCenter.default.removeObserver(o) }
    }
}

/// Root view of the panel content. Handles keyboard navigation and shortcuts.
@MainActor
final class NotesRootView: FlippedView {
    weak var controller: NotesRootViewController?

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func becomeFirstResponder() -> Bool {
        controller?.rootFocusChanged(true)
        return true
    }

    override func resignFirstResponder() -> Bool {
        controller?.rootFocusChanged(false)
        return true
    }

    override func layout() {
        super.layout()
        controller?.layoutViews()
    }

    override func keyDown(with event: NSEvent) {
        if controller?.handleKeyDown(event) == true { return }
        super.keyDown(with: event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if controller?.handleKeyEquivalent(event) == true { return true }
        return super.performKeyEquivalent(with: event)
    }

    override func cancelOperation(_ sender: Any?) { controller?.handleEscape() }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        controller?.restyleAll()
    }

    /// Transparent gaps between cards pass clicks to the root (ends editing) instead of the desktop.
    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
    }
}

/// Behind-window blur with rounded corners, behind the content stack (see `updateBackdrop`).
final class StackBackdropView: NSVisualEffectView {
    static let cornerRadius: CGFloat = Metrics.headerCornerRadius + Metrics.outerMargin

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        blendingMode = .behindWindow
        material = .underWindowBackground
        state = .active
        maskImage = Self.mask
        isHidden = true
    }

    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// Stretchable rounded-rect mask (corners kept by the cap insets).
    private static let mask: NSImage = {
        let r = cornerRadius
        let size = NSSize(width: 2 * r + 1, height: 2 * r + 1)
        let image = NSImage(size: size, flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: r, yRadius: r).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: r, left: r, bottom: r, right: r)
        image.resizingMode = .stretch
        return image
    }()
}
