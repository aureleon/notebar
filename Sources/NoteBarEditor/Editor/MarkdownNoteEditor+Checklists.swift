import AppKit
import NoteBarCore

/// Checked checklist items sort below the open ones (`AppSettings.sortCheckedItems`), and the checked
/// items at the end of each block can be folded behind an "N completed" row.
///
/// The row sits in the paragraph spacing above the first completed item (`MarkdownStyler.completedHeads`).
/// Folded (`Note.hidesCompletedItems`), `NoteLayoutManager` hides the items' glyphs and gives their
/// first line the row's height and the other lines none, like a rendered table. The folded items show
/// again while the caret or a search match is in them, without changing the saved state.
struct CompletedGroup: Equatable {
    /// Line index of the first completed item.
    var head: Int
    /// Storage range of the completed items, line terminators included.
    var range: NSRange
    var count: Int
    /// Leading whitespace of the items (the row lines up with their checkboxes).
    var indent: String
}

extension MarkdownNoteEditor {
    var sortsCheckedItems: Bool { mode == .standard && env.settings.sortCheckedItems }

    var completedRowHeight: CGFloat { ceil(layoutManagerNB.defaultLineHeight(for: completedRowFont)) + 4 }

    var completedRowFont: NSFont { style.font(size: max(9, style.fontSize - 1)) }

    // MARK: Sort on toggle

    /// Toggles the checkbox at `index` and moves its item within its block (one undo step).
    /// False when nothing moves; the caller then toggles in place.
    func toggleAndSort(at index: Int, token: EmbedToken) -> Bool {
        let embeds = MarkdownCodec.embeds(in: textStorage)
        guard let e = embeds.first(where: { $0.index == index }) else { return false }
        let md = markdown as NSString
        let at = MarkdownCodec.markdownOffset(forStorageOffset: index, embeds: embeds)
        let next: unichar? = index + 1 < textStorage.length ? (textStorage.string as NSString).character(at: index + 1) : nil
        let toggled = md.replacingCharacters(in: NSRange(location: at, length: e.emittedLength),
                                             with: MarkdownCodec.emitted(token.toggled(), followedBy: next))
        guard let r = ChecklistSort.sorted(toggled, itemAt: at) else { return false }
        let sel = markdownSelection
        let a = r.map(sel.location), b = r.map(sel.end)
        replaceMarkdown(r.text, selection: NSRange(location: a, length: max(0, b - a)), undoable: true, actionName: "Toggle Checkbox")
        return true
    }

    // MARK: Groups

    func makeCompletedGroups(_ lines: [MarkdownLine]) -> [CompletedGroup] {
        guard sortsCheckedItems else { return [] }
        let s = storageString
        var out: [CompletedGroup] = []
        for b in ChecklistSort.blocks(in: lines) {
            guard let tail = b.completedTail, let ls = b.completedLines else { continue }
            // A block inside folded items folds with them.
            let start = lines[ls.lowerBound].fullRange.location
            if let last = out.last, start < last.range.end { continue }
            let end = lines[ls.upperBound - 1].fullRange.end
            let head = lines[ls.lowerBound]
            out.append(CompletedGroup(head: ls.lowerBound, range: NSRange(location: start, length: end - start),
                                      count: tail.count,
                                      indent: s.substring(with: NSRange(location: head.range.location, length: head.indent))))
        }
        return out
    }

    /// True when the selection is in the group's items (a caret at the end of the open item above is not).
    func selection(_ sel: NSRange, isIn range: NSRange) -> Bool {
        guard sel.end >= range.location else { return false }
        if sel.location < range.end { return true }
        // The last line of the note has no terminator: its end is still in it.
        let s = storageString
        return sel.location == range.end && range.end == s.length && range.length > 0
            && !UC.isLineTerminator(s.character(at: range.end - 1))
    }

    /// Groups shown folded right now.
    private func foldedGroups() -> [CompletedGroup] {
        guard note.hidesCompletedItems, !textView.hasMarkedText() else { return [] }
        let sel = textView.selectedRange()
        let focused = isEditingFocused
        return completedGroups.filter { g in
            if focused, selection(sel, isIn: g.range) { return false }
            if searchRanges.contains(where: { NSIntersectionRange($0, g.range).length > 0 }) { return false }
            return true
        }
    }

