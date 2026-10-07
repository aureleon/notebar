import AppKit
import SwiftUI
import NoteBarCore

/// The Settings window: a normal titled window with toolbar tabs (General, Appearance, Shortcuts,
/// Data, About). Created lazily on the first `show()` and reused afterwards.
@MainActor
public final class SettingsWindowController: NSObject, NSWindowDelegate {
    public let models: SettingsModels
    private var windowStorage: NSWindow?
    private var tabController: SettingsTabViewController?
    private var hasBeenShown = false

    public init(env: AppEnvironment) {
        models = SettingsModels(env: env)
        super.init()
    }

    /// The settings window (created on first access, not shown).
    public var window: NSWindow {
        if let windowStorage { return windowStorage }
        let w = makeWindow()
        windowStorage = w
        return w
    }

    public var isVisible: Bool { windowStorage?.isVisible ?? false }

    /// Brings the settings window to the front (the app is an accessory app, so activate it first).
    public func show() { show(tab: nil) }

    /// Shows the window and selects `tab` (nil keeps the current tab).
    public func show(tab: SettingsTab?) {
        let w = window
        models.refresh()
        if let tab { select(tab) }
        NSApp.activate()
        if !hasBeenShown {
            hasBeenShown = true
            w.center()
        }
        w.makeKeyAndOrderFront(nil)
        w.orderFrontRegardless()
    }

    public func select(_ tab: SettingsTab) {
        _ = window
        guard let tc = tabController, let index = SettingsTab.allCases.firstIndex(of: tab) else { return }
        tc.selectedTabViewItemIndex = index
    }

    public func close() { windowStorage?.performClose(nil) }

    // MARK: Window

    private func makeWindow() -> NSWindow {
        let tc = SettingsTabViewController()
        tc.tabStyle = .toolbar
        tc.transitionOptions = []
        tc.canPropagateSelectedChildViewControllerTitle = true
        for tab in SettingsTab.allCases {
            let host = NSHostingController(rootView: SettingsViews.view(for: tab, models: models))
            host.sizingOptions = []
            host.title = tab.title
            host.view.frame = NSRect(origin: .zero, size: tab.contentSize)
            let item = NSTabViewItem(viewController: host)
            item.label = tab.title
            item.identifier = tab.rawValue
            item.image = NSImage(systemSymbolName: tab.symbolName, accessibilityDescription: tab.title)
            tc.addTabViewItem(item)
        }
        tabController = tc

        let first = SettingsTab.allCases[0]
        let w = SettingsWindow(contentRect: NSRect(origin: .zero, size: first.contentSize),
                               styleMask: [.titled, .closable, .miniaturizable],
                               backing: .buffered, defer: true)
        w.contentViewController = tc
        w.setContentSize(first.contentSize)
        w.toolbarStyle = .preference
        w.title = first.title
        w.isReleasedWhenClosed = false
        w.collectionBehavior = [.moveToActiveSpace, .fullScreenNone]
        w.delegate = self
        w.identifier = NSUserInterfaceItemIdentifier("NoteBarSettings")
        tc.onSelect = { [weak w] tab in
            guard let w else { return }
            w.title = tab.title
            Self.resize(w, to: tab.contentSize)
        }
        models.window = w
        return w
    }

    /// Resizes the window content keeping the top-left corner fixed.
    private static func resize(_ window: NSWindow, to contentSize: NSSize) {
        let current = window.contentRect(forFrameRect: window.frame)
        guard current.size != contentSize else { return }
        var frame = window.frameRect(forContentRect: NSRect(origin: current.origin, size: contentSize))
        frame.origin.y = window.frame.maxY - frame.height
        window.setFrame(frame, display: true, animate: window.isVisible)
    }

    public func windowWillClose(_ notification: Notification) {
        models.flush()
        // End any field editing / recording.
        windowStorage?.makeFirstResponder(nil)
    }

    public func windowDidBecomeKey(_ notification: Notification) {
        models.launch.refresh()
        models.backups.refresh()
    }
}

/// Reports tab changes so the window can resize and retitle.
final class SettingsTabViewController: NSTabViewController {
    var onSelect: ((SettingsTab) -> Void)?

    override func tabView(_ tabView: NSTabView, didSelect tabViewItem: NSTabViewItem?) {
        super.tabView(tabView, didSelect: tabViewItem)
        if let id = tabViewItem?.identifier as? String, let tab = SettingsTab(rawValue: id) { onSelect?(tab) }
    }
}

/// Handles ⌘W and the standard editing shortcuts. The app is an accessory app and may have no
/// main menu, so text fields would otherwise not get ⌘C / ⌘V / ⌘A / ⌘Z.
final class SettingsWindow: NSWindow {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if super.performKeyEquivalent(with: event) { return true }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            .intersection([.command, .shift, .option, .control])
        guard let key = event.charactersIgnoringModifiers?.lowercased() else { return false }
        let action: Selector?
        switch (key, flags) {
        case ("w", .command): performClose(nil); return true
        case ("x", .command): action = #selector(NSText.cut(_:))
        case ("c", .command): action = #selector(NSText.copy(_:))
        case ("v", .command): action = #selector(NSText.paste(_:))
        case ("a", .command): action = #selector(NSText.selectAll(_:))
        case ("z", .command): action = Selector(("undo:"))
        case ("z", [.command, .shift]): action = Selector(("redo:"))
        default: action = nil
        }
        if let action { return NSApp.sendAction(action, to: nil, from: self) }
        return false
    }

    override func cancelOperation(_ sender: Any?) {
        // Esc with nothing to cancel: keep the window (standard settings behavior).
    }
}
