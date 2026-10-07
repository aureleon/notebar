import AppKit
import NoteBarCore

/// Non-activating panel that never becomes key, so the editor keeps keyboard focus.
final class ToolbarPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Button that reacts to the first click in a non-key window.
final class ToolbarButton: NSButton {
    var formatAction: FormatAction?
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// The formatting toolbar: a glass pill shown just above the selection of the focused editor.
/// Order: copy · list | text color · heading | B · I · highlight · S · U · link | inline code · code block | clear.
@MainActor
final class FormattingToolbar: NSObject {
    static let shared = FormattingToolbar()

    private var panel: ToolbarPanel?
    private weak var owner: MarkdownNoteEditor?
    private weak var parentWindow: NSWindow?
    private var colorButton: ToolbarButton?

    static let groups: [[(FormatAction, String, String)]] = [
        [(.copy, "doc.on.doc", "Copy"), (.bulletList, "list.bullet", "Bulleted List")],
        [(.textColor, "paintpalette", "Text Color"), (.heading, "textformat.size", "Heading")],
        [(.bold, "bold", "Bold"), (.italic, "italic", "Italic"), (.highlight, "highlighter", "Highlight"),
         (.strikethrough, "strikethrough", "Strikethrough"), (.underline, "underline", "Underline"), (.link, "link", "Link")],
        [(.inlineCode, "chevron.left.forwardslash.chevron.right", "Inline Code"), (.codeBlock, "curlybraces", "Code Block")],
        [(.clearFormatting, "eraser", "Clear Formatting")],
    ]

    var isVisible: Bool { panel?.isVisible == true }
    var currentOwner: MarkdownNoteEditor? { isVisible ? owner : nil }

    func makePanelForTesting() -> ToolbarPanel { makePanel() }

    private func makePanel() -> ToolbarPanel {
        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.spacing = 1
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 8, bottom: 0, right: 8)
        stack.alignment = .centerY
        for (gi, group) in Self.groups.enumerated() {
            if gi > 0 {
                let sep = NSBox()
                sep.boxType = .custom
                sep.borderWidth = 0
                sep.fillColor = NSColor.separatorColor
                sep.translatesAutoresizingMaskIntoConstraints = false
                sep.widthAnchor.constraint(equalToConstant: 1).isActive = true
                sep.heightAnchor.constraint(equalToConstant: 16).isActive = true
                stack.addArrangedSubview(sep)
                stack.setCustomSpacing(5, after: stack.arrangedSubviews[stack.arrangedSubviews.count - 2])
                stack.setCustomSpacing(5, after: sep)
            }
            for (action, symbol, tip) in group {
                let b = ToolbarButton()
                b.formatAction = action
                b.bezelStyle = .accessoryBarAction
                b.isBordered = false
                b.imagePosition = .imageOnly
                let cfg = NSImage.SymbolConfiguration(pointSize: 12.5, weight: .medium)
                if let img = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)?.withSymbolConfiguration(cfg) {
                    b.image = img
                } else {
                    b.title = String(tip.prefix(1))
                    b.imagePosition = .noImage
                }
                b.contentTintColor = .labelColor
                b.toolTip = tip
                b.target = self
                b.action = #selector(buttonPressed(_:))
                b.refusesFirstResponder = true
                b.translatesAutoresizingMaskIntoConstraints = false
                b.widthAnchor.constraint(equalToConstant: 24).isActive = true
                b.heightAnchor.constraint(equalToConstant: 26).isActive = true
                if action == .textColor { colorButton = b }
                stack.addArrangedSubview(b)
            }
        }
        let height: CGFloat = 34
        let size = NSSize(width: ceil(stack.fittingSize.width), height: height)
        let glass = NSGlassEffectView(frame: NSRect(origin: .zero, size: size))
        glass.cornerRadius = height / 2
        glass.contentView = stack
        stack.frame = glass.bounds
        stack.autoresizingMask = [.width, .height]

        let p = ToolbarPanel(contentRect: NSRect(origin: .zero, size: size),
                             styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        p.isFloatingPanel = true
        p.hidesOnDeactivate = false
        p.becomesKeyOnlyIfNeeded = true
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.isReleasedWhenClosed = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        p.contentView = glass
        p.animationBehavior = .utilityWindow
        return p
    }

    /// Shows the toolbar for `editor` above `selectionRect` (screen coordinates).
    func show(for editor: MarkdownNoteEditor, selectionRect: NSRect) {
        guard let window = editor.window else { return }
        if panel == nil { panel = makePanel() }
        guard let panel else { return }
        if owner !== editor || parentWindow !== window {
            parentWindow?.removeChildWindow(panel)
            owner = editor
            parentWindow = window
        }
        panel.appearance = editor.effectiveAppearance
        let size = panel.frame.size
        let screen = window.screen ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 4000, height: 4000)
        var x = selectionRect.midX - size.width / 2
        x = min(max(x, visible.minX + 6), visible.maxX - size.width - 6)
        var y = selectionRect.maxY + 6
        if y + size.height > visible.maxY - 4 { y = selectionRect.minY - size.height - 6 }
        panel.level = window.level
        panel.setFrameOrigin(NSPoint(x: round(x), y: round(y)))
        if panel.parent == nil { window.addChildWindow(panel, ordered: .above) }
        panel.orderFront(nil)
    }

    /// Hides the toolbar (only if it belongs to `editor`, when given).
    func hide(for editor: MarkdownNoteEditor?) {
        guard let panel, panel.isVisible || panel.parent != nil else { return }
        if let editor, owner !== editor { return }
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
    }

    @objc private func buttonPressed(_ sender: ToolbarButton) {
        guard let owner, let action = sender.formatAction else { return }
        if action == .textColor {
            owner.showColorMenu(relativeTo: sender)
            return
        }
        owner.perform(action)
        if action == .copy { hide(for: owner) }
    }
}

/// Diagnostics for offscreen snapshot tooling.
@MainActor
public enum EditorDiagnostics {
    /// A fresh formatting toolbar content view (glass pill with its buttons), not attached to any window.
    public static func toolbarContentView() -> NSView {
        FormattingToolbar.shared.makeContentViewForTesting()
    }
}

extension FormattingToolbar {
    /// The toolbar's buttons on a plain pill (glass does not render in offscreen snapshots).
    func makeContentViewForTesting() -> NSView {
        let p = makePanelForTesting()
        guard let glass = p.contentView as? NSGlassEffectView, let stack = glass.contentView else { return NSView() }
        glass.contentView = nil
        let pill = TestPill(frame: glass.frame)
        stack.frame = pill.bounds
        pill.addSubview(stack)
        return pill
    }

    final class TestPill: NSView {
        override func draw(_ dirtyRect: NSRect) {
            NSColor.windowBackgroundColor.setFill()
            NSBezierPath(roundedRect: bounds, xRadius: bounds.height / 2, yRadius: bounds.height / 2).fill()
        }
    }
}
