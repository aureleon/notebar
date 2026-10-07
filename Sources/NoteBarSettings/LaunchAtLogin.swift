import Foundation
import ServiceManagement

/// Start NoteBar when the user logs in.
///
/// First choice: `SMAppService.mainApp` (a real Login Item). With an ad-hoc signature, or when the
/// binary is not inside an app bundle, `register()` can fail. Then NoteBar writes a LaunchAgent
/// (`~/Library/LaunchAgents/local.dhguz.NoteBar.plist`) that runs the current executable at login.
public enum LaunchAtLogin {
    public enum State: Equatable, Sendable {
        /// Nothing starts NoteBar at login.
        case disabled
        /// Registered with `SMAppService.mainApp` and approved.
        case loginItem
        /// Registered with `SMAppService.mainApp`, but the user must approve it in
        /// System Settings › General › Login Items.
        case requiresApproval
        /// The LaunchAgent fallback plist is installed.
        case launchAgent
    }

    public enum Failure: LocalizedError {
        case noExecutable
        case couldNotEnable(loginItem: Error, launchAgent: Error)
        case couldNotDisable(Error)

        public var errorDescription: String? {
            switch self {
            case .noExecutable:
                return "NoteBar cannot find its own executable."
            case .couldNotEnable(let a, let b):
                return "NoteBar cannot start at login. Login item: \(a.localizedDescription) Launch agent: \(b.localizedDescription)"
            case .couldNotDisable(let e):
                return "NoteBar cannot remove the login item: \(e.localizedDescription)"
            }
        }
    }

    public static let launchAgentLabel = "local.dhguz.NoteBar"

    public static var launchAgentURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents", isDirectory: true)
            .appendingPathComponent("\(launchAgentLabel).plist")
    }

    /// The real current state (read from the system each time).
    public static var state: State {
        switch SMAppService.mainApp.status {
        case .enabled: return .loginItem
        case .requiresApproval: return .requiresApproval
        default: return isLaunchAgentInstalled ? .launchAgent : .disabled
        }
    }

    /// True when NoteBar will start at the next login (an unapproved login item does not count).
    public static var isEnabled: Bool {
        switch state {
        case .loginItem, .launchAgent: return true
        case .disabled, .requiresApproval: return false
        }
    }

    public static var isLaunchAgentInstalled: Bool {
        FileManager.default.fileExists(atPath: launchAgentURL.path)
    }

    public static func setEnabled(_ enabled: Bool) throws {
        if enabled { try enable() } else { try disable() }
    }

    /// Opens System Settings › General › Login Items.
    public static func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    /// If the LaunchAgent points to a different executable (the app was moved or rebuilt to a
    /// new place), rewrite it. Only runs from a real `.app` bundle so dev builds do not take over.
    public static func repairLaunchAgentIfNeeded() {
        guard isLaunchAgentInstalled, Bundle.main.bundleURL.pathExtension == "app",
              let exe = Bundle.main.executablePath else { return }
        guard let data = try? Data(contentsOf: launchAgentURL),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let args = plist["ProgramArguments"] as? [String] else { return }
        if args.first != exe { try? installLaunchAgent() }
    }

    /// The LaunchAgent plist for `executablePath` (XML property list).
    public static func makeLaunchAgentPlist(executablePath: String, bundleIdentifier: String?) throws -> Data {
        var dict: [String: Any] = [
            "Label": launchAgentLabel,
            "ProgramArguments": [executablePath],
            "RunAtLoad": true,
            "KeepAlive": false,
            "ProcessType": "Interactive",
            "LimitLoadToSessionType": "Aqua",
        ]
        if let bundleIdentifier { dict["AssociatedBundleIdentifiers"] = [bundleIdentifier] }
        return try PropertyListSerialization.data(fromPropertyList: dict, format: .xml, options: 0)
    }

    // MARK: Private

    private static func enable() throws {
        let service = SMAppService.mainApp
        if service.status == .enabled { removeLaunchAgent(); return }
        do {
            try service.register()
            // Do not start twice at login.
            removeLaunchAgent()
        } catch let loginItemError {
            do {
                try installLaunchAgent()
            } catch let agentError {
                throw Failure.couldNotEnable(loginItem: loginItemError, launchAgent: agentError)
            }
        }
    }

    private static func disable() throws {
        var failure: Error?
        let service = SMAppService.mainApp
        if service.status == .enabled || service.status == .requiresApproval {
            do { try service.unregister() } catch { failure = error }
        }
        if isLaunchAgentInstalled {
            do { try FileManager.default.removeItem(at: launchAgentURL) } catch { failure = error }
        }
        if let failure, state != .disabled { throw Failure.couldNotDisable(failure) }
    }

    private static func installLaunchAgent() throws {
        guard let exe = Bundle.main.executablePath else { throw Failure.noExecutable }
        let data = try makeLaunchAgentPlist(executablePath: exe, bundleIdentifier: Bundle.main.bundleIdentifier)
        try FileManager.default.createDirectory(at: launchAgentURL.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try data.write(to: launchAgentURL, options: .atomic)
    }

    private static func removeLaunchAgent() {
        if isLaunchAgentInstalled { try? FileManager.default.removeItem(at: launchAgentURL) }
    }
}
