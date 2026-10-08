import AppKit
import NoteBarCore

extension NSAttributedString.Key {
    /// Bool. A markdown marker character that is hidden in "invisible markdown" mode.
    static let nbMarker = NSAttributedString.Key("NoteBar.marker")
    /// Bool. Character of a code fence line (the line collapses when its markers are hidden).
    static let nbFence = NSAttributedString.Key("NoteBar.fence")
    /// Int (1/2, alternating per block). Characters of a fenced code block (box drawn behind).
    static let nbCodeBlock = NSAttributedString.Key("NoteBar.codeBlock")
    /// NSColor. Rounded highlight drawn behind `==marked==` text.
    static let nbHighlight = NSAttributedString.Key("NoteBar.highlight")
    /// NSColor. Color swatch drawn in the (widened) slot of this `#` character.
    static let nbSwatch = NSAttributedString.Key("NoteBar.swatch")
    /// NSColor. Color of the `#` redrawn after the swatch (the glyph itself is drawn clear).
    static let nbSwatchText = NSAttributedString.Key("NoteBar.swatchText")
    /// Bool. List marker character drawn as a bullet glyph.
    static let nbBullet = NSAttributedString.Key("NoteBar.bullet")
    /// Bool. Horizontal rule line.
    static let nbRule = NSAttributedString.Key("NoteBar.rule")
}

/// Resolved fonts and colors for one editor (theme × appearance × note color × mode).
final class EditorStyle {
    let fontSize: CGFloat
    let isDark: Bool
    let mode: NoteMode
    let text, secondary, link, inlineCode, codeBackground, highlight, quote, markup, title, checkbox, ruleColor: NSColor
    let hideMarkup: Bool

    let lineSpacing: CGFloat = 2
    let tabInterval: CGFloat = 24
    /// Size of small captions (file tile names, image placeholder labels). Relative to the theme size.
    var captionSize: CGFloat { round(fontSize * 0.75 * 10) / 10 }
    /// Extra indent of the continuation rows of a wrapped code line (code lines wrap by character).
    var codeContinuationIndent: CGFloat { round(fontSize * 0.9) }
    var swatchDiameter: CGFloat { round(fontSize * 0.72) }
    var swatchGap: CGFloat { 3 }
    var swatchReserve: CGFloat { swatchDiameter + swatchGap }
    var checkboxDiameter: CGFloat { round(fontSize * 1.15) }
    var checkboxGap: CGFloat { round(fontSize * 0.45) }

    private var fontCache: [String: NSFont] = [:]
    private var widthCache: [String: CGFloat] = [:]
    private var paragraphCache: [String: NSParagraphStyle] = [:]

    @MainActor
    init(themes: ThemeManager, appearance: NSAppearance, color: NoteColor, mode: NoteMode, hideMarkup: Bool) {
        let p = themes.palette(for: appearance)
        func c(_ hex: String, _ fallback: NSColor) -> NSColor { NSColor(hex: hex) ?? fallback }
        fontSize = themes.fontSize
        isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        self.mode = mode
        self.hideMarkup = hideMarkup
        text = c(p.text, .labelColor)
        secondary = c(p.secondaryText, .secondaryLabelColor)
        link = c(p.link, .linkColor)
        inlineCode = c(p.inlineCode, .systemBlue)
        codeBackground = c(p.codeBlockBackground, .quaternaryLabelColor)
        highlight = c(p.highlight, .systemYellow)
        quote = c(p.quote, .systemBrown)
        markup = c(p.markup, .tertiaryLabelColor)
        title = themes.cardTitle(color, appearance: appearance)
        checkbox = link
        ruleColor = secondary.withAlphaComponent(0.35)
    }

    /// Test / fallback initializer with explicit values (`fontSize` default = theme default, 14 pt).
    init(fontSize: CGFloat = 14, isDark: Bool = false, mode: NoteMode = .standard, hideMarkup: Bool = false) {
        self.fontSize = fontSize; self.isDark = isDark; self.mode = mode; self.hideMarkup = hideMarkup
        text = .labelColor; secondary = .secondaryLabelColor; link = .linkColor; inlineCode = .systemBlue
        codeBackground = .quaternaryLabelColor; highlight = .systemYellow; quote = .systemBrown
        markup = .tertiaryLabelColor; title = .labelColor; checkbox = .systemBlue; ruleColor = .separatorColor
    }

