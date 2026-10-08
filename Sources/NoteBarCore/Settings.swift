import AppKit
import Combine

public enum PanelSide: String, CaseIterable, Codable, Sendable {
    case left, right
    public var opposite: PanelSide { self == .left ? .right : .left }
}

public enum CardColorStyle: String, CaseIterable, Codable, Sendable {
    /// The note color fills the card.
    case background
    /// The card keeps the default color; a colored bar is drawn on its left edge.
    case leftBar
}

public enum AppearanceMode: String, CaseIterable, Codable, Sendable {
    case system, light, dark
    @MainActor public var nsAppearance: NSAppearance? {
        switch self {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }
}

public enum HotSideArea: String, CaseIterable, Codable, Sendable {
    case corner, quadrant, edge, dynamic

    public var displayName: String {
        switch self {
        case .corner: "Corner"
        case .quadrant: "Quadrant"
        case .edge: "Edge"
        case .dynamic: "Dynamic"
        }
    }

    public var description: String {
        switch self {
        case .corner: "Only the upper corner of the screen"
        case .quadrant: "Upper half of the screen side"
        case .edge: "Full side of the screen"
        case .dynamic: "Matches the current height of NoteBar"
        }
    }
}

public enum AppPaths {
    /// `~/Library/Application Support/NoteBar`, or `$NOTEBAR_DATA_DIR` if set (use it for tests / smoke runs).
    public static var supportDirectory: URL {
        if let override = ProcessInfo.processInfo.environment["NOTEBAR_DATA_DIR"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("NoteBar", isDirectory: true)
    }
    public static var databaseURL: URL { supportDirectory.appendingPathComponent("notebar.sqlite") }
    public static var attachmentsDirectory: URL { supportDirectory.appendingPathComponent("attachments", isDirectory: true) }
    public static var backupsDirectory: URL { supportDirectory.appendingPathComponent("Backups", isDirectory: true) }

    public static func ensureDirectories() {
        for d in [supportDirectory, attachmentsDirectory, backupsDirectory] {
            try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        }
    }
}

/// Panel width rules shared by every module (Panel, UI, Settings, snapshots).
public enum PanelWidth {
    /// Automatic width: about 27 % of the visible screen width, clamped to 380...600 pt.
    public static func automatic(visibleWidth: CGFloat) -> CGFloat {
        guard visibleWidth.isFinite, visibleWidth > 0 else { return 380 }
        return min(max((visibleWidth * 0.27).rounded(), 380), 600)
    }
    /// Hard limits for a user-set width.
    public static let minWidth: CGFloat = 280
    public static let maxWidth: CGFloat = 720
    /// Width used when no screen is known (for example, in tests).
    public static let fallback: CGFloat = 380
}

public extension Notification.Name {
    /// userInfo["key"] = the property name that changed (String).
    static let appSettingsDidChange = Notification.Name("NoteBar.appSettingsDidChange")
    /// Posted when NoteBar's content height changes (dynamic hot side).
    static let contentExtentDidChange = Notification.Name("NoteBar.contentExtentDidChange")
}

/// User preferences, persisted in UserDefaults. SwiftUI: use `@ObservedObject var settings: AppSettings`
/// (no @State — SwiftUI macros are unavailable with Command Line Tools). AppKit: observe
/// `.appSettingsDidChange` (userInfo["key"]) or `objectWillChange`.
@MainActor
public final class AppSettings: ObservableObject {
    public static let shared = AppSettings()

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        func get<T>(_ k: String, _ d: T) -> T { defaults.object(forKey: k) as? T ?? d }
        func getEnum<E: RawRepresentable>(_ k: String, _ d: E) -> E where E.RawValue == String {
            (defaults.string(forKey: k)).flatMap(E.init(rawValue:)) ?? d
        }
        panelSide = getEnum("panelSide", .right)
        // Migration (once): the old default 290 pt and the Open Bar keys are gone.
        if !defaults.bool(forKey: "migratedPanelWidthV2") {
            if defaults.object(forKey: "panelWidth") == nil || defaults.double(forKey: "panelWidth") == 290 {
                defaults.removeObject(forKey: "panelWidth")
                defaults.set(true, forKey: "panelWidthIsAutomatic")
            }
            defaults.removeObject(forKey: "showOpenBar")
            defaults.removeObject(forKey: "openBarOffset")
            defaults.set(true, forKey: "migratedPanelWidthV2")
        }
        panelWidth = get("panelWidth", 380.0)
        // A saved width without the flag was set by the user before automatic width existed: keep it fixed.
        panelWidthIsAutomatic = get("panelWidthIsAutomatic", defaults.object(forKey: "panelWidth") == nil)
        blurBackdrop = get("blurBackdrop", true)
        if !defaults.bool(forKey: "migratedHotSideOptIn") {
            defaults.removeObject(forKey: "hotSideEnabled")
            defaults.set(true, forKey: "migratedHotSideOptIn")
        }
        hotSideEnabled = get("hotSideEnabled", false)
        hotSideArea = getEnum("hotSideArea", .edge)
        hotSideDelay = get("hotSideDelay", 0.3)
        autoHide = get("autoHide", true)
        pinnedOpen = get("pinnedOpen", false)
        colorStyle = getEnum("colorStyle", .background)
        appearance = getEnum("appearance", .system)
        themeId = get("themeId", "default")
        hideMarkup = get("hideMarkup", true)
        defaultNoteMode = getEnum("defaultNoteMode", .standard)
        vimKeybinds = get("vimKeybinds", false)
        backupsEnabled = get("backupsEnabled", true)
        backupRetention = get("backupRetention", 14)
        lastFolderId = (defaults.object(forKey: "lastFolderId") as? NSNumber)?.int64Value
        if let data = defaults.data(forKey: "hotkeys"), let h = try? JSONDecoder().decode([String: KeyCombo].self, from: data) {
            var decoded = Dictionary(uniqueKeysWithValues: h.compactMap { k, v in HotkeyAction(rawValue: k).map { ($0, v) } })
            for (action, defaultCombo) in HotkeyAction.defaults {
                if decoded[action] == nil {
                    decoded[action] = defaultCombo
                }
            }
            hotkeys = decoded
        } else {
            hotkeys = HotkeyAction.defaults
        }
    }

