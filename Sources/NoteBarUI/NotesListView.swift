import AppKit
import NoteBarCore

@MainActor
protocol NotesListDelegate: AnyObject {
    var actions: NoteActions { get }
    func notesList(_ list: NotesListView, card: NoteCardView, editorFocusChanged focused: Bool)
    func notesList(_ list: NotesListView, card: NoteCardView, editorEvent event: EditorEvent)
    func notesList(_ list: NotesListView, menuFor card: NoteCardView) -> NSMenu?
    func notesList(_ list: NotesListView, clicked card: NoteCardView, event: NSEvent)
    func notesListBackgroundClicked(_ list: NotesListView)
    func notesListBackgroundMenu(_ list: NotesListView) -> NSMenu?
    func notesList(_ list: NotesListView, dropOnBackground payload: ImportPayload)
    func notesList(_ list: NotesListView, drop payload: ImportPayload, on card: NoteCardView) -> Bool
    /// A card was dragged to `gap` (0 = before the first displayed card, count = after the last).
    func notesList(_ list: NotesListView, moveNote id: NoteID, toGap gap: Int)
}

/// The scrolling stack of note cards. Frame-based layout (fast with a few hundred cards); live editors
/// are created only for cards near the viewport and kept while the list shows the same folder.
@MainActor
final class NotesListView: NSView, NoteCardDelegate {
    weak var delegate: NotesListDelegate?
    let env: AppEnvironment
    let scrollView = NSScrollView()
    private let doc: NotesDocView
    private(set) var cards: [NoteCardView] = []
    private var cardsByID: [NoteID: NoteCardView] = [:]
    private let emptyView = EmptyStateView()
    private let dropHint = DropHintView()
    private var lastSize: NSSize = .zero
    private var isLayingOut = false
    private var liveEditorsScheduled = false

    /// Pinned at the top of the document (search scope bar). Scrolls with the cards.
    var topAccessory: NSView? {
        didSet {
            oldValue?.removeFromSuperview()
            if let topAccessory { doc.addSubview(topAccessory) }
            layoutCards(animated: false)
            needsLayout = true
        }
    }

    var topInset: CGFloat = 0 {
        didSet {
            scrollView.contentInsets = NSEdgeInsets(top: topInset, left: 0, bottom: 0, right: 0)
            scrollView.scrollerInsets = NSEdgeInsets(top: 0, left: 0, bottom: Metrics.outerMargin, right: 0)
            needsLayout = true
        }
    }

    /// Reordering by drag (off in search results).
    var allowsReorder = true
    var selectedNoteID: NoteID? { didSet { if oldValue != selectedNoteID { updateSelection() } } }
    /// The keyboard selection ring is shown only while the list has keyboard focus.
    var showsSelection = false { didSet { if oldValue != showsSelection { updateSelection() } } }

