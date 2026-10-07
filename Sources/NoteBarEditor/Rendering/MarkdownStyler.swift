import AppKit
import NoteBarCore

/// Applies markdown styling to the editor's text storage in place (attributes only, characters never change).
/// Works paragraph by paragraph; unchanged runs are skipped so layout is only invalidated where needed.
final class MarkdownStyler {
    var style: EditorStyle

    init(style: EditorStyle) { self.style = style }

    private struct Flags: OptionSet, Hashable {
        let rawValue: UInt32
        static let bold = Flags(rawValue: 1 << 0)
        static let italic = Flags(rawValue: 1 << 1)
        static let mono = Flags(rawValue: 1 << 2)
        static let strike = Flags(rawValue: 1 << 3)
        static let underline = Flags(rawValue: 1 << 4)
        static let marker = Flags(rawValue: 1 << 5)
        static let highlight = Flags(rawValue: 1 << 6)
        static let dim = Flags(rawValue: 1 << 7)
        static let codeColor = Flags(rawValue: 1 << 8)
        static let bullet = Flags(rawValue: 1 << 9)
        static let listMarker = Flags(rawValue: 1 << 10)
    }

    /// Styles the given lines. Call inside `beginEditing()` / `endEditing()` for batching.
    func style(_ storage: NSTextStorage, lines: [MarkdownLine], indices: [Int]) {
        guard !indices.isEmpty else { return }
        let s = storage.string as NSString
        storage.beginEditing()
        for i in indices where i < lines.count {
            let line = lines[i]
            guard line.fullRange.length > 0, line.fullRange.end <= storage.length else { continue }
            for (r, attrs) in runs(for: line, in: storage, string: s) {
                setIfChanged(storage, attrs, r)
            }
        }
        storage.endEditing()
    }

    private func setIfChanged(_ storage: NSTextStorage, _ attrs: [NSAttributedString.Key: Any], _ r: NSRange) {
        var eff = NSRange()
        let cur = storage.attributes(at: r.location, longestEffectiveRange: &eff, in: r)
        if eff.location <= r.location, eff.end >= r.end, NSDictionary(dictionary: cur).isEqual(to: attrs) { return }
        storage.setAttributes(attrs, range: r)
    }

    // MARK: Runs

