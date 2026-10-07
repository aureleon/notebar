import Foundation
import NoteBarCore

/// Result of a pure text transformation: the new markdown and the new selection (UTF-16 offsets).
public struct TextEditResult: Equatable, Sendable {
    public var text: String
    public var selection: NSRange
    public init(text: String, selection: NSRange) { self.text = text; self.selection = selection }
}

/// Inline styles toggled by the formatting toolbar and shortcuts.
public enum InlineStyle: CaseIterable, Sendable {
    case bold, italic, strike, highlight, code, underline

    public var open: String {
        switch self {
        case .bold: "**"
        case .italic: "*"
        case .strike: "~~"
        case .highlight: "=="
        case .code: "`"
        case .underline: "<u>"
        }
    }

    public var close: String { self == .underline ? "</u>" : open }

    func matches(_ kind: InlineSpan.Kind) -> Bool {
        switch (self, kind) {
        case (.bold, .bold), (.italic, .italic), (.strike, .strike), (.highlight, .highlight),
             (.code, .code), (.underline, .underline): true
        default: false
        }
    }
}

public enum ListStyle: Sendable { case bullet, numbered, checklist }

/// A replacement in the original text.
struct TextEdit {
    var range: NSRange
    var replacement: String
}

/// Pure markdown editing operations (formatting toolbar, shortcuts, list continuation).
/// All functions take the full markdown and the selection, and return the new markdown + selection.
public enum FormatEditing {

    // MARK: - Edit helpers

    static func apply(_ edits: [TextEdit], to text: String) -> String {
        let m = NSMutableString(string: text)
        for e in edits.sorted(by: { $0.range.location > $1.range.location }) {
            m.replaceCharacters(in: e.range, with: e.replacement)
        }
        return m as String
    }

    /// Maps an offset through edits. `after` decides what happens to an offset where text is inserted.
    static func map(_ p: Int, _ edits: [TextEdit], after: Bool) -> Int {
        var delta = 0
        for e in edits.sorted(by: { $0.range.location < $1.range.location }) {
            let len = (e.replacement as NSString).length
            if e.range.length == 0 {
                if e.range.location < p || (e.range.location == p && after) { delta += len; continue }
                if e.range.location >= p { break }
            } else {
                if e.range.end <= p { delta += len - e.range.length; continue }
                if e.range.location < p { return e.range.location + delta + (after ? len : 0) }
                break
            }
        }
        return p + delta
    }

    static func result(_ text: String, _ edits: [TextEdit], _ sel: NSRange, startAfter: Bool = true, endAfter: Bool = false) -> TextEditResult {
        guard !edits.isEmpty else { return TextEditResult(text: text, selection: sel) }
        let out = apply(edits, to: text)
        let a = map(sel.location, edits, after: startAfter)
        let b = sel.length == 0 ? a : max(a, map(sel.end, edits, after: endAfter))
        return TextEditResult(text: out, selection: NSRange(location: a, length: b - a))
    }

    /// Lines touched by the selection. A selection that ends exactly at the start of a line does not include it.
    static func targetLines(_ lines: [MarkdownLine], _ sel: NSRange) -> [Int] {
        let first = BlockScanner.lineIndex(in: lines, containing: sel.location)
        var last = BlockScanner.lineIndex(in: lines, containing: sel.end)
        if sel.length > 0, last > first, lines[last].range.location == sel.end { last -= 1 }
        return Array(first...last)
    }

    static func trimmed(_ ns: NSString, _ r: NSRange) -> NSRange {
        var a = r.location, b = r.end
        while a < b, UC.isWhitespace(ns.character(at: a)) { a += 1 }
        while b > a, UC.isWhitespace(ns.character(at: b - 1)) { b -= 1 }
        return NSRange(location: a, length: b - a)
    }

    // MARK: - Inline styles