    // MARK: Fonts

    var bodyFont: NSFont { font(size: fontSize) }
    var monoSize: CGFloat { max(8, fontSize - 1) }
    var monoFont: NSFont { font(size: monoSize, mono: true) }

    func headingSize(_ level: Int) -> CGFloat {
        switch level {
        case 1: round(fontSize * 1.45)
        case 2: round(fontSize * 1.25)
        case 3: round(fontSize * 1.1)
        default: fontSize
        }
    }

    var titleSize: CGFloat { fontSize + 2 }

    /// Code fence lines (```` ```lang ````): a small mono font in a bar of fixed height, so the block does
    /// not move when its backticks are shown or hidden.
    var fenceSize: CGFloat { max(8, round(fontSize * 0.78)) }
    var fenceFont: NSFont { font(size: fenceSize, mono: true) }
    var fenceBarHeight: CGFloat {
        let f = fenceFont
        return ceil(f.ascender - f.descender + f.leading) + 6
    }

    func font(size: CGFloat, bold: Bool = false, italic: Bool = false, mono: Bool = false) -> NSFont {
        let key = "\(size)|\(bold)|\(italic)|\(mono)"
        if let f = fontCache[key] { return f }
        var f: NSFont = mono ? .monospacedSystemFont(ofSize: size, weight: bold ? .bold : .regular)
                             : .systemFont(ofSize: size, weight: bold ? .bold : .regular)
        if italic {
            let d = f.fontDescriptor.withSymbolicTraits(f.fontDescriptor.symbolicTraits.union(.italic))
            if let i = NSFont(descriptor: d, size: size) { f = i }
        }
        fontCache[key] = f
        return f
    }

    func width(of s: String, font: NSFont) -> CGFloat {
        let key = "\(font.fontName)|\(font.pointSize)|\(s)"
        if let w = widthCache[key] { return w }
        let w = (s as NSString).size(withAttributes: [.font: font]).width
        widthCache[key] = w
        return w
    }

    // MARK: Paragraph styles

    struct ParagraphKey: Hashable {
        var head: CGFloat = 0
        var first: CGFloat = 0
        var tail: CGFloat = 0
        var spacingAfter: CGFloat = 0
        var spacingBefore: CGFloat = 0
        var tab: CGFloat = 24
        var lineSpacing: CGFloat = 2
        /// Code lines: break by character (no word wrap). Wrapped rows start at `head`, a visible continuation indent.
        var charWrap = false
    }

    func paragraphStyle(_ k: ParagraphKey) -> NSParagraphStyle {
        let key = "\(k.head)|\(k.first)|\(k.tail)|\(k.spacingAfter)|\(k.spacingBefore)|\(k.tab)|\(k.lineSpacing)|\(k.charWrap)"
        if let p = paragraphCache[key] { return p }
        let p = NSMutableParagraphStyle()
        p.headIndent = k.head
        p.firstLineHeadIndent = k.first
        p.tailIndent = k.tail
        p.paragraphSpacing = k.spacingAfter
        p.paragraphSpacingBefore = k.spacingBefore
        p.lineSpacing = k.lineSpacing
        p.tabStops = []
        p.defaultTabInterval = k.tab
        // Code lines never break at words: they wrap by character, so a long token cannot
        // push the code box taller at a word boundary. See `ParagraphKey.charWrap`.
        p.lineBreakMode = k.charWrap ? .byCharWrapping : .byWordWrapping
        paragraphCache[key] = p
        return p
    }

    /// Advance of the leading whitespace (tabs snap to the tab interval).
    func indentWidth(_ s: String, font: NSFont, tab: CGFloat) -> CGFloat {
        var x: CGFloat = 0
        let space = width(of: " ", font: font)
        for ch in s.utf16 {
            if ch == UC.tab { x = (floor(x / tab) + 1) * tab } else { x += space }
        }
        return x
    }
}
