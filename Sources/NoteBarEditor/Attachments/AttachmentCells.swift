import AppKit
import NoteBarCore

/// Shared state for one editor's attachment cells (style, store access, invalidation callback).
@MainActor
final class EditorContext {
    let env: AppEnvironment
    var style: EditorStyle
    /// Called when a cell's size or content changed (image loaded...).
    var onCellUpdate: ((NSTextAttachment) -> Void)?
    private var urls: [AttachmentID: URL?] = [:]

    init(env: AppEnvironment, style: EditorStyle) {
        self.env = env
        self.style = style
    }

    func attachment(_ id: AttachmentID) -> Attachment? { env.store.attachment(id: id) }

    /// Resolved file URL (cached; bookmark resolution can be slow).
    func url(for id: AttachmentID) -> URL? {
        if let u = urls[id] { return u }
        let u = attachment(id).flatMap { env.store.url(for: $0) }
        urls[id] = u
        return u
    }

    func forgetURLs() { urls.removeAll() }

    func cellDidUpdate(_ cell: NSTextAttachmentCell) {
        guard let a = cell.attachment else { return }
        onCellUpdate?(a)
    }

    /// Creates the attachment (with its cell) for a token.
    func makeAttachment(_ token: EmbedToken) -> NSTextAttachment {
        let a = EmbedAttachment(token: token)
        a.attachmentCell = makeCell(token)
        return a
    }

    func makeCell(_ token: EmbedToken) -> NSTextAttachmentCell {
        switch token {
        case .checkbox(let checked, _):
            CheckboxCell(checked: checked, context: self)
        case .attachment(let id, let isImage, let name, _):
            isImage ? ImageAttachmentCell(id: id, name: name, context: self)
                    : FileAttachmentCell(id: id, name: name, context: self)
        }
    }
}

/// Base class: cells draw with the editor style and never track the mouse themselves
/// (the text view handles clicks so it can toggle / open without moving the caret).
class EmbedCell: NSTextAttachmentCell {
    weak var context: EditorContext?

    init(context: EditorContext) {
        self.context = context
        super.init(textCell: "")
    }

    required init(coder: NSCoder) { fatalError("not supported") }

    var style: EditorStyle { MainActor.assumeIsolated { context?.style } ?? EditorStyle() }

    override func wantsToTrackMouse() -> Bool { false }
    override func wantsToTrackMouse(for theEvent: NSEvent, in cellFrame: NSRect, of controlView: NSView?, atCharacterIndex charIndex: Int) -> Bool { false }

    override func draw(withFrame cellFrame: NSRect, in controlView: NSView?, characterIndex charIndex: Int, layoutManager: NSLayoutManager) {
        draw(withFrame: cellFrame, in: controlView)
    }

    override func draw(withFrame cellFrame: NSRect, in controlView: NSView?, characterIndex charIndex: Int) {
        draw(withFrame: cellFrame, in: controlView)
    }

    override func highlight(_ flag: Bool, withFrame cellFrame: NSRect, in controlView: NSView?) {}
}

// MARK: - Checkbox

final class CheckboxCell: EmbedCell {
    let checked: Bool

    init(checked: Bool, context: EditorContext) {
        self.checked = checked
        super.init(context: context)
    }

    required init(coder: NSCoder) { fatalError("not supported") }

    override func cellFrame(for textContainer: NSTextContainer, proposedLineFragment lineFrag: NSRect,
                            glyphPosition position: NSPoint, characterIndex charIndex: Int) -> NSRect {
        let st = style
        let d = st.checkboxDiameter
        let font = (textContainer.layoutManager?.textStorage?.attribute(.font, at: charIndex, effectiveRange: nil) as? NSFont) ?? st.bodyFont
        let y = (font.capHeight - d) / 2
        return NSRect(x: 0, y: y.rounded(), width: d + st.checkboxGap, height: d)
    }

    override func draw(withFrame cellFrame: NSRect, in controlView: NSView?) {
        let st = style
        let d = st.checkboxDiameter
        let box = NSRect(x: cellFrame.minX + 0.75, y: cellFrame.minY + (cellFrame.height - d) / 2 + 0.75,
                         width: d - 1.5, height: d - 1.5)
        let circle = NSBezierPath(ovalIn: box)
        if checked {
            st.checkbox.setFill()
            circle.fill()
            let check = NSBezierPath()
            let w = box.width, h = box.height
            // Flipped coordinates (y grows down).
            check.move(to: NSPoint(x: box.minX + w * 0.28, y: box.minY + h * 0.52))
            check.line(to: NSPoint(x: box.minX + w * 0.44, y: box.minY + h * 0.68))
            check.line(to: NSPoint(x: box.minX + w * 0.73, y: box.minY + h * 0.35))
            check.lineWidth = max(1.4, d * 0.11)
            check.lineCapStyle = .round
            check.lineJoinStyle = .round
            NSColor.white.setStroke()
            check.stroke()
        } else {
            st.text.withAlphaComponent(st.isDark ? 0.06 : 0.04).setFill()
            circle.fill()
            st.secondary.withAlphaComponent(0.7).setStroke()
            circle.lineWidth = 1.2
            circle.stroke()
        }
    }
}

