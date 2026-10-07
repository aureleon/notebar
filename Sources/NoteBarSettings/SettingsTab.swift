import AppKit
import SwiftUI
import NoteBarCore

/// The tabs of the settings window.
public enum SettingsTab: String, CaseIterable, Sendable {
    case general, appearance, shortcuts, data, about

    public var title: String {
        switch self {
        case .general: "General"
        case .appearance: "Appearance"
        case .shortcuts: "Shortcuts"
        case .data: "Data"
        case .about: "About"
        }
    }

    public var symbolName: String {
        switch self {
        case .general: "gearshape"
        case .appearance: "paintpalette"
        case .shortcuts: "command"
        case .data: "externaldrive"
        case .about: "info.circle"
        }
    }

    /// Content size of the tab (the window resizes when the tab changes; long tabs scroll).
    public var contentSize: NSSize {
        switch self {
        case .general: NSSize(width: 580, height: 560)
        case .appearance: NSSize(width: 580, height: 640)
        case .shortcuts: NSSize(width: 580, height: 520)
        case .data: NSSize(width: 580, height: 620)
        case .about: NSSize(width: 580, height: 440)
        }
    }
}

@MainActor
public enum SettingsViews {
    /// The SwiftUI view of one tab.
    public static func view(for tab: SettingsTab, models: SettingsModels, height: CGFloat? = nil) -> AnyView {
        let settings = models.env.settings
        let content: AnyView
        switch tab {
        case .general: content = AnyView(GeneralPane(settings: settings, launch: models.launch))
        case .appearance: content = AnyView(AppearancePane(settings: settings, themes: models.themes, models: models))
        case .shortcuts: content = AnyView(ShortcutsPane(settings: settings, registration: models.hotkeyStatus))
        case .data: content = AnyView(DataPane(settings: settings, backups: models.backups))
        case .about: content = AnyView(AboutPane(env: models.env, about: models.about))
        }
        return AnyView(content.frame(width: tab.contentSize.width, height: height ?? tab.contentSize.height))
    }

    /// An `NSHostingView` of one tab, sized to `tab.contentSize` (or `height`; used by the snapshot tool).
    public static func makeHostingView(for tab: SettingsTab, models: SettingsModels, height: CGFloat? = nil) -> NSView {
        let v = NSHostingView(rootView: view(for: tab, models: models, height: height))
        v.frame = NSRect(origin: .zero, size: NSSize(width: tab.contentSize.width, height: height ?? tab.contentSize.height))
        return v
    }
}