    init(env: AppEnvironment) {
        self.env = env
        doc = NotesDocView()
        super.init(frame: .zero)
        doc.owner = self
        scrollView.drawsBackground = false
        scrollView.contentView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.scrollerStyle = .overlay
        scrollView.autohidesScrollers = true
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.horizontalScrollElasticity = .none
        scrollView.documentView = doc
        scrollView.contentView.postsBoundsChangedNotifications = true
        addSubview(scrollView)
        emptyView.isHidden = true
        let themes = env.themes
        emptyView.colorsProvider = { a in themes.ui(a) }
        emptyView.fontSize = themes.fontSize
        dropHint.fontSize = themes.fontSize
        addSubview(emptyView)
        dropHint.isHidden = true
        addSubview(dropHint)
        NotificationCenter.default.addObserver(self, selector: #selector(clipBoundsChanged),
                                               name: NSView.boundsDidChangeNotification, object: scrollView.contentView)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    var actions: NoteActions { delegate!.actions }

    // MARK: Data

    func card(for id: NoteID) -> NoteCardView? { cardsByID[id] }
    var noteIDs: [NoteID] { cards.map(\.note.id) }

    /// Drops every card (folder switch).
    func removeAll() {
        for c in cards { c.removeFromSuperview() }
        cards = []
        cardsByID = [:]
        selectedNoteID = nil
        layoutCards(animated: false)
        scrollToTop()
    }

    /// Diffs the displayed cards against `notes`: inserts / removes / reorders card views and keeps
    /// the existing editors.
    func setNotes(_ notes: [Note], animated: Bool, folderNames: [FolderID: String]? = nil,
                  forceUnfolded: Bool = false, query: String = "") {
        var old = cardsByID
        var newCards: [NoteCardView] = []
        var inserted: [NoteCardView] = []
        for n in notes {
            let card: NoteCardView
            if let c = old.removeValue(forKey: n.id) {
                card = c
                if c.note != n {
                    if Self.sameMetadata(c.note, n) { c.bodyDidChange(n) } else { c.update(note: n) }
                }
            } else {
                card = NoteCardView(note: n, env: env)
                card.delegate = self
                inserted.append(card)
            }
            card.forceUnfolded = forceUnfolded
            card.folderName = folderNames?[n.folderId]
            card.searchQuery = query
            newCards.append(card)
        }
        var lostFocus = false
        for c in old.values {
            if let e = c.editor, e.isEditingFocused { lostFocus = true }
            c.removeFromSuperview()
        }
        cards = newCards
        cardsByID = Dictionary(uniqueKeysWithValues: cards.map { ($0.note.id, $0) })
        for c in inserted { doc.addSubview(c) }
        if let sel = selectedNoteID, cardsByID[sel] == nil { selectedNoteID = nil }
        updateSelection()
        let animate = animated && NoteBarUIOptions.animations && window != nil
        layoutCards(animated: animate, fadeIn: Set(inserted.map { ObjectIdentifier($0) }))
        // Every card marks all its matches (cards whose editor is created later mark it then). An empty
        // query clears the marks. The find indicator is shown only for the first match of the first card.
        for card in newCards { card.highlightSearchMatch() }
        // The edited note left the list (moved / deleted elsewhere): keep keyboard focus in the panel.
        if lostFocus { delegate?.notesListBackgroundClicked(self) }
    }

    /// Everything but the body / date is equal.
    static func sameMetadata(_ a: Note, _ b: Note) -> Bool {
        a.color == b.color && a.mode == b.mode && a.isFolded == b.isFolded && a.isPinned == b.isPinned
            && a.folderId == b.folderId && a.sortIndex == b.sortIndex
    }

    func noteChanged(_ note: Note) { cardsByID[note.id]?.update(note: note) }
    func noteBodyChanged(_ note: Note) { cardsByID[note.id]?.bodyDidChange(note) }

    func setEmptyState(title: String?, subtitle: String?) {
        emptyView.title = title ?? ""
        emptyView.subtitle = subtitle ?? ""
        emptyView.isHidden = title == nil
        needsLayout = true
        onContentExtentChange?()
    }

    func restyleAll() {
        for c in cards { c.themeDidChange() }
        emptyView.restyle()
        layoutCards(animated: false)
    }

    // MARK: Layout

    override func layout() {
        super.layout()
        scrollView.frame = bounds
        applyEdgeFade(to: scrollView, top: Metrics.gap, bottom: Metrics.outerMargin + 2)
        let visibleTop = topInset
        let accessoryH: CGFloat = topAccessory == nil ? 0 : Metrics.scopeBarHeight + Metrics.gap
        emptyView.frame = NSRect(x: Metrics.outerMargin, y: visibleTop + accessoryH + 24, width: max(0, bounds.width - 2 * Metrics.outerMargin), height: 80)
        dropHint.frame = NSRect(x: Metrics.outerMargin, y: max(0, topInset - Metrics.gap), width: max(0, bounds.width - 2 * Metrics.outerMargin),
                                height: max(0, bounds.height - topInset + Metrics.gap - Metrics.outerMargin))
        let size = scrollView.contentSize
        if size != lastSize {
            lastSize = size
            layoutCards(animated: false)
        }
    }

    private var cardWidth: CGFloat { max(60, scrollView.contentSize.width - 2 * Metrics.outerMargin) }

    /// Positions every card. Keeps the first visible card in place (scroll anchoring) unless the list is
    /// scrolled to the top.
    /// Height of all cards plus margins, from the last layout pass (used by snapshots).
    private(set) var lastContentHeight: CGFloat = 0

    func layoutCards(animated: Bool, fadeIn: Set<ObjectIdentifier> = []) {
        guard !isLayingOut else { return }
        isLayingOut = true
        defer { isLayingOut = false }
        let clip = scrollView.contentView
        let width = scrollView.contentSize.width
        let cw = cardWidth
        let m = Metrics.outerMargin
        let pad = Metrics.cardShadowPad

        // Anchor.
        let atTop = clip.bounds.minY <= -topInset + 1
        var anchor: (NoteCardView, CGFloat)?
        if !atTop && !animated {
            let visTop = clip.bounds.minY + topInset
            if let a = cards.first(where: { $0.frame.maxY - pad > visTop }) {
                anchor = (a, a.frame.minY - clip.bounds.minY)
            }
        }

        var y: CGFloat = 0
        if let acc = topAccessory {
            let h = acc.fittingSize.height > 0 ? acc.fittingSize.height : Metrics.scopeBarHeight
            acc.frame = NSRect(x: m, y: y, width: cw, height: h)
            y += h + Metrics.gap
        }
        var targets: [(NoteCardView, NSRect)] = []
        for card in cards {
            let h = card.cardHeight(forWidth: cw)
            let r = NSRect(x: m - pad, y: y - pad, width: cw + 2 * pad, height: h + 2 * pad)
            targets.append((card, r))
            y += h + Metrics.gap
        }
        let contentH = (cards.isEmpty ? y : y - Metrics.gap) + Metrics.gap + m
        lastContentHeight = contentH
        let visibleH = max(0, scrollView.contentSize.height - topInset)
        doc.frame = NSRect(x: 0, y: 0, width: width, height: max(contentH, visibleH))

        if animated {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.22
                ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                ctx.allowsImplicitAnimation = true
                for (card, r) in targets {
                    if fadeIn.contains(ObjectIdentifier(card)) {
                        card.frame = r
                        card.alphaValue = 0
                        card.animator().alphaValue = card.isDragSource ? 0.35 : 1
                    } else if card.frame != r {
                        card.animator().frame = r
                    }
                }
            }
        } else {
            for (card, r) in targets where card.frame != r { card.frame = r }
        }
        for (card, _) in targets { card.layoutSubtreeIfNeeded() }

        if let (card, offset) = anchor {
            let newY = card.frame.minY - offset
            scrollClip(to: newY)
        }
        scheduleLiveEditors()
        onContentExtentChange?()
    }