// MARK: - Image

final class ImageAttachmentCell: EmbedCell {
    let attachmentID: AttachmentID
    let name: String
    private(set) var loadedImage: NSImage?
    private var loading = false
    private(set) var isMissing = false

    static let maxHeight: CGFloat = 400
    static let placeholderHeight: CGFloat = 72
    static let verticalMargin: CGFloat = 4
    static let cornerRadius: CGFloat = 8

    init(id: AttachmentID, name: String, context: EditorContext) {
        self.attachmentID = id
        self.name = name
        super.init(context: context)
    }

    required init(coder: NSCoder) { fatalError("not supported") }

    var url: URL? { MainActor.assumeIsolated { context?.url(for: attachmentID) } }

    private func ensureLoaded() {
        guard loadedImage == nil, !loading, !isMissing else { return }
        MainActor.assumeIsolated {
            guard let url = context?.url(for: attachmentID) else { isMissing = true; return }
            if let img = AttachmentResources.shared.cachedImage(url) { loadedImage = img; return }
            loading = true
            AttachmentResources.shared.loadImage(url) { [weak self] img in
                guard let self else { return }
                self.loading = false
                self.loadedImage = img
                self.isMissing = img == nil
                self.context?.cellDidUpdate(self)
            }
        }
    }

    /// Size for an available width.
    func imageSize(available: CGFloat) -> NSSize {
        let avail = max(20, floor(available))
        guard let img = loadedImage, img.size.width > 0, img.size.height > 0 else {
            return NSSize(width: avail, height: Self.placeholderHeight)
        }
        let aspect = img.size.height / img.size.width
        var w = min(avail, img.size.width)
        var h = w * aspect
        if h > Self.maxHeight { h = Self.maxHeight; w = h / aspect }
        return NSSize(width: floor(w), height: floor(h))
    }

    override func cellFrame(for textContainer: NSTextContainer, proposedLineFragment lineFrag: NSRect,
                            glyphPosition position: NSPoint, characterIndex charIndex: Int) -> NSRect {
        ensureLoaded()
        let available = lineFrag.width - position.x - textContainer.lineFragmentPadding * 2 - 1
        let size = imageSize(available: available)
        return NSRect(x: 0, y: -Self.verticalMargin, width: size.width, height: size.height + Self.verticalMargin * 2)
    }

    override func draw(withFrame cellFrame: NSRect, in controlView: NSView?) {
        let rect = NSRect(x: cellFrame.minX, y: cellFrame.minY + Self.verticalMargin,
                          width: cellFrame.width, height: cellFrame.height - Self.verticalMargin * 2)
        let path = NSBezierPath(roundedRect: rect, xRadius: Self.cornerRadius, yRadius: Self.cornerRadius)
        let st = style
        if let image = loadedImage {
            NSGraphicsContext.saveGraphicsState()
            path.addClip()
            image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true,
                       hints: [NSImageRep.HintKey.interpolation: NSImageInterpolation.high.rawValue])
            NSGraphicsContext.restoreGraphicsState()
            st.text.withAlphaComponent(0.08).setStroke()
            path.lineWidth = 0.5
            path.stroke()
            return
        }
        st.text.withAlphaComponent(st.isDark ? 0.08 : 0.05).setFill()
        path.fill()
        let symbol = isMissing ? "photo.badge.exclamationmark" : "photo"
        let label = isMissing ? "Image not found" : name
        drawPlaceholder(in: rect, symbol: symbol, label: label, style: st)
    }

    private func drawPlaceholder(in rect: NSRect, symbol: String, label: String, style st: EditorStyle) {
        let cfg = NSImage.SymbolConfiguration(pointSize: 18, weight: .regular)
        if let img = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?.withSymbolConfiguration(cfg) {
            let tinted = img.tinted(st.secondary)
            let s = tinted.size
            tinted.draw(in: NSRect(x: rect.midX - s.width / 2, y: rect.midY - s.height / 2 - 8, width: s.width, height: s.height),
                        from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        }
        let para = NSMutableParagraphStyle()
        para.alignment = .center
        para.lineBreakMode = .byTruncatingMiddle
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 10.5), .foregroundColor: st.secondary, .paragraphStyle: para]
        (label as NSString).draw(with: NSRect(x: rect.minX + 8, y: rect.midY + 6, width: rect.width - 16, height: 14),
                                 options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], attributes: attrs)
    }
}

