import AppKit

/// A small symbol button drawn by hand (renders in offscreen snapshots, works in non-activating panels).
/// Shows a hover/pressed fill. Optional permanent circular background (header buttons).
final class IconButton: NSView {
    enum Shape { case circle, roundedRect(CGFloat) }

    var symbolName: String { didSet { if oldValue != symbolName { reloadImage() } } }
    var symbolSize: CGFloat { didSet { reloadImage() } }
    var symbolWeight: NSFont.Weight = .medium { didSet { reloadImage() } }
    var tint: NSColor = .secondaryLabelColor { didSet { needsDisplay = true } }
    /// Fill drawn always (nil = only on hover).
    var restingFill: NSColor? { didSet { needsDisplay = true } }
    var hoverFill: NSColor = NSColor.black.withAlphaComponent(0.06) { didSet { needsDisplay = true } }
    var pressedFill: NSColor = NSColor.black.withAlphaComponent(0.12)
    var shape: Shape = .circle { didSet { needsDisplay = true } }
    /// Optional text drawn instead of the symbol (e.g. "Aa").
    var text: String? { didSet { needsDisplay = true } }
    var textFont: NSFont = UIFonts.footerButton(14)
    var isOn = false { didSet { needsDisplay = true } }
    var onTint: NSColor?
    var isEnabled = true { didSet { needsDisplay = true } }
    var onClick: ((IconButton) -> Void)?

    private var image: NSImage?
    private var hovering = false { didSet { if oldValue != hovering { needsDisplay = true } } }
    private var pressed = false { didSet { if oldValue != pressed { needsDisplay = true } } }
    private var tracking: NSTrackingArea?

    init(symbol: String, size: CGFloat = 12, toolTip: String? = nil, onClick: ((IconButton) -> Void)? = nil) {
        self.symbolName = symbol
        self.symbolSize = size
        self.onClick = onClick
        super.init(frame: NSRect(x: 0, y: 0, width: 22, height: 22))
        self.toolTip = toolTip
        reloadImage()
        setAccessibilityRole(.button)
        setAccessibilityLabel(toolTip ?? symbol)
    }

    required init?(coder: NSCoder) { fatalError() }

    private func reloadImage() {
        image = Symbols.image(symbolName, size: symbolSize, weight: symbolWeight)
        needsDisplay = true
    }

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let t = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(t)
        tracking = t
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        pressed = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard isEnabled else { return }
        pressed = bounds.contains(convert(event.locationInWindow, from: nil))
    }

    override func mouseUp(with event: NSEvent) {
        guard isEnabled else { return }
        let inside = bounds.contains(convert(event.locationInWindow, from: nil))
        pressed = false
        if inside { onClick?(self) }
    }

    override func accessibilityPerformPress() -> Bool { onClick?(self); return true }

    override func draw(_ dirtyRect: NSRect) {
        let path: NSBezierPath
        switch shape {
        case .circle: path = NSBezierPath(ovalIn: bounds)
        case .roundedRect(let r): path = NSBezierPath(roundedRect: bounds, xRadius: r, yRadius: r)
        }
        if let restingFill { restingFill.setFill(); path.fill() }
        if isEnabled && (pressed || hovering) { (pressed ? pressedFill : hoverFill).setFill(); path.fill() }
        let color = (isOn ? (onTint ?? tint) : tint).withAlphaComponent(isEnabled ? 1 : 0.35)
        if let text {
            let attrs: [NSAttributedString.Key: Any] = [.font: textFont, .foregroundColor: color]
            let s = (text as NSString).size(withAttributes: attrs)
            (text as NSString).draw(at: NSPoint(x: bounds.midX - s.width / 2, y: bounds.midY - s.height / 2), withAttributes: attrs)
        } else if let image {
            Symbols.draw(image, in: bounds, color: color)
        }
    }

    /// Shows `menu` below the button.
    func popUp(_ menu: NSMenu) {
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: bounds.maxY + 4), in: self)
        hovering = false
        pressed = false
    }
}

/// Rounded "pill" background used to group footer buttons.
final class PillView: NSView {
    var fill: NSColor = .clear { didSet { needsDisplay = true } }
    var stroke: NSColor = .clear { didSet { needsDisplay = true } }
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        let r = bounds.height / 2
        let p = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: r, yRadius: r)
        fill.setFill(); p.fill()
        stroke.setStroke(); p.lineWidth = 1; p.stroke()
    }
    override func hitTest(_ point: NSPoint) -> NSView? {
        let v = super.hitTest(point)
        return v === self ? nil : v
    }
}
