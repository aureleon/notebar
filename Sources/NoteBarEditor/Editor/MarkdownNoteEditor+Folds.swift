import AppKit
import NoteBarCore

/// Folding the children of a list item (sub-lines, nested lists).
///
/// A chevron sits after the item's text (the styler leaves room for it): ⌄ while the item is open, ›
/// while it is folded. Folded, the children take no space; they are
/// hidden like folded completed items (`NoteLayoutManager.collapsedItems`), and they show again while
/// the caret or a search match is in them. By default the children of a checked item are folded and
/// those of an open item are not; `Note.foldOverrides` keeps the items folded the other way, by item
/// text. Checking or unchecking an item drops its override, so it takes the new default.
struct ItemFold: Equatable {
    /// Line index of the item.
    var item: Int
    /// `ListEditing.foldKey` of the item.
    var key: String
    /// Storage range of the children, line terminators included.
    var range: NSRange
    var checked: Bool
}

extension MarkdownNoteEditor {
    /// Folded children take no space: the item's › says they are there.
    var itemFoldRowHeight: CGFloat { 0 }

    func makeItemFolds(_ lines: [MarkdownLine]) -> [ItemFold] {
        guard mode == .standard else { return [] }
        let s = storageString
        var out: [ItemFold] = []
        for i in lines.indices where lines[i].kind.isList && ListEditing.isFoldable(in: lines, item: i, string: s) {
            guard let key = ListEditing.foldKey(s, lines[i]) else { continue }
            let c = ListEditing.childLines(in: lines, of: i)
            let start = lines[c.lowerBound].fullRange.location
            let end = lines[c.upperBound - 1].fullRange.end
            var checked = false
            if case .checklist(true) = lines[i].kind { checked = true }
            out.append(ItemFold(item: i, key: key, range: NSRange(location: start, length: end - start), checked: checked))
        }
        return out
    }

    func isFolded(_ f: ItemFold) -> Bool { note.foldOverrides.contains(f.key) != f.checked }

    /// Children shown folded right now: not in folded completed items (`outside`) or in a folded
    /// item above, and without the caret or a search match in them.
    func foldedItemRanges(outside hidden: [NSRange]) -> [NSRange] {
        guard !itemFolds.isEmpty, !textView.hasMarkedText() else { return [] }
        let sel = textView.selectedRange()
        let focused = isEditingFocused
        var out: [NSRange] = []
        for f in itemFolds where isFolded(f) {
            if (hidden + out).contains(where: { f.range.location >= $0.location && f.range.location < $0.end }) { continue }
            if focused, selection(sel, isIn: f.range) { continue }
            if searchRanges.contains(where: { NSIntersectionRange($0, f.range).length > 0 }) { continue }
            out.append(f.range)
        }
        return out
    }

    /// Folds or unfolds the children of `f` and saves it on the note.
    func toggleItemFold(_ f: ItemFold) {
        guard var n = env.store.note(id: noteID) else { return }
        let keys = Set(itemFolds.map(\.key))
        n.foldOverrides = n.foldOverrides.intersection(keys)   // drop items that are gone
        if n.foldOverrides.contains(f.key) { n.foldOverrides.remove(f.key) } else { n.foldOverrides.insert(f.key) }
        note.foldOverrides = n.foldOverrides
        if isFolded(f), isEditingFocused, selection(textView.selectedRange(), isIn: f.range) {
            // Folding with the caret in the children: put it at the end of the item so they fold.
            textView.setSelectedRange(NSRange(location: max(0, f.range.location - 1), length: 0))
        }
        env.store.updateNote(n)
        updateCompletedCollapse()
    }

    /// The checkbox at storage `index` was toggled: its item takes the default fold of its new state.
    func resetFold(ofItemWithKey key: String?) {
        guard let key, var n = env.store.note(id: noteID), n.foldOverrides.contains(key) else { return }
        n.foldOverrides.remove(key)
        note.foldOverrides = n.foldOverrides
        env.store.updateNote(n)
        updateCompletedCollapse()
    }

