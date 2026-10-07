import Foundation

/// One paragraph ("line") of a note and its block-level markdown role.
public struct MarkdownLine: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case blank
        case paragraph
        /// `#`…`######` + space.
        case heading(Int)
        /// `>` (possibly nested `> >`).
        case quote
        /// `-`, `*`, `+` + space.
        case bullet
        /// `1.` / `1)` + space. Payload = the number.
        case numbered(Int)
        /// `- [ ] ` / `- [x] ` (raw text) or a checkbox attachment character.
        case checklist(checked: Bool)
        /// ``` or ~~~ fence line (opening or closing).
        case fence
        /// A line inside a fenced code block.
        case code
        /// `---`, `***`, `___`.
        case rule

        public var isList: Bool {
            switch self {
            case .bullet, .numbered, .checklist: true
            default: false
            }
        }
    }

    /// Paragraph range without its terminator.
    public var range: NSRange
    /// Paragraph range including its terminator.
    public var fullRange: NSRange
    public var kind: Kind
    /// Leading whitespace length before a list marker (lists only, 0 otherwise).
    public var indent: Int
    /// The block marker (heading `## `, quote `> `, list marker incl. its trailing space, fence = whole line).
    /// Zero length at the line start when there is none.
    public var markerRange: NSRange
    /// The first non-blank line of the note (rendered as the title).
    public var isTitle: Bool = false
    /// Ordinal of the fenced code block this line belongs to (fences + content), or -1.
    public var codeBlock: Int = -1

    /// Inline content after the block marker.
    public var contentRange: NSRange {
        let start = max(markerRange.end, range.location)
        return NSRange(location: start, length: max(0, range.end - start))
    }

    public var isCode: Bool { kind == .code || kind == .fence }
}

/// Splits text into paragraphs and classifies each one. Works on raw markdown and on the editor's
/// storage string (where checkboxes are attachment characters; `checkbox` reports their state).
public enum BlockScanner {
    public static func scan(_ s: NSString, checkbox: (Int) -> Bool? = { _ in nil }) -> [MarkdownLine] {
        var lines: [MarkdownLine] = []
        let len = s.length
        var pos = 0
        var inFence = false
        var fenceChar: unichar = 0
        var fenceLen = 0
        var block = -1
        var titleFound = false
        var lastHadTerminator = true

        func add(_ range: NSRange, _ full: NSRange) {
            var line: MarkdownLine
            if inFence {
                if let f = fence(s, range), f.char == fenceChar, f.count >= fenceLen, f.infoIsBlank {
                    line = MarkdownLine(range: range, fullRange: full, kind: .fence, indent: 0, markerRange: range)
                    inFence = false
                } else {
                    line = MarkdownLine(range: range, fullRange: full, kind: .code, indent: 0,
                                        markerRange: NSRange(location: range.location, length: 0))
                }
                line.codeBlock = block
            } else if let f = fence(s, range), f.char != UC.backtick || !f.infoHasBacktick {
                block += 1
                inFence = true
                fenceChar = f.char
                fenceLen = f.count
                line = MarkdownLine(range: range, fullRange: full, kind: .fence, indent: 0, markerRange: range)
                line.codeBlock = block
            } else {
                line = classify(s, range: range, fullRange: full, checkbox: checkbox)
            }
            if !titleFound, line.kind != .blank {
                titleFound = true
                if !line.isCode && line.kind != .rule { line.isTitle = true }
            }
            lines.append(line)
        }

        while pos < len {
            var start = 0, end = 0, contentsEnd = 0
            s.getParagraphStart(&start, end: &end, contentsEnd: &contentsEnd, for: NSRange(location: pos, length: 0))
            add(NSRange(location: start, length: contentsEnd - start), NSRange(location: start, length: end - start))
            lastHadTerminator = end > contentsEnd
            pos = max(end, pos + 1)
        }
        if len == 0 || lastHadTerminator {
            add(NSRange(location: len, length: 0), NSRange(location: len, length: 0))
        }
        return lines
    }

    struct Fence { var char: unichar; var count: Int; var infoIsBlank: Bool; var infoHasBacktick: Bool }

    static func fence(_ s: NSString, _ range: NSRange) -> Fence? {
        var i = range.location
        let end = range.end
        var spaces = 0
        while i < end, s.character(at: i) == UC.space, spaces < 4 { i += 1; spaces += 1 }
        guard spaces <= 3, i < end else { return nil }
        let c = s.character(at: i)
        guard c == UC.backtick || c == UC.tilde else { return nil }
        var n = 0
        while i < end, s.character(at: i) == c { i += 1; n += 1 }
        guard n >= 3 else { return nil }
        var blank = true, backtick = false
        while i < end {
            let ch = s.character(at: i)
            if !UC.isWhitespace(ch) { blank = false }
            if ch == UC.backtick { backtick = true }
            i += 1
        }
        return Fence(char: c, count: n, infoIsBlank: blank, infoHasBacktick: backtick)
    }

