import AppKit
import NoteBarCore

/// NSMenuItem that runs a closure.
final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(_ title: String, key: String = "", modifiers: NSEvent.ModifierFlags = [.command],
         symbol: String? = nil, state: NSControl.StateValue = .off, enabled: Bool = true,
         handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(fire), keyEquivalent: key)
        target = self
        keyEquivalentModifierMask = modifiers
        self.state = state
        isEnabled = enabled
        if let symbol { image = Symbols.image(symbol, size: 13) }
    }

    required init(coder: NSCoder) { fatalError() }

    @objc private func fire() { handler() }

    override var isEnabled: Bool {
        get { super.isEnabled }
        set { super.isEnabled = newValue }
    }
}

/// A menu item view with a row of color circles (gear menu / Color submenu).
final class ColorRowView: NSView {
    private let colors = NoteColor.allCases
    private let current: NoteColor
    private let swatch: (NoteColor) -> NSColor
    private let onPick: (NoteColor) -> Void
    private var hoverIndex: Int? { didSet { if oldValue != hoverIndex { needsDisplay = true } } }
    private let circle: CGFloat = 18
    private let spacing: CGFloat = 8
    private let insetX: CGFloat = 14

    init(current: NoteColor, swatch: @escaping (NoteColor) -> NSColor, onPick: @escaping (NoteColor) -> Void) {
        self.current = current
        self.swatch = swatch
        self.onPick = onPick
        let w = insetX * 2 + CGFloat(NoteColor.allCases.count) * circle + CGFloat(NoteColor.allCases.count - 1) * spacing
        super.init(frame: NSRect(x: 0, y: 0, width: max(w, 220), height: 32))
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
        setAccessibilityRole(.group)
        setAccessibilityLabel("Note color")
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    private func rect(at i: Int) -> NSRect {
        NSRect(x: insetX + CGFloat(i) * (circle + spacing), y: (bounds.height - circle) / 2, width: circle, height: circle)
    }

    private func index(at p: NSPoint) -> Int? {
        colors.indices.first { rect(at: $0).insetBy(dx: -spacing / 2, dy: -6).contains(p) }
    }

    override func mouseMoved(with event: NSEvent) { hoverIndex = index(at: convert(event.locationInWindow, from: nil)) }
    override func mouseExited(with event: NSEvent) { hoverIndex = nil }
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {
        guard let i = index(at: convert(event.locationInWindow, from: nil)) else { return }
        let c = colors[i]
        enclosingMenuItem?.menu?.cancelTracking()
        onPick(c)
    }

    override func draw(_ dirtyRect: NSRect) {
        for (i, c) in colors.enumerated() {
            let r = rect(at: i)
            if hoverIndex == i {
                NSColor.labelColor.withAlphaComponent(0.12).setFill()
                NSBezierPath(ovalIn: r.insetBy(dx: -3, dy: -3)).fill()
            }
            let p = NSBezierPath(ovalIn: r)
            if c == .none {
                NSColor.textBackgroundColor.setFill(); p.fill()
                NSColor.tertiaryLabelColor.setStroke(); p.lineWidth = 1; p.stroke()
                let slash = NSBezierPath()
                slash.move(to: NSPoint(x: r.minX + 4, y: r.maxY - 4))
                slash.line(to: NSPoint(x: r.maxX - 4, y: r.minY + 4))
                NSColor.systemRed.withAlphaComponent(0.8).setStroke(); slash.lineWidth = 1.5; slash.stroke()
            } else {
                swatch(c).setFill(); p.fill()
                NSColor.black.withAlphaComponent(0.08).setStroke(); p.lineWidth = 0.5; p.stroke()
            }
            if c == current {
                let ring = NSBezierPath(ovalIn: r.insetBy(dx: -2.5, dy: -2.5))
                NSColor.controlAccentColor.setStroke(); ring.lineWidth = 1.5; ring.stroke()
            }
        }
    }
}

/// Builds every menu of the notes UI.
@MainActor
enum MenuBuilder {
    static func arrowKey(_ up: Bool) -> String {
        String(Character(UnicodeScalar(up ? NSUpArrowFunctionKey : NSDownArrowFunctionKey)!))
    }

    static func colorRowItem(current: NoteColor, env: AppEnvironment, onPick: @escaping (NoteColor) -> Void) -> NSMenuItem {
        let item = NSMenuItem()
        item.view = ColorRowView(current: current, swatch: { env.themes.swatch($0) }, onPick: onPick)
        return item
    }

    static func colorSubmenu(current: NoteColor, env: AppEnvironment, onPick: @escaping (NoteColor) -> Void) -> NSMenu {
        let m = NSMenu()
        m.addItem(colorRowItem(current: current, env: env, onPick: onPick))
        m.addItem(.separator())
        for c in NoteColor.allCases {
            let item = ClosureMenuItem(c.displayName, key: "", state: c == current ? .on : .off) { onPick(c) }
            item.image = colorDot(c, env: env)
            m.addItem(item)
        }
        return m
    }

