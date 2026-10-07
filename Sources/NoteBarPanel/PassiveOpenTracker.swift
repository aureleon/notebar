import AppKit

/// Watches a panel that was opened passively (Hot Side dwell, file drag over the Open Bar). Such an open
/// does not take keyboard focus, so the user can keep typing in the frontmost app. If the user never
/// interacts and the cursor stays outside the panel area for `leaveDelay`, the panel hides again, so an
/// accidental open does not stick.
///
/// Interaction ends passive mode: the panel gaining focus (a click makes the non-activating panel key),
/// or a drag that ends with the cursor over the panel (a drop). The panel area is the panel, the Open
/// Bar and the strip between them and the screen edge (where the Hot Side cursor rests).
@MainActor
final class PassiveOpenTracker {
    static let leaveDelay: TimeInterval = 0.5
    private static let pollInterval: TimeInterval = 0.1

    /// Rects (global coordinates) that count as "near the panel".
    var zone: () -> [CGRect] = { [] }
    /// The panel frame itself (a drop target).
    var panelFrame: () -> CGRect? = { nil }
    /// True when the user has engaged the panel (focus flag).
    var isEngaged: () -> Bool = { false }
    /// False while auto-hide is off, the panel is pinned or a suspension is active: then passive opens
    /// still do not take focus, but they do not hide on leave either.
    var mayHide: () -> Bool = { true }
    var onLeave: () -> Void = {}

    private(set) var isActive = false
    private var timer: Timer?
    private var outsideSince: Date?
    private var buttonsWereDown = false

    func start() {
        guard !isActive else { return }
        isActive = true
        outsideSince = nil
        buttonsWereDown = NSEvent.pressedMouseButtons != 0
        let t = Timer(timeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        t.tolerance = 0.03
        RunLoop.main.add(t, forMode: .common)   // keep polling during drag sessions / menu tracking
        timer = t
    }

    func stop() {
        guard isActive else { return }
        isActive = false
        timer?.invalidate()
        timer = nil
        outsideSince = nil
        buttonsWereDown = false
    }

    private func tick() {
        guard isActive else { return }
        if isEngaged() { stop(); return }

        let mouse = NSEvent.mouseLocation
        // A button is down: a drag toward the panel, or a click elsewhere (auto-hide handles that).
        // Never hide in the middle of a drag.
        if NSEvent.pressedMouseButtons != 0 {
            buttonsWereDown = true
            outsideSince = nil
            return
        }
        if buttonsWereDown {
            buttonsWereDown = false
            if let frame = panelFrame(), frame.insetBy(dx: -2, dy: -2).contains(mouse) {
                // Dropped onto the panel: the user used it. Keep it like a normal open (without focus).
                stop()
                return
            }
        }

        let near = zone().contains { $0.insetBy(dx: -2, dy: -2).contains(mouse) }
        if near || !mayHide() {
            outsideSince = nil
            return
        }
        let now = Date()
        guard let since = outsideSince else { outsideSince = now; return }
        if now.timeIntervalSince(since) >= Self.leaveDelay {
            stop()
            onLeave()
        }
    }
}
