import Foundation

/// An inline markdown span inside one paragraph. Ranges are absolute (in the scanned string).
public struct InlineSpan: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case bold, italic, strike, highlight, code, underline
        /// `<span style="color:#rrggbb">…</span>` — payload is the hex string including `#`.
        case color(String)
        /// `[text](url)` / `![alt](url)` — payload is the URL.
        case link(String)
        /// Bare URL or `<scheme://…>`.
        case autolink(String)
        /// `#rgb` / `#rrggbb` color token (rendered with a swatch). Payload includes `#`.
        case hex(String)
        /// `\*` — the backslash is the marker, the escaped character the content.
        case escape
    }

    public var kind: Kind
    /// Full range including markers.
    public var range: NSRange
    /// Range between the markers.
    public var content: NSRange
    /// Markup characters (dimmed or hidden).
    public var markers: [NSRange]

    public init(kind: Kind, range: NSRange, content: NSRange, markers: [NSRange]) {
        self.kind = kind; self.range = range; self.content = content; self.markers = markers
    }
}

/// Text color span syntax used by the formatting toolbar: `<span style="color:#RRGGBB">text</span>`.
public enum ColorSpanSyntax {
    public static func open(_ hex: String) -> String { "<span style=\"color:\(hex)\">" }
    public static let close = "</span>"
}

