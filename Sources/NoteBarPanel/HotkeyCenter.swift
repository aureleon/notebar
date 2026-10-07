import AppKit
import Carbon.HIToolbox
import NoteBarCore

/// Global hotkeys through Carbon `RegisterEventHotKey` (no Accessibility permission needed).
///
/// - Registers one hotkey per entry in `settings.hotkeys` and calls `onAction` when one is pressed,
///   also while NoteBar is in the background and the panel is hidden.
/// - Re-registers when the "hotkeys" setting changes.
/// - Suspends every hotkey while the Settings shortcut recorder is active: it posts
///   `Notification.Name("NoteBar.hotkeyRecording")` with userInfo["active"] = true / false.
/// - Combos that cannot be registered (taken by the system or another app, a duplicate within NoteBar,
///   or Option-only combos that macOS 15+ rejects) end up in `failedActions`, and
///   `NoteBarPanelNotification.hotkeyRegistrationDidChange` is posted after every registration pass.
@MainActor
public final class HotkeyCenter {
    public var onAction: ((HotkeyAction) -> Void)?
    /// Actions whose shortcut could not be registered in the last registration pass.
    public private(set) var failedActions: Set<HotkeyAction> = []
    /// True while hotkeys are suspended (shortcut recorder active).
    public private(set) var isSuspended = false
    /// The combos that are currently registered.
    public var registeredCombos: [HotkeyAction: KeyCombo] { registrations.mapValues(\.combo) }

    private let settings: AppSettings
    private var registrations: [HotkeyAction: (ref: EventHotKeyRef, combo: KeyCombo)] = [:]
    private var handlerRef: EventHandlerRef?
    private var observers: [NSObjectProtocol] = []

    /// 'NBar' — signature in EventHotKeyID so we only react to our own hotkeys.
    private static let signature: OSType = 0x4E42_6172

    public init(settings: AppSettings) {
        self.settings = settings
        installHandler()
        let nc = NotificationCenter.default
        observers.append(nc.addObserver(forName: .appSettingsDidChange, object: nil, queue: .main) { [weak self] n in
            let key = n.userInfo?["key"] as? String
            guard key == nil || key == "hotkeys" else { return }
            MainActor.assumeIsolated { self?.reload() }
        })
        observers.append(nc.addObserver(forName: NoteBarPanelNotification.hotkeyRecording, object: nil, queue: .main) { [weak self] n in
            let active = (n.userInfo?["active"] as? Bool) ?? false
            MainActor.assumeIsolated { self?.setRecording(active) }
        })
        reload()
    }

    // MARK: Public

    /// Unregisters and registers all hotkeys from the current settings.
    public func reload() {
        unregisterAll()
        guard !isSuspended else { publish(); return }
        var failed: Set<HotkeyAction> = []
        var used: Set<KeyCombo> = []
        // Stable order so a duplicate combo always fails for the same (later) action.
        for action in HotkeyAction.allCases {
            guard let combo = settings.hotkeys[action] else { continue }
            if used.contains(combo) { failed.insert(action); continue }
            if let ref = register(combo, id: Self.id(for: action)) {
                registrations[action] = (ref, combo)
                used.insert(combo)
            } else {
                failed.insert(action)
            }
        }
        failedActions = failed
        publish()
    }

    /// Suspends (true) or resumes (false) all hotkeys. Not counted: the last notification wins, so an
    /// unbalanced `true` from a recorder can never leave the hotkeys off after it posts `false`.
    public func setRecording(_ active: Bool) {
        guard active != isSuspended else { return }
        isSuspended = active
        reload()
    }

    /// True if `combo` could be registered right now (not taken by the system or another app).
    /// Combos NoteBar itself holds count as available. Useful for a shortcut recorder.
    public func isAvailable(_ combo: KeyCombo) -> Bool {
        if registrations.values.contains(where: { $0.combo == combo }) { return true }
        guard let ref = register(combo, id: 999) else { return false }
        UnregisterEventHotKey(ref)
        return true
    }

    // MARK: Carbon

    private func register(_ combo: KeyCombo, id: UInt32) -> EventHotKeyRef? {
        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: Self.signature, id: id)
        let status = RegisterEventHotKey(combo.keyCode, combo.carbonModifiers, hotKeyID,
                                         GetApplicationEventTarget(), 0, &ref)
        guard status == noErr, let ref else {
            NSLog("NoteBar: could not register hotkey %@ (OSStatus %d)", combo.displayString, status)
            return nil
        }
        return ref
    }

    private func unregisterAll() {
        for (_, r) in registrations { UnregisterEventHotKey(r.ref) }
        registrations.removeAll()
    }

    private func installHandler() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let me = Unmanaged.passUnretained(self).toOpaque()
        let status = InstallEventHandler(GetApplicationEventTarget(), { _, event, userData in
            guard let event, let userData else { return OSStatus(eventNotHandledErr) }
            var hk = EventHotKeyID()
            let err = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                        nil, MemoryLayout<EventHotKeyID>.size, nil, &hk)
            guard err == noErr, hk.signature == HotkeyCenter.signature else { return OSStatus(eventNotHandledErr) }
            let id = hk.id
            let center = Unmanaged<HotkeyCenter>.fromOpaque(userData).takeUnretainedValue()
            // Carbon calls on the main thread; hop explicitly so the handler can return immediately.
            DispatchQueue.main.async { MainActor.assumeIsolated { center.fire(id: id) } }
            return noErr
        }, 1, &spec, me, &handlerRef)
        if status != noErr { NSLog("NoteBar: InstallEventHandler failed (OSStatus %d)", status) }
    }

    private func fire(id: UInt32) {
        guard !isSuspended, let action = Self.action(for: id), registrations[action] != nil else { return }
        onAction?(action)
    }

    private func publish() {
        NotificationCenter.default.post(name: NoteBarPanelNotification.hotkeyRegistrationDidChange, object: self,
                                        userInfo: ["failed": failedActions.map(\.rawValue).sorted(),
                                                   "suspended": isSuspended])
    }

    private static func id(for action: HotkeyAction) -> UInt32 {
        UInt32(HotkeyAction.allCases.firstIndex(of: action)! + 1)
    }

    private static func action(for id: UInt32) -> HotkeyAction? {
        let i = Int(id) - 1
        return HotkeyAction.allCases.indices.contains(i) ? HotkeyAction.allCases[i] : nil
    }

    isolated deinit {
        unregisterAll()
        if let handlerRef { RemoveEventHandler(handlerRef) }
        for o in observers { NotificationCenter.default.removeObserver(o) }
    }
}
