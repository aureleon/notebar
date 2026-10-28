import Foundation

/// Pure list behaviors: Enter continues / ends lists, Tab / Shift-Tab indent list items, code auto-indent.
///
/// Sub-lines: indented text lines under a list item belong to that item (they render flush with
/// its text and move with it). Shift-Enter on an item or sub-line starts a sub-line; Enter on a
/// sub-line starts another; Enter on an empty sub-line turns it into the item's next sibling.
public enum ListEditing {
    /// A line that can belong to a list item above it: a list line, or an indented text or
    /// whitespace-only line. Never the title.
    static func isNestable(_ l: MarkdownLine) -> Bool {
        !l.isTitle && (l.kind.isList || ((l.kind == .paragraph || l.kind == .blank) && l.indent > 0))
    }

    /// True when `l` is a child of a list item at indent `base` (it follows the item or its other children).
    public static func isChildLine(_ l: MarkdownLine, base: Int) -> Bool { isNestable(l) && l.indent > base }

    /// The list item that line `i` belongs to: the nearest list line above with a smaller indent, with
    /// only nestable lines between them. nil for top-level lines.
    public static func parentItem(in lines: [MarkdownLine], of i: Int) -> Int? {
        guard i >= 0, i < lines.count, isNestable(lines[i]), lines[i].indent > 0 else { return nil }
        let ind = lines[i].indent
        var j = i - 1
        while j >= 0 {
            let l = lines[j]
            guard isNestable(l) else { return nil }
            if l.kind.isList, l.indent < ind { return j }
            j -= 1
        }
        return nil
    }

    /// The list item that line `i` is a sub-line of, or nil. A sub-line is an indented text line (or
    /// an indented whitespace-only line) below a list item with a smaller indent, with only that
    /// item's children (deeper list lines, other sub-lines) between them.
    public static func subLineOwner(in lines: [MarkdownLine], line i: Int) -> Int? {
        guard i >= 0, i < lines.count, lines[i].kind == .paragraph || lines[i].kind == .blank else { return nil }
        return parentItem(in: lines, of: i)
    }

    /// Lines of list item `i`'s children (empty when it has none, or `i` is not a list item).
    public static func childLines(in lines: [MarkdownLine], of i: Int) -> Range<Int> {
        guard i >= 0, i < lines.count, lines[i].kind.isList, !lines[i].isTitle else { return (i + 1)..<(i + 1) }
        var j = i + 1
        while j < lines.count, isChildLine(lines[j], base: lines[i].indent) { j += 1 }
        return (i + 1)..<j
    }

    /// True when list item `i` can fold: it has text (`foldKey`) and children that are not all blank.
    public static func isFoldable(in lines: [MarkdownLine], item i: Int, string ns: NSString) -> Bool {
        let c = childLines(in: lines, of: i)
        return !c.isEmpty && c.contains { lines[$0].kind != .blank } && foldKey(ns, lines[i]) != nil
    }

    /// True when a list item above line `i` (its parent, grandparent, ...) is checked.
    public static func hasCheckedAncestor(in lines: [MarkdownLine], line i: Int) -> Bool {
        var p = parentItem(in: lines, of: i)
        while let j = p {
            if case .checklist(true) = lines[j].kind { return true }
            p = parentItem(in: lines, of: j)
        }
        return false
    }

    /// Identity of a list item for its saved fold (`Note.foldOverrides`): its trimmed text. nil when empty.
    public static func foldKey(_ ns: NSString, _ line: MarkdownLine) -> String? {
        let t = FormatEditing.trimmed(ns, line.contentRange)
        guard t.length > 0 else { return nil }
        return ns.substring(with: t)
    }

    /// Marker of the item after list line `line` ("- ", "3. ", "- [ ] ").
    static func nextMarker(_ ns: NSString, _ line: MarkdownLine) -> String {
        let markerText = ns.substring(with: line.markerRange)
        switch line.kind {
        case .bullet:
            return String(markerText.prefix(1)) + " "
        case .numbered(let n):
            let delim = markerText.contains(")") ? ")" : "."
            return "\(n + 1)\(delim) "
        case .checklist:
            let bullet = markerText.first.map { "-*+".contains($0) ? String($0) : "-" } ?? "-"
            return "\(bullet) [ ] "
        default:
            return markerText.hasSuffix(" ") ? markerText : markerText + " "
        }
    }

