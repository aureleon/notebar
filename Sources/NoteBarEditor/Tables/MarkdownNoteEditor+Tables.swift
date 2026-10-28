import AppKit
import NoteBarCore

/// GFM pipe tables in Standard notes.
///
/// The storage keeps the raw markdown rows. While the caret is outside a table (or the editor is not
/// focused), the table is "collapsed": `NoteLayoutManager` hides its glyphs, gives its first row's
/// line the height of the rendered grid and its other rows no height, and a `TableScrollView` over
/// that line draws the grid (scrolling sideways when it is wider than the card). Moving the caret into
/// the table (click, arrows, vim j / k) shows the raw rows for editing.
extension MarkdownNoteEditor {
    static let tableMarginTop: CGFloat = 4
    static let tableMarginBottom: CGFloat = 6

    // MARK: Models

    /// The tables of the note (cached until the next text edit).
    func tableModels() -> [TableModel] {
        if let c = tableModelCache { return c }
        guard mode == .standard else { tableModelCache = []; return [] }
        let lines = currentLines()
        let s = storageString
        var out: [TableModel] = []
        var i = 0
        while i < lines.count {
            let first = lines[i]
            guard first.kind == .table, first.tableRow == 0, i + 1 < lines.count else { i += 1; continue }
            var j = i
            while j + 1 < lines.count, lines[j + 1].table == first.table { j += 1 }
            let aligns = TableSyntax.delimiterAlignments(s, lines[i + 1].range) ?? []
            var rows: [[TableCell]] = []
            for k in i...j where lines[k].tableRow != 1 {
                let row = TableSyntax.row(s, lines[k].range)
                rows.append(aligns.indices.map { c in
                    c < row.cells.count
                        ? makeTableCell(s, row.cells[c], header: k == i, alignment: aligns[c])
                        : TableCell(text: NSAttributedString(), storageIndex: [], range: NSRange(location: lines[k].range.end, length: 0))
                })
            }
            let range = NSRange(location: first.range.location, length: lines[j].range.end - first.range.location)
            out.append(TableModel(ordinal: first.table, range: range, alignments: aligns, rows: rows))
            i = j + 1
        }
        tableModelCache = out
        return out
    }

