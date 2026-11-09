import AppKit
import NoteBarCore

/// The rail of binder tabs on the inner panel edge: Scratch, one tab per folder, and "all folders".
/// Scratch and "all folders" stay in place. The folder tabs between them shrink down to
/// `minTabHeight` when the panel is too short for all of them, and scroll after that.
@MainActor
final class FolderTabRailView: FlippedView {
    enum Kind: Hashable { case scratch, folder(FolderID), allFolders }

    /// How the rail looks (prototype switch, to compare the looks side by side).
    /// - spine: tabs hang on a strip along the cards, the open one runs through it.
    /// - pill: one capsule in the header's material with a round button per tab.
    /// - floating: rounded tabs a gap away from the cards, nothing behind them.
    /// - joined: like floating, but the open tab reaches the cards, in its folder's card color.
    /// - bar: a horizontal capsule under the header, above the first note. Round buttons, and the open
    ///   Scratch and all folders, and a chip with the name of each folder.
    /// - header: the same chips inside the header pill, in place of the back arrow and the title.
    enum Style: String, CaseIterable { case spine, pill, floating, joined, bar, header }
    /// Header style: the title of the Scratch screen ("Scratch · Today"), shown on the open Scratch tab.
    var scratchTitle: String?
    static let barHeight: CGFloat = 32
    static var style: Style = .spine
    /// Pill style: width of the capsule and diameter of its buttons.
    static let pillWidth: CGFloat = 28
    static let pillButton: CGFloat = 22

    static let tabHeight: CGFloat = 34
    static let minTabHeight: CGFloat = 22
    static let tabGap: CGFloat = 4
    /// Visible width of a tab that is not active (the active one takes the full rail width).
    static let inactiveWidth: CGFloat = 21
    /// The rail view reaches this far into the notes column: the outer margin of the cards, where
    /// the spine is. Nothing of the rail is under a card (cards can be translucent).
    static let tuck: CGFloat = Metrics.outerMargin

    var onSelect: ((Kind) -> Void)?
    /// The rail got taller or shorter (folders changed).
    var onHeightChange: (() -> Void)?
    var railOnLeft = true {
        didSet { if oldValue != railOnLeft { needsDisplay = true; for t in allTabs { t.railOnLeft = railOnLeft } } }
    }

    private let env: AppEnvironment
    private var scratchTab: FolderTabView?
    private(set) var folderTabs: [FolderTabView] = []
    private let allTab = FolderTabView(kind: .allFolders)
    /// Clips the folder tabs while they scroll.
    private let clip = FlippedView()
    private(set) var active: Kind = .allFolders
    private var folders: [Folder] = []
    private var lastFittingHeight: CGFloat = -1

    var allTabs: [FolderTabView] { (scratchTab.map { [$0] } ?? []) + folderTabs + [allTab] }

    init(env: AppEnvironment) {
        self.env = env
        super.init(frame: .zero)
        clip.clipsToBounds = true
        addSubview(clip)
        addSubview(allTab)
        allTab.symbolName = "list.bullet"
        allTab.toolTip = "All Folders"
        allTab.setAccessibilityLabel("All Folders")
        allTab.onClick = { [weak self] in self?.onSelect?(.allFolders) }
        isHidden = true
        setAccessibilityRole(.tabGroup)
        setAccessibilityLabel("Folders")
    }

    required init?(coder: NSCoder) { fatalError() }

    func reload(folders: [Folder], showsScratch: Bool, active: Kind) {
        self.folders = folders
        self.active = active
        if showsScratch, scratchTab == nil {
            let t = FolderTabView(kind: .scratch)
            t.symbolName = "pencil.and.scribble"
            t.toolTip = "Scratch"
            t.setAccessibilityLabel("Scratch")
            t.onClick = { [weak self] in self?.onSelect?(.scratch) }
            addSubview(t)
            scratchTab = t
        } else if !showsScratch, let t = scratchTab {
            t.removeFromSuperview()
            scratchTab = nil
        }
        // Reuse the tab views by folder, so a hover survives a reload.
        var old = Dictionary(uniqueKeysWithValues: folderTabs.map { ($0.kind, $0) })
        folderTabs = folders.map { f in
            let t = old.removeValue(forKey: .folder(f.id)) ?? FolderTabView(kind: .folder(f.id))
            let name = f.name.trimmingCharacters(in: .whitespacesAndNewlines)
            t.letter = name.first.map { String($0).uppercased() } ?? "?"
            t.toolTip = f.name
            t.title = name
            t.setAccessibilityLabel(f.name)
            t.noteColor = f.color
            t.onClick = { [weak self] in self?.onSelect?(.folder(f.id)) }
            if t.superview !== clip { clip.addSubview(t) }
            return t
        }
        for t in old.values { t.removeFromSuperview() }
        for t in allTabs {
            t.isActive = t.kind == active
            t.railOnLeft = railOnLeft
        }
        scratchTab?.title = Self.style == .header && active == .scratch ? scratchTitle : nil
        updateTucks()
        restyle()
        needsLayout = true
    }