    public static func toggle(_ style: InlineStyle, text: String, selection sel: NSRange) -> TextEditResult {
        let ns = text as NSString
        let lines = BlockScanner.scan(ns)
        if sel.length == 0 {
            let line = lines[BlockScanner.lineIndex(in: lines, containing: sel.location)]
            let spans = InlineParser.parse(ns, in: line.contentRange)
            if let span = spans.filter({ style.matches($0.kind) && $0.content.location <= sel.location && sel.location <= $0.content.end })
                .min(by: { $0.range.length < $1.range.length }) {
                let edits = span.markers.map { TextEdit(range: $0, replacement: "") }
                return result(text, edits, sel, startAfter: false)
            }
            // Caret inside a word: wrap the word.
            let p = sel.location
            if p > line.contentRange.location, p < line.contentRange.end,
               UC.isWordChar(ns.character(at: p - 1)), UC.isWordChar(ns.character(at: p)) {
                var a = p, b = p
                while a > line.contentRange.location, UC.isWordChar(ns.character(at: a - 1)) { a -= 1 }
                while b < line.contentRange.end, UC.isWordChar(ns.character(at: b)) { b += 1 }
                let edits = [TextEdit(range: NSRange(location: a, length: 0), replacement: style.open),
                             TextEdit(range: NSRange(location: b, length: 0), replacement: style.close)]
                return result(text, edits, sel, startAfter: true)
            }
            let edits = [TextEdit(range: sel, replacement: style.open + style.close)]
            let caret = sel.location + (style.open as NSString).length
            return TextEditResult(text: apply(edits, to: text), selection: NSRange(location: caret, length: 0))
        }

        var segments: [(NSRange, [InlineSpan])] = []
        for i in targetLines(lines, sel) {
            let line = lines[i]
            let seg = trimmed(ns, NSIntersectionRange(sel, line.contentRange))
            guard seg.length > 0 else { continue }
            segments.append((seg, InlineParser.parse(ns, in: line.contentRange)))
        }
        guard !segments.isEmpty else { return TextEditResult(text: text, selection: sel) }

        func styledSpan(_ seg: NSRange, _ spans: [InlineSpan]) -> InlineSpan? {
            spans.filter { s in
                style.matches(s.kind) &&
                ((s.content.location <= seg.location && seg.end <= s.content.end) ||
                 (s.range.location <= seg.location && seg.end <= s.range.end && seg.location <= s.content.location && s.content.end <= seg.end))
            }.min(by: { $0.range.length < $1.range.length })
        }

        let styled = segments.map { styledSpan($0.0, $0.1) }
        var edits: [TextEdit] = []
        if styled.allSatisfy({ $0 != nil }) {
            var seen = Set<Int>()
            for s in styled.compactMap({ $0 }) where seen.insert(s.range.location).inserted {
                edits += s.markers.map { TextEdit(range: $0, replacement: "") }
            }
            return result(text, edits, sel, startAfter: true, endAfter: false)
        }
        for (k, (seg, spans)) in segments.enumerated() where styled[k] == nil {
            // Merge: drop same-style spans fully inside the segment, then wrap the segment.
            for s in spans where style.matches(s.kind) && s.range.location >= seg.location && s.range.end <= seg.end {
                edits += s.markers.map { TextEdit(range: $0, replacement: "") }
            }
            edits.append(TextEdit(range: NSRange(location: seg.location, length: 0), replacement: style.open))
            edits.append(TextEdit(range: NSRange(location: seg.end, length: 0), replacement: style.close))
        }
        // Keep the selection on the text (inside the new markers).
        let out = apply(edits, to: text)
        let first = segments.first!.0, last = segments.last!.0
        let a = map(first.location, edits, after: true)
        let b = map(last.end, edits, after: false)
        return TextEditResult(text: out, selection: NSRange(location: a, length: max(0, b - a)))
    }

    // MARK: - Text color

