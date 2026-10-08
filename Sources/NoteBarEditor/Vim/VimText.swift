import Foundation
import NoteBarCore

/// Cursor motions understood by the vim layer.
public enum VimMotion: Equatable, Sendable {
    case left, right
    /// Logical lines (operators `dj` / `dk`; plain `j` / `k` move by visual line in the editor).
    case down, up
    case wordForward(big: Bool), wordBackward(big: Bool), wordEnd(big: Bool)
    case lineStart, firstNonBlank, lineEnd
    /// `gg` / `G`. `line` (0-based) set = `{count}gg` / `{count}G`.
    case fileStart(line: Int?), fileEnd(line: Int?)
    /// Return: first non-blank of the next line.
    case nextLineStart
}

/// The text a vim operator acts on.
public struct VimOperatorRange: Equatable, Sendable {
    public var range: NSRange
    /// Whole lines (`dd`, `dj`, `yy`, ...).
    public var linewise: Bool
    public init(range: NSRange, linewise: Bool) { self.range = range; self.linewise = linewise }
}

/// A text change computed by `VimText`: replace `range` with `text`, then put the caret at `caret`.
public struct VimEdit: Equatable, Sendable {
    public var range: NSRange
    public var text: String
    public var caret: Int
    public init(range: NSRange, text: String, caret: Int) { self.range = range; self.text = text; self.caret = caret }
}

/// Pure vim text logic on UTF-16 strings (the editor's text storage, where attachments are one
/// U+FFFC character). No AppKit, so `EditorChecks` can test it directly.
public enum VimText {
    // MARK: Lines

    static func isNL(_ c: unichar) -> Bool { UC.isLineTerminator(c) }

    public static func lineStart(_ s: NSString, _ pos: Int) -> Int {
        var i = min(max(0, pos), s.length)
        while i > 0, !isNL(s.character(at: i - 1)) { i -= 1 }
        return i
    }

    /// Index of the line terminator (or `s.length` on the last line).
    public static func lineEnd(_ s: NSString, _ pos: Int) -> Int {
        var i = min(max(0, pos), s.length)
        while i < s.length, !isNL(s.character(at: i)) { i += 1 }
        return i
    }

    /// End of the line including its terminator (CRLF counts as one terminator).
    static func lineEndIncludingTerminator(_ s: NSString, _ pos: Int) -> Int {
        var e = lineEnd(s, pos)
        if e < s.length {
            if s.character(at: e) == UC.cr, e + 1 < s.length, s.character(at: e + 1) == UC.lf { e += 2 } else { e += 1 }
        }
        return e
    }

    /// The last character a Normal-mode caret may sit on in this line (the line start on an empty line).
    public static func lastCharOfLine(_ s: NSString, _ pos: Int) -> Int {
        let a = lineStart(s, pos), e = lineEnd(s, pos)
        return e > a ? e - 1 : a
    }

    /// First non-blank character of the line. With `marker`, a line marker there (a checkbox) and the
    /// blanks after it are skipped too, unless the marker is all the line holds.
    public static func firstNonBlank(_ s: NSString, _ pos: Int, marker: Marker? = nil) -> Int {
        var i = lineStart(s, pos)
        let e = lineEnd(s, pos)
        while i < e, UC.isSpaceOrTab(s.character(at: i)) { i += 1 }
        if let end = markerPrefixEnd(s, i, lineEnd: e, marker: marker) { return end }
        return i
    }

    /// Says whether the character at a storage index is a line marker (a checkbox attachment). The
    /// Normal-mode caret skips markers like hidden markup, and `0`, `^`, `I`, `cc` keep them.
    public typealias Marker = (Int) -> Bool

    /// End of the marker prefix (marker plus the blanks after it) when `fnb` is a marker followed by
    /// more text on the line; nil otherwise.
    static func markerPrefixEnd(_ s: NSString, _ fnb: Int, lineEnd e: Int, marker: Marker?) -> Int? {
        guard let marker, fnb < e, marker(fnb) else { return nil }
        var j = fnb + 1
        while j < e, UC.isSpaceOrTab(s.character(at: j)) { j += 1 }
        return j < e ? j : nil
    }