    func restyle() {
        let appearance = effectiveAppearance
        let ui = env.themes.ui(appearance)
        for t in allTabs {
            if t.noteColor == .none {
                t.fill = ui.headerBackground
                t.dimFill = ui.headerBackground.withAlphaComponent(ui.headerBackground.alphaComponent * 0.6)
                t.ink = ui.text
                t.dimInk = ui.text
            } else {
                // The open tab has the strong color of the folder icon, not the pale card fill: a tab
                // is small and must read against any desktop. The others are halfway to the card fill.
                let strong = env.themes.barColor(t.noteColor, appearance: appearance)
                let card = env.themes.cardBackground(t.noteColor, appearance: appearance)
                let dim = card.blended(withFraction: 0.5, of: strong) ?? strong
                t.fill = strong
                t.dimFill = dim
                t.ink = Self.isLight(strong) ? NSColor.black.withAlphaComponent(0.8) : .white
                t.dimInk = Self.isLight(dim) ? NSColor.black.withAlphaComponent(0.8) : .white
            }
            switch Self.style {
            case .joined:
                // The open tab is a piece of the folder's cards.
                t.fill = env.themes.cardBackground(t.noteColor, appearance: appearance)
                t.ink = ui.text
            case .pill where t.noteColor == .none, .bar where t.noteColor == .none, .header where t.noteColor == .none:
                // On the capsule (the header's material) a plain button is a shade of the text color.
                t.fill = ui.text.withAlphaComponent(0.85)
                t.ink = ui.headerBackground.withAlphaComponent(1)
                t.dimFill = ui.text.withAlphaComponent(0.10)
            default: break
            }
            t.stroke = ui.isDark ? NSColor.white.withAlphaComponent(0.14) : NSColor.black.withAlphaComponent(0.10)
            t.fontSize = env.themes.fontSize
        }
        spineFill = ui.headerBackground.withAlphaComponent(ui.headerBackground.alphaComponent * 0.6)
        pillFill = ui.headerBackground
        pillStroke = ui.isDark ? NSColor.white.withAlphaComponent(0.10) : NSColor.black.withAlphaComponent(0.06)
        needsDisplay = true
    }

    private static func isLight(_ color: NSColor) -> Bool {
        guard let c = color.usingColorSpace(.sRGB) else { return true }
        return 0.299 * c.redComponent + 0.587 * c.greenComponent + 0.114 * c.blueComponent > 0.62
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        restyle()
    }

    // MARK: Spine

    /// The strip the tabs hang on: the outer margin of the notes column, down the whole rail. It
    /// touches the cards, so a tab beside a gap or below the last card is still joined to something.
    /// The open tab runs through it to the cards.
    private var spineFill: NSColor = .clear
    var spineRect: NSRect {
        NSRect(x: railOnLeft ? bounds.width - Self.tuck : 0, y: 0, width: Self.tuck, height: bounds.height)
    }

    private var pillFill: NSColor = .clear
    private var pillStroke: NSColor = .clear
    var pillRect: NSRect {
        NSRect(x: railOnLeft ? 0 : bounds.width - Self.pillWidth, y: 0, width: Self.pillWidth, height: bounds.height)
    }

