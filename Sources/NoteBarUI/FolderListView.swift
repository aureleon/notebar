import AppKit
import NoteBarCore

@MainActor
protocol FolderListDelegate: AnyObject {
    func folderList(_ list: FolderListView, open folderId: FolderID)
    func folderListMenu(for folder: Folder?) -> NSMenu
    func folderList(_ list: FolderListView, rename folderId: FolderID, to name: String)
    func folderList(_ list: FolderListView, dropNote noteId: NoteID, on folderId: FolderID)
    func folderList(_ list: FolderListView, drop payload: ImportPayload, on folderId: FolderID)
    /// Inline rename finished (committed or cancelled). `hadFocus`: the field had keyboard focus.
    func folderListDidEndRename(_ list: FolderListView, hadFocus: Bool)
    /// Click on the Recently Deleted row.
    func folderListOpenTrash(_ list: FolderListView, from row: NSView)
}

/// Root view: the folder list (icon, name, pin mark, note count) inside one rounded group.
@MainActor
final class FolderListView: NSView {
    weak var delegate: FolderListDelegate?
    weak var actions: NoteActions?
    let env: AppEnvironment
    let scrollView = NSScrollView()
    private let doc: FolderListDocView
    private(set) var rows: [FolderRowView] = []
    /// See NotesListView.hoverSuppressed.
    var hoverSuppressed = false { didSet { if oldValue != hoverSuppressed { rows.forEach { $0.hoverSuppressed = hoverSuppressed } } } }
    var selectedFolderID: FolderID? { didSet { if oldValue != selectedFolderID { updateRowStates() } } }
    /// Shows the keyboard selection ring (the list has keyboard focus).
    var showsSelection = false { didSet { if oldValue != showsSelection { updateRowStates() } } }
    private(set) var renamingFolderID: FolderID?
    private var pendingReload = false
    /// Number of items in Recently Deleted; nil hides the row (only shown with that setting).
    var trashCount: Int? { didSet { if oldValue != trashCount { updateTrashRow() } } }
    private(set) var trashRow: TrashRowView?

    var topInset: CGFloat = 0 { didSet { scrollView.contentInsets.top = topInset; needsLayout = true } }

    init(env: AppEnvironment) {
        self.env = env
        doc = FolderListDocView()
        super.init(frame: .zero)
        doc.owner = self
        scrollView.drawsBackground = false
        scrollView.contentView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.scrollerStyle = .overlay
        scrollView.autohidesScrollers = true
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.verticalScrollElasticity = .allowed
        scrollView.documentView = doc
        scrollView.contentView.postsBoundsChangedNotifications = true
        addSubview(scrollView)
        NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: scrollView.contentView,
                                               queue: nil) { [weak self] _ in
            MainActor.assumeIsolated { self?.onContentExtentChange?() }
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    // MARK: Data

    func reload(folders: [Folder], counts: [FolderID: Int]) {
        if renamingFolderID != nil { pendingReload = true; return }
        var old = Dictionary(uniqueKeysWithValues: rows.map { ($0.folder.id, $0) })
        var newRows: [FolderRowView] = []
        for (i, f) in folders.enumerated() {
            let row = old.removeValue(forKey: f.id) ?? makeRow(f)
            row.configure(folder: f, count: counts[f.id] ?? 0, shortcutIndex: i < 9 ? i + 1 : nil)
            newRows.append(row)
        }
        for r in old.values { r.removeFromSuperview() }
        rows = newRows
        for r in rows where r.superview == nil { doc.addSubview(r) }
        if let sel = selectedFolderID, !folders.contains(where: { $0.id == sel }) { selectedFolderID = nil }
        updateRowStates()
        restyle()
        needsLayout = true
        layoutSubtreeIfNeeded()
    }

    private func makeRow(_ f: Folder) -> FolderRowView {
        let row = FolderRowView(folder: f, env: env)
        row.hoverSuppressed = hoverSuppressed
        row.owner = self
        return row
    }

    func row(for id: FolderID) -> FolderRowView? { rows.first { $0.folder.id == id } }

    var folderIDs: [FolderID] { rows.map(\.folder.id) }

    // MARK: Selection / keyboard

    func moveSelection(_ delta: Int) {
        guard !rows.isEmpty else { return }
        let ids = folderIDs
        if let sel = selectedFolderID, let i = ids.firstIndex(of: sel) {
            selectedFolderID = ids[max(0, min(ids.count - 1, i + delta))]
        } else {
            selectedFolderID = delta >= 0 ? ids.first : ids.last
        }
        if let sel = selectedFolderID, let r = row(for: sel) { scrollToVisible(r) }
    }

    func openSelected() {
        guard let sel = selectedFolderID else { return }
        delegate?.folderList(self, open: sel)
    }

    private func updateRowStates() {
        for r in rows { r.isSelected = showsSelection && r.folder.id == selectedFolderID }
    }

    func scrollToVisible(_ row: FolderRowView) {
        let clip = scrollView.contentView
        let visible = clip.bounds
        let top = visible.minY + topInset
        let rect = row.frame.insetBy(dx: 0, dy: -8)
        var y = visible.minY
        if rect.minY < top { y = rect.minY - topInset } else if rect.maxY > visible.maxY { y = rect.maxY - visible.height }
        let maxY = max(-topInset, doc.frame.height - visible.height)
        y = max(-topInset, min(y, maxY))
        if y != visible.minY { clip.scroll(to: NSPoint(x: 0, y: y)); scrollView.reflectScrolledClipView(clip) }
    }

    func scrollToTop() {
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: -topInset))
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    // MARK: Rename

