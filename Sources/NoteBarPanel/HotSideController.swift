import AppKit
import NoteBarCore

/// "Hot Side": a 1 pt transparent strip on the panel-side edge of every screen. Resting the cursor on
/// it for `settings.hotSideDelay` seconds (no mouse button down) opens the panel on that screen. The
/// open is passive: it does not take keyboard focus (see `PassiveOpenTracker`).
/// Dragging a file / text onto the edge also opens it, so the user can drop onto the panel.
///
/// The strip skips the menu bar area, the bottom corner (hot corners) and edge parts that touch another
/// display (the cursor does not stop there). A click on the strip is not swallowed twice: after a click
/// the strip lets mouse events through until the cursor leaves the edge.
@MainActor
final class HotSideController {
    private let settings: AppSettings
    private var windows: [HotSideWindow] = []
    private var settingsObserver: NSObjectProtocol?

    /// Asked to open the panel on a screen.
    var onTrigger: ((NSScreen) -> Void)?
    /// True while the panel is visible on the given screen (then the edge is ignored there).
    var isPanelShown: (NSScreen) -> Bool = { _ in false }

    init(settings: AppSettings) {
        self.settings = settings
        settingsObserver = NotificationCenter.default.addObserver(forName: .appSettingsDidChange, object: nil, queue: .main) { [weak self] n in
            let key = n.userInfo?["key"] as? String
            guard key == nil || key == "hotSideEnabled" || key == "panelSide" else { return }
            MainActor.assumeIsolated { self?.rebuild() }
        }
    }

    /// Re-creates the strips for the current screens and settings.
    func rebuild() {
        for w in windows { w.dwell.cancel(); w.orderOut(nil) }
        windows.removeAll()
        guard settings.hotSideEnabled else { return }
        let side = settings.panelSide
        let screens = NSScreen.screens
        for screen in screens {
            let others = screens.filter { $0 != screen }.map(\.frame)
            let segments = PanelGeometry.hotSideSegments(screenFrame: screen.frame, visibleFrame: screen.visibleFrame,
                                                         side: side, otherScreenFrames: others)
            for rect in segments {
                let w = HotSideWindow(frame: rect, side: side, displayID: screen.nbDisplayID)
                w.dwell.delay = { [weak self] in max(0, self?.settings.hotSideDelay ?? 0.3) }
                w.dwell.isSuppressed = { [weak self, weak w] in
                    guard let self, let screen = NSScreen.nbScreen(withID: w?.displayID) else { return true }
                    return self.isPanelShown(screen)
                }
                w.dwell.onFire = { [weak self, weak w] in
                    guard let self, let screen = NSScreen.nbScreen(withID: w?.displayID) else { return }
                    self.onTrigger?(screen)
                }
                w.orderFrontRegardless()
                windows.append(w)
            }
        }
    }

    var windowCount: Int { windows.count }
}

// MARK: - Window

final class HotSideWindow: NSPanel {
    let displayID: CGDirectDisplayID?
    let dwell: EdgeDwellTracker
    private let edgeView: HotSideView

    init(frame: NSRect, side: PanelSide, displayID: CGDirectDisplayID?) {
        self.displayID = displayID
        dwell = EdgeDwellTracker(edgeRect: frame, side: side)
        edgeView = HotSideView(frame: NSRect(origin: .zero, size: frame.size))
        super.init(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .statusBar
        collectionBehavior = edgeWindowCollectionBehavior
        isOpaque = false
        hasShadow = false
        // Fully transparent pixels are click-through for the window server, and then no tracking events
        // arrive either. A ~1% alpha keeps the strip "solid" while staying invisible.
        backgroundColor = NSColor(white: 0, alpha: 0.012)
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        isExcludedFromWindowsMenu = true
        animationBehavior = .none
        ignoresMouseEvents = false
        becomesKeyOnlyIfNeeded = true
        setAccessibilityElement(false)
        contentView = edgeView
        edgeView.dwell = dwell
        dwell.window = self
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

final class HotSideView: NSView {
    weak var dwell: EdgeDwellTracker?
    private var tracking: NSTrackingArea?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        autoresizingMask = [.width, .height]
        registerForDraggedTypes([.fileURL, .URL, .string, .tiff, .png, .rtf, .html])
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let t = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect, .enabledDuringMouseDrag],
                               owner: self, userInfo: nil)
        addTrackingArea(t)
        tracking = t
    }