    static func colorDot(_ c: NoteColor, env: AppEnvironment) -> NSImage {
        NSImage(size: NSSize(width: 12, height: 12), flipped: false) { r in
            let p = NSBezierPath(ovalIn: r.insetBy(dx: 1, dy: 1))
            if c == .none {
                NSColor.tertiaryLabelColor.setStroke(); p.lineWidth = 1; p.stroke()
            } else {
                env.themes.swatch(c).setFill(); p.fill()
            }
            return true
        }
    }

    static func modeItems(current: NoteMode, onPick: @escaping (NoteMode) -> Void) -> [NSMenuItem] {
        NoteMode.allCases.map { mode in
            ClosureMenuItem(mode.displayName, key: "", state: mode == current ? .on : .off) { onPick(mode) }
        }
    }

    /// Gear button: color circles, then the note mode.
    static func gearMenu(for note: Note, actions: NoteActions) -> NSMenu {
        let m = NSMenu()
        m.autoenablesItems = false
        m.addItem(.sectionHeader(title: "Color"))
        m.addItem(colorRowItem(current: note.color, env: actions.env) { actions.setColor($0, for: note.id) })
        m.addItem(.separator())
        m.addItem(.sectionHeader(title: "Mode"))
        for item in modeItems(current: note.mode, onPick: { actions.setMode($0, for: note.id) }) { m.addItem(item) }
        m.addItem(.separator())
        m.addItem(ClosureMenuItem(note.isFolded ? "Unfold" : "Fold", key: "", symbol: note.isFolded ? "rectangle.expand.vertical" : "rectangle.compress.vertical") {
            actions.toggleFold(note.id)
        })
        m.addItem(ClosureMenuItem(note.isPinned ? "Unpin" : "Pin", key: "", symbol: note.isPinned ? "pin.slash" : "pin") {
            actions.togglePin(note.id)
        })
        return m
    }

    /// Aa button: formatting commands sent to the editor.
    static func formatMenu(perform: @escaping (FormatAction) -> Void) -> NSMenu {
        let m = NSMenu()
        m.autoenablesItems = false
        func add(_ title: String, _ a: FormatAction, _ symbol: String, key: String = "", mods: NSEvent.ModifierFlags = [.command]) {
            m.addItem(ClosureMenuItem(title, key: key, modifiers: mods, symbol: symbol) { perform(a) })
        }
        add("Bold", .bold, "bold", key: "b")
        add("Italic", .italic, "italic", key: "i")
        add("Underline", .underline, "underline", key: "u")
        add("Strikethrough", .strikethrough, "strikethrough", key: "x", mods: [.command, .shift])
        add("Highlight", .highlight, "highlighter", key: "h", mods: [.command, .shift])
        add("Text Color", .textColor, "paintpalette")
        m.addItem(.separator())
        add("Heading", .heading, "textformat.size")
        add("Quote", .quote, "text.quote")
        add("Bulleted List", .bulletList, "list.bullet")
        add("Numbered List", .numberedList, "list.number")
        add("Checklist", .checklist, "checklist")
        m.addItem(.separator())
        add("Link", .link, "link", key: "k")
        add("Inline Code", .inlineCode, "chevron.left.forwardslash.chevron.right")
        add("Code Block", .codeBlock, "curlybraces")
        m.addItem(.separator())
        add("Clear Formatting", .clearFormatting, "eraser")
        add("Copy Note Text", .copy, "doc.on.doc")
        return m
    }

    /// Move menu (⌘⇧M, card context menu).
    static func moveMenu(for note: Note, actions: NoteActions) -> NSMenu {
        let m = NSMenu()
        m.autoenablesItems = false
        let env = actions.env
        m.addItem(ClosureMenuItem("Move to a New Folder…", key: "m", modifiers: [.option, .command], symbol: "folder.badge.plus") {
            actions.moveToNewFolder(note.id)
        })
        m.addItem(.sectionHeader(title: "Within Folder"))
        let list = env.store.notes(in: note.folderId)
        let idx = list.firstIndex { $0.id == note.id } ?? 0
        let zone = actions.zone(for: note, in: list)
        m.addItem(ClosureMenuItem("Move to Top", key: "", symbol: "arrow.up.to.line", enabled: idx > zone.lowerBound) {
            actions.move(note.id, .top)
        })
        m.addItem(ClosureMenuItem("Move Up", key: arrowKey(true), modifiers: [.option, .shift, .command], symbol: "arrow.up",
                                  enabled: idx > zone.lowerBound) { actions.move(note.id, .up) })
        m.addItem(ClosureMenuItem("Move Down", key: arrowKey(false), modifiers: [.option, .shift, .command], symbol: "arrow.down",
                                  enabled: idx < zone.upperBound) { actions.move(note.id, .down) })
        m.addItem(ClosureMenuItem("Move to Bottom", key: "", symbol: "arrow.down.to.line", enabled: idx < zone.upperBound) {
            actions.move(note.id, .bottom)
        })
        m.addItem(.sectionHeader(title: "Move to Folder"))
        let folderItem = NSMenuItem(title: "Folder", action: nil, keyEquivalent: "")
        folderItem.image = Symbols.image("folder", size: 13)
        let sub = NSMenu()
        for f in env.store.folders() {
            let item = ClosureMenuItem(f.name, key: "", symbol: "folder", state: f.id == note.folderId ? .on : .off,
                                       enabled: f.id != note.folderId) { actions.move(note.id, toFolder: f.id) }
            sub.addItem(item)
        }
        folderItem.submenu = sub
        m.addItem(folderItem)
        return m
    }

