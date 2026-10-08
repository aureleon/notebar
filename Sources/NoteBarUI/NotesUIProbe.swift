import AppKit
import NoteBarCore

/// Test / snapshot hooks (used by the `UISnapshot` executable; XCTest is unavailable).
/// Not needed by the app.
@MainActor
public final class NotesUIProbe {
    private unowned let root: NotesRootViewController

    init(root: NotesRootViewController) { self.root = root }

    private var list: NotesListView { root.notesList }

    public var displayedNoteIDs: [NoteID] { list.noteIDs }
    public var liveEditorCount: Int { list.cards.filter(\.hasEditor).count }
    public var cardCount: Int { list.cards.count }
    public var folderRowIDs: [FolderID] { root.folderList.folderIDs }
    public var folderRowsVisible: Bool { !root.folderList.isHidden }
    public var notesVisible: Bool { !list.isHidden }
    public var isSearching: Bool { root.search != nil }
    public var isToastVisible: Bool { root.toast.isShowing }
    public var selectedNoteID: NoteID? { list.selectedNoteID }
    public var focusedNoteID: NoteID? { root.focusedNoteID }
    public var pendingDeletion: NoteID? { root.pendingDeletion }
    public var headerTitle: String { root.header.isSearching ? "<search>" : root.currentHeaderTitle }
    public var isSettingsButtonVisible: Bool { !root.header.settingsButton.isHidden }
    public var showsSelection: Bool { list.showsSelection }
    public func panelFocusChanged(_ focused: Bool) { root.panelFocusChanged(focused) }

    public func cardIdentity(of id: NoteID) -> ObjectIdentifier? { list.card(for: id).map { ObjectIdentifier($0) } }
    public func editorIdentity(of id: NoteID) -> ObjectIdentifier? { list.card(for: id)?.editor.map { ObjectIdentifier($0) } }
    public func editor(of id: NoteID) -> (any NoteEditing)? { list.card(for: id)?.editor }
    public func cardFrame(of id: NoteID) -> NSRect? { list.card(for: id).map { $0.convert($0.cardRect, to: root.view) } }
    public func isCardFolded(_ id: NoteID) -> Bool? { list.card(for: id)?.isFolded }
    /// Visible card height (without the shadow pad) and the title's frame / font size (card coordinates).
    public func cardVisibleHeight(_ id: NoteID) -> CGFloat? { list.card(for: id).map { $0.cardRect.height } }
    public func cardTitleOrigin(_ id: NoteID) -> NSPoint? { list.card(for: id)?.titleFrameForChecks.origin }
    /// Query whose marks each card has asked its editor for ("" = none). Every result card should have it.
    public func cardHighlightedQuery(_ id: NoteID) -> String? { list.card(for: id)?.highlightedQuery }
    public func cardTitlePointSize(_ id: NoteID) -> CGFloat? { list.card(for: id)?.titleFont.pointSize }

    /// Height of the note list content (all cards), for sizing snapshots.
    public var contentHeight: CGFloat { list.lastContentHeight }

    public func layoutNow() {
        root.view.layoutSubtreeIfNeeded()
        list.layoutCards(animated: false)
        list.updateLiveEditors()
        root.view.layoutSubtreeIfNeeded()
    }

    public func createAllEditors() { list.createAllEditors() }
    public func setHovered(_ id: NoteID, _ on: Bool) { list.card(for: id)?.setHoveredForSnapshot(on) }
    /// Number of card actions in the "…" menu (nil if the card has no action column yet).
    public func hiddenActionCount(_ id: NoteID) -> Int? {
        guard let card = list.card(for: id), let f = card.footer else { return nil }
        card.layoutSubtreeIfNeeded()
        f.layoutSubtreeIfNeeded()
        return f.hiddenActions.count
    }

    public func select(_ id: NoteID?) { root.select(id) }
    public func focusList() { root.focusRoot() }

