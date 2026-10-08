import AppKit
import NoteBarCore

/// Global switches for NoteBarUI. Change before creating `NotesRootViewController`.
@MainActor
public enum NoteBarUIOptions {
    /// Use `NSGlassEffectView` (Liquid Glass) behind the header pill. Offscreen snapshots cannot render
    /// glass, so `UISnapshot` turns this off and a drawn pill is used instead.
    public static var useGlass = true
    /// Animate list changes (reorder, insert). Snapshots turn this off.
    public static var animations = true
}

/// Glass cards (Settings › Appearance › "Glass cards", key `blurBackdrop`): cards, the folder group and
/// the header use Liquid Glass (`NSGlassEffectView`), tinted with their theme color, like the widgets
/// in Notification Center. Off: solid theme colors with a drawn shadow.
@MainActor
enum CardGlass {
    static func isEnabled(_ env: AppEnvironment) -> Bool {
        NoteBarUIOptions.useGlass && env.settings.blurBackdrop
    }

    /// Glass tint for a theme fill: the same hue, translucent so the blurred desktop shows through.
    static func tint(_ fill: NSColor, dark: Bool) -> NSColor {
        fill.withAlphaComponent(dark ? 0.55 : 0.6)
    }

    /// Makes (or reuses) a glass view as the bottom subview of `host`, or removes it when `enabled` is false.
    static func sync(_ glass: inout NSGlassEffectView?, in host: NSView, enabled: Bool) {
        if enabled {
            if glass == nil {
                let g = NSGlassEffectView()
                host.addSubview(g, positioned: .below, relativeTo: nil)
                glass = g
            }
        } else {
            glass?.removeFromSuperview()
            glass = nil
        }
    }
}

/// Layout constants (points). Set by eye.
enum Metrics {
    /// Room around the content so card shadows are not clipped by the panel window.
    static let outerMargin: CGFloat = 6
    /// Header pill height. Grows with the panel width (46 pt at 290 pt wide, now about 54 pt at 410 pt).
    static let headerHeight: CGFloat = 54
    static let headerCornerRadius: CGFloat = 22
    static let headerButtonSize: CGFloat = 32
    /// Gap between the header and the first card, between the search bar and the first result, and
    /// between cards.
    static let gap: CGFloat = 10
    /// Card padding. The action column (right edge, on hover) has its own space, so it adds no height.
    static let cardPaddingX: CGFloat = 18
    static let cardPaddingTop: CGFloat = 18
    static let cardPaddingBottom: CGFloat = 18
    /// Height of the folded title row. Holds the title font (`UIFonts.title`) with its line height.
    static let cardTitleRowHeight: CGFloat = 22
    static let folderNameRowHeight: CGFloat = 18
    /// Action drawer (bottom-right, on hover): gap to the card's bottom edge and to the pin above it.
    static let actionColumnInsetBottom: CGFloat = 6
    static let actionColumnGap: CGFloat = 4
    /// Height of the search bar row (result count and scope toggle).
    static let scopeBarHeight: CGFloat = 26
    static let leftBarWidth: CGFloat = 4
    static let folderRowHeight: CGFloat = 34
    static let folderListPadding: CGFloat = 6
    static let folderGroupRadius: CGFloat = 14
    /// Room around each card for its drawn shadow (card views are this much larger than the card).
    static let cardShadowPad: CGFloat = 8
    static let pinButtonSize: CGFloat = 22
    /// Distance of the (unfolded) card's pin button from the card's top and right edges.
    static let pinButtonInset: CGFloat = 8
    /// Space between the end of the first text line and the pin button.
    static let pinTextGap: CGFloat = 4
    static let minEditorHeight: CGFloat = 18
    /// Editors are created for cards within this distance of the visible area.
    static let editorPrefetchDistance: CGFloat = 900
}

/// Theme colors resolved for one appearance.
struct UIColors {
    let isDark: Bool
    let text: NSColor
    let secondaryText: NSColor
    let accent: NSColor
    let link: NSColor
    let headerBackground: NSColor
    let folderRowBackground: NSColor
    let highlight: NSColor

