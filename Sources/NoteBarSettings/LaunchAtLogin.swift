import Foundation
import ServiceManagement

/// Start NoteBar when the user logs in.
///
/// First choice: `SMAppService.mainApp` (a real Login Item). With an ad-hoc signature, or when the
/// binary is not inside an app bundle, `register()` can fail. Then NoteBar writes a LaunchAgent
/// (`~/Library/LaunchAgents/local.dhguz.NoteBar.plist`) that runs the current executable at login.
///
/// Rules that keep exactly one mechanism active:
/// - When the user turned NoteBar off in System Settings › Login Items (`.requiresApproval`), NoteBar
///   does not install the LaunchAgent. The user must approve the login item there.
/// - When the login item is enabled, a LaunchAgent is redundant and is removed.
/// - Automatic repairs only run from the real installed app (bundle id `local.dhguz.NoteBar` in
///   /Applications or ~/Applications), so dev builds and test copies cannot take over the agent.
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
        /// The user turned NoteBar off in System Settings › General › Login Items.
        case needsApproval
        case couldNotEnable(loginItem: Error, launchAgent: Error)
        case couldNotDisable(Error)

        public var errorDescription: String? {
            switch self {
            case .noExecutable:
                return "NoteBar cannot find its own executable."
            case .needsApproval:
                return "NoteBar is turned off in System Settings › General › Login Items. Turn it on there."
            case .couldNotEnable(let a, let b):
                return "NoteBar cannot start at login. Login item: \(a.localizedDescription) Launch agent: \(b.localizedDescription)"
            case .couldNotDisable(let e):
                return "NoteBar cannot remove the login item: \(e.localizedDescription)"
            }
        }
    }

    public static let launchAgentLabel = "local.dhguz.NoteBar"
    /// The bundle identifier of the real app. Copies with another identifier never touch the agent automatically.
    public static let canonicalBundleIdentifier = "local.dhguz.NoteBar"

    public static var launchAgentURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents", isDirectory: true)
            .appendingPathComponent("\(launchAgentLabel).plist")
    }

    /// The real current state (read from the system each time).
    public static var state: State {
        switch SMAppService.mainApp.status {
        case .enabled:
            return .loginItem
        case .requiresApproval:
            // A LaunchAgent from an earlier version still starts NoteBar: report that, it is the truth.
            return isLaunchAgentInstalled ? .launchAgent : .requiresApproval
        default:
            return isLaunchAgentInstalled ? .launchAgent : .disabled
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

    // MARK: Maintenance (call at launch)

    /// True when this process is the real installed NoteBar: bundle id `local.dhguz.NoteBar`,
    /// inside /Applications or ~/Applications (also in a subfolder).
    public static var isInstalledCopy: Bool {
        isInstalledCopy(bundleIdentifier: Bundle.main.bundleIdentifier, bundleURL: Bundle.main.bundleURL)
    }

    static func isInstalledCopy(bundleIdentifier: String?, bundleURL: URL) -> Bool {
        guard bundleIdentifier == canonicalBundleIdentifier, bundleURL.pathExtension == "app" else { return false }
        let path = bundleURL.resolvingSymlinksInPath().standardizedFileURL.path
        let roots = ["/Applications",
                     FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications").path]
        return roots.contains { path.hasPrefix($0 + "/") }
    }

    /// Fixes the LaunchAgent at launch:
    /// - removes it when the login item is enabled (else NoteBar would start twice), and
    /// - points it at this executable when the app was moved or reinstalled.
    ///
    /// Only the real app does this: same bundle id, and either installed in an Applications folder or
    /// the old target no longer exists. So build/NoteBar.app or a renamed test copy cannot take over.
    public static func repairLaunchAgentIfNeeded() {
        guard Bundle.main.bundleIdentifier == canonicalBundleIdentifier else { return }
        removeRedundantLaunchAgent()
        guard isLaunchAgentInstalled, Bundle.main.bundleURL.pathExtension == "app",
              let exe = Bundle.main.executablePath else { return }
        let target = launchAgentProgram()
        guard target != exe else { return }
        let targetGone = target.map { !FileManager.default.isExecutableFile(atPath: $0) } ?? true
        guard isInstalledCopy || targetGone else { return }
        try? installLaunchAgent()
    }

    /// Removes the LaunchAgent when the login item is enabled: both would start NoteBar at login.
    /// Only acts in the real app (bundle id `local.dhguz.NoteBar`).
    public static func removeRedundantLaunchAgent() {
        guard Bundle.main.bundleIdentifier == canonicalBundleIdentifier, isLaunchAgentInstalled,
              SMAppService.mainApp.status == .enabled else { return }
        removeLaunchAgent()
    }

    /// The executable the installed LaunchAgent runs, or nil.
    public static func launchAgentProgram() -> String? {
        guard let data = try? Data(contentsOf: launchAgentURL),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let args = plist["ProgramArguments"] as? [String] else { return nil }
        return args.first
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

    /// True when `register()` failed only because the user turned the login item off in
    /// System Settings. The user must approve it there; a LaunchAgent would bypass that choice.
    static func needsApproval(after error: Error, status: SMAppService.Status) -> Bool {
        if status == .requiresApproval { return true }
        let ns = error as NSError
        guard ns.domain != NSCocoaErrorDomain, ns.domain != NSPOSIXErrorDomain else { return false }
        return ns.code == Int(kSMErrorLaunchDeniedByUser)
    }

    private static func enable() throws {
        let service = SMAppService.mainApp
        if service.status == .enabled { removeLaunchAgent(); return }
        do {
            try service.register()
            // Do not start twice at login. (If the item still needs approval, keep a working agent.)
            if service.status == .enabled { removeLaunchAgent() }
        } catch let loginItemError {
            // Turned off in System Settings › Login Items: the UI shows "Open Login Items Settings…".
            if needsApproval(after: loginItemError, status: service.status) {
                // `.requiresApproval` explains itself through `state`; otherwise tell the caller.
                if service.status == .requiresApproval { return }
                throw Failure.needsApproval
            }
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