    /// Start of the line's text after its indent and marker prefix, when the line has a marker.
    public static func markerContentStart(_ s: NSString, _ pos: Int, marker: Marker?) -> Int? {
        guard marker != nil else { return nil }
        var i = lineStart(s, pos)
        let e = lineEnd(s, pos)
        while i < e, UC.isSpaceOrTab(s.character(at: i)) { i += 1 }
        return markerPrefixEnd(s, i, lineEnd: e, marker: marker)
    }

    /// Normal mode: the caret never sits on a line terminator unless the line is empty, and never on a
    /// marker prefix (indent, checkbox) when the line has text after it.
    public static func clampNormal(_ s: NSString, _ pos: Int, marker: Marker? = nil) -> Int {
        let p = min(max(0, pos), s.length)
        let q = min(p, lastCharOfLine(s, p))
        if let cs = markerContentStart(s, q, marker: marker), q < cs { return cs }
        return q
    }

    /// True when `pos` is inside the marker prefix of its line (there is text after the marker).
    static func inMarkerPrefix(_ s: NSString, _ pos: Int, marker: Marker?) -> Bool {
        guard let cs = markerContentStart(s, pos, marker: marker) else { return false }
        return pos < cs
    }

    /// 0-based line index of `pos`.
    public static func lineIndex(_ s: NSString, _ pos: Int) -> Int {
        var n = 0
        let p = min(max(0, pos), s.length)
        var i = 0
        while i < p {
            let c = s.character(at: i)
            if c == UC.cr, i + 1 < s.length, s.character(at: i + 1) == UC.lf { i += 1 }
            if isNL(c) { n += 1 }
            i += 1
        }
        return n
    }

    public static func lineCount(_ s: NSString) -> Int { lineIndex(s, s.length) + 1 }

    /// Start of 0-based line `n` (clamped to the last line).
    public static func startOfLine(_ s: NSString, _ n: Int) -> Int {
        var i = 0, line = 0
        while line < n {
            let e = lineEnd(s, i)
            if e >= s.length { return lineStart(s, e) }
            i = lineEndIncludingTerminator(s, i)
            line += 1
        }
        return i
    }

    /// Same column (in characters) on the line `delta` lines away, clamped to that line.
    static func verticalTarget(_ s: NSString, _ pos: Int, delta: Int) -> Int {
        let col = pos - lineStart(s, pos)
        let target = max(0, min(lineCount(s) - 1, lineIndex(s, pos) + delta))
        let a = startOfLine(s, target)
        return min(a + col, lastCharOfLine(s, a))
    }

    // MARK: Words

    enum CharClass { case space, word, punct }

    static func charClass(_ c: unichar, big: Bool) -> CharClass {
        if UC.isWhitespace(c) { return .space }
        if big { return .word }
        if c == UC.underscore { return .word }
        if c < 0x80 {
            let isAlnum = (0x30...0x39).contains(c) || (0x41...0x5A).contains(c) || (0x61...0x7A).contains(c)
            return isAlnum ? .word : .punct
        }
        if c == UC.attachment { return .punct }
        return UC.isPunctuation(c) ? .punct : .word
    }

    /// `w` / `W`: start of the next word. An empty line counts as a word.
    public static func wordForward(_ s: NSString, _ pos: Int, big: Bool = false) -> Int {
        let n = s.length
        var i = pos
        guard i < n else { return n }
        let c0 = charClass(s.character(at: i), big: big)
        if c0 != .space { while i < n, charClass(s.character(at: i), big: big) == c0 { i += 1 } }
        while i < n, charClass(s.character(at: i), big: big) == .space {
            if i > pos, isNL(s.character(at: i)), isNL(s.character(at: i - 1)) { return i }
            i += 1
        }
        return i
    }