    /// Neutral fill used for hover states and pill groups on top of a card/row.
    var hoverFill: NSColor { isDark ? NSColor.white.withAlphaComponent(0.10) : NSColor.black.withAlphaComponent(0.06) }
    var pressedFill: NSColor { isDark ? NSColor.white.withAlphaComponent(0.18) : NSColor.black.withAlphaComponent(0.12) }
    var pillFill: NSColor { isDark ? NSColor.white.withAlphaComponent(0.08) : NSColor.white.withAlphaComponent(0.55) }
    var pillStroke: NSColor { isDark ? NSColor.white.withAlphaComponent(0.06) : NSColor.black.withAlphaComponent(0.05) }
    var headerButtonFill: NSColor { isDark ? NSColor.white.withAlphaComponent(0.12) : NSColor.white.withAlphaComponent(0.85) }
    var shadowOpacity: Float { isDark ? 0.45 : 0.16 }
    var hairline: NSColor { isDark ? NSColor.white.withAlphaComponent(0.07) : NSColor.black.withAlphaComponent(0.04) }
    var iconTint: NSColor { secondaryText }
    /// Folder icons use the theme accent, the same as the header folder title.
    var folderIcon: NSColor { accent }
}

/// Default panel width for the current screen (the panel window sets the real width). Uses the
/// automatic rule from `PanelWidth` (about 27 % of the visible width, 380...600 pt).
@MainActor
enum PanelSizing {
    static var defaultWidth: CGFloat {
        PanelWidth.automatic(visibleWidth: NSScreen.main?.visibleFrame.width ?? 0)
    }
}

@MainActor
extension ThemeManager {
    func ui(_ appearance: NSAppearance) -> UIColors {
        let p = palette(for: appearance)
        let dark = appearance.isDark
        func c(_ hex: String, _ fallback: NSColor) -> NSColor { NSColor(hex: hex) ?? fallback }
        return UIColors(isDark: dark,
                        text: c(p.text, .labelColor),
                        secondaryText: c(p.secondaryText, .secondaryLabelColor),
                        accent: c(p.accent, .controlAccentColor),
                        link: c(p.link, .linkColor),
                        headerBackground: c(p.headerBackground, .windowBackgroundColor),
                        folderRowBackground: c(p.folderRowBackground, .windowBackgroundColor),
                        highlight: c(p.highlight, .systemYellow))
    }

    /// Color used for the left bar / folder icon tint of a note color.
    func barColor(_ color: NoteColor, appearance: NSAppearance) -> NSColor {
        guard color != .none else { return .clear }
        let title = cardTitle(color, appearance: appearance)
        return appearance.isDark ? title : (title.blended(withFraction: 0.25, of: .white) ?? title)
    }
}

extension NSAppearance {
    var isDark: Bool { bestMatch(from: [.aqua, .darkAqua]) == .darkAqua }
}

/// Every UI font is relative to the theme font size (`env.themes.fontSize`, 14 by default). The offsets
/// keep the proportions of the old 13 pt design. The card title is `title(fontSize)`, the same size and
/// weight as the editor's title line (`fontSize + 2`).
enum UIFonts {
    /// Card title (folded row and the preview). Pass `fontSize + 2` to match the editor's title line.
    static func title(_ size: CGFloat) -> NSFont { .systemFont(ofSize: size, weight: .bold) }
    static func headerTitle(_ fs: CGFloat) -> NSFont { .systemFont(ofSize: fs + 2, weight: .bold) }
    static func headerSearch(_ fs: CGFloat) -> NSFont { .systemFont(ofSize: fs) }
    static func footer(_ fs: CGFloat) -> NSFont { .monospacedDigitSystemFont(ofSize: fs - 2.5, weight: .medium) }
    static func footerButton(_ fs: CGFloat) -> NSFont { .systemFont(ofSize: fs - 2.5, weight: .semibold) }
    static func badge(_ fs: CGFloat) -> NSFont { .systemFont(ofSize: fs - 2, weight: .semibold) }
    static func folderName(_ fs: CGFloat) -> NSFont { .systemFont(ofSize: fs, weight: .regular) }
    static func folderCount(_ fs: CGFloat) -> NSFont { .monospacedDigitSystemFont(ofSize: fs - 2, weight: .regular) }
    static func small(_ fs: CGFloat) -> NSFont { .systemFont(ofSize: fs - 2, weight: .medium) }
    static func scope(_ fs: CGFloat) -> NSFont { .systemFont(ofSize: fs - 2, weight: .semibold) }
    /// Secondary line / hint text (empty state, drop hint, toast).
    static func caption(_ fs: CGFloat, weight: NSFont.Weight = .regular) -> NSFont { .systemFont(ofSize: fs - 1, weight: weight) }
    static func emptyTitle(_ fs: CGFloat) -> NSFont { .systemFont(ofSize: fs + 1, weight: .semibold) }
}

