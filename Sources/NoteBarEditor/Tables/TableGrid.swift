import AppKit

// MARK: - Model

/// One cell of a rendered table: the styled text without markdown markers, and where each of its
/// characters lives in the editor's storage (a click puts the caret there).
struct TableCell {
    var text: NSAttributedString
    /// Storage index of each UTF-16 unit of `text`.
    var storageIndex: [Int]
    /// Storage range of the cell text (empty for an empty or missing cell).
    var range: NSRange

    /// Storage index for a character index of `text` (the end of the cell past its last character).
    func storageLocation(forTextIndex i: Int) -> Int {
        guard !storageIndex.isEmpty else { return range.location }
        return i < storageIndex.count ? storageIndex[max(0, i)] : range.end
    }
}

/// A table of the note: header row first, then the body rows. Every row has `alignments.count` cells.
struct TableModel {
    var ordinal: Int
    /// Storage range from the start of the header row to the end of the last row (no terminator).
    var range: NSRange
    var alignments: [TableAlignment]
    var rows: [[TableCell]]
}

// MARK: - Layout

/// Column widths and row heights of a rendered table at a given width.
struct TableGridLayout: Equatable {
    static let padX: CGFloat = 8
    static let padY: CGFloat = 4
    /// A column is never wider than this part of the editor width (longer cells wrap).
    static let maxColumnFraction: CGFloat = 0.6
    static let minColumnWidth: CGFloat = 36

    var columns: [CGFloat]
    var rows: [CGFloat]
    var size: NSSize { NSSize(width: columns.reduce(0, +), height: rows.reduce(0, +)) }

    static func textSize(_ t: NSAttributedString, width: CGFloat) -> NSSize {
        guard t.length > 0 else { return .zero }
        let r = t.boundingRect(with: NSSize(width: width, height: .greatestFiniteMagnitude),
                               options: [.usesLineFragmentOrigin, .usesFontLeading])
        return NSSize(width: ceil(r.width), height: ceil(r.height))
    }

    /// Each column fits its longest cell, up to `maxColumnFraction` of `width`. `lineHeight`: height of an empty cell.
    static func make(_ m: TableModel, width: CGFloat, lineHeight: CGFloat) -> TableGridLayout {
        let n = m.alignments.count
        let cap = max(minColumnWidth * 2, floor(width * maxColumnFraction))
        var cols = [CGFloat](repeating: minColumnWidth, count: n)
        for row in m.rows {
            for (c, cell) in row.enumerated() where c < n {
                let natural = textSize(cell.text, width: .greatestFiniteMagnitude).width + 2 * padX
                cols[c] = max(cols[c], min(cap, natural))
            }
        }
        var rows: [CGFloat] = []
        for row in m.rows {
            var h = lineHeight
            for (c, cell) in row.enumerated() where c < n {
                h = max(h, textSize(cell.text, width: cols[c] - 2 * padX).height)
            }
            rows.append(ceil(h + 2 * padY))
        }
        return TableGridLayout(columns: cols.map { ceil($0) }, rows: rows)
    }

    /// The cell under `p` (grid coordinates), as (row, column).
    func cell(at p: NSPoint) -> (row: Int, column: Int)? {
        guard p.x >= 0, p.y >= 0 else { return nil }
        var y: CGFloat = 0, r = -1
        for (i, h) in rows.enumerated() { if p.y < y + h { r = i; break }; y += h }
        var x: CGFloat = 0, c = -1
        for (i, w) in columns.enumerated() { if p.x < x + w { c = i; break }; x += w }
        return r >= 0 && c >= 0 ? (r, c) : nil
    }

    func cellRect(row: Int, column: Int) -> NSRect {
        let x = columns.prefix(column).reduce(0, +)
        let y = rows.prefix(row).reduce(0, +)
        return NSRect(x: x, y: y, width: columns[column], height: rows[row])
    }
}

// MARK: - Views

