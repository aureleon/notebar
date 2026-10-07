import AppKit
import NoteBarCore

/// Owns the floating side panel plus its Open Bar and Hot Side. Create once, call `setContent(_:)`
/// with the notes view controller, then drive it with `show` / `hide` / `toggle`.
///
/// Behavior summary:
/// - The panel appears on the screen with the cursor, inset `PanelMetrics.edgeInset` from the edge, the
///   menu bar and the bottom of `visibleFrame` (so it never covers the menu bar or the Dock).
/// - Showing orders the panel front without activating NoteBar and makes it key, so typing goes to it
///   while the previous app stays frontmost.
/// - Settings changes (side, width, Open Bar, Hot Side) and display changes apply immediately.
@MainActor
public final class PanelController {
    /// The NSPanel. Use it as the parent for sheets, child windows (formatting toolbar) and popovers.
    public var panelWindow: NSPanel { window }
    /// Called after every show (true) / hide (false).
    public var onVisibilityChange: ((Bool) -> Void)?
    /// Logical state: true from the start of the show animation until hide is requested.
    public private(set) var isVisible = false

    private let env: AppEnvironment
    private let window: NoteBarPanelWindow
    private let container: PanelContentView
    private var contentController: NSViewController?
    private let autoHide: AutoHideMonitor
    private let hotSide: HotSideController
    private let openBar: OpenBarController

    /// Screen the panel is (or was last) shown on. The Open Bar stays on it while the panel is hidden.
    private var screenID: CGDirectDisplayID?
    /// Incremented by every animation; completion handlers of stale animations do nothing.
    private var animationGeneration = 0
    private var observers: [NSObjectProtocol] = []

    public init(env: AppEnvironment) {
        self.env = env
        window = NoteBarPanelWindow()
        container = PanelContentView(frame: NSRect(x: 0, y: 0, width: 290, height: 600))
        window.contentView = container
        window.alphaValue = 0
        autoHide = AutoHideMonitor(settings: env.settings, panel: window)
        hotSide = HotSideController(settings: env.settings)
        openBar = OpenBarController(env: env)

        window.onEscape = { [weak self] in self?.hide() }
        window.onClose = { [weak self] in self?.hide() }
        window.onOpenSettings = { [weak self] in self?.env.controller?.openSettings() }

        container.side = env.settings.panelSide
        container.resizeHandle.onResize = { [weak self] proposed in
            self?.env.settings.panelWidth = Double(PanelGeometry.clampWidth(Double(proposed)))
        }

        autoHide.isPanelVisible = { [weak self] in self?.isVisible ?? false }
        autoHide.hide = { [weak self] in self?.hide() }
        autoHide.auxiliaryWindows = { [weak self] in self.map { [$0.openBar.window] } ?? [] }

        hotSide.isPanelShown = { [weak self] screen in
            guard let self else { return false }
            return self.isVisible && self.screenID == screen.nbDisplayID
        }
        hotSide.onTrigger = { [weak self] screen in self?.show(on: screen) }

        openBar.onToggle = { [weak self] in self?.toggleFromOpenBar() }
        openBar.onShowRequest = { [weak self] in
            guard let self, !self.isVisible else { return }
            self.show(on: self.currentScreen)
        }
        openBar.isPanelVisible = { [weak self] in self?.isVisible ?? false }
        openBar.currentLayout = { [weak self] in
            guard let self, let screen = self.currentScreen else { return nil }
            return (self.geometry(for: screen), self.isVisible)
        }

        installObservers()
        hotSide.rebuild()
        openBar.update(animated: false)
    }

    // MARK: Content

    /// Installs the view controller's view so it fills the panel. The panel keeps a strong reference.
    public func setContent(_ viewController: NSViewController) {
        contentController = viewController
        container.host(viewController.view)
    }

    // MARK: Show / hide

    public func show(animated: Bool = true) { show(on: nil, animated: animated) }

    /// Shows the panel on `screen` (default: the screen with the cursor). If it is already visible on
    /// another screen it moves there.
    public func show(on screen: NSScreen?, animated: Bool = true) {
        guard let target = screen ?? NSScreen.nbScreenWithMouse else { return }
        let g = geometry(for: target)
        let wasVisible = isVisible
        let sameScreen = screenID == target.nbDisplayID

        if wasVisible && sameScreen {
            // Already there: just bring it forward and focus it (e.g. revealNote / showSearch).
            window.orderFrontRegardless()
            window.makeKey()
            return
        }

        isVisible = true
        screenID = target.nbDisplayID
        container.side = g.side
        let slide = animated && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        // Start from the hidden position (or fade in place when Reduce Motion is on). If a hide animation
        // on the same screen is still running, reverse it from where it is instead of jumping.
        let midHideOnSameScreen = window.isVisible && sameScreen && window.frame.width == g.shownFrame.width
        if !midHideOnSameScreen {
            setFrame(slide ? g.hiddenFrame : g.shownFrame, alpha: 0, duration: 0)
        }
        window.orderFrontRegardless()
        window.makeKey()
        setFrame(g.shownFrame, alpha: 1, duration: animated ? PanelMetrics.animationDuration : 0, timing: .easeOut)
        openBar.update(animated: animated)

        if !wasVisible {
            env.presenter?.panelDidShow()
            autoHide.panelDidShow()
            notifyVisibility(true)
        }
    }

