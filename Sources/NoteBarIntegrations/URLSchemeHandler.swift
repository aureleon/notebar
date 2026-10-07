import AppKit
import NoteBarCore

/// Receives `kAEGetURL` Apple Events (`notebar://…`) and runs them through `IntegrationActions`.
@MainActor
final class URLSchemeHandler: NSObject {
    private let actions: IntegrationActions

    init(actions: IntegrationActions) {
        self.actions = actions
        super.init()
    }

    static let eventClass = AEEventClass(kInternetEventClass)  // 'GURL'
    static let eventID = AEEventID(kAEGetURL)                   // 'GURL'

    func install() {
        NSAppleEventManager.shared().setEventHandler(self, andSelector: #selector(handleGetURL(_:withReplyEvent:)),
                                                     forEventClass: Self.eventClass, andEventID: Self.eventID)
    }

    func uninstall() {
        NSAppleEventManager.shared().removeEventHandler(forEventClass: Self.eventClass, andEventID: Self.eventID)
    }

    @objc func handleGetURL(_ event: NSAppleEventDescriptor, withReplyEvent reply: NSAppleEventDescriptor) {
        guard let raw = event.paramDescriptor(forKeyword: AEKeyword(keyDirectObject))?.stringValue else {
            integrationsLog.error("GetURL event without a URL string")
            return
        }
        handle(raw)
    }

    /// Parses and runs a URL string (queued until the app has finished launching).
    func handle(_ raw: String) {
        integrationsLog.info("URL: \(raw, privacy: .private)")
        switch NoteBarURLParser.parse(raw) {
        case .failure(let error):
            integrationsLog.error("Bad URL \(raw, privacy: .private): \(error.description, privacy: .public)")
            NSSound.beep()
        case .success(let parsed):
            actions.whenReady { [actions] in
                do {
                    let reply = try actions.perform(parsed.command)
                    Self.callback(parsed.successURL, reply)
                } catch {
                    let message = (error as? IntegrationError)?.message ?? error.localizedDescription
                    let code = (error as? IntegrationError)?.code ?? -2700
                    integrationsLog.error("URL failed: \(message, privacy: .public)")
                    if parsed.errorURL == nil { NSSound.beep() }
                    Self.callback(parsed.errorURL, [("errorCode", String(code)), ("errorMessage", message)])
                }
            }
        }
    }

    /// x-callback-url reply (`x-success` gets `id`/`folder`, `x-error` gets `errorCode`/`errorMessage`).
    private static func callback(_ base: String?, _ items: [(String, String)]) {
        guard let base, !base.isEmpty else { return }
        let s = NoteBarURLParser.appendingQuery(base, items)
        guard let url = URL(string: s), let scheme = url.scheme?.lowercased(), scheme != NoteBarURLParser.scheme else {
            integrationsLog.error("Invalid x-callback URL \(s, privacy: .private)")
            return
        }
        // x-callback-url convention: the reply brings the calling app back to the front.
        NSWorkspace.shared.open(url, configuration: NSWorkspace.OpenConfiguration(), completionHandler: nil)
    }
}
