import AppKit
import NoteBarCore

/// Lightweight read-only rendering of a note body, used for cards that have no live editor yet
/// (far from the viewport). Its height is close to the editor's so the list barely shifts when the
/// editor replaces it.
@MainActor
final class NotePreviewView: NSView {
    private var text = NSAttributedString()
    private var cachedWidth: CGFloat = -1
    private var cachedHeight: CGFloat = 0
    var onClick: ((NSEvent) -> Void)?

    override var isFlipped: Bool { true }

    func configure(note: Note, env: AppEnvironment, appearance: NSAppearance) {
        text = Self.render(note: note, env: env, appearance: appearance)
        cachedWidth = -1
        needsDisplay = true
    }

    func height(forWidth width: CGFloat) -> CGFloat {
        if width == cachedWidth { return cachedHeight }
        let r = text.boundingRect(with: NSSize(width: max(1, width), height: .greatestFiniteMagnitude),
                                  options: [.usesLineFragmentOrigin, .usesFontLeading])
        cachedWidth = width
        cachedHeight = max(Metrics.minEditorHeight, ceil(r.height))
        return cachedHeight
    }

    override func draw(_ dirtyRect: NSRect) {
        text.draw(with: bounds, options: [.usesLineFragmentOrigin, .usesFontLeading, .truncatesLastVisibleLine])
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    static func render(note: Note, env: AppEnvironment, appearance: NSAppearance) -> NSAttributedString {
        let size = env.themes.fontSize
        let code = note.mode == .code
        let bodyFont: NSFont = code ? .monospacedSystemFont(ofSize: size - 1, weight: .regular) : .systemFont(ofSize: size)
        let textColor = env.themes.color(\.text, appearance: appearance)
        let titleColor = env.themes.cardTitle(note.color, appearance: appearance)
        let linkColor = env.themes.color(\.link, appearance: appearance)
        let para = NSMutableParagraphStyle()
        para.lineBreakMode = .byWordWrapping
        let out = NSMutableAttributedString()
        var sawTitle = false
        let lines = note.body.components(separatedBy: "\n")
        for (i, raw) in lines.enumerated() {
            var line = raw
            var attrs: [NSAttributedString.Key: Any] = [.font: bodyFont, .foregroundColor: textColor, .paragraphStyle: para]
            if !code {
                for (prefix, repl) in [("- [ ] ", "○ "), ("- [x] ", "◉ "), ("- [X] ", "◉ "), ("* [ ] ", "○ "), ("* [x] ", "◉ ")]
                where line.hasPrefix(prefix) {
                    line = repl + line.dropFirst(prefix.count)
                }
            }
            if !sawTitle, !line.trimmingCharacters(in: .whitespaces).isEmpty {
                sawTitle = true
                if !code {
                    attrs[.font] = NSFont.systemFont(ofSize: size, weight: .bold)
                    attrs[.foregroundColor] = titleColor
                    line = NoteText.title(of: line)
                }
            }
            let piece = NSMutableAttributedString(string: line, attributes: attrs)
            // Attachment tokens -> their names, in the link color.
            for m in AttachmentLink.matches(in: piece.string).reversed() {
                let label = (m.isImage ? "▣ " : "◫ ") + (m.name.isEmpty ? "Attachment" : m.name)
                piece.replaceCharacters(in: m.nsRange, with: NSAttributedString(string: label, attributes: attrs.merging([.foregroundColor: linkColor]) { $1 }))
                if m.isImage {
                    // Images render full width in the editor: reserve some height so the list shifts less.
                    let tall = NSMutableParagraphStyle()
                    tall.paragraphSpacing = 110
                    piece.addAttribute(.paragraphStyle, value: tall, range: NSRange(location: 0, length: piece.length))
                }
            }
            out.append(piece)
            if i < lines.count - 1 { out.append(NSAttributedString(string: "\n", attributes: attrs)) }
        }
        if out.length == 0 {
            out.append(NSAttributedString(string: " ", attributes: [.font: bodyFont]))
        }
        return out
    }
}