    private func scrollClip(to y: CGFloat) {
        let clip = scrollView.contentView
        let maxY = max(-topInset, doc.frame.height - clip.bounds.height)
        let clamped = max(-topInset, min(y, maxY))
        if abs(clamped - clip.bounds.minY) > 0.5 {
            clip.scroll(to: NSPoint(x: 0, y: clamped))
            scrollView.reflectScrolledClipView(clip)
        }
    }

    // MARK: Lazy editors

    @objc private func clipBoundsChanged() {
        scheduleLiveEditors()
        onContentExtentChange?()
    }

    /// Called when `contentBottom` may have changed (layout, scroll, empty state).
    var onContentExtentChange: (() -> Void)?

    /// Bottom edge of the last visible element (search bar, last card, empty state) in this view's
    /// coordinates, clamped to the view. `topInset` when there is nothing.
    var contentBottom: CGFloat {
        var docBottom: CGFloat?
        if let acc = topAccessory { docBottom = acc.frame.maxY }
        if let last = cards.last { docBottom = max(docBottom ?? 0, last.frame.maxY - Metrics.cardShadowPad) }
        var y = docBottom.map { convert(NSPoint(x: 0, y: $0), from: doc).y } ?? topInset
        if !emptyView.isHidden { y = max(y, emptyView.frame.maxY) }
        return min(max(y, 0), bounds.height)
    }

