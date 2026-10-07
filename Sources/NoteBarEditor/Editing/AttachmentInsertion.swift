import Foundation

/// Where attachment tokens go when files / images are inserted: images on their own line,
/// file shortcuts inline (several tiles can share a line), separated from surrounding text.
public enum AttachmentInsertion {
    /// `items` = (token markdown, isImage). Replaces the selection; the caret ends after the inserted tokens.
    public static func insert(_ items: [(String, Bool)], into text: String, selection sel: NSRange) -> TextEditResult {
        let ns = text as NSString
        let before: unichar? = sel.location > 0 ? ns.character(at: sel.location - 1) : nil
        let after: unichar? = sel.end < ns.length ? ns.character(at: sel.end) : nil
        var out = ""
        var lastIsImage = false
        func lastChar() -> unichar? { out.utf16.last ?? before }
        for (token, isImage) in items {
            let prev = lastChar()
            if isImage {
                if let prev, !UC.isLineTerminator(prev) { out += "\n" }
            } else if lastIsImage {
                if let prev, !UC.isLineTerminator(prev) { out += "\n" }
            } else if let prev, !UC.isWhitespace(prev) {
                out += " "
            }
            out += token
            lastIsImage = isImage
        }
        if let after {
            if lastIsImage, !UC.isLineTerminator(after) { out += "\n" }
            else if !lastIsImage, !UC.isWhitespace(after) { out += " " }
        }
        let m = NSMutableString(string: text)
        m.replaceCharacters(in: sel, with: out)
        return TextEditResult(text: m as String, selection: NSRange(location: sel.location + (out as NSString).length, length: 0))
    }
}