    func beginRename(_ id: FolderID) {
        layoutSubtreeIfNeeded()
        guard let r = row(for: id) else { return }
        renamingFolderID = id
        scrollToVisible(r)
        r.beginRename()
    }

    func renameDidEnd(_ row: FolderRowView, newName: String?, hadFocus: Bool) {
        let id = row.folder.id
        renamingFolderID = nil
        pendingReload = false
        if let newName { delegate?.folderList(self, rename: id, to: newName) }
        delegate?.folderListDidEndRename(self, hadFocus: hadFocus)
    }

    /// Commits an inline rename (e.g. when the panel hides).
    func endRename() { rows.first { $0.isRenaming }?.commitRename() }

    // MARK: Style / layout

    private func updateTrashRow() {
        if let n = trashCount {
            let row = trashRow ?? {
                let r = TrashRowView(env: env)
                r.onClick = { [weak self] v in
                    guard let self else { return }
                    self.delegate?.folderListOpenTrash(self, from: v)
                }
                doc.addSubview(r)
                trashRow = r
                return r
            }()
            row.count = n
        } else {
            trashRow?.removeFromSuperview()
            trashRow = nil
        }
        needsLayout = true
    }

    func restyle() {
        for r in rows { r.restyle() }
        trashRow?.restyle()
        doc.updateGlass()
        doc.needsDisplay = true
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        restyle()
    }

    override func layout() {
        super.layout()
        scrollView.frame = bounds
        applyEdgeFade(to: scrollView, top: Metrics.gap, bottom: Metrics.outerMargin + 2)
        let w = scrollView.contentSize.width
        let m = Metrics.outerMargin
        let pad = Metrics.folderListPadding
        var y = pad
        for r in rows {
            r.frame = NSRect(x: m + pad, y: y, width: max(0, w - 2 * (m + pad)), height: Metrics.folderRowHeight)
            y += Metrics.folderRowHeight
        }
        if let trashRow {
            trashRow.frame = NSRect(x: m + pad, y: y, width: max(0, w - 2 * (m + pad)), height: Metrics.folderRowHeight)
            y += Metrics.folderRowHeight
        }
        let groupHeight = y + pad
        doc.groupRect = NSRect(x: m, y: 0, width: max(0, w - 2 * m), height: groupHeight)
        let visibleH = max(0, scrollView.contentSize.height - topInset)
        doc.frame = NSRect(x: 0, y: 0, width: w, height: max(groupHeight + Metrics.gap + m, visibleH))
        doc.needsDisplay = true
        onContentExtentChange?()
    }

    /// Called when `contentBottom` may have changed (layout, scroll).
    var onContentExtentChange: (() -> Void)?

    /// Bottom edge of the folder group in this view's coordinates, clamped to the view.
    var contentBottom: CGFloat {
        guard doc.groupRect.height > 0 else { return topInset }
        let y = convert(NSPoint(x: 0, y: doc.groupRect.maxY), from: doc).y
        return min(max(y, 0), bounds.height)
    }