/// Draws a table: rounded border, tinted header row, row and column lines, styled cell text.
final class TableGridView: NSView {
    var model: TableModel? { didSet { linkRectCache = nil } }
    var grid = TableGridLayout(columns: [], rows: [])
    var borderColor: NSColor = .separatorColor
    var headerColor: NSColor = .quaternaryLabelColor
    /// A click in a cell: the storage index under the pointer, or the link there.
    var onClick: ((_ storageIndex: Int, _ link: URL?, _ event: NSEvent) -> Void)?

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        guard let model, !grid.rows.isEmpty else { return }
        let size = grid.size
        let outer = NSRect(origin: .zero, size: size).insetBy(dx: 0.5, dy: 0.5)
        let shape = NSBezierPath(roundedRect: outer, xRadius: 6, yRadius: 6)
        NSGraphicsContext.saveGraphicsState()
        shape.addClip()
        headerColor.setFill()
        NSRect(x: 0, y: 0, width: size.width, height: grid.rows[0]).fill()
        borderColor.setFill()
        var y: CGFloat = 0
        for h in grid.rows.dropLast() { y += h; NSRect(x: 0, y: y - 0.5, width: size.width, height: 1).fill() }
        var x: CGFloat = 0
        for w in grid.columns.dropLast() { x += w; NSRect(x: x - 0.5, y: 0, width: 1, height: size.height).fill() }
        NSGraphicsContext.restoreGraphicsState()
        borderColor.setStroke()
        shape.lineWidth = 1
        shape.stroke()

        for (r, row) in model.rows.enumerated() where r < grid.rows.count {
            for (c, cell) in row.enumerated() where c < grid.columns.count && cell.text.length > 0 {
                let rect = grid.cellRect(row: r, column: c)
                guard rect.intersects(dirtyRect) else { continue }
                let inner = rect.insetBy(dx: TableGridLayout.padX, dy: TableGridLayout.padY)
                cell.text.draw(with: inner, options: [.usesLineFragmentOrigin, .usesFontLeading])
            }
        }
    }

    /// The text index under `p` in a cell (TextKit, same wrapping as the drawing), or nil past the text.
    func textIndex(in cell: TableCell, rect: NSRect, at p: NSPoint) -> Int? {
        guard cell.text.length > 0 else { return nil }
        let storage = NSTextStorage(attributedString: cell.text)
        let lm = NSLayoutManager()
        lm.usesFontLeading = true
        let tc = NSTextContainer(size: NSSize(width: rect.width - 2 * TableGridLayout.padX, height: .greatestFiniteMagnitude))
        tc.lineFragmentPadding = 0
        lm.addTextContainer(tc)
        storage.addLayoutManager(lm)
        let local = NSPoint(x: p.x - rect.minX - TableGridLayout.padX, y: p.y - rect.minY - TableGridLayout.padY)
        var fraction: CGFloat = 0
        let g = lm.glyphIndex(for: local, in: tc, fractionOfDistanceThroughGlyph: &fraction)
        guard g < lm.numberOfGlyphs else { return nil }
        let box = lm.boundingRect(forGlyphRange: NSRange(location: g, length: 1), in: tc)
        let ci = lm.characterIndexForGlyph(at: g)
        if box.contains(local) { return ci }
        // Beside the text: the caret goes before / after the nearest character.
        return fraction > 0.5 ? ci + 1 : ci
    }

    struct Hit { var storageIndex: Int; var link: URL? }

    func hit(at p: NSPoint) -> Hit? {
        guard let model, let (r, c) = grid.cell(at: p), r < model.rows.count, c < model.rows[r].count else { return nil }
        let cell = model.rows[r][c]
        let rect = grid.cellRect(row: r, column: c)
        guard let i = textIndex(in: cell, rect: rect, at: p) else { return Hit(storageIndex: cell.range.end, link: nil) }
        var link: URL?
        if i < cell.text.length {
            let box = rect.insetBy(dx: TableGridLayout.padX, dy: TableGridLayout.padY)
            if box.contains(p) { link = cell.text.attribute(.link, at: i, effectiveRange: nil) as? URL }
        }
        return Hit(storageIndex: cell.storageLocation(forTextIndex: i), link: link)
    }

    /// True when `p` (grid coordinates) is on a link.
    func isLink(at p: NSPoint) -> Bool { hit(at: p)?.link != nil }

    /// Rects of the link text in the cells (grid coordinates), laid out as drawn. Cached per model and layout.
    private var linkRectCache: (layout: [CGFloat], rects: [NSRect])?

    var linkRects: [NSRect] {
        let key = grid.columns + grid.rows
        if let c = linkRectCache, c.layout == key { return c.rects }
        var out: [NSRect] = []
        for (r, row) in (model?.rows ?? []).enumerated() where r < grid.rows.count {
            for (c, cell) in row.enumerated() where c < grid.columns.count && cell.text.length > 0 {
                let full = NSRange(location: 0, length: cell.text.length)
                var links: [NSRange] = []
                cell.text.enumerateAttribute(.link, in: full, options: []) { v, range, _ in if v != nil { links.append(range) } }
                guard !links.isEmpty else { continue }
                let rect = grid.cellRect(row: r, column: c)
                let storage = NSTextStorage(attributedString: cell.text)
                let lm = NSLayoutManager()
                lm.usesFontLeading = true
                let tc = NSTextContainer(size: NSSize(width: rect.width - 2 * TableGridLayout.padX, height: .greatestFiniteMagnitude))
                tc.lineFragmentPadding = 0
                lm.addTextContainer(tc)
                storage.addLayoutManager(lm)
                for l in links {
                    let gr = lm.glyphRange(forCharacterRange: l, actualCharacterRange: nil)
                    lm.enumerateEnclosingRects(forGlyphRange: gr, withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0),
                                               in: tc) { box, _ in
                        out.append(box.offsetBy(dx: rect.minX + TableGridLayout.padX, dy: rect.minY + TableGridLayout.padY))
                    }
                }
            }
        }
        linkRectCache = (key, out)
        return out
    }

    /// While the window is key: the pointing hand on links, the I-beam on the rest, the arrow (from
    /// `TableScrollView`) on the scroll bar. The rects do not overlap (see `CursorRects`).
    override func resetCursorRects() {
        let links = linkRects
        var holes = links
        if let sv = enclosingScrollView as? TableScrollView, let s = sv.scrollerFrame { holes.append(convert(s, from: sv)) }
        for r in CursorRects.subtract(holes, from: visibleRect) { addCursorRect(r, cursor: .iBeam) }
        for r in links { addCursorRect(r, cursor: .pointingHand) }
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        guard let h = hit(at: p) else { return }
        onClick?(h.storageIndex, h.link, event)
    }
}