    private func scheduleLiveEditors() {
        guard !liveEditorsScheduled else { return }
        liveEditorsScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.liveEditorsScheduled = false
            self.updateLiveEditors()
        }
    }

    /// Creates editors for unfolded cards within `editorPrefetchDistance` of the visible area.
    func updateLiveEditors() {
        let vis = scrollView.contentView.bounds.insetBy(dx: 0, dy: -Metrics.editorPrefetchDistance)
        var created = false
        for c in cards where !c.isFolded && !c.hasEditor && c.frame.intersects(vis) {
            if c.ensureEditor() { created = true }
        }
        if created { layoutCards(animated: false) }
    }

    /// Creates editors for every card now (snapshots / export).
    func createAllEditors() {
        for c in cards where !c.isFolded { c.ensureEditor() }
        layoutCards(animated: false)
    }

    // MARK: Scrolling

    func scrollToTop() { scrollClip(to: -topInset) }

    /// Scrolls the minimum amount so the card is fully visible (or its top, if it is taller than the view).
    func scrollToCard(_ card: NoteCardView, animated: Bool = false) {
        let clip = scrollView.contentView
        let vis = clip.bounds
        let r = card.frame.insetBy(dx: 0, dy: Metrics.cardShadowPad - 4)
        let top = vis.minY + topInset
        var y = vis.minY
        if r.minY < top { y = r.minY - topInset }
        else if r.maxY > vis.maxY { y = min(r.maxY - vis.height, r.minY - topInset) }
        else { return }
        if animated && NoteBarUIOptions.animations {
            let maxY = max(-topInset, doc.frame.height - clip.bounds.height)
            let clamped = max(-topInset, min(y, maxY))
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.2
                clip.animator().setBoundsOrigin(NSPoint(x: 0, y: clamped))
            }
            scrollView.reflectScrolledClipView(clip)
        } else {
            scrollClip(to: y)
        }
        updateLiveEditors()
    }

    /// Keeps the caret of the focused text view visible after a card grew.
    private func scrollCaretVisible(in card: NoteCardView) {
        guard let tv = window?.firstResponder as? NSTextView, card.containsDescendant(tv) else { return }
        tv.scrollRangeToVisible(tv.selectedRange())
    }

    // MARK: Selection

    private func updateSelection() {
        for c in cards { c.isSelected = showsSelection && c.note.id == selectedNoteID }
    }

    func index(of id: NoteID) -> Int? { cards.firstIndex { $0.note.id == id } }

    // MARK: NoteCardDelegate

    func cardNeedsLayout(_ card: NoteCardView) {
        guard !isLayingOut else {
            DispatchQueue.main.async { [weak self] in self?.layoutCards(animated: false) }
            return
        }
        layoutCards(animated: false)
        if card.isEditorFocused { scrollCaretVisible(in: card) }
    }

    func card(_ card: NoteCardView, editorEvent event: EditorEvent) {
        delegate?.notesList(self, card: card, editorEvent: event)
    }

    func card(_ card: NoteCardView, editorFocusChanged focused: Bool) {
        delegate?.notesList(self, card: card, editorFocusChanged: focused)
    }

    func cardClicked(_ card: NoteCardView, event: NSEvent) {
        delegate?.notesList(self, clicked: card, event: event)
    }

    func cardMenu(_ card: NoteCardView) -> NSMenu? { delegate?.notesList(self, menuFor: card) }

    func card(_ card: NoteCardView, drop payload: ImportPayload) -> Bool {
        delegate?.notesList(self, drop: payload, on: card) ?? false
    }

    func cardBeginDrag(_ card: NoteCardView, event: NSEvent) {
        guard allowsReorder else { return }
        let item = NSPasteboardItem()
        item.setString(String(card.note.id), forType: .noteBarNoteID)
        let dragItem = NSDraggingItem(pasteboardWriter: item)
        let image = NSImage(size: card.bounds.size)
        if let rep = card.renderBitmap(scale: window?.backingScaleFactor ?? 2) { image.addRepresentation(rep) }
        dragItem.setDraggingFrame(card.frame, contents: image)
        card.isDragSource = true
        doc.draggingCard = card
        let session = doc.beginDraggingSession(with: [dragItem], event: event, source: doc)
        session.animatesToStartingPositionsOnCancelOrFail = true
        session.draggingFormation = .none
    }

    // MARK: Drop geometry

    fileprivate func gapIndex(at p: NSPoint) -> Int {
        for (i, c) in cards.enumerated() where p.y < c.frame.midY { return i }
        return cards.count
    }

    fileprivate func indicatorRect(forGap gap: Int) -> NSRect {
        let m = Metrics.outerMargin
        let pad = Metrics.cardShadowPad
        let y: CGFloat
        if cards.isEmpty { y = 0 }
        else if gap >= cards.count { y = cards[cards.count - 1].frame.maxY - pad + Metrics.gap / 2 }
        else { y = cards[gap].frame.minY + pad - Metrics.gap / 2 }
        return NSRect(x: m + 8, y: y - 1.5, width: max(0, cardWidth - 16), height: 3)
    }

    fileprivate func setExternalDropActive(_ on: Bool) {
        if dropHint.isHidden == !on { return }
        dropHint.colors = env.themes.ui(effectiveAppearance)
        dropHint.isHidden = !on
    }

    fileprivate func handleBackgroundDrop(_ payload: ImportPayload) { delegate?.notesList(self, dropOnBackground: payload) }
    fileprivate func handleMove(_ id: NoteID, gap: Int) { delegate?.notesList(self, moveNote: id, toGap: gap) }
    fileprivate func handleBackgroundClick() { delegate?.notesListBackgroundClicked(self) }
    fileprivate func backgroundMenu() -> NSMenu? { delegate?.notesListBackgroundMenu(self) }
}

