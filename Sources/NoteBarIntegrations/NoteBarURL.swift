import Foundation

// Pure Foundation (no NoteBarCore / AppKit), so scripts/check-integrations.sh can compile it standalone.

/// A parsed `notebar://` URL.
///
/// Supported forms (action names are case-insensitive, `notebar:new`, `notebar:///new` and
/// `notebar://x-callback-url/new` are accepted too):
///
///     notebar://new?text=…&folder=…&show=0|1&color=yellow&mode=code
///     notebar://show | hide | toggle
///     notebar://search?q=…
///     notebar://open?note=<id>        (reveal + edit a note)
///     notebar://open?folder=<name>    (show a folder)
///     notebar://open                  (same as show)
///     notebar://settings
///
/// x-callback-url: `x-success` / `x-error` are honored by the URL handler.
public enum NoteBarURLCommand: Equatable, Sendable {
    case newNote(NewNoteRequest)
    case show
    case hide
    case toggle
    /// Empty query = just open the search field.
    case search(query: String)
    case openNote(id: Int64)
    case openFolder(name: String)
    case settings
}

public struct NewNoteRequest: Equatable, Sendable {
    /// nil = empty note.
    public var text: String?
    /// nil = current / last folder. Created if missing.
    public var folder: String?
    /// Reveal the panel and focus the new note. Default true.
    public var show: Bool
    /// Raw `NoteColor` value (e.g. "yellow"), validated by the handler.
    public var color: String?
    /// Raw `NoteMode` value ("standard", "plain", "code"), validated by the handler.
    public var mode: String?

    public init(text: String? = nil, folder: String? = nil, show: Bool = true, color: String? = nil, mode: String? = nil) {
        self.text = text; self.folder = folder; self.show = show; self.color = color; self.mode = mode
    }
}

public enum NoteBarURLError: Error, Equatable, Sendable, CustomStringConvertible {
    case notNoteBarURL
    case unknownAction(String)
    case missingParameter(String)
    case invalidParameter(name: String, value: String)

    public var description: String {
        switch self {
        case .notNoteBarURL: "Not a notebar:// URL."
        case .unknownAction(let a): a.isEmpty ? "Missing action (use notebar://new, show, hide, toggle, search, open, settings)." : "Unknown action \"\(a)\"."
        case .missingParameter(let p): "Missing parameter \"\(p)\"."
        case .invalidParameter(let n, let v): "Invalid value \"\(v)\" for parameter \"\(n)\"."
        }
    }
}

/// A parsed URL: the command plus the x-callback-url parameters.
public struct ParsedNoteBarURL: Equatable, Sendable {
    public var command: NoteBarURLCommand
    public var successURL: String?
    public var errorURL: String?
}

public enum NoteBarURLParser {
    public static let scheme = "notebar"

    /// Parses a raw URL string. Does not rely on `URL(string:)`, so unencoded spaces, Unicode, `#`
    /// and stray `%` characters (as sent by some launchers) are tolerated.
    /// A `#` is treated as literal text, not as a fragment (notes often contain `#tags` / `#rrggbb`).
    public static func parse(_ raw: String) -> Result<ParsedNoteBarURL, NoteBarURLError> {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let colon = s.firstIndex(of: ":"), s[..<colon].lowercased() == scheme else {
            return .failure(.notNoteBarURL)
        }
        var rest = s[s.index(after: colon)...]
        var query: Substring = ""
        if let q = rest.firstIndex(of: "?") {
            query = rest[rest.index(after: q)...]
            rest = rest[..<q]
        }
        var path = rest.split(separator: "/", omittingEmptySubsequences: true).map { decodeComponent($0).lowercased() }
        if path.first == "x-callback-url" { path.removeFirst() }
        let action = path.first ?? ""
        let params = parseQuery(query)

        let success = params.first("x-success")
        let error = params.first("x-error")
        func done(_ c: NoteBarURLCommand) -> Result<ParsedNoteBarURL, NoteBarURLError> {
            .success(ParsedNoteBarURL(command: c, successURL: success, errorURL: error))
        }

        switch action {
        case "new", "new-note", "newnote", "add", "create":
            var req = NewNoteRequest()
            req.text = params.first("text", "body", "content", "t")
            req.folder = params.first("folder", "f")?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            if let v = params.first("show", "reveal") {
                guard let b = parseBool(v) else { return .failure(.invalidParameter(name: "show", value: v)) }
                req.show = b
            }
            req.color = params.first("color")?.lowercased().nilIfEmpty
            req.mode = params.first("mode")?.lowercased().nilIfEmpty
            return done(.newNote(req))
        case "show":
            return done(.show)
        case "hide":
            return done(.hide)
        case "toggle":
            return done(.toggle)
        case "search", "find":
            return done(.search(query: params.first("q", "query", "text", "term") ?? ""))
        case "open", "reveal", "note":
            if let v = params.first("note", "id") ?? (path.count > 1 ? path[1] : nil) {
                let t = v.trimmingCharacters(in: .whitespaces)
                // Any non-zero id: notes created while the database could not be written keep a negative id.
                guard let id = Int64(t), id != 0 else { return .failure(.invalidParameter(name: "note", value: v)) }
                return done(.openNote(id: id))
            }
            if let f = params.first("folder", "f")?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty {
                return done(.openFolder(name: f))
            }
            if action == "open" { return done(.show) }
            return .failure(.missingParameter("note"))
        case "settings", "preferences", "prefs":
            return done(.settings)
        default:
            return .failure(.unknownAction(action))
        }
    }