    /// Right click on a card.
    static func cardContextMenu(for note: Note, actions: NoteActions, inSearch: Bool) -> NSMenu {
        let m = NSMenu()
        m.autoenablesItems = false
        let env = actions.env
        if inSearch {
            m.addItem(ClosureMenuItem("Show in Folder", key: "", symbol: "folder") { actions.root?.revealFromSearch(note.id) })
            m.addItem(.separator())
        }
        m.addItem(ClosureMenuItem(note.isPinned ? "Unpin" : "Pin", key: "", symbol: note.isPinned ? "pin.slash" : "pin") {
            actions.togglePin(note.id)
        })
        m.addItem(ClosureMenuItem(note.isFolded ? "Unfold" : "Fold", key: "", symbol: note.isFolded ? "rectangle.expand.vertical" : "rectangle.compress.vertical") {
            actions.toggleFold(note.id)
        })
        let colorItem = NSMenuItem(title: "Color", action: nil, keyEquivalent: "")
        colorItem.image = Symbols.image("paintpalette", size: 13)
        colorItem.submenu = colorSubmenu(current: note.color, env: env) { actions.setColor($0, for: note.id) }
        m.addItem(colorItem)
        let modeItem = NSMenuItem(title: "Mode", action: nil, keyEquivalent: "")
        modeItem.image = Symbols.image("textformat", size: 13)
        let modes = NSMenu()
        for item in modeItems(current: note.mode, onPick: { actions.setMode($0, for: note.id) }) { modes.addItem(item) }
        modeItem.submenu = modes
        m.addItem(modeItem)
        let moveItem = NSMenuItem(title: "Move", action: nil, keyEquivalent: "")
        moveItem.image = Symbols.image("arrow.up.and.down.and.arrow.left.and.right", size: 13)
        moveItem.submenu = moveMenu(for: note, actions: actions)
        m.addItem(moveItem)
        m.addItem(.separator())
        m.addItem(ClosureMenuItem("Copy Text", key: "", symbol: "doc.on.doc") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(env.store.note(id: note.id)?.body ?? note.body, forType: .string)
        })
        m.addItem(ClosureMenuItem("Copy as Image", key: "", symbol: "photo") { actions.copyImage(note.id) })
        m.addItem(ClosureMenuItem("Export as Image…", key: "", symbol: "square.and.arrow.down") { actions.saveImage(note.id) })
        m.addItem(.separator())
        m.addItem(ClosureMenuItem("Delete Note", key: "", symbol: "trash") { actions.delete(note.id, confirm: false) })
        return m
    }

    /// Right click on a folder row (or the folder list background when `folder == nil`).
    static func folderContextMenu(for folder: Folder?, actions: NoteActions) -> NSMenu {
        let m = NSMenu()
        m.autoenablesItems = false
        let env = actions.env
        m.addItem(ClosureMenuItem("New Folder", key: "", symbol: "folder.badge.plus") { actions.newFolder() })
        guard let folder else { return m }
        m.addItem(.separator())
        m.addItem(ClosureMenuItem("Open", key: "", symbol: "folder") { actions.root?.showFolder(folder.id) })
        m.addItem(ClosureMenuItem("New Note in Folder", key: "", symbol: "square.and.pencil") {
            actions.root?.showFolder(folder.id)
            actions.root?.createNewNote()
        })
        m.addItem(ClosureMenuItem("Rename", key: "", symbol: "pencil") { actions.root?.beginRenameFolder(folder.id) })
        m.addItem(ClosureMenuItem(folder.isPinned ? "Unpin" : "Pin", key: "", symbol: folder.isPinned ? "pin.slash" : "pin") {
            actions.togglePinFolder(folder.id)
        })
        let colorItem = NSMenuItem(title: "Color", action: nil, keyEquivalent: "")
        colorItem.image = Symbols.image("paintpalette", size: 13)
        colorItem.submenu = colorSubmenu(current: folder.color, env: env) { actions.setFolderColor($0, folder.id) }
        m.addItem(colorItem)
        m.addItem(.separator())
        m.addItem(ClosureMenuItem("Delete Folder…", key: "", symbol: "trash", enabled: env.store.folders().count > 1) {
            actions.deleteFolder(folder.id)
        })
        return m
    }

    /// Export button: save or copy the note as an image.
    static func exportMenu(for note: Note, actions: NoteActions) -> NSMenu {
        let m = NSMenu()
        m.autoenablesItems = false
        m.addItem(ClosureMenuItem("Save as PNG…", key: "", symbol: "square.and.arrow.down") { actions.saveImage(note.id) })
        m.addItem(ClosureMenuItem("Copy Image", key: "", symbol: "doc.on.doc") { actions.copyImage(note.id) })
        return m
    }
}