    override func draw(_ dirtyRect: NSRect) {
        switch Self.style {
        case .spine:
            spineFill.setFill()
            NSBezierPath(roundedRect: spineRect, xRadius: 3, yRadius: 3).fill()
        case .pill:
            let r = min(Self.pillWidth, bounds.height) / 2
            let path = NSBezierPath(roundedRect: pillRect.insetBy(dx: 0.5, dy: 0.5), xRadius: r, yRadius: r)
            pillFill.setFill()
            path.fill()
            pillStroke.setStroke()
            path.lineWidth = 1
            path.stroke()
        case .bar:
            let r = bounds.height / 2
            let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: r, yRadius: r)
            pillFill.setFill()
            path.fill()
            pillStroke.setStroke()
            path.lineWidth = 1
            path.stroke()
        case .floating, .joined, .header:
            break
        }
    }

    // MARK: Bar

    /// First folder tab shown in the bar. The bar scrolls by whole tabs.
    private var barFirst = 0
    private func barShown(from first: Int, widths: [CGFloat], room: CGFloat) -> Int {
        var x: CGFloat = 0, n = 0
        for w in widths[first...] {
            if x + w > room + 0.5 { break }
            x += w + Self.tabGap
            n += 1
        }
        return n
    }

    /// Scratch at the left end, all folders at the right end, and between them as many whole folder
    /// tabs as fit. The open folder's tab is always one of them.
    private func placeBar() {
        // In the header there is no capsule of its own, and all folders comes first (where the back
        // arrow was).
        let inHeader = Self.style == .header
        let pad: CGFloat = inHeader ? 0 : 4
        let d = bounds.height - 2 * pad
        var left = pad
        if inHeader {
            allTab.frame = NSRect(x: left, y: pad, width: d, height: d)
            left += d + Self.tabGap
        }
        if let s = scratchTab {
            let w = s.title == nil ? d : s.titleWidth + 20
            s.frame = NSRect(x: left, y: pad, width: w, height: d)
            left += w + Self.tabGap
        }
        if !inHeader { allTab.frame = NSRect(x: bounds.width - pad - d, y: pad, width: d, height: d) }
        let room = max(0, (inHeader ? bounds.width : allTab.frame.minX - Self.tabGap) - left)
        clip.frame = NSRect(x: left, y: pad, width: room, height: d)
        let widths = folderTabs.map { min(room, max(d, $0.titleWidth + 20)) }
        guard !widths.isEmpty else { return }
        barFirst = min(max(barFirst, 0), widths.count - 1)
        // Do not leave room unused at the end.
        while barFirst > 0, barFirst + barShown(from: barFirst, widths: widths, room: room) == widths.count,
              barFirst - 1 + barShown(from: barFirst - 1, widths: widths, room: room) == widths.count { barFirst -= 1 }
        if let i = folderTabs.firstIndex(where: { $0.isActive }) {
            barFirst = min(barFirst, i)
            while barFirst < i, barFirst + barShown(from: barFirst, widths: widths, room: room) <= i { barFirst += 1 }
        }
        let shown = barShown(from: barFirst, widths: widths, room: room)
        var x: CGFloat = 0
        for (i, t) in folderTabs.enumerated() {
            t.isHidden = i < barFirst || i >= barFirst + shown
            guard !t.isHidden else { continue }
            t.frame = NSRect(x: x, y: 0, width: widths[i], height: d)
            x += widths[i] + Self.tabGap
        }
        barCanScroll = shown < widths.count
    }
    private(set) var barCanScroll = false

    // MARK: Layout

    private var fixedCount: Int { (scratchTab == nil ? 0 : 1) + 1 }

    /// The rail is never lower than this: the fixed tabs and one folder tab, at the smallest size.
    var minimumHeight: CGFloat {
        let n = CGFloat(fixedCount + min(1, folderTabs.count))
        return n * (Self.minTabHeight + Self.tabGap) - Self.tabGap
    }

    /// Tab height for a rail of `available` height: full size if every tab fits, else smaller, down
    /// to `minTabHeight`.
    /// When they do not fit even then, the rail holds as many whole tabs as it can, stretched a
    /// little so the last one ends flush with the rail's end (the bottom of the last note).
    func tabHeight(available: CGFloat) -> CGFloat {
        let n = CGFloat(fixedCount + folderTabs.count)
        let fit = (available + Self.tabGap) / n - Self.tabGap
        if fit >= Self.minTabHeight { return min(Self.tabHeight, fit) }
        return (available + Self.tabGap) / slots(available: available) - Self.tabGap
    }

    /// Whole tabs a scrolling rail of `available` height shows.
    private func slots(available: CGFloat) -> CGFloat {
        max(CGFloat(fixedCount + min(1, folderTabs.count)),
            floor((available + Self.tabGap) / (Self.minTabHeight + Self.tabGap)))
    }

    /// Height of the rail: all tabs, or, when they need to scroll, as many whole tabs as `available`
    /// holds. A rail that ended in the middle of a tab would show a cut-off tab.
    func fittingHeight(available: CGFloat) -> CGFloat {
        let n = CGFloat(fixedCount + folderTabs.count)
        let step = tabHeight(available: available) + Self.tabGap
        let fits = n * step - Self.tabGap <= available + 0.5
        let h = ((fits ? n : min(n, slots(available: available))) * step - Self.tabGap).rounded()
        if h != lastFittingHeight {
            let first = lastFittingHeight < 0
            lastFittingHeight = h
            if !first { DispatchQueue.main.async { [weak self] in self?.onHeightChange?() } }
        }
        return h
    }

    private(set) var currentTabHeight: CGFloat = FolderTabRailView.tabHeight
    private var step: CGFloat { currentTabHeight + Self.tabGap }
    /// Tab slots the rail shows (fixed tabs included), and those left for the folder tabs.
    private var shownSlots: Int { max(fixedCount, Int(((bounds.height + Self.tabGap) / step).rounded())) }
    private var folderSlots: Int { shownSlots - fixedCount }
    private var maxScrollSlots: Int { max(0, folderTabs.count - folderSlots) }
    var maxScrollOffset: CGFloat { CGFloat(maxScrollSlots) * step }
    /// Folder tabs scrolled out above. The tabs scroll by whole tabs, so none is ever cut off.
    private var scrollSlots = 0
    var scrollOffset: CGFloat { CGFloat(scrollSlots) * step }
    /// Wheel movement that did not add up to a whole tab yet.
    private var wheelRemainder: CGFloat = 0

    override func layout() {
        super.layout()
        layoutTabs()
    }

    func layoutTabs() {
        if Self.style == .bar || Self.style == .header { placeBar(); return }
        for t in folderTabs { t.isHidden = false }
        currentTabHeight = tabHeight(available: bounds.height)
        // Keep the open folder's tab in view.
        if let i = folderTabs.firstIndex(where: { $0.isActive }), folderSlots > 0 {
            scrollSlots = min(scrollSlots, i)
            scrollSlots = max(scrollSlots, i - folderSlots + 1)
        }
        placeTabs()
    }

    /// Slot edges are whole points, so tab heights can differ by a point and the last tab ends
    /// exactly at the rail's end.
    private func placeTabs() {
        let w = bounds.width
        let step = self.step
        func edge(_ slot: Int) -> CGFloat { (CGFloat(slot) * step).rounded() }
        scrollSlots = min(max(scrollSlots, 0), maxScrollSlots)
        let first = scratchTab == nil ? 0 : 1
        scratchTab?.frame = NSRect(x: 0, y: 0, width: w, height: edge(1) - Self.tabGap)
        let last = shownSlots - 1
        allTab.frame = NSRect(x: 0, y: edge(last), width: w, height: max(0, bounds.height - edge(last)))
        clip.frame = NSRect(x: 0, y: edge(first), width: w, height: max(0, edge(last) - Self.tabGap - edge(first)))
        for (i, t) in folderTabs.enumerated() {
            let slot = first + i - scrollSlots
            t.frame = NSRect(x: 0, y: edge(slot) - edge(first), width: w, height: edge(slot + 1) - edge(slot) - Self.tabGap)
        }
        updateTucks()
    }

    /// Only the open tab crosses the spine.
    private func updateTucks() {
        let joins = Self.style == .spine || Self.style == .joined
        for t in allTabs { t.tuck = joins && t.isActive ? Self.tuck : 0 }
    }

    func scroll(by dy: CGFloat) {
        if Self.style == .bar || Self.style == .header {
            wheelRemainder += dy
            let steps = Int((wheelRemainder / 24).rounded(.towardZero))
            guard steps != 0 else { return }
            wheelRemainder = 0
            barFirst += steps
            placeBar()
            return
        }
        wheelRemainder += dy
        let steps = Int((wheelRemainder / step).rounded(.towardZero))
        guard steps != 0 else { return }
        wheelRemainder -= CGFloat(steps) * step
        let before = scrollSlots
        scrollSlots += steps
        placeTabs()
        if scrollSlots == before { wheelRemainder = 0 }
    }

    override func scrollWheel(with event: NSEvent) {
        if Self.style == .bar || Self.style == .header {
            guard barCanScroll || barFirst > 0 else { super.scrollWheel(with: event); return }
            let d = abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) ? event.scrollingDeltaX : event.scrollingDeltaY
            scroll(by: -d * (event.hasPreciseScrollingDeltas ? 1 : 8))
            return
        }
        guard maxScrollOffset > 0 else { super.scrollWheel(with: event); return }
        scroll(by: -event.scrollingDeltaY * (event.hasPreciseScrollingDeltas ? 1 : 8))
    }

    /// Only the tabs take clicks. The gaps and the part tucked under the cards do not.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit is FolderTabView ? hit : nil
    }
}

