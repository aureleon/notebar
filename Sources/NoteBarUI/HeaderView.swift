import AppKit
import NoteBarCore

/// The rounded header pill: back chevron, title, search, +. In search mode: search field + close button.
@MainActor
final class HeaderView: NSView, NSSearchFieldDelegate {
    /// Room around the pill for its drawn shadow. The pill itself is `pillRect`.
    static let shadowPad: CGFloat = 6

    var onBack: (() -> Void)?
    var onSearch: (() -> Void)?
    var onPlus: (() -> Void)?
    var onQueryChange: ((String) -> Void)?
    /// Escape in the search field. Return true if handled.
    var onSearchEscape: (() -> Void)?
    var onSearchMoveDown: (() -> Void)?
    var onSearchSubmit: (() -> Void)?
    var onCloseSearch: (() -> Void)?
    /// A note is dragged over the back button long enough (spring loading).
    var onSpringBack: (() -> Void)?

    private let env: AppEnvironment
    private var glass: NSGlassEffectView?
    private let content = FlippedView()
    let backButton = IconButton(symbol: "chevron.left", size: 13, toolTip: "Back (⌘[)")
    let searchButton = IconButton(symbol: "magnifyingglass", size: 12.5, toolTip: "Search (⌘F)")
    let plusButton = IconButton(symbol: "plus", size: 13, toolTip: "New Note (⌘N)")
    private let closeSearchButton = IconButton(symbol: "xmark", size: 11, toolTip: "Close Search (Esc)")
    private let titleLabel = PassthroughLabel()
    let searchField = HeaderSearchField()

    private(set) var isSearching = false
    private var showsBack = false
    private var title = "NoteBar"
    private var titleIsAccent = false
    private var springTimer: Timer?