    static func leading(_ ns: NSString, _ line: MarkdownLine) -> String {
        ns.substring(with: NSRange(location: line.range.location, length: line.indent))
    }

    static func insert(_ insert: String, at sel: NSRange, in text: String) -> TextEditResult {
        let out = FormatEditing.apply([TextEdit(range: sel, replacement: insert)], to: text)
        return TextEditResult(text: out, selection: NSRange(location: sel.location + (insert as NSString).length, length: 0))
    }

    /// Shift-Enter: on a list item (after its marker) or a sub-line, starts a sub-line of the item.
    /// nil = insert the default newline.
    public static func lineBreak(text: String, selection sel: NSRange) -> TextEditResult? {
        guard sel.length == 0 else { return nil }
        let ns = text as NSString
        let lines = BlockScanner.scan(ns)
        let li = BlockScanner.lineIndex(in: lines, containing: sel.location)
        let line = lines[li]
        if line.kind.isList, !line.isTitle {
            guard sel.location >= line.markerRange.end else { return nil }
            return insert("\n" + leading(ns, line) + "\t", at: sel, in: text)
        }
        guard subLineOwner(in: lines, line: li) != nil, sel.location >= line.range.location + line.indent else { return nil }
        return insert("\n" + leading(ns, line), at: sel, in: text)
    }

    /// Backspace at the start of a sub-line's text joins it to the line above (its indent is hidden,
    /// so deleting it bit by bit would do nothing visible). nil = default.
    public static func joinSubLine(text: String, selection sel: NSRange) -> TextEditResult? {
        guard sel.length == 0 else { return nil }
        let ns = text as NSString
        let lines = BlockScanner.scan(ns)
        let li = BlockScanner.lineIndex(in: lines, containing: sel.location)
        let line = lines[li]
        guard li > 0, subLineOwner(in: lines, line: li) != nil, sel.location == line.range.location + line.indent else { return nil }
        let end = lines[li - 1].range.end
        let out = FormatEditing.apply([TextEdit(range: NSRange(location: end, length: sel.location - end), replacement: "")], to: text)
        return TextEditResult(text: out, selection: NSRange(location: end, length: 0))
    }

    /// Enter key. Returns nil when the default newline should be inserted.
    public static func newline(text: String, selection sel: NSRange) -> TextEditResult? {
        guard sel.length == 0 else { return nil }
        let ns = text as NSString
        let lines = BlockScanner.scan(ns)
        let li = BlockScanner.lineIndex(in: lines, containing: sel.location)
        let line = lines[li]
        let caret = sel.location
        switch line.kind {
        case .bullet, .numbered, .checklist, .quote:
            guard caret >= line.markerRange.end else { return nil }
            let content = line.contentRange
            let empty = FormatEditing.trimmed(ns, content).length == 0
            if empty {
                if line.kind.isList, line.indent > 0 {
                    return outdentLine(ns, line, selection: sel)
                }
                // End the list: clear the marker line.
                let out = FormatEditing.apply([TextEdit(range: line.range, replacement: "")], to: text)
                return TextEditResult(text: out, selection: NSRange(location: line.range.location, length: 0))
            }
            let indent = ns.substring(with: NSRange(location: line.range.location, length: line.markerRange.location - line.range.location))
            return insert("\n" + indent + nextMarker(ns, line), at: sel, in: text)
        case .paragraph, .blank:
            guard let o = subLineOwner(in: lines, line: li), caret >= line.range.location + line.indent else { return nil }
            if FormatEditing.trimmed(ns, line.range).length > 0 {
                return insert("\n" + leading(ns, line), at: sel, in: text)
            }
            // Empty sub-line: becomes the owner's next sibling item.
            let owner = lines[o]
            let item = leading(ns, owner) + nextMarker(ns, owner)
            let out = FormatEditing.apply([TextEdit(range: line.range, replacement: item)], to: text)
            return TextEditResult(text: out, selection: NSRange(location: line.range.location + (item as NSString).length, length: 0))
        case .code:
            return newlineKeepingIndent(text: text, selection: sel)
        default:
            return nil
        }
    }

