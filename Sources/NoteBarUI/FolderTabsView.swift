import AppKit
import NoteBarCore

/// The navigation in the header pill: Scratch, one chip per folder, and the "…" button.
/// Scratch and "…" stay in place. The folder chips between them scroll sideways and fade at an end
/// that has more. Only the open folder's chip is filled. The open Scratch chip holds ‹ day ›.
///
/// A chip is also where its folder is renamed (a text field in place), moved (drag it sideways), and
/// where notes, files, and text are dropped into the folder.
@MainActor
final class FolderTabsView: FlippedView, NSTextFieldDelegate, NSDraggingSource {
    enum Kind: Hashable { case scratch, folder(FolderID), more }

    static let gap: CGFloat = 4
    static let fade: CGFloat = 18
    /// A longer folder name is cut with an ellipsis (the tooltip has all of it).
    static let maxChipWidth: CGFloat = 160
    /// Room the folder chips keep beside an open Scratch chip. The day is cut, or left out, for it.
    static let minChipRoom: CGFloat = 56

    var onSelect: ((Kind) -> Void)?
    /// ‹ › in the open Scratch chip (-1 an earlier day, +1 a later one).
    var onStepDay: ((Int) -> Void)?
    /// Right click on a folder chip.
    var menuForFolder: ((FolderID) -> NSMenu?)?
    /// The "…" button (New Folder, Archive, Recently Deleted, Settings).
    var onMore: ((NSView) -> Void)?
    /// Inline rename committed with a new, non-empty name.
    var onRename: ((FolderID, String) -> Void)?
    /// Inline rename ended (committed or cancelled). `hadFocus`: the field had the keyboard focus.
    var onRenameEnd: ((_ hadFocus: Bool) -> Void)?
    /// A chip was dragged to the gap before chip `gap` (the chip count: after the last one).
    var onMoveFolder: ((FolderID, _ gap: Int) -> Void)?
    var onDropNote: ((NoteID, FolderID) -> Void)?
    var onDropPayload: ((ImportPayload, FolderID) -> Void)?

    private let env: AppEnvironment
    private(set) var scratchChip: FolderChipView?
    private(set) var folderChips: [FolderChipView] = []
    let moreButton = FolderChipView(kind: .more)
    /// Clips the folder chips while they scroll.
    private let clip = FlippedView()
    private(set) var active: Kind?
    /// The day on the open Scratch chip ("Today") and which way its stepper can go.
    var scratchTitle: String?
    var scratchStepper: (back: Bool, forward: Bool)?
    /// "Scratch" and its hotkey.
    var scratchToolTip = "Scratch"

    var allChips: [FolderChipView] { (scratchChip.map { [$0] } ?? []) + folderChips + [moreButton] }
    func chip(for id: FolderID) -> FolderChipView? { folderChips.first { $0.kind == .folder(id) } }