/// Inline parser for one paragraph. A pragmatic subset of CommonMark/GFM:
/// code spans, backslash escapes, links, autolinks, `<u>` / color `<span>` tags, bare URLs, `#hex` colors,
/// and emphasis (`*` `_` `**` `__` `~~` `==`) using the CommonMark delimiter algorithm.
public enum InlineParser {
    public static func parse(_ s: NSString, in range: NSRange) -> [InlineSpan] {
        let n = range.length
        guard n > 0 else { return [] }
        let base = range.location
        let c = s.characters(in: range)
        var masked = [Bool](repeating: false, count: n)
        var spans: [InlineSpan] = []

        func r(_ a: Int, _ b: Int) -> NSRange { NSRange(location: base + a, length: b - a) }
        func mask(_ a: Int, _ b: Int) { for k in a..<b { masked[k] = true } }
        func anyMasked(_ a: Int, _ b: Int) -> Bool {
            for k in a..<b where masked[k] { return true }
            return false
        }

        // 1. Escapes and code spans, left to right.
        var i = 0
        while i < n {
            let ch = c[i]
            if ch == UC.backslash, i + 1 < n, UC.isASCIIPunctuation(c[i + 1]) {
                spans.append(InlineSpan(kind: .escape, range: r(i, i + 2), content: r(i + 1, i + 2), markers: [r(i, i + 1)]))
                mask(i, i + 2)
                i += 2
                continue
            }
            if ch == UC.backtick {
                var j = i
                while j < n, c[j] == UC.backtick { j += 1 }
                let runLen = j - i
                // Find a closing run of exactly runLen backticks.
                var k = j
                var closeAt = -1
                while k < n {
                    if c[k] == UC.backtick {
                        var e = k
                        while e < n, c[e] == UC.backtick { e += 1 }
                        if e - k == runLen { closeAt = k; break }
                        k = e
                    } else {
                        k += 1
                    }
                }
                if closeAt >= 0 {
                    spans.append(InlineSpan(kind: .code, range: r(i, closeAt + runLen), content: r(j, closeAt),
                                            markers: [r(i, j), r(closeAt, closeAt + runLen)]))
                    mask(i, closeAt + runLen)
                    i = closeAt + runLen
                } else {
                    mask(i, j) // literal backticks
                    i = j
                }
                continue
            }
            i += 1
        }

        // 2. Tags, angle autolinks, links.
        var linkTextRanges: [(Int, Int)] = []
        var uStack: [(Int, Int)] = []      // (start, end) of open tag
        var spanStack: [(Int, Int, String)] = []
        i = 0
        while i < n {
            if masked[i] { i += 1; continue }
            let ch = c[i]
            if ch == UC.lt {
                if let (len, tag) = matchTag(c, at: i), !anyMasked(i, i + len) {
                    switch tag {
                    case .uOpen: uStack.append((i, i + len))
                    case .uClose:
                        if let o = uStack.popLast() {
                            spans.append(InlineSpan(kind: .underline, range: r(o.0, i + len), content: r(o.1, i),
                                                    markers: [r(o.0, o.1), r(i, i + len)]))
                            mask(o.0, o.1); mask(i, i + len)
                        }
                    case .spanOpen(let hex): spanStack.append((i, i + len, hex))
                    case .spanClose:
                        if let o = spanStack.popLast() {
                            spans.append(InlineSpan(kind: .color(o.2), range: r(o.0, i + len), content: r(o.1, i),
                                                    markers: [r(o.0, o.1), r(i, i + len)]))
                            mask(o.0, o.1); mask(i, i + len)
                        }
                    }
                    i += len
                    continue
                }
                // <scheme://...>
                var k = i + 1
                while k < n, c[k] != UC.gt, c[k] != UC.lt, !UC.isWhitespace(c[k]), !masked[k] { k += 1 }
                if k < n, c[k] == UC.gt, k > i + 1 {
                    let url = String(utf16CodeUnits: Array(c[(i + 1)..<k]), count: k - i - 1)
                    if url.contains("://") || url.lowercased().hasPrefix("mailto:") {
                        spans.append(InlineSpan(kind: .autolink(url), range: r(i, k + 1), content: r(i + 1, k),
                                                markers: [r(i, i + 1), r(k, k + 1)]))
                        mask(i, k + 1)
                        i = k + 1
                        continue
                    }
                }
            }
            if ch == UC.lbracket {
                let openStart = (i > 0 && c[i - 1] == UC.bang && !masked[i - 1]) ? i - 1 : i
                if let link = matchLink(c, masked: masked, at: i) {
                    let textStart = i + 1
                    spans.append(InlineSpan(kind: .link(link.url), range: r(openStart, link.end),
                                            content: r(textStart, link.closeBracket),
                                            markers: [r(openStart, textStart), r(link.closeBracket, link.end)]))
                    mask(openStart, textStart)
                    mask(link.closeBracket, link.end)
                    linkTextRanges.append((textStart, link.closeBracket))
                    i = textStart
                    continue
                }
            }
            i += 1
        }

        // 3. Bare URLs and #hex colors (regex on the paragraph text).
        let text = String(utf16CodeUnits: c, count: n) as NSString
        let whole = NSRange(location: 0, length: n)
        for m in urlRegex.matches(in: text as String, range: whole) {
            var a = m.range.location, b = m.range.end
            if a > 0, UC.isWordChar(c[a - 1]) || c[a - 1] == UC.slash || c[a - 1] == UC.dot { continue }
            // Trim trailing punctuation and unbalanced closing parens.
            while b > a {
                let last = c[b - 1]
                if last == UC.dot || last == 0x2C || last == UC.colon || last == 0x3B || last == UC.bang || last == 0x3F
                    || last == UC.apos || last == UC.dquote || last == UC.rbracket || last == UC.star || last == UC.underscore
                    || last == UC.tilde {
                    b -= 1; continue
                }
                if last == UC.rparen {
                    var open = 0, close = 0
                    for k in a..<b { if c[k] == UC.lparen { open += 1 } else if c[k] == UC.rparen { close += 1 } }
                    if close > open { b -= 1; continue }
                }
                break
            }
            guard b - a > 4, !anyMasked(a, b) else { continue }
            if linkTextRanges.contains(where: { a >= $0.0 && b <= $0.1 }) { continue }
            let url = text.substring(with: NSRange(location: a, length: b - a))
            if url.lowercased().hasPrefix("www."), b - a < 6 { continue }
            spans.append(InlineSpan(kind: .autolink(url), range: r(a, b), content: r(a, b), markers: []))
            mask(a, b)
            a = b
        }
        for m in hexRegex.matches(in: text as String, range: whole) {
            let a = m.range.location, b = m.range.end
            if a > 0 {
                let p = c[a - 1]
                if UC.isWordChar(p) || p == UC.amp || p == UC.hash || p == UC.slash { continue }
            }
            if b < n, UC.isWordChar(c[b]) { continue }
            guard !anyMasked(a, b) else { continue }
            let hex = text.substring(with: m.range)
            spans.append(InlineSpan(kind: .hex(hex), range: r(a, b), content: r(a, b), markers: []))
            mask(a, b)
        }

        // 4. Emphasis delimiters.
        spans.append(contentsOf: emphasis(c, masked: masked, base: base))
        spans.sort { ($0.range.location, -$0.range.length) < ($1.range.location, -$1.range.length) }
        return spans
    }