    init(env: AppEnvironment) {
        self.env = env
        super.init(frame: NSRect(x: 0, y: 0, width: PanelSizing.defaultWidth, height: Metrics.headerHeight + 2 * Self.shadowPad))
        if NoteBarUIOptions.useGlass {
            let g = NSGlassEffectView()
            g.cornerRadius = Metrics.headerCornerRadius
            g.contentView = content
            addSubview(g)
            glass = g
        } else {
            addSubview(content)
        }
        titleLabel.font = UIFonts.headerTitle(env.themes.fontSize)
        titleLabel.lineBreakMode = .byTruncatingTail
        for b in [backButton, searchButton, plusButton, closeSearchButton] {
            b.symbolWeight = .semibold
            content.addSubview(b)
        }
        content.addSubview(titleLabel)
        content.addSubview(searchField)
        searchField.placeholderString = "Search"
        searchField.font = UIFonts.headerSearch(env.themes.fontSize)
        searchField.focusRingType = .none
        searchField.delegate = self
        searchField.sendsSearchStringImmediately = true
        searchField.sendsWholeSearchString = false
        searchField.isHidden = true
        searchField.target = self
        searchField.action = #selector(searchFieldAction(_:))
        closeSearchButton.isHidden = true
        backButton.onClick = { [weak self] _ in self?.onBack?() }
        searchButton.onClick = { [weak self] _ in self?.onSearch?() }
        plusButton.onClick = { [weak self] _ in self?.onPlus?() }
        closeSearchButton.onClick = { [weak self] _ in self?.onCloseSearch?() }
        registerForDraggedTypes([.noteBarNoteID])
        setAccessibilityRole(.toolbar)
        setAccessibilityLabel("NoteBar header")
        update()
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    var pillRect: NSRect { bounds.insetBy(dx: Self.shadowPad, dy: Self.shadowPad) }

    // MARK: State

    func setTitle(_ title: String, accent: Bool, showsBack: Bool, plusToolTip: String) {
        self.title = title
        self.titleIsAccent = accent
        self.showsBack = showsBack
        plusButton.toolTip = plusToolTip
        plusButton.setAccessibilityLabel(plusToolTip)
        update()
    }

    func setSearching(_ on: Bool, query: String = "") {
        isSearching = on
        if on, searchField.stringValue != query { searchField.stringValue = query }
        if !on { searchField.stringValue = "" }
        update()
    }

    var query: String { searchField.stringValue }

    func focusSearchField() {
        guard isSearching else { return }
        window?.makeFirstResponder(searchField)
        searchField.currentEditor()?.selectAll(nil)
    }

    var isSearchFieldFocused: Bool {
        guard let fr = window?.firstResponder as? NSView else { return false }
        return searchField.containsDescendant(fr) || (fr as? NSText)?.delegate === searchField
    }

    private func update() {
        titleLabel.stringValue = title
        titleLabel.isHidden = isSearching
        backButton.isHidden = isSearching || !showsBack
        searchButton.isHidden = isSearching
        plusButton.isHidden = isSearching
        searchField.isHidden = !isSearching
        closeSearchButton.isHidden = !isSearching
        restyle()
        needsLayout = true
    }

    func restyle() {
        let c = env.themes.ui(effectiveAppearance)
        titleLabel.font = UIFonts.headerTitle(env.themes.fontSize)
        searchField.font = UIFonts.headerSearch(env.themes.fontSize)
        titleLabel.textColor = titleIsAccent ? c.accent : c.text
        for b in [backButton, searchButton, plusButton, closeSearchButton] {
            b.onTint = c.accent
            b.tint = c.text.withAlphaComponent(0.85)
            b.restingFill = c.headerButtonFill
            b.hoverFill = c.hoverFill
            b.pressedFill = c.pressedFill
        }
        glass?.tintColor = c.isDark ? NSColor.black.withAlphaComponent(0.12) : NSColor.white.withAlphaComponent(0.25)
        needsDisplay = true
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        restyle()
    }

    // MARK: Layout / drawing

    override func layout() {
        super.layout()
        let pill = pillRect
        if let glass { glass.frame = pill; content.frame = glass.bounds } else { content.frame = pill }
        let w = pill.width, h = pill.height
        let s = Metrics.headerButtonSize
        let y = (h - s) / 2
        backButton.frame = NSRect(x: 8, y: y, width: s, height: s)
        plusButton.frame = NSRect(x: w - 8 - s, y: y, width: s, height: s)
        searchButton.frame = NSRect(x: plusButton.frame.minX - 6 - s, y: y, width: s, height: s)
        let titleX: CGFloat = showsBack ? backButton.frame.maxX + 8 : 16
        let th = ceil(titleLabel.intrinsicContentSize.height)
        titleLabel.frame = NSRect(x: titleX, y: (h - th) / 2, width: max(0, searchButton.frame.minX - 8 - titleX), height: th)
        closeSearchButton.frame = NSRect(x: w - 8 - s, y: y, width: s, height: s)
        let fh: CGFloat = min(28, h - 12)
        searchField.frame = NSRect(x: 10, y: (h - fh) / 2, width: max(40, closeSearchButton.frame.minX - 8 - 10), height: fh)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard glass == nil else { return }
        let c = env.themes.ui(effectiveAppearance)
        let r = pillRect
        let path = NSBezierPath(roundedRect: r, xRadius: Metrics.headerCornerRadius, yRadius: Metrics.headerCornerRadius)
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(CGFloat(c.shadowOpacity) * 0.8)
        shadow.shadowBlurRadius = 5
        shadow.shadowOffset = NSSize(width: 0, height: -1)
        shadow.set()
        c.headerBackground.setFill()
        path.fill()
        NSGraphicsContext.restoreGraphicsState()
        c.hairline.setStroke()
        path.lineWidth = 1
        path.stroke()
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        guard pillRect.contains(local) else { return nil }
        return super.hitTest(point)
    }

    // MARK: Search field delegate

    /// Also fires for the field's clear (x) button, which does not send controlTextDidChange.
    @objc private func searchFieldAction(_ sender: Any?) {
        onQueryChange?(searchField.stringValue)
    }

    func controlTextDidChange(_ obj: Notification) {
        onQueryChange?(searchField.stringValue)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        switch commandSelector {
        case #selector(NSResponder.cancelOperation(_:)):
            onSearchEscape?(); return true
        case #selector(NSResponder.moveDown(_:)):
            onSearchMoveDown?(); return true
        case #selector(NSResponder.insertNewline(_:)):
            onSearchSubmit?(); return true
        default:
            return false
        }
    }

    // MARK: Spring-loaded back button (drag a note onto it to reach the folder list)

    private func overBack(_ info: NSDraggingInfo) -> Bool {
        guard !backButton.isHidden else { return false }
        let p = content.convert(info.draggingLocation, from: nil)
        return backButton.frame.insetBy(dx: -6, dy: -6).contains(p)
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { draggingUpdated(sender) }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard PasteboardImport.hasInternalNote(sender.draggingPasteboard), overBack(sender) else {
            cancelSpring()
            return []
        }
        if springTimer == nil {
            backButton.isOn = true
            springTimer = Timer.scheduledTimer(withTimeInterval: 0.55, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.cancelSpring()
                    self?.onSpringBack?()
                }
            }
        }
        return .move
    }

    override func draggingExited(_ sender: NSDraggingInfo?) { cancelSpring() }
    override func draggingEnded(_ sender: NSDraggingInfo) { cancelSpring() }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let over = overBack(sender)
        cancelSpring()
        if over { onSpringBack?() }
        return false
    }

    private func cancelSpring() {
        springTimer?.invalidate()
        springTimer = nil
        backButton.isOn = false
    }
}

/// NSSearchField that keeps working inside the non-activating panel.
final class HeaderSearchField: NSSearchField {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// A label that never takes mouse events (clicks/drags go to the view below).
final class PassthroughLabel: NSTextField {
    init() {
        super.init(frame: .zero)
        isEditable = false
        isSelectable = false
        isBordered = false
        drawsBackground = false
        lineBreakMode = .byTruncatingTail
        maximumNumberOfLines = 1
        cell?.truncatesLastVisibleLine = true
        cell?.usesSingleLineMode = true
    }

    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