    /// `e` / `E`: end of the current or next word.
    public static func wordEnd(_ s: NSString, _ pos: Int, big: Bool = false) -> Int {
        let n = s.length
        var i = pos + 1
        while i < n, charClass(s.character(at: i), big: big) == .space { i += 1 }
        guard i < n else { return max(0, n - 1) }
        let c = charClass(s.character(at: i), big: big)
        while i + 1 < n, charClass(s.character(at: i + 1), big: big) == c { i += 1 }
        return i
    }

    /// `b` / `B`: start of the current or previous word. An empty line counts as a word.
    public static func wordBackward(_ s: NSString, _ pos: Int, big: Bool = false) -> Int {
        var i = min(pos, s.length) - 1
        guard i > 0 else { return 0 }
        while i > 0, charClass(s.character(at: i), big: big) == .space {
            if isNL(s.character(at: i)), isNL(s.character(at: i - 1)) { return i }
            i -= 1
        }
        if charClass(s.character(at: i), big: big) == .space { return i }
        let c = charClass(s.character(at: i), big: big)
        while i > 0, charClass(s.character(at: i - 1), big: big) == c { i -= 1 }
        return i
    }

    // MARK: Motions

    /// Where `motion` (repeated `count` times) moves a Normal-mode caret.
    /// With `marker`, the caret skips line markers (see `clampNormal`); `b` and `e` step over them.
    public static func target(_ motion: VimMotion, in s: NSString, from pos: Int, count: Int = 1,
                              marker: Marker? = nil) -> Int {
        let p = rawTarget(motion, in: s, from: pos, count: count, marker: marker)
        if let cs = markerContentStart(s, p, marker: marker), p < cs { return cs }
        return p
    }

    static func rawTarget(_ motion: VimMotion, in s: NSString, from pos: Int, count: Int, marker: Marker?) -> Int {
        let n = max(1, count)
        var p = min(max(0, pos), s.length)
        switch motion {
        case .left:
            p = max(lineStart(s, p), p - n)
        case .right:
            p = min(lastCharOfLine(s, p), p + n)
        case .down:
            p = verticalTarget(s, p, delta: n)
        case .up:
            p = verticalTarget(s, p, delta: -n)
        case .wordForward(let big):
            for _ in 0..<n { p = wordForward(s, p, big: big) }
            p = min(p, max(0, s.length))
        case .wordBackward(let big):
            for _ in 0..<n {
                p = wordBackward(s, p, big: big)
                // Landed on a checkbox: it is not a word; go on to the previous line (or stay on the text).
                while inMarkerPrefix(s, p, marker: marker) {
                    let a = lineStart(s, p)
                    if a == 0 { break }
                    p = wordBackward(s, a, big: big)
                }
            }
        case .wordEnd(let big):
            for _ in 0..<n {
                p = wordEnd(s, p, big: big)
                // Landed on a checkbox (a one-character "word"): go on to the end of the first word after it.
                while inMarkerPrefix(s, p, marker: marker) {
                    let next = wordEnd(s, p, big: big)
                    if next <= p { break }
                    p = next
                }
            }
        case .lineStart:
            p = lineStart(s, p)
        case .firstNonBlank:
            p = firstNonBlank(s, p)
        case .lineEnd:
            // {count}$ goes to the end of the line count-1 lines down.
            if n > 1 { p = verticalTarget(s, p, delta: n - 1) }
            p = lastCharOfLine(s, p)
        case .fileStart(let line):
            p = firstNonBlank(s, startOfLine(s, line ?? 0))
        case .fileEnd(let line):
            p = firstNonBlank(s, startOfLine(s, line ?? (lineCount(s) - 1)))
        case .nextLineStart:
            let e = lineEnd(s, p)
            guard e < s.length else { return clampNormal(s, p) }
            p = firstNonBlank(s, verticalTarget(s, p, delta: n))
        }
        return p
    }

    static func isLinewise(_ m: VimMotion) -> Bool {
        switch m {
        case .down, .up, .fileStart, .fileEnd, .nextLineStart: true
        default: false
        }
    }

