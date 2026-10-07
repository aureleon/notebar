import AppKit
import SwiftUI
import NoteBarCore

// Small helpers shared by the settings panes.

extension Color {
    /// SwiftUI color from a theme hex string ("#RRGGBB" / "#RRGGBBAA").
    init(hex: String, fallback: NSColor = .labelColor) {
        self.init(nsColor: NSColor(hex: hex) ?? fallback)
    }
}

enum SettingsFormat {
    static let backupDate: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        f.doesRelativeDateFormatting = true
        return f
    }()

    static let fileDate: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HHmm"
        return f
    }()

    static func bytes(_ n: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: n, countStyle: .file)
    }

    /// Replaces the home directory prefix with "~".
    static func abbreviatedPath(_ url: URL) -> String {
        (url.path as NSString).abbreviatingWithTildeInPath
    }
}

/// Converts a SwiftUI color to "#RRGGBB", keeping the alpha suffix of `previous` if it had one
/// (palette entries such as `headerBackground` are translucent).
func hexString(from color: Color, preservingAlphaOf previous: String) -> String {
    let rgb = NSColor(color).hexString
    var p = previous.trimmingCharacters(in: .whitespaces)
    if p.hasPrefix("#") { p.removeFirst() }
    if p.count == 8 { return rgb + String(p.suffix(2)) }
    return rgb
}

/// The caption style used under toggles and rows.
struct FootnoteText: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}