    private func save(_ key: String, _ value: Any?) {
        if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
        NotificationCenter.default.post(name: .appSettingsDidChange, object: self, userInfo: ["key": key])
    }

    // MARK: Panel
    @Published public var panelSide: PanelSide { didSet { save("panelSide", panelSide.rawValue) } }
    /// Points. Clamp to 280...720 when using. Ignored while `panelWidthIsAutomatic` is true.
    @Published public var panelWidth: Double { didSet { save("panelWidth", panelWidth) } }
    /// true = width follows the screen (about 27 % of the visible width, 380...600 pt).
    /// Set to false when the user resizes the panel or picks a width.
    @Published public var panelWidthIsAutomatic: Bool { didSet { save("panelWidthIsAutomatic", panelWidthIsAutomatic) } }
    @Published public var hotSideEnabled: Bool { didSet { save("hotSideEnabled", hotSideEnabled) } }
    @Published public var hotSideArea: HotSideArea { didSet { save("hotSideArea", hotSideArea.rawValue) } }
    /// Seconds the cursor must rest on the edge before the panel opens.
    @Published public var hotSideDelay: Double { didSet { save("hotSideDelay", hotSideDelay) } }
    /// Blur the screen area behind the panel (Notification Center style). Off = no backdrop.
    @Published public var blurBackdrop: Bool { didSet { save("blurBackdrop", blurBackdrop) } }
    /// Hide the panel when another app/window becomes active.
    @Published public var autoHide: Bool { didSet { save("autoHide", autoHide) } }
    /// Keep the panel open (overrides autoHide).
    @Published public var pinnedOpen: Bool { didSet { save("pinnedOpen", pinnedOpen) } }

    // MARK: Look
    @Published public var colorStyle: CardColorStyle { didSet { save("colorStyle", colorStyle.rawValue) } }
    @Published public var appearance: AppearanceMode { didSet { save("appearance", appearance.rawValue) } }
    @Published public var themeId: String { didSet { save("themeId", themeId) } }

    // MARK: Editor
    /// true = invisible markdown (markers hidden when caret is elsewhere); false = dimmed markers.
    @Published public var hideMarkup: Bool { didSet { save("hideMarkup", hideMarkup) } }
    @Published public var defaultNoteMode: NoteMode { didSet { save("defaultNoteMode", defaultNoteMode.rawValue) } }
    /// Vim keys: notes open in Normal mode (block caret), motions and operators, `/` search, `:` commands,
    /// ⌃W J / ⌃W K between cards, j / k / l / R in the folder list. Off by default (opt-in).
    @Published public var vimKeybinds: Bool { didSet { save("vimKeybinds", vimKeybinds) } }

    // MARK: Data
    @Published public var backupsEnabled: Bool { didSet { save("backupsEnabled", backupsEnabled) } }
    @Published public var backupRetention: Int { didSet { save("backupRetention", backupRetention) } }
    /// Folder shown when the panel opens (nil = folder list).
    @Published public var lastFolderId: FolderID? { didSet { save("lastFolderId", lastFolderId.map { NSNumber(value: $0) }) } }

    // MARK: Hotkeys
    /// Missing key = no shortcut for that action.
    @Published public var hotkeys: [HotkeyAction: KeyCombo] {
        didSet {
            let raw = Dictionary(uniqueKeysWithValues: hotkeys.map { ($0.key.rawValue, $0.value) })
            save("hotkeys", try? JSONEncoder().encode(raw))
        }
    }
}

// MARK: - Hotkeys

public enum HotkeyAction: String, CaseIterable, Codable, Sendable {
    case togglePanel, newNote, newNoteFromClipboard, search, toggleFloatPanel

    public var displayName: String {
        switch self {
        case .togglePanel: "Show / Hide NoteBar"
        case .newNote: "New Note"
        case .newNoteFromClipboard: "New Note from Clipboard"
        case .search: "Search Notes"
        case .toggleFloatPanel: "Float / Stay Open"
        }
    }

