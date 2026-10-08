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
    func cardExpandToggled(_ card: NoteCardView)
}

/// One note card: rounded background with a soft shadow, the hosted editor (or a preview), a pin
/// button, the footer, and the folded title row. The view is `Metrics.cardShadowPad` larger than the
/// card on every side so the drawn shadow is not clipped; `cardRect` is the visible card.
@MainActor
final class NoteCardView: NSView {
    private(set) var note: Note
    let env: AppEnvironment
    weak var delegate: NoteCardDelegate?

    private(set) var editor: (any NoteEditing)?
    private var preview: NotePreviewView?
    private let titleLabel = PassthroughLabel()
    private let badge = BadgeButton()
    private let pinButton = IconButton(symbol: "pin", size: 10.5, toolTip: "Pin")
    private let expandButton = IconButton(symbol: "arrow.up.left.and.arrow.down.right", size: 10.5, toolTip: "Expand Card (⇧⌘E)")
    /// For checks: the pin button frame, expand button frame, and the preview (when there is no live editor).
    var pinButtonFrame: NSRect { pinButton.frame }
    var expandButtonFrame: NSRect { expandButton.frame }
    var previewForChecks: NotePreviewView? { preview }
    /// Created on first hover / focus (keeps long lists light).
    private(set) var footer: CardActionsView?
    /// Date on the title line, left of the pin. Created and shown with `footer`.
    private var dateLabel: CardDateView?
    private var folderLabel: PassthroughLabel?
    private var folderIcon: NSImageView?
    /// Glass mode (`CardGlass`): the card background, and above it the left bar, hairline and rings.
    private var glass: NSGlassEffectView?
    private var chrome: CardChromeView?

    /// Search results are always shown expanded.
    var forceUnfolded = false { didSet { if oldValue != forceUnfolded { foldStateChanged() } } }
    var isExpanded = false { didSet { if oldValue != isExpanded { expandStateChanged() } } }
    /// Folder name shown above the text (search results across folders).
    var folderName: String? { didSet { if oldValue != folderName { updateFolderLabel() } } }
    /// Current search query (search results). Every result card marks its matches (see `highlightSearchMatch`).
    var searchQuery = ""
    /// The query whose marks are in this card's editor now ("" = none).
    private(set) var highlightedQuery = ""

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

    init(note: Note, env: AppEnvironment) {
        self.note = note
        self.env = env
        super.init(frame: NSRect(x: 0, y: 0, width: PanelSizing.defaultWidth, height: 80))
        titleLabel.font = titleFont
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
        expandButton.symbolWeight = .semibold
        expandButton.onClick = { [weak self] _ in
            guard let self else { return }
            self.delegate?.cardExpandToggled(self)
        }
        addSubview(expandButton)
        registerForDraggedTypes(PasteboardImport.attachmentTypes)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        refreshContent()
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    var cardRect: NSRect { bounds.insetBy(dx: Metrics.cardShadowPad, dy: Metrics.cardShadowPad) }
    /// The card title font: the same size and weight as the editor's title line, so the folded and the
    /// expanded title match.
    var titleFont: NSFont { UIFonts.title(env.themes.fontSize + 2) }
    /// For checks: the title label's frame in card coordinates.
    var titleFrameForChecks: NSRect { titleLabel.frame }
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
        dateLabel?.text = UIFormat.footerDate.string(from: newNote.updatedAt)
    }