    /// The range an operator (`d`, `c`, `y`) acts on for `motion`. `change` applies the `cw` = `ce` rule.
    public static func operatorRange(_ motion: VimMotion, in s: NSString, from pos: Int, count: Int = 1,
                                     change: Bool = false, marker: Marker? = nil) -> VimOperatorRange? {
        let p = min(max(0, pos), s.length)
        if isLinewise(motion) {
            let t = target(motion, in: s, from: p, count: count, marker: marker)
            return linesRange(s, from: p, to: t)
        }
        var m = motion
        if change, case .wordForward(let big) = motion, p < s.length, !UC.isWhitespace(s.character(at: p)) {
            m = .wordEnd(big: big)
            // `cw` on the last character of a word changes only that word.
            if p + 1 < s.length, charClass(s.character(at: p + 1), big: big) != charClass(s.character(at: p), big: big) {
                return VimOperatorRange(range: NSRange(location: p, length: 1), linewise: false)
            }
        }
        var r: NSRange
        switch m {
        case .right:
            let e = min(lineEnd(s, p), p + max(1, count))
            r = NSRange(location: p, length: e - p)
        case .lineEnd:
            var e = lineEnd(s, p)
            if count > 1 { e = lineEnd(s, verticalTarget(s, p, delta: count - 1)) }
            r = NSRange(location: p, length: e - p)
        case .wordEnd:
            let t = target(m, in: s, from: p, count: count, marker: marker)
            r = NSRange(location: p, length: min(s.length, t + 1) - p)
        case .wordForward:
            var t = target(m, in: s, from: p, count: count, marker: marker)
            // `dw` on the last word of a line stops at the end of the line.
            let e = lineEnd(s, p)
            if t > e, e > p { t = e }
            r = NSRange(location: p, length: t - p)
        default:
            let t = target(m, in: s, from: p, count: count, marker: marker)
            r = t < p ? NSRange(location: t, length: p - t) : NSRange(location: p, length: t - p)
        }
        return r.length > 0 ? VimOperatorRange(range: r, linewise: false) : nil
    }

    /// Whole lines from the line of `a` to the line of `b` (terminator of the last line included).
    public static func linesRange(_ s: NSString, from a: Int, to b: Int) -> VimOperatorRange {
        let lo = lineStart(s, min(a, b))
        let hi = lineEndIncludingTerminator(s, max(a, b))
        return VimOperatorRange(range: NSRange(location: lo, length: hi - lo), linewise: true)
    }

    // MARK: Edits

    /// Deleting whole lines: also removes the line break before them when they are the last lines.
    public static func linewiseDeleteRange(_ s: NSString, _ r: NSRange) -> NSRange {
        var r = r
        if r.end == s.length, r.location > 0, r.length == 0 || !isNL(s.character(at: r.end - 1)) {
            r = NSRange(location: r.location - 1, length: r.length + 1)
        }
        return r
    }

    /// Register text for whole lines: always ends with one line break.
    public static func linewiseRegister(_ text: String) -> String {
        text.hasSuffix("\n") || text.hasSuffix("\r") ? text : text + "\n"
    }

    /// `p` (after) / `P` (before) with the register `text`.
    public static func paste(_ text: String, linewise: Bool, before: Bool, in s: NSString, at pos: Int, count: Int = 1) -> VimEdit? {
        guard !text.isEmpty else { return nil }
        let p = min(max(0, pos), s.length)
        let n = max(1, count)
        if linewise {
            let body = String(repeating: linewiseRegister(text), count: n)
            if before {
                let a = lineStart(s, p)
                return VimEdit(range: NSRange(location: a, length: 0), text: body, caret: firstNonBlank(body as NSString, 0) + a)
            }
            let e = lineEnd(s, p)
            if e >= s.length {
                // Last line has no line break: add one before the pasted lines and drop the trailing one.
                let ins = "\n" + String(body.dropLast())
                return VimEdit(range: NSRange(location: s.length, length: 0), text: ins,
                               caret: s.length + 1 + firstNonBlank(ins as NSString, 1) - 1)
            }
            let at = lineEndIncludingTerminator(s, p)
            return VimEdit(range: NSRange(location: at, length: 0), text: body, caret: at + firstNonBlank(body as NSString, 0))
        }
        let body = String(repeating: text, count: n)
        let len = (body as NSString).length
        var at = p
        if !before, p < lineEnd(s, p) { at = p + 1 }
        return VimEdit(range: NSRange(location: at, length: 0), text: body, caret: at + len - 1)
    }