    // MARK: Drag helpers used by rows / doc view

    fileprivate func beginFolderDrag(_ row: FolderRowView, event: NSEvent) {
        guard rows.count > 1 else { return }
        let item = NSPasteboardItem()
        item.setString(String(row.folder.id), forType: .noteBarFolderID)
        let dragItem = NSDraggingItem(pasteboardWriter: item)
        let img = NSImage(size: row.bounds.size)
        if let rep = row.renderBitmap(scale: 2) { img.addRepresentation(rep) }
        dragItem.setDraggingFrame(row.frame, contents: img)
        row.alphaValue = 0.4
        doc.draggingRow = row
        doc.beginDraggingSession(with: [dragItem], event: event, source: doc)
    }

    fileprivate func folderGapIndex(at p: NSPoint) -> Int {
        for (i, r) in rows.enumerated() where p.y < r.frame.midY { return i }
        return rows.count
    }

    fileprivate func row(at p: NSPoint) -> FolderRowView? { rows.first { $0.frame.contains(p) } }

    func performFolderMove(id: FolderID, gap: Int) {
        let folders = env.store.folders()
        guard let from = folders.firstIndex(where: { $0.id == id }) else { return }
        var dest = gap > from ? gap - 1 : gap
        let pinnedCount = folders.filter(\.isPinned).count
        let zone = folders[from].isPinned ? 0...max(0, pinnedCount - 1) : pinnedCount...max(pinnedCount, folders.count - 1)
        dest = max(zone.lowerBound, min(zone.upperBound, dest))
        if dest != from { actions?.reorderFolder(id, toIndex: dest) }
    }
}

/// Document view of the folder list: draws the rounded group behind the rows and handles drops.
@MainActor
final class FolderListDocView: NSView, NSDraggingSource {
    weak var owner: FolderListView?
    var groupRect: NSRect = .zero { didSet { if oldValue != groupRect { updateGlass() } } }
    private var glass: NSGlassEffectView?
    var draggingRow: FolderRowView?
    private let indicator = DropIndicatorView()
    private weak var dropRow: FolderRowView? { didSet { oldValue?.isDropTarget = false; dropRow?.isDropTarget = true } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.noteBarFolderID, .noteBarNoteID] + PasteboardImport.externalTypes)
        indicator.isHidden = true
        addSubview(indicator)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    /// Glass mode (`CardGlass`): a glass group background below the rows instead of the drawn one.
    func updateGlass() {
        guard let env = owner?.env else { return }
        CardGlass.sync(&glass, in: self, enabled: CardGlass.isEnabled(env) && groupRect.height > 0)
        guard let glass else { return }
        let c = env.themes.ui(effectiveAppearance)
        glass.cornerRadius = Metrics.folderGroupRadius
        glass.tintColor = CardGlass.tint(c.folderRowBackground, dark: c.isDark)
        glass.frame = groupRect
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateGlass()
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let env = owner?.env, groupRect.height > 0 else { return }
        let c = env.themes.ui(effectiveAppearance)
        let path = NSBezierPath(roundedRect: groupRect, xRadius: Metrics.folderGroupRadius, yRadius: Metrics.folderGroupRadius)
        guard glass == nil else { return }
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(CGFloat(c.shadowOpacity))
        shadow.shadowBlurRadius = 6
        shadow.shadowOffset = NSSize(width: 0, height: -1.5)
        shadow.set()
        c.folderRowBackground.setFill()
        path.fill()
        NSGraphicsContext.restoreGraphicsState()
        c.hairline.setStroke()
        path.lineWidth = 1
        path.stroke()
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let p = convert(event.locationInWindow, from: nil)
        let folder = owner?.rows.first { $0.frame.contains(p) }?.folder
        return owner?.delegate?.folderListMenu(for: folder)
    }

    // MARK: NSDraggingSource

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .withinApplication ? .move : []
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        draggingRow?.alphaValue = 1
        draggingRow = nil
        indicator.isHidden = true
        dropRow = nil
    }

    // MARK: NSDraggingDestination

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { draggingUpdated(sender) }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard let owner else { return [] }
        let pb = sender.draggingPasteboard
        let p = convert(sender.draggingLocation, from: nil)
        if PasteboardImport.hasInternalFolder(pb) {
            dropRow = nil
            let gap = owner.folderGapIndex(at: p)
            showIndicator(gap: gap)
            return .move
        }
        indicator.isHidden = true
        if PasteboardImport.hasInternalNote(pb) {
            dropRow = owner.row(at: p)
            return dropRow == nil ? [] : .move
        }
        if PasteboardImport.canImport(pb) {
            dropRow = owner.row(at: p)
            return dropRow == nil ? [] : .copy
        }
        return []
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        indicator.isHidden = true
        dropRow = nil
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let owner else { return false }
        let pb = sender.draggingPasteboard
        let p = convert(sender.draggingLocation, from: nil)
        defer { indicator.isHidden = true; dropRow = nil }
        if let id = PasteboardImport.folderID(from: pb) {
            owner.performFolderMove(id: id, gap: owner.folderGapIndex(at: p))
            return true
        }
        guard let row = owner.row(at: p) else { return false }
        if let noteId = PasteboardImport.noteID(from: pb) {
            owner.delegate?.folderList(owner, dropNote: noteId, on: row.folder.id)
            return true
        }
        let folderId = row.folder.id
        return PasteboardImport.receive(from: pb) { [weak owner] payload in
            guard let owner else { return }
            owner.delegate?.folderList(owner, drop: payload, on: folderId)
        }
    }

    private func showIndicator(gap: Int) {
        guard let owner, let env = Optional(owner.env) else { return }
        let rows = owner.rows
        let y: CGFloat
        if rows.isEmpty { y = Metrics.folderListPadding }
        else if gap >= rows.count { y = rows[rows.count - 1].frame.maxY }
        else { y = rows[gap].frame.minY }
        let x = rows.first?.frame.minX ?? groupRect.minX
        let w = rows.first?.frame.width ?? groupRect.width
        indicator.color = env.themes.ui(effectiveAppearance).accent
        indicator.frame = NSRect(x: x, y: y - 1.5, width: w, height: 3)
        indicator.isHidden = false
    }
}

