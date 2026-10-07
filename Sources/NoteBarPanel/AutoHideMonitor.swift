import AppKit
import NoteBarCore

/// Tracks whether the user's focus is in NoteBar while the panel is shown, and hides the panel when the
/// user leaves it: a click in another app, or another app becoming active.
///
/// Focus tracking (`panelHasFocus`) does not trust `NSWindow.isKeyWindow`: a non-activating panel can
/// stay key after the user clicks a window of the app that is already active. The flag is:
/// - set when the panel is shown focused, made key, becomes key, or gets a mouse-down (local monitor),
///   and when another of our own windows (Settings, alerts, Quick Look, popovers) becomes key,
/// - cleared by any mouse-down that goes to another app (global monitor), by another app becoming
///   active, and when our app is left with no key window.
/// The monitors stay installed while the panel is visible, also when auto-hide is off or the panel is
/// pinned, so the flag stays correct for `PanelController.toggle()`.
///
/// It never hides while:
/// - focus is on one of our own windows (Settings, alerts, sheets, save panels, Quick Look, popovers,
///   the formatting toolbar child panel, menus),
/// - a mouse button is still down (the user may be dragging a file from Finder onto the panel),
/// - the cursor is over the panel when the button comes up (a drag from another app dropped onto it),
/// - auto-hide is off, the panel is pinned open, or a suspension is active.
///
/// Mouse-down global monitors need no Accessibility permission (only key monitors do).
@MainActor
final class AutoHideMonitor {
    private let settings: AppSettings
    private weak var panel: NSPanel?
    /// Extra windows that count as "inside" (the Open Bar).
    var auxiliaryWindows: () -> [NSWindow] = { [] }
    var isPanelVisible: () -> Bool = { false }
    var hide: () -> Void = {}
    /// Called when the focus flag changes.
    var onFocusChange: (Bool) -> Void = { _ in }

    /// True while keyboard focus is in NoteBar (the panel or one of our own windows). Only meaningful
    /// while the panel is visible; false while it is hidden.
    private(set) var panelHasFocus = false {
        didSet { if panelHasFocus != oldValue { onFocusChange(panelHasFocus) } }
    }

    private var globalMouseMonitor: Any?
    private var localMouseMonitor: Any?
    private var observers: [NSObjectProtocol] = []
    private var permanentObservers: [NSObjectProtocol] = []
    private var pendingCheck: DispatchWorkItem?
    private var pendingOutsideClick = false
    private var suspendCount = 0
    private var isActive = false
    private let ownPID = ProcessInfo.processInfo.processIdentifier

    init(settings: AppSettings, panel: NSPanel) {
        self.settings = settings
        self.panel = panel
        // Always-on: suspension requests can arrive while the panel is hidden.
        let o = NotificationCenter.default.addObserver(forName: NoteBarPanelNotification.suspendAutoHide, object: nil, queue: .main) { [weak self] n in
            let active = (n.userInfo?["active"] as? Bool) ?? false
            MainActor.assumeIsolated { self?.setSuspended(active) }
        }
        permanentObservers.append(o)
    }

    var isEnabled: Bool { settings.autoHide && !settings.pinnedOpen && suspendCount == 0 }

    func setSuspended(_ suspended: Bool) {
        suspendCount = max(0, suspendCount + (suspended ? 1 : -1))
        if suspendCount == 0 { scheduleCheck() }
    }

    /// The panel was made key on purpose (hotkey, toggle, reveal).
    func noteFocusGained() {
        guard isActive else { return }
        panelHasFocus = true
    }

    // MARK: Lifecycle (only monitor while the panel is shown)