    /// `ListEditing.foldKey` of the list item on the line holding storage `index`.
    func foldKey(atStorage index: Int) -> String? {
        let lines = currentLines()
        guard !lines.isEmpty else { return nil }
        return ListEditing.foldKey(storageString, lines[BlockScanner.lineIndex(in: lines, containing: index)])
    }

    // MARK: Chevrons

    func positionFoldChevrons() {
        let lm = layoutManagerNB
        let lines = styledLines
        let s = storageString
        let hidden = lm.collapsedChecks + lm.collapsedItems
        // Items that are on screen (not inside folded completed items or a folded item above).
        let shown = itemFolds.filter { f in
            f.item < lines.count && f.range.end <= textStorage.length
                && !hidden.contains { lines[f.item].range.location >= $0.location && lines[f.item].range.location < $0.end }
        }
        guard !shown.isEmpty || !foldChevrons.isEmpty else { return }
        while foldChevrons.count > shown.count { foldChevrons.removeLast().removeFromSuperview() }
        while foldChevrons.count < shown.count {
            let v = FoldChevronView(frame: .zero)
            textView.addSubview(v)
            foldChevrons.append(v)
        }
        guard !shown.isEmpty else { return }
        lm.ensureLayout(for: container)
        let origin = textView.textContainerOrigin
        let st = style
        let folded = Set(lm.collapsedItems.map(\.location))
        let lineHeight = ceil(lm.defaultLineHeight(for: st.bodyFont))
        for (v, f) in zip(foldChevrons, shown) {
            let item = lines[f.item]
            let collapsed = folded.contains(f.range.location)
            // After the item's text, in the room its lines leave (`NoteTextContainer`).
            guard item.range.length > 0, item.range.end <= textStorage.length else { v.isHidden = true; continue }
            let gi = lm.glyphIndexForCharacter(at: item.range.end - 1)
            guard gi < lm.numberOfGlyphs else { v.isHidden = true; continue }
            let glyph = lm.boundingRect(forGlyphRange: NSRange(location: gi, length: 1), in: container)
            let used = lm.lineFragmentUsedRect(forGlyphAt: gi, effectiveRange: nil)
            let h = min(lineHeight, used.height)
            let rect = NSRect(x: glyph.maxX + st.chevronGap, y: used.maxY - h, width: st.chevronWidth, height: h)
            v.configure(collapsed: collapsed, color: st.secondary, hoverColor: st.text, pointSize: max(8, st.fontSize - 5))
            v.onClick = { [weak self] in self?.toggleItemFold(f) }
            v.isHidden = false
            let frame = rect.offsetBy(dx: origin.x, dy: origin.y)
            if v.frame != frame { v.frame = frame }
        }
    }

    /// True when `p` (text view coordinates) is on a fold chevron or the clickable part of an
    /// "N completed" row: the pointer shows the pointing hand there, not the I-beam.
    func isFoldControl(at p: NSPoint) -> Bool {
        foldControlFrames.contains { $0.contains(p) }
    }

    /// Clickable frames of the fold chevrons and "N completed" rows, in text view coordinates.
    var foldControlFrames: [NSRect] {
        foldChevrons.filter { !$0.isHidden }.map(\.frame) + completedRows.filter { !$0.isHidden }.map(\.clickableFrame)
    }

    /// Areas of the text view (its coordinates) with a cursor other than the I-beam: the pointing hand
    /// on fold controls and the visible checkboxes and file tiles, the arrow on the code copy button.
    var cursorAreas: [(frame: NSRect, cursor: NSCursor)] {
        var out = foldControlFrames.map { ($0, NSCursor.pointingHand) }
        if let b = codeCopyButton, !b.isHidden { out.append((b.frame, .arrow)) }
        let lm = layoutManagerNB
        let len = textStorage.length
        guard len > 0 else { return out }
        let origin = textView.textContainerOrigin
        let visible = textView.visibleRect.offsetBy(dx: -origin.x, dy: -origin.y)
        let glyphs = lm.glyphRange(forBoundingRect: visible, in: container)
        let chars = lm.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        guard chars.length > 0, chars.end <= len else { return out }
        textStorage.enumerateAttribute(.attachment, in: chars, options: []) { value, range, _ in
            guard let a = value as? EmbedAttachment else { return }
            if case .attachment(_, true, _, _) = a.token { return }   // images: I-beam (a click selects them)
            for ci in range.location..<range.end {
                if lm.collapsedFold(at: ci) != nil { continue }
                let g = lm.glyphIndexForCharacter(at: ci)
                let r = lm.boundingRect(forGlyphRange: NSRange(location: g, length: 1), in: container)
                if r.width > 0, r.height > 0 { out.append((r.offsetBy(dx: origin.x, dy: origin.y), .pointingHand)) }
            }
        }
        return out
    }