/// One tab. The view spans the rail and the spine. The drawn body is narrower while the tab is not
/// active and ends at the spine. The active one is wider and runs through the spine to the cards,
/// so it reads as the open divider.
@MainActor
final class FolderTabView: NSView {
    let kind: FolderTabRailView.Kind
    var letter: String? { didSet { if oldValue != letter { needsDisplay = true } } }
    /// Bar style: the folder name, shown on the open tab.
    var title: String? { didSet { if oldValue != title { needsDisplay = true } } }
    private var titleAttributes: [NSAttributedString.Key: Any] {
        [.font: NSFont.systemFont(ofSize: fontSize - 1.5, weight: .semibold), .foregroundColor: ink]
    }
    var titleWidth: CGFloat { ceil(((title ?? "") as NSString).size(withAttributes: titleAttributes).width) }
    var symbolName: String? { didSet { if oldValue != symbolName { image = nil; needsDisplay = true } } }
    var noteColor: NoteColor = .none
    var fill: NSColor = .windowBackgroundColor { didSet { needsDisplay = true } }
    var ink: NSColor = .labelColor { didSet { needsDisplay = true } }
    /// Fill and ink while the tab is not the open one.
    var dimFill: NSColor = .windowBackgroundColor { didSet { needsDisplay = true } }
    var dimInk: NSColor = .labelColor { didSet { needsDisplay = true } }
    var stroke: NSColor = .clear { didSet { needsDisplay = true } }
    var fontSize: CGFloat = 14 { didSet { if oldValue != fontSize { image = nil; needsDisplay = true } } }
    var isActive = false { didSet { if oldValue != isActive { image = nil; needsDisplay = true } } }
    var railOnLeft = true { didSet { if oldValue != railOnLeft { needsDisplay = true } } }
    var onClick: (() -> Void)?
    /// How far the body reaches into the notes column (0: the tab ends at the spine).
    var tuck: CGFloat = FolderTabRailView.tuck { didSet { if oldValue != tuck { needsDisplay = true } } }