/// One folder row.
@MainActor
final class FolderRowView: NSView, NSTextFieldDelegate {
    private(set) var folder: Folder
    private var count = 0
    weak var owner: FolderListView?
    private let env: AppEnvironment
    private let icon = NSImageView()
    private let nameLabel = PassthroughLabel()
    private let countLabel = PassthroughLabel()
    private let pinMark = NSImageView()
    private var renameField: NSTextField?
    private var hovering = false { didSet { if oldValue != hovering { needsDisplay = true } } }
    private var mouseInside = false { didSet { refreshHover() } }
    /// See NoteCardView.hoverSuppressed.
    var hoverSuppressed = false { didSet { if oldValue != hoverSuppressed { refreshHover() } } }
    private func refreshHover() { hovering = mouseInside && !hoverSuppressed }
    var isShowingHoverForTesting: Bool { hovering }
    func setHoveredForSnapshot(_ on: Bool) { mouseInside = on }
    var isSelected = false { didSet { if oldValue != isSelected { needsDisplay = true } } }
    var isDropTarget = false { didSet { if oldValue != isDropTarget { needsDisplay = true } } }
    private var tracking: NSTrackingArea?
    private var mouseDownPoint: NSPoint?
    private var didDrag = false

    init(folder: Folder, env: AppEnvironment) {
        self.folder = folder
        self.env = env
        super.init(frame: .zero)
        icon.imageScaling = .scaleProportionallyDown
        pinMark.imageScaling = .scaleProportionallyDown
        countLabel.alignment = .right
        for v in [icon, pinMark] as [NSView] { v.unregisterDraggedTypes() }
        addSubview(icon)
        addSubview(nameLabel)
        addSubview(pinMark)
        addSubview(countLabel)
        setAccessibilityRole(.button)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    var isRenaming: Bool { renameField != nil }

    func configure(folder: Folder, count: Int, shortcutIndex: Int?) {
        self.folder = folder
        self.count = count
        nameLabel.stringValue = folder.name
        countLabel.stringValue = "\(count)"
        pinMark.isHidden = !folder.isPinned
        toolTip = shortcutIndex.map { "\(folder.name) — ⌘\($0)" } ?? folder.name
        setAccessibilityLabel("\(folder.name), \(count) \(count == 1 ? "note" : "notes")\(folder.isPinned ? ", pinned" : "")")
        restyle()
        needsLayout = true
    }

    func restyle() {
        let c = env.themes.ui(effectiveAppearance)
        nameLabel.font = UIFonts.folderName(env.themes.fontSize)
        countLabel.font = UIFonts.folderCount(env.themes.fontSize)
        let tint = folder.color == .none ? c.folderIcon : env.themes.barColor(folder.color, appearance: effectiveAppearance)
        icon.image = Symbols.image(folder.isPinned ? "folder.fill" : "folder", size: 14, weight: .regular)
        icon.contentTintColor = tint
        pinMark.image = Symbols.image("pin.fill", size: 9, weight: .semibold)
        pinMark.contentTintColor = c.accent
        nameLabel.textColor = c.text
        countLabel.textColor = c.secondaryText
        renameField?.textColor = c.text
        needsDisplay = true
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        restyle()
    }

    override func layout() {
        super.layout()
        let h = bounds.height
        icon.frame = NSRect(x: 8, y: (h - 18) / 2, width: 20, height: 18)
        let cw = max(18, ceil((countLabel.stringValue as NSString).size(withAttributes: [.font: countLabel.font as Any]).width) + 6)
        countLabel.frame = NSRect(x: bounds.width - 8 - cw, y: (h - 15) / 2, width: cw, height: 15)
        var right = countLabel.frame.minX - 6
        if !pinMark.isHidden {
            pinMark.frame = NSRect(x: right - 11, y: (h - 12) / 2, width: 11, height: 12)
            right = pinMark.frame.minX - 4
        }
        let nh = ceil(nameLabel.intrinsicContentSize.height)
        nameLabel.frame = NSRect(x: 34, y: (h - nh) / 2, width: max(0, right - 34), height: nh)
        if let f = renameField {
            f.frame = NSRect(x: 31, y: (h - 22) / 2, width: max(40, bounds.width - 31 - 8), height: 22)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        let c = env.themes.ui(effectiveAppearance)
        let r = bounds.insetBy(dx: 0, dy: 1)
        let p = NSBezierPath(roundedRect: r, xRadius: 8, yRadius: 8)
        if isDropTarget {
            c.accent.withAlphaComponent(0.22).setFill(); p.fill()
            c.accent.setStroke(); p.lineWidth = 1.5; p.stroke()
        } else if isSelected {
            c.accent.withAlphaComponent(c.isDark ? 0.28 : 0.18).setFill(); p.fill()
        } else if hovering && !isRenaming {
            c.hoverFill.setFill(); p.fill()
        }
    }

    // MARK: Mouse

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let t = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(t)
        tracking = t
    }

    override func mouseEntered(with event: NSEvent) { mouseInside = true }
    override func mouseExited(with event: NSEvent) { mouseInside = false }

    override func mouseDown(with event: NSEvent) {
        guard !isRenaming else { return }
        if event.clickCount == 2 { return }
        mouseDownPoint = event.locationInWindow
        didDrag = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = mouseDownPoint, !didDrag, !isRenaming else { return }
        let p = event.locationInWindow
        if hypot(p.x - start.x, p.y - start.y) > 4 {
            didDrag = true
            owner?.beginFolderDrag(self, event: event)
        }
    }

    override func mouseUp(with event: NSEvent) {
        defer { mouseDownPoint = nil }
        guard mouseDownPoint != nil, !didDrag, !isRenaming else { return }
        if bounds.contains(convert(event.locationInWindow, from: nil)), let owner {
            owner.delegate?.folderList(owner, open: folder.id)
        }
    }

    override func accessibilityPerformPress() -> Bool {
        if let owner { owner.delegate?.folderList(owner, open: folder.id) }
        return true
    }

    // MARK: Inline rename

    func beginRename() {
        guard renameField == nil else { return }
        let f = RenameField(string: folder.name)
        f.font = UIFonts.folderName(env.themes.fontSize)
        f.isBordered = false
        f.isBezeled = true
        f.bezelStyle = .roundedBezel
        f.focusRingType = .default
        f.drawsBackground = true
        f.delegate = self
        f.cell?.isScrollable = true
        f.cell?.wraps = false
        f.lineBreakMode = .byClipping
        f.onCancel = { [weak self] in self?.finishRename(commit: false) }
        renameField = f
        nameLabel.isHidden = true
        countLabel.isHidden = true
        pinMark.isHidden = true
        addSubview(f)
        layout()
        restyle()
        window?.makeFirstResponder(f)
        f.currentEditor()?.selectAll(nil)
    }

    func commitRename() { finishRename(commit: true) }

    private func finishRename(commit: Bool) {
        guard let f = renameField else { return }
        let name = f.stringValue
        renameField = nil
        f.delegate = nil
        let hadFocus = f.currentEditor() != nil
        f.removeFromSuperview()
        nameLabel.isHidden = false
        countLabel.isHidden = false
        pinMark.isHidden = !folder.isPinned
        needsLayout = true
        needsDisplay = true
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        owner?.renameDidEnd(self, newName: commit && !trimmed.isEmpty ? trimmed : nil, hadFocus: hadFocus)
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        finishRename(commit: true)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) { finishRename(commit: false); return true }
        if commandSelector == #selector(NSResponder.insertNewline(_:)) { finishRename(commit: true); return true }
        return false
    }
}

