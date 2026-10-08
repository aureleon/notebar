import AppKit

/// Runs alerts and open / save panels as app-modal dialogs that take keyboard focus.
///
/// The NoteBar panel never activates the app, so another app is usually frontmost. `NSApp.activate()`
/// is cooperative (macOS 14+) and is refused then: the dialog shows, but keystrokes go to the other
/// app. A non-activating dialog becomes key without activation, like the panel, so Return / Esc / Tab
/// and typing reach it. The dialog also sits above the panel and suspends auto-hide while it is open.
@MainActor
public enum ModalSupport {
    public static let suspendAutoHide = Notification.Name("NoteBar.suspendAutoHide")

    public static func suspend(_ active: Bool) {
        NotificationCenter.default.post(name: suspendAutoHide, object: nil, userInfo: ["active": active])
    }

    /// Checks and snapshots set this: dialogs are answered by it and never shown on the screen.
    public static var testResponder: ((String) -> NSApplication.ModalResponse)?

    @discardableResult
    public static func run(_ alert: NSAlert) -> NSApplication.ModalResponse {
        if let testResponder { return testResponder(alert.messageText) }
        suspend(true)
        defer { suspend(false) }
        prepare(alert.window)
        return alert.runModal()
    }

    public static func run(_ panel: NSSavePanel) -> NSApplication.ModalResponse {
        if let testResponder { return testResponder(panel.message ?? "open / save panel") }
        suspend(true)
        defer { suspend(false) }
        prepare(panel)
        return panel.runModal()
    }

    private static func prepare(_ window: NSWindow) {
        if let panel = window as? NSPanel {
            panel.styleMask.insert(.nonactivatingPanel)
            panel.becomesKeyOnlyIfNeeded = false
        }
        NSApp.activate()
        window.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
    }
}
