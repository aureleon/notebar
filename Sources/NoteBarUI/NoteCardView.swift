import AppKit
import NoteBarCore

@MainActor
protocol NoteCardDelegate: AnyObject {
    var actions: NoteActions { get }
    /// The card's height changed (editor grew, fold toggled...).
    func cardNeedsLayout(_ card: NoteCardView)
    func card(_ card: NoteCardView, editorEvent event: EditorEvent)
    func card(_ card: NoteCardView, editorFocusChanged focused: Bool)
    func cardBeginDrag(_ card: NoteCardView, event: NSEvent)
    /// Click on the card chrome (not inside the text).
    func cardClicked(_ card: NoteCardView, event: NSEvent)
    func cardMenu(_ card: NoteCardView) -> NSMenu?
    func card(_ card: NoteCardView, drop payload: ImportPayload) -> Bool
}

/// One note card: rounded background with a soft shadow, the hosted editor (or a preview), a pin
/// button, the footer, and the folded title row. The view is `Metrics.cardShadowPad` larger than the
/// card on every side so the drawn shadow is not clipped; `cardRect` is the visible card.
@MainActor
final class NoteCardView: NSView {
    private(set) var note: Note
    let env: AppEnvironment
    weak var delegate: NoteCardDelegate?
    /// Export rendering: no footer, no hover chrome.
    let isExport: Bool

    private(set) var editor: (any NoteEditing)?
    private var preview: NotePreviewView?
    private let titleLabel = PassthroughLabel()
    private let badge = BadgeButton()
    private let pinButton = IconButton(symbol: "pin", size: 10.5, toolTip: "Pin")
    /// Created on first hover / focus (keeps long lists light).
    private(set) var footer: CardFooterView?
    private var folderLabel: PassthroughLabel?
    private var folderIcon: NSImageView?

    /// Search results are always shown expanded.
    var forceUnfolded = false { didSet { if oldValue != forceUnfolded { foldStateChanged() } } }
    /// Folder name shown above the text (search results across folders).
    var folderName: String? { didSet { if oldValue != folderName { updateFolderLabel() } } }
    /// Current search query (search results). Highlighting is requested by the list for one card at a
    /// time, because `highlightSearch` also scrolls the match into view.
    var searchQuery = ""

    var isSelected = false { didSet { if oldValue != isSelected { needsDisplay = true; updateChrome(animated: true) } } }
    var isDropTarget = false { didSet { if oldValue != isDropTarget { needsDisplay = true } } }
    var isDragSource = false { didSet { alphaValue = isDragSource ? 0.35 : 1 } }
    private(set) var isEditorFocused = false
    private var hovering = false { didSet { if oldValue != hovering { updateChrome(animated: true) } } }
    private var menuOpen = false { didSet { updateChrome(animated: false) } }
    private var tracking: NSTrackingArea?
    private var mouseDownEvent: NSEvent?
    private var didStartDrag = false

    private var cachedContentHeight: CGFloat?
    private var cachedContentWidth: CGFloat = -1
    private var isMeasuring = false
    private var layoutChangeScheduled = false

