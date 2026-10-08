import AppKit
import NoteBarCore

/// Copy button on the fence bar of the fenced code block under the pointer (Standard notes).
extension MarkdownNoteEditor {
    /// Where copied code goes (checks use a private pasteboard).
    @MainActor static var codeCopyPasteboard: NSPasteboard = .general

    /// The code block (storage range, fences included) at `point` (text view coordinates), or nil.
    func codeBlockRange(at point: NSPoint) -> NSRange? {
        guard mode == .standard, textStorage.length > 0 else { return nil }
        let lm = layoutManagerNB
        let o = textView.textContainerOrigin
        let p = NSPoint(x: point.x - o.x, y: point.y - o.y)
        var fraction: CGFloat = 0
        let g = lm.glyphIndex(for: p, in: container, fractionOfDistanceThroughGlyph: &fraction)
        guard g < lm.numberOfGlyphs else { return nil }
        let frag = lm.lineFragmentRect(forGlyphAt: g, effectiveRange: nil)
        guard p.y >= frag.minY, p.y <= frag.maxY else { return nil }
        let ci = lm.characterIndexForGlyph(at: g)
        guard ci < textStorage.length, textStorage.attribute(.nbCodeBlock, at: ci, effectiveRange: nil) != nil else { return nil }
        var full = NSRange()
        textStorage.attribute(.nbCodeBlock, at: ci, longestEffectiveRange: &full, in: NSRange(location: 0, length: textStorage.length))
        return full
    }

    /// The code inside a block (the lines between the fences).
    func code(inBlock block: NSRange) -> String {
        let lines = currentLines().filter { $0.kind == .code && NSIntersectionRange($0.range, block).length == $0.range.length && $0.range.location >= block.location && $0.range.end <= block.end }
        guard let first = lines.first, let last = lines.last else { return "" }
        return markdown(for: NSRange(location: first.range.location, length: last.range.end - first.range.location))
    }

    /// Mouse moved over the text: show the copy button on the block under the pointer.
    func updateCodeCopyButton(at point: NSPoint?) {
        guard let point, let block = codeBlockRange(at: point) else { hideCodeCopyButton(); return }
        let lm = layoutManagerNB
        let gr = lm.glyphRange(forCharacterRange: NSRange(location: block.location, length: 1), actualCharacterRange: nil)
        guard gr.length > 0 else { hideCodeCopyButton(); return }
        let top = lm.lineFragmentRect(forGlyphAt: gr.location, effectiveRange: nil)
        let o = textView.textContainerOrigin
        let size = max(12, min(top.height, style.fenceBarHeight) - 2)
        let frame = NSRect(x: o.x + container.size.width - size - 6, y: o.y + top.minY + (top.height - size) / 2,
                           width: size, height: size)
        let b = codeCopyButton ?? makeCodeCopyButton()
        b.frame = frame
        b.contentTintColor = style.secondary
        b.isHidden = false
        codeCopyBlock = block
    }

    func hideCodeCopyButton() {
        codeCopyButton?.isHidden = true
        codeCopyBlock = nil
    }

    private func makeCodeCopyButton() -> NSButton {
        let b = NSButton(image: Self.copySymbol("doc.on.doc"), target: self, action: #selector(copyCodeBlock(_:)))
        b.isBordered = false
        b.imageScaling = .scaleProportionallyDown
        b.refusesFirstResponder = true
        b.toolTip = "Copy Code"
        b.setAccessibilityLabel("Copy code")
        textView.addSubview(b)
        codeCopyButton = b
        return b
    }

    static func copySymbol(_ name: String) -> NSImage {
        let img = NSImage(systemSymbolName: name, accessibilityDescription: "Copy")
            ?? NSImage(size: NSSize(width: 12, height: 12))
        return img.withSymbolConfiguration(.init(pointSize: 10, weight: .medium)) ?? img
    }

    @objc func copyCodeBlock(_ sender: Any?) {
        guard let block = codeCopyBlock, block.end <= textStorage.length else { return }
        let pb = Self.codeCopyPasteboard
        pb.clearContents()
        pb.setString(code(inBlock: block), forType: .string)
        // Short confirmation: a checkmark for a moment.
        codeCopyButton?.image = Self.copySymbol("checkmark")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            self?.codeCopyButton?.image = Self.copySymbol("doc.on.doc")
        }
    }
}

// MARK: - Checks

extension MarkdownNoteEditor {
    /// Hovers the point (text view coordinates). Returns the copy button frame, or nil when hidden.
    public func hoverForTesting(_ point: NSPoint?) -> NSRect? {
        updateCodeCopyButton(at: point)
        guard let b = codeCopyButton, !b.isHidden else { return nil }
        return b.frame
    }
    /// Clicks the copy button.
    public func clickCodeCopyForTesting() { copyCodeBlock(nil) }
    public static var codeCopyPasteboardForTesting: NSPasteboard {
        get { codeCopyPasteboard }
        set { codeCopyPasteboard = newValue }
    }
    /// The rect of the line fragment for storage character `index` (text view coordinates).
    public func lineRectForTesting(at index: Int) -> NSRect {
        let lm = layoutManagerNB
        lm.ensureLayout(for: container)
        let g = lm.glyphIndexForCharacter(at: min(index, max(0, textStorage.length - 1)))
        let r = lm.lineFragmentRect(forGlyphAt: g, effectiveRange: nil)
        let o = textView.textContainerOrigin
        return r.offsetBy(dx: o.x, dy: o.y)
    }
}
