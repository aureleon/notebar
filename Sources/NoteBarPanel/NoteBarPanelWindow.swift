import AppKit
import NoteBarCore

/// The floating side panel window. Borderless, non-activating (typing works while another app stays
/// frontmost), visually transparent: the hosted content draws its own cards and shadows. The content
/// view has a nearly invisible fill so empty areas do not pass clicks to the app below.
/// (See `PanelContentView.hitTestFill`.)
final class NoteBarPanelWindow: NSPanel {
    /// Escape that no view handled.
    var onEscape: (() -> Void)?
    /// ⌘W.
    var onClose: (() -> Void)?
    /// ⌘,
    var onOpenSettings: (() -> Void)?

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 290, height: 600),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        level = .statusBar
        collectionBehavior = edgeWindowCollectionBehavior
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        hidesOnDeactivate = false
        isFloatingPanel = true
        level = .statusBar            // isFloatingPanel resets the level; set it again.
        becomesKeyOnlyIfNeeded = false
        worksWhenModal = true
        isMovable = false
        isMovableByWindowBackground = false
        isReleasedWhenClosed = false
        isExcludedFromWindowsMenu = true
        tabbingMode = .disallowed
        animationBehavior = .none
        acceptsMouseMovedEvents = true
        title = "NoteBar"
        setAccessibilityLabel("NoteBar")
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// Never push the panel back on screen: hidden frames are intentionally off the edge.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }

    /// NSPanel closes itself on Escape by default; route it to the controller instead.
    override func cancelOperation(_ sender: Any?) { onEscape?() }

    override func keyDown(with event: NSEvent) {
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.capsLock, .numericPad, .function])
        if event.keyCode == 53, mods.isEmpty { onEscape?(); return }
        super.keyDown(with: event)
    }

    override func close() {
        // Something asked the panel to close (for example performClose from a responder): treat as hide.
        if let onClose { onClose() } else { super.close() }
    }

    /// Standard editing shortcuts must work even if the app has no main menu, and while the app is not
    /// active (the panel is non-activating, so the menu bar belongs to another app).
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if super.performKeyEquivalent(with: event) { return true }
        guard event.type == .keyDown else { return false }
        if let menu = NSApp.mainMenu, menu.performKeyEquivalent(with: event) { return true }

        let mods = event.modifierFlags.intersection([.command, .shift, .option, .control])
        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
        var selector: Selector?
        switch (mods, key) {
        case ([.command], "x"): selector = #selector(NSText.cut(_:))
        case ([.command], "c"): selector = #selector(NSText.copy(_:))
        case ([.command], "v"): selector = #selector(NSText.paste(_:))
        case ([.command], "a"): selector = #selector(NSText.selectAll(_:))
        case ([.command], "z"): selector = Selector(("undo:"))
        case ([.command, .shift], "z"): selector = Selector(("redo:"))
        case ([.command, .shift, .option], "v"): selector = #selector(NSTextView.pasteAsPlainText(_:))
        case ([.command], "w"):
            onClose?(); return true
        case ([.command], ","):
            onOpenSettings?(); return true
        default: break
        }
        if let selector { return NSApp.sendAction(selector, to: nil, from: self) }
        return false
    }
}

/// Root view of the panel: invisible but hit-testable, hosts the notes view controller's view and the
/// resize handle.
final class PanelContentView: NSView {
    /// The window server sends mouse, scroll and drag events on alpha-0 pixels to the window below.
    /// The content draws nothing in the gaps between cards and under a short list, so a nearly invisible
    /// fill (2/255) keeps the whole panel rect "solid": those events stay in the panel.
    static let hitTestFill = NSColor(white: 0, alpha: 0.008)

    let resizeHandle = PanelResizeHandle()
    private(set) weak var hostedView: NSView?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = Self.hitTestFill.cgColor
        autoresizesSubviews = true
        addSubview(resizeHandle)
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    override var isOpaque: Bool { false }

    func host(_ view: NSView) {
        hostedView?.removeFromSuperview()
        view.translatesAutoresizingMaskIntoConstraints = true
        view.frame = bounds
        view.autoresizingMask = [.width, .height]
        addSubview(view, positioned: .below, relativeTo: resizeHandle)
        hostedView = view
    }

    var side: PanelSide = .right { didSet { needsLayout = true } }

    override func layout() {
        super.layout()
        hostedView?.frame = bounds
        let w = PanelResizeHandle.thickness
        // The handle sits on the inner edge, below the header area so it does not cover header buttons.
        let topReserve: CGFloat = 56
        let h = max(bounds.height - topReserve - 16, 0)
        let x = side == .right ? 0 : bounds.width - w
        resizeHandle.frame = NSRect(x: x, y: 16, width: w, height: h)
        resizeHandle.side = side
    }
}

/// Thin invisible strip on the panel's inner edge. Drag it to change the panel width.
final class PanelResizeHandle: NSView {
    static let thickness: CGFloat = 4

    var side: PanelSide = .right
    /// Called with the proposed new width during a drag (unclamped).
    var onResize: ((CGFloat) -> Void)?
    var onResizeEnded: (() -> Void)?

    private var dragStartMouseX: CGFloat = 0
    private var dragStartWidth: CGFloat = 0
    private var dragging = false
    private var tracking: NSTrackingArea?

    private static let cursor = NSCursor.columnResize(directions: .all)

    override var isOpaque: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        // .activeAlways: the panel's app is usually not active.
        let t = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                               owner: self, userInfo: nil)
        addTrackingArea(t)
        tracking = t
    }

    override func mouseEntered(with event: NSEvent) { Self.cursor.set() }
    override func mouseExited(with event: NSEvent) { if !dragging { NSCursor.arrow.set() } }

    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        dragging = true
        dragStartMouseX = NSEvent.mouseLocation.x
        dragStartWidth = window.frame.width
        Self.cursor.set()
    }

    override func mouseDragged(with event: NSEvent) {
        guard dragging else { return }
        let dx = NSEvent.mouseLocation.x - dragStartMouseX
        // Right-side panel grows when dragging left (negative dx), left-side panel when dragging right.
        let proposed = side == .right ? dragStartWidth - dx : dragStartWidth + dx
        onResize?(proposed)
        Self.cursor.set()
    }

    override func mouseUp(with event: NSEvent) {
        guard dragging else { return }
        dragging = false
        onResizeEnded?()
        if let window, !NSMouseInRect(window.mouseLocationOutsideOfEventStream, frame, false) { NSCursor.arrow.set() }
    }
}