    public func hide(animated: Bool = true) {
        guard isVisible else { return }
        isVisible = false
        autoHide.panelDidHide()
        env.presenter?.panelWillHide()
        env.store.flush()

        let screen = currentScreen
        let slide = animated && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let target = screen.map { geometry(for: $0) }.map { slide ? $0.hiddenFrame : $0.shownFrame } ?? window.frame
        setFrame(target, alpha: 0, duration: animated ? PanelMetrics.animationDuration : 0, timing: .easeIn) { [weak self] in
            self?.window.orderOut(nil)
        }
        openBar.update(animated: animated)
        notifyVisibility(false)
        yieldActivationIfIdle()
    }

    /// The panel never activates NoteBar, but an alert / sheet / Settings window may have. If NoteBar is
    /// active and has no other visible window left, give focus back to the previous app so keystrokes do
    /// not go nowhere.
    private func yieldActivationIfIdle() {
        guard NSApp.isActive else { return }
        let others = NSApp.windows.contains { w in
            w !== window && w.isVisible && w.canBecomeKey && w.styleMask.contains(.titled)
        }
        if !others { NSApp.deactivate() }
    }

    /// Hotkey / menu bar icon. A pinned panel that is visible but not focused (the user works in another
    /// app next to it) gets focus first; the next toggle hides it.
    public func toggle() {
        if !isVisible { show(); return }
        if env.settings.pinnedOpen && !window.isKeyWindow && NSApp.keyWindow == nil {
            window.orderFrontRegardless()
            window.makeKey()
            return
        }
        hide()
    }

    /// Clicking the Open Bar: it lives on a specific screen, so open on that screen.
    private func toggleFromOpenBar() {
        if isVisible { hide() } else { show(on: currentScreen) }
    }

    /// The screen the panel is shown on / was last shown on (falls back to the main screen).
    public var currentScreen: NSScreen? {
        NSScreen.nbScreen(withID: screenID) ?? NSScreen.screens.first
    }

    // MARK: Frames

    private func geometry(for screen: NSScreen) -> PanelGeometry {
        screen.nbGeometry(side: env.settings.panelSide, width: env.settings.panelWidth)
    }

    /// Animates (or sets) frame + alpha. Every call supersedes earlier animations.
    private func setFrame(_ frame: CGRect, alpha: CGFloat, duration: TimeInterval,
                          timing: CAMediaTimingFunctionName = .easeInEaseOut, completion: (() -> Void)? = nil) {
        animationGeneration += 1
        let generation = animationGeneration
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = duration
            ctx.timingFunction = CAMediaTimingFunction(name: timing)
            ctx.allowsImplicitAnimation = false
            if duration > 0 {
                window.animator().setFrame(frame, display: true)
                window.animator().alphaValue = alpha
            } else {
                window.animator().setFrame(frame, display: true)
                window.animator().alphaValue = alpha
                window.setFrame(frame, display: true)
                window.alphaValue = alpha
            }
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, generation == self.animationGeneration else { return }
                completion?()
            }
        })
    }

    /// Re-applies the frame for the current settings / screens without animation.
    private func relayout() {
        container.side = env.settings.panelSide
        if isVisible {
            if NSScreen.nbScreen(withID: screenID) == nil { screenID = NSScreen.nbScreenWithMouse?.nbDisplayID }
            if let screen = currentScreen { setFrame(geometry(for: screen).shownFrame, alpha: 1, duration: 0) }
        }
        openBar.update(animated: false)
    }

    private func notifyVisibility(_ visible: Bool) {
        onVisibilityChange?(visible)
        NotificationCenter.default.post(name: NoteBarPanelNotification.panelVisibilityDidChange, object: self,
                                        userInfo: ["visible": visible])
    }

    // MARK: Observers

    private func installObservers() {
        let nc = NotificationCenter.default
        observers.append(nc.addObserver(forName: .appSettingsDidChange, object: env.settings, queue: .main) { [weak self] n in
            let key = n.userInfo?["key"] as? String
            MainActor.assumeIsolated { self?.settingsChanged(key) }
        })
        observers.append(nc.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.screensChanged() }
        })
        // The menu bar can auto-hide in full-screen Spaces, which changes visibleFrame.
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.spaceChanged() }
        })
    }

    private func settingsChanged(_ key: String?) {
        switch key {
        case "panelSide", "panelWidth", "showOpenBar":
            // HotSideController observes panelSide / hotSideEnabled itself.
            relayout()
        case "autoHide", "pinnedOpen":
            // Turning pin off while focus is elsewhere should hide on the next check.
            autoHide.scheduleCheck()
        case nil:
            relayout()
        default:
            break
        }
    }

    private func screensChanged() {
        hotSide.rebuild()
        relayout()
    }

    private func spaceChanged() {
        guard isVisible, let screen = currentScreen else { openBar.update(animated: false); return }
        let frame = geometry(for: screen).shownFrame
        if window.frame != frame { setFrame(frame, alpha: 1, duration: 0) }
        openBar.update(animated: false)
    }
}
