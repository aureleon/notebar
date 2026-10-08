import AppKit
import NoteBarCore

/// The strip at the bottom of a card: Aa · share · gear | calendar date | export · trash.
@MainActor
final class CardFooterView: NSView {
    let formatButton = IconButton(symbol: "textformat", size: 11, toolTip: "Format")
    let shareButton = IconButton(symbol: "square.and.arrow.up", size: 11, toolTip: "Share")
    let gearButton = IconButton(symbol: "gearshape", size: 11, toolTip: "Color & Mode")
    let exportButton = IconButton(symbol: "square.and.arrow.down", size: 11, toolTip: "Export as Image")
    let trashButton = IconButton(symbol: "trash", size: 11, toolTip: "Delete Note")
    private let leftPill = PillView()
    private let rightPill = PillView()
    private let dateView = FooterDateView()

    var date: Date = Date() { didSet { dateView.text = UIFormat.footerDate.string(from: date) } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        formatButton.text = "Aa"
        formatButton.textFont = UIFonts.footerButton(14)  // set from the theme by setFontSize
        addSubview(leftPill)
        addSubview(rightPill)
        addSubview(dateView)
        for b in [formatButton, shareButton, gearButton] { leftPill.addSubview(b) }
        for b in [exportButton, trashButton] { rightPill.addSubview(b) }
        for b in [formatButton, shareButton, gearButton, exportButton, trashButton] {
            b.symbolWeight = .medium
            b.shape = .circle
        }
        dateView.text = UIFormat.footerDate.string(from: date)
    }

    /// Footer and date text follow the theme font size.
    func setFontSize(_ fs: CGFloat) {
        for b in [formatButton] { b.textFont = UIFonts.footerButton(fs) }
        dateView.font = UIFonts.footer(fs)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    func style(tint: NSColor, pillFill: NSColor, pillStroke: NSColor, hoverFill: NSColor, pressedFill: NSColor, dateColor: NSColor) {
        for b in [formatButton, shareButton, gearButton, exportButton, trashButton] {
            b.tint = tint
            b.hoverFill = hoverFill
            b.pressedFill = pressedFill
        }
        leftPill.fill = pillFill
        leftPill.stroke = pillStroke
        rightPill.fill = pillFill
        rightPill.stroke = pillStroke
        dateView.color = dateColor
    }

    override func layout() {
        super.layout()
        let h = bounds.height
        let b: CGFloat = 22
        let inset: CGFloat = 1
        leftPill.frame = NSRect(x: 0, y: (h - (b + 2 * inset)) / 2, width: 3 * b + 2 * inset, height: b + 2 * inset)
        for (i, v) in [formatButton, shareButton, gearButton].enumerated() {
            v.frame = NSRect(x: inset + CGFloat(i) * b, y: inset, width: b, height: b)
        }
        rightPill.frame = NSRect(x: bounds.width - (2 * b + 2 * inset), y: leftPill.frame.minY, width: 2 * b + 2 * inset, height: b + 2 * inset)
        for (i, v) in [exportButton, trashButton].enumerated() {
            v.frame = NSRect(x: inset + CGFloat(i) * b, y: inset, width: b, height: b)
        }
        dateView.frame = NSRect(x: leftPill.frame.maxX + 4, y: 0, width: max(0, rightPill.frame.minX - leftPill.frame.maxX - 8), height: h)
    }

    /// Clicks on the empty parts fall through to the card (so the footer can start a card drag).
    override func hitTest(_ point: NSPoint) -> NSView? {
        let v = super.hitTest(point)
        return v === self ? nil : v
    }
}

/// Calendar icon + date, centered. Draws itself so it never swallows clicks.
final class FooterDateView: NSView {
    var text = "" { didSet { needsDisplay = true } }
    var color: NSColor = .secondaryLabelColor { didSet { needsDisplay = true } }
    var font: NSFont = UIFonts.footer(14) { didSet { invalidateIntrinsicContentSize(); needsDisplay = true } }
    private let icon = Symbols.image("calendar", size: 9.5, weight: .medium)

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        let s = (text as NSString).size(withAttributes: attrs)
        let iconW: CGFloat = icon == nil ? 0 : 13
        var total = s.width + iconW
        var drawText = text
        if total > bounds.width, bounds.width > 40 {
            // Narrow card: drop the time.
            drawText = String(text.prefix(10))
            total = (drawText as NSString).size(withAttributes: attrs).width + iconW
        }
        let x = max(0, (bounds.width - total) / 2)
        if let icon {
            Symbols.draw(icon, in: NSRect(x: x, y: (bounds.height - 12) / 2, width: 11, height: 12), color: color)
        }
        (drawText as NSString).draw(at: NSPoint(x: x + iconW, y: (bounds.height - s.height) / 2), withAttributes: attrs)
    }
}

/// "+ N lines" pill on folded cards. Click to unfold.
@MainActor
final class BadgeButton: NSView {
    var text = "" { didSet { invalidateIntrinsicContentSize(); needsDisplay = true; setAccessibilityLabel(text) } }
    var textColor: NSColor = .secondaryLabelColor { didSet { needsDisplay = true } }
    var font: NSFont = UIFonts.badge(14) { didSet { invalidateIntrinsicContentSize(); needsDisplay = true } }
    var fill: NSColor = .clear { didSet { needsDisplay = true } }
    var hoverFill: NSColor = .clear
    var onClick: (() -> Void)?
    private var hovering = false { didSet { needsDisplay = true } }
    private var tracking: NSTrackingArea?

    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityRole(.button)
        toolTip = "Unfold"
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override var intrinsicContentSize: NSSize {
        let s = (text as NSString).size(withAttributes: [.font: font])
        return NSSize(width: ceil(s.width) + 18, height: 20)
    }

    override func draw(_ dirtyRect: NSRect) {
        let p = NSBezierPath(roundedRect: bounds, xRadius: bounds.height / 2, yRadius: bounds.height / 2)
        fill.setFill(); p.fill()
        if hovering { hoverFill.setFill(); p.fill() }
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: textColor]
        let s = (text as NSString).size(withAttributes: attrs)
        (text as NSString).draw(at: NSPoint(x: (bounds.width - s.width) / 2, y: (bounds.height - s.height) / 2), withAttributes: attrs)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let t = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(t)
        tracking = t
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onClick?() }
    }
    override func accessibilityPerformPress() -> Bool { onClick?(); return true }
}