/// Text field used for inline renames.
final class RenameField: NSTextField {
    var onCancel: (() -> Void)?
    convenience init(string: String) {
        self.init(frame: .zero)
        stringValue = string
        isEditable = true
        isSelectable = true
    }
    override func cancelOperation(_ sender: Any?) { onCancel?() }
}

/// Thin accent line that marks where a dragged card / folder will land.
final class DropIndicatorView: NSView {
    var color: NSColor = .controlAccentColor { didSet { needsDisplay = true } }
    override func draw(_ dirtyRect: NSRect) {
        color.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: bounds.height / 2, yRadius: bounds.height / 2).fill()
    }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// "Recently Deleted" at the end of the folder list (Keep deleted items = Recently Deleted). A click
/// opens the trash menu (Restore / Delete Now per item, Empty).
@MainActor
final class TrashRowView: NSView {
    private let env: AppEnvironment
    private let icon = NSImageView()
    private let nameLabel = PassthroughLabel()
    private let countLabel = PassthroughLabel()
    private var hovering = false { didSet { if oldValue != hovering { needsDisplay = true } } }
    private var tracking: NSTrackingArea?
    var onClick: ((NSView) -> Void)?
    var count = 0 {
        didSet {
            countLabel.stringValue = "\(count)"
            setAccessibilityLabel("Recently Deleted, \(count) \(count == 1 ? "item" : "items")")
            needsLayout = true
        }
    }