    /// `focused`: the panel was made key (explicit open). False for passive opens (Hot Side, drag hover).
    func panelDidShow(focused: Bool) {
        guard !isActive else {
            if focused { panelHasFocus = true }
            return
        }
        isActive = true
        panelHasFocus = focused
        let nc = NotificationCenter.default
        let wnc = NSWorkspace.shared.notificationCenter

        // Any of our windows becoming key (the panel after a click, Settings, an alert, a popover).
        observers.append(nc.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main) { [weak self] n in
            let window = n.object as? NSWindow
            MainActor.assumeIsolated {
                guard let self, let window, self.countsAsFocus(window) else { return }
                self.panelHasFocus = true
            }
        })
        // Key moved away. If nothing of ours is key after focus settles, focus left NoteBar.
        observers.append(nc.addObserver(forName: NSWindow.didResignKeyNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleCheck(focusSettled: true) }
        })
        observers.append(nc.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleCheck(focusSettled: true) }
        })
        observers.append(wnc.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] n in
            let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            let pid = app?.processIdentifier
            MainActor.assumeIsolated {
                guard let self, pid != self.ownPID else { return }
                // Another app took focus (⌘-Tab, Dock, Mission Control, an app activating itself).
                self.panelHasFocus = false
                self.scheduleCheck()
            }
        })
        // Clicks delivered to other apps. The panel may still report key status (see above).
        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.panelHasFocus = false
                self.scheduleCheck(after: 0.05, outsideClick: true)
            }
        }
        // Clicks in the panel (also when AppKit already considers it key, so no notification comes).
        localMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] event in
            MainActor.assumeIsolated {
                guard let self, let window = event.window, self.isPanelOrAttached(window) else { return }
                self.panelHasFocus = true
            }
            return event
        }
    }

    func panelDidHide() {
        guard isActive else { return }
        isActive = false
        panelHasFocus = false
        pendingCheck?.cancel(); pendingCheck = nil
        pendingOutsideClick = false
        let nc = NotificationCenter.default
        let wnc = NSWorkspace.shared.notificationCenter
        for o in observers { nc.removeObserver(o); wnc.removeObserver(o) }
        observers.removeAll()
        if let globalMouseMonitor { NSEvent.removeMonitor(globalMouseMonitor) }
        globalMouseMonitor = nil
        if let localMouseMonitor { NSEvent.removeMonitor(localMouseMonitor) }
        localMouseMonitor = nil
    }

    // MARK: Window classification

    /// The panel itself, its child windows (formatting toolbar) and its sheets.
    private func isPanelOrAttached(_ window: NSWindow) -> Bool {
        guard let panel else { return false }
        if window === panel || window === panel.attachedSheet { return true }
        if panel.childWindows?.contains(where: { $0 === window }) == true { return true }
        var parent = window.parent
        while let p = parent {
            if p === panel { return true }
            parent = p.parent
        }
        return false
    }

    /// Windows whose key status means "the user works in NoteBar". The status item window, the Open Bar
    /// and the Hot Side strips never count (they cannot or should not take focus).
    private func countsAsFocus(_ window: NSWindow) -> Bool {
        if isPanelOrAttached(window) { return true }
        if window is HotSideWindow || window is OpenBarWindow { return false }
        if NSStringFromClass(type(of: window)).contains("StatusBar") { return false }
        return window.canBecomeKey
    }

    /// The current key window of our app, if it is a real one (not the panel's possibly stale status).
    private var otherOwnKeyWindow: NSWindow? {
        guard let key = NSApp.keyWindow, key !== panel, key.isVisible, countsAsFocus(key) else { return nil }
        return key
    }

    // MARK: Decision

    /// The short delay lets focus settle (a sheet or our Settings window becoming key right after the
    /// panel resigns key) before deciding. `outsideClick`: a global monitor saw a click that went to
    /// another app. Then the panel hides even if it still reports key status (a non-activating panel can
    /// stay key when the user clicks a window of the app that is already active). `focusSettled`: key
    /// status moved; clear the focus flag if nothing of ours is key afterwards.
    func scheduleCheck(after delay: TimeInterval = 0.15, outsideClick: Bool = false, focusSettled: Bool = false) {
        guard isActive else { return }
        pendingOutsideClick = pendingOutsideClick || outsideClick
        pendingFocusSettle = pendingFocusSettle || focusSettled
        pendingCheck?.cancel()
        let item = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.evaluate() } }
        pendingCheck = item
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }

    private var pendingFocusSettle = false

    private func evaluate() {
        pendingCheck = nil
        guard isActive else { pendingOutsideClick = false; pendingFocusSettle = false; return }

        if pendingFocusSettle {
            pendingFocusSettle = false
            // AppKit may still report the panel as key (stale for a non-activating panel); only a
            // definite "no key window" or a key window that is not ours clears the flag here. The
            // global monitors handle the stale case.
            if NSApp.modalWindow == nil, otherOwnKeyWindow == nil, NSApp.keyWindow == nil {
                panelHasFocus = false
            }
        }

        guard isPanelVisible(), isEnabled, let panel else { pendingOutsideClick = false; return }

        // Still pressing: maybe a drag from another app toward the panel. Decide on release.
        if NSEvent.pressedMouseButtons != 0 { scheduleCheck(after: 0.1); return }
        let outsideClick = pendingOutsideClick
        pendingOutsideClick = false

        if NSApp.modalWindow != nil || panel.attachedSheet != nil { return }
        if outsideClick {
            let mouse = NSEvent.mouseLocation
            let inside = ([panel] + auxiliaryWindows() + (panel.childWindows ?? [])).contains {
                $0.isVisible && $0.frame.insetBy(dx: -2, dy: -2).contains(mouse)
            }
            // A drag that started in another app and was dropped onto the panel: keep the panel. It does
            // not take focus; the user clicks it to type.
            if inside { return }
            // A click in another app while one of our own windows (Settings, Quick Look) is key and
            // NoteBar is active: that click deactivates NoteBar, so hiding is right. If NoteBar is not
            // active, the click went elsewhere: hide as well.
            hide()
            return
        }

        if panelHasFocus { return }
        if otherOwnKeyWindow != nil { return }   // one of our own windows has focus
        // Focus went to another app without a click (⌘-Tab, Mission Control, an app activating itself).
        // The cursor position does not matter here: taking focus back would fight the user.
        hide()
    }
}