    init(env: AppEnvironment) {
        self.env = env
        super.init(frame: .zero)
        clip.clipsToBounds = true
        addSubview(clip)
        addSubview(moreButton)
        moreButton.symbolName = "ellipsis"
        moreButton.toolTip = "New Folder, Archive, Recently Deleted, and Settings"
        moreButton.setAccessibilityLabel("More")
        moreButton.onClick = { [weak self] in
            guard let self else { return }
            self.onMore?(self.moreButton)
        }
        indicator.isHidden = true
        clip.addSubview(indicator)
        registerForDraggedTypes([.noteBarFolderID, .noteBarNoteID] + PasteboardImport.externalTypes)
        setAccessibilityRole(.tabGroup)
        setAccessibilityLabel("Folders")
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: Data

    /// `counts`: notes per folder, for the tooltips.
    func reload(folders: [Folder], counts: [FolderID: Int], showsScratch: Bool, active: Kind?) {
        if showsScratch, scratchChip == nil {
            let t = FolderChipView(kind: .scratch)
            t.symbolName = "pencil.and.scribble"
            t.setAccessibilityLabel("Scratch")
            t.onClick = { [weak self] in self?.onSelect?(.scratch) }
            t.onStep = { [weak self] in self?.onStepDay?($0) }
            addSubview(t)
            scratchChip = t
        } else if !showsScratch, let t = scratchChip {
            t.removeFromSuperview()
            scratchChip = nil
        }
        // Reuse the chips by folder, so a hover survives a reload.
        var old = Dictionary(uniqueKeysWithValues: folderChips.map { ($0.kind, $0) })
        folderChips = folders.map { f in
            let t = old.removeValue(forKey: .folder(f.id)) ?? FolderChipView(kind: .folder(f.id))
            let n = counts[f.id] ?? 0
            let label = "\(f.name) · \(n) \(n == 1 ? "note" : "notes")" + (f.isPinned ? " · pinned" : "")
            t.title = f.name.trimmingCharacters(in: .whitespacesAndNewlines)
            t.toolTip = label
            t.setAccessibilityLabel(label)
            t.noteColor = f.color
            t.owner = self
            t.onClick = { [weak self] in self?.onSelect?(.folder(f.id)) }
            t.menuProvider = { [weak self] in self?.menuForFolder?(f.id) }
            if t.superview !== clip { clip.addSubview(t, positioned: .below, relativeTo: indicator) }
            return t
        }
        for t in old.values { t.removeFromSuperview() }
        if let r = renaming, chip(for: r.id) == nil { finishRename(commit: false) }
        if active != self.active { revealsActive = true }
        self.active = active
        for t in allChips {
            t.isActive = t.kind == active
            t.setAccessibilitySelected(t.isActive)
        }
        let openScratch = active == .scratch
        scratchChip?.title = openScratch ? scratchTitle : nil
        scratchChip?.stepper = openScratch ? scratchStepper : nil
        scratchChip?.toolTip = openScratch ? nil : scratchToolTip
        restyle()
        layoutChips()
    }

    func restyle() {
        let appearance = effectiveAppearance
        let ui = env.themes.ui(appearance)
        for t in allChips {
            if t.noteColor == .none {
                // On the pill (the header's material) a plain chip is a shade of the text color.
                t.fill = ui.text.withAlphaComponent(0.85)
                t.ink = ui.headerBackground.withAlphaComponent(1)
            } else {
                // The strong color of the folder (the left bar color), not the pale card fill: a chip
                // is small and must read on the pill.
                let strong = env.themes.barColor(t.noteColor, appearance: appearance)
                t.fill = strong
                t.ink = Self.isLight(strong) ? NSColor.black.withAlphaComponent(0.8) : .white
            }
            t.plainInk = ui.text
            t.accent = ui.accent
            t.fontSize = env.themes.fontSize
        }
        if let f = renaming?.field, let c = chip(for: renaming!.id) { style(f, on: c) }
        indicator.color = ui.accent
        needsLayout = true
    }

    private static func isLight(_ color: NSColor) -> Bool {
        guard let c = color.usingColorSpace(.sRGB) else { return true }
        return 0.299 * c.redComponent + 0.587 * c.greenComponent + 0.114 * c.blueComponent > 0.62
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        restyle()
    }

    // MARK: Layout

    /// How far the chips are scrolled (points), and whether the open one must be brought into view.
    private(set) var scrollOffset: CGFloat = 0
    private(set) var maxScrollOffset: CGFloat = 0
    private var revealsActive = true
    private var lastWidth: CGFloat = -1
    var canScroll: Bool { maxScrollOffset > 0 }
    private(set) var fadesLeft = false
    private(set) var fadesRight = false

    override func layout() {
        super.layout()
        layoutChips()
    }

    /// Scratch at the left end, "…" at the right end, the folder chips between them.
    func layoutChips() {
        let d = bounds.height
        guard d > 0 else { return }
        if bounds.width != lastWidth { lastWidth = bounds.width; revealsActive = true }
        var left: CGFloat = 0
        if let s = scratchChip {
            s.hidesTitle = false
            var w = d
            if s.title != nil {
                let natural = s.titleWidth + (s.stepper == nil ? 38 : 72)
                let most = bounds.width - d - 2 * Self.gap - Self.minChipRoom
                w = min(natural, most)
                // No room for a few letters of the day: the icon and ‹ › only.
                if w < natural, w < FolderChipView.compactScratchWidth + 28 {
                    s.hidesTitle = true
                    w = s.stepper == nil ? d : FolderChipView.compactScratchWidth
                }
            }
            s.frame = NSRect(x: 0, y: 0, width: w, height: d)
            left = w + Self.gap
        }
        moreButton.frame = NSRect(x: max(left, bounds.width - d), y: 0, width: d, height: d)
        let room = max(0, moreButton.frame.minX - Self.gap - left)
        clip.frame = NSRect(x: left, y: 0, width: room, height: d)
        var x: CGFloat = 0
        var frames: [NSRect] = []
        for t in folderChips {
            let w = min(room, Self.maxChipWidth, max(d, t.chipWidth))
            frames.append(NSRect(x: x, y: 0, width: w, height: d))
            x += w + Self.gap
        }
        maxScrollOffset = max(0, x - Self.gap - room)
        // The chip being renamed, else the open one, with a neighbor's edge in view on each side, so
        // it is plain that there are more. A scroll by hand stays until the open chip changes.
        let shown = renaming.map { Kind.folder($0.id) } ?? active
        if revealsActive, let i = folderChips.firstIndex(where: { $0.kind == shown }) {
            // A chip that nearly fills the room is centered instead, so neither end of it is cut.
            let peek = max(0, min(Self.fade + 10, ((room - frames[i].width) / 2).rounded(.down)))
            scrollOffset = min(scrollOffset, frames[i].minX - (i > 0 ? peek : 0))
            scrollOffset = max(scrollOffset, frames[i].maxX - room + (i < frames.count - 1 ? peek : 0))
        }
        revealsActive = false
        scrollOffset = min(max(scrollOffset, 0), maxScrollOffset).rounded()
        for (t, f) in zip(folderChips, frames) { t.frame = f.offsetBy(dx: -scrollOffset, dy: 0) }
        if let r = renaming, let c = chip(for: r.id) {
            let h = ceil(r.field.intrinsicContentSize.height)
            // Set by eye: the typed name starts where the drawn name does.
            r.field.frame = NSRect(x: c.frame.minX + c.textX + 1, y: ((d - h) / 2).rounded(),
                                   width: max(10, c.frame.width - c.textX - FolderChipView.trailingPad + 3), height: h)
        }
        updateFade()
    }

    /// Chips fade out at an end that has more of them (`fadesLeft`, `fadesRight`). The open chip is
    /// never under a fade while all of it is in view: at a narrow width it can reach the end of the
    /// room, and a fade would hide its dot or the end of its name.
    private func updateFade() {
        let w = clip.bounds.width
        fadesLeft = scrollOffset > 0.5
        fadesRight = scrollOffset < maxScrollOffset - 0.5
        var left = fadesLeft, right = fadesRight
        let shown = renaming.map { Kind.folder($0.id) } ?? active
        if let c = folderChips.first(where: { $0.kind == shown }), isInView(c) {
            if c.frame.minX < Self.fade { left = false }
            if c.frame.maxX > w - Self.fade { right = false }
        }
        guard w > 2 * Self.fade, left || right else { clip.layer?.mask = nil; return }
        clip.wantsLayer = true
        let mask = CAGradientLayer()
        mask.frame = clip.bounds
        mask.startPoint = CGPoint(x: 0, y: 0.5)
        mask.endPoint = CGPoint(x: 1, y: 0.5)
        let f = Self.fade / w
        let clear = NSColor.clear.cgColor, solid = NSColor.black.cgColor
        mask.colors = [left ? clear : solid, solid, solid, right ? clear : solid]
        mask.locations = [0, NSNumber(value: Double(f)), NSNumber(value: Double(1 - f)), 1]
        clip.layer?.mask = mask
    }

    func scroll(by dx: CGFloat) {
        scrollOffset += dx
        layoutChips()
    }

    /// Either wheel axis scrolls the chips (a mouse wheel has only the vertical one).
    override func scrollWheel(with event: NSEvent) {
        guard canScroll else { super.scrollWheel(with: event); return }
        let d = abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) ? event.scrollingDeltaX : event.scrollingDeltaY
        scroll(by: -d * (event.hasPreciseScrollingDeltas ? 1 : 8))
    }

