import AppKit
import NoteBarCore

/// The Open Bar: a thin vertical pill on the panel's inner side while the panel is shown, and at the
/// screen edge while it is hidden. Click toggles the panel, right-click shows the side menu, vertical
/// drag moves it (the offset is saved in UserDefaults "openBarOffset"). Dragging a file over it opens
/// the panel so the user can drop onto a note.
@MainActor
final class OpenBarController {
    static let offsetDefaultsKey = "openBarOffset"

    let window: OpenBarWindow
    let view: OpenBarView
    private let env: AppEnvironment
    private let defaults: UserDefaults

    var onToggle: () -> Void = {}
    var onShowRequest: () -> Void = {}
    /// Frame / state provider: the geometry of the screen the bar belongs to and whether the panel is shown.
    var currentLayout: () -> (geometry: PanelGeometry, panelShown: Bool)? = { nil }
    var isPanelVisible: () -> Bool = { false }

    private var dragStartOffset: CGFloat = 0

    init(env: AppEnvironment, defaults: UserDefaults = .standard) {
        self.env = env
        self.defaults = defaults
        view = OpenBarView(frame: NSRect(x: 0, y: 0, width: PanelMetrics.openBarHitWidth, height: PanelMetrics.openBarHitHeight))
        window = OpenBarWindow(contentView: view)
        view.onClick = { [weak self] in self?.onToggle() }
        view.onMenu = { [weak self] event in self?.showMenu(for: event) }
        view.onDragBegan = { [weak self] in guard let self else { return }; self.dragStartOffset = self.offset }
        view.onDrag = { [weak self] dy in self?.dragged(by: dy) }
        view.onDragEnded = { [weak self] in self?.saveOffset() }
        view.onFileDragHover = { [weak self] in self?.onShowRequest() }
    }

    var offset: CGFloat {
        get { CGFloat(defaults.double(forKey: Self.offsetDefaultsKey)) }
        set { defaults.set(Double(newValue), forKey: Self.offsetDefaultsKey) }
    }

    private var liveOffset: CGFloat?

    /// Positions (and shows / hides) the bar for the current state.
    func update(animated: Bool) {
        guard env.settings.showOpenBar, let layout = currentLayout() else {
            window.orderOut(nil)
            return
        }
        let g = layout.geometry
        let frame = g.openBarFrame(panelShown: layout.panelShown, offset: liveOffset ?? offset)
        view.side = g.side
        view.panelShown = layout.panelShown
        view.toolTip = layout.panelShown ? "Hide NoteBar" : "Show NoteBar" + hotkeyHint
        let wasVisible = window.isVisible
        if animated && wasVisible && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = PanelMetrics.animationDuration
                ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                window.animator().setFrame(frame, display: true)
            }
        } else {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0
                window.animator().setFrame(frame, display: true)
            }
        }
        if !wasVisible { window.orderFrontRegardless() }
    }

    private var hotkeyHint: String {
        guard let combo = env.settings.hotkeys[.togglePanel] else { return "" }
        return " (\(combo.displayString))"
    }

    // MARK: Drag to move vertically

    private func dragged(by dy: CGFloat) {
        guard let layout = currentLayout() else { return }
        let vf = layout.geometry.visibleFrame
        liveOffset = PanelGeometry.clampOpenBarOffset(dragStartOffset + dy, visibleFrame: vf)
        update(animated: false)
    }

    private func saveOffset() {
        if let liveOffset { offset = liveOffset }
        liveOffset = nil
    }

    // MARK: Menu

    func makeMenu() -> NSMenu {
        let s = env.settings
        let menu = NSMenu(title: "Open Bar")
        menu.autoenablesItems = false
        let shown = isPanelVisible()
        let toggle = ClosureMenuItem(shown ? "Hide NoteBar" : "Show NoteBar") { [weak self] in self?.onToggle() }
        toggle.nbShowHotkey(s.hotkeys[.togglePanel])
        menu.addItem(toggle)
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem("Move to Left Side", state: s.panelSide == .left ? .on : .off) { s.panelSide = .left })
        menu.addItem(ClosureMenuItem("Move to Right Side", state: s.panelSide == .right ? .on : .off) { s.panelSide = .right })
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem("Keep Panel Open", state: s.pinnedOpen ? .on : .off) { s.pinnedOpen.toggle() })
        menu.addItem(ClosureMenuItem("Reset Open Bar Position", enabled: offset != 0) { [weak self] in
            self?.offset = 0; self?.update(animated: true)
        })
        menu.addItem(ClosureMenuItem("Hide Open Bar") { s.showOpenBar = false })
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem("Settings…") { [weak self] in self?.env.controller?.openSettings() })
        return menu
    }

    private func showMenu(for event: NSEvent) {
        NSMenu.popUpContextMenu(makeMenu(), with: event, for: view)
    }
}

// MARK: - Window