    /// ⌥⌘N toggle; ⌃⌥⌘N new; ⌃⌥⌘V clipboard; ⌃⌥⌘F search; ⌥⇧⌘N float panel.
    public static let defaults: [HotkeyAction: KeyCombo] = [
        .togglePanel: KeyCombo(keyCode: 0x2D, carbonModifiers: KeyCombo.cmd | KeyCombo.option),
        .newNote: KeyCombo(keyCode: 0x2D, carbonModifiers: KeyCombo.cmd | KeyCombo.option | KeyCombo.control),
        .newNoteFromClipboard: KeyCombo(keyCode: 0x09, carbonModifiers: KeyCombo.cmd | KeyCombo.option | KeyCombo.control),
        .search: KeyCombo(keyCode: 0x03, carbonModifiers: KeyCombo.cmd | KeyCombo.option | KeyCombo.control),
        .toggleFloatPanel: KeyCombo(keyCode: 0x2D, carbonModifiers: KeyCombo.cmd | KeyCombo.option | KeyCombo.shift),
    ]
}

/// A Carbon hotkey: virtual key code (kVK_*) + Carbon modifier mask (cmdKey, optionKey, ...).
public struct KeyCombo: Codable, Hashable, Sendable {
    public var keyCode: UInt32
    public var carbonModifiers: UInt32

    public static let cmd: UInt32 = 0x0100      // cmdKey
    public static let shift: UInt32 = 0x0200    // shiftKey
    public static let option: UInt32 = 0x0800   // optionKey
    public static let control: UInt32 = 0x1000  // controlKey

    public init(keyCode: UInt32, carbonModifiers: UInt32) { self.keyCode = keyCode; self.carbonModifiers = carbonModifiers }

    public init(keyCode: UInt16, modifierFlags: NSEvent.ModifierFlags) {
        var m: UInt32 = 0
        if modifierFlags.contains(.command) { m |= Self.cmd }
        if modifierFlags.contains(.shift) { m |= Self.shift }
        if modifierFlags.contains(.option) { m |= Self.option }
        if modifierFlags.contains(.control) { m |= Self.control }
        self.init(keyCode: UInt32(keyCode), carbonModifiers: m)
    }

    public var modifierFlags: NSEvent.ModifierFlags {
        var f: NSEvent.ModifierFlags = []
        if carbonModifiers & Self.cmd != 0 { f.insert(.command) }
        if carbonModifiers & Self.shift != 0 { f.insert(.shift) }
        if carbonModifiers & Self.option != 0 { f.insert(.option) }
        if carbonModifiers & Self.control != 0 { f.insert(.control) }
        return f
    }

    /// e.g. "⌃⌥⌘N" (US layout key names).
    public var displayString: String {
        var s = ""
        if carbonModifiers & Self.control != 0 { s += "⌃" }
        if carbonModifiers & Self.option != 0 { s += "⌥" }
        if carbonModifiers & Self.shift != 0 { s += "⇧" }
        if carbonModifiers & Self.cmd != 0 { s += "⌘" }
        return s + (Self.keyNames[keyCode] ?? "Key\(keyCode)")
    }

    /// Key equivalent string for NSMenuItem (lowercase letter etc.), or nil.
    public var menuKeyEquivalent: String? {
        guard let n = Self.keyNames[keyCode], n.count == 1 else { return nil }
        return n.lowercased()
    }

    static let keyNames: [UInt32: String] = [
        0x00: "A", 0x0B: "B", 0x08: "C", 0x02: "D", 0x0E: "E", 0x03: "F", 0x05: "G", 0x04: "H", 0x22: "I",
        0x26: "J", 0x28: "K", 0x25: "L", 0x2E: "M", 0x2D: "N", 0x1F: "O", 0x23: "P", 0x0C: "Q", 0x0F: "R",
        0x01: "S", 0x11: "T", 0x20: "U", 0x09: "V", 0x0D: "W", 0x07: "X", 0x10: "Y", 0x06: "Z",
        0x1D: "0", 0x12: "1", 0x13: "2", 0x14: "3", 0x15: "4", 0x17: "5", 0x16: "6", 0x1A: "7", 0x1C: "8", 0x19: "9",
        0x31: "Space", 0x24: "↩", 0x30: "⇥", 0x33: "⌫", 0x35: "⎋", 0x7B: "←", 0x7C: "→", 0x7D: "↓", 0x7E: "↑",
        0x2B: ",", 0x2F: ".", 0x2C: "/", 0x29: ";", 0x27: "'", 0x21: "[", 0x1E: "]", 0x2A: "\\", 0x1B: "-", 0x18: "=", 0x32: "`",
        0x7A: "F1", 0x78: "F2", 0x63: "F3", 0x76: "F4", 0x60: "F5", 0x61: "F6", 0x62: "F7", 0x64: "F8",
        0x65: "F9", 0x6D: "F10", 0x67: "F11", 0x6F: "F12",
    ]
}