    /// Whether the whole chip is inside the visible part of the strip.
    func isInView(_ chip: FolderChipView) -> Bool {
        chip.superview === clip ? clip.bounds.insetBy(dx: -0.5, dy: -0.5).contains(chip.frame) : !chip.isHidden
    }

    // MARK: Inline rename

    private var renaming: (id: FolderID, field: RenameField)?
    var renamingFolderID: FolderID? { renaming?.id }
    var renameField: NSTextField? { renaming?.field }

    /// The chip becomes a text field in place: same font, as wide as the name, and it grows with the
    /// typing. Return or a focus loss commits, Escape cancels, and so does an empty name.
    func beginRename(_ id: FolderID) {
        if renaming?.id == id { return }
        endRename()
        guard let c = chip(for: id) else { return }
        let f = RenameField(string: c.title ?? "")
        f.isBordered = false
        f.isBezeled = false
        f.drawsBackground = false
        f.focusRingType = .none
        f.cell?.isScrollable = true
        f.cell?.wraps = false
        f.cell?.usesSingleLineMode = true
        f.lineBreakMode = .byClipping
        f.delegate = self
        f.onCancel = { [weak self] in self?.finishRename(commit: false) }
        f.setAccessibilityLabel("Folder name")
        renaming = (id, f)
        c.isRenaming = true
        c.renameText = f.stringValue
        style(f, on: c)
        clip.addSubview(f)
        revealsActive = true
        layoutChips()
        window?.makeFirstResponder(f)
        f.currentEditor()?.selectAll(nil)
        // The window's field editor is shared (the search field uses it too): its colors are set for
        // the chip here and put back when the rename ends.
        if let editor = f.currentEditor() as? NSTextView, let ink = f.textColor {
            editorDefaults = (editor.insertionPointColor, editor.selectedTextAttributes)
            editor.insertionPointColor = ink
            editor.selectedTextAttributes = [.backgroundColor: ink.withAlphaComponent(0.28), .foregroundColor: ink]
        }
    }

