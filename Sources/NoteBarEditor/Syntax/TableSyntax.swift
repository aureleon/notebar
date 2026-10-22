import Foundation

/// Column alignment from a table's delimiter row (`:---` left, `:---:` center, `---:` right).
public enum TableAlignment: Equatable, Sendable {
    case none, left, center, right
}

/// GFM pipe tables: cell and delimiter-row parsing on UTF-16 strings (raw markdown or the editor's storage).
///
/// A table is a header row, a delimiter row with the same number of cells, then body rows until a
/// line without a pipe (or a blank line, or another block). Rows may start with up to 3 spaces.
/// `\|` is an escaped pipe inside a cell.
public enum TableSyntax {
    static let pipe: unichar = 0x7C

    /// One row split into cells.
    public struct Row: Equatable, Sendable {
        /// Cell text without the pipes and the blanks around it (may be empty).
        public var cells: [NSRange]
        /// Unescaped pipe characters of the row.
        public var pipes: [Int]
    }

    /// Splits `range` (one line, no terminator) into cells.
    public static func row(_ s: NSString, _ range: NSRange) -> Row {
        var cells: [NSRange] = []
        var pipes: [Int] = []
        let end = range.end
        var i = range.location
        while i < end, UC.isSpaceOrTab(s.character(at: i)) { i += 1 }
        if i < end, s.character(at: i) == pipe { pipes.append(i); i += 1 }
        var cellStart = i
        func trimmed(_ a: Int, _ b: Int) -> NSRange {
            var a = a, b = b
            while a < b, UC.isWhitespace(s.character(at: a)) { a += 1 }
            while b > a, UC.isWhitespace(s.character(at: b - 1)) { b -= 1 }
            return NSRange(location: a, length: b - a)
        }
        while i < end {
            let c = s.character(at: i)
            if c == UC.backslash, i + 1 < end { i += 2; continue }
            if c == pipe {
                cells.append(trimmed(cellStart, i))
                pipes.append(i)
                cellStart = i + 1
            }
            i += 1
        }
        // The text after the last pipe is a cell unless it is blank (a closing pipe).
        let last = trimmed(cellStart, end)
        if last.length > 0 || pipes.isEmpty { cells.append(last) }
        return Row(cells: cells, pipes: pipes)
    }

    /// True when the line has an unescaped pipe (every table row needs one).
    public static func hasPipe(_ s: NSString, _ range: NSRange) -> Bool {
        var i = range.location
        while i < range.end {
            let c = s.character(at: i)
            if c == UC.backslash { i += 2; continue }
            if c == pipe { return true }
            i += 1
        }
        return false
    }

    /// Leading spaces of the line (tables allow at most 3).
    static func indent(_ s: NSString, _ range: NSRange) -> Int {
        var i = range.location
        while i < range.end, s.character(at: i) == UC.space { i += 1 }
        return i - range.location
    }

    /// The column alignments when `range` is a delimiter row (`|---|:--:|`), else nil.
    public static func delimiterAlignments(_ s: NSString, _ range: NSRange) -> [TableAlignment]? {
        guard indent(s, range) <= 3, hasPipe(s, range) else { return nil }
        let r = row(s, range)
        guard !r.cells.isEmpty else { return nil }
        var out: [TableAlignment] = []
        for cell in r.cells {
            guard cell.length > 0 else { return nil }
            var a = cell.location, b = cell.end
            let left = s.character(at: a) == UC.colon
            if left { a += 1 }
            let right = b > a && s.character(at: b - 1) == UC.colon
            if right { b -= 1 }
            guard b > a else { return nil }
            for k in a..<b where s.character(at: k) != UC.dash { return nil }
            out.append(left && right ? .center : left ? .left : right ? .right : .none)
        }
        return out
    }

    /// True when `header` and `delimiter` start a table.
    static func startsTable(_ s: NSString, header: NSRange, delimiter: NSRange) -> Bool {
        guard indent(s, header) <= 3, hasPipe(s, header),
              let aligns = delimiterAlignments(s, delimiter) else { return false }
        return row(s, header).cells.count == aligns.count
    }
}
