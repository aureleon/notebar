import AppKit

/// TextKit 1 layout manager for note editors:
/// - hides markdown markers (null glyphs) in invisible-markdown mode unless they are "revealed" (caret inside the span),
/// - gives code-fence lines a fixed bar height, draws list bullets,
/// - draws code block boxes, rounded highlights, `#hex` swatches and horizontal rules.
final class NoteLayoutManager: NSLayoutManager, NSLayoutManagerDelegate {
    /// Invisible markdown on/off.
    var hideMarkup = false
    /// Character ranges whose markers stay visible (spans containing the caret).
    var revealed: [NSRange] = []
    var codeBlockColor: NSColor = .quaternaryLabelColor
    var ruleColor: NSColor = .separatorColor
    var swatchDiameter: CGFloat = 9
    var swatchGap: CGFloat = 3
    /// Height of a code fence line, the same with backticks shown or hidden (nothing moves).
    var fenceBarHeight: CGFloat = 16
    /// `nbTable` values (ordinal + 1) of the tables drawn as a grid: their glyphs are hidden, the first
    /// row's line gets the grid's height and the other rows' lines get none.
    var collapsedTables: Set<Int> = []
    /// Height of the line starting at a storage index of a collapsed table (the grid height for the
    /// first row, 0 for the others). nil: lay the line out as text.
    var collapsedTableLineHeight: ((Int) -> CGFloat?)?
    /// Folded completed checklist items (storage ranges, sorted): their glyphs are hidden, the first
    /// line gets `completedRowHeight` (the "N completed" row sits there) and the others get none.
    var collapsedChecks: [NSRange] = []
    var completedRowHeight: CGFloat = 20
    /// Folded children of list items (storage ranges, sorted, never inside `collapsedChecks`): hidden the
    /// same way, with a slim first line (`itemFoldRowHeight`) for the ▸ chevron.
    var collapsedItems: [NSRange] = []
    var itemFoldRowHeight: CGFloat = 10

    private var bulletGlyphs: [String: CGGlyph] = [:]

