import Foundation

/// UTF-16 code units used by the parsers. All markdown syntax is ASCII, so scanning UTF-16 units is safe
/// (surrogate halves are never mistaken for syntax).
enum UC {
    static let tab: unichar = 0x09
    static let lf: unichar = 0x0A
    static let cr: unichar = 0x0D
    static let space: unichar = 0x20
    static let bang: unichar = 0x21
    static let dquote: unichar = 0x22
    static let hash: unichar = 0x23
    static let amp: unichar = 0x26
    static let apos: unichar = 0x27
    static let lparen: unichar = 0x28
    static let rparen: unichar = 0x29
    static let star: unichar = 0x2A
    static let plus: unichar = 0x2B
    static let dash: unichar = 0x2D
    static let dot: unichar = 0x2E
    static let slash: unichar = 0x2F
    static let zero: unichar = 0x30
    static let nine: unichar = 0x39
    static let colon: unichar = 0x3A
    static let lt: unichar = 0x3C
    static let eq: unichar = 0x3D
    static let gt: unichar = 0x3E
    static let lbracket: unichar = 0x5B
    static let backslash: unichar = 0x5C
    static let rbracket: unichar = 0x5D
    static let underscore: unichar = 0x5F
    static let backtick: unichar = 0x60
    static let tilde: unichar = 0x7E
    static let lowerX: unichar = 0x78
    static let upperX: unichar = 0x58
    /// U+FFFC OBJECT REPLACEMENT CHARACTER (attachment character).
    static let attachment: unichar = 0xFFFC

    static func isWhitespace(_ c: unichar) -> Bool {
        switch c {
        case 0x20, 0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0xA0, 0x1680, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000, 0x85: return true
        case 0x2000...0x200A: return true
        default: return false
        }
    }

    static func isLineTerminator(_ c: unichar) -> Bool {
        c == lf || c == cr || c == 0x2028 || c == 0x2029 || c == 0x85
    }

    static func isSpaceOrTab(_ c: unichar) -> Bool { c == space || c == tab }

    static func isASCIIPunctuation(_ c: unichar) -> Bool {
        (0x21...0x2F).contains(c) || (0x3A...0x40).contains(c) || (0x5B...0x60).contains(c) || (0x7B...0x7E).contains(c)
    }

    private static let punctuation: CharacterSet = CharacterSet.punctuationCharacters.union(.symbols)

    static func isPunctuation(_ c: unichar) -> Bool {
        if c < 0x80 { return isASCIIPunctuation(c) }
        if c >= 0xD800 && c <= 0xDFFF { return false }
        guard let s = Unicode.Scalar(c) else { return false }
        return punctuation.contains(s)
    }

    static func isDigit(_ c: unichar) -> Bool { c >= zero && c <= nine }

    static func isHexDigit(_ c: unichar) -> Bool {
        isDigit(c) || (c >= 0x41 && c <= 0x46) || (c >= 0x61 && c <= 0x66)
    }

    /// Letters, digits, underscore, and any non-ASCII non-punctuation unit (covers CJK, emoji halves).
    static func isWordChar(_ c: unichar) -> Bool {
        if c < 0x80 {
            return isDigit(c) || (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A) || c == underscore
        }
        return !isWhitespace(c) && !isPunctuation(c)
    }
}

extension NSString {
    /// Characters of `range` copied into an array (fast random access for the parsers).
    func characters(in range: NSRange) -> [unichar] {
        guard range.length > 0 else { return [] }
        var buf = [unichar](repeating: 0, count: range.length)
        getCharacters(&buf, range: range)
        return buf
    }
}

extension NSRange {
    @inline(__always) var end: Int { location + length }

    /// True when the ranges overlap or touch (inclusive ends). Used for caret-in-span checks.
    func touches(_ other: NSRange) -> Bool {
        other.location <= end && other.end >= location
    }

    func contains(index: Int) -> Bool { index >= location && index < end }

    func offset(by delta: Int) -> NSRange { NSRange(location: location + delta, length: length) }
}
