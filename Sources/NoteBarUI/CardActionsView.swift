import AppKit
import NoteBarCore

/// The card's action drawer in the bottom-right corner, under the pin column: Aa · copy · gear · trash,
/// top to bottom, in a rounded tray that hugs the bottom of the view. When the card is too short for
/// all four, the last slot that fits becomes a "…" button with the rest in a menu (`hiddenActions`).
/// Shown on hover / focus, like the date.
@MainActor
final class CardActionsView: NSView {
    enum Action: CaseIterable { case format, copy, colorAndMode, delete }

    let formatButton = IconButton(symbol: "textformat", size: 11, toolTip: "Format")
    let copyButton = IconButton(symbol: "doc.on.doc", size: 11, toolTip: "Copy Note Text")
    let gearButton = IconButton(symbol: "gearshape", size: 11, toolTip: "Color & Mode")
    let trashButton = IconButton(symbol: "trash", size: 11, toolTip: "Delete Note")
    let moreButton = IconButton(symbol: "ellipsis", size: 11, toolTip: "More")
    private let pill = PillView()
    private var actionButtons: [IconButton] { [formatButton, copyButton, gearButton, trashButton] }
    /// Actions that do not fit and are in the "…" menu. Set by `layout`.
    private(set) var hiddenActions: [Action] = []

    static let buttonSize: CGFloat = 20
    /// Padding inside the drawer around the buttons.
    static let padding: CGFloat = 2
    static let cornerRadius: CGFloat = 7
    static let width: CGFloat = buttonSize + 2 * padding
    /// Smallest view height that holds one button.
    static let minHeight: CGFloat = buttonSize + 2 * padding

    override init(frame: NSRect) {
        super.init(frame: frame)
        formatButton.text = "Aa"
        formatButton.textFont = UIFonts.footerButton(14)  // set from the theme by setFontSize
        pill.cornerRadius = Self.cornerRadius
        addSubview(pill)
        for b in actionButtons + [moreButton] {
            pill.addSubview(b)
            b.symbolWeight = .medium
            b.shape = .circle
        }
        moreButton.isHidden = true
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    func setFontSize(_ fs: CGFloat) {
        formatButton.textFont = UIFonts.footerButton(fs)
    }

    func style(tint: NSColor, pillFill: NSColor, pillStroke: NSColor, hoverFill: NSColor, pressedFill: NSColor) {
        for b in actionButtons + [moreButton] {
            b.tint = tint
            b.hoverFill = hoverFill
            b.pressedFill = pressedFill
        }
        pill.fill = pillFill
        pill.stroke = pillStroke
    }

    /// Number of button slots that fit in `height`.
    static func slots(forHeight height: CGFloat) -> Int { max(0, Int((height - 2 * padding + 0.5) / buttonSize)) }

    /// Bottom-aligned: the drawer ends at the bottom of the view and grows up as far as the buttons need.
    override func layout() {
        super.layout()
        let b = Self.buttonSize
        let slots = Self.slots(forHeight: bounds.height)
        let all = actionButtons
        let visible: [IconButton]
        if slots >= all.count {
            visible = all
            hiddenActions = []
        } else if slots == 0 {
            visible = []
            hiddenActions = Action.allCases
        } else {
            visible = Array(all.prefix(slots - 1)) + [moreButton]
            hiddenActions = Array(Action.allCases.dropFirst(slots - 1))
        }
        for v in all + [moreButton] { v.isHidden = !visible.contains { $0 === v } }
        pill.isHidden = visible.isEmpty
        let p = Self.padding
        let ph = CGFloat(visible.count) * b + 2 * p
        pill.frame = NSRect(x: (bounds.width - Self.width) / 2, y: bounds.height - ph, width: Self.width, height: ph)
        for (i, v) in visible.enumerated() {
            v.frame = NSRect(x: p, y: p + CGFloat(i) * b, width: b, height: b)
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for t in trackingAreas where t.owner === self { removeTrackingArea(t) }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.cursorUpdate, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    /// Arrow over the column, never the editor's I-beam.
    override func cursorUpdate(with event: NSEvent) { NSCursor.arrow.set() }

    /// Clicks on the empty parts fall through to the card (so they can start a card drag).
    override func hitTest(_ point: NSPoint) -> NSView? {
        let v = super.hitTest(point)
        return v === self ? nil : v
    }
}

/// Calendar icon + date, right-aligned. Sits on the title line, left of the pin. Takes the hit (so the
/// editor below does not show its I-beam) and passes clicks on to the card.
final class CardDateView: NSView {
    var text = "" { didSet { needsDisplay = true } }
    var color: NSColor = .secondaryLabelColor { didSet { needsDisplay = true } }
    var font: NSFont = UIFonts.footer(14) { didSet { needsDisplay = true } }
    private let icon = Symbols.image("calendar", size: 9.5, weight: .medium)
    private static let iconWidth: CGFloat = 13

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// Width of the widest date in `font` (constant, so the space kept free for it never changes).
    static func reservedWidth(font: NSFont) -> CGFloat {
        let s = ("00/00/0000, 00:00" as NSString).size(withAttributes: [.font: font])
        return ceil(s.width + iconWidth)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for t in trackingAreas where t.owner === self { removeTrackingArea(t) }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.cursorUpdate, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    override func cursorUpdate(with event: NSEvent) { NSCursor.arrow.set() }

    override func draw(_ dirtyRect: NSRect) {
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        var drawText = text
        var s = (drawText as NSString).size(withAttributes: attrs)
        if s.width + Self.iconWidth > bounds.width {
            // Narrow card: drop the time.
            drawText = String(text.prefix(10))
            s = (drawText as NSString).size(withAttributes: attrs)
        }
        let x = max(0, bounds.width - s.width - Self.iconWidth)
        if let icon {
            Symbols.draw(icon, in: NSRect(x: x, y: (bounds.height - 12) / 2, width: 11, height: 12), color: color)
        }
        (drawText as NSString).draw(at: NSPoint(x: x + Self.iconWidth, y: (bounds.height - s.height) / 2), withAttributes: attrs)
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
