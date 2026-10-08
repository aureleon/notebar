import AppKit
import NoteBarCore

/// A small transient pill at the bottom of the panel ("Note deleted — Undo").
@MainActor
final class ToastView: NSView {
    private let label = makeLabel(font: UIFonts.caption(14, weight: .medium))
    private let actionButton = TextButton()
    /// Theme font size (set by the owner).
    var fontSize: CGFloat = 14 {
        didSet {
            label.font = UIFonts.caption(fontSize, weight: .medium)
            actionButton.font = UIFonts.caption(fontSize, weight: .semibold)
            invalidateIntrinsicContentSize()
        }
    }
    private var timer: Timer?
    private var onAction: (() -> Void)?
    private var onExpire: (() -> Void)?
    private var tracking: NSTrackingArea?
    private var hovering = false
    private var generation = 0

    override init(frame: NSRect) {
        super.init(frame: frame)
        addSubview(label)
        addSubview(actionButton)
        actionButton.onClick = { [weak self] in self?.fireAction() }
        isHidden = true
        setAccessibilityRole(.group)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    /// Shows the toast. `onExpire` runs when it disappears without the action being used.
    func show(_ message: String, actionTitle: String?, duration: TimeInterval = 5,
              onAction: (() -> Void)?, onExpire: (() -> Void)?) {
        // A toast that is replaced counts as expired.
        let previous = self.onExpire
        self.onExpire = nil
        previous?()
        label.stringValue = message
        actionButton.title = actionTitle ?? ""
        actionButton.isHidden = actionTitle == nil
        self.onAction = onAction
        self.onExpire = onExpire
        restyle()
        generation += 1
        isHidden = false
        alphaValue = 1
        setAccessibilityLabel(message)
        NSAccessibility.post(element: self, notification: .announcementRequested,
                             userInfo: [.announcement: message, .priority: NSAccessibilityPriorityLevel.medium.rawValue])
        superview?.needsLayout = true
        schedule(duration)
    }

    private func schedule(_ duration: TimeInterval) {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: duration, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if self.hovering { self.schedule(1.5) } else { self.dismiss(expired: true) }
            }
        }
    }

    /// Hides the toast. `expired == true` runs the expire handler (e.g. commits a pending delete).
    func dismiss(expired: Bool) {
        timer?.invalidate(); timer = nil
        let expire = onExpire
        onExpire = nil
        onAction = nil
        if !isHidden {
            let gen = generation
            if NoteBarUIOptions.animations {
                NSAnimationContext.runAnimationGroup({ ctx in
                    ctx.duration = 0.18
                    self.animator().alphaValue = 0
                }, completionHandler: {
                    MainActor.assumeIsolated { if self.generation == gen { self.isHidden = true } }
                })
            } else {
                isHidden = true
            }
        }
        if expired { expire?() }
    }

    var messageForChecks: String { label.stringValue }
    func fireActionForChecks() { fireAction() }

    private func fireAction() {
        let action = onAction
        onExpire = nil
        dismiss(expired: false)
        action?()
    }

    var isShowing: Bool { !isHidden && timer != nil }

    func preferredSize(maxWidth: CGFloat) -> NSSize {
        let lw = ceil(label.intrinsicContentSize.width) + 6
        let bw = actionButton.isHidden ? 0 : ceil(actionButton.intrinsicContentSize.width) + 12
        return NSSize(width: min(maxWidth, lw + bw + 28), height: 32)
    }

    override func layout() {
        super.layout()
        let bw = actionButton.isHidden ? 0 : ceil(actionButton.intrinsicContentSize.width)
        let lh = ceil(label.intrinsicContentSize.height)
        label.frame = NSRect(x: 14, y: (bounds.height - lh) / 2, width: max(0, bounds.width - 28 - (bw > 0 ? bw + 12 : 0) + 4), height: lh)
        actionButton.frame = NSRect(x: bounds.width - 14 - bw, y: (bounds.height - 22) / 2, width: bw, height: 22)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        restyle()
    }

    private func restyle() {
        let dark = effectiveAppearance.isDark
        label.textColor = dark ? NSColor(white: 0.1, alpha: 1) : .white
        actionButton.color = dark ? NSColor(srgbRed: 0.05, green: 0.38, blue: 0.85, alpha: 1)
                                  : NSColor(srgbRed: 0.55, green: 0.78, blue: 1, alpha: 1)
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let dark = effectiveAppearance.isDark
        let r = bounds.insetBy(dx: 0.5, dy: 0.5)
        let p = NSBezierPath(roundedRect: r, xRadius: r.height / 2, yRadius: r.height / 2)
        (dark ? NSColor(white: 0.93, alpha: 0.97) : NSColor(white: 0.12, alpha: 0.92)).setFill()
        p.fill()
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
}

/// A borderless text button drawn by hand.
@MainActor
final class TextButton: NSView {
    var title = "" { didSet { invalidateIntrinsicContentSize(); needsDisplay = true; setAccessibilityLabel(title) } }
    var color: NSColor = .linkColor { didSet { needsDisplay = true } }
    var font: NSFont = UIFonts.caption(14, weight: .semibold) { didSet { invalidateIntrinsicContentSize(); needsDisplay = true } }
    var onClick: (() -> Void)?
    private var pressed = false { didSet { needsDisplay = true } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityRole(.button)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var intrinsicContentSize: NSSize {
        let s = (title as NSString).size(withAttributes: [.font: font])
        return NSSize(width: ceil(s.width), height: ceil(s.height))
    }

    override func draw(_ dirtyRect: NSRect) {
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color.withAlphaComponent(pressed ? 0.6 : 1)]
        let s = (title as NSString).size(withAttributes: attrs)
        (title as NSString).draw(at: NSPoint(x: (bounds.width - s.width) / 2, y: (bounds.height - s.height) / 2), withAttributes: attrs)
    }

    override func mouseDown(with event: NSEvent) { pressed = true }
    override func mouseUp(with event: NSEvent) {
        pressed = false
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onClick?() }
    }
    override func accessibilityPerformPress() -> Bool { onClick?(); return true }
}