    private var editorDefaults: (caret: NSColor, selection: [NSAttributedString.Key: Any])?

    private func style(_ f: NSTextField, on c: FolderChipView) {
        f.font = c.titleFont
        f.textColor = c.isActive ? c.ink : c.plainInk
    }

    /// Commits a rename in progress (the panel hides, another screen shows).
    func endRename() { finishRename(commit: true) }
    func cancelRename() { finishRename(commit: false) }

    private func finishRename(commit: Bool) {
        guard let r = renaming else { return }
        renaming = nil
        r.field.delegate = nil
        let name = r.field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let hadFocus = r.field.currentEditor() != nil
        if let editor = r.field.currentEditor() as? NSTextView, let d = editorDefaults {
            editor.insertionPointColor = d.caret
            editor.selectedTextAttributes = d.selection
        }
        editorDefaults = nil
        r.field.removeFromSuperview()
        if let c = chip(for: r.id) {
            c.isRenaming = false
            c.renameText = nil
        }
        revealsActive = true
        layoutChips()
        if commit, !name.isEmpty { onRename?(r.id, name) }
        onRenameEnd?(hadFocus)
    }

    func controlTextDidChange(_ obj: Notification) {
        guard let r = renaming, let c = chip(for: r.id) else { return }
        c.renameText = r.field.stringValue
        revealsActive = true
        layoutChips()
    }

