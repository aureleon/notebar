import SwiftUI
import NoteBarCore

/// A small picture of the panel in a theme: light half on the left, dark half on the right.
struct ThemeSwatch: View {
    let theme: Theme

    var body: some View {
        HStack(spacing: 0) {
            half(theme.light, desktop: Color(white: 0.86))
            half(theme.dark, desktop: Color(white: 0.16))
        }
    }

    private func half(_ p: ThemePalette, desktop: Color) -> some View {
        let radius = max(2, theme.cornerRadius / 4)
        return ZStack(alignment: .top) {
            desktop
            VStack(spacing: 3) {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(Color(hex: p.headerBackground))
                    .frame(height: 11)
                    .overlay(alignment: .leading) {
                        Capsule().fill(Color(hex: p.accent)).frame(width: 20, height: 3.5).padding(.leading, 5)
                    }
                card(p, "none", lines: 2)
                card(p, "yellow", lines: 1)
                card(p, "purple", lines: 1)
            }
            .padding(6)
        }
    }

    private func card(_ p: ThemePalette, _ key: String, lines: Int) -> some View {
        let radius = max(2, theme.cornerRadius / 4)
        let bg = p.cardBackgrounds[key] ?? p.cardBackgrounds["none"] ?? "#FFFFFF"
        let title = p.cardTitles[key] ?? p.text
        return RoundedRectangle(cornerRadius: radius, style: .continuous)
            .fill(Color(hex: bg))
            .shadow(color: .black.opacity(0.12), radius: 1, y: 0.5)
            .frame(height: lines > 1 ? 20 : 15)
            .overlay(alignment: .topLeading) {
                VStack(alignment: .leading, spacing: 2.5) {
                    Capsule().fill(Color(hex: title)).frame(width: 22, height: 3)
                    ForEach(0..<lines, id: \.self) { i in
                        Capsule().fill(Color(hex: p.text).opacity(0.35)).frame(width: i == 0 ? 34 : 26, height: 2)
                    }
                }
                .padding(.horizontal, 5)
                .padding(.top, 4)
            }
    }
}

/// One selectable theme in the grid.
struct ThemeTile: View {
    let theme: Theme
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                ThemeSwatch(theme: theme)
                    .frame(width: 128, height: 84)
                    .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
                    )
                    .padding(3)
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(Color.accentColor, lineWidth: isSelected ? 3 : 0)
                    )
                Text(theme.name)
                    .font(.callout)
                    .fontWeight(isSelected ? .semibold : .regular)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: 134)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("\(theme.name) theme"))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// Picture of how a note color is shown: full background or left bar.
struct ColorStyleTile: View {
    let style: CardColorStyle
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                ZStack {
                    RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.primary.opacity(0.06))
                    VStack(spacing: 5) {
                        sample(tint: Color(hex: "#FBF0C2"), title: Color(hex: "#8A6A00"))
                        sample(tint: Color(hex: "#EADFFB"), title: Color(hex: "#5B3A99"))
                    }
                    .padding(8)
                }
                .frame(width: 128, height: 70)
                .padding(3)
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(Color.accentColor, lineWidth: isSelected ? 3 : 0)
                )
                Text(style == .background ? "Full background" : "Left bar")
                    .font(.callout)
                    .fontWeight(isSelected ? .semibold : .regular)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func sample(tint: Color, title: Color) -> some View {
        let shape = RoundedRectangle(cornerRadius: 5, style: .continuous)
        return shape
            .fill(style == .background ? tint : Color(nsColor: .textBackgroundColor))
            .overlay(alignment: .leading) {
                if style == .leftBar {
                    Rectangle().fill(title.opacity(0.75)).frame(width: 4)
                }
            }
            .clipShape(shape)
            .shadow(color: .black.opacity(0.12), radius: 1, y: 0.5)
            .overlay(alignment: .topLeading) {
                VStack(alignment: .leading, spacing: 3) {
                    Capsule().fill(title).frame(width: 30, height: 3.5)
                    Capsule().fill(Color.primary.opacity(0.3)).frame(width: 48, height: 2.5)
                }
                .padding(.leading, style == .leftBar ? 10 : 7)
                .padding(.top, 5)
            }
            .frame(height: 22)
    }
}
