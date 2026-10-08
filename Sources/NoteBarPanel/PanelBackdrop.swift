import AppKit
import NoteBarCore

/// The blurred area behind the panel, like the Notification Center widget panel: a soft blur that fills
/// the screen edge on the panel side and fades out toward the middle of the screen.
///
/// It is a separate borderless window one level below the panel. It never takes clicks
/// (`ignoresMouseEvents`), so clicks outside the panel reach the apps below and auto-hide still works.
/// It does not slide: the panel slides, and this window only fades (the caller passes the same duration).
///
/// Layers, bottom to top, inside the window:
/// 1. `NSVisualEffectView` (behind-window blur) with a horizontal alpha `maskImage`.
/// 2. A tint view with the same alpha ramp as a `CAGradientLayer` mask. Black at 20 % in dark mode,
///    white at 8 % in light mode. The tint view is a sibling, not a subview, so the blur mask does not
///    have to mask it.
///
/// Reduce Transparency: the blur view is hidden and a solid tinted fill (same mask) is used instead.
@MainActor
final class PanelBackdrop {
    /// Blur material. Picked by eye from the options in the spec (see the report); the material adapts
    /// to light and dark mode.
    static let material: NSVisualEffectView.Material = .underWindowBackground

    private let window: NSWindow
    private let content: BackdropContentView
    private let effect: NSVisualEffectView
    private let tint: TintView
    /// Incremented by every alpha animation; stale completion handlers do nothing.
    private var generation = 0
    private var observer: NSObjectProtocol?
    /// Last placed state, reapplied when the accessibility options change.
    private var lastGeometry: PanelGeometry?