/// Scrolls a `TableGridView` sideways. Vertical scrolling (and any scrolling when the table fits)
/// goes on to the notes list: each gesture picks one axis from its first movement.
final class TableScrollView: NSScrollView {
    let grid = TableGridView()
    private var horizontalGesture: Bool?
    /// What the grid was last configured with (skips redrawing when nothing changed).
    var configuredKey: String?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        drawsBackground = false
        contentView.drawsBackground = false
        borderType = .noBorder
        hasHorizontalScroller = true
        hasVerticalScroller = false
        autohidesScrollers = true
        scrollerStyle = .overlay
        verticalScrollElasticity = .none
        horizontalScrollElasticity = .allowed
        documentView = grid
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    var overflows: Bool { grid.frame.width > contentView.bounds.width + 0.5 }

    /// The horizontal scroll bar (own coordinates) while the table scrolls sideways, or nil.
    var scrollerFrame: NSRect? {
        guard overflows, let s = horizontalScroller, !s.isHidden else { return nil }
        return s.frame
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        if let s = scrollerFrame { addCursorRect(s, cursor: .arrow) }
    }

    override func scrollWheel(with event: NSEvent) {
        let gestureStart = event.phase == .began || event.phase == .mayBegin
        let legacy = event.phase == [] && event.momentumPhase == []
        if gestureStart || legacy { horizontalGesture = nil }
        if horizontalGesture == nil, event.scrollingDeltaX != 0 || event.scrollingDeltaY != 0 {
            horizontalGesture = overflows && abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY)
        }
        if horizontalGesture == true {
            super.scrollWheel(with: event)
        } else {
            nextResponder?.scrollWheel(with: event)
        }
    }

    func configure(model: TableModel, grid layout: TableGridLayout, border: NSColor, header: NSColor) {
        grid.model = model
        grid.grid = layout
        grid.borderColor = border
        grid.headerColor = header
        let size = layout.size
        let f = NSRect(x: 0, y: 0, width: ceil(size.width), height: ceil(size.height))
        if grid.frame != f { grid.frame = f }
        grid.needsDisplay = true
        window?.invalidateCursorRects(for: grid)
        window?.invalidateCursorRects(for: self)
    }
}