    static func classify(_ s: NSString, range: NSRange, fullRange: NSRange, checkbox: (Int) -> Bool?) -> MarkdownLine {
        let start = range.location, end = range.end
        let none = NSRange(location: start, length: 0)
        func line(_ k: MarkdownLine.Kind, indent: Int = 0, marker: NSRange? = nil) -> MarkdownLine {
            MarkdownLine(range: range, fullRange: fullRange, kind: k, indent: indent, markerRange: marker ?? none)
        }
        func ch(_ i: Int) -> unichar { i < end ? s.character(at: i) : 0 }

        // Blank?
        var i = start
        while i < end, UC.isWhitespace(s.character(at: i)) { i += 1 }
        if i == end { return line(.blank) }

        // Leading spaces (max 3 for heading / quote / rule).
        var sp = start
        while sp < end, ch(sp) == UC.space, sp - start < 4 { sp += 1 }
        let shallow = sp - start <= 3

        if shallow {
            // Heading.
            if ch(sp) == UC.hash {
                var h = sp
                while ch(h) == UC.hash { h += 1 }
                let level = h - sp
                if level <= 6, h < end, UC.isSpaceOrTab(ch(h)) {
                    var m = h
                    while m < end, UC.isSpaceOrTab(ch(m)) { m += 1 }
                    return line(.heading(level), marker: NSRange(location: start, length: m - start))
                }
            }
            // Rule: three or more of the same - * _ with optional spaces only.
            let rc = ch(sp)
            if rc == UC.dash || rc == UC.star || rc == UC.underscore {
                var count = 0, ok = true, k = sp
                while k < end {
                    let c = ch(k)
                    if c == rc { count += 1 } else if !UC.isSpaceOrTab(c) { ok = false; break }
                    k += 1
                }
                if ok && count >= 3 { return line(.rule, marker: range) }
            }
            // Quote (nested allowed).
            if ch(sp) == UC.gt {
                var m = sp
                while m < end, ch(m) == UC.gt {
                    m += 1
                    if m < end, ch(m) == UC.space { m += 1 }
                    var look = m
                    while look < end, ch(look) == UC.space, look - m < 3 { look += 1 }
                    if ch(look) == UC.gt { m = look } else { break }
                }
                return line(.quote, marker: NSRange(location: start, length: m - start))
            }
        }

        // Lists: any leading whitespace.
        var ind = start
        while ind < end, UC.isSpaceOrTab(ch(ind)) { ind += 1 }
        let indent = ind - start
        let c0 = ch(ind)

        // Checkbox attachment.
        if c0 == UC.attachment, let checked = checkbox(ind) {
            return line(.checklist(checked: checked), indent: indent, marker: NSRange(location: ind, length: 1))
        }
        if c0 == UC.dash || c0 == UC.star || c0 == UC.plus {
            // Raw checklist: "- [ ]" followed by space/tab or end of line.
            if ch(ind + 1) == UC.space, ch(ind + 2) == UC.lbracket {
                let box = ch(ind + 3)
                if (box == UC.space || box == UC.lowerX || box == UC.upperX), ch(ind + 4) == UC.rbracket {
                    let after = ind + 5
                    if after == end || UC.isSpaceOrTab(ch(after)) {
                        let mEnd = after < end ? after + 1 : after
                        return line(.checklist(checked: box != UC.space), indent: indent,
                                    marker: NSRange(location: ind, length: mEnd - ind))
                    }
                }
            }
            if ind + 1 < end, UC.isSpaceOrTab(ch(ind + 1)) {
                var m = ind + 1
                while m < end, UC.isSpaceOrTab(ch(m)) { m += 1 }
                return line(.bullet, indent: indent, marker: NSRange(location: ind, length: m - ind))
            }
        }
        if UC.isDigit(c0) {
            var d = ind
            while d < end, UC.isDigit(ch(d)), d - ind < 9 { d += 1 }
            let delim = ch(d)
            if (delim == UC.dot || delim == UC.rparen), d + 1 < end, UC.isSpaceOrTab(ch(d + 1)) {
                let number = Int(s.substring(with: NSRange(location: ind, length: d - ind))) ?? 1
                var m = d + 1
                while m < end, UC.isSpaceOrTab(ch(m)) { m += 1 }
                return line(.numbered(number), indent: indent, marker: NSRange(location: ind, length: m - ind))
            }
        }
        return line(.paragraph)
    }

    /// Index of the line containing `location` (binary search). A location at a line's end belongs to it.
    public static func lineIndex(in lines: [MarkdownLine], containing location: Int) -> Int {
        guard !lines.isEmpty else { return 0 }
        var lo = 0, hi = lines.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if lines[mid].fullRange.location <= location { lo = mid } else { hi = mid - 1 }
        }
        return lo
    }
}