    func controlTextDidEndEditing(_ obj: Notification) { finishRename(commit: true) }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) { finishRename(commit: false); return true }
        if commandSelector == #selector(NSResponder.insertNewline(_:)) { finishRename(commit: true); return true }
        return false
    }

    // MARK: Drag a chip to move its folder

    private let indicator = DropIndicatorView()
    private weak var draggedChip: FolderChipView?
    private weak var dropChip: FolderChipView? { didSet { oldValue?.isDropTarget = false; dropChip?.isDropTarget = true } }

    fileprivate func beginDrag(_ chip: FolderChipView, event: NSEvent) {
        guard case .folder(let id) = chip.kind, folderChips.count > 1, renaming == nil else { return }
        let item = NSPasteboardItem()
        item.setString(String(id), forType: .noteBarFolderID)
        let dragItem = NSDraggingItem(pasteboardWriter: item)
        let image = NSImage(size: chip.bounds.size)
        if let rep = chip.renderBitmap(scale: window?.backingScaleFactor ?? 2) { image.addRepresentation(rep) }
        dragItem.setDraggingFrame(convert(chip.bounds, from: chip), contents: image)
        chip.alphaValue = 0.4
        draggedChip = chip
        beginDraggingSession(with: [dragItem], event: event, source: self)
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .withinApplication ? .move : []
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        draggedChip?.alphaValue = 1
        draggedChip = nil
        endDropFeedback()
    }

    /// The gap a point (in this view) is nearest to: the index of the chip after it.
    func gapIndex(at p: NSPoint) -> Int {
        let x = clip.convert(p, from: self).x
        for (i, c) in folderChips.enumerated() where x < c.frame.midX { return i }
        return folderChips.count
    }

    private func folderChip(at p: NSPoint) -> FolderChipView? {
        let q = clip.convert(p, from: self)
        guard clip.bounds.contains(q) else { return nil }
        return folderChips.first { $0.frame.contains(q) }
    }

    private func showIndicator(gap: Int) {
        let x: CGFloat
        if folderChips.isEmpty { x = 0 }
        else if gap >= folderChips.count { x = folderChips[folderChips.count - 1].frame.maxX + Self.gap / 2 }
        else { x = folderChips[gap].frame.minX - Self.gap / 2 }
        let h = clip.bounds.height
        indicator.frame = NSRect(x: min(max(x - 1.5, 0), max(0, clip.bounds.width - 3)), y: 4, width: 3, height: max(0, h - 8))
        indicator.isHidden = false
    }

    private func endDropFeedback() {
        indicator.isHidden = true
        dropChip = nil
    }

    /// A drag held near an end that has more chips scrolls them (dragging updates repeat while the
    /// pointer rests).
    private func autoscroll(at p: NSPoint) {
        guard canScroll else { return }
        let x = clip.convert(p, from: self).x
        if x < Self.fade + 6, fadesLeft { scroll(by: -10) }
        if x > clip.bounds.width - Self.fade - 6, fadesRight { scroll(by: 10) }
    }

    // MARK: Drops on a chip (a note to move, or files, pictures, and text for a new note)

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { draggingUpdated(sender) }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        let pb = sender.draggingPasteboard
        let p = convert(sender.draggingLocation, from: nil)
        autoscroll(at: p)
        if PasteboardImport.hasInternalFolder(pb) {
            dropChip = nil
            showIndicator(gap: gapIndex(at: p))
            return .move
        }
        indicator.isHidden = true
        if PasteboardImport.hasInternalNote(pb) {
            dropChip = folderChip(at: p)
            return dropChip == nil ? [] : .move
        }
        if PasteboardImport.canImport(pb) {
            dropChip = folderChip(at: p)
            return dropChip == nil ? [] : .copy
        }
        return []
    }

    override func draggingExited(_ sender: NSDraggingInfo?) { endDropFeedback() }
    override func draggingEnded(_ sender: NSDraggingInfo) { endDropFeedback() }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let pb = sender.draggingPasteboard
        let p = convert(sender.draggingLocation, from: nil)
        defer { endDropFeedback() }
        if let id = PasteboardImport.folderID(from: pb) {
            onMoveFolder?(id, gapIndex(at: p))
            return true
        }
        guard case .folder(let folderId)? = folderChip(at: p)?.kind else { return false }
        if let noteId = PasteboardImport.noteID(from: pb) {
            onDropNote?(noteId, folderId)
            return true
        }
        return PasteboardImport.receive(from: pb) { [weak self] payload in
            self?.onDropPayload?(payload, folderId)
        }
    }
}

/// One chip of the strip: the Scratch button, a folder, or the "…" button.
/// - Folder: its name. The open one is filled with the folder's strong color. The others are plain
///   names with a dot in that color.
/// - Scratch: a round button. Open: a filled chip with its icon and ‹ day ›.
@MainActor
final class FolderChipView: NSView {
    /// Open Scratch chip without the day: the icon and ‹ ›.
    static let compactScratchWidth: CGFloat = 68
    static let trailingPad: CGFloat = 10

