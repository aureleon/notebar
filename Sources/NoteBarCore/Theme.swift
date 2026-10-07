import AppKit

public struct ThemePalette: Codable, Hashable, Sendable {
    /// Hex strings like "#RRGGBB" or "#RRGGBBAA".
    public var text: String
    public var secondaryText: String
    public var accent: String
    public var link: String
    public var inlineCode: String
    public var codeBlockBackground: String
    public var highlight: String
    public var quote: String
    public var markup: String          // dimmed markdown markers
    public var headerBackground: String
    public var folderRowBackground: String
    /// Card background per NoteColor rawValue. "none" = default card color.
    public var cardBackgrounds: [String: String]
    /// Title text per NoteColor rawValue (darker shade of the card color).
    public var cardTitles: [String: String]

    public init(text: String, secondaryText: String, accent: String, link: String, inlineCode: String,
                codeBlockBackground: String, highlight: String, quote: String, markup: String,
                headerBackground: String, folderRowBackground: String,
                cardBackgrounds: [String: String], cardTitles: [String: String]) {
        self.text = text; self.secondaryText = secondaryText; self.accent = accent; self.link = link
        self.inlineCode = inlineCode; self.codeBlockBackground = codeBlockBackground; self.highlight = highlight
        self.quote = quote; self.markup = markup; self.headerBackground = headerBackground
        self.folderRowBackground = folderRowBackground; self.cardBackgrounds = cardBackgrounds; self.cardTitles = cardTitles
    }
}

public struct Theme: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var cornerRadius: Double
    public var fontSize: Double
    public var light: ThemePalette
    public var dark: ThemePalette

    public init(id: String, name: String, cornerRadius: Double = 16, fontSize: Double = 13,
                light: ThemePalette, dark: ThemePalette) {
        self.id = id; self.name = name; self.cornerRadius = cornerRadius; self.fontSize = fontSize
        self.light = light; self.dark = dark
    }

    public func palette(isDark: Bool) -> ThemePalette { isDark ? dark : light }
}

public extension Theme {
    static let defaultTheme = Theme(
        id: "default", name: "Default",
        light: ThemePalette(
            text: "#1D1D1F", secondaryText: "#86868B", accent: "#1F4F99", link: "#0A66D8",
            inlineCode: "#2F6FDB", codeBlockBackground: "#0000000D", highlight: "#D8F5A2", quote: "#8A5A2B",
            markup: "#00000040", headerBackground: "#FFFFFFE6", folderRowBackground: "#FFFFFFF2",
            cardBackgrounds: ["none": "#FFFFFF", "purple": "#EADFFB", "yellow": "#FBF0C2", "blue": "#D8E7FB",
                              "green": "#DDF2D8", "pink": "#FADCE3", "cream": "#F5ECDC"],
            cardTitles: ["none": "#1D1D1F", "purple": "#5B3A99", "yellow": "#8A6A00", "blue": "#1F4F99",
                         "green": "#2F6B2A", "pink": "#9A2F4B", "cream": "#7A5A2E"]),
        dark: ThemePalette(
            text: "#F2F2F7", secondaryText: "#98989D", accent: "#F0B456", link: "#5AA2FF",
            inlineCode: "#7FB0FF", codeBlockBackground: "#FFFFFF14", highlight: "#4E6B1E", quote: "#D2A06E",
            markup: "#FFFFFF40", headerBackground: "#2C2C2EE6", folderRowBackground: "#2C2C2EF2",
            cardBackgrounds: ["none": "#2C2C2E", "purple": "#3A3150", "yellow": "#4A4223", "blue": "#26384F",
                              "green": "#2A4229", "pink": "#4C2C35", "cream": "#433D33"],
            cardTitles: ["none": "#F2F2F7", "purple": "#CDB6FF", "yellow": "#F5D97A", "blue": "#9CC6FF",
                         "green": "#A6DE9C", "pink": "#FFA9BD", "cream": "#E8CFA5"]))

    static let graphite = Theme(
        id: "graphite", name: "Graphite", cornerRadius: 12,
        light: ThemePalette(
            text: "#222222", secondaryText: "#7A7A7A", accent: "#5E5CE6", link: "#3B5BDB",
            inlineCode: "#5E5CE6", codeBlockBackground: "#00000010", highlight: "#FFE58F", quote: "#6B6B6B",
            markup: "#00000038", headerBackground: "#F4F4F5E6", folderRowBackground: "#F7F7F8F2",
            cardBackgrounds: ["none": "#F7F7F8", "purple": "#E6E3F7", "yellow": "#F6F0D2", "blue": "#DFE7F3",
                              "green": "#E0EEDF", "pink": "#F3E0E4", "cream": "#EFE9DF"],
            cardTitles: ["none": "#222222", "purple": "#4B3F99", "yellow": "#7A6200", "blue": "#2B4A80",
                         "green": "#2E5E2B", "pink": "#86304A", "cream": "#6B5232"]),
        dark: ThemePalette(
            text: "#E6E6E6", secondaryText: "#8E8E93", accent: "#8E8CFF", link: "#7DA2FF",
            inlineCode: "#A5A3FF", codeBlockBackground: "#FFFFFF12", highlight: "#5C4D12", quote: "#B0B0B0",
            markup: "#FFFFFF38", headerBackground: "#1C1C1EE6", folderRowBackground: "#1C1C1EF2",
            cardBackgrounds: ["none": "#1C1C1E", "purple": "#2E2A44", "yellow": "#3B3520", "blue": "#202D40",
                              "green": "#223522", "pink": "#3D242C", "cream": "#36312A"],
            cardTitles: ["none": "#E6E6E6", "purple": "#C3B8FF", "yellow": "#EAD27A", "blue": "#9EC0FF",
                         "green": "#9FD69A", "pink": "#FFA3B8", "cream": "#E0C9A2"]))