    public func createNewNote() { root.createNewNote() }
    public func plus() { root.plusPressed() }
    public func deleteWithUndo(_ id: NoteID) { root.softDelete(id) }
    public func undoDelete() { root.undoDeletion() }
    public func commitDelete() { root.commitPendingDeletion() }

    public func setSearchQuery(_ q: String, allFolders: Bool? = nil) {
        root.beginSearch()
        root.header.searchField.stringValue = q
        root.search?.query = q
        if let allFolders { root.search?.allFolders = allFolders }
        root.runSearch(animated: false)
    }

    public func pressEscape() { root.handleEscape() }
    public func goBack() { root.goBack() }

    /// Synthesizes a key-down and routes it like the panel would (key equivalent first, then keyDown
    /// on the first responder chain's root view).
    @discardableResult
    public func press(keyCode: UInt16, characters: String, modifiers: NSEvent.ModifierFlags = []) -> Bool {
        guard let ev = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
                                        windowNumber: root.view.window?.windowNumber ?? 0, context: nil,
                                        characters: characters, charactersIgnoringModifiers: characters,
                                        isARepeat: false, keyCode: keyCode) else { return false }
        if !modifiers.intersection([.command]).isEmpty { return root.handleKeyEquivalent(ev) }
        return root.handleKeyDown(ev)
    }

    public func dropOnBackground(text: String) { root.createNote(from: .text(text)) }
    public func dropFiles(_ urls: [URL], onCard id: NoteID) -> Bool {
        guard let card = list.card(for: id) else { return false }
        return root.notesList(list, drop: .files(urls), on: card)
    }
    public func dropFiles(_ urls: [URL]) { root.createNote(from: .files(urls)) }
    public func moveNote(_ id: NoteID, toGap gap: Int) { root.notesList(list, moveNote: id, toGap: gap) }
    public func clickCard(_ id: NoteID) {
        guard let card = list.card(for: id),
              let ev = NSEvent.mouseEvent(with: .leftMouseUp, location: .zero, modifierFlags: [], timestamp: 0,
                                          windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 0) else { return }
        root.notesList(list, clicked: card, event: ev)
    }
    public func beginRename(_ folderId: FolderID) { root.beginRenameFolder(folderId) }
    // Vim
    /// Runs a card command as if the card's editor sent it (`EditorEvent.vim`).
    public func vimCommand(_ cmd: VimCardCommand, on id: NoteID) {
        guard let card = list.card(for: id) else { return }
        root.notesList(list, card: card, editorEvent: .vim(cmd))
    }
    public var selectedFolderID: FolderID? { root.folderList.selectedFolderID }
    public var renamingFolderID: FolderID? { root.folderList.renamingFolderID }
    public var searchAllFolders: Bool? { root.search?.allFolders }
    public func isEditorFocused(_ id: NoteID) -> Bool { list.card(for: id)?.isEditorFocused ?? false }
    /// Whether the pointer at `p` (root view coordinates) gets the arrow cursor (else the text I-beam).
    public func wantsArrowCursor(at p: NSPoint) -> Bool? {
        guard let sup = root.view.superview, let hit = root.view.hitTest(root.view.convert(p, to: sup)) else { return nil }
        return NotesRootViewController.wantsArrowCursor(over: hit)
    }
    public func endRename() { root.folderList.endRename() }
    public func showMoveMenuItems(for id: NoteID) -> [String] {
        guard let n = root.store.note(id: id) else { return [] }
        return MenuBuilder.moveMenu(for: n, actions: root.actions).items.map { $0.isSeparatorItem ? "-" : $0.title }
    }
    public func gearMenuItems(for id: NoteID) -> [String] {
        guard let n = root.store.note(id: id) else { return [] }
        return MenuBuilder.gearMenu(for: n, actions: root.actions).items.map { $0.isSeparatorItem ? "-" : ($0.view != nil ? "<colors>" : $0.title + ($0.state == .on ? " ✓" : "")) }
    }
    public func cardMenuItems(for id: NoteID) -> [String] {
        guard let n = root.store.note(id: id) else { return [] }
        return MenuBuilder.cardContextMenu(for: n, actions: root.actions, inSearch: root.search != nil).items
            .map { $0.isSeparatorItem ? "-" : $0.title }
    }
    public func moveByKeyboard(_ id: NoteID, up: Bool) { root.actions.move(id, up ? .up : .down) }
    public func moveToTop(_ id: NoteID) { root.actions.move(id, .top) }
    public func moveToBottom(_ id: NoteID) { root.actions.move(id, .bottom) }
    public func moveFolder(_ id: FolderID, toGap gap: Int) { root.folderList.performFolderMove(id: id, gap: gap) }
    public var searchQuery: String? { root.search?.query }

    /// Pin button frame in the root view (nil if no card).
    public func pinFrame(of id: NoteID) -> NSRect? {
        list.card(for: id).map { $0.convert($0.pinButtonFrame, to: root.view) }
    }

    /// Expand button frame in the root view (nil if no card).
    public func expandButtonFrame(of id: NoteID) -> NSRect? {
        list.card(for: id).map { $0.convert($0.expandButtonFrame, to: root.view) }
    }

    public var expandedNoteID: NoteID? { list.expandedNoteID }
    public func isExpanded(_ id: NoteID) -> Bool { list.card(for: id)?.isExpanded ?? false }
    public func toggleExpand(_ id: NoteID) { root.toggleExpand(id) }
    public var backdropFrame: NSRect { root.backdropFrame }
    public var rootContentHeight: CGFloat { root.contentHeight }

    /// Used rect of the card's first text line in the root view: from the live editor's text view,
    /// else from the preview.
    public func firstLineFrame(of id: NoteID) -> NSRect? {
        guard let card = list.card(for: id) else { return nil }
        if let editor = card.editor {
            guard let tv = editor.firstDescendantTextView(), let lm = tv.layoutManager, let tc = tv.textContainer,
                  lm.numberOfGlyphs > 0 else { return nil }
            lm.ensureLayout(for: tc)
            var r = lm.lineFragmentUsedRect(forGlyphAt: 0, effectiveRange: nil)
            r.origin.x += tv.textContainerOrigin.x
            r.origin.y += tv.textContainerOrigin.y
            return tv.convert(r, to: root.view)
        }
        guard let p = card.previewForChecks, let r = p.firstLineUsedRect else { return nil }
        return p.convert(r, to: root.view)
    }

    public func discardEditor(of id: NoteID) { list.card(for: id)?.discardEditor() }
    public func ensureEditor(of id: NoteID) {
        guard let card = list.card(for: id) else { return }
        card.ensureEditor()
        list.layoutCards(animated: false)
    }

    /// How a pasteboard would be imported by a drop / paste outside the editor:
    /// "files", "image", "text" or "none".
    public static func importKind(of pb: NSPasteboard) -> String {
        switch PasteboardImport.payload(from: pb) {
        case .files?: return "files"
        case .image?: return "image"
        case .text?: return "text"
        case nil: return "none"
        }
    }

    /// True if drops of `type` are accepted on the notes list background.
    public static func acceptsDragType(_ type: NSPasteboard.PasteboardType) -> Bool {
        PasteboardImport.externalTypes.contains(type) && PasteboardImport.attachmentTypes.contains(type)
    }
    public func showToast(_ text: String, action: String?) { root.showToast(text, actionTitle: action, action: action == nil ? nil : {}) }
}

extension NotesRootViewController {
    /// Hooks for snapshots / checks.
    public var probe: NotesUIProbe { NotesUIProbe(root: self) }

    var currentHeaderTitle: String {
        switch screen {
        case .folders: return "NoteBar"
        case .folder(let id): return store.folder(id: id)?.name ?? "Notes"
        }
    }
}
