import AppKit
import SwiftUI
import NoteBarCore

/// Theme list + the custom theme editor draft.
@MainActor
final class ThemesModel: ObservableObject {
    let env: AppEnvironment
    @Published private(set) var all: [Theme] = []
    /// The selected theme when it is a custom theme (editable). nil for built-in themes.
    @Published private(set) var draft: Theme?
    /// The editor shows the dark palette when true.
    @Published var editsDarkPalette = false

    private var pendingSave: DispatchWorkItem?
    private var observer: NSObjectProtocol?

    init(env: AppEnvironment) {
        self.env = env
        observer = NotificationCenter.default.addObserver(forName: .themeDidChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reload() }
        }
        reload()
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    var selectedId: String { env.settings.themeId }

    static func isBuiltIn(_ id: String) -> Bool { Theme.builtIn.contains { $0.id == id } }

    func reload() {
        all = env.themes.allThemes
        let id = env.settings.themeId
        if Self.isBuiltIn(id) {
            draft = nil
        } else if pendingSave == nil || draft?.id != id {
            draft = all.first { $0.id == id }
        }
    }

    func select(_ id: String) {
        saveNow()
        env.settings.themeId = id
        // ThemeManager reloads on the settings notification and posts .themeDidChange -> reload().
        reload()
    }

    /// Copies the selected theme into a new custom theme and selects it.
    func duplicateSelected() {
        saveNow()
        var t = all.first { $0.id == env.settings.themeId } ?? env.themes.theme
        t.id = "custom-" + UUID().uuidString.prefix(8).lowercased()
        t.name = uniqueName(base: "\(t.name) Copy")
        env.store.saveTheme(t)
        select(t.id)
    }

    func deleteSelected() {
        let id = env.settings.themeId
        guard !Self.isBuiltIn(id) else { return }
        pendingSave?.cancel(); pendingSave = nil
        draft = nil
        env.store.deleteTheme(id: id)
        env.settings.themeId = Theme.defaultTheme.id
        env.themes.reload()
        reload()
    }

    // MARK: Editing

    func update(_ change: (inout Theme) -> Void) {
        guard var d = draft else { return }
        change(&d)
        guard d != draft else { return }
        draft = d
        scheduleSave()
    }

    func paletteColor(_ key: WritableKeyPath<ThemePalette, String>) -> Binding<Color> {
        Binding(
            get: { [weak self] in
                guard let d = self?.draft else { return .clear }
                return Color(hex: d.palette(isDark: self?.editsDarkPalette ?? false)[keyPath: key])
            },
            set: { [weak self] color in
                guard let self else { return }
                let dark = self.editsDarkPalette
                self.update { t in
                    if dark { t.dark[keyPath: key] = hexString(from: color, preservingAlphaOf: t.dark[keyPath: key]) }
                    else { t.light[keyPath: key] = hexString(from: color, preservingAlphaOf: t.light[keyPath: key]) }
                }
            })
    }

    enum CardPart { case background, title }

    func cardColor(_ color: NoteColor, _ part: CardPart) -> Binding<Color> {
        func read(_ p: ThemePalette) -> String {
            let dict = part == .background ? p.cardBackgrounds : p.cardTitles
            return dict[color.rawValue] ?? dict["none"] ?? (part == .background ? "#FFFFFF" : p.text)
        }
        return Binding(
            get: { [weak self] in
                guard let d = self?.draft else { return .clear }
                return Color(hex: read(d.palette(isDark: self?.editsDarkPalette ?? false)))
            },
            set: { [weak self] c in
                guard let self else { return }
                let dark = self.editsDarkPalette
                self.update { t in
                    var p = dark ? t.dark : t.light
                    let hex = hexString(from: c, preservingAlphaOf: read(p))
                    if part == .background { p.cardBackgrounds[color.rawValue] = hex } else { p.cardTitles[color.rawValue] = hex }
                    if dark { t.dark = p } else { t.light = p }
                }
            })
    }

    var name: Binding<String> {
        Binding(get: { [weak self] in self?.draft?.name ?? "" },
                set: { [weak self] v in self?.update { $0.name = v } })
    }

    var fontSize: Binding<Double> {
        Binding(get: { [weak self] in self?.draft?.fontSize ?? 14 },
                set: { [weak self] v in self?.update { $0.fontSize = min(max(v, 10), 22) } })
    }

    var cornerRadius: Binding<Double> {
        Binding(get: { [weak self] in self?.draft?.cornerRadius ?? 16 },
                set: { [weak self] v in self?.update { $0.cornerRadius = min(max(v.rounded(), 0), 24) } })
    }

    /// Resets the edited palette (light or dark) to the Default theme's palette.
    func resetPaletteToDefault() {
        let dark = editsDarkPalette
        update { t in if dark { t.dark = Theme.defaultTheme.dark } else { t.light = Theme.defaultTheme.light } }
    }

    // MARK: Saving

    private func scheduleSave() {
        pendingSave?.cancel()
        let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.saveNow() } }
        pendingSave = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    func saveNow() {
        guard let work = pendingSave else { return }
        work.cancel()
        pendingSave = nil
        guard var d = draft else { return }
        let trimmed = d.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { d.name = "Untitled Theme" }
        env.store.saveTheme(d)
        env.themes.reload()
    }

    private func uniqueName(base: String) -> String {
        let names = Set(all.map(\.name))
        if !names.contains(base) { return base }
        var i = 2
        while names.contains("\(base) \(i)") { i += 1 }
        return "\(base) \(i)"
    }
}