    init(env: AppEnvironment) {
        self.env = env
        super.init(frame: .zero)
        icon.imageScaling = .scaleProportionallyDown
        icon.unregisterDraggedTypes()
        nameLabel.stringValue = "Recently Deleted"
        countLabel.alignment = .right
        for v in [icon, nameLabel, countLabel] as [NSView] { addSubview(v) }
        setAccessibilityRole(.button)
        toolTip = "Deleted notes and folders"
        restyle()
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func restyle() {
        let c = env.themes.ui(effectiveAppearance)
        nameLabel.font = UIFonts.folderName(env.themes.fontSize)
        countLabel.font = UIFonts.folderCount(env.themes.fontSize)
        icon.image = Symbols.image("trash", size: 13, weight: .regular)
        icon.contentTintColor = c.secondaryText
        nameLabel.textColor = c.secondaryText
        countLabel.textColor = c.secondaryText
        needsDisplay = true
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        restyle()
    }

    override func layout() {
        super.layout()
        let h = bounds.height
        icon.frame = NSRect(x: 8, y: (h - 18) / 2, width: 20, height: 18)
        let cw = max(18, ceil((countLabel.stringValue as NSString).size(withAttributes: [.font: countLabel.font as Any]).width) + 6)
        countLabel.frame = NSRect(x: bounds.width - 8 - cw, y: (h - 15) / 2, width: cw, height: 15)
        let nh = ceil(nameLabel.intrinsicContentSize.height)
        nameLabel.frame = NSRect(x: 34, y: (h - nh) / 2, width: max(0, countLabel.frame.minX - 40), height: nh)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard hovering else { return }
        env.themes.ui(effectiveAppearance).hoverFill.setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 0, dy: 1), xRadius: 8, yRadius: 8).fill()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let t = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(t)
        tracking = t
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onClick?(self) }
    }
    override func accessibilityPerformPress() -> Bool { onClick?(self); return true }
}
