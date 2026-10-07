import AppKit
import SwiftUI
import NoteBarCore

/// Shared state for all settings panes. One instance per settings window (or per snapshot run).
@MainActor
public final class SettingsModels {
    public let env: AppEnvironment
    /// Sheets (alerts, open panels) attach to this window when it is visible.
    public weak var window: NSWindow?

    let launch = LaunchAtLoginModel()
    let themes: ThemesModel
    /// Which global shortcuts macOS refused to register (shown in the Shortcuts pane).
    public let hotkeyStatus: HotkeyRegistrationStatus
    lazy var backups = BackupsModel(models: self)
    lazy var about = AboutModel(store: env.store)

    public convenience init(env: AppEnvironment) {
        self.init(env: env, hotkeyStatus: .shared)
    }

    public init(env: AppEnvironment, hotkeyStatus: HotkeyRegistrationStatus) {
        self.env = env
        self.themes = ThemesModel(env: env)
        self.hotkeyStatus = hotkeyStatus
    }

    /// Re-reads values that can change outside the settings window (login item, backups, themes).
    public func refresh() {
        launch.refresh()
        themes.reload()
        backups.refresh()
        about.refresh()
        hotkeyStatus.refreshIfNeeded()
    }

    /// Writes pending edits (the theme editor debounces saves).
    public func flush() {
        themes.saveNow()
    }

    // MARK: Alerts

    func present(_ alert: NSAlert, completion: ((NSApplication.ModalResponse) -> Void)? = nil) {
        if let window, window.isVisible {
            alert.beginSheetModal(for: window) { completion?($0) }
        } else {
            let r = alert.runModal()
            completion?(r)
        }
    }

    func showError(_ error: Error, title: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = error.localizedDescription
        present(alert)
    }

    func showInfo(_ title: String, _ message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        present(alert)
    }

    /// Asks a yes/no question. `onConfirm` runs only when the user picks `confirmTitle`.
    func confirm(_ title: String, message: String, confirmTitle: String, destructive: Bool,
                 onConfirm: @escaping () -> Void) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        let ok = alert.addButton(withTitle: confirmTitle)
        ok.hasDestructiveAction = destructive
        alert.addButton(withTitle: "Cancel")
        present(alert) { if $0 == .alertFirstButtonReturn { onConfirm() } }
    }
}

/// Launch-at-login toggle state. Always reflects the real system status after each change.
@MainActor
final class LaunchAtLoginModel: ObservableObject {
    @Published private(set) var state: LaunchAtLogin.State = .disabled
    @Published private(set) var lastError: String?
    /// The last enable attempt was refused because the user turned NoteBar off in Login Items.
    @Published private(set) var deniedByUser = false

    init() { refresh() }

    var isOn: Bool { state != .disabled }

    /// Show the "Open Login Items Settings…" button.
    var showsLoginItemsButton: Bool { state == .requiresApproval || deniedByUser }

    func refresh() {
        LaunchAtLogin.removeRedundantLaunchAgent()
        state = LaunchAtLogin.state
        if state != .disabled, deniedByUser { deniedByUser = false; lastError = nil }
    }

    func set(_ on: Bool) {
        do {
            try LaunchAtLogin.setEnabled(on)
            lastError = nil
            deniedByUser = false
        } catch LaunchAtLogin.Failure.needsApproval {
            lastError = LaunchAtLogin.Failure.needsApproval.errorDescription
            deniedByUser = true
        } catch {
            lastError = error.localizedDescription
            deniedByUser = false
        }
        refresh()
    }

    var statusText: String? {
        if let lastError { return lastError }
        switch state {
        case .disabled, .loginItem: return nil
        case .requiresApproval:
            return "Allow NoteBar in System Settings › General › Login Items. Until then it does not start at login."
        case .launchAgent:
            return "Uses a launch agent: \(SettingsFormat.abbreviatedPath(LaunchAtLogin.launchAgentURL))"
        }
    }
}
