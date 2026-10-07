import AppKit
import NoteBarCore

/// Markdown constructs that the editor shows as a single attachment character.
public enum EmbedToken: Hashable, Sendable {
    /// `- [ ] ` / `- [x] ` checklist prefix (source includes the bullet and at most one trailing space/tab).
    case checkbox(checked: Bool, source: String)
    /// `![name](attachment:ID)` (image) or `[name](attachment:ID)` (file shortcut).
    case attachment(id: AttachmentID, isImage: Bool, name: String, source: String)

    public var source: String {
        switch self {
        case .checkbox(_, let s): s
        case .attachment(_, _, _, let s): s
        }
    }

    public var isCheckbox: Bool { if case .checkbox = self { true } else { false } }

    /// The same checkbox with the opposite state (keeps the bullet character and spacing).
    public func toggled() -> EmbedToken {
        guard case .checkbox(let checked, let source) = self else { return self }
        var u = Array(source.utf16)
        if let i = u.firstIndex(of: UC.lbracket), i + 1 < u.count { u[i + 1] = checked ? UC.space : UC.lowerX }
        return .checkbox(checked: !checked, source: String(utf16CodeUnits: u, count: u.count))
    }
}

/// Which tokens become attachment characters.
public struct CodecOptions: Hashable, Sendable {
    public var checkboxes: Bool
    public var attachments: Bool
    public init(checkboxes: Bool, attachments: Bool) { self.checkboxes = checkboxes; self.attachments = attachments }

    public static let standard = CodecOptions(checkboxes: true, attachments: true)
    /// Plain text / code notes: checklists stay raw text, attachments still render.
    public static let raw = CodecOptions(checkboxes: false, attachments: true)

    public static func forMode(_ mode: NoteMode) -> CodecOptions { mode == .standard ? .standard : .raw }
}

/// The attachment character in the editor's text storage. Remembers its markdown source.
public final class EmbedAttachment: NSTextAttachment {
    public let token: EmbedToken

    public init(token: EmbedToken) {
        self.token = token
        super.init(data: nil, ofType: nil)
    }

    required init?(coder: NSCoder) { fatalError("not supported") }
}

/// Lossless conversion between a markdown body and the editor's attributed text.
/// `markdown(from: attributedString(from: md)) == md` for every input.
public enum MarkdownCodec {
    public struct TokenMatch: Equatable, Sendable {
        public var range: NSRange
        public var token: EmbedToken
    }

    /// Tokens in raw markdown, sorted and non-overlapping. Checkboxes inside fenced code blocks are ignored.
    public static func tokens(in markdown: String, options: CodecOptions, range: NSRange? = nil) -> [TokenMatch] {
        let ns = markdown as NSString
        var out: [TokenMatch] = []
        if options.attachments, ns.range(of: "attachment:").location != NSNotFound {
            for m in AttachmentLink.matches(in: markdown) {
                if let r = range, !(m.nsRange.location >= r.location && m.nsRange.end <= r.end) { continue }
                out.append(TokenMatch(range: m.nsRange, token: .attachment(id: m.attachmentID, isImage: m.isImage,
                                                                           name: m.name, source: ns.substring(with: m.nsRange))))
            }
        }
        if options.checkboxes, ns.range(of: "[").location != NSNotFound {
            for line in BlockScanner.scan(ns) {
                guard case .checklist(let checked) = line.kind else { continue }
                if let r = range, !(line.markerRange.location >= r.location && line.markerRange.end <= r.end) { continue }
                if out.contains(where: { NSIntersectionRange($0.range, line.markerRange).length > 0 }) { continue }
                out.append(TokenMatch(range: line.markerRange,
                                      token: .checkbox(checked: checked, source: ns.substring(with: line.markerRange))))
            }
        }
        out.sort { $0.range.location < $1.range.location }
        return out
    }

    public typealias AttachmentMaker = (EmbedToken) -> NSTextAttachment

    public static let defaultMaker: AttachmentMaker = { EmbedAttachment(token: $0) }