final class OpenBarWindow: NSPanel {
    init(contentView: NSView) {
        super.init(contentRect: contentView.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .statusBar
        collectionBehavior = edgeWindowCollectionBehavior
        isOpaque = false
        hasShadow = false
        backgroundColor = .clear
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        isExcludedFromWindowsMenu = true
        animationBehavior = .none
        becomesKeyOnlyIfNeeded = true
        acceptsMouseMovedEvents = true
        self.contentView = contentView
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

// MARK: - View

/// Draws the pill and handles hover, click, right-click, vertical drag and file-drag hover.
final class OpenBarView: NSView {
    var onClick: () -> Void = {}
    var onMenu: (NSEvent) -> Void = { _ in }
    var onDragBegan: () -> Void = {}
    /// Total vertical distance (points, up = positive) since the drag began.
    var onDrag: (CGFloat) -> Void = { _ in }
    var onDragEnded: () -> Void = {}
    var onFileDragHover: () -> Void = {}

    var side: PanelSide = .right { didSet { if side != oldValue { needsLayout = true } } }
    var panelShown = false { didSet { if panelShown != oldValue { needsLayout = true } } }

    private(set) var isHovered = false { didSet { if isHovered != oldValue { updateAppearance(animated: true) } } }
    private var isPressed = false { didSet { if isPressed != oldValue { updateAppearance(animated: true) } } }

    private let hitLayer = CALayer()
    private let pill = CALayer()
    private var tracking: NSTrackingArea?
    private var mouseDownPoint: CGPoint?
    private var isDraggingBar = false
    private var fileDragTimer: Timer?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        // Nearly invisible fill so the whole hit area receives clicks (alpha-0 pixels are click-through).
        hitLayer.backgroundColor = NSColor(white: 0, alpha: 0.012).cgColor
        hitLayer.cornerRadius = 6
        layer?.addSublayer(hitLayer)
        pill.borderWidth = 0.5
        pill.shadowOpacity = 0.25
        pill.shadowRadius = 2
        pill.shadowOffset = .zero
        pill.shadowColor = NSColor.black.cgColor
        layer?.addSublayer(pill)
        registerForDraggedTypes([.fileURL, .URL, .string, .tiff, .png, .rtf, .html])
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel("Show or hide NoteBar")
        updateAppearance(animated: false)
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    override var isOpaque: Bool { false }
    override var isFlipped: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func accessibilityPerformPress() -> Bool { onClick(); return true }

    /// Pill rect inside the hit area. Hidden panel: close to the screen edge. Shown: centered.
    var pillRect: CGRect {
        let w = PanelMetrics.openBarPillWidth + (isHovered || isPressed ? 1 : 0)
        let h = PanelMetrics.openBarPillHeight + (isHovered || isPressed ? 4 : 0)
        let x: CGFloat
        if panelShown {
            x = (bounds.width - w) / 2
        } else {
            x = side == .right ? bounds.width - PanelMetrics.openBarEdgeGap - w : PanelMetrics.openBarEdgeGap
        }
        return CGRect(x: x, y: (bounds.height - h) / 2, width: w, height: h)
    }

    override func layout() {
        super.layout()
        updateAppearance(animated: false)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateAppearance(animated: false)
    }

    func updateAppearance(animated: Bool) {
        CATransaction.begin()
        CATransaction.setDisableActions(!animated)
        CATransaction.setAnimationDuration(0.12)
        hitLayer.frame = bounds
        let r = pillRect
        pill.frame = r
        pill.cornerRadius = r.width / 2
        let dark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        // Neutral gray reads on both light and dark wallpapers; the border adds contrast on mid tones.
        let fillAlpha: CGFloat = isPressed ? 0.95 : (isHovered ? 0.88 : 0.62)
        let fill = dark ? NSColor(white: 0.78, alpha: fillAlpha) : NSColor(white: 0.52, alpha: fillAlpha)
        pill.backgroundColor = fill.cgColor
        pill.borderColor = (dark ? NSColor(white: 0, alpha: 0.35) : NSColor(white: 1, alpha: 0.55)).cgColor
        CATransaction.commit()
    }

    // MARK: Tracking

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let t = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                               owner: self, userInfo: nil)
        addTrackingArea(t)
        tracking = t
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false }

    // MARK: Mouse

    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.control) { onMenu(event); return }
        mouseDownPoint = NSEvent.mouseLocation
        isDraggingBar = false
        isPressed = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = mouseDownPoint else { return }
        let dy = NSEvent.mouseLocation.y - start.y
        if !isDraggingBar, abs(dy) >= 4 {
            isDraggingBar = true
            onDragBegan()
            NSCursor.closedHand.set()
        }
        if isDraggingBar { onDrag(dy) }
    }

    override func mouseUp(with event: NSEvent) {
        defer { mouseDownPoint = nil; isDraggingBar = false; isPressed = false }
        guard mouseDownPoint != nil else { return }
        if isDraggingBar {
            onDragEnded()
            NSCursor.arrow.set()
        } else {
            onClick()
        }
    }

    override func rightMouseDown(with event: NSEvent) { onMenu(event) }
    override func menu(for event: NSEvent) -> NSMenu? { nil }   // menus are built fresh in onMenu

    // MARK: File drag hover

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        isHovered = true
        fileDragTimer?.invalidate()
        let t = Timer(timeInterval: 0.25, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.fileDragTimer = nil; self?.onFileDragHover() }
        }
        RunLoop.main.add(t, forMode: .common)
        fileDragTimer = t
        return []
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { [] }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        isHovered = false
        fileDragTimer?.invalidate(); fileDragTimer = nil
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { false }
}