enum UIFormat {
    /// "20/05/2026, 17:02"
    static let footerDate: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "dd/MM/yyyy, HH:mm"
        return f
    }()

    static func linesBadge(_ n: Int) -> String { n == 1 ? "+ 1 line" : "+ \(n) lines" }

    /// A file name for exports, derived from the note title.
    static func fileName(for note: Note) -> String {
        var t = note.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { t = "Note" }
        let bad = CharacterSet(charactersIn: "/\\:?%*|\"<>")
        t = t.components(separatedBy: bad).joined(separator: "-")
        return String(t.prefix(60))
    }
}

enum Symbols {
    static func image(_ name: String, size: CGFloat, weight: NSFont.Weight = .regular) -> NSImage? {
        let cfg = NSImage.SymbolConfiguration(pointSize: size, weight: weight)
        return NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(cfg)
    }

    /// Draws a template symbol tinted with `color`, centered in `rect`.
    static func draw(_ image: NSImage, in rect: NSRect, color: NSColor) {
        let size = image.size
        let r = NSRect(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2, width: size.width, height: size.height)
            .integral
        let tinted = NSImage(size: size, flipped: false) { b in
            image.draw(in: b)
            color.set()
            b.fill(using: .sourceAtop)
            return true
        }
        tinted.draw(in: r, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    }
}

extension NSView {
    /// Renders the view (and subviews) into a bitmap at `scale`.
    func renderBitmap(scale: CGFloat = 2, rect: NSRect? = nil) -> NSBitmapImageRep? {
        let r = rect ?? bounds
        guard r.width >= 1, r.height >= 1,
              let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(ceil(r.width * scale)),
                                         pixelsHigh: Int(ceil(r.height * scale)), bitsPerSample: 8, samplesPerPixel: 4,
                                         hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        rep.size = r.size
        cacheDisplay(in: r, to: rep)
        return rep
    }

    /// True if `view` is self or a descendant.
    func containsDescendant(_ view: NSView?) -> Bool {
        var v = view
        while let cur = v { if cur === self { return true }; v = cur.superview }
        return false
    }
}

/// Fades the top / bottom edges of a scroll view (cards dissolve under the header instead of being cut).
@MainActor
func applyEdgeFade(to scrollView: NSScrollView, top: CGFloat, bottom: CGFloat) {
    scrollView.wantsLayer = true
    guard let layer = scrollView.layer else { return }
    let h = max(1, scrollView.bounds.height)
    let mask = (layer.mask as? CAGradientLayer) ?? CAGradientLayer()
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    mask.frame = layer.bounds
    let clear = NSColor.clear.cgColor, solid = NSColor.black.cgColor
    mask.colors = [clear, solid, solid, clear]
    // Layer coordinates are not flipped: y = 1 is the top edge.
    mask.startPoint = CGPoint(x: 0.5, y: scrollView.layer?.isGeometryFlipped == true ? 0 : 1)
    mask.endPoint = CGPoint(x: 0.5, y: scrollView.layer?.isGeometryFlipped == true ? 1 : 0)
    mask.locations = [0, NSNumber(value: Double(min(0.4, top / h))), NSNumber(value: Double(max(0.6, 1 - bottom / h))), 1]
    if layer.mask !== mask { layer.mask = mask }
    CATransaction.commit()
}

/// A plain flipped container.
class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// Non-editable single-line label.
@MainActor
func makeLabel(_ text: String = "", font: NSFont, color: NSColor = .labelColor) -> NSTextField {
    let l = NSTextField(labelWithString: text)
    l.font = font
    l.textColor = color
    l.lineBreakMode = .byTruncatingTail
    l.maximumNumberOfLines = 1
    l.cell?.truncatesLastVisibleLine = true
    l.isSelectable = false
    l.allowsDefaultTighteningForTruncation = false
    return l
}

/// Unique "New Folder", "New Folder 2", ...
@MainActor
func uniqueFolderName(_ base: String, in store: NoteStore) -> String {
    let names = Set(store.folders().map { $0.name.lowercased() })
    if !names.contains(base.lowercased()) { return base }
    var i = 2
    while names.contains("\(base) \(i)".lowercased()) { i += 1 }
    return "\(base) \(i)"
}