    private var image: NSImage?
    private(set) var hovering = false { didSet { if oldValue != hovering { needsDisplay = true } } }
    private var pressed = false { didSet { if oldValue != pressed { needsDisplay = true } } }
    private var tracking: NSTrackingArea?

    init(kind: FolderTabRailView.Kind) {
        self.kind = kind
        super.init(frame: .zero)
        setAccessibilityRole(.button)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    /// The drawn tab: from its outer edge to the spine, or through it (`tuck`).
    var bodyRect: NSRect {
        let rail = bounds.width - FolderTabRailView.tuck
        let visible = isActive || hovering ? rail : min(FolderTabRailView.inactiveWidth, rail)
        let w = visible + tuck
        let inner = FolderTabRailView.tuck - tuck
        return NSRect(x: railOnLeft ? bounds.width - inner - w : inner, y: 0, width: w, height: bounds.height)
    }

    /// The part of the body outside the notes column (where the letter sits).
    var faceRect: NSRect {
        var r = bodyRect
        r.size.width -= tuck
        if !railOnLeft { r.origin.x += tuck }
        return r
    }

    /// The fill as drawn: full colour for the open tab, dimmer for the others.
    var drawnFill: NSColor {
        if isActive { return fill }
        return dimFill.withAlphaComponent(dimFill.alphaComponent * (pressed || hovering ? 1 : 0.85))
    }

    /// Pill style: the round button, centered in the capsule.
    var buttonRect: NSRect {
        let d = min(FolderTabRailView.pillButton, bounds.height - 2) + (isActive || hovering ? 2 : 0)
        let cx = railOnLeft ? FolderTabRailView.pillWidth / 2 : bounds.width - FolderTabRailView.pillWidth / 2
        return NSRect(x: cx - d / 2, y: bounds.midY - d / 2, width: d, height: d)
    }

    override func draw(_ dirtyRect: NSRect) {
        let style = FolderTabRailView.style
        if style == .bar || style == .header { drawBarButton(); return }
        let body = bodyRect
        let r = min(9, body.height / 2)
        var face = faceRect
        if style == .pill {
            face = buttonRect
            drawnFill.setFill()
            NSBezierPath(ovalIn: face).fill()
        } else {
            // Spine, and the open tab of joined: round the outer corners only (the rounded rect runs
            // past the inner end, which is clipped). Floating tabs round all four.
            let flatInner = style == .spine || (style == .joined && isActive)
            var shape = body.insetBy(dx: 0, dy: 0.5)
            if flatInner {
                shape.size.width += r
                if !railOnLeft { shape.origin.x -= r }
            }
            shape = shape.insetBy(dx: 0.5, dy: 0)
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(rect: body).addClip()
            let path = NSBezierPath(roundedRect: shape, xRadius: r, yRadius: r)
            drawnFill.setFill()
            path.fill()
            stroke.setStroke()
            path.lineWidth = 1
            path.stroke()
            NSGraphicsContext.restoreGraphicsState()
        }
        let inkColor = isActive ? ink : dimInk.withAlphaComponent(hovering ? 1 : 0.8)
        if let symbolName {
            if image == nil { image = Symbols.image(symbolName, size: isActive ? fontSize - 1.5 : fontSize - 3, weight: .semibold) }
            if let image { Symbols.draw(image, in: face, color: isActive ? ink : dimInk, fraction: isActive || hovering ? 1 : 0.8) }
        } else if let letter {
            let size = min(isActive ? fontSize - 1 : fontSize - 2.5, max(9, bounds.height - 8))
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: size, weight: isActive ? .bold : .semibold),
                .foregroundColor: inkColor,
            ]
            let s = NSAttributedString(string: letter, attributes: attrs)
            let sz = s.size()
            s.draw(at: NSPoint(x: (face.midX - sz.width / 2).rounded(), y: (face.midY - sz.height / 2).rounded()))
        }
    }

    /// Bar style: a round button, or a capsule with the folder name for the open folder.
    private func drawBarButton() {
        let b = bounds
        let r = b.height / 2
        drawnFill.setFill()
        NSBezierPath(roundedRect: b, xRadius: r, yRadius: r).fill()
        let inkColor = isActive ? ink : dimInk.withAlphaComponent(hovering ? 1 : 0.8)
        if let symbolName, title == nil {
            if image == nil { image = Symbols.image(symbolName, size: fontSize - 3, weight: .semibold) }
            if let image { Symbols.draw(image, in: b, color: inkColor, fraction: 1) }
            return
        }
        var attrs = titleAttributes
        attrs[.foregroundColor] = inkColor
        let showsTitle = title != nil
        let para = NSMutableParagraphStyle()
        para.alignment = .center
        para.lineBreakMode = .byTruncatingTail
        attrs[.paragraphStyle] = para
        let text = (showsTitle ? title : letter) ?? ""
        let h = (text as NSString).size(withAttributes: attrs).height
        let inset: CGFloat = showsTitle ? 9 : 0
        (text as NSString).draw(with: NSRect(x: inset, y: ((b.height - h) / 2).rounded(), width: b.width - 2 * inset, height: h),
                                options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], attributes: attrs)
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
    override func mouseDown(with event: NSEvent) { pressed = true }
    override func mouseUp(with event: NSEvent) {
        let inside = bounds.contains(convert(event.locationInWindow, from: nil))
        pressed = false
        if inside { onClick?() }
    }

    func setHoveredForSnapshot(_ on: Bool) { hovering = on }
}
