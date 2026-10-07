import Foundation

/// Pure list behaviors: Enter continues / ends lists, Tab / Shift-Tab indent list items, code auto-indent.
public enum ListEditing {
    /// Enter key. Returns nil when the default newline should be inserted.
    public static func newline(text: String, selection sel: NSRange) -> TextEditResult? {
        guard sel.length == 0 else { return nil }
        let ns = text as NSString
        let lines = BlockScanner.scan(ns)
        let line = lines[BlockScanner.lineIndex(in: lines, containing: sel.location)]
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
            let markerText = ns.substring(with: line.markerRange)
            let next: String
            switch line.kind {
            case .bullet:
                next = String(markerText.prefix(1)) + " "
            case .numbered(let n):
                let delim = markerText.contains(")") ? ")" : "."
                next = "\(n + 1)\(delim) "
            case .checklist:
                let bullet = markerText.first.map { "-*+".contains($0) ? String($0) : "-" } ?? "-"
                next = "\(bullet) [ ] "
            default:
                next = markerText.hasSuffix(" ") ? markerText : markerText + " "
            }
            let insert = "\n" + indent + next
            let out = FormatEditing.apply([TextEdit(range: sel, replacement: insert)], to: text)
            return TextEditResult(text: out, selection: NSRange(location: caret + (insert as NSString).length, length: 0))
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