    // MARK: - Tags

    enum Tag: Equatable { case uOpen, uClose, spanOpen(String), spanClose }

    private static let tagLiterals: [(String, Tag)] = [("<u>", .uOpen), ("</u>", .uClose), ("</span>", .spanClose)]

    static func matchTag(_ c: [unichar], at i: Int) -> (Int, Tag)? {
        func matches(_ lit: String, at p: Int) -> Bool {
            let u = Array(lit.utf16)
            guard p + u.count <= c.count else { return false }
            for k in 0..<u.count {
                var x = c[p + k]
                if x >= 0x41 && x <= 0x5A { x += 0x20 } // case-insensitive tag names
                if x != u[k] { return false }
            }
            return true
        }
        for (lit, tag) in tagLiterals where matches(lit, at: i) { return (lit.utf16.count, tag) }
        // <span style="color:#hex">  (optional spaces and trailing ';')
        let prefix = "<span style=\"color:"
        guard matches(prefix, at: i) else { return nil }
        var p = i + prefix.utf16.count
        while p < c.count, c[p] == UC.space { p += 1 }
        guard p < c.count, c[p] == UC.hash else { return nil }
        let hexStart = p
        p += 1
        while p < c.count, UC.isHexDigit(c[p]) { p += 1 }
        let digits = p - hexStart - 1
        guard digits == 3 || digits == 6 || digits == 8 else { return nil }
        let hex = String(utf16CodeUnits: Array(c[hexStart..<p]), count: p - hexStart)
        while p < c.count, c[p] == UC.space || c[p] == 0x3B { p += 1 }
        guard p + 1 < c.count, c[p] == UC.dquote, c[p + 1] == UC.gt else { return nil }
        return (p + 2 - i, .spanOpen(hex))
    }

    // MARK: - Links

    struct LinkMatch { var closeBracket: Int; var end: Int; var url: String }

    static func matchLink(_ c: [unichar], masked: [Bool], at i: Int) -> LinkMatch? {
        let n = c.count
        var depth = 0
        var k = i
        var close = -1
        while k < n {
            if masked[k] && k != i { k += 1; continue }
            if c[k] == UC.backslash { k += 2; continue }
            if c[k] == UC.lbracket { depth += 1 }
            else if c[k] == UC.rbracket {
                depth -= 1
                if depth == 0 { close = k; break }
            }
            k += 1
        }
        guard close >= 0, close + 1 < n, c[close + 1] == UC.lparen, !masked[close + 1] else { return nil }
        var p = close + 2
        var parens = 1
        while p < n {
            if c[p] == UC.backslash { p += 2; continue }
            if c[p] == UC.lparen { parens += 1 }
            else if c[p] == UC.rparen {
                parens -= 1
                if parens == 0 { break }
            }
            p += 1
        }
        guard p < n, c[p] == UC.rparen else { return nil }
        var inner = String(utf16CodeUnits: Array(c[(close + 2)..<p]), count: p - close - 2)
            .trimmingCharacters(in: .whitespaces)
        if let sp = inner.firstIndex(where: { $0 == " " || $0 == "\t" }) { inner = String(inner[..<sp]) }
        if inner.hasPrefix("<"), inner.hasSuffix(">"), inner.count >= 2 { inner = String(inner.dropFirst().dropLast()) }
        return LinkMatch(closeBracket: close, end: p + 1, url: inner)
    }

