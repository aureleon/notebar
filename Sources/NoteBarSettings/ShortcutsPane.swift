import SwiftUI
import NoteBarCore

/// Finds problems with the global shortcuts: duplicates and clashes with system shortcuts.
enum HotkeyConflicts {
    private static let space: UInt32 = 0x31
    private static let cmd = KeyCombo.cmd, shift = KeyCombo.shift, opt = KeyCombo.option, ctrl = KeyCombo.control

    /// Well-known system shortcuts that a global hotkey would break.
    static let system: [KeyCombo: String] = [
        KeyCombo(keyCode: space, carbonModifiers: cmd): "Spotlight",
        KeyCombo(keyCode: space, carbonModifiers: cmd | opt): "Finder search",
        KeyCombo(keyCode: space, carbonModifiers: ctrl): "the input source switch",
        KeyCombo(keyCode: space, carbonModifiers: ctrl | cmd): "the Character Viewer",
        KeyCombo(keyCode: 0x30, carbonModifiers: cmd): "the app switcher",
        KeyCombo(keyCode: 0x14, carbonModifiers: cmd | shift): "screenshots",
        KeyCombo(keyCode: 0x15, carbonModifiers: cmd | shift): "screenshots",
        KeyCombo(keyCode: 0x17, carbonModifiers: cmd | shift): "screenshots",
        KeyCombo(keyCode: 0x0C, carbonModifiers: ctrl | cmd): "Lock Screen",
        KeyCombo(keyCode: 0x35, carbonModifiers: cmd | opt): "Force Quit",
        KeyCombo(keyCode: 0x7E, carbonModifiers: ctrl): "Mission Control",
        KeyCombo(keyCode: 0x7D, carbonModifiers: ctrl): "App Exposé",
        KeyCombo(keyCode: 0x7B, carbonModifiers: ctrl): "switching Spaces",
        KeyCombo(keyCode: 0x7C, carbonModifiers: ctrl): "switching Spaces",
        KeyCombo(keyCode: 0x02, carbonModifiers: cmd | opt): "showing and hiding the Dock",
    ]

    /// A warning for one action, or nil. `failed`: actions that macOS refused to register.
    static func warning(for action: HotkeyAction, in hotkeys: [HotkeyAction: KeyCombo],
                        failed: Set<HotkeyAction> = []) -> String? {
        guard let combo = hotkeys[action] else { return nil }
        let others = HotkeyAction.allCases.filter { $0 != action && hotkeys[$0] == combo }
        if let other = others.first {
            return "\(combo.displayString) is also used for “\(other.displayName)”. Only one of them works."
        }
        if let problem = ShortcutRecorderView.problem(with: combo) {
            return problem.message(for: combo)
        }
        if failed.contains(action) {
            if let name = system[combo] {
                return "Could not register \(combo.displayString): it is the system shortcut for \(name)."
            }
            return "Could not register \(combo.displayString): another app uses it. Record a different shortcut."
        }
        if let name = system[combo] {
            return "\(combo.displayString) is the system shortcut for \(name)."
        }
        let m = combo.carbonModifiers
        if m == cmd || m == cmd | shift {
            return "\(combo.displayString) overrides the same shortcut in every app. Add ⌃ or ⌥ to avoid this."
        }
        return nil
    }
}

struct ShortcutsPane: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var registration: HotkeyRegistrationStatus
    private static let panelShortcuts: [(String, String)] = [
        ("Move to Folder…", "⇧⌘M"),
        ("Move to a New Folder", "⌥⌘M"),
        ("Move Note Up", "⌥⇧⌘↑"),
        ("Move Note Down", "⌥⇧⌘↓"),
        ("Stop Editing", "Esc"),
    ]

    var body: some View {
        let hotkeys = settings.hotkeys
        let failed = registration.failed
        Form {
            Section {
                ForEach(HotkeyAction.allCases, id: \.self) { action in
                    let warning = HotkeyConflicts.warning(for: action, in: hotkeys, failed: failed)
                    LabeledContent {
                        HStack(spacing: 8) {
                            if warning != nil {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundStyle(.yellow)
                                    .help(warning ?? "")
                            }
                            ShortcutRecorder(combo: hotkeys[action]) { newValue in
                                settings.hotkeys[action] = newValue
                            }
                            .frame(width: 160, height: 24)
                        }
                        // The NSView has no text baseline; align the field with the label's first line.
                        .alignmentGuide(.firstTextBaseline) { d in d[VerticalAlignment.center] + 4 }
                    } label: {
                        Text(action.displayName)
                        if let warning { Text(warning).foregroundStyle(.orange) }
                    }
                }
            } header: {
                Text("Global Shortcuts")
            } footer: {
                FootnoteText("These work in every app, also when the panel is hidden. Click a field and type the new shortcut. "
                             + "A shortcut needs ⌘ or ⌃ and can add ⌥ and ⇧. Press Esc to cancel and Delete to remove a shortcut.")
            }

            Section {
                HStack {
                    Spacer()
                    Button("Restore Defaults") { settings.hotkeys = HotkeyAction.defaults }
                        .disabled(hotkeys == HotkeyAction.defaults)
                }
            }

            Section("In the Panel") {
                ForEach(Self.panelShortcuts, id: \.0) { item in
                    LabeledContent(item.0) {
                        Text(item.1).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}