// MARK: - File shortcut

final class FileAttachmentCell: EmbedCell {
    let attachmentID: AttachmentID
    let name: String
    private var thumbnail: NSImage?
    private var icon: NSImage?
    private var requested = false
    private(set) var isMissing = false

    static let size = NSSize(width: 84, height: 96)
    static let iconSize: CGFloat = 46

    init(id: AttachmentID, name: String, context: EditorContext) {
        self.attachmentID = id
        self.name = name
        super.init(context: context)
    }

    required init(coder: NSCoder) { fatalError("not supported") }

    var url: URL? { MainActor.assumeIsolated { context?.url(for: attachmentID) } }

    private func ensureLoaded() {
        guard !requested else { return }
        requested = true
        MainActor.assumeIsolated {
            guard let url = context?.url(for: attachmentID), FileManager.default.fileExists(atPath: url.path) else {
                isMissing = true
                return
            }
            icon = AttachmentResources.shared.icon(for: url)
            if let t = AttachmentResources.shared.cachedThumbnail(url) { thumbnail = t; return }
            let px = Self.iconSize
            AttachmentResources.shared.loadThumbnail(url, size: NSSize(width: px, height: px)) { [weak self] img in
                guard let self, let img else { return }
                self.thumbnail = img
                self.context?.cellDidUpdate(self)
            }
        }
    }

    override func cellFrame(for textContainer: NSTextContainer, proposedLineFragment lineFrag: NSRect,
                            glyphPosition position: NSPoint, characterIndex charIndex: Int) -> NSRect {
        ensureLoaded()
        return NSRect(x: 0, y: -6, width: Self.size.width + 4, height: Self.size.height)
    }

    override func draw(withFrame cellFrame: NSRect, in controlView: NSView?) {
        ensureLoaded()
        let st = style
        let tile = NSRect(x: cellFrame.minX + 1, y: cellFrame.minY + 2, width: Self.size.width - 2, height: cellFrame.height - 4)
        let path = NSBezierPath(roundedRect: tile, xRadius: 10, yRadius: 10)
        st.text.withAlphaComponent(st.isDark ? 0.08 : 0.045).setFill()
        path.fill()
        st.text.withAlphaComponent(0.10).setStroke()
        path.lineWidth = 0.5
        path.stroke()

        let s = Self.iconSize
        let iconRect = NSRect(x: tile.midX - s / 2, y: tile.minY + 8, width: s, height: s)
        if isMissing {
            let cfg = NSImage.SymbolConfiguration(pointSize: 26, weight: .light)
            if let img = NSImage(systemSymbolName: "questionmark.folder", accessibilityDescription: nil)?.withSymbolConfiguration(cfg) {
                let t = img.tinted(st.secondary)
                let sz = t.size
                t.draw(in: NSRect(x: iconRect.midX - sz.width / 2, y: iconRect.midY - sz.height / 2, width: sz.width, height: sz.height),
                       from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            }
        } else if let img = thumbnail ?? icon {
            // Aspect-fit inside the icon square.
            let isz = img.size
            let scale = min(s / max(isz.width, 1), s / max(isz.height, 1))
            let w = isz.width * scale, h = isz.height * scale
            let r = NSRect(x: iconRect.midX - w / 2, y: iconRect.midY - h / 2, width: w, height: h)
            if thumbnail != nil {
                NSGraphicsContext.saveGraphicsState()
                NSBezierPath(roundedRect: r, xRadius: 3, yRadius: 3).addClip()
                img.draw(in: r, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
                NSGraphicsContext.restoreGraphicsState()
            } else {
                img.draw(in: r, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            }
        }

        let para = NSMutableParagraphStyle()
        para.alignment = .center
        para.lineBreakMode = .byWordWrapping
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10, weight: .medium),
            .foregroundColor: isMissing ? st.secondary : st.text,
            .paragraphStyle: para,
        ]
        let textRect = NSRect(x: tile.minX + 5, y: iconRect.maxY + 5, width: tile.width - 10, height: tile.maxY - iconRect.maxY - 8)
        (name as NSString).draw(with: textRect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], attributes: attrs)
    }
}

extension NSImage {
    /// Template-style tint for SF Symbols.
    func tinted(_ color: NSColor) -> NSImage {
        let img = NSImage(size: size, flipped: false) { rect in
            self.draw(in: rect)
            color.set()
            rect.fill(using: .sourceAtop)
            return true
        }
        return img
    }
}
