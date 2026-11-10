import AppKit
import NoteBarCore

/// The folder chips in the header (`FolderTabsView`) are the navigation: one click opens a folder
/// or Scratch. What the folder list screen did lives here too: rename (in place on the chip), reorder
/// (drag a chip), drops on a folder, and the "…" menu (New Folder, Archive, Recently Deleted, Settings).
extension NotesRootViewController {
    func wireFolderTabs() {
        let tabs = folderTabs
        tabs.onSelect = { [weak self] kind in self?.folderTabPressed(kind) }
        tabs.onStepDay = { [weak self] delta in self?.stepScratchDay(delta) }
        tabs.onMore = { [weak self] view in self?.showMoreMenu(from: view) }
        tabs.menuForFolder = { [weak self] id in
            guard let self, let folder = self.store.folder(id: id) else { return nil }
            return MenuBuilder.folderContextMenu(for: folder, actions: self.actions)
        }
        tabs.onRename = { [weak self] id, name in self?.actions.renameFolder(id, to: name) }
        tabs.onRenameEnd = { [weak self] hadFocus in if hadFocus { self?.focusRoot() } }
        tabs.onMoveFolder = { [weak self] id, gap in self?.moveFolder(id, toGap: gap) }
        tabs.onDropNote = { [weak self] noteId, folderId in self?.actions.move(noteId, toFolder: folderId) }
        tabs.onDropPayload = { [weak self] payload, folderId in self?.createNote(from: payload, in: folderId) }
    }

    /// The chip that belongs to the screen. Search keeps the chip of the screen it started from.
    var activeFolderTab: FolderTabsView.Kind? {
        switch search?.origin ?? screen {
        case .folder(let id): return .folder(id)
        case .scratch: return .scratch
        case .archive, .archivedFolder: return nil
        }
    }

    /// Rebuilds the chips from the store and marks the one of the current screen.
    func updateFolderTabs() {
        guard header != nil else { return }
        let tabs = folderTabs
        if case .scratch(let day) = screen {
            let s = env.scratch
            tabs.scratchTitle = s.title(for: day)
            tabs.scratchStepper = (s.days().contains { $0 < day }, day < s.todayKey)
        }
        tabs.scratchToolTip = scratchToolTip
        tabs.reload(folders: store.folders(), counts: folderCounts(), showsScratch: env.settings.scratchEnabled,
                    active: activeFolderTab)
    }

    func folderTabPressed(_ kind: FolderTabsView.Kind) {
        switch kind {
        case .scratch: showScratch(edit: false)
        case .folder(let id): showFolder(id)
        case .more: break
        }
    }

    /// The "…" button: what the folder list had besides the folders.
    func moreMenu() -> NSMenu {
        let m = NSMenu()
        m.autoenablesItems = false
        m.addItem(ClosureMenuItem("New Folder", key: "n", modifiers: [.command, .shift], symbol: "folder.badge.plus") { [weak self] in
            self?.actions.newFolder()
        })
        m.addItem(.separator())
        func submenu(_ title: String, symbol: String, count: Int, _ menu: NSMenu) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.image = Symbols.image(symbol, size: 13)
            item.submenu = menu
            if count > 0 { item.badge = NSMenuItemBadge(count: count) }
            return item
        }
        m.addItem(submenu("Archive", symbol: "archivebox", count: store.archivedNotes().count + store.archivedFolders().count,
                          MenuBuilder.archiveMenu(actions: actions)))
        // Listed whatever Keep deleted items says (it only sets how long). Empty: nothing to open.
        let trash = store.trashedNotes().count + store.trashedFolders().count
        let deleted = submenu("Recently Deleted", symbol: "trash", count: trash, MenuBuilder.trashMenu(actions: actions))
        deleted.isEnabled = trash > 0
        m.addItem(deleted)
        m.addItem(.separator())
        m.addItem(ClosureMenuItem("Settings…", key: ",", symbol: "gearshape") { [weak self] in self?.env.controller?.openSettings() })
        return m
    }

    func showMoreMenu(from view: NSView) {
        let m = moreMenu()
        if let hook = menuPopUpHook { hook(m); return }
        m.popUp(positioning: nil, at: NSPoint(x: 0, y: view.bounds.maxY + 6), in: view)
    }

    // MARK: Rename

    /// Rename in place on the folder's chip. While the chips do not show (search, the archive), the
    /// folder opens first.
    func beginRenameFolder(_ id: FolderID) {
        guard store.folder(id: id) != nil else { return }
        if !header.showsTabs { showFolder(id) }
        rootView.layoutSubtreeIfNeeded()
        folderTabs.beginRename(id)
    }

    // MARK: Reorder

    /// A chip was dropped in the gap before chip `gap`. A folder stays inside its pinned or unpinned
    /// group (pinned folders sort first).
    func moveFolder(_ id: FolderID, toGap gap: Int) {
        let folders = store.folders()
        guard let from = folders.firstIndex(where: { $0.id == id }) else { return }
        var dest = gap > from ? gap - 1 : gap
        let pinnedCount = folders.filter(\.isPinned).count
        let zone = folders[from].isPinned ? 0...max(0, pinnedCount - 1) : pinnedCount...max(pinnedCount, folders.count - 1)
        dest = max(zone.lowerBound, min(zone.upperBound, dest))
        if dest != from { actions.reorderFolder(id, toIndex: dest) }
    }

    // MARK: Next / previous

    /// ⌃Tab / ⌃⇧Tab, `gt` / `gT`: the next or previous chip (Scratch, then the folders), around the
    /// ends. Not in search and not on the archive screens (the chips do not show there).
    func stepFolderTab(_ delta: Int) {
        guard header.showsTabs, let current = activeFolderTab else { NSSound.beep(); return }
        var strip: [FolderTabsView.Kind] = env.settings.scratchEnabled ? [.scratch] : []
        strip += store.folders().map { .folder($0.id) }
        guard strip.count > 1, let i = strip.firstIndex(of: current) else { NSSound.beep(); return }
        folderTabPressed(strip[((i + delta) % strip.count + strip.count) % strip.count])
    }
}