    /// The rendered text of one cell: the inline styling of a paragraph, without the markers.
    func makeTableCell(_ s: NSString, _ range: NSRange, header: Bool, alignment: TableAlignment) -> TableCell {
        guard range.length > 0 else { return TableCell(text: NSAttributedString(), storageIndex: [], range: range) }
        let st = style
        let line = MarkdownLine(range: range, fullRange: range, kind: .paragraph, indent: 0,
                                markerRange: NSRange(location: range.location, length: 0))
        let para = NSMutableParagraphStyle()
        para.lineBreakMode = .byWordWrapping
        para.alignment = alignment == .center ? .center : alignment == .right ? .right : .natural
        let out = NSMutableAttributedString()
        var index: [Int] = []
        for (r, a) in styler.runs(for: line, in: textStorage, string: s) where a[.nbMarker] == nil && a[.attachment] == nil {
            var font = a[.font] as? NSFont ?? st.bodyFont
            if header { font = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask) }
            var attrs: [NSAttributedString.Key: Any] = [.paragraphStyle: para, .font: font]
            attrs[.foregroundColor] = (a[.nbSwatchText] as? NSColor) ?? (a[.foregroundColor] as? NSColor) ?? st.text
            for k in [NSAttributedString.Key.strikethroughStyle, .underlineStyle] { if let v = a[k] { attrs[k] = v } }
            if let h = a[.nbHighlight] { attrs[.backgroundColor] = h }
            if let link = a[.link] { attrs[.link] = link; attrs[.foregroundColor] = st.link }
            out.append(NSAttributedString(string: s.substring(with: r), attributes: attrs))
            index.append(contentsOf: r.location..<r.end)
        }
        return TableCell(text: out, storageIndex: index, range: range)
    }

    /// Column widths and row heights at the current width (cached until the tables change).
    func gridLayout(for m: TableModel) -> TableGridLayout {
        let w = container.size.width
        if let c = tableLayoutCache[m.ordinal], c.width == w { return c.layout }
        let lineHeight = ceil(layoutManagerNB.defaultLineHeight(for: style.bodyFont))
        let l = TableGridLayout.make(m, width: w, lineHeight: lineHeight)
        tableLayoutCache[m.ordinal] = (w, l)
        return l
    }

    // MARK: Collapse

    /// Tables the selection touches (shown as raw rows). None when the editor is not focused.
    func expandedTableOrdinals() -> Set<Int> {
        guard isEditingFocused else { return [] }
        let lines = currentLines()
        guard !lines.isEmpty else { return [] }
        let sel = textView.selectedRange()
        let i0 = BlockScanner.lineIndex(in: lines, containing: sel.location)
        let i1 = max(i0, BlockScanner.lineIndex(in: lines, containing: sel.end))
        var out = Set<Int>()
        for i in i0...i1 where i < lines.count && lines[i].table >= 0 { out.insert(lines[i].table) }
        return out
    }

    private func collapsedTableValues(_ models: [TableModel]) -> Set<Int> {
        let expanded = expandedTableOrdinals()
        return Set(models.filter { !expanded.contains($0.ordinal) }.map { $0.ordinal + 1 })
    }

    /// Selection or focus changed: collapse / expand the tables it left / entered.
    func updateTableCollapse() {
        // Typing with an input method: keep the table as it is until the text is committed.
        guard !textView.hasMarkedText() else { return }
        let models = tableModels()
        let new = collapsedTableValues(models)
        let old = layoutManagerNB.collapsedTables
        guard new != old else { return }
        layoutManagerNB.collapsedTables = new
        for m in models where old.contains(m.ordinal + 1) != new.contains(m.ordinal + 1) { invalidateTable(m) }
        layoutDidChange()
    }

    /// After a restyle: when the tables' text changed, rebuild their grids and lay them out again.
    func tablesDidChange() {
        let models = tableModels()
        let s = storageString
        let signature = models.map { s.substring(with: $0.range) }
        guard signature != tableSignature else { return }
        tableSignature = signature
        tableLayoutCache = [:]
        if !textView.hasMarkedText() { layoutManagerNB.collapsedTables = collapsedTableValues(models) }
        for m in models { invalidateTable(m) }
        for v in tableViews { v.configuredKey = nil }
    }

    /// Theme / appearance / font size changed: rebuild every grid.
    func resetTables() {
        tableModelCache = nil
        tableLayoutCache = [:]
        tableSignature = []
        for v in tableViews { v.configuredKey = nil }
    }

    private func invalidateTable(_ m: TableModel) {
        let len = textStorage.length
        let r = NSIntersectionRange(NSRange(location: m.range.location, length: m.range.length + 1), NSRange(location: 0, length: len))
        guard r.length > 0 else { return }
        layoutManagerNB.invalidateGlyphs(forCharacterRange: r, changeInLength: 0, actualCharacterRange: nil)
        layoutManagerNB.invalidateLayout(forCharacterRange: r, actualCharacterRange: nil)
        layoutManagerNB.invalidateDisplay(forCharacterRange: r)
    }

    /// `NoteLayoutManager.collapsedTableLineHeight`: the grid (plus margins) on the first row, nothing on the others.
    func collapsedTableLineHeight(at ci: Int) -> CGFloat? {
        guard let m = tableModels().first(where: { ci >= $0.range.location && ci <= $0.range.end }) else { return nil }
        guard ci == m.range.location else { return 0 }
        return gridLayout(for: m).size.height + Self.tableMarginTop + Self.tableMarginBottom
    }

    // MARK: Grid views

    /// Puts a grid view over the first line of every collapsed table.
    func positionTableViews() {
        let models = mode == .standard ? tableModels().filter { layoutManagerNB.collapsedTables.contains($0.ordinal + 1) } : []
        guard !models.isEmpty || !tableViews.isEmpty else { return }
        while tableViews.count > models.count { tableViews.removeLast().removeFromSuperview() }
        while tableViews.count < models.count {
            let v = TableScrollView(frame: .zero)
            v.grid.onClick = { [weak self] index, link, event in self?.tableClicked(at: index, link: link, event: event) }
            textView.addSubview(v)
            tableViews.append(v)
        }
        guard !models.isEmpty else { return }
        let lm = layoutManagerNB
        lm.ensureLayout(for: container)
        let origin = textView.textContainerOrigin
        let s = storageString
        for (v, m) in zip(tableViews, models) {
            let grid = gridLayout(for: m)
            let key = "\(m.ordinal)|\(s.substring(with: m.range))|\(grid.columns)|\(grid.rows)|\(style.isDark)"
            if v.configuredKey != key {
                v.configure(model: m, grid: grid, border: style.ruleColor, header: style.codeBackground)
                v.configuredKey = key
            }
            let g = lm.glyphIndexForCharacter(at: m.range.location)
            guard g < lm.numberOfGlyphs else { v.isHidden = true; continue }
            let frag = lm.lineFragmentRect(forGlyphAt: g, effectiveRange: nil)
            let f = NSRect(x: origin.x, y: origin.y + frag.minY + Self.tableMarginTop,
                           width: container.size.width, height: grid.size.height)
            v.isHidden = false
            if v.frame != f { v.frame = f }
        }
    }

    /// A click on a grid: open the link there, else edit the table with the caret on the clicked character.
    func tableClicked(at index: Int, link: URL?, event: NSEvent) {
        if let link, event.clickCount == 1, event.modifierFlags.intersection([.shift, .option, .control]).isEmpty {
            _ = textView(textView, clickedOnLink: link, at: index)
            return
        }
        window?.makeFirstResponder(textView)
        textView.setSelectedRange(NSRange(location: min(max(0, index), textStorage.length), length: 0))
        textView.scrollRangeToVisible(textView.selectedRange())
    }

    /// True when `p` (text view coordinates) is on a link in a rendered table.
    /// For checks: link rects of the first rendered table (grid coordinates).
    public var tableLinkRectsForTesting: [NSRect] { tableViews.first { !$0.isHidden }?.grid.linkRects ?? [] }

    /// For checks: `isTableScroller(at:)`.
    public func isTableScrollerForTesting(at p: NSPoint) -> Bool { isTableScroller(at: p) }

    /// Frames (text view coordinates) of the tables drawn as grids.
    var visibleTableFrames: [NSRect] { tableViews.filter { !$0.isHidden }.map(\.frame) }

    /// True when `p` (text view coordinates) is on the scroll bar of a table that scrolls sideways.
    func isTableScroller(at p: NSPoint) -> Bool {
        for v in tableViews where !v.isHidden && v.frame.contains(p) {
            return v.scrollerFrame.map { $0.contains(v.convert(p, from: textView)) } ?? false
        }
        return false
    }

    func isTableLink(at p: NSPoint) -> Bool {
        for v in tableViews where !v.isHidden && v.frame.contains(p) {
            return v.grid.isLink(at: v.grid.convert(p, from: textView))
        }
        return false
    }

    /// For checks: the rendered tables (grid view frames in text view coordinates and their cell texts).
    public var renderedTablesForTesting: [(frame: NSRect, documentWidth: CGFloat, cells: [[String]])] {
        tableViews.filter { !$0.isHidden }.map { v in
            (v.frame, v.grid.frame.width, v.grid.model?.rows.map { $0.map(\.text.string) } ?? [])
        }
    }

    /// For checks: clicks the rendered table `table` at the center of cell (`row`, `column`).
    public func clickTableCellForTesting(table: Int, row: Int, column: Int) {
        let visible = tableViews.filter { !$0.isHidden }
        guard table < visible.count, let ev = NSEvent.mouseEvent(with: .leftMouseDown, location: .zero, modifierFlags: [], timestamp: 0,
                                                                 windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 0)
        else { return }
        let v = visible[table]
        let r = v.grid.grid.cellRect(row: row, column: column)
        if let h = v.grid.hit(at: NSPoint(x: r.minX + TableGridLayout.padX + 1, y: r.midY)) {
            tableClicked(at: h.storageIndex, link: nil, event: ev)
        }
    }
}