    /// Attributed text for `markdown` (or only `range` of it — use line-aligned ranges).
    public static func attributedString(from markdown: String, options: CodecOptions, range: NSRange? = nil,
                                        attributes: [NSAttributedString.Key: Any] = [:],
                                        makeAttachment: AttachmentMaker = defaultMaker) -> NSMutableAttributedString {
        let ns = markdown as NSString
        let full = range ?? NSRange(location: 0, length: ns.length)
        let result = NSMutableAttributedString()
        result.beginEditing()
        var pos = full.location
        for t in tokens(in: markdown, options: options, range: full) {
            if t.range.location > pos {
                result.append(NSAttributedString(string: ns.substring(with: NSRange(location: pos, length: t.range.location - pos)),
                                                 attributes: attributes))
            }
            var attrs = attributes
            attrs[.attachment] = makeAttachment(t.token)
            result.append(NSAttributedString(string: "\u{FFFC}", attributes: attrs))
            pos = t.range.end
        }
        if full.end > pos {
            result.append(NSAttributedString(string: ns.substring(with: NSRange(location: pos, length: full.end - pos)),
                                             attributes: attributes))
        }
        result.endEditing()
        return result
    }

    // MARK: Serialization

    /// One attachment character in storage and the markdown it serializes to.
    public struct Embed: Equatable {
        public var index: Int
        public var token: EmbedToken
        public var emitted: String
        public var emittedLength: Int { emitted.utf16.count }
    }

    /// The text a token serializes to at storage index `index` (adds the space a checkbox needs when
    /// text follows it directly).
    static func emitted(_ token: EmbedToken, followedBy next: unichar?) -> String {
        let src = token.source
        if token.isCheckbox, let last = src.utf16.last, !UC.isSpaceOrTab(last),
           let next, !UC.isWhitespace(next) {
            return src + " "
        }
        return src
    }

    public static func embeds(in text: NSAttributedString, range: NSRange? = nil) -> [Embed] {
        let full = range ?? NSRange(location: 0, length: text.length)
        guard full.length > 0 else { return [] }
        let s = text.string as NSString
        var out: [Embed] = []
        text.enumerateAttribute(.attachment, in: full, options: []) { value, r, _ in
            guard let a = value as? EmbedAttachment else { return }
            for k in r.location..<r.end where s.character(at: k) == UC.attachment {
                let next: unichar? = k + 1 < s.length ? s.character(at: k + 1) : nil
                out.append(Embed(index: k, token: a.token, emitted: emitted(a.token, followedBy: next)))
            }
        }
        return out
    }

    /// Markdown for the attributed text (or a range of it).
    public static func markdown(from text: NSAttributedString, range: NSRange? = nil) -> String {
        let full = range ?? NSRange(location: 0, length: text.length)
        let s = text.string as NSString
        let list = embeds(in: text, range: full)
        if list.isEmpty { return s.substring(with: full) }
        var out = ""
        out.reserveCapacity(full.length + list.count * 24)
        var pos = full.location
        for e in list {
            if e.index > pos { out += s.substring(with: NSRange(location: pos, length: e.index - pos)) }
            out += e.emitted
            pos = e.index + 1
        }
        if full.end > pos { out += s.substring(with: NSRange(location: pos, length: full.end - pos)) }
        return out
    }

    // MARK: Offset mapping

    public static func markdownOffset(forStorageOffset offset: Int, embeds: [Embed]) -> Int {
        var delta = 0
        for e in embeds {
            if e.index < offset { delta += e.emittedLength - 1 } else { break }
        }
        return offset + delta
    }

    /// Storage offset for a markdown offset. Offsets inside a token map to its start (or end with `roundUp`).
    public static func storageOffset(forMarkdownOffset offset: Int, embeds: [Embed], roundUp: Bool = false) -> Int {
        var delta = 0
        for e in embeds {
            let mdStart = e.index + delta
            let mdEnd = mdStart + e.emittedLength
            if offset <= mdStart { break }
            if offset < mdEnd { return roundUp ? e.index + 1 : e.index }
            delta += e.emittedLength - 1
        }
        return offset - delta
    }

    public static func markdownRange(forStorageRange r: NSRange, embeds: [Embed]) -> NSRange {
        let a = markdownOffset(forStorageOffset: r.location, embeds: embeds)
        let b = markdownOffset(forStorageOffset: r.end, embeds: embeds)
        return NSRange(location: a, length: b - a)
    }

    public static func storageRange(forMarkdownRange r: NSRange, embeds: [Embed]) -> NSRange {
        let a = storageOffset(forMarkdownOffset: r.location, embeds: embeds)
        let b = max(a, storageOffset(forMarkdownOffset: r.end, embeds: embeds, roundUp: r.length > 0))
        return NSRange(location: a, length: b - a)
    }
}