    /// `panelLevel`: the panel's window level. The backdrop goes one level below.
    init(panelLevel: NSWindow.Level) {
        window = NSWindow(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.level = NSWindow.Level(rawValue: panelLevel.rawValue - 1)
        window.collectionBehavior = edgeWindowCollectionBehavior
        window.hidesOnDeactivate = false
        window.canHide = false
        window.isExcludedFromWindowsMenu = true
        window.tabbingMode = .disallowed
        window.animationBehavior = .none
        window.title = "NoteBar backdrop"

        content = BackdropContentView(frame: .zero)
        effect = NSVisualEffectView(frame: .zero)
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.material = Self.material
        effect.autoresizingMask = [.width, .height]
        tint = TintView(frame: .zero)
        tint.autoresizingMask = [.width, .height]
        content.addSubview(effect)
        content.addSubview(tint)
        content.onAppearanceChange = { [weak self] in self?.refreshTint() }
        window.contentView = content

        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let g = self.lastGeometry, self.window.isVisible else { return }
                self.place(g)
            }
        }
    }

    /// Shows the backdrop for `geometry` (the panel's screen, side and width) and fades it in. With
    /// `duration` 0 it is set at once, which is also how it follows screen, side and width changes.
    /// `enabled` = `settings.blurBackdrop`; when false, the backdrop is hidden.
    func show(_ geometry: PanelGeometry, enabled: Bool, duration: TimeInterval, timing: CAMediaTimingFunctionName = .easeOut) {
        guard enabled else {
            hide(duration: 0)
            return
        }
        lastGeometry = geometry
        place(geometry)
        if !window.isVisible {
            window.alphaValue = 0
            window.orderFrontRegardless()
        }
        animateAlpha(1, duration: duration, timing: timing)
    }

    /// Fades the backdrop out and orders it out at the end.
    func hide(duration: TimeInterval, timing: CAMediaTimingFunctionName = .easeIn) {
        guard window.isVisible else {
            lastGeometry = nil
            return
        }
        lastGeometry = nil
        animateAlpha(0, duration: duration, timing: timing) { [weak self] in self?.window.orderOut(nil) }
    }

    /// The frame of the backdrop: the full screen height, from the screen edge on the panel side to
    /// `PanelMetrics.backdropFadeWidth` beyond the panel's inner edge (never past the screen).
    static func frame(for g: PanelGeometry) -> CGRect {
        let s = g.screenFrame
        let p = g.shownFrame
        let fade = PanelMetrics.backdropFadeWidth
        if g.side == .right {
            let x0 = max(p.minX - fade, s.minX)
            return CGRect(x: x0, y: s.minY, width: s.maxX - x0, height: s.height)
        } else {
            let x1 = min(p.maxX + fade, s.maxX)
            return CGRect(x: s.minX, y: s.minY, width: x1 - s.minX, height: s.height)
        }
    }

    /// Alpha ramp from the left edge (location 0) to the right edge (location 1) of the backdrop frame.
    /// Opaque from the screen edge to the panel's inner edge, then a fade to transparent.
    static func alphaStops(for g: PanelGeometry) -> [(location: CGFloat, alpha: CGFloat)] {
        let f = frame(for: g)
        guard f.width > 0 else { return [(0, 1), (1, 1)] }
        let p = g.shownFrame
        if g.side == .right {
            // Opaque on the right (screen edge), fade on the left.
            let inner = min(max((p.minX - f.minX) / f.width, 0), 1)
            return [(0, 0), (inner, 1), (1, 1)]
        } else {
            let inner = min(max((p.maxX - f.minX) / f.width, 0), 1)
            return [(0, 1), (inner, 1), (1, 0)]
        }
    }

    // MARK: Placement

    private func place(_ g: PanelGeometry) {
        let frame = Self.frame(for: g)
        if window.frame != frame { window.setFrame(frame, display: true) }
        let stops = Self.alphaStops(for: g)
        let size = frame.size
        effect.maskImage = Self.maskImage(stops: stops, size: size)
        effect.isHidden = Self.reduceTransparency
        tint.frame = content.bounds
        let mask = CAGradientLayer()
        mask.frame = CGRect(origin: .zero, size: size)
        mask.colors = stops.map { NSColor.black.withAlphaComponent($0.alpha).cgColor }
        mask.locations = stops.map { NSNumber(value: Double($0.location)) }
        mask.startPoint = CGPoint(x: 0, y: 0.5)
        mask.endPoint = CGPoint(x: 1, y: 0.5)
        tint.layer?.mask = mask
        refreshTint()
    }

    private func refreshTint() {
        let dark = content.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let color: NSColor
        if Self.reduceTransparency {
            // Solid fill: no blur to show through.
            color = dark ? NSColor(white: 0.12, alpha: 0.92) : NSColor(white: 0.92, alpha: 0.92)
        } else {
            color = dark ? NSColor.black.withAlphaComponent(0.20) : NSColor.white.withAlphaComponent(0.08)
        }
        tint.layer?.backgroundColor = color.cgColor
    }

    private static var reduceTransparency: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
    }

    /// Alpha-only image (black with the ramp's alpha), stretched to `size`.
    private static func maskImage(stops: [(location: CGFloat, alpha: CGFloat)], size: NSSize) -> NSImage {
        let image = NSImage(size: size, flipped: false) { rect in
            let colors = stops.map { NSColor.black.withAlphaComponent($0.alpha) }
            let locations = stops.map { CGFloat($0.location) }
            NSGradient(colors: colors, atLocations: locations, colorSpace: .sRGB)?
                .draw(in: rect, angle: 0)
            return true
        }
        image.resizingMode = .stretch
        return image
    }

    // MARK: Animation

    private func animateAlpha(_ alpha: CGFloat, duration: TimeInterval, timing: CAMediaTimingFunctionName,
                              completion: (() -> Void)? = nil) {
        generation += 1
        let gen = generation
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = duration
            ctx.timingFunction = CAMediaTimingFunction(name: timing)
            ctx.allowsImplicitAnimation = false
            window.animator().alphaValue = alpha
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, gen == self.generation else { return }
                completion?()
            }
        })
        if duration <= 0 { window.alphaValue = alpha }
    }
}

/// Root view of the backdrop window. Reports appearance changes (light / dark) so the tint follows.
private final class BackdropContentView: NSView {
    var onAppearanceChange: (() -> Void)?
    override var isOpaque: Bool { false }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        onAppearanceChange?()
    }
}

/// The tint layer. Its color and mask are set by `PanelBackdrop`.
private final class TintView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }
    required init?(coder: NSCoder) { fatalError("not supported") }
    override var isOpaque: Bool { false }
}