    // MARK: - Regexes

    static let urlRegex = try! NSRegularExpression(pattern: #"(?:[a-zA-Z][a-zA-Z0-9+.-]{1,20}://|www\.)[^\s<>\uFFFC]+"#)
    static let hexRegex = try! NSRegularExpression(pattern: #"#(?:[0-9a-fA-F]{6}|[0-9a-fA-F]{3})"#)

    // MARK: - Emphasis (CommonMark "process emphasis", simplified)

    private struct Delim {
        var ch: unichar
        var start: Int
        var count: Int
        var lo: Int
        var hi: Int
        var canOpen: Bool
        var canClose: Bool
        var active = true
        var remaining: Int { hi - lo }
    }

    static func emphasis(_ c: [unichar], masked: [Bool], base: Int) -> [InlineSpan] {
        let n = c.count
        var delims: [Delim] = []
        var i = 0
        while i < n {
            let ch = c[i]
            guard !masked[i], ch == UC.star || ch == UC.underscore || ch == UC.tilde || ch == UC.eq else { i += 1; continue }
            var j = i
            while j < n, c[j] == ch, !masked[j] { j += 1 }
            let len = j - i
            let prev: unichar = i > 0 ? c[i - 1] : UC.space
            let next: unichar = j < n ? c[j] : UC.space
            let prevWS = UC.isWhitespace(prev), nextWS = UC.isWhitespace(next)
            let prevP = UC.isPunctuation(prev), nextP = UC.isPunctuation(next)
            let left = !nextWS && (!nextP || prevWS || prevP)
            let right = !prevWS && (!prevP || nextWS || nextP)
            var open = left, close = right
            if ch == UC.underscore {
                open = left && (!right || prevP)
                close = right && (!left || nextP)
            }
            if (ch == UC.tilde || ch == UC.eq) && len != 2 { i = j; continue }
            if open || close {
                delims.append(Delim(ch: ch, start: i, count: len, lo: i, hi: j, canOpen: open, canClose: close))
            }
            i = j
        }
        guard delims.count > 1 else { return [] }

        var out: [InlineSpan] = []
        var ci = 0
        while ci < delims.count {
            let closer = delims[ci]
            guard closer.canClose, closer.active, closer.remaining > 0 else { ci += 1; continue }
            var found = -1
            var oi = ci - 1
            while oi >= 0 {
                let o = delims[oi]
                if o.active, o.ch == closer.ch, o.canOpen, o.remaining > 0 {
                    if o.ch == UC.star || o.ch == UC.underscore {
                        if (o.canClose || closer.canOpen), (o.count + closer.count) % 3 == 0,
                           !(o.count % 3 == 0 && closer.count % 3 == 0) {
                            oi -= 1; continue
                        }
                    } else if o.remaining < 2 || closer.remaining < 2 {
                        oi -= 1; continue
                    }
                    found = oi
                    break
                }
                oi -= 1
            }
            guard found >= 0 else { ci += 1; continue }
            var o = delims[found]
            var cl = delims[ci]
            let use: Int
            let kind: InlineSpan.Kind
            if cl.ch == UC.star || cl.ch == UC.underscore {
                use = (o.remaining >= 2 && cl.remaining >= 2) ? 2 : 1
                kind = use == 2 ? .bold : .italic
            } else {
                use = 2
                kind = cl.ch == UC.tilde ? .strike : .highlight
            }
            let om = NSRange(location: base + o.hi - use, length: use)
            let cm = NSRange(location: base + cl.lo, length: use)
            o.hi -= use
            cl.lo += use
            out.append(InlineSpan(kind: kind, range: NSRange(location: om.location, length: cm.end - om.location),
                                  content: NSRange(location: om.end, length: cm.location - om.end), markers: [om, cm]))
            delims[found] = o
            delims[ci] = cl
            if found + 1 < ci { for k in (found + 1)..<ci { delims[k].active = false } }
            if cl.remaining == 0 { ci += 1 }
        }
        return out
    }
}