    func runs(for line: MarkdownLine, in storage: NSAttributedString, string s: NSString) -> [(NSRange, [NSAttributedString.Key: Any])] {
        let st = style
        let full = line.fullRange
        let n = full.length
        let base0 = full.location
        var flags = [Flags](repeating: [], count: n)
        var linkAt = [Int](repeating: -1, count: n)
        var colorAt = [Int](repeating: -1, count: n)
        var links: [URL] = []
        var colors: [NSColor] = []
        var swatches: [Int: NSColor] = [:]
        var kerns: [Int: CGFloat] = [:]

        // Base font / color / paragraph per line.
        var size = st.fontSize
        var bold = false, italic = false, mono = false
        var color = st.text
        var para = EditorStyle.ParagraphKey(tab: st.tabInterval, lineSpacing: st.lineSpacing)
        var lineAttrs: [NSAttributedString.Key: Any] = [:]

        func mark(_ r: NSRange, _ f: Flags) {
            let a = max(r.location, base0) - base0, b = min(r.end, full.end) - base0
            guard a < b else { return }
            for k in a..<b { flags[k].insert(f) }
        }

        switch st.mode {
        case .plain:
            if line.isTitle { size = st.titleSize; bold = true; color = st.title; para.spacingAfter = 3 }
        case .code:
            mono = true
            size = st.monoSize
            para.tab = st.width(of: "    ", font: st.monoFont)
            if line.isTitle { bold = true; color = st.title; para.spacingAfter = 3 }
        case .standard:
            switch line.kind {
            case .heading(let level):
                size = st.headingSize(level); bold = true
                if !line.isTitle { para.spacingBefore = 4 }
                mark(line.markerRange, .marker)
            case .quote:
                italic = true; color = st.quote
                mark(line.markerRange, .marker)
            case .fence, .code:
                mono = true; size = st.monoSize; color = st.inlineCode
                para.head = 8; para.first = 8; para.tail = -8; para.lineSpacing = 1
                para.tab = st.width(of: "    ", font: st.monoFont)
                lineAttrs[.nbCodeBlock] = (line.codeBlock % 2) + 1
                if line.kind == .fence {
                    color = st.markup
                    lineAttrs[.nbFence] = true
                    mark(line.range, .marker)
                }
            case .rule:
                color = st.markup
                lineAttrs[.nbRule] = true
                mark(line.range, .marker)
            case .bullet, .numbered, .checklist:
                let font = st.bodyFont
                let indentStr = s.substring(with: NSRange(location: line.range.location, length: line.indent))
                var w = st.indentWidth(indentStr, font: font, tab: st.tabInterval)
                switch line.kind {
                case .checklist(let checked):
                    w += st.checkboxDiameter + st.checkboxGap
                    if checked { mark(line.contentRange, [.dim, .strike]) }
                case .bullet:
                    let rest = s.substring(with: NSRange(location: line.markerRange.location + 1, length: line.markerRange.length - 1))
                    w += st.width(of: "•", font: font) + st.indentWidth(rest, font: font, tab: st.tabInterval)
                    mark(NSRange(location: line.markerRange.location, length: 1), [.bullet, .listMarker])
                default:
                    w += st.width(of: s.substring(with: line.markerRange), font: font)
                    mark(line.markerRange, .listMarker)
                }
                para.head = ceil(w)
            case .blank, .paragraph:
                break
            }
            if line.isTitle {
                bold = true
                size = max(size, st.titleSize)
                color = st.title
                para.spacingAfter = 3
            }

            // Inline spans.
            if !line.isCode, line.kind != .rule, line.contentRange.length > 0 {
                for span in InlineParser.parse(s, in: line.contentRange) {
                    switch span.kind {
                    case .bold: mark(span.range, .bold)
                    case .italic: mark(span.range, .italic)
                    case .strike: mark(span.content, .strike)
                    case .highlight: mark(span.content, .highlight)
                    case .underline: mark(span.content, .underline)
                    case .code: mark(span.range, [.mono, .codeColor])
                    case .escape: break
                    case .color(let hex):
                        if let c = NSColor(hex: hex) {
                            colors.append(c)
                            let a = span.content.location - base0
                            for k in a..<(a + span.content.length) { colorAt[k] = colors.count - 1 }
                        }
                    case .link(let url), .autolink(let url):
                        if let u = linkURL(url) {
                            links.append(u)
                            let a = span.content.location - base0
                            for k in a..<(a + span.content.length) { linkAt[k] = links.count - 1 }
                        }
                    case .hex(let hex):
                        // The '#' glyph slot is widened; the layout manager draws the swatch and the '#' in it.
                        if let c = NSColor(hex: hex) {
                            let at = span.range.location - base0
                            swatches[at] = c
                            kerns[at] = (kerns[at] ?? 0) + st.swatchReserve
                        }
                    }
                    for m in span.markers { mark(m, .marker) }
                }
            }
        }

        let pstyle = st.paragraphStyle(para)

        // Group characters into runs.
        var out: [(NSRange, [NSAttributedString.Key: Any])] = []
        var runStart = 0
        func attrs(at k: Int) -> [NSAttributedString.Key: Any] {
            let f = flags[k]
            var a = lineAttrs
            let isMono = mono || f.contains(.mono)
            let fsize = (f.contains(.mono) && !mono) ? max(8, size - 1) : size
            a[.font] = st.font(size: fsize, bold: bold || f.contains(.bold), italic: italic || f.contains(.italic), mono: isMono)
            var fg = color
            if f.contains(.marker) { fg = st.markup }
            else if f.contains(.codeColor) { fg = st.inlineCode }
            else if colorAt[k] >= 0 { fg = colors[colorAt[k]] }
            else if f.contains(.dim) || f.contains(.listMarker) { fg = st.secondary }
            a[.foregroundColor] = fg
            a[.paragraphStyle] = pstyle
            if f.contains(.strike) { a[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
            if f.contains(.underline) { a[.underlineStyle] = NSUnderlineStyle.single.rawValue }
            if f.contains(.highlight) { a[.nbHighlight] = st.highlight }
            if f.contains(.marker) { a[.nbMarker] = true }
            if f.contains(.bullet) { a[.nbBullet] = true }
            if linkAt[k] >= 0 { a[.link] = links[linkAt[k]] }
            if let c = swatches[k] {
                a[.nbSwatch] = c
                a[.nbSwatchText] = fg
                a[.foregroundColor] = NSColor.clear
            }
            if let kern = kerns[k] { a[.kern] = kern }
            return a
        }
        func same(_ a: Int, _ b: Int) -> Bool {
            flags[a] == flags[b] && linkAt[a] == linkAt[b] && colorAt[a] == colorAt[b]
                && swatches[a] == nil && swatches[b] == nil && kerns[a] == nil && kerns[b] == nil
        }
        let chars = s.characters(in: full)
        for k in 0..<n {
            let isAttachment = chars[k] == UC.attachment
            let boundary = k > 0 && (isAttachment || chars[k - 1] == UC.attachment || !same(k - 1, k))
            if boundary {
                out.append((NSRange(location: base0 + runStart, length: k - runStart), attrs(at: runStart)))
                runStart = k
            }
        }
        out.append((NSRange(location: base0 + runStart, length: n - runStart), attrs(at: runStart)))

        // Keep attachments on their characters.
        for i in out.indices where out[i].0.length == 1 && chars[out[i].0.location - base0] == UC.attachment {
            if let att = storage.attribute(.attachment, at: out[i].0.location, effectiveRange: nil) {
                out[i].1[.attachment] = att
                out[i].1[.nbMarker] = nil
            }
        }
        return out
    }

    func linkURL(_ s: String) -> URL? {
        var str = s.trimmingCharacters(in: .whitespaces)
        if str.lowercased().hasPrefix("www.") { str = "https://" + str }
        if let u = URL(string: str), u.scheme != nil { return u }
        if let enc = str.addingPercentEncoding(withAllowedCharacters: .urlFragmentAllowed), let u = URL(string: enc), u.scheme != nil {
            return u
        }
        return nil
    }
}