    /// Folds / unfolds groups after a restyle, a selection change, a search, or a new saved state.
    func updateCompletedCollapse() {
        let lm = layoutManagerNB
        lm.completedRowHeight = completedRowHeight
        lm.itemFoldRowHeight = itemFoldRowHeight
        let new = foldedGroups().map(\.range)
        let newItems = foldedItemRanges(outside: new)
        let old = lm.collapsedChecks, oldItems = lm.collapsedItems
        if new != old || newItems != oldItems {
            lm.collapsedChecks = new
            lm.collapsedItems = newItems
            let len = textStorage.length
            for r in old + new + oldItems + newItems {
                let c = NSIntersectionRange(r, NSRange(location: 0, length: len))
                guard c.length > 0 else { continue }
                lm.invalidateGlyphs(forCharacterRange: c, changeInLength: 0, actualCharacterRange: nil)
                lm.invalidateLayout(forCharacterRange: c, actualCharacterRange: nil)
                lm.invalidateDisplay(forCharacterRange: c)
            }
            layoutDidChange()
            textView.needsDisplay = true
        }
        positionCompletedRows()
    }

    /// Backspace right after folded items would join the line to a hidden item: put the caret at the
    /// end of the items instead, which shows them. True when it did.
    func revealFoldedItemsBeforeCaret() -> Bool {
        let sel = textView.selectedRange()
        guard sel.length == 0, sel.location > 0,
              let r = (layoutManagerNB.collapsedChecks + layoutManagerNB.collapsedItems).first(where: { $0.end == sel.location })
        else { return false }
        textView.setSelectedRange(NSRange(location: r.end - 1, length: 0))
        return true
    }

    /// Saves the folded state of this note's completed items (all its checklists).
    func toggleCompletedItems() {
        guard var n = env.store.note(id: noteID) else { return }
        n.hidesCompletedItems.toggle()
        if n.hidesCompletedItems, isEditingFocused {
            // Folding with the caret in the items: put it at the end of the open items so they fold.
            let sel = textView.selectedRange()
            if let g = completedGroups.first(where: { selection(sel, isIn: $0.range) }) {
                textView.setSelectedRange(NSRange(location: max(0, g.range.location - 1), length: 0))
            }
        }
        env.store.updateNote(n)
        note.hidesCompletedItems = n.hidesCompletedItems
        updateCompletedCollapse()
    }

    // MARK: Rows

    func positionCompletedRows() {
        positionFoldChevrons()
        let groups = completedGroups
        guard !groups.isEmpty || !completedRows.isEmpty else { return }
        while completedRows.count > groups.count { completedRows.removeLast().removeFromSuperview() }
        while completedRows.count < groups.count {
            let v = CompletedRowView(frame: .zero)
            v.onClick = { [weak self] in self?.toggleCompletedItems() }
            textView.addSubview(v)
            completedRows.append(v)
        }
        guard !groups.isEmpty else { return }
        let lm = layoutManagerNB
        lm.ensureLayout(for: container)
        let origin = textView.textContainerOrigin
        let st = style
        let h = completedRowHeight
        let folded = Set(lm.collapsedChecks.map(\.location))
        for (v, g) in zip(completedRows, groups) {
            let collapsed = folded.contains(g.range.location)
            v.configure(count: g.count, collapsed: collapsed, font: completedRowFont, color: st.secondary, hoverColor: st.text,
                        chevronWidth: st.checkboxDiameter)
            let gi = lm.glyphIndexForCharacter(at: g.range.location)
            guard gi < lm.numberOfGlyphs, g.range.end <= textStorage.length else { v.isHidden = true; continue }
            let frag = lm.lineFragmentRect(forGlyphAt: gi, effectiveRange: nil)
            let x = st.indentWidth(g.indent, font: st.bodyFont, tab: st.tabInterval)
            let f = NSRect(x: origin.x + x, y: origin.y + frag.minY, width: max(0, container.size.width - x), height: h)
            v.isHidden = false
            if v.frame != f { v.frame = f }
        }
    }