    // MARK: Query parsing

    public struct QueryItems: Equatable, Sendable {
        public var items: [(name: String, value: String)]
        public static func == (a: QueryItems, b: QueryItems) -> Bool {
            a.items.map(\.name) == b.items.map(\.name) && a.items.map(\.value) == b.items.map(\.value)
        }
        /// First value for any of `names` (names are matched case-insensitively, in the given priority order).
        public func first(_ names: String...) -> String? {
            for n in names {
                if let v = items.first(where: { $0.name == n })?.value { return v }
            }
            return nil
        }
    }

    /// Splits `a=1&b=2;c` into decoded pairs. Keys are lowercased. A key without `=` has an empty value.
    public static func parseQuery<S: StringProtocol>(_ query: S) -> QueryItems {
        var out: [(String, String)] = []
        for part in query.split(separator: "&", omittingEmptySubsequences: true) {
            let pair: (Substring, Substring)
            if let eq = part.firstIndex(of: "=") {
                pair = (Substring(part[..<eq]), Substring(part[part.index(after: eq)...]))
            } else {
                pair = (Substring(part), "")
            }
            let name = decodeComponent(pair.0).trimmingCharacters(in: .whitespaces).lowercased()
            guard !name.isEmpty else { continue }
            out.append((name, decodeComponent(pair.1)))
        }
        return QueryItems(items: out.map { (name: $0.0, value: $0.1) })
    }

    /// Lenient form decoding: `+` → space, valid `%XX` → byte, anything else kept as is.
    /// Bytes are decoded as UTF-8 (invalid sequences become U+FFFD instead of failing).
    public static func decodeComponent<S: StringProtocol>(_ s: S) -> String {
        let u = Array(s.utf8)
        var bytes: [UInt8] = []
        bytes.reserveCapacity(u.count)
        var i = 0
        while i < u.count {
            let c = u[i]
            if c == UInt8(ascii: "+") {
                bytes.append(0x20); i += 1
            } else if c == UInt8(ascii: "%"), i + 2 < u.count, let h = hexValue(u[i + 1]), let l = hexValue(u[i + 2]) {
                bytes.append(h << 4 | l); i += 3
            } else {
                bytes.append(c); i += 1
            }
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    /// "1/0", "true/false", "yes/no", "on/off" (case-insensitive). Empty = true (`?show`).
    public static func parseBool(_ v: String) -> Bool? {
        switch v.trimmingCharacters(in: .whitespaces).lowercased() {
        case "1", "true", "yes", "on", "y", "": return true
        case "0", "false", "no", "off", "n": return false
        default: return nil
        }
    }

    private static func hexValue(_ c: UInt8) -> UInt8? {
        switch c {
        case UInt8(ascii: "0")...UInt8(ascii: "9"): c - UInt8(ascii: "0")
        case UInt8(ascii: "a")...UInt8(ascii: "f"): c - UInt8(ascii: "a") + 10
        case UInt8(ascii: "A")...UInt8(ascii: "F"): c - UInt8(ascii: "A") + 10
        default: nil
        }
    }

    // MARK: Building (for x-callback replies and scripts)

    /// Percent-encodes a query value (everything except unreserved characters).
    public static func encodeComponent(_ s: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        // alphanumerics includes non-ASCII letters; restrict to ASCII.
        return s.unicodeScalars.map { sc -> String in
            if sc.isASCII, allowed.contains(sc) { return String(sc) }
            return String(sc).utf8.map { String(format: "%%%02X", $0) }.joined()
        }.joined()
    }

    /// Appends `name=value` pairs to a callback URL string, keeping any existing query.
    public static func appendingQuery(_ base: String, _ items: [(String, String)]) -> String {
        guard !items.isEmpty else { return base }
        let q = items.map { "\(encodeComponent($0.0))=\(encodeComponent($0.1))" }.joined(separator: "&")
        let sep = base.contains("?") ? (base.hasSuffix("?") || base.hasSuffix("&") ? "" : "&") : "?"
        return base + sep + q
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
