import AppKit
import NoteBarCore

/// The rounded header pill.
/// - Folder and Scratch screens: the folder chips (`FolderTabsView`), search, +.
/// - Archive screens: back chevron, title, search.
/// - Search mode: the search field and a close button.
@MainActor
final class HeaderView: NSView, NSSearchFieldDelegate {
    /// Room around the pill for its drawn shadow. The pill itself is `pillRect`.
    static let shadowPad: CGFloat = 6

    /// What the pill shows while search is closed.
    enum Content: Equatable {
        /// The folder chips, search, and + (`plusToolTip`: what + makes on this screen).
        case tabs(plusToolTip: String)
        /// A back arrow, a title, and search (the archive).
        case title(String)
    }

    var onBack: (() -> Void)?
    var onSearch: (() -> Void)?
    var onPlus: (() -> Void)?
    var onQueryChange: ((String) -> Void)?
    /// Escape in the search field. Return true if handled.
    var onSearchEscape: (() -> Void)?
    var onSearchMoveDown: (() -> Void)?
    /// Tab (false) / Shift+Tab (true) in the search field.
    var onSearchTab: ((_ backward: Bool) -> Void)?
    var onSearchSubmit: (() -> Void)?
    /// ⌃[ in the search field (vim: go up). Returns false when not used.
    var onSearchNavigateUp: (() -> Bool)?
    var onCloseSearch: (() -> Void)?

    private let env: AppEnvironment
    private var glass: NSGlassEffectView?
    /// Everything in the pill is a subview of this view. In glass mode it is the glass view's content
    /// view, so the chips and buttons sit above the glass.
    private let content = FlippedView()
    let tabs: FolderTabsView
    let backButton = IconButton(symbol: "chevron.left", size: 13, toolTip: "Back (⌘[)")
    let searchButton = IconButton(symbol: "magnifyingglass", size: 12.5, toolTip: "Search (⌘F)")
    let plusButton = IconButton(symbol: "plus", size: 13, toolTip: "New Note (⌘N)")
    private let closeSearchButton = IconButton(symbol: "xmark", size: 11, toolTip: "Close Search (Esc)")
    private let titleLabel = PassthroughLabel()
    let searchField = HeaderSearchField()

    private(set) var isSearching = false
    private(set) var shown: Content = .tabs(plusToolTip: "New Note (⌘N)")
    /// The chips are in the pill (not in search, not on the archive screens).
    var showsTabs: Bool { if case .tabs = shown { return !isSearching }; return false }

    init(env: AppEnvironment) {
        self.env = env
        tabs = FolderTabsView(env: env)
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
        content.addSubview(tabs)
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
        setAccessibilityRole(.toolbar)
        setAccessibilityLabel("NoteBar header")
        update()
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    var pillRect: NSRect { bounds.insetBy(dx: Self.shadowPad, dy: Self.shadowPad) }

    // MARK: State

    func show(_ content: Content) {
        shown = content
        if case .tabs(let tip) = content {
            plusButton.toolTip = tip
            plusButton.setAccessibilityLabel(tip)
        }
        update()
    }

    func setSearching(_ on: Bool, query: String = "") {
        isSearching = on
        if on, searchField.stringValue != query { searchField.stringValue = query }
        if !on { searchField.stringValue = "" }
        update()
    }

    var query: String { searchField.stringValue }

    /// selectAll false: the caret goes to the end of the query (Tab back from the results).
    func focusSearchField(selectAll: Bool = true) {
        guard isSearching else { return }
        window?.makeFirstResponder(searchField)
        if selectAll {
            searchField.currentEditor()?.selectAll(nil)
        } else {
            let len = (searchField.stringValue as NSString).length
            searchField.currentEditor()?.selectedRange = NSRange(location: len, length: 0)
        }
    }

    var isSearchFieldFocused: Bool {
        guard let fr = window?.firstResponder as? NSView else { return false }
        return searchField.containsDescendant(fr) || (fr as? NSText)?.delegate === searchField
    }

    private func update() {
        var title: String?
        if case .title(let t) = shown { title = t }
        titleLabel.stringValue = title ?? ""
        titleLabel.isHidden = isSearching || title == nil
        backButton.isHidden = isSearching || title == nil
        tabs.isHidden = !showsTabs
        searchButton.isHidden = isSearching
        // The archive has no +: nothing is made there.
        plusButton.isHidden = !showsTabs
        searchField.isHidden = !isSearching
        closeSearchButton.isHidden = !isSearching
        restyle()
        needsLayout = true
    }

    func restyle() {
        let c = env.themes.ui(effectiveAppearance)
        titleLabel.font = UIFonts.headerTitle(env.themes.fontSize)
        searchField.font = UIFonts.headerSearch(env.themes.fontSize)
        titleLabel.textColor = c.accent
        for b in [backButton, searchButton, plusButton, closeSearchButton] {
            b.onTint = c.accent
            b.tint = c.text.withAlphaComponent(0.85)
            b.restingFill = c.headerButtonFill
            b.hoverFill = c.hoverFill
            b.pressedFill = c.pressedFill
        }
        tabs.restyle()
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
        // Without the + button (archive), search takes its place at the right end.
        searchButton.frame = NSRect(x: plusButton.isHidden ? w - 8 - s : plusButton.frame.minX - 6 - s, y: y, width: s, height: s)
        // The chips: from the left end of the pill to the search button.
        let tabsFrame = NSRect(x: 8, y: y, width: max(0, searchButton.frame.minX - 8 - 8), height: s)
        if tabs.frame != tabsFrame { tabs.frame = tabsFrame }
        tabs.layoutChips()
        let titleX = backButton.frame.maxX + 8
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
        case #selector(NSResponder.insertTab(_:)):
            onSearchTab?(false); return true
        case #selector(NSResponder.insertBacktab(_:)):
            onSearchTab?(true); return true
        case #selector(NSResponder.insertNewline(_:)):
            onSearchSubmit?(); return true
        default:
            // ⌃[ arrives as noop: (no key binding).
            if let e = NSApp.currentEvent, e.type == .keyDown, e.keyCode == 33,
               e.modifierFlags.intersection([.command, .shift, .option, .control]) == [.control] {
                return onSearchNavigateUp?() ?? false
            }
            return false
        }
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