    static let builtIn: [Theme] = [.defaultTheme, .graphite]
}

public extension NSColor {
    /// "#RGB", "#RRGGBB" or "#RRGGBBAA". Returns nil if invalid.
    convenience init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        if s.count == 3 { s = s.map { "\($0)\($0)" }.joined() }
        guard s.count == 6 || s.count == 8, let v = UInt64(s, radix: 16) else { return nil }
        let r, g, b, a: Double
        if s.count == 6 {
            r = Double((v >> 16) & 0xFF) / 255; g = Double((v >> 8) & 0xFF) / 255; b = Double(v & 0xFF) / 255; a = 1
        } else {
            r = Double((v >> 24) & 0xFF) / 255; g = Double((v >> 16) & 0xFF) / 255
            b = Double((v >> 8) & 0xFF) / 255; a = Double(v & 0xFF) / 255
        }
        self.init(srgbRed: r, green: g, blue: b, alpha: a)
    }

    var hexString: String {
        let c = usingColorSpace(.sRGB) ?? self
        return String(format: "#%02X%02X%02X", Int(round(c.redComponent * 255)),
                      Int(round(c.greenComponent * 255)), Int(round(c.blueComponent * 255)))
    }
}

/// Resolves the current theme + appearance into colors. Posts `.themeDidChange` when the theme or
/// appearance setting changes. Views should re-read colors in `viewDidChangeEffectiveAppearance` too.
@MainActor
public final class ThemeManager {
    public private(set) var theme: Theme
    private let settings: AppSettings
    private weak var store: NoteStore?
    private var observer: NSObjectProtocol?
    private var storeObserver: NSObjectProtocol?

    public init(settings: AppSettings, store: NoteStore?) {
        self.settings = settings
        self.store = store
        self.theme = .defaultTheme
        reload()
        observer = NotificationCenter.default.addObserver(forName: .appSettingsDidChange, object: nil, queue: .main) { [weak self] n in
            let key = n.userInfo?["key"] as? String
            guard key == nil || key == "themeId" || key == "appearance" || key == "colorStyle" else { return }
            MainActor.assumeIsolated { self?.reload() }
        }
        // Custom themes live in the store: reload after a restore (`.all`).
        storeObserver = NotificationCenter.default.addObserver(forName: .noteStoreDidChange, object: nil, queue: .main) { [weak self] n in
            guard n.storeChange == .all else { return }
            MainActor.assumeIsolated { self?.reload() }
        }
    }

    public var allThemes: [Theme] { Theme.builtIn + (store?.customThemes() ?? []) }

    public func reload() {
        theme = allThemes.first { $0.id == settings.themeId } ?? .defaultTheme
        NSApp?.appearance = settings.appearance.nsAppearance
        NotificationCenter.default.post(name: .themeDidChange, object: self)
    }

    public func palette(for appearance: NSAppearance) -> ThemePalette {
        theme.palette(isDark: appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua)
    }

    public func color(_ keyPath: KeyPath<ThemePalette, String>, appearance: NSAppearance) -> NSColor {
        NSColor(hex: palette(for: appearance)[keyPath: keyPath]) ?? .labelColor
    }

    public func cardBackground(_ color: NoteColor, appearance: NSAppearance) -> NSColor {
        let p = palette(for: appearance)
        return NSColor(hex: p.cardBackgrounds[color.rawValue] ?? p.cardBackgrounds["none"] ?? "#FFFFFF") ?? .windowBackgroundColor
    }

    public func cardTitle(_ color: NoteColor, appearance: NSAppearance) -> NSColor {
        let p = palette(for: appearance)
        return NSColor(hex: p.cardTitles[color.rawValue] ?? p.text) ?? .labelColor
    }

    /// The swatch color shown in color pickers (light-mode card background, slightly stronger).
    public func swatch(_ color: NoteColor) -> NSColor {
        guard color != .none, let hex = theme.light.cardTitles[color.rawValue], let c = NSColor(hex: hex) else {
            return .tertiaryLabelColor
        }
        return c.blended(withFraction: 0.35, of: .white) ?? c
    }

    public var fontSize: CGFloat { CGFloat(theme.fontSize) }
    public var cornerRadius: CGFloat { CGFloat(theme.cornerRadius) }
}

public extension Notification.Name {
    static let themeDidChange = Notification.Name("NoteBar.themeDidChange")
}