    /// `o` (below) / `O` (above): a new empty line, caret on it.
    public static func openLine(below: Bool, in s: NSString, at pos: Int) -> VimEdit {
        if below {
            let e = lineEnd(s, pos)
            return VimEdit(range: NSRange(location: e, length: 0), text: "\n", caret: e + 1)
        }
        let a = lineStart(s, pos)
        return VimEdit(range: NSRange(location: a, length: 0), text: "\n", caret: a)
    }
}

// MARK: - Ex commands

/// Result of parsing a `:` command line.
public enum VimExCommand: Equatable, Sendable {
    case card(VimCardCommand)
    /// `:w`.
    case write
    /// `:{n}`: 1-based line.
    case goToLine(Int)
    /// `:noh`.
    case noHighlight
    case error(String)
    /// Empty command line.
    case none
}

public enum VimEx {
    static let colorAliases: [String: NoteColor] = ["default": .none, "none": .none, "clear": .none, "no": .none]
    static let modeAliases: [String: NoteMode] = ["standard": .standard, "markdown": .standard, "md": .standard,
                                                  "code": .code, "plain": .plain, "text": .plain]

    public static func parse(_ line: String) -> VimExCommand {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return .none }
        if let n = Int(trimmed) { return .goToLine(max(1, n)) }
        let parts = trimmed.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        let name = parts[0].lowercased()
        let arg = parts.count > 1 ? String(parts[1]).trimmingCharacters(in: .whitespaces) : ""
        switch name {
        case "w", "w!", "write": return .write
        case "q", "q!", "quit", "wq", "wq!", "x", "x!", "xit", "exit": return .card(.quit)
        case "pin", "p", "unpin": return .card(.togglePin)
        case "fold", "fo": return .card(.setFolded(true))
        case "unfold", "foldopen": return .card(.setFolded(false))
        case "copy", "y", "yank", "co": return .card(.copyNote)
        case "delete", "d", "del": return .card(.delete)
        case "noh", "nohl", "nohlsearch": return .noHighlight
        case "format", "fmt": return .card(.showFormatMenu)
        case "color", "colour", "col":
            guard !arg.isEmpty else { return .card(.showColorMenu) }
            guard let c = color(named: arg) else { return .error("Unknown color “\(arg)”") }
            return .card(.setColor(c))
        case "mode":
            guard !arg.isEmpty else { return .card(.showColorMenu) }
            guard let m = mode(named: arg) else { return .error("Unknown mode “\(arg)” (standard, code, plain)") }
            return .card(.setMode(m))
        case "move", "m", "mv":
            return arg.isEmpty ? .card(.showMoveMenu) : .card(.moveToFolder(arg))
        default:
            return .error("Not a command: \(trimmed)")
        }
    }

    /// Exact name or alias first, then a unique prefix ("pur" = purple).
    static func color(named raw: String) -> NoteColor? {
        let k = raw.lowercased()
        if let c = colorAliases[k] ?? NoteColor(rawValue: k) { return c }
        let hits = NoteColor.allCases.filter { $0 != .none && $0.rawValue.hasPrefix(k) }
        return hits.count == 1 ? hits[0] : nil
    }

    static func mode(named raw: String) -> NoteMode? {
        let k = raw.lowercased()
        if let m = modeAliases[k] { return m }
        let hits = Set(modeAliases.filter { $0.key.hasPrefix(k) }.map(\.value))
        return hits.count == 1 ? hits.first : nil
    }
}