    var handCursorFrames: [NSRect] { cursorAreas.filter { $0.cursor == .pointingHand }.map(\.frame) }

    /// The text view's cursor rects follow `cursorAreas` and the tables: rebuild them when those move.
    func cursorAreasDidChange() {
        let frames = cursorAreas.map(\.frame) + visibleTableFrames
        guard frames != lastHandCursorFrames else { return }
        lastHandCursorFrames = frames
        textView.window?.invalidateCursorRects(for: textView)
    }

    // MARK: Testing

    /// For checks: `handCursorFrames`.
    public var handCursorFramesForTesting: [NSRect] { handCursorFrames }

    /// For checks: `isFoldControl(at:)`.
    public func isFoldControlForTesting(at p: NSPoint) -> Bool { isFoldControl(at: p) }

    /// For checks: the fold chevrons on screen (folded, frame in text view coordinates).
    public var foldChevronsForTesting: [(collapsed: Bool, frame: NSRect)] {
        foldChevrons.filter { !$0.isHidden }.map { ($0.collapsed, $0.frame) }
    }

    /// For checks: clicks fold chevron `index`.
    public func toggleFoldForTesting(_ index: Int) {
        let visible = foldChevrons.filter { !$0.isHidden }
        guard index < visible.count else { return }
        visible[index].onClick?()
    }
}

/// ⌄ / ›: folds or unfolds the children of a list item.
final class FoldChevronView: NSView {
    var onClick: (() -> Void)?
    private(set) var collapsed = false
    private var color: NSColor = .secondaryLabelColor
    private var hoverColor: NSColor = .labelColor
    private var pointSize: CGFloat = 9
    private var hovering = false

    override var isFlipped: Bool { true }

    func configure(collapsed: Bool, color: NSColor, hoverColor: NSColor, pointSize: CGFloat) {
        setAccessibilityElement(true)
        setAccessibilityRole(.disclosureTriangle)
        setAccessibilityLabel(collapsed ? "Show sub-items" : "Hide sub-items")
        guard collapsed != self.collapsed || color != self.color || hoverColor != self.hoverColor
                || pointSize != self.pointSize else { return }
        self.collapsed = collapsed; self.color = color; self.hoverColor = hoverColor; self.pointSize = pointSize
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let c = hovering ? hoverColor : color.withAlphaComponent(collapsed ? 1 : 0.7)
        let symbol = collapsed ? "chevron.right" : "chevron.down"
        let config = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .semibold)
        guard let img = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?.withSymbolConfiguration(config) else { return }
        let tinted = NSImage(size: img.size, flipped: false) { r in
            img.draw(in: r)
            c.set()
            r.fill(using: .sourceAtop)
            return true
        }
        let s = img.size
        tinted.draw(in: NSRect(x: ((bounds.width - s.width) / 2).rounded(), y: ((bounds.height - s.height) / 2).rounded(),
                               width: s.width, height: s.height))
    }

    override func mouseDown(with event: NSEvent) {}

    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onClick?() }
    }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for t in trackingAreas { removeTrackingArea(t) }
        // .inVisibleRect: the area follows the frame (set after the view is created).
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .cursorUpdate, .activeAlways, .inVisibleRect],
                                       owner: self))
    }

    override func cursorUpdate(with event: NSEvent) { NSCursor.pointingHand.set() }

    override func mouseEntered(with event: NSEvent) { hovering = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovering = false; needsDisplay = true }

    override func accessibilityPerformPress() -> Bool { onClick?(); return true }
}