    // MARK: Testing

    /// For checks: the "N completed" rows (count, folded, frame in text view coordinates).
    public var completedRowsForTesting: [(count: Int, collapsed: Bool, frame: NSRect)] {
        completedRows.filter { !$0.isHidden }.map { ($0.count, $0.collapsed, $0.frame) }
    }

    /// For checks: clicks the "N completed" row `row`.
    public func toggleCompletedForTesting(row: Int) {
        let visible = completedRows.filter { !$0.isHidden }
        guard row < visible.count else { return }
        visible[row].onClick?()
    }
}

/// "▸ 3 completed": folds / unfolds the completed items of the note.
final class CompletedRowView: NSView {
    var onClick: (() -> Void)?
    private(set) var count = 0
    private(set) var collapsed = false
    private var font: NSFont = .systemFont(ofSize: 12)
    private var color: NSColor = .secondaryLabelColor
    private var hoverColor: NSColor = .labelColor
    private var chevronWidth: CGFloat = 16
    private var hovering = false

    override var isFlipped: Bool { true }

    func configure(count: Int, collapsed: Bool, font: NSFont, color: NSColor, hoverColor: NSColor, chevronWidth: CGFloat) {
        guard count != self.count || collapsed != self.collapsed || font != self.font || color != self.color
                || hoverColor != self.hoverColor || chevronWidth != self.chevronWidth else { return }
        self.count = count; self.collapsed = collapsed; self.font = font; self.color = color; self.hoverColor = hoverColor
        self.chevronWidth = chevronWidth
        window?.invalidateCursorRects(for: self)
        updateTrackingAreas()
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(collapsed ? "Show \(count) completed" : "Hide \(count) completed")
        needsDisplay = true
    }

    private var label: String { "\(count) completed" }

    /// The chevron and the label (the clickable part).
    private var contentWidth: CGFloat {
        chevronWidth + 6 + ceil((label as NSString).size(withAttributes: [.font: font]).width)
    }

    override func draw(_ dirtyRect: NSRect) {
        let c = hovering ? hoverColor : color
        let symbol = collapsed ? "chevron.right" : "chevron.down"
        let config = NSImage.SymbolConfiguration(pointSize: font.pointSize - 2, weight: .semibold)
        if let img = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?.withSymbolConfiguration(config) {
            let tinted = NSImage(size: img.size, flipped: false) { r in
                img.draw(in: r)
                c.set()
                r.fill(using: .sourceAtop)
                return true
            }
            let s = img.size
            tinted.draw(in: NSRect(x: ((chevronWidth - s.width) / 2).rounded(), y: ((bounds.height - s.height) / 2).rounded(),
                                   width: s.width, height: s.height))
        }
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: c]
        let h = font.ascender - font.descender
        (label as NSString).draw(at: NSPoint(x: chevronWidth + 6, y: ((bounds.height - h) / 2).rounded()), withAttributes: attrs)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        // Only the chevron and label take clicks; the rest of the row is the text view's.
        guard let sv = superview else { return nil }
        let p = convert(point, from: sv)
        return p.x >= 0 && p.x <= contentWidth && p.y >= 0 && p.y <= bounds.height ? self : nil
    }

    override func mouseDown(with event: NSEvent) {}

    override func mouseUp(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if bounds.contains(p) { onClick?() }
    }

    override func resetCursorRects() {
        addCursorRect(NSRect(x: 0, y: 0, width: min(bounds.width, contentWidth), height: bounds.height), cursor: .pointingHand)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for t in trackingAreas { removeTrackingArea(t) }
        addTrackingArea(NSTrackingArea(rect: NSRect(x: 0, y: 0, width: min(bounds.width, contentWidth), height: bounds.height),
                                       options: [.mouseEnteredAndExited, .activeAlways], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { hovering = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovering = false; needsDisplay = true }

    override func accessibilityPerformPress() -> Bool { onClick?(); return true }
}
