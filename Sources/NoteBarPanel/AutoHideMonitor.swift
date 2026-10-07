import AppKit
import NoteBarCore

/// Hides the panel when the user leaves it: a click in another app, another app becoming active, or the
/// panel losing key status to a window that is not ours.
///
/// It never hides while:
/// - focus is on one of our own windows (Settings, alerts, sheets, save panels, Quick Look, popovers,
///   the formatting toolbar child panel, menus),
/// - a mouse button is still down (the user may be dragging a file from Finder onto the panel),
/// - the cursor is over the panel when the button comes up (a drop onto the panel, or a click that
///   fell through a transparent gap between cards),
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

    private var globalMouseMonitor: Any?
    private var observers: [NSObjectProtocol] = []
    private var pendingCheck: DispatchWorkItem?
    private var suspendCount = 0
    private var isActive = false

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

    private var permanentObservers: [NSObjectProtocol] = []

    var isEnabled: Bool { settings.autoHide && !settings.pinnedOpen && suspendCount == 0 }

    func setSuspended(_ suspended: Bool) {
        suspendCount = max(0, suspendCount + (suspended ? 1 : -1))
        if suspendCount == 0 { scheduleCheck() }
    }

    // MARK: Lifecycle (only monitor while the panel is shown)

    func panelDidShow() {
        guard !isActive else { return }
        isActive = true
        let nc = NotificationCenter.default
        let wnc = NSWorkspace.shared.notificationCenter
        if let panel {
            observers.append(nc.addObserver(forName: NSWindow.didResignKeyNotification, object: panel, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.scheduleCheck() }
            })
        }
        observers.append(nc.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleCheck() }
        })
        observers.append(wnc.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] n in
            let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            guard app?.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
            MainActor.assumeIsolated { self?.scheduleCheck() }
        })
        // Clicks delivered to other apps (the panel may not be key, e.g. after a drop).
        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleCheck(after: 0.05) }
        }
    }

    func panelDidHide() {
        guard isActive else { return }
        isActive = false
        pendingCheck?.cancel(); pendingCheck = nil
        let nc = NotificationCenter.default
        let wnc = NSWorkspace.shared.notificationCenter
        for o in observers { nc.removeObserver(o); wnc.removeObserver(o) }
        observers.removeAll()
        if let globalMouseMonitor { NSEvent.removeMonitor(globalMouseMonitor) }
        globalMouseMonitor = nil
    }

    // MARK: Decision

    /// The short delay lets focus settle (a sheet or our Settings window becoming key right after the
    /// panel resigns key) before deciding.
    func scheduleCheck(after delay: TimeInterval = 0.15) {
        guard isActive else { return }
        pendingCheck?.cancel()
        let item = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.evaluate() } }
        pendingCheck = item
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }

    private func evaluate() {
        pendingCheck = nil
        guard isActive, isPanelVisible(), isEnabled, let panel else { return }

        // Still pressing: maybe a drag from another app toward the panel. Decide on release.
        if NSEvent.pressedMouseButtons != 0 { scheduleCheck(after: 0.1); return }

        if panel.isKeyWindow { return }
        if NSApp.modalWindow != nil || panel.attachedSheet != nil { return }
        if let key = NSApp.keyWindow, key.isVisible { return }   // one of our own windows has focus

        let mouse = NSEvent.mouseLocation
        let inside = ([panel] + auxiliaryWindows()).contains { $0.isVisible && $0.frame.insetBy(dx: -2, dy: -2).contains(mouse) }
        if inside {
            // Dropped onto the panel or clicked a transparent gap: keep it and take focus back.
            panel.makeKey()
            return
        }
        hide()
    }
}
