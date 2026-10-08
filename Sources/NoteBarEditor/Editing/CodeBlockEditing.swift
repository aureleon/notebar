import Foundation

/// Pure fenced-code-block behaviors (Standard notes). Each returns nil when the key keeps its normal
/// meaning. A result with unchanged text only moves the caret (or blocks the key).
public enum CodeBlockEditing {
    struct Block {
        /// Line indexes of the opening fence, the content lines and the closing fence (nil = unclosed).
        var open: Int
        var close: Int?
        var last: Int
        var content: ClosedRange<Int>? {
            let e = close.map { $0 - 1 } ?? last
            return e >= open + 1 ? (open + 1)...e : nil
        }
    }

    static func block(_ lines: [MarkdownLine], containing i: Int) -> Block? {
        let id = lines[i].codeBlock
        guard id >= 0 else { return nil }
        var a = i, b = i
        while a > 0, lines[a - 1].codeBlock == id { a -= 1 }
        while b + 1 < lines.count, lines[b + 1].codeBlock == id { b += 1 }
        guard lines[a].kind == .fence else { return nil }
        let close = b > a && lines[b].kind == .fence ? b : nil
        return Block(open: a, close: close, last: b)
    }

    static func isBlank(_ ns: NSString, _ r: NSRange) -> Bool {
        for k in r.location..<r.end where !UC.isWhitespace(ns.character(at: k)) { return false }
        return true
    }

    static func edit(_ text: String, _ r: NSRange, _ s: String, caret: Int) -> TextEditResult {
        let out = (text as NSString).replacingCharacters(in: r, with: s)
        return TextEditResult(text: out, selection: NSRange(location: caret, length: 0))
    }

    /// Return.
    /// - At the end of an opening fence without a closing fence: adds the closing fence.
    /// - On an empty last code line (after another code line): leaves the block, below the closing fence.
    public static func newline(text: String, selection sel: NSRange) -> TextEditResult? {
        guard sel.length == 0 else { return nil }
        let ns = text as NSString
        let lines = BlockScanner.scan(ns)
        let i = BlockScanner.lineIndex(in: lines, containing: sel.location)
        let line = lines[i]
        let caret = sel.location
        guard let b = block(lines, containing: i) else { return nil }

        if i == b.open, b.close == nil, caret == line.range.end {
            let fence = BlockScanner.fence(ns, line.range)!
            let indentLen = BlockScanner.fenceInfoRange(ns, line.range).location - line.range.location
            var indent = 0
            while indent < indentLen, ns.character(at: line.range.location + indent) == UC.space { indent += 1 }
            let closing = String(repeating: " ", count: indent)
                + String(repeating: Character(UnicodeScalar(fence.char)!), count: fence.count)
            // Lines below an unclosed fence are inside the block: the closing fence goes right after the
            // new empty line, so they stay outside.
            return edit(text, sel, "\n\n" + closing, caret: caret + 1)
        }

        if let close = b.close, line.kind == .code, i == close - 1, i - 1 > b.open, isBlank(ns, line.range) {
            // Remove the empty line, then continue on a line after the closing fence.
            var out = ns.replacingCharacters(in: line.fullRange, with: "") as NSString
            let fenceLine = lines[close]
            let fenceEnd = fenceLine.range.end - line.fullRange.length
            let next = close + 1 < lines.count ? lines[close + 1] : nil
            if let next, next.range.length == 0 || isBlank(ns, next.range) {
                return TextEditResult(text: out as String, selection: NSRange(location: next.range.location - line.fullRange.length, length: 0))
            }
            out = out.replacingCharacters(in: NSRange(location: fenceEnd, length: 0), with: "\n") as NSString
            return TextEditResult(text: out as String, selection: NSRange(location: fenceEnd + 1, length: 0))
        }
        return nil
    }

    /// Backspace at the start of the first code line (it would join the code to the opening fence):
    /// an empty block is removed; a block with code keeps its text and the caret goes to the end of
    /// the line above the block.
    public static func backspace(text: String, selection sel: NSRange) -> TextEditResult? {
        guard sel.length == 0 else { return nil }
        let ns = text as NSString
        let lines = BlockScanner.scan(ns)
        let i = BlockScanner.lineIndex(in: lines, containing: sel.location)
        let line = lines[i]
        guard line.kind == .code, sel.location == line.range.location, let b = block(lines, containing: i), i == b.open + 1 else {
            return nil
        }
        let empty = b.content.map { $0.allSatisfy { isBlank(ns, lines[$0].range) } } ?? true
        if empty {
            let start = lines[b.open].fullRange.location
            var end = lines[b.last].fullRange.end
            var removeStart = start
            // Last block of the note: also remove the line break before it.
            if end == ns.length, lines[b.last].fullRange.length == lines[b.last].range.length, start > 0 {
                removeStart = start - 1
            }
            end = max(end, removeStart)
            return edit(text, NSRange(location: removeStart, length: end - removeStart), "", caret: removeStart)
        }
        guard b.open > 0 else { return TextEditResult(text: text, selection: sel) }
        return TextEditResult(text: text, selection: NSRange(location: lines[b.open - 1].range.end, length: 0))
    }

    /// Forward Delete at the end of the last code line never joins it to the closing fence.
    public static func forwardDelete(text: String, selection sel: NSRange) -> TextEditResult? {
        guard sel.length == 0 else { return nil }
        let ns = text as NSString
        let lines = BlockScanner.scan(ns)
        let i = BlockScanner.lineIndex(in: lines, containing: sel.location)
        let line = lines[i]
        guard line.kind == .code, sel.location == line.range.end, let b = block(lines, containing: i), b.close == i + 1 else {
            return nil
        }
        return TextEditResult(text: text, selection: sel)
    }
}
