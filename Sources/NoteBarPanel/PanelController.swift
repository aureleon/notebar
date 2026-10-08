import AppKit
import NoteBarCore

/// Owns the floating side panel, its blurred backdrop and the Hot Side. Create once, call `setContent(_:)`
/// with the notes view controller, then drive it with `show` / `hide` / `toggle`.
///
/// Behavior summary:
/// - The panel appears on the screen with the cursor, inset `PanelMetrics.edgeInset` from the edge, the
///   menu bar and the bottom of `visibleFrame` (so it never covers the menu bar or the Dock).
/// - An explicit show (hotkey, menu bar icon, reveal, URL) orders the panel front without
///   activating NoteBar and makes it key, so typing goes to it while the previous app stays frontmost.
/// - A passive show (Hot Side dwell, file drag) does not take keyboard focus. A click
///   in the panel focuses it. If the user does not interact and the cursor leaves the panel area, it
///   hides again (`PassiveOpenTracker`).
/// - Focus changes in the first `PanelMetrics.showGrace` seconds after a show do not hide the panel.
/// - The backdrop (`PanelBackdrop`) fades with the panel and follows its frame.
/// - Settings changes (side, width, blur, Hot Side) and display changes apply immediately.
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
    private let backdrop: PanelBackdrop
    private let passive = PassiveOpenTracker()

    /// Screen the panel is (or was last) shown on.
    private var screenID: CGDirectDisplayID?
    /// Incremented by every animation; completion handlers of stale animations do nothing.
    private var animationGeneration = 0
    private var observers: [NSObjectProtocol] = []

    public init(env: AppEnvironment) {
        self.env = env
        window = NoteBarPanelWindow()
        container = PanelContentView(frame: NSRect(x: 0, y: 0, width: PanelWidth.fallback, height: 600))
        window.contentView = container
        window.alphaValue = 0
        autoHide = AutoHideMonitor(settings: env.settings, panel: window)
        hotSide = HotSideController(settings: env.settings)
        backdrop = PanelBackdrop(panelLevel: window.level)

        window.onEscape = { [weak self] in self?.hide() }
        window.onClose = { [weak self] in self?.hide() }
        window.onOpenSettings = { [weak self] in self?.env.controller?.openSettings() }

        container.side = env.settings.panelSide
        container.resizeHandle.onResize = { [weak self] proposed in
            // A width set by hand stops following the screen.
            self?.env.settings.panelWidthIsAutomatic = false
            self?.env.settings.panelWidth = Double(PanelSizing.clamp(Double(proposed)))
        }

        autoHide.isPanelVisible = { [weak self] in self?.isVisible ?? false }
        autoHide.hide = { [weak self] in self?.hide() }

        hotSide.isPanelShown = { [weak self] screen in
            guard let self else { return false }
            return self.isVisible && self.screenID == screen.nbDisplayID
        }
        // Passive: the cursor resting on the edge must not take focus from the app the user types in.
        hotSide.onTrigger = { [weak self] screen in self?.show(on: screen, makeKey: false) }

        autoHide.onFocusChange = { [weak self] focused in
            if focused { self?.passive.stop() }
        }
        passive.isEngaged = { [weak self] in self?.autoHide.panelHasFocus ?? true }
        passive.mayHide = { [weak self] in self?.autoHide.isEnabled ?? false }
        passive.onLeave = { [weak self] in self?.hide() }
        passive.panelFrame = { [weak self] in
            guard let self, let screen = self.currentScreen else { return nil }
            return self.geometry(for: screen).shownFrame
        }
        passive.zone = { [weak self] in self?.passiveZone() ?? [] }

        installObservers()
        hotSide.rebuild()
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
    ///
    /// `makeKey`: false for passive opens (Hot Side, drag hover). The panel then does not take keyboard
    /// focus and hides again if the user does not interact with it. A visible panel keeps its current
    /// focus state when a passive show moves it.
    public func show(on screen: NSScreen?, animated: Bool = true, makeKey: Bool = true) {
        guard let target = screen ?? NSScreen.nbScreenWithMouse else { return }
        let g = geometry(for: target)
        let wasVisible = isVisible
        let sameScreen = screenID == target.nbDisplayID
        autoHide.beginShowGrace()

        if wasVisible && sameScreen {
            // Already there: just bring it forward and focus it (e.g. revealNote / showSearch).
            window.orderFrontRegardless()
            if makeKey { focusPanel() }
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
        if makeKey {
            window.makeKey()
            passive.stop()
        }
        let fade = animated ? PanelMetrics.animationDuration : 0
        setFrame(g.shownFrame, alpha: 1, duration: fade, timing: .easeOut)
        backdrop.show(g, enabled: env.settings.blurBackdrop, duration: fade)

        if !wasVisible {
            env.presenter?.panelDidShow()
            autoHide.panelDidShow(focused: makeKey)
            if !makeKey { passive.start() }
            notifyVisibility(true)
        } else if makeKey {
            autoHide.noteFocusGained()
        }
    }

    /// Brings the visible panel forward and gives it keyboard focus (without activating NoteBar).
    private func focusPanel() {
        window.orderFrontRegardless()
        window.makeKey()
        passive.stop()
        autoHide.noteFocusGained()
    }

    /// True while the panel is visible and keyboard focus is in NoteBar. Unlike `isKeyWindow` this is
    /// not stale after the user clicks a window of the already-active app.
    public var panelHasFocus: Bool { isVisible && autoHide.panelHasFocus }

    /// Area that counts as "at the panel" for a passive open: the panel, child windows,
    /// and the band between them and the screen edge (where the Hot Side cursor rests).
    private func passiveZone() -> [CGRect] {
        guard let screen = currentScreen else { return [] }
        let g = geometry(for: screen)
        let core = g.shownFrame
        let sf = screen.frame
        let band: CGRect
        if g.side == .right {
            band = CGRect(x: core.minX, y: sf.minY, width: max(sf.maxX - core.minX, 0), height: sf.height)
        } else {
            band = CGRect(x: sf.minX, y: sf.minY, width: max(core.maxX - sf.minX, 0), height: sf.height)
        }
        return [band] + (window.childWindows ?? []).filter(\.isVisible).map(\.frame)
    }

    public func hide(animated: Bool = true) {
        guard isVisible else { return }
        isVisible = false
        passive.stop()
        autoHide.panelDidHide()
        env.presenter?.panelWillHide()
        env.store.flush()

        let screen = currentScreen
        let slide = animated && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let target = screen.map { geometry(for: $0) }.map { slide ? $0.hiddenFrame : $0.shownFrame } ?? window.frame
        let fade = animated ? PanelMetrics.animationDuration : 0
        setFrame(target, alpha: 0, duration: fade, timing: .easeIn) { [weak self] in
            self?.window.orderOut(nil)
        }
        backdrop.hide(duration: fade)
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

    /// Hotkey / menu bar icon. A visible panel without focus gets focus first; the next toggle hides
    /// it. This applies when it stays open on purpose (Keep Panel Open, or auto-hide off: the user works
    /// in another app next to it) and after a passive open (Hot Side, drag hover).
    ///
    /// Focus comes from `AutoHideMonitor.panelHasFocus`, not `isKeyWindow`, which stays true for a
    /// non-activating panel after the user clicks a window of the already-active app.
    public func toggle() {
        if !isVisible { show(); return }
        let staysOpen = env.settings.pinnedOpen || !env.settings.autoHide
        if !autoHide.panelHasFocus && (staysOpen || passive.isActive)
            && NSApp.modalWindow == nil && window.attachedSheet == nil {
            focusPanel()
            return
        }
        hide()
    }

    /// The screen the panel is shown on / was last shown on (falls back to the main screen).
    public var currentScreen: NSScreen? {
        NSScreen.nbScreen(withID: screenID) ?? NSScreen.screens.first
    }

    // MARK: Frames

    private func geometry(for screen: NSScreen) -> PanelGeometry {
        screen.nbGeometry(side: env.settings.panelSide, width: PanelSizing.requestedWidth(env.settings))
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
        updateBackdrop(duration: 0)
    }

    /// Moves the backdrop to the panel's screen, side and width (or hides it while the panel is hidden).
    private func updateBackdrop(duration: TimeInterval) {
        guard isVisible, let screen = currentScreen else {
            backdrop.hide(duration: duration)
            return
        }
        backdrop.show(geometry(for: screen), enabled: env.settings.blurBackdrop, duration: duration)
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
        case "panelSide", "panelWidth", "panelWidthIsAutomatic", "blurBackdrop":
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
        guard isVisible, let screen = currentScreen else { return }
        let frame = geometry(for: screen).shownFrame
        if window.frame != frame { setFrame(frame, alpha: 1, duration: 0) }
        updateBackdrop(duration: 0)
    }
}