/// Document view of the notes list: background drops, the reorder indicator, the drag source.
@MainActor
final class NotesDocView: NSView, NSDraggingSource {
    weak var owner: NotesListView?
    var draggingCard: NoteCardView?
    private let indicator = DropIndicatorView()

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.noteBarNoteID] + PasteboardImport.externalTypes)
        indicator.isHidden = true
        addSubview(indicator)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) { owner?.handleBackgroundClick() }

    override func menu(for event: NSEvent) -> NSMenu? { owner?.backgroundMenu() }

    // MARK: Source

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .withinApplication ? .move : []
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        draggingCard?.isDragSource = false
        draggingCard = nil
        indicator.isHidden = true
        owner?.setExternalDropActive(false)
    }

    // MARK: Destination

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { draggingUpdated(sender) }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard let owner else { return [] }
        let pb = sender.draggingPasteboard
        if PasteboardImport.hasInternalNote(pb) {
            owner.setExternalDropActive(false)
            guard owner.allowsReorder, let id = PasteboardImport.noteID(from: pb), owner.card(for: id) != nil else {
                indicator.isHidden = true
                return []
            }
            let gap = owner.gapIndex(at: convert(sender.draggingLocation, from: nil))
            indicator.color = owner.env.themes.ui(effectiveAppearance).accent
            indicator.frame = owner.indicatorRect(forGap: gap)
            indicator.isHidden = false
            addSubview(indicator, positioned: .above, relativeTo: nil)
            return .move
        }
        indicator.isHidden = true
        if PasteboardImport.canImport(pb) {
            owner.setExternalDropActive(true)
            return .copy
        }
        return []
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        indicator.isHidden = true
        owner?.setExternalDropActive(false)
    }

    override func draggingEnded(_ sender: NSDraggingInfo) {
        indicator.isHidden = true
        owner?.setExternalDropActive(false)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let owner else { return false }
        let pb = sender.draggingPasteboard
        indicator.isHidden = true
        owner.setExternalDropActive(false)
        if let id = PasteboardImport.noteID(from: pb) {
            guard owner.allowsReorder, owner.card(for: id) != nil else { return false }
            owner.handleMove(id, gap: owner.gapIndex(at: convert(sender.draggingLocation, from: nil)))
            return true
        }
        return PasteboardImport.receive(from: pb) { [weak owner] payload in
            owner?.handleBackgroundDrop(payload)
        }
    }
}

