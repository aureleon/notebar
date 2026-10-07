import AppKit
import NoteBarCore

/// Entry point of the integrations module: `notebar://` URL scheme, Services menu, AppleScript.
///
/// Wiring (AppDelegate):
///
///     func applicationWillFinishLaunching(_ n: Notification) {
///         ...create env, env.controller = self...
///         integrations = IntegrationsController(env: env)
///         integrations.install()
///     }
///
/// Requests that arrive before `applicationDidFinishLaunching` has returned (e.g. the URL that
/// launched the app) are queued and run once launching is done, so `env.controller` can rely on
/// its panel / notes UI being set up.
///
/// The app delegate must NOT implement `application(_:open:)`: that would compete with the
/// kAEGetURL handler installed here.
@MainActor
public final class IntegrationsController {
    public let env: AppEnvironment
    /// The shared action layer (also usable directly, e.g. from menus or tests).
    public let actions: IntegrationActions
    private let urlHandler: URLSchemeHandler
    private let servicesProvider: ServicesProvider
    private var launchObserver: NSObjectProtocol?
    private var installed = false

    public init(env: AppEnvironment) {
        self.env = env
        actions = IntegrationActions(env: env)
        urlHandler = URLSchemeHandler(actions: actions)
        servicesProvider = ServicesProvider(actions: actions)
    }

    /// Call from applicationWillFinishLaunching (URL Apple Event handler must be installed early).
    public func install() {
        guard !installed else { return }
        installed = true
        IntegrationActions.current = actions

        // URL scheme.
        urlHandler.install()

        // AppleScript: Cocoa Scripting loads Resources/NoteBar.sdef itself (OSAScriptingDefinition +
        // NSAppleScriptEnabled in Info.plist) and instantiates the command classes by name.
        _ = ScriptCommandClasses.all

        // Services menu.
        NSApplication.shared.servicesProvider = servicesProvider
        NSUpdateDynamicServices()

        // Readiness: run queued requests right after applicationDidFinishLaunching returns.
        if NSRunningApplication.current.isFinishedLaunching {
            DispatchQueue.main.async { [actions] in actions.markReady() }
        } else {
            launchObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.didFinishLaunchingNotification, object: nil, queue: .main
            ) { [weak self] _ in
                // Async: the delegate's applicationDidFinishLaunching may run after this observer.
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        guard let self else { return }
                        if let o = self.launchObserver { NotificationCenter.default.removeObserver(o) }
                        self.launchObserver = nil
                        self.actions.markReady()
                    }
                }
            }
        }
    }

    /// Runs a `notebar://` URL string as if it came from another app (e.g. from a menu or tests).
    public func handleURL(_ string: String) {
        urlHandler.handle(string)
    }

    /// Removes the URL handler and services provider (not needed in normal use).
    public func uninstall() {
        guard installed else { return }
        installed = false
        urlHandler.uninstall()
        if (NSApplication.shared.servicesProvider as AnyObject?) === servicesProvider { NSApplication.shared.servicesProvider = nil }
        if let o = launchObserver { NotificationCenter.default.removeObserver(o) }
        launchObserver = nil
        if IntegrationActions.current === actions { IntegrationActions.current = nil }
    }
}
