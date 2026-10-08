import AppKit
import NoteBarCore

/// Row above the search results: result count, the "Archive" chip (also find archived notes) and the
/// "This Folder | All Folders" toggle.
@MainActor
final class SearchScopeBar: NSView {
    var onToggle: ((Bool) -> Void)?
    var onArchiveToggle: ((Bool) -> Void)?
    private let env: AppEnvironment
    private let countLabel = PassthroughLabel()
    private let toggle = SegmentToggle()
    let archiveChip = ChipToggle(title: "Archive")

    init(env: AppEnvironment) {
        self.env = env
        super.init(frame: NSRect(x: 0, y: 0, width: 280, height: Metrics.scopeBarHeight))
        countLabel.font = UIFonts.scope(env.themes.fontSize)
        toggle.font = UIFonts.scope(env.themes.fontSize)
        archiveChip.font = UIFonts.scope(env.themes.fontSize)
        addSubview(countLabel)
        addSubview(archiveChip)
        addSubview(toggle)
        toggle.onChange = { [weak self] idx in self?.onToggle?(idx == 1) }
        archiveChip.onChange = { [weak self] on in self?.onArchiveToggle?(on) }
        archiveChip.toolTip = "Also find archived notes"
        archiveChip.setAccessibilityLabel("Include archived notes")
        restyle()
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var fittingSize: NSSize { NSSize(width: frame.width, height: Metrics.scopeBarHeight) }

    /// `folderName == nil` hides the toggle (searching from the folder list always covers all folders).
    /// `inArchive`: search started in the archive (only archived notes; no toggles).
    func update(resultCount: Int?, allFolders: Bool, folderName: String?, includeArchived: Bool = false, inArchive: Bool = false) {
        if let n = resultCount {
            countLabel.stringValue = n == 1 ? "1 result" : "\(n) results"
        } else {
            countLabel.stringValue = inArchive ? "In the archive" : allFolders ? "All folders" : "In “\(folderName ?? "")”"
        }
        archiveChip.isHidden = inArchive
        archiveChip.isOn = includeArchived
        toggle.isHidden = folderName == nil || inArchive
        toggle.titles = [folderName.map { Self.short($0) } ?? "Folder", "All Folders"]
        toggle.selectedIndex = allFolders ? 1 : 0
        needsLayout = true
    }

    private static func short(_ s: String) -> String { s.count > 14 ? String(s.prefix(13)) + "…" : s }

    func restyle() {
        let c = env.themes.ui(effectiveAppearance)
        countLabel.font = UIFonts.scope(env.themes.fontSize)
        toggle.font = UIFonts.scope(env.themes.fontSize)
        archiveChip.font = UIFonts.scope(env.themes.fontSize)
        countLabel.textColor = c.text
        toggle.colors = c
        archiveChip.colors = c
        needsDisplay = true
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        restyle()
    }

    override func layout() {
        super.layout()
        let tw = toggle.isHidden ? 0 : min(toggle.intrinsicContentSize.width, bounds.width * 0.65)
        // The chip and the toggle share one height, centered on the bar.
        let h = Metrics.scopeBarHeight
        toggle.frame = NSRect(x: bounds.width - tw, y: (bounds.height - h) / 2, width: tw, height: h)
        let cw = archiveChip.isHidden ? 0 : archiveChip.intrinsicContentSize.width
        let chipRight = toggle.isHidden ? bounds.width : toggle.frame.minX - 6
        archiveChip.frame = NSRect(x: chipRight - cw, y: (bounds.height - h) / 2, width: cw, height: h)
        let lh = ceil(countLabel.intrinsicContentSize.height)
        let labelRight = archiveChip.isHidden ? toggle.frame.minX : archiveChip.frame.minX
        countLabel.frame = NSRect(x: 8, y: (bounds.height - lh) / 2, width: max(0, labelRight - 16), height: lh)
    }

    override func draw(_ dirtyRect: NSRect) {
        // Soft backing so the count is readable over any desktop.
        let c = env.themes.ui(effectiveAppearance)
        let lw = ceil(countLabel.intrinsicContentSize.width) + 16
        let r = NSRect(x: 0, y: (bounds.height - Metrics.scopeBarHeight) / 2, width: min(lw, bounds.width), height: Metrics.scopeBarHeight)
        c.folderRowBackground.withAlphaComponent(0.85).setFill()
        NSBezierPath(roundedRect: r, xRadius: 12, yRadius: 12).fill()
    }
}

/// On / off pill ("Archive" in the search scope bar), drawn like a `SegmentToggle` segment.
@MainActor
final class ChipToggle: NSView {
    let title: String
    var isOn = false { didSet { if oldValue != isOn { needsDisplay = true } } }
    var colors: UIColors? { didSet { needsDisplay = true } }
    var onChange: ((Bool) -> Void)?
    var font = UIFonts.scope(14) { didSet { invalidateIntrinsicContentSize(); needsDisplay = true } }