    /// Enter in code: keeps the leading whitespace of the current line. Nil if there is none.
    public static func newlineKeepingIndent(text: String, selection sel: NSRange) -> TextEditResult? {
        let ns = text as NSString
        let lineRange = ns.lineRange(for: NSRange(location: sel.location, length: 0))
        var e = lineRange.location
        while e < sel.location, UC.isSpaceOrTab(ns.character(at: e)) { e += 1 }
        guard e > lineRange.location else { return nil }
        let insert = "\n" + ns.substring(with: NSRange(location: lineRange.location, length: e - lineRange.location))
        let out = FormatEditing.apply([TextEdit(range: sel, replacement: insert)], to: text)
        return TextEditResult(text: out, selection: NSRange(location: sel.location + (insert as NSString).length, length: 0))
    }

    /// Tab / Shift-Tab on list items. Returns nil when no selected line is a list item
    /// (the caller then inserts a normal tab, or ignores Shift-Tab).
    public static func indent(text: String, selection sel: NSRange, outdent: Bool, unit: String = "\t") -> TextEditResult? {
        let ns = text as NSString
        let lines = BlockScanner.scan(ns)
        let idx = FormatEditing.targetLines(lines, sel).filter { lines[$0].kind.isList }
        guard !idx.isEmpty else { return nil }
        var edits: [TextEdit] = []
        for i in idx {
            let line = lines[i]
            if outdent {
                if let r = outdentRange(ns, line.range) { edits.append(TextEdit(range: r, replacement: "")) }
            } else {
                edits.append(TextEdit(range: NSRange(location: line.range.location, length: 0), replacement: unit))
            }
        }
        return FormatEditing.result(text, edits, sel, startAfter: true, endAfter: true)
    }

    /// Code mode Tab: indent all selected lines (multi-line selection) or insert spaces up to the next tab stop.
    public static func codeIndent(text: String, selection sel: NSRange, outdent: Bool, width: Int = 4) -> TextEditResult {
        let ns = text as NSString
        let lines = BlockScanner.scan(ns)
        let idx = FormatEditing.targetLines(lines, sel)
        if !outdent, sel.length == 0 {
            let lineStart = ns.lineRange(for: NSRange(location: sel.location, length: 0)).location
            let col = sel.location - lineStart
            let n = width - (col % width)
            let spaces = String(repeating: " ", count: n)
            let out = FormatEditing.apply([TextEdit(range: sel, replacement: spaces)], to: text)
            return TextEditResult(text: out, selection: NSRange(location: sel.location + n, length: 0))
        }
        var edits: [TextEdit] = []
        for i in idx {
            let line = lines[i]
            if outdent {
                var e = line.range.location
                while e < line.range.end, e - line.range.location < width, ns.character(at: e) == UC.space { e += 1 }
                if e == line.range.location, line.range.length > 0, ns.character(at: e) == UC.tab { e += 1 }
                if e > line.range.location { edits.append(TextEdit(range: NSRange(location: line.range.location, length: e - line.range.location), replacement: "")) }
            } else if line.range.length > 0 || idx.count == 1 {
                edits.append(TextEdit(range: NSRange(location: line.range.location, length: 0), replacement: String(repeating: " ", count: width)))
            }
        }
        return FormatEditing.result(text, edits, sel, startAfter: sel.length == 0, endAfter: true)
    }

    static func outdentRange(_ ns: NSString, _ r: NSRange) -> NSRange? {
        guard r.length > 0 else { return nil }
        if ns.character(at: r.location) == UC.tab { return NSRange(location: r.location, length: 1) }
        var e = r.location
        while e < r.end, e - r.location < 4, ns.character(at: e) == UC.space { e += 1 }
        return e > r.location ? NSRange(location: r.location, length: e - r.location) : nil
    }

    static func outdentLine(_ ns: NSString, _ line: MarkdownLine, selection sel: NSRange) -> TextEditResult? {
        guard let r = outdentRange(ns, line.range) else { return nil }
        let edits = [TextEdit(range: r, replacement: "")]
        return FormatEditing.result(ns as String, edits, sel)
    }
}