    /// Wraps the selection in `<span style="color:#hex">…</span>`, changes an existing color, or removes it (`hex == nil`).
    public static func setColor(_ hex: String?, text: String, selection sel: NSRange) -> TextEditResult {
        let ns = text as NSString
        let lines = BlockScanner.scan(ns)
        var edits: [TextEdit] = []
        var handled = false
        for i in targetLines(lines, sel) {
            let line = lines[i]
            let spans = InlineParser.parse(ns, in: line.contentRange)
            let seg = sel.length == 0 ? sel : trimmed(ns, NSIntersectionRange(sel, line.contentRange))
            if sel.length > 0 && seg.length == 0 { continue }
            let colorSpans = spans.filter { if case .color = $0.kind { return true }; return false }
            let existing = colorSpans.filter { s in
                (s.content.location <= seg.location && seg.end <= s.content.end) ||
                (seg.length > 0 && seg.location <= s.range.location && s.range.end <= seg.end &&
                 s.range.location - seg.location <= s.markers[0].length && seg.end - s.range.end <= s.markers[1].length) ||
                (seg.location <= s.content.location && s.content.end <= seg.end && s.range.location <= seg.location && seg.end <= s.range.end)
            }.min(by: { $0.range.length < $1.range.length })
            if let span = existing {
                handled = true
                if let hex { edits.append(TextEdit(range: span.markers[0], replacement: ColorSpanSyntax.open(hex))) }
                else { edits += span.markers.map { TextEdit(range: $0, replacement: "") } }
                continue
            }
            guard let hex, seg.length > 0 else { continue }
            handled = true
            for s in colorSpans where s.range.location >= seg.location && s.range.end <= seg.end {
                edits += s.markers.map { TextEdit(range: $0, replacement: "") }
            }
            edits.append(TextEdit(range: NSRange(location: seg.location, length: 0), replacement: ColorSpanSyntax.open(hex)))
            edits.append(TextEdit(range: NSRange(location: seg.end, length: 0), replacement: ColorSpanSyntax.close))
        }
        if !handled, sel.length == 0, let hex {
            let open = ColorSpanSyntax.open(hex)
            let out = apply([TextEdit(range: sel, replacement: open + ColorSpanSyntax.close)], to: text)
            return TextEditResult(text: out, selection: NSRange(location: sel.location + (open as NSString).length, length: 0))
        }
        return result(text, edits, sel, startAfter: true, endAfter: false)
    }

    // MARK: - Links

