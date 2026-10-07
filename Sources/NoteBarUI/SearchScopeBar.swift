import AppKit
import NoteBarCore

/// Row above the search results: result count + "This Folder | All Folders" toggle.
@MainActor
final class SearchScopeBar: NSView {
    var onToggle: ((Bool) -> Void)?
    private let env: AppEnvironment
    private let countLabel = PassthroughLabel()
    private let toggle = SegmentToggle()

    init(env: AppEnvironment) {
        self.env = env
        super.init(frame: NSRect(x: 0, y: 0, width: 280, height: 26))
        countLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        addSubview(countLabel)
        addSubview(toggle)
        toggle.onChange = { [weak self] idx in self?.onToggle?(idx == 1) }
        restyle()
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var fittingSize: NSSize { NSSize(width: frame.width, height: 26) }

    /// `folderName == nil` hides the toggle (searching from the folder list always covers all folders).
    func update(resultCount: Int?, allFolders: Bool, folderName: String?) {
        if let n = resultCount {
            countLabel.stringValue = n == 1 ? "1 result" : "\(n) results"
        } else {
            countLabel.stringValue = allFolders ? "All folders" : "In “\(folderName ?? "")”"
        }
        toggle.isHidden = folderName == nil
        toggle.titles = [folderName.map { Self.short($0) } ?? "Folder", "All Folders"]
        toggle.selectedIndex = allFolders ? 1 : 0
        needsLayout = true
    }

    private static func short(_ s: String) -> String { s.count > 14 ? String(s.prefix(13)) + "…" : s }

    func restyle() {
        let c = env.themes.ui(effectiveAppearance)
        countLabel.textColor = c.text
        toggle.colors = c
        needsDisplay = true
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        restyle()
    }

    override func layout() {
        super.layout()
        let tw = toggle.isHidden ? 0 : min(toggle.intrinsicContentSize.width, bounds.width * 0.65)
        toggle.frame = NSRect(x: bounds.width - tw, y: 1, width: tw, height: 24)
        let lh = ceil(countLabel.intrinsicContentSize.height)
        countLabel.frame = NSRect(x: 8, y: (bounds.height - lh) / 2, width: max(0, toggle.frame.minX - 16), height: lh)
    }

    override func draw(_ dirtyRect: NSRect) {
        // Soft backing so the count is readable over any desktop.
        let c = env.themes.ui(effectiveAppearance)
        let lw = ceil(countLabel.intrinsicContentSize.width) + 16
        let r = NSRect(x: 0, y: 1, width: min(lw, bounds.width), height: 24)
        c.folderRowBackground.withAlphaComponent(0.85).setFill()
        NSBezierPath(roundedRect: r, xRadius: 12, yRadius: 12).fill()
    }
}

/// Two-segment pill toggle drawn by hand.
@MainActor
final class SegmentToggle: NSView {
    var titles: [String] = ["A", "B"] { didSet { invalidateIntrinsicContentSize(); needsDisplay = true } }
    var selectedIndex = 0 { didSet { needsDisplay = true } }
    var colors: UIColors? { didSet { needsDisplay = true } }
    var onChange: ((Int) -> Void)?
    private let font = NSFont.systemFont(ofSize: 11, weight: .semibold)

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private func segmentWidth(_ i: Int) -> CGFloat {
        ceil((titles[i] as NSString).size(withAttributes: [.font: font]).width) + 20
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: titles.indices.map(segmentWidth).reduce(0, +) + 4, height: 24)
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
            let color: NSColor = selected ? (c.isDark ? .black : .white) : c.text.withAlphaComponent(0.75)
            let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
            let s = (titles[i] as NSString).size(withAttributes: attrs)
            (titles[i] as NSString).draw(at: NSPoint(x: r.midX - s.width / 2, y: r.midY - s.height / 2), withAttributes: attrs)
        }
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