    override func mouseEntered(with event: NSEvent) { dwell?.cursorEntered() }
    override func mouseExited(with event: NSEvent) { /* the tracker polls the cursor itself */ }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { dwell?.clicked() }
    override func rightMouseDown(with event: NSEvent) { dwell?.clicked() }

    // Drag sessions (a file dragged from Finder) open the panel so the user can drop onto it.
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { dwell?.dragEntered(); return [] }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { [] }
    override func draggingExited(_ sender: NSDraggingInfo?) { dwell?.dragExited() }
    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { false }
}

// MARK: - Dwell logic

/// Decides when a cursor resting on the edge should open the panel.
///
/// - The dwell timer runs only while the cursor is on the edge; it polls at 20 Hz during a visit and
///   stops as soon as the cursor leaves (no cost while idle).
/// - A mouse button pressed at any time during a visit invalidates the visit (window drags, selections
///   that hit the edge). The cursor must leave and come back.
/// - Sliding along the edge (more than 40 pt from where the dwell started) restarts the dwell, so moving
///   toward a hot corner does not open the panel.
/// - After firing, the edge stays quiet until the cursor leaves.
@MainActor
final class EdgeDwellTracker {
    let edgeRect: CGRect
    let side: PanelSide
    weak var window: NSWindow?

    var delay: () -> TimeInterval = { 0.3 }
    var isSuppressed: () -> Bool = { false }
    var onFire: () -> Void = {}

    private var timer: Timer?
    private var dwellStart: Date?
    private var anchorY: CGFloat = 0
    private var invalidVisit = false
    private var firedThisVisit = false
    private var passthrough = false
    private var dragTimer: Timer?

    init(edgeRect: CGRect, side: PanelSide) {
        self.edgeRect = edgeRect
        self.side = side
    }

    /// Cursor is on the edge column (with a little tolerance; the cursor can report maxX exactly).
    func isOnEdge(_ p: CGPoint) -> Bool {
        let tolerance: CGFloat = 1.5
        let inX = side == .right ? p.x >= edgeRect.maxX - tolerance - edgeRect.width : p.x <= edgeRect.minX + tolerance + edgeRect.width
        return inX && p.y >= edgeRect.minY - 1 && p.y <= edgeRect.maxY + 1
    }

    func cursorEntered() {
        guard timer == nil else { return }
        let p = NSEvent.mouseLocation
        invalidVisit = NSEvent.pressedMouseButtons != 0
        firedThisVisit = false
        dwellStart = Date()
        anchorY = p.y
        let t = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.tick() } }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func clicked() {
        // The click landed on the 1 pt strip instead of the window below (for example a scroll bar at the
        // screen edge). Let following clicks pass through until the cursor leaves the edge.
        invalidVisit = true
        setPassthrough(true)
        if timer == nil { cursorEntered(); invalidVisit = true }
    }

    func cancel() {
        timer?.invalidate(); timer = nil
        dragTimer?.invalidate(); dragTimer = nil
        dwellStart = nil
        setPassthrough(false)
    }

    private func setPassthrough(_ on: Bool) {
        guard passthrough != on else { return }
        passthrough = on
        window?.ignoresMouseEvents = on
    }

    private func tick() {
        let p = NSEvent.mouseLocation
        guard isOnEdge(p) else { endVisit(); return }
        if NSEvent.pressedMouseButtons != 0 { invalidVisit = true }
        guard !invalidVisit, !firedThisVisit else { return }
        if isSuppressed() { dwellStart = Date(); anchorY = p.y; return }
        if abs(p.y - anchorY) > 40 { dwellStart = Date(); anchorY = p.y; return }
        if let start = dwellStart, Date().timeIntervalSince(start) >= delay() {
            firedThisVisit = true
            onFire()
        }
    }

    private func endVisit() {
        timer?.invalidate(); timer = nil
        dwellStart = nil
        invalidVisit = false
        firedThisVisit = false
        setPassthrough(false)
    }

    func dragEntered() {
        dragTimer?.invalidate()
        let d = max(0.15, min(delay(), 0.6))
        let t = Timer(timeInterval: d, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.dragTimer = nil
                if !self.isSuppressed() { self.onFire() }
            }
        }
        RunLoop.main.add(t, forMode: .common)
        dragTimer = t
    }

    func dragExited() {
        dragTimer?.invalidate(); dragTimer = nil
    }
}