    /// Toggles a link. Inside a link: unwraps it. Otherwise wraps the selection as `[sel](url)`.
    /// Without `url`, inserts `https://` and selects it so the user can type the address.
    public static func toggleLink(text: String, selection sel: NSRange, url: String?) -> TextEditResult {
        let ns = text as NSString
        let lines = BlockScanner.scan(ns)
        let line = lines[BlockScanner.lineIndex(in: lines, containing: sel.location)]
        let spans = InlineParser.parse(ns, in: line.contentRange)
        if let link = spans.first(where: {
            if case .link = $0.kind { return $0.range.location <= sel.location && sel.end <= $0.range.end }
            return false
        }) {
            // Images and file tiles are attachment tokens, not links: never unwrap or nest them.
            if isAttachmentToken(link) { return TextEditResult(text: text, selection: sel) }
            let edits = link.markers.map { TextEdit(range: $0, replacement: "") }
            return result(text, edits, sel, startAfter: true, endAfter: false)
        }
        // Limit to the first line of the selection.
        var s = NSIntersectionRange(sel, line.range)
        if sel.length == 0 || s.length == 0 { s = NSRange(location: sel.location, length: 0) }
        s = s.length > 0 ? trimmed(ns, s) : s
        let label = ns.substring(with: s)
        let looksLikeURL = label.range(of: #"^(https?://|www\.)\S+$"#, options: .regularExpression) != nil
        let target = url ?? (looksLikeURL ? (label.hasPrefix("www.") ? "https://" + label : label) : nil)
        let placeholder = "https://"
        let urlText = target ?? placeholder
        let replacement = "[\(label)](\(urlText))"
        let out = apply([TextEdit(range: s, replacement: replacement)], to: text)
        let labelLen = (label as NSString).length
        if s.length == 0 {
            return TextEditResult(text: out, selection: NSRange(location: s.location + 1, length: 0))
        }
        if target == nil {
            return TextEditResult(text: out, selection: NSRange(location: s.location + labelLen + 3, length: (placeholder as NSString).length))
        }
        return TextEditResult(text: out, selection: NSRange(location: s.location + (replacement as NSString).length, length: 0))
    }

    // MARK: - Line prefixes

    public static func toggleList(_ style: ListStyle, text: String, selection sel: NSRange) -> TextEditResult {
        let ns = text as NSString
        let lines = BlockScanner.scan(ns)
        var idx = targetLines(lines, sel).filter { !lines[$0].isCode }
        let nonBlank = idx.filter { lines[$0].kind != .blank }
        if !nonBlank.isEmpty { idx = nonBlank }
        guard !idx.isEmpty else { return TextEditResult(text: text, selection: sel) }

        func isStyle(_ k: MarkdownLine.Kind) -> Bool {
            switch (style, k) {
            case (.bullet, .bullet), (.numbered, .numbered), (.checklist, .checklist): true
            default: false
            }
        }
        let allAre = idx.allSatisfy { isStyle(lines[$0].kind) }
        var edits: [TextEdit] = []
        var number = 1
        for i in idx {
            let line = lines[i]
            if allAre {
                edits.append(TextEdit(range: line.markerRange, replacement: ""))
                continue
            }
            let marker: String
            switch style {
            case .bullet: marker = "- "
            case .numbered: marker = "\(number). "; number += 1
            case .checklist: marker = "- [ ] "
            }
            switch line.kind {
            case .bullet, .numbered:
                edits.append(TextEdit(range: line.markerRange, replacement: marker))
            case .checklist:
                if style != .checklist { edits.append(TextEdit(range: line.markerRange, replacement: marker)) }
            case .heading:
                edits.append(TextEdit(range: line.markerRange, replacement: marker))
            case .quote:
                edits.append(TextEdit(range: NSRange(location: line.markerRange.end, length: 0), replacement: marker))
            default:
                edits.append(TextEdit(range: NSRange(location: line.range.location, length: 0), replacement: marker))
            }
        }
        return result(text, edits, sel, startAfter: true, endAfter: true)
    }

    public static func toggleQuote(text: String, selection sel: NSRange) -> TextEditResult {
        let ns = text as NSString
        let lines = BlockScanner.scan(ns)
        var idx = targetLines(lines, sel).filter { !lines[$0].isCode }
        let nonBlank = idx.filter { lines[$0].kind != .blank }
        if !nonBlank.isEmpty { idx = nonBlank }
        guard !idx.isEmpty else { return TextEditResult(text: text, selection: sel) }
        let allAre = idx.allSatisfy { lines[$0].kind == .quote }
        var edits: [TextEdit] = []
        for i in idx {
            let line = lines[i]
            if allAre { edits.append(TextEdit(range: line.markerRange, replacement: "")) }
            else if line.kind != .quote { edits.append(TextEdit(range: NSRange(location: line.range.location, length: 0), replacement: "> ")) }
        }
        return result(text, edits, sel, startAfter: true, endAfter: true)
    }

    /// Sets the heading level of the selected lines. `nil` = plain paragraph.
    /// With `toggle`, applying the current level again removes it.
    public static func setHeading(_ level: Int?, text: String, selection sel: NSRange, toggle: Bool = true) -> TextEditResult {
        let ns = text as NSString
        let lines = BlockScanner.scan(ns)
        var idx = targetLines(lines, sel).filter { !lines[$0].isCode }
        let nonBlank = idx.filter { lines[$0].kind != .blank }
        if !nonBlank.isEmpty { idx = nonBlank }
        guard !idx.isEmpty else { return TextEditResult(text: text, selection: sel) }
        let allAtLevel = level != nil && idx.allSatisfy { lines[$0].kind == .heading(level!) }
        var edits: [TextEdit] = []
        for i in idx {
            let line = lines[i]
            let target: Int? = (toggle && allAtLevel) ? nil : level
            let marker = target.map { String(repeating: "#", count: max(1, min(6, $0))) + " " } ?? ""
            if case .heading = line.kind {
                edits.append(TextEdit(range: line.markerRange, replacement: marker))
            } else if !marker.isEmpty {
                edits.append(TextEdit(range: NSRange(location: line.range.location, length: 0), replacement: marker))
            }
        }
        return result(text, edits, sel, startAfter: true, endAfter: true)
    }

    /// Toolbar heading button: paragraph → H1 → H2 → H3 → paragraph.
    public static func cycleHeading(text: String, selection sel: NSRange) -> TextEditResult {
        let ns = text as NSString
        let lines = BlockScanner.scan(ns)
        let line = lines[BlockScanner.lineIndex(in: lines, containing: sel.location)]
        let next: Int?
        if case .heading(let l) = line.kind { next = l >= 3 ? nil : l + 1 } else { next = 1 }
        return setHeading(next, text: text, selection: sel, toggle: false)
    }

    // MARK: - Code block

    public static func toggleCodeBlock(text: String, selection sel: NSRange) -> TextEditResult {
        let ns = text as NSString
        let lines = BlockScanner.scan(ns)
        let cur = BlockScanner.lineIndex(in: lines, containing: sel.location)
        if lines[cur].codeBlock >= 0 {
            let block = lines[cur].codeBlock
            let members = lines.indices.filter { lines[$0].codeBlock == block }
            var edits: [TextEdit] = []
            let open = lines[members.first!]
            edits.append(TextEdit(range: open.fullRange, replacement: ""))
            if members.count > 1, let lastIdx = members.last, lines[lastIdx].kind == .fence {
                let close = lines[lastIdx]
                if close.fullRange.length > close.range.length {
                    edits.append(TextEdit(range: close.fullRange, replacement: ""))
                } else if lastIdx > 0 {
                    let prevEnd = lines[lastIdx - 1].range.end
                    let r = NSRange(location: prevEnd, length: close.range.end - prevEnd)
                    if r.location >= open.fullRange.end {
                        edits.append(TextEdit(range: r, replacement: ""))
                    }
                }
            }
            return result(text, edits, sel, startAfter: true, endAfter: false)
        }
        let idx = targetLines(lines, sel)
        let first = lines[idx.first!], last = lines[idx.last!]
        if sel.length == 0, first.kind == .blank {
            let out = apply([TextEdit(range: first.range, replacement: "```\n\n```")], to: text)
            return TextEditResult(text: out, selection: NSRange(location: first.range.location + 4, length: 0))
        }
        let edits = [TextEdit(range: NSRange(location: first.range.location, length: 0), replacement: "```\n"),
                     TextEdit(range: NSRange(location: last.range.end, length: 0), replacement: "\n```")]
        let out = apply(edits, to: text)
        let a = first.range.location + 4
        let b = last.range.end + 4
        if sel.length == 0 { return TextEditResult(text: out, selection: NSRange(location: sel.location + 4, length: 0)) }
        return TextEditResult(text: out, selection: NSRange(location: a, length: b - a))
    }

    // MARK: - Clear formatting

    /// `![name](attachment:ID)` / `[name](attachment:ID)` — rendered as an image or file tile.
    static func isAttachmentToken(_ span: InlineSpan) -> Bool {
        if case .link(let url) = span.kind { return url.hasPrefix(AttachmentLink.scheme + ":") }
        return false
    }

    /// Removes inline markers, heading/quote markers and code fences in the selected lines
    /// (the whole caret line when nothing is selected). Lists, checklists and attachments stay.
    public static func clearFormatting(text: String, selection sel: NSRange) -> TextEditResult {
        let ns = text as NSString
        let lines = BlockScanner.scan(ns)
        var ranges: [NSRange] = []
        var blocks = Set<Int>()
        for i in targetLines(lines, sel) {
            let line = lines[i]
            if line.codeBlock >= 0 { blocks.insert(line.codeBlock); continue }
            switch line.kind {
            case .heading, .quote: ranges.append(line.markerRange)
            default: break
            }
            let spans = InlineParser.parse(ns, in: line.contentRange)
            // Attachment tokens (images, file tiles) and everything inside their labels stay intact.
            let protected = spans.filter(isAttachmentToken).map(\.range)
            for span in spans where !span.markers.isEmpty {
                if case .escape = span.kind { continue }
                if protected.contains(where: { $0.location <= span.range.location && span.range.end <= $0.end }) { continue }
                if sel.length == 0 || NSIntersectionRange(span.range, sel).length > 0 {
                    ranges += span.markers
                }
            }
        }
        for b in blocks {
            let members = lines.indices.filter { lines[$0].codeBlock == b && lines[$0].kind == .fence }
            for m in members { ranges.append(lines[m].fullRange.length > 0 ? lines[m].fullRange : lines[m].range) }
        }
        // Deduplicate / drop overlaps.
        ranges.sort { $0.location < $1.location }
        var merged: [NSRange] = []
        for r in ranges where r.length > 0 {
            if let last = merged.last, r.location < last.end {
                if r.end > last.end { merged[merged.count - 1] = NSUnionRange(last, r) }
            } else {
                merged.append(r)
            }
        }
        let edits = merged.map { TextEdit(range: $0, replacement: "") }
        return result(text, edits, sel, startAfter: true, endAfter: false)
    }
}