    override init() {
        super.init()
        delegate = self
        allowsNonContiguousLayout = false
        usesFontLeading = true
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    func isRevealed(_ index: Int) -> Bool {
        for r in revealed where index >= r.location && index <= r.end { return true }
        return false
    }

    private func isHidden(_ index: Int, _ storage: NSTextStorage) -> Bool {
        if isInCollapsedTable(index, storage) || collapsedFold(at: index) != nil { return true }
        if storage.attribute(.nbIndent, at: index, effectiveRange: nil) != nil { return true }
        return hideMarkup && storage.attribute(.nbMarker, at: index, effectiveRange: nil) != nil && !isRevealed(index)
    }

    func isInCollapsedTable(_ index: Int, _ storage: NSTextStorage) -> Bool {
        guard !collapsedTables.isEmpty, let v = storage.attribute(.nbTable, at: index, effectiveRange: nil) as? Int else { return false }
        return collapsedTables.contains(v)
    }

    /// The folded range of completed items holding storage index `index`.
    func collapsedCheck(at index: Int) -> NSRange? {
        for r in collapsedChecks where index >= r.location && index < r.end { return r }
        return nil
    }

    /// The folded range (completed items or an item's children) holding `index`, and its first line's height.
    func collapsedFold(at index: Int) -> (range: NSRange, rowHeight: CGFloat)? {
        if let r = collapsedCheck(at: index) { return (r, completedRowHeight) }
        for r in collapsedItems where index >= r.location && index < r.end { return (r, itemFoldRowHeight) }
        return nil
    }

    private func bulletGlyph(for font: NSFont) -> CGGlyph? {
        let key = "\(font.fontName)|\(font.pointSize)"
        if let g = bulletGlyphs[key] { return g }
        var chars: [UniChar] = [0x2022]
        var glyph: CGGlyph = 0
        guard CTFontGetGlyphsForCharacters(font as CTFont, &chars, &glyph, 1), glyph != 0 else { return nil }
        bulletGlyphs[key] = glyph
        return glyph
    }

    // MARK: Glyph generation

    func layoutManager(_ layoutManager: NSLayoutManager, shouldGenerateGlyphs glyphs: UnsafePointer<CGGlyph>,
                       properties props: UnsafePointer<NSLayoutManager.GlyphProperty>,
                       characterIndexes charIndexes: UnsafePointer<Int>, font aFont: NSFont,
                       forGlyphRange glyphRange: NSRange) -> Int {
        guard let storage = textStorage, glyphRange.length > 0 else { return 0 }
        let count = glyphRange.length
        let first = charIndexes[0], last = charIndexes[count - 1]
        guard first < storage.length else { return 0 }
        let charRange = NSRange(location: first, length: min(storage.length, last + 1) - first)
        var interesting = (collapsedChecks + collapsedItems).contains { NSIntersectionRange($0, charRange).length > 0 }
        if !interesting { storage.enumerateAttributes(in: charRange, options: [.longestEffectiveRangeNotRequired]) { a, _, stop in
            if (hideMarkup && a[.nbMarker] != nil) || a[.nbBullet] != nil || a[.nbIndent] != nil
                || (a[.nbTable] as? Int).map({ self.collapsedTables.contains($0) }) == true {
                interesting = true; stop.pointee = true
            }
        } }
        guard interesting else { return 0 }

        var newGlyphs = Array(UnsafeBufferPointer(start: glyphs, count: count))
        var newProps = Array(UnsafeBufferPointer(start: props, count: count))
        var changed = false
        for i in 0..<count {
            let ci = charIndexes[i]
            guard ci < storage.length, !newProps[i].contains(.controlCharacter) else { continue }
            if isHidden(ci, storage) {
                newProps[i] = .controlCharacter
                changed = true
            } else if storage.attribute(.nbBullet, at: ci, effectiveRange: nil) != nil, let g = bulletGlyph(for: aFont) {
                newGlyphs[i] = g
                changed = true
            }
        }
        guard changed else { return 0 }
        newGlyphs.withUnsafeBufferPointer { g in
            newProps.withUnsafeBufferPointer { p in
                layoutManager.setGlyphs(g.baseAddress!, properties: p.baseAddress!, characterIndexes: charIndexes,
                                        font: aFont, forGlyphRange: glyphRange)
            }
        }
        return count
    }

    func layoutManager(_ layoutManager: NSLayoutManager, shouldUse action: NSLayoutManager.ControlCharacterAction,
                       forControlCharacterAt charIndex: Int) -> NSLayoutManager.ControlCharacterAction {
        if let storage = textStorage, charIndex < storage.length, isHidden(charIndex, storage),
           !UC.isLineTerminator((storage.string as NSString).character(at: charIndex)) {
            return .zeroAdvancement
        }
        return action
    }

    func layoutManager(_ layoutManager: NSLayoutManager,
                       shouldSetLineFragmentRect lineFragmentRect: UnsafeMutablePointer<NSRect>,
                       lineFragmentUsedRect: UnsafeMutablePointer<NSRect>,
                       baselineOffset: UnsafeMutablePointer<CGFloat>,
                       in textContainer: NSTextContainer, forGlyphRange glyphRange: NSRange) -> Bool {
        guard let storage = textStorage, glyphRange.length > 0 else { return false }
        let ci = characterIndexForGlyph(at: glyphRange.location)
        guard ci < storage.length else { return false }
        if let (r, rowHeight) = collapsedFold(at: ci) {
            let h = ci == r.location ? rowHeight : 0
            lineFragmentRect.pointee.size.height = h
            // The used rect would start below the head line's paragraph spacing (the row's space).
            lineFragmentUsedRect.pointee = NSRect(x: lineFragmentRect.pointee.minX, y: lineFragmentRect.pointee.minY,
                                                  width: h == 0 ? 0 : lineFragmentUsedRect.pointee.width, height: h)
            baselineOffset.pointee = 0
            return true
        }
        if isInCollapsedTable(ci, storage), let h = collapsedTableLineHeight?(ci) {
            lineFragmentRect.pointee.size.height = h
            lineFragmentUsedRect.pointee.size.height = h
            if h == 0 { lineFragmentUsedRect.pointee.size.width = 0 }
            baselineOffset.pointee = 0
            return true
        }
        guard storage.attribute(.nbFence, at: ci, effectiveRange: nil) != nil else { return false }
        let h = fenceBarHeight
        let font = storage.attribute(.font, at: ci, effectiveRange: nil) as? NSFont ?? .monospacedSystemFont(ofSize: 11, weight: .regular)
        let textH = font.ascender - font.descender
        lineFragmentRect.pointee.size.height = h
        lineFragmentUsedRect.pointee.size.height = h
        baselineOffset.pointee = ((h - textH) / 2 + font.ascender).rounded()
        return true
    }

    // MARK: Drawing

    override func showAttachmentCell(_ cell: NSCell, in rect: NSRect, characterIndex attachmentIndex: Int) {
        // Folded completed items: their checkboxes are not drawn either.
        if collapsedFold(at: attachmentIndex) != nil { return }
        super.showAttachmentCell(cell, in: rect, characterIndex: attachmentIndex)
    }

    override func drawStrikethrough(forGlyphRange glyphRange: NSRange, strikethroughType: NSUnderlineStyle, baselineOffset: CGFloat,
                                    lineFragmentRect lineRect: NSRect, lineFragmentGlyphRange lineGlyphRange: NSRange,
                                    containerOrigin: NSPoint) {
        if !collapsedChecks.isEmpty || !collapsedItems.isEmpty,
           collapsedFold(at: characterIndexForGlyph(at: glyphRange.location)) != nil { return }
        super.drawStrikethrough(forGlyphRange: glyphRange, strikethroughType: strikethroughType, baselineOffset: baselineOffset,
                                lineFragmentRect: lineRect, lineFragmentGlyphRange: lineGlyphRange, containerOrigin: containerOrigin)
    }

    override func drawBackground(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        super.drawBackground(forGlyphRange: glyphsToShow, at: origin)
        guard let storage = textStorage, let container = textContainers.first, storage.length > 0 else { return }
        let charRange = characterRange(forGlyphRange: glyphsToShow, actualGlyphRange: nil)
        let all = NSRange(location: 0, length: storage.length)

        // Code block boxes.
        var drawn = Set<Int>()
        storage.enumerateAttribute(.nbCodeBlock, in: charRange, options: []) { value, range, _ in
            guard value != nil else { return }
            var full = NSRange()
            storage.attribute(.nbCodeBlock, at: range.location, longestEffectiveRange: &full, in: all)
            guard drawn.insert(full.location).inserted else { return }
            let gr = glyphRange(forCharacterRange: full, actualCharacterRange: nil)
            guard gr.length > 0 else { return }
            let top = lineFragmentRect(forGlyphAt: gr.location, effectiveRange: nil)
            let bottom = lineFragmentRect(forGlyphAt: gr.end - 1, effectiveRange: nil)
            let rect = NSRect(x: origin.x, y: origin.y + top.minY, width: container.size.width, height: bottom.maxY - top.minY)
            codeBlockColor.setFill()
            NSBezierPath(roundedRect: rect, xRadius: 8, yRadius: 8).fill()
        }

        // Highlights (==marked==): rounded pills behind the text.
        storage.enumerateAttribute(.nbHighlight, in: charRange, options: []) { value, range, _ in
            guard let color = value as? NSColor else { return }
            let gr = glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            let font = storage.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont ?? .systemFont(ofSize: NSFont.systemFontSize)
            color.setFill()
            enumerateLineFragments(forGlyphRange: gr) { lineRect, _, tc, lineGlyphs, _ in
                var r = NSIntersectionRange(gr, lineGlyphs)
                // Skip suppressed / control glyphs at the ends.
                while r.length > 0, self.propertyForGlyph(at: r.location) == .null || self.propertyForGlyph(at: r.location).contains(.controlCharacter) {
                    r = NSRange(location: r.location + 1, length: r.length - 1)
                }
                while r.length > 0, self.propertyForGlyph(at: r.end - 1) == .null || self.propertyForGlyph(at: r.end - 1).contains(.controlCharacter) {
                    r.length -= 1
                }
                guard r.length > 0 else { return }
                let b = self.boundingRect(forGlyphRange: r, in: tc)
                let baseline = lineRect.minY + self.location(forGlyphAt: r.location).y
                let top = baseline - font.ascender - 1
                let h = font.ascender - font.descender + 2
                let pill = NSRect(x: b.minX - 2 + origin.x, y: top + origin.y, width: b.width + 4, height: h)
                NSBezierPath(roundedRect: pill, xRadius: 4, yRadius: 4).fill()
            }
        }

        // Horizontal rules.
        storage.enumerateAttribute(.nbRule, in: charRange, options: []) { value, range, _ in
            guard value != nil else { return }
            let gr = glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            guard gr.length > 0 else { return }
            let lf = lineFragmentRect(forGlyphAt: gr.location, effectiveRange: nil)
            let y = (origin.y + lf.minY + (lf.height - 2) / 2).rounded() + 0.5
            ruleColor.setFill()
            NSRect(x: origin.x, y: y, width: container.size.width, height: 1).fill()
        }
    }

    override func drawGlyphs(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        super.drawGlyphs(forGlyphRange: glyphsToShow, at: origin)
        guard let storage = textStorage, storage.length > 0 else { return }
        let charRange = characterRange(forGlyphRange: glyphsToShow, actualGlyphRange: nil)
        // #hex swatches: circle + '#' drawn in the widened slot of the '#' glyph.
        storage.enumerateAttribute(.nbSwatch, in: charRange, options: []) { value, range, _ in
            guard let color = value as? NSColor else { return }
            let g = glyphIndexForCharacter(at: range.location)
            guard g < numberOfGlyphs, propertyForGlyph(at: g) != .null else { return }
            let lf = lineFragmentRect(forGlyphAt: g, effectiveRange: nil)
            let loc = location(forGlyphAt: g)
            let font = storage.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont ?? .systemFont(ofSize: NSFont.systemFontSize)
            let textColor = storage.attribute(.nbSwatchText, at: range.location, effectiveRange: nil) as? NSColor ?? .labelColor
            let d = swatchDiameter
            let x = origin.x + lf.minX + loc.x + 0.5
            let baseline = origin.y + lf.minY + loc.y
            let cy = baseline - font.xHeight / 2 - 0.5
            let rect = NSRect(x: x, y: cy - d / 2, width: d, height: d)
            let path = NSBezierPath(ovalIn: rect)
            color.setFill()
            path.fill()
            NSColor.black.withAlphaComponent(0.18).setStroke()
            path.lineWidth = 0.75
            path.stroke()
            ("#" as NSString).draw(at: NSPoint(x: x + d + swatchGap - 0.5, y: baseline - font.ascender),
                                   withAttributes: [.font: font, .foregroundColor: textColor])
        }
    }
}
