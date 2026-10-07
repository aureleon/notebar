import AppKit
import NoteBarCore

/// NSMenuItem that runs a closure. Keeps menu code free of @objc target boilerplate.
final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(_ title: String, keyEquivalent: String = "", modifiers: NSEvent.ModifierFlags = [.command],
         state: NSControl.StateValue = .off, enabled: Bool = true, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: keyEquivalent)
        target = self
        keyEquivalentModifierMask = modifiers
        self.state = state
        isEnabled = enabled
    }

    required init(coder: NSCoder) { fatalError("not supported") }

    @objc private func run() { handler() }
}

extension NSMenuItem {
    /// Shows a global hotkey as the key equivalent of a menu item (display only; the hotkey itself is
    /// handled by `HotkeyCenter`). Keys without a single-character name (Space, arrows...) are skipped.
    func nbShowHotkey(_ combo: KeyCombo?) {
        guard let combo, let key = combo.menuKeyEquivalent else { return }
        keyEquivalent = key
        keyEquivalentModifierMask = combo.modifierFlags
    }
}