    private func refreshContent() {
        refreshTitle()
        dateLabel?.text = UIFormat.footerDate.string(from: note.updatedAt)
        let pinned = note.isPinned
        pinButton.symbolName = pinned ? "pin.fill" : "pin"
        pinButton.toolTip = pinned ? "Unpin" : "Pin"
        pinButton.setAccessibilityLabel(pinned ? "Unpin note" : "Pin note")
        let sym = isExpanded ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right"
        let tip = isExpanded ? "Collapse Card (⇧⌘E)" : "Expand Card (⇧⌘E)"
        let label = isExpanded ? "Collapse note" : "Expand note"
        expandButton.symbolName = sym
        expandButton.toolTip = tip
        expandButton.setAccessibilityLabel(label)
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

    private func expandStateChanged() {
        let sym = isExpanded ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right"
        let tip = isExpanded ? "Collapse Card (⇧⌘E)" : "Expand Card (⇧⌘E)"
        let label = isExpanded ? "Collapse note" : "Expand note"
        expandButton.symbolName = sym
        expandButton.toolTip = tip
        expandButton.setAccessibilityLabel(label)
        restyle()
        updateChrome(animated: false)
        invalidateHeight()
        needsLayout = true
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
        // A search that is running marks the new editor too (cards whose editor loads later).
        if !isFolded, !highlightedQuery.isEmpty || !searchQuery.isEmpty {
            // The marks for the current query go into the new editor.
            highlightedQuery = ""
            highlightSearchMatch()
        }
        return true
    }

    /// Drops the editor (folder switch / memory). Not used while it has focus.
    func discardEditor() {
        guard let e = editor, !e.isEditingFocused else { return }
        e.removeFromSuperview()
        editor = nil
        highlightedQuery = ""
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

    /// `insert`: with vim keys on, start in Insert mode (else Normal mode).
    func focusEditor(atEnd: Bool, insert: Bool = false) {
        guard !isFolded else { return }
        if ensureEditor() { delegate?.cardNeedsLayout(self) }
        layoutSubtreeIfNeeded()
        editor?.focus(atEnd: atEnd, insertMode: insert)
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

    /// Marks every match of `searchQuery` in this card's editor, and clears the marks when the query is
    /// empty or the card is folded. Cards without an editor are marked when `ensureEditor` creates one,
    /// so a search does not create an editor for every result.
    func highlightSearchMatch() {
        let q = isFolded ? "" : searchQuery
        guard q != highlightedQuery else { return }
        highlightedQuery = q
        // No editor yet: `ensureEditor` applies `highlightedQuery` when it creates one.
        editor?.highlightSearch(q)
    }

    /// Scrolls to the first search match and shows the find indicator. Call only on the first result card.
    func revealFirstSearchMatch() {
        editor?.revealFirstSearchMatch()
    }

    // MARK: Measuring

    func invalidateHeight() {
        cachedContentHeight = nil
        cachedContentWidth = -1
        needsLayout = true
    }

    /// The text stops left of the pin / action column on the right edge.
    private func contentWidth(forCardWidth w: CGFloat) -> CGFloat {
        max(40, w - Metrics.cardPaddingX - Metrics.pinButtonInset - Metrics.pinButtonSize - Metrics.pinTextGap)
    }

    /// Room for the date at the end of the title line.
    private var dateReserve: CGFloat { CardDateView.reservedWidth(font: UIFonts.footer(env.themes.fontSize)) }

    // MARK: Pin corner

    /// The top-right part of the content area under the date (which is centered on the pin), in content
    /// coordinates. Text must not go there. Reserved for every card (not only hovered ones) so text
    /// does not reflow when the date appears. nil: the date sits above the text (folder row).
    private func pinCornerRect(contentWidth w: CGFloat) -> NSRect? {
        let minX = w - dateReserve - 6
        let dateBottom = Metrics.pinButtonInset + Metrics.pinButtonSize / 2 + 8
        let height = dateBottom - (Metrics.cardPaddingTop + folderRowHeight)
        guard minX > 40, height > 0 else { return nil }
        return NSRect(x: minX, y: 0, width: w - minX + 200, height: height)
    }

    /// Puts `rect` into the editor's text container as an exclusion path. The `NoteEditing` contract
    /// has no call for this, so it works on the editor's NSTextView directly (any editor built on
    /// one). Returns true if the paths changed and the editor must measure again.
    private func reservePinCorner(_ rect: NSRect?, in editor: NSView, contentWidth w: CGFloat) -> Bool {
        guard let tv = editor.firstDescendantTextView(), let tc = tv.textContainer else { return false }
        let paths = rect.map { [NSBezierPath(rect: $0)] } ?? []
        let current = tc.exclusionPaths.map(\.bounds)
        guard current != paths.map(\.bounds) else { return false }
        tc.exclusionPaths = paths
        // Editors that size their container themselves may cache the height per container width.
        // A different width makes their next layout drop that cache and measure again.
        if !tc.widthTracksTextView {
            tc.size = NSSize(width: tc.size.width + 1, height: tc.size.height)
        }
        return true
    }

    private func contentHeight(forWidth w: CGFloat) -> CGFloat {
        if let h = cachedContentHeight, cachedContentWidth == w { return h }
        var h: CGFloat
        let corner = pinCornerRect(contentWidth: w)
        if let editor {
            isMeasuring = true
            let cornerChanged = reservePinCorner(corner, in: editor, contentWidth: w)
            if editor.frame.width != w {
                editor.setFrameSize(NSSize(width: w, height: max(editor.frame.height, Metrics.minEditorHeight)))
                // Editors built on Auto Layout update their text container width in layout().
                editor.layoutSubtreeIfNeeded()
            } else if cornerChanged {
                editor.needsLayout = true
                editor.layoutSubtreeIfNeeded()
            }
            let ih = editor.intrinsicContentSize.height
            h = ih > 0 ? ceil(ih) : ceil(editor.fittingSize.height)
            isMeasuring = false
        } else {
            ensurePreview()
            preview?.firstLineExclusion = corner
            h = preview?.height(forWidth: w) ?? Metrics.minEditorHeight
        }
        h = max(h, Metrics.minEditorHeight)
        cachedContentHeight = h
        cachedContentWidth = w
        return h
    }

    private var folderRowHeight: CGFloat { folderName == nil ? 0 : 16 + 6 }

    static let minUnfoldedHeight: CGFloat = 6 + Metrics.pinButtonSize * 2 + 2 + 2
        + CardActionsView.minHeight + Metrics.actionColumnInsetBottom

    /// Height of the visible card (without the shadow pad) at the given card width.
    func cardHeight(forWidth w: CGFloat, minHeight: CGFloat = 0) -> CGFloat {
        var h = Metrics.cardPaddingTop + folderRowHeight
        if isFolded {
            h += Metrics.cardTitleRowHeight
        } else {
            h += contentHeight(forWidth: contentWidth(forCardWidth: w))
        }
        h = ceil(h + Metrics.cardPaddingBottom)
        let baseH = isFolded ? h : max(h, Self.minUnfoldedHeight)
        return isExpanded ? max(baseH, minHeight) : baseH
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
            let rowH = Metrics.cardTitleRowHeight
            // Expand button on the far right, pin button next to it.
            expandButton.frame = NSRect(x: cr.maxX - Metrics.pinButtonInset - pin, y: y + (rowH - pin) / 2, width: pin, height: pin)
            pinButton.frame = NSRect(x: expandButton.frame.minX - 4 - pin, y: y + (rowH - pin) / 2, width: pin, height: pin)
            badge.frame = NSRect(x: pinButton.frame.minX - 4 - bw, y: y + (rowH - 20) / 2, width: bw, height: 20)
            var right = badge.isHidden ? pinButton.frame.minX - 4 : badge.frame.minX - 6
            if let dateLabel {
                let dw = dateReserve
                dateLabel.frame = NSRect(x: right - dw, y: y + (rowH - 16) / 2, width: dw, height: 16)
                if footerVisible { right = dateLabel.frame.minX - 6 }
            }
            footer?.frame = .zero
            let th = ceil(titleLabel.intrinsicContentSize.height)
            titleLabel.frame = NSRect(x: cr.minX + px, y: y + (rowH - th) / 2, width: max(0, right - cr.minX - px), height: th)
            y += Metrics.cardTitleRowHeight
        } else {
            let w = contentWidth(forCardWidth: cr.width)
            let h = contentHeight(forWidth: w)
            let cardInnerH = cr.height - Metrics.cardPaddingTop - Metrics.cardPaddingBottom - folderRowHeight
            let contentH = max(h, cardInnerH)
            let r = NSRect(x: cr.minX + px, y: y, width: w, height: contentH)
            if let editor, editor.frame != r { editor.frame = r }
            if let preview, preview.frame != r { preview.frame = r }
            // Expansion button at the top-right corner where pin was:
            expandButton.frame = NSRect(x: cr.maxX - Metrics.pinButtonInset - pin, y: cr.minY + 6,
                                       width: pin, height: pin)
            // Pin button shifted below the expansion button, inline in the right action column:
            pinButton.frame = NSRect(x: expandButton.frame.minX, y: expandButton.frame.maxY + 2,
                                     width: pin, height: pin)
            let pf = pinButton.frame
            let top = pf.maxY + 2
            let cw = CardActionsView.width
            footer?.frame = NSRect(x: pf.midX - cw / 2, y: top, width: cw,
                                   height: max(0, cr.maxY - Metrics.actionColumnInsetBottom - top))
            if let dateLabel {
                // Centered on the expand button, ending where the text ends.
                let dw = dateReserve
                dateLabel.frame = NSRect(x: r.maxX - dw, y: expandButton.frame.midY - 8, width: dw, height: 16)
            }
            y += contentH
        }
        glass?.frame = cr
        chrome?.frame = bounds
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
        titleLabel.font = titleFont
        titleLabel.textColor = env.themes.cardTitle(note.color, appearance: a)
        let fs = env.themes.fontSize
        updateGlass()
        footer?.setFontSize(fs)
        badge.font = UIFonts.badge(fs)
        folderLabel?.font = UIFonts.small(fs)
        let tint = colored ? env.themes.cardTitle(note.color, appearance: a).withAlphaComponent(0.8) : c.secondaryText
        let pillFill = colored ? (c.isDark ? NSColor.white.withAlphaComponent(0.08) : NSColor.white.withAlphaComponent(0.5)) : c.hoverFill
        footer?.style(tint: tint, pillFill: pillFill, pillStroke: .clear, hoverFill: c.hoverFill, pressedFill: c.pressedFill)
        dateLabel?.color = tint
        dateLabel?.font = UIFonts.footer(fs)
        badge.textColor = colored ? env.themes.cardTitle(note.color, appearance: a) : c.secondaryText
        badge.fill = pillFill
        badge.hoverFill = c.hoverFill
        pinButton.tint = note.isPinned ? (colored ? env.themes.cardTitle(note.color, appearance: a) : c.accent) : tint
        pinButton.restingFill = note.isPinned ? nil : pillFill
        pinButton.hoverFill = c.hoverFill
        pinButton.pressedFill = c.pressedFill
        expandButton.tint = isExpanded ? (colored ? env.themes.cardTitle(note.color, appearance: a) : c.accent) : tint
        expandButton.restingFill = isExpanded ? nil : pillFill
        expandButton.hoverFill = c.hoverFill
        expandButton.pressedFill = c.pressedFill
        folderLabel?.textColor = c.secondaryText
        folderIcon?.contentTintColor = c.secondaryText
        if let preview { preview.configure(note: note, env: env, appearance: a) }
        needsDisplay = true
    }

    private func updateGlass() {
        CardGlass.sync(&glass, in: self, enabled: CardGlass.isEnabled(env))
        if let glass {
            glass.cornerRadius = env.themes.cornerRadius
            glass.tintColor = CardGlass.tint(backgroundColor, dark: effectiveAppearance.isDark)
            glass.frame = cardRect
            if chrome == nil {
                let v = CardChromeView(frame: bounds)
                v.card = self
                addSubview(v, positioned: .above, relativeTo: glass)
                chrome = v
            }
        } else {
            chrome?.removeFromSuperview()
            chrome = nil
        }
    }

    override var needsDisplay: Bool {
        didSet { if needsDisplay { chrome?.needsDisplay = true } }
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
        let show = footerVisible
        let target: CGFloat = show ? 1 : 0
        let footer: CardActionsView
        if let existing = self.footer { footer = existing } else if show { footer = makeFooter() } else {
            pinButton.isHidden = !(hovering || note.isPinned || menuOpen)
            expandButton.isHidden = isFolded && !(hovering || isExpanded || menuOpen)
            badge.isHidden = !isFolded || note.linesAfterTitle == 0
            return
        }
        if footer.alphaValue != target {
            if animated && NoteBarUIOptions.animations {
                if show { footer.isHidden = false; dateLabel?.isHidden = false }
                NSAnimationContext.runAnimationGroup({ ctx in
                    ctx.duration = show ? 0.12 : 0.2
                    footer.animator().alphaValue = target
                    dateLabel?.animator().alphaValue = target
                }, completionHandler: {
                    MainActor.assumeIsolated {
                        if !self.footerVisible { self.footer?.isHidden = true; self.dateLabel?.isHidden = true }
                    }
                })
            } else {
                footer.alphaValue = target
                footer.isHidden = !show
                dateLabel?.alphaValue = target
                dateLabel?.isHidden = !show
            }
            if isFolded { needsLayout = true }
        } else {
            footer.isHidden = !show
            dateLabel?.isHidden = !show
        }
        let pinWasHidden = pinButton.isHidden
        pinButton.isHidden = !(hovering || note.isPinned || menuOpen)
        expandButton.isHidden = isFolded && !(hovering || isExpanded || menuOpen)
        badge.isHidden = !isFolded || note.linesAfterTitle == 0
        if pinWasHidden != pinButton.isHidden, isFolded { needsLayout = true }
    }

    /// Forces the hover chrome on/off (snapshots).
    func setHoveredForSnapshot(_ on: Bool) { hovering = on }

    private func updateFolderLabel() {
        if let name = folderName {
            if folderLabel == nil {
                let l = PassthroughLabel()
                l.font = UIFonts.small(env.themes.fontSize)
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
        // Glass mode: the glass is the background; `chrome` draws the decorations above it.
        guard glass == nil else { return }
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
        drawDecorations()
    }

    /// Left color bar, hairline, selection and drop rings (card coordinates).
    fileprivate func drawDecorations() {
        let a = effectiveAppearance
        let c = env.themes.ui(a)
        let cr = cardRect
        let radius = env.themes.cornerRadius
        let path = NSBezierPath(roundedRect: cr, xRadius: radius, yRadius: radius)
        if colorStyle == .leftBar, note.color != .none {
            NSGraphicsContext.saveGraphicsState()
            path.addClip()
            env.themes.barColor(note.color, appearance: a).setFill()
            NSRect(x: cr.minX, y: cr.minY, width: Metrics.leftBarWidth, height: cr.height).fill()
            NSGraphicsContext.restoreGraphicsState()
        }
        if glass == nil {
            // Glass has its own edge highlight.
            c.hairline.setStroke()
            path.lineWidth = 1
            path.stroke()
        }

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

    private func makeFooter() -> CardActionsView {
        let d = CardDateView()
        d.alphaValue = 0
        d.isHidden = true
        d.text = UIFormat.footerDate.string(from: note.updatedAt)
        addSubview(d)
        dateLabel = d
        let f = CardActionsView()
        f.alphaValue = 0
        f.isHidden = true
        addSubview(f)
        footer = f
        wireFooter(f)
        restyle()
        needsLayout = true
        layoutSubtreeIfNeeded()
        return f
    }

    private func wireFooter(_ footer: CardActionsView) {
        footer.moreButton.onClick = { [weak self] b in
            guard let self, let footer = self.footer else { return }
            self.popUp(self.moreMenu(footer.hiddenActions), from: b)
        }
        footer.formatButton.onClick = { [weak self] b in
            guard let self else { return }
            let menu = MenuBuilder.formatMenu { [weak self] action in self?.performFormat(action) }
            self.popUp(menu, from: b)
        }
        footer.copyButton.onClick = { [weak self] _ in
            guard let self, let actions = self.delegate?.actions else { return }
            actions.copyText(self.note.id)
        }
        footer.gearButton.onClick = { [weak self] b in
            guard let self, let actions = self.delegate?.actions else { return }
            self.popUp(MenuBuilder.gearMenu(for: self.currentNote, actions: actions), from: b)
        }
        footer.trashButton.onClick = { [weak self] _ in
            guard let self, let actions = self.delegate?.actions else { return }
            actions.delete(self.note.id, confirm: false)
        }
    }

    /// "…" menu: the actions that do not fit in the column of a short card.
    private func moreMenu(_ hidden: [CardActionsView.Action]) -> NSMenu {
        let m = NSMenu()
        m.autoenablesItems = false
        for action in hidden {
            switch action {
            case .format:
                let item = NSMenuItem(title: "Format", action: nil, keyEquivalent: "")
                item.image = Symbols.image("textformat", size: 13)
                item.submenu = MenuBuilder.formatMenu { [weak self] a in self?.performFormat(a) }
                m.addItem(item)
            case .copy:
                m.addItem(ClosureMenuItem("Copy Note Text", key: "", symbol: "doc.on.doc") { [weak self] in
                    guard let self else { return }
                    self.delegate?.actions.copyText(self.note.id)
                })
            case .colorAndMode:
                guard let actions = delegate?.actions else { continue }
                let item = NSMenuItem(title: "Color & Mode", action: nil, keyEquivalent: "")
                item.image = Symbols.image("gearshape", size: 13)
                item.submenu = MenuBuilder.gearMenu(for: currentNote, actions: actions)
                m.addItem(item)
            case .delete:
                m.addItem(.separator())
                m.addItem(ClosureMenuItem("Delete Note", key: "", symbol: "trash") { [weak self] in
                    guard let self else { return }
                    self.delegate?.actions.delete(self.note.id, confirm: false)
                })
            }
        }
        return m
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
        return PasteboardImport.receive(from: sender.draggingPasteboard) { [weak self] payload in
            guard let self else { return }
            _ = self.delegate?.card(self, drop: payload)
        }
    }
}

extension NSView {
    /// The first NSTextView in this view's subtree (breadth-first), or self.
    func firstDescendantTextView() -> NSTextView? {
        if let tv = self as? NSTextView { return tv }
        var queue = subviews
        while !queue.isEmpty {
            let v = queue.removeFirst()
            if let tv = v as? NSTextView { return tv }
            queue.append(contentsOf: v.subviews)
        }
        return nil
    }
}

/// Glass mode: draws the card's decorations just above its glass background. Never takes clicks.
private final class CardChromeView: NSView {
    weak var card: NoteCardView?
    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) { card?.drawDecorations() }
}