    let kind: FolderTabsView.Kind
    fileprivate weak var owner: FolderTabsView?
    var title: String? { didSet { if oldValue != title { needsDisplay = true } } }
    var symbolName: String? { didSet { if oldValue != symbolName { image = nil; needsDisplay = true } } }
    var noteColor: NoteColor = .none { didSet { if oldValue != noteColor { needsDisplay = true } } }
    /// Fill and ink of the open chip.
    var fill: NSColor = .labelColor { didSet { needsDisplay = true } }
    var ink: NSColor = .windowBackgroundColor { didSet { needsDisplay = true } }
    /// The text color of the header, for chips without a fill.
    var plainInk: NSColor = .labelColor { didSet { needsDisplay = true } }
    var accent: NSColor = .controlAccentColor { didSet { needsDisplay = true } }
    var fontSize: CGFloat = 14 { didSet { if oldValue != fontSize { image = nil; needsDisplay = true } } }
    var isActive = false { didSet { if oldValue != isActive { needsDisplay = true } } }
    /// A note or a file is dragged over the chip.
    var isDropTarget = false { didSet { if oldValue != isDropTarget { needsDisplay = true } } }
    /// The name is being edited in a field over the chip: no title is drawn, and the chip is as wide
    /// as the typed text.
    var isRenaming = false { didSet { if oldValue != isRenaming { needsDisplay = true } } }
    var renameText: String?
    var onClick: (() -> Void)?
    var menuProvider: (() -> NSMenu?)?
    /// The open Scratch chip: ‹ day › (which way it can step).
    var stepper: (back: Bool, forward: Bool)? { didSet { needsDisplay = true } }
    var onStep: ((Int) -> Void)?
    /// Too narrow for the day: the open Scratch chip shows its icon and ‹ › only.
    var hidesTitle = false { didSet { if oldValue != hidesTitle { needsDisplay = true } } }

    private var image: NSImage?
    private(set) var hovering = false { didSet { if oldValue != hovering { needsDisplay = true } } }
    private var pressed = false { didSet { if oldValue != pressed { needsDisplay = true } } }
    private var tracking: NSTrackingArea?
    private var mouseDownPoint: NSPoint?
    private var didDrag = false

