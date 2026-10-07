import SwiftUI
import NoteBarCore

struct AppearancePane: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var themes: ThemesModel
    let models: SettingsModels

    var body: some View {
        Form {
            Section {
                Picker("Appearance", selection: $settings.appearance) {
                    Text("System").tag(AppearanceMode.system)
                    Text("Light").tag(AppearanceMode.light)
                    Text("Dark").tag(AppearanceMode.dark)
                }
                .pickerStyle(.segmented)
            }

            Section {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 136, maximum: 160), spacing: 14, alignment: .top)],
                          alignment: .leading, spacing: 14) {
                    ForEach(themes.all) { theme in
                        ThemeTile(theme: theme, isSelected: theme.id == settings.themeId) {
                            themes.select(theme.id)
                        }
                    }
                }
                .padding(.vertical, 4)

                HStack {
                    Spacer()
                    if themes.draft != nil {
                        Button("Delete Theme…", role: .destructive) { confirmDelete() }
                    }
                    Button(themes.draft == nil ? "Duplicate to Customize" : "Duplicate") {
                        themes.duplicateSelected()
                    }
                }
            } header: {
                Text("Theme")
            } footer: {
                if themes.draft == nil {
                    FootnoteText("Built-in themes cannot be changed. Duplicate one to make your own colors.")
                }
            }

            if themes.draft != nil {
                ThemeEditorSection(themes: themes)
            }

            Section("Notes") {
                LabeledContent("Note color") {
                    HStack(spacing: 14) {
                        ForEach(CardColorStyle.allCases, id: \.self) { style in
                            ColorStyleTile(style: style, isSelected: settings.colorStyle == style) {
                                settings.colorStyle = style
                            }
                        }
                    }
                }

                Picker("Mode for new notes", selection: $settings.defaultNoteMode) {
                    ForEach(NoteMode.allCases, id: \.self) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }

                Toggle(isOn: $settings.hideMarkup) {
                    Text("Hide Markdown markup")
                    Text("Markers such as ** and # are hidden when the text cursor is not on them. When off, they are dimmed.")
                }
            }
        }
        .formStyle(.grouped)
    }

    private func confirmDelete() {
        guard let draft = themes.draft else { return }
        models.confirm("Delete the theme “\(draft.name)”?",
                       message: "NoteBar switches to the Default theme. You cannot undo this.",
                       confirmTitle: "Delete", destructive: true) { [themes] in
            themes.deleteSelected()
        }
    }
}

/// Color editor for the selected custom theme. Changes save automatically.
struct ThemeEditorSection: View {
    @ObservedObject var themes: ThemesModel

    private static let fields: [(String, WritableKeyPath<ThemePalette, String>)] = [
        ("Accent (folder title)", \.accent),
        ("Text", \.text),
        ("Secondary text", \.secondaryText),
        ("Links", \.link),
        ("Inline code", \.inlineCode),
        ("Quotes", \.quote),
        ("Highlight", \.highlight),
        ("Header background", \.headerBackground),
    ]

    var body: some View {
        Section {
            TextField("Name", text: themes.name)

            Picker("Edit colors for", selection: $themes.editsDarkPalette) {
                Text("Light Mode").tag(false)
                Text("Dark Mode").tag(true)
            }
            .pickerStyle(.segmented)

            ForEach(Self.fields, id: \.0) { field in
                ColorPicker(field.0, selection: themes.paletteColor(field.1), supportsOpacity: false)
            }

            DisclosureGroup("Note colors") {
                ForEach(NoteColor.allCases, id: \.self) { color in
                    LabeledContent(color == .none ? "No color" : color.displayName) {
                        HStack(spacing: 16) {
                            HStack(spacing: 6) {
                                Text("Card").foregroundStyle(.secondary)
                                ColorPicker("Card", selection: themes.cardColor(color, .background), supportsOpacity: false)
                                    .labelsHidden()
                            }
                            HStack(spacing: 6) {
                                Text("Title").foregroundStyle(.secondary)
                                ColorPicker("Title", selection: themes.cardColor(color, .title), supportsOpacity: false)
                                    .labelsHidden()
                            }
                        }
                    }
                }
            }

            LabeledContent("Text size") {
                Stepper(value: themes.fontSize, in: 10...22, step: 1) {
                    Text("\(Int(themes.fontSize.wrappedValue)) pt").monospacedDigit()
                }
            }

            LabeledContent("Card corners") {
                HStack(spacing: 10) {
                    Slider(value: themes.cornerRadius, in: 0...24, step: 1).frame(maxWidth: 220)
                    Text("\(Int(themes.cornerRadius.wrappedValue)) pt")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .frame(width: 40, alignment: .trailing)
                }
            }

            HStack {
                Spacer()
                Button(themes.editsDarkPalette ? "Reset Dark Colors" : "Reset Light Colors") {
                    themes.resetPaletteToDefault()
                }
            }
        } header: {
            Text("Customize “\(themes.draft?.name ?? "")”")
        } footer: {
            FootnoteText("Changes apply to the panel right away.")
        }
    }
}