    init(title: String) {
        self.title = title
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override var intrinsicContentSize: NSSize {
        NSSize(width: ceil((title as NSString).size(withAttributes: [.font: font]).width) + 24, height: Metrics.scopeBarHeight)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let c = colors else { return }
        let bg = NSBezierPath(roundedRect: bounds, xRadius: bounds.height / 2, yRadius: bounds.height / 2)
        c.folderRowBackground.withAlphaComponent(0.9).setFill()
        bg.fill()
        if isOn {
            let r = bounds.insetBy(dx: 2, dy: 2)
            c.accent.setFill()
            NSBezierPath(roundedRect: r, xRadius: r.height / 2, yRadius: r.height / 2).fill()
        }
        let color: NSColor = isOn ? SegmentToggle.labelColor(on: c.accent) : c.text.withAlphaComponent(0.75)
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        let s = (title as NSString).size(withAttributes: attrs)
        (title as NSString).draw(at: NSPoint(x: bounds.midX - s.width / 2, y: bounds.midY - s.height / 2), withAttributes: attrs)
    }

    override func mouseDown(with event: NSEvent) {}

    override func mouseUp(with event: NSEvent) {
        guard bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        isOn.toggle()
        onChange?(isOn)
    }

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .checkBox }
    override func accessibilityValue() -> Any? { isOn ? 1 : 0 }
    override func accessibilityPerformPress() -> Bool {
        isOn.toggle()
        onChange?(isOn)
        return true
    }
}

/// Two-segment pill toggle drawn by hand.
@MainActor
final class SegmentToggle: NSView {
    var titles: [String] = ["A", "B"] { didSet { invalidateIntrinsicContentSize(); needsDisplay = true } }
    var selectedIndex = 0 { didSet { needsDisplay = true } }
    var colors: UIColors? { didSet { needsDisplay = true } }
    var onChange: ((Int) -> Void)?
    var font = UIFonts.scope(14) { didSet { invalidateIntrinsicContentSize(); needsDisplay = true } }

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private func segmentWidth(_ i: Int) -> CGFloat {
        ceil((titles[i] as NSString).size(withAttributes: [.font: font]).width) + 20
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: titles.indices.map(segmentWidth).reduce(0, +) + 4, height: Metrics.scopeBarHeight)
    }

    private func segmentRects() -> [NSRect] {
        let total = titles.indices.map(segmentWidth).reduce(0, +)
        let scale = total > 0 ? (bounds.width - 4) / total : 1
        var x: CGFloat = 2
        return titles.indices.map { i in
            let w = segmentWidth(i) * scale
            defer { x += w }
            return NSRect(x: x, y: 2, width: w, height: bounds.height - 4)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let c = colors else { return }
        let bg = NSBezierPath(roundedRect: bounds, xRadius: bounds.height / 2, yRadius: bounds.height / 2)
        c.folderRowBackground.withAlphaComponent(0.9).setFill()
        bg.fill()
        for (i, r) in segmentRects().enumerated() {
            let selected = i == selectedIndex
            if selected {
                c.accent.setFill()
                NSBezierPath(roundedRect: r, xRadius: r.height / 2, yRadius: r.height / 2).fill()
            }
            let color: NSColor = selected ? Self.labelColor(on: c.accent) : c.text.withAlphaComponent(0.75)
            let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
            let s = (titles[i] as NSString).size(withAttributes: attrs)
            (titles[i] as NSString).draw(at: NSPoint(x: r.midX - s.width / 2, y: r.midY - s.height / 2), withAttributes: attrs)
        }
    }

    /// Black or white, whichever has more contrast on `fill` (WCAG relative luminance).
    static func labelColor(on fill: NSColor) -> NSColor {
        guard let c = fill.usingColorSpace(.sRGB) else { return .white }
        func lin(_ v: CGFloat) -> CGFloat { v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
        let l = 0.2126 * lin(c.redComponent) + 0.7152 * lin(c.greenComponent) + 0.0722 * lin(c.blueComponent)
        // Contrast with white = 1.05 / (l + 0.05); with black = (l + 0.05) / 0.05.
        return 1.05 / (l + 0.05) >= (l + 0.05) / 0.05 ? .white : .black
    }

    override func mouseDown(with event: NSEvent) {}

    override func mouseUp(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        guard let i = segmentRects().firstIndex(where: { $0.contains(p) }), i != selectedIndex else { return }
        selectedIndex = i
        onChange?(i)
    }

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .radioGroup }
    override func accessibilityLabel() -> String? { "Search scope: \(titles[selectedIndex])" }
    override func accessibilityPerformPress() -> Bool {
        selectedIndex = selectedIndex == 0 ? 1 : 0
        onChange?(selectedIndex)
        return true
    }
}