    init(kind: FolderTabsView.Kind) {
        self.kind = kind
        super.init(frame: .zero)
        setAccessibilityRole(.button)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    override func menu(for event: NSEvent) -> NSMenu? { isRenaming ? nil : menuProvider?() }

    private var isFolder: Bool { if case .folder = kind { return true }; return false }
    var titleFont: NSFont { .systemFont(ofSize: fontSize - 1.5, weight: .semibold) }
    private func width(of text: String) -> CGFloat { ceil((text as NSString).size(withAttributes: [.font: titleFont]).width) }
    var titleWidth: CGFloat { width(of: title ?? "") }
    /// A folder with a color has a dot before its name.
    var showsDot: Bool { isFolder && noteColor != .none }
    /// Where the name starts.
    var textX: CGFloat { showsDot ? 22 : 10 }
    /// Width of a folder chip for its name (or for the text typed into the rename field).
    var chipWidth: CGFloat {
        let text = renameText.map { max(width(of: $0), 14) + 8 } ?? titleWidth
        return textX + text + Self.trailingPad
    }
    private var backRect: NSRect { NSRect(x: 27, y: 0, width: 16, height: bounds.height) }
    private var forwardRect: NSRect { NSRect(x: bounds.width - 24, y: 0, width: 16, height: bounds.height) }

    override func draw(_ dirtyRect: NSRect) {
        let b = bounds
        let r = b.height / 2
        let capsule = NSBezierPath(roundedRect: b, xRadius: r, yRadius: r)
        // Only the open chip is filled, so it is the one that stands out. The other folders are plain
        // names (a faint fill under the pointer). Scratch and "…" are round buttons.
        if isActive {
            fill.setFill()
            capsule.fill()
        } else if !isFolder {
            plainInk.withAlphaComponent(hovering || pressed ? 0.17 : 0.09).setFill()
            capsule.fill()
        } else if hovering || pressed || isRenaming {
            plainInk.withAlphaComponent(0.08).setFill()
            capsule.fill()
        }
        if isDropTarget || isRenaming {
            let ring = NSBezierPath(roundedRect: b.insetBy(dx: 0.75, dy: 0.75), xRadius: r - 0.75, yRadius: r - 0.75)
            if isDropTarget {
                accent.withAlphaComponent(0.22).setFill()
                ring.fill()
            }
            accent.setStroke()
            ring.lineWidth = 1.5
            ring.stroke()
        }
        let inkColor = isActive ? ink : plainInk.withAlphaComponent(isFolder ? (hovering ? 0.95 : 0.62) : (hovering ? 1 : 0.8))
        var attrs: [NSAttributedString.Key: Any] = [.font: titleFont, .foregroundColor: inkColor]
        let para = NSMutableParagraphStyle()
        para.lineBreakMode = .byTruncatingTail
        attrs[.paragraphStyle] = para
        func drawText(_ text: String, from x: CGFloat, to right: CGFloat) {
            let h = ceil((text as NSString).size(withAttributes: attrs).height)
            (text as NSString).draw(with: NSRect(x: x, y: ((b.height - h) / 2).rounded(), width: max(0, right - x), height: h),
                                    options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], attributes: attrs)
        }
        if let symbolName {
            if image == nil { image = Symbols.image(symbolName, size: fontSize - 3, weight: .semibold) }
            guard let image else { return }
            guard let title, isActive else {
                Symbols.draw(image, in: b, color: inkColor, fraction: 1)
                return
            }
            // The open Scratch chip: its icon, then ‹ day ›.
            Symbols.draw(image, in: NSRect(x: 8, y: 0, width: 18, height: b.height), color: inkColor, fraction: 1)
            if let stepper {
                for (name, rect, on) in [("chevron.left", backRect, stepper.back), ("chevron.right", forwardRect, stepper.forward)] {
                    if let c = Symbols.image(name, size: fontSize - 5, weight: .bold) {
                        Symbols.draw(c, in: rect, color: inkColor, fraction: on ? 0.9 : 0.3)
                    }
                }
            }
            if !hidesTitle { drawText(title, from: stepper == nil ? 29 : 46, to: stepper == nil ? b.width - 9 : forwardRect.minX - 2) }
            return
        }
        if showsDot {
            // The dot keeps its place when the chip opens, so the names do not jump.
            (isActive ? ink.withAlphaComponent(0.9) : fill).setFill()
            NSBezierPath(ovalIn: NSRect(x: 10, y: (b.height - 7) / 2, width: 7, height: 7)).fill()
        }
        if !isRenaming, let title { drawText(title, from: textX, to: b.width - Self.trailingPad + 2) }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        // .activeAlways: the panel's app is usually not active.
        let t = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                               owner: self, userInfo: nil)
        addTrackingArea(t)
        tracking = t
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false; pressed = false }

    override func mouseDown(with event: NSEvent) {
        guard !isRenaming else { return }
        pressed = true
        mouseDownPoint = event.locationInWindow
        didDrag = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard isFolder, let start = mouseDownPoint, !didDrag, !isRenaming else { return }
        let p = event.locationInWindow
        if hypot(p.x - start.x, p.y - start.y) > 4 {
            didDrag = true
            pressed = false
            owner?.beginDrag(self, event: event)
        }
    }

    override func mouseUp(with event: NSEvent) {
        defer { mouseDownPoint = nil }
        pressed = false
        guard mouseDownPoint != nil, !didDrag, !isRenaming else { return }
        let p = convert(event.locationInWindow, from: nil)
        guard bounds.contains(p) else { return }
        if let stepper {
            if backRect.insetBy(dx: -4, dy: 0).contains(p) { if stepper.back { onStep?(-1) }; return }
            if forwardRect.insetBy(dx: -6, dy: 0).contains(p) { if stepper.forward { onStep?(1) }; return }
        }
        onClick?()
    }

    override func accessibilityPerformPress() -> Bool { onClick?(); return true }

    func setHoveredForSnapshot(_ on: Bool) { hovering = on }
    /// For checks: a click on ‹ (-1) or › (+1) of the open Scratch chip. False: that way is off.
    func stepForChecks(_ delta: Int) -> Bool {
        guard let stepper, delta < 0 ? stepper.back : stepper.forward else { return false }
        onStep?(delta)
        return true
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
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func cancelOperation(_ sender: Any?) { onCancel?() }
}

/// Thin accent line that marks where a dragged card / folder chip will land.
final class DropIndicatorView: NSView {
    var color: NSColor = .controlAccentColor { didSet { needsDisplay = true } }
    override func draw(_ dirtyRect: NSRect) {
        color.setFill()
        let r = min(bounds.width, bounds.height) / 2
        NSBezierPath(roundedRect: bounds, xRadius: r, yRadius: r).fill()
    }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
