import AppKit
import NoteBarCore

/// Folder tabs (`settings.folderTabsEnabled`): the rail takes `FolderTabs.railWidth` on the inner side
/// of the root view. The panel window is wider by the same amount, so the notes column keeps its width.
extension NotesRootViewController {
    /// Width the rail takes from the root view (0 while the tabs are off).
    var railInset: CGFloat { FolderTabs.railWidth(env.settings) }

    /// True if the rail is on the left of the notes column (panel on the right side of the screen).
    var railOnLeft: Bool { env.settings.panelSide == .right }

    /// The notes column: the root view without the rail. Header, lists, backdrop, and toast live in it.
    var columnFrame: NSRect {
        guard let v = rootView else { return .zero }
        let b = v.bounds
        let r = min(railInset, b.width)
        return NSRect(x: railOnLeft ? r : 0, y: 0, width: b.width - r, height: b.height)
    }

    /// The tab that belongs to the screen. Search keeps the tab of the screen it started from.
    var activeFolderTab: FolderTabRailView.Kind {
        switch search?.origin ?? screen {
        case .folder(let id): return .folder(id)
        case .scratch: return .scratch
        case .folders, .archive, .archivedFolder: return .allFolders
        }
    }

    /// Rebuilds the tabs from the store and marks the one of the current screen.
    func updateFolderTabs() {
        guard let folderTabs else { return }
        let on = env.settings.folderTabsEnabled
        folderTabs.isHidden = !on
        guard on else { return }
        folderTabs.reload(folders: store.folders(), showsScratch: env.settings.scratchEnabled, active: activeFolderTab)
        layoutFolderTabs()
    }

    /// Places the rail from the top of the panel, beside the header. It ends where the notes end (the last
    /// card or folder row), so the panel is never taller than its content. The tabs that do not fit
    /// scroll. A very short or empty list still leaves room for `minimumTabs` small tabs, otherwise
    /// there would be no tab to leave it with.
    func layoutFolderTabs() {
        guard let v = rootView, let folderTabs, !folderTabs.isHidden else { return }
        let m = Metrics.outerMargin
        let top = m
        let column = columnFrame
        let w = railInset + FolderTabRailView.tuck
        folderTabs.railOnLeft = railOnLeft
        let x = railOnLeft ? column.minX - railInset : column.maxX - FolderTabRailView.tuck
        let panel = max(0, v.bounds.height - top - m)
        let notes = min(v.bounds.height, listContentHeight) - m - top
        let available = min(panel, max(notes, folderTabs.minimumHeight))
        let f = NSRect(x: x, y: top, width: w, height: folderTabs.fittingHeight(available: available))
        if folderTabs.frame != f { folderTabs.frame = f }
        folderTabs.layoutTabs()
    }

    /// Height of the rail from the top of the panel (0 while the tabs are off).
    public var railHeight: CGFloat {
        guard let v = rootView, let folderTabs, !folderTabs.isHidden else { return 0 }
        return min(v.bounds.height, folderTabs.frame.maxY + Metrics.outerMargin)
    }

    func folderTabPressed(_ kind: FolderTabRailView.Kind) {
        switch kind {
        case .scratch: showScratch(edit: false)
        case .folder(let id): showFolder(id)
        case .allFolders: showFolderList()
        }
    }

    func folderTabsSettingsChanged() {
        guard rootView != nil else { return }
        updateFolderTabs()
        rootView.needsLayout = true
        layoutViews()
    }
}
