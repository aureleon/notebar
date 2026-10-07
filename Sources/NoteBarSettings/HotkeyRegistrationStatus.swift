import Foundation
import NoteBarCore

extension Notification.Name {
    /// Posted by the panel's HotkeyCenter after every registration pass, with
    /// userInfo["failed": [String] (HotkeyAction raw values), "suspended": Bool].
    /// (Internal so it cannot clash with a same-named constant in another module.)
    static let noteBarHotkeyRegistrationDidChange = Notification.Name("NoteBar.hotkeyRegistrationDidChange")
}

/// Which global shortcuts macOS refused to register (taken by another app, or a combo that
/// `RegisterEventHotKey` rejects). Fed by `NoteBar.hotkeyRegistrationDidChange`.
///
/// One process-wide instance (`shared`) so that it can start observing before the HotkeyCenter
/// makes its first registration pass. If it has not seen a pass yet when Settings opens,
/// `refreshIfNeeded()` asks the HotkeyCenter for a new pass (a short suspend / resume).
@MainActor
public final class HotkeyRegistrationStatus: ObservableObject {
    public static let shared = HotkeyRegistrationStatus()

    /// Actions whose shortcut could not be registered in the last (not suspended) pass.
    @Published public private(set) var failed: Set<HotkeyAction> = []
    /// True after the first not-suspended registration pass was received.
    public private(set) var hasReport = false

    private var observer: NSObjectProtocol?

    public init(observing: Bool = true) {
        if observing { startObserving() }
    }

    /// Starts listening (idempotent). `shared` already listens; call `_ = HotkeyRegistrationStatus.shared`
    /// before creating the HotkeyCenter to also catch its first pass.
    public func startObserving() {
        guard observer == nil else { return }
        observer = NotificationCenter.default.addObserver(forName: .noteBarHotkeyRegistrationDidChange,
                                                          object: nil, queue: .main) { [weak self] n in
            let suspended = (n.userInfo?["suspended"] as? Bool) ?? false
            let raw = (n.userInfo?["failed"] as? [String]) ?? []
            MainActor.assumeIsolated {
                // While the recorder is active every hotkey is unregistered on purpose: keep the last real result.
                guard let self, !suspended else { return }
                self.update(failed: Set(raw.compactMap(HotkeyAction.init(rawValue:))))
            }
        }
    }

    /// Sets the result directly (e.g. `status.update(failed: hotkeyCenter.failedActions)`).
    public func update(failed newValue: Set<HotkeyAction>) {
        hasReport = true
        if newValue != failed { failed = newValue }
    }

    /// If no registration pass was seen yet, makes the HotkeyCenter run one now. It uses the
    /// recorder protocol (`NoteBar.hotkeyRecording` active true, then false), which re-registers
    /// every hotkey and posts the result.
    public func refreshIfNeeded() {
        guard !hasReport else { return }
        let nc = NotificationCenter.default
        nc.post(name: .noteBarHotkeyRecording, object: self, userInfo: ["active": true])
        nc.post(name: .noteBarHotkeyRecording, object: self, userInfo: ["active": false])
    }

    public func isFailed(_ action: HotkeyAction) -> Bool { failed.contains(action) }
}