    init(note: Note, env: AppEnvironment, isExport: Bool = false) {
        self.note = note
        self.env = env
        self.isExport = isExport
        super.init(frame: NSRect(x: 0, y: 0, width: 290, height: 80))
        titleLabel.font = UIFonts.title(env.themes.fontSize)
        addSubview(titleLabel)
        badge.onClick = { [weak self] in
            guard let self else { return }
            self.delegate?.actions.setFolded(false, id: self.note.id)
        }
        addSubview(badge)
        pinButton.symbolWeight = .semibold
        pinButton.onClick = { [weak self] _ in
            guard let self else { return }
            self.delegate?.actions.togglePin(self.note.id)
        }
        addSubview(pinButton)
        if !isExport {
            registerForDraggedTypes(PasteboardImport.attachmentTypes)
        }
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        refreshContent()
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    var cardRect: NSRect { bounds.insetBy(dx: Metrics.cardShadowPad, dy: Metrics.cardShadowPad) }
    var isFolded: Bool { note.isFolded && !forceUnfolded }
    var hasEditor: Bool { editor != nil }

    // MARK: Model updates

    /// Metadata change (color, mode, fold, pin, or body changed elsewhere).
    func update(note newNote: Note) {
        let foldChanged = newNote.isFolded != note.isFolded
        let bodyChanged = newNote.body != note.body
        let modeChanged = newNote.mode != note.mode
        note = newNote
        editor?.apply(note: newNote)
        if bodyChanged || modeChanged { invalidateHeight() }
        refreshContent()
        if foldChanged { foldStateChanged() }
        needsDisplay = true
    }

    /// Body typed in this card's editor (or updated elsewhere without metadata). Never touches the editor.
    func bodyDidChange(_ newNote: Note) {
        let wasBody = note.body
        note = newNote
        if editor == nil, wasBody != newNote.body {
            invalidateHeight()
            preview?.configure(note: newNote, env: env, appearance: effectiveAppearance)
            delegate?.cardNeedsLayout(self)
        }
        refreshTitle()
        footer?.date = newNote.updatedAt
    }

    private func refreshContent() {
        refreshTitle()
        footer?.date = note.updatedAt
        let pinned = note.isPinned
        pinButton.symbolName = pinned ? "pin.fill" : "pin"
        pinButton.toolTip = pinned ? "Unpin" : "Pin"
        pinButton.setAccessibilityLabel(pinned ? "Unpin note" : "Pin note")
        badge.text = UIFormat.linesBadge(note.linesAfterTitle)
        restyle()
        updateChrome(animated: false)
        setAccessibilityLabel("Note: \(note.title.isEmpty ? "Untitled" : note.title)\(pinned ? ", pinned" : "")\(isFolded ? ", folded" : "")")
    }

    private func refreshTitle() {
        let t = note.title
        titleLabel.stringValue = t.isEmpty ? "Untitled" : t
        let lines = UIFormat.linesBadge(note.linesAfterTitle)
        if badge.text != lines { badge.text = lines; needsLayout = true }
        badge.isHidden = !isFolded || note.linesAfterTitle == 0
        titleLabel.isHidden = !isFolded
    }

    private func foldStateChanged() {
        invalidateHeight()
        if isFolded {
            // Folding the note being edited: hand keyboard focus back to the list.
            if let editor, editor.isEditingFocused { delegate?.card(self, editorEvent: .escape) }
            editor?.isHidden = true
            preview?.isHidden = true
        } else {
            editor?.isHidden = false
            preview?.isHidden = false
            if editor == nil { ensurePreview() }
        }
        titleLabel.isHidden = !isFolded
        refreshTitle()
        restyle()
        updateChrome(animated: false)
        needsLayout = true
        delegate?.cardNeedsLayout(self)
    }

    // MARK: Editor / preview

    /// Creates the live editor (idempotent). Returns true if it was created now.
    @discardableResult
    func ensureEditor() -> Bool {
        guard editor == nil else { return false }
        let e = env.editorFactory.makeEditor(for: note, env: env)
        e.onBodyChange = { [weak self] body in
            guard let self else { return }
            self.env.store.updateNoteBody(id: self.note.id, body: body)
        }
        e.onLayoutChange = { [weak self] in self?.editorLayoutChanged() }
        e.onFocusChange = { [weak self] focused in self?.editorFocusChanged(focused) }
        e.onEvent = { [weak self] event in
            guard let self else { return }
            self.delegate?.card(self, editorEvent: event)
        }
        e.translatesAutoresizingMaskIntoConstraints = true
        e.isHidden = isFolded
        addSubview(e, positioned: .below, relativeTo: pinButton)
        editor = e
        // Re-apply now that the editor inherits the card's appearance.
        e.apply(note: note)
        preview?.removeFromSuperview()
        preview = nil
        invalidateHeight()
        return true
    }

    /// Drops the editor (folder switch / memory). Not used while it has focus.
    func discardEditor() {
        guard let e = editor, !e.isEditingFocused else { return }
        e.removeFromSuperview()
        editor = nil
        invalidateHeight()
        if !isFolded { ensurePreview() }
    }

    func ensurePreview() {
        guard editor == nil, preview == nil else { return }
        let p = NotePreviewView()
        p.configure(note: note, env: env, appearance: effectiveAppearance)
        p.isHidden = isFolded
        addSubview(p, positioned: .below, relativeTo: pinButton)
        preview = p
        invalidateHeight()
    }

    func focusEditor(atEnd: Bool) {
        guard !isFolded else { return }
        if ensureEditor() { delegate?.cardNeedsLayout(self) }
        layoutSubtreeIfNeeded()
        editor?.focus(atEnd: atEnd)
    }

    private func editorLayoutChanged() {
        if isMeasuring {
            // Reported while we measure: re-check once afterwards.
            guard !layoutChangeScheduled else { return }
            layoutChangeScheduled = true
            DispatchQueue.main.async { [weak self] in
                self?.layoutChangeScheduled = false
                self?.editorLayoutChanged()
            }
            return
        }
        let old = cachedContentHeight
        invalidateHeight()
        let new = contentHeight(forWidth: contentWidth(forCardWidth: cardRect.width))
        if old != new { delegate?.cardNeedsLayout(self) }
    }

    private func editorFocusChanged(_ focused: Bool) {
        isEditorFocused = focused
        updateChrome(animated: true)
        needsDisplay = true
        delegate?.card(self, editorFocusChanged: focused)
    }

    /// Asks the editor to mark the first match of `searchQuery`.
    func highlightSearchMatch() {
        guard !searchQuery.isEmpty, !isFolded else { return }
        if ensureEditor() { delegate?.cardNeedsLayout(self) }
        editor?.highlightSearch(searchQuery)
    }

    // MARK: Measuring

    func invalidateHeight() {
        cachedContentHeight = nil
        cachedContentWidth = -1
        needsLayout = true
    }

    private func contentWidth(forCardWidth w: CGFloat) -> CGFloat { max(40, w - 2 * Metrics.cardPaddingX) }

    private func contentHeight(forWidth w: CGFloat) -> CGFloat {
        if let h = cachedContentHeight, cachedContentWidth == w { return h }
        var h: CGFloat
        if let editor {
            isMeasuring = true
            if editor.frame.width != w {
                editor.setFrameSize(NSSize(width: w, height: max(editor.frame.height, Metrics.minEditorHeight)))
                // Editors built on Auto Layout update their text container width in layout().
                editor.layoutSubtreeIfNeeded()
            }
            let ih = editor.intrinsicContentSize.height
            h = ih > 0 ? ceil(ih) : ceil(editor.fittingSize.height)
            isMeasuring = false
        } else {
            ensurePreview()
            h = preview?.height(forWidth: w) ?? Metrics.minEditorHeight
        }
        h = max(h, Metrics.minEditorHeight)
        cachedContentHeight = h
        cachedContentWidth = w
        return h
    }

    private var folderRowHeight: CGFloat { folderName == nil ? 0 : 16 + 6 }

    private var footerBlockHeight: CGFloat {
        isExport ? Metrics.cardPaddingTop : Metrics.footerGap + Metrics.footerHeight + Metrics.footerInsetBottom
    }

    /// Height of the visible card (without the shadow pad) at the given card width.
    func cardHeight(forWidth w: CGFloat) -> CGFloat {
        var h = Metrics.cardPaddingTop + folderRowHeight
        if isFolded {
            h += Metrics.cardTitleRowHeight
        } else {
            h += contentHeight(forWidth: contentWidth(forCardWidth: w))
        }
        return ceil(h + footerBlockHeight)
    }

    // MARK: Layout

    override func layout() {
        super.layout()
        let cr = cardRect
        let px = Metrics.cardPaddingX
        var y = cr.minY + Metrics.cardPaddingTop
        if let folderLabel, let folderIcon {
            folderIcon.frame = NSRect(x: cr.minX + px - 1, y: y, width: 14, height: 14)
            folderLabel.frame = NSRect(x: cr.minX + px + 16, y: y - 0.5, width: max(0, cr.width - 2 * px - 16 - 24), height: 15)
            y += folderRowHeight
        }
        let pin = Metrics.pinButtonSize
        if isFolded {
            let bw = badge.isHidden ? 0 : badge.intrinsicContentSize.width
            badge.frame = NSRect(x: cr.maxX - px + 4 - bw, y: y, width: bw, height: 20)
            let pinX = (badge.isHidden ? cr.maxX - px + 4 : badge.frame.minX - 4) - pin
            pinButton.frame = NSRect(x: pinX, y: y - 1, width: pin, height: pin)
            let right = pinButton.isHidden ? (badge.isHidden ? cr.maxX - px : badge.frame.minX - 6) : pinButton.frame.minX - 4
            let th = ceil(titleLabel.intrinsicContentSize.height)
            titleLabel.frame = NSRect(x: cr.minX + px, y: y + (Metrics.cardTitleRowHeight - th) / 2, width: max(0, right - cr.minX - px), height: th)
            y += Metrics.cardTitleRowHeight
        } else {
            let w = contentWidth(forCardWidth: cr.width)
            let h = contentHeight(forWidth: w)
            let r = NSRect(x: cr.minX + px, y: y, width: w, height: h)
            if let editor, editor.frame != r { editor.frame = r }
            if let preview, preview.frame != r { preview.frame = r }
            pinButton.frame = NSRect(x: cr.maxX - 8 - pin, y: cr.minY + 8, width: pin, height: pin)
            y += h
        }
        if let footer {
            footer.frame = NSRect(x: cr.minX + Metrics.footerInsetX, y: y + Metrics.footerGap,
                                  width: max(0, cr.width - 2 * Metrics.footerInsetX), height: Metrics.footerHeight)
        }
    }

    // MARK: Style

    var colorStyle: CardColorStyle { env.settings.colorStyle }

    var backgroundColor: NSColor {
        env.themes.cardBackground(colorStyle == .background ? note.color : .none, appearance: effectiveAppearance)
    }

    func restyle() {
        let a = effectiveAppearance
        let c = env.themes.ui(a)
        let colored = colorStyle == .background && note.color != .none
        titleLabel.font = UIFonts.title(env.themes.fontSize)
        titleLabel.textColor = env.themes.cardTitle(note.color, appearance: a)
        let tint = colored ? env.themes.cardTitle(note.color, appearance: a).withAlphaComponent(0.8) : c.secondaryText
        let pillFill = colored ? (c.isDark ? NSColor.white.withAlphaComponent(0.08) : NSColor.white.withAlphaComponent(0.5)) : c.hoverFill
        footer?.style(tint: tint, pillFill: pillFill, pillStroke: .clear, hoverFill: c.hoverFill, pressedFill: c.pressedFill,
                      dateColor: tint)
        badge.textColor = colored ? env.themes.cardTitle(note.color, appearance: a) : c.secondaryText
        badge.fill = pillFill
        badge.hoverFill = c.hoverFill
        pinButton.tint = note.isPinned ? (colored ? env.themes.cardTitle(note.color, appearance: a) : c.accent) : tint
        pinButton.restingFill = note.isPinned ? nil : pillFill
        pinButton.hoverFill = c.hoverFill
        pinButton.pressedFill = c.pressedFill
        folderLabel?.textColor = c.secondaryText
        folderIcon?.contentTintColor = c.secondaryText
        if let preview { preview.configure(note: note, env: env, appearance: a) }
        needsDisplay = true
    }

    /// Theme / appearance / color style changed.
    func themeDidChange() {
        invalidateHeight()
        editor?.apply(note: currentNote)
        restyle()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        restyle()
        // Editors resolve theme colors from their own effectiveAppearance, which is updated after the
        // card's: re-apply on the next turn.
        DispatchQueue.main.async { [weak self] in
            guard let self, let editor = self.editor else { return }
            editor.apply(note: self.currentNote)
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { editor?.apply(note: currentNote) }
    }

    private var footerVisible: Bool { hovering || isEditorFocused || isSelected || menuOpen }

    private func updateChrome(animated: Bool) {
        guard !isExport else {
            pinButton.isHidden = !note.isPinned
            badge.isHidden = !isFolded || note.linesAfterTitle == 0
            return
        }
        let show = footerVisible
        let target: CGFloat = show ? 1 : 0
        let footer: CardFooterView
        if let existing = self.footer { footer = existing } else if show { footer = makeFooter() } else {
            pinButton.isHidden = !(hovering || note.isPinned || menuOpen)
            badge.isHidden = !isFolded || note.linesAfterTitle == 0
            return
        }
        if footer.alphaValue != target {
            if animated && NoteBarUIOptions.animations {
                if show { footer.isHidden = false }
                NSAnimationContext.runAnimationGroup({ ctx in
                    ctx.duration = show ? 0.12 : 0.2
                    footer.animator().alphaValue = target
                }, completionHandler: {
                    MainActor.assumeIsolated { if !self.footerVisible { self.footer?.isHidden = true } }
                })
            } else {
                footer.alphaValue = target
                footer.isHidden = !show
            }
        } else {
            footer.isHidden = !show
        }
        let pinWasHidden = pinButton.isHidden
        pinButton.isHidden = !(hovering || note.isPinned || menuOpen)
        badge.isHidden = !isFolded || note.linesAfterTitle == 0
        if pinWasHidden != pinButton.isHidden, isFolded { needsLayout = true }
    }

    /// Forces the hover chrome on/off (snapshots).
    func setHoveredForSnapshot(_ on: Bool) { hovering = on }

    private func updateFolderLabel() {
        if let name = folderName {
            if folderLabel == nil {
                let l = PassthroughLabel()
                l.font = UIFonts.small
                let icon = NSImageView()
                icon.image = Symbols.image("folder", size: 10, weight: .medium)
                icon.imageScaling = .scaleProportionallyDown
                icon.unregisterDraggedTypes()
                addSubview(l)
                addSubview(icon)
                folderLabel = l
                folderIcon = icon
            }
            folderLabel?.stringValue = name
        } else {
            folderLabel?.removeFromSuperview(); folderLabel = nil
            folderIcon?.removeFromSuperview(); folderIcon = nil
        }
        restyle()
        needsLayout = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let a = effectiveAppearance
        let c = env.themes.ui(a)
        let cr = cardRect
        let radius = env.themes.cornerRadius
        let path = NSBezierPath(roundedRect: cr, xRadius: radius, yRadius: radius)
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(CGFloat(c.shadowOpacity))
        shadow.shadowBlurRadius = 6
        shadow.shadowOffset = NSSize(width: 0, height: -1.5)
        shadow.set()
        backgroundColor.setFill()
        path.fill()
        NSGraphicsContext.restoreGraphicsState()

        if colorStyle == .leftBar, note.color != .none {
            NSGraphicsContext.saveGraphicsState()
            path.addClip()
            env.themes.barColor(note.color, appearance: a).setFill()
            NSRect(x: cr.minX, y: cr.minY, width: Metrics.leftBarWidth, height: cr.height).fill()
            NSGraphicsContext.restoreGraphicsState()
        }
        c.hairline.setStroke()
        path.lineWidth = 1
        path.stroke()

        if isSelected && !isEditorFocused {
            let ring = NSBezierPath(roundedRect: cr.insetBy(dx: 1, dy: 1), xRadius: radius - 1, yRadius: radius - 1)
            c.accent.withAlphaComponent(0.9).setStroke()
            ring.lineWidth = 2
            ring.stroke()
        }
        if isDropTarget {
            let ring = NSBezierPath(roundedRect: cr.insetBy(dx: 1.5, dy: 1.5), xRadius: radius - 1.5, yRadius: radius - 1.5)
            c.accent.withAlphaComponent(0.12).setFill()
            ring.fill()
            c.accent.setStroke()
            ring.lineWidth = 2
            ring.setLineDash([5, 4], count: 2, phase: 0)
            ring.stroke()
        }
    }

    // MARK: Hit testing / mouse

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        guard cardRect.contains(local) else { return nil }
        return super.hitTest(point)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        guard !isExport else { return }
        let t = NSTrackingArea(rect: cardRect, options: [.mouseEnteredAndExited, .activeAlways], owner: self)
        addTrackingArea(t)
        tracking = t
        if let w = window {
            let p = convert(w.mouseLocationOutsideOfEventStream, from: nil)
            hovering = cardRect.contains(p) && isMouseInsideVisibleArea(p)
        }
    }

    private func isMouseInsideVisibleArea(_ p: NSPoint) -> Bool { visibleRect.contains(p) }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }

    override func mouseDown(with event: NSEvent) {
        mouseDownEvent = event
        didStartDrag = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = mouseDownEvent, !didStartDrag else { return }
        let a = start.locationInWindow, b = event.locationInWindow
        if hypot(a.x - b.x, a.y - b.y) > 4 {
            didStartDrag = true
            delegate?.cardBeginDrag(self, event: start)
        }
    }

    override func mouseUp(with event: NSEvent) {
        defer { mouseDownEvent = nil }
        guard mouseDownEvent != nil, !didStartDrag else { return }
        if cardRect.contains(convert(event.locationInWindow, from: nil)) { delegate?.cardClicked(self, event: event) }
    }

    override func menu(for event: NSEvent) -> NSMenu? { delegate?.cardMenu(self) }

    /// Runs a menu below `view` while keeping the footer visible.
    func popUp(_ menu: NSMenu, from view: NSView) {
        menuOpen = true
        if let b = view as? IconButton { b.popUp(menu) } else {
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: view.bounds.maxY + 4), in: view)
        }
        menuOpen = false
        updateTrackingAreas()
    }

    override func rightMouseDown(with event: NSEvent) {
        guard let menu = delegate?.cardMenu(self) else { return super.rightMouseDown(with: event) }
        menuOpen = true
        NSMenu.popUpContextMenu(menu, with: event, for: self)
        menuOpen = false
        updateTrackingAreas()
    }

    // MARK: Footer

    private func makeFooter() -> CardFooterView {
        let f = CardFooterView()
        f.alphaValue = 0
        f.isHidden = true
        f.date = note.updatedAt
        addSubview(f)
        footer = f
        wireFooter(f)
        restyle()
        needsLayout = true
        layoutSubtreeIfNeeded()
        return f
    }

    private func wireFooter(_ footer: CardFooterView) {
        footer.formatButton.onClick = { [weak self] b in
            guard let self else { return }
            let menu = MenuBuilder.formatMenu { [weak self] action in self?.performFormat(action) }
            self.popUp(menu, from: b)
        }
        footer.shareButton.onClick = { [weak self] b in
            guard let self, let actions = self.delegate?.actions else { return }
            actions.share(self.note.id, from: b)
        }
        footer.gearButton.onClick = { [weak self] b in
            guard let self, let actions = self.delegate?.actions else { return }
            self.popUp(MenuBuilder.gearMenu(for: self.currentNote, actions: actions), from: b)
        }
        footer.exportButton.onClick = { [weak self] b in
            guard let self, let actions = self.delegate?.actions else { return }
            self.popUp(MenuBuilder.exportMenu(for: self.currentNote, actions: actions), from: b)
        }
        footer.trashButton.onClick = { [weak self] _ in
            guard let self, let actions = self.delegate?.actions else { return }
            actions.delete(self.note.id, confirm: false)
        }
    }

    /// The freshest copy of the note (the store may be ahead of `note` while typing).
    var currentNote: Note { env.store.note(id: note.id) ?? note }

    func performFormat(_ action: FormatAction) {
        guard !isFolded else { return }
        if ensureEditor() { delegate?.cardNeedsLayout(self) }
        guard let editor else { return }
        if !editor.isEditingFocused, action != .copy { editor.focus(atEnd: true) }
        editor.perform(action)
    }

    // MARK: Drops (file / image / text on the card chrome)

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { draggingUpdated(sender) }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        let pb = sender.draggingPasteboard
        guard !PasteboardImport.hasInternalNote(pb), !PasteboardImport.hasInternalFolder(pb),
              PasteboardImport.canImport(pb) else { isDropTarget = false; return [] }
        isDropTarget = true
        return .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) { isDropTarget = false }
    override func draggingEnded(_ sender: NSDraggingInfo) { isDropTarget = false }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        isDropTarget = false
        guard let payload = PasteboardImport.payload(from: sender.draggingPasteboard) else { return false }
        return delegate?.card(self, drop: payload) ?? false
    }
}