/// "No notes yet — Press + or drop something here".
@MainActor
final class EmptyStateView: NSView {
    var title = "" { didSet { needsDisplay = true } }
    var subtitle = "" { didSet { needsDisplay = true } }
    var colorsProvider: ((NSAppearance) -> UIColors)?
    /// Theme font size (set by the owner).
    var fontSize: CGFloat = 14 { didSet { needsDisplay = true } }

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func restyle() { needsDisplay = true }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let colors = colorsProvider?(effectiveAppearance)
        let dark = effectiveAppearance.isDark
        let main = colors?.text ?? (dark ? .white : .black)
        let para = NSMutableParagraphStyle()
        para.alignment = .center
        // The panel is transparent: give the text a soft backing so it reads on any desktop.
        let fs = fontSize
        let t = NSAttributedString(string: title, attributes: [.font: UIFonts.emptyTitle(fs),
                                                               .foregroundColor: main.withAlphaComponent(0.85), .paragraphStyle: para])
        let s = NSAttributedString(string: subtitle, attributes: [.font: UIFonts.caption(fs),
                                                                  .foregroundColor: main.withAlphaComponent(0.6), .paragraphStyle: para])
        let w = bounds.width - 24
        let th = ceil(t.boundingRect(with: NSSize(width: w, height: 100), options: .usesLineFragmentOrigin).height)
        let sh = subtitle.isEmpty ? 0 : ceil(s.boundingRect(with: NSSize(width: w, height: 100), options: .usesLineFragmentOrigin).height)
        let total = th + (sh > 0 ? sh + 4 : 0) + 24
        let box = NSRect(x: 0, y: 0, width: bounds.width, height: total)
        let bg = (colors?.folderRowBackground ?? .windowBackgroundColor).withAlphaComponent(0.85)
        bg.setFill()
        NSBezierPath(roundedRect: box, xRadius: 14, yRadius: 14).fill()
        t.draw(with: NSRect(x: 12, y: 12, width: w, height: th), options: .usesLineFragmentOrigin)
        if sh > 0 { s.draw(with: NSRect(x: 12, y: 12 + th + 4, width: w, height: sh), options: .usesLineFragmentOrigin) }
    }
}

/// Dashed outline shown while something from another app is dragged over the list background.
@MainActor
final class DropHintView: NSView {
    var colors: UIColors? { didSet { needsDisplay = true } }
    /// Theme font size (set by the owner).
    var fontSize: CGFloat = 14 { didSet { needsDisplay = true } }
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        guard let c = colors else { return }
        let r = bounds.insetBy(dx: 2, dy: 2)
        let p = NSBezierPath(roundedRect: r, xRadius: 16, yRadius: 16)
        c.accent.withAlphaComponent(0.10).setFill()
        p.fill()
        c.accent.setStroke()
        p.lineWidth = 2
        p.setLineDash([6, 5], count: 2, phase: 0)
        p.stroke()
        let label = NSAttributedString(string: "Drop to create a new note", attributes: [
            .font: UIFonts.caption(fontSize, weight: .semibold), .foregroundColor: c.isDark ? NSColor.black : NSColor.white,
        ])
        let s = label.size()
        let pill = NSRect(x: (bounds.width - s.width) / 2 - 12, y: 14, width: s.width + 24, height: s.height + 10)
        c.accent.setFill()
        NSBezierPath(roundedRect: pill, xRadius: pill.height / 2, yRadius: pill.height / 2).fill()
        label.draw(at: NSPoint(x: pill.minX + 12, y: pill.minY + 5))
    }
}
