import AppKit
import SwiftUI
import NoteBarCore

extension Notification.Name {
    /// Posted with userInfo["active": Bool] when a shortcut recorder starts / stops recording.
    /// The panel's HotkeyCenter suspends the global hotkeys while `active == true`.
    /// (Internal so it cannot clash with a same-named constant in another module.)
    static let noteBarHotkeyRecording = Notification.Name("NoteBar.hotkeyRecording")
}

/// A click-to-record shortcut field.
///
/// - Click (or Space / Return when focused) starts recording; the field shows "Type shortcut…".
/// - A key with at least one of ⌘ ⌃ ⌥ sets the shortcut. ⇧ alone is not enough.
/// - Esc cancels. ⌫ / ⌦ clears the shortcut. The ⓧ button clears it too.
public final class ShortcutRecorderView: NSView {
    public var combo: KeyCombo? {
        didSet { if oldValue != combo { needsDisplay = true; updateAccessibility() } }
    }
    /// Called when the user records or clears a shortcut.
    public var onChange: ((KeyCombo?) -> Void)?
    public private(set) var isRecording = false
    /// Beep when a key without ⌘ ⌃ ⌥ is pressed while recording (off in automated checks).
    public static var beepsOnInvalidKey = true

    private var liveModifiers: NSEvent.ModifierFlags = []
    private var hint: String?
    private var resignObserver: NSObjectProtocol?

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        updateAccessibility()
    }

    public convenience init() { self.init(frame: NSRect(x: 0, y: 0, width: 160, height: 24)) }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    // MARK: Layout / focus

    public override var intrinsicContentSize: NSSize { NSSize(width: 160, height: 24) }
    public override var acceptsFirstResponder: Bool { true }
    public override var canBecomeKeyView: Bool { true }
    public override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    public override var focusRingMaskBounds: NSRect { bounds }
    public override func drawFocusRingMask() { capsulePath().fill() }

    private func capsulePath() -> NSBezierPath {
        let r = bounds.insetBy(dx: 0.5, dy: 0.5)
        return NSBezierPath(roundedRect: r, xRadius: r.height / 2, yRadius: r.height / 2)
    }

    private var showsClearButton: Bool { combo != nil && !isRecording }

    private var clearButtonRect: NSRect {
        let s = bounds.height
        return NSRect(x: bounds.maxX - s - 1, y: bounds.minY, width: s, height: s)
    }

    // MARK: Drawing

    public override func draw(_ dirtyRect: NSRect) {
        let path = capsulePath()
        let accent = NSColor.controlAccentColor
        if isRecording {
            accent.withAlphaComponent(0.14).setFill()
        } else {
            NSColor.quaternarySystemFill.setFill()
        }
        path.fill()
        path.lineWidth = isRecording ? 1.5 : 1
        (isRecording ? accent : NSColor.separatorColor).setStroke()
        path.stroke()

        let text: String
        let color: NSColor
        var weight: NSFont.Weight = .regular
        if isRecording {
            let mods = Self.modifierString(liveModifiers)
            text = hint ?? (mods.isEmpty ? "Type shortcut…" : mods + "…")
            color = hint != nil ? .systemOrange : .secondaryLabelColor
        } else if let combo {
            text = combo.displayString
            color = .labelColor
            weight = .medium
        } else {
            text = "Record Shortcut"
            color = .tertiaryLabelColor
        }
        let font = NSFont.systemFont(ofSize: 12.5, weight: weight)
        let para = NSMutableParagraphStyle()
        para.alignment = .center
        para.lineBreakMode = .byTruncatingTail
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color, .paragraphStyle: para]
        let side = showsClearButton ? clearButtonRect.width : 8
        let textHeight = ceil(font.ascender - font.descender)
        let textRect = NSRect(x: bounds.minX + side, y: bounds.midY - textHeight / 2 - 0.5,
                              width: max(0, bounds.width - side * 2), height: textHeight)
        (text as NSString).draw(with: textRect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], attributes: attrs)

        if showsClearButton {
            let config = NSImage.SymbolConfiguration(pointSize: 12, weight: .regular)
                .applying(.init(paletteColors: [.tertiaryLabelColor]))
            if let img = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "Clear")?
                .withSymbolConfiguration(config) {
                let s = img.size
                let r = clearButtonRect
                img.draw(in: NSRect(x: r.midX - s.width / 2, y: r.midY - s.height / 2, width: s.width, height: s.height))
            }
        }
    }

    static func modifierString(_ f: NSEvent.ModifierFlags) -> String {
        var s = ""
        if f.contains(.control) { s += "⌃" }
        if f.contains(.option) { s += "⌥" }
        if f.contains(.shift) { s += "⇧" }
        if f.contains(.command) { s += "⌘" }
        return s
    }

    // MARK: Recording state

    public func startRecording() {
        guard !isRecording else { return }
        if window?.firstResponder !== self { window?.makeFirstResponder(self) }
        isRecording = true
        liveModifiers = []
        hint = nil
        needsDisplay = true
        updateAccessibility()
        NotificationCenter.default.post(name: .noteBarHotkeyRecording, object: self, userInfo: ["active": true])
    }

    public func stopRecording() {
        guard isRecording else { return }
        isRecording = false
        liveModifiers = []
        hint = nil
        needsDisplay = true
        updateAccessibility()
        NotificationCenter.default.post(name: .noteBarHotkeyRecording, object: self, userInfo: ["active": false])
    }

    private func commit(_ newValue: KeyCombo?) {
        combo = newValue
        stopRecording()
        onChange?(newValue)
    }

    // MARK: Events

    public override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if showsClearButton && clearButtonRect.contains(p) {
            combo = nil
            onChange?(nil)
            return
        }
        if isRecording { stopRecording() } else { startRecording() }
    }

    public override func keyDown(with event: NSEvent) {
        if isRecording {
            handleRecording(event)
            return
        }
        let plain = Self.relevantModifiers(event).isEmpty
        let key = Int(event.keyCode)
        if plain, [0x31, 0x24, 0x4C].contains(key) { // Space, Return, Enter
            startRecording()
        } else if plain, [0x33, 0x75].contains(key), combo != nil { // ⌫, ⌦
            combo = nil
            onChange?(nil)
        } else {
            super.keyDown(with: event)
        }
    }

    public override func performKeyEquivalent(with event: NSEvent) -> Bool {
        // ⌘-combos arrive here first, before keyDown. Capture them while recording.
        if isRecording, window?.firstResponder === self {
            handleRecording(event)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    public override func flagsChanged(with event: NSEvent) {
        guard isRecording else { super.flagsChanged(with: event); return }
        liveModifiers = Self.relevantModifiers(event)
        hint = nil
        needsDisplay = true
    }

    static func relevantModifiers(_ event: NSEvent) -> NSEvent.ModifierFlags {
        event.modifierFlags.intersection(.deviceIndependentFlagsMask).intersection([.command, .option, .control, .shift])
    }

    /// Returns what the recorder did with `event` (used by the checks).
    @discardableResult
    func handleRecording(_ event: NSEvent) -> RecordResult {
        guard event.type == .keyDown else { return .ignored }
        let mods = Self.relevantModifiers(event)
        let key = Int(event.keyCode)
        if mods.isEmpty {
            switch key {
            case 0x35: // Esc
                stopRecording()
                return .cancelled
            case 0x33, 0x75: // ⌫, ⌦
                commit(nil)
                return .cleared
            case 0x30: // Tab: leave the field
                stopRecording()
                window?.selectNextKeyView(self)
                return .cancelled
            default:
                break
            }
        }
        guard !mods.intersection([.command, .option, .control]).isEmpty else {
            hint = "Add ⌘, ⌃ or ⌥"
            needsDisplay = true
            if Self.beepsOnInvalidKey { NSSound.beep() }
            return .rejected
        }
        commit(KeyCombo(keyCode: event.keyCode, modifierFlags: mods))
        return .recorded
    }

    enum RecordResult: Equatable { case ignored, cancelled, cleared, rejected, recorded }

    public override func resignFirstResponder() -> Bool {
        stopRecording()
        return super.resignFirstResponder()
    }

    public override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver); self.resignObserver = nil }
        if newWindow == nil { stopRecording() }
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else { return }
        // Switching to another app while recording must not leave the global hotkeys suspended.
        resignObserver = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.stopRecording() }
        }
    }

    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    private func updateAccessibility() {
        setAccessibilityLabel("Shortcut")
        setAccessibilityValue(isRecording ? "Recording" : (combo?.displayString ?? "None"))
        setAccessibilityHelp("Click to record a shortcut. Press Delete to clear it.")
    }
}

/// SwiftUI wrapper for `ShortcutRecorderView`.
struct ShortcutRecorder: NSViewRepresentable {
    var combo: KeyCombo?
    var onChange: (KeyCombo?) -> Void

    func makeNSView(context: Context) -> ShortcutRecorderView {
        let v = ShortcutRecorderView()
        v.combo = combo
        v.onChange = onChange
        v.setContentHuggingPriority(.required, for: .vertical)
        return v
    }

    func updateNSView(_ nsView: ShortcutRecorderView, context: Context) {
        if !nsView.isRecording { nsView.combo = combo }
        nsView.onChange = onChange
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: ShortcutRecorderView, context: Context) -> CGSize? {
        CGSize(width: 160, height: 24)
    }
}
