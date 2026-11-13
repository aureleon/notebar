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

/// A menu item view with a row of color circles (Color & Mode menu / Color submenu).
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

    /// Color & Mode button (and `gc`): color circles, then the note mode.
    static func gearMenu(for note: Note, actions: NoteActions) -> NSMenu {
        let m = NSMenu()
        m.autoenablesItems = false
        m.addItem(.sectionHeader(title: "Color"))
        m.addItem(colorRowItem(current: note.color, env: actions.env) { actions.setColor($0, for: note.id) })
        m.addItem(.separator())
        m.addItem(.sectionHeader(title: "Mode"))
        for item in modeItems(current: note.mode, onPick: { actions.setMode($0, for: note.id) }) { m.addItem(item) }
        // Pin and fold have their own buttons on the card (and stay in the right-click menu).
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
        // To another folder: an existing one (submenu) or a new one.
        let folderItem = NSMenuItem(title: "Move to Folder", action: nil, keyEquivalent: "")
        folderItem.image = Symbols.image("folder", size: 13)
        let sub = NSMenu()
        sub.autoenablesItems = false
        for f in env.store.folders() {
            let item = ClosureMenuItem(f.name, key: "", symbol: "folder", state: f.id == note.folderId ? .on : .off,
                                       enabled: f.id != note.folderId) { actions.move(note.id, toFolder: f.id) }
            sub.addItem(item)
        }
        folderItem.submenu = sub
        m.addItem(folderItem)
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
        return m
    }

    /// Recently Deleted in the "…" menu of the header: every trashed folder and note with Restore / Delete Now, then Empty.
    static func trashMenu(actions: NoteActions) -> NSMenu {
        let m = NSMenu()
        m.autoenablesItems = false
        let store = actions.env.store
        let ago = RelativeDateTimeFormatter()
        ago.unitsStyle = .full
        func when(_ d: Date?) -> String { d.map { "Deleted " + ago.localizedString(for: $0, relativeTo: Date()) } ?? "" }
        func item(_ title: String, symbol: String, subtitle: String, restore: @escaping () -> Void, delete: @escaping () -> Void) -> NSMenuItem {
            let it = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            it.image = Symbols.image(symbol, size: 13)
            it.subtitle = subtitle
            let sub = NSMenu()
            sub.autoenablesItems = false
            sub.addItem(ClosureMenuItem("Restore", key: "", symbol: "arrow.uturn.backward", handler: restore))
            sub.addItem(ClosureMenuItem("Delete Now", key: "", symbol: "trash", handler: delete))
            it.submenu = sub
            return it
        }
        let folders = store.trashedFolders(), notes = store.trashedNotes()
        if !folders.isEmpty { m.addItem(.sectionHeader(title: "Folders")) }
        for f in folders {
            let n = store.noteCount(inTrashedFolder: f.id)
            m.addItem(item(f.name, symbol: "folder", subtitle: "\(n) \(n == 1 ? "note" : "notes") · " + when(f.deletedAt),
                           restore: { actions.restoreFolderUndoably(f.id, name: "Restore Folder") },
                           delete: { actions.deleteForGood(folder: f.id) }))
        }
        if !notes.isEmpty { m.addItem(.sectionHeader(title: "Notes")) }
        let names = Dictionary(uniqueKeysWithValues: (store.folders() + store.archivedFolders()).map { ($0.id, $0.name) })
        for n in notes {
            let title = n.title.isEmpty ? "Untitled" : String(n.title.prefix(60))
            let place = n.scratchDay.map { "Scratch, \(actions.env.scratch.title(for: $0)) · " } ?? names[n.folderId].map { "In \($0) · " }
            m.addItem(item(title, symbol: "doc.text", subtitle: (place ?? "") + when(n.deletedAt),
                           restore: { actions.restoreNoteUndoably(n.id, name: "Restore Note") },
                           delete: { actions.deleteForGood(note: n.id) }))
        }
        m.addItem(.separator())
        m.addItem(ClosureMenuItem("Empty Recently Deleted…", key: "", symbol: "trash.slash",
                                  enabled: !folders.isEmpty || !notes.isEmpty) { actions.emptyTrash() })
        return m
    }

    /// Save as Note (Scratch cards): a copy of the note at the top of the picked folder.
    static func saveAsNoteMenu(for id: NoteID, actions: NoteActions) -> NSMenu {
        let m = NSMenu()
        m.autoenablesItems = false
        m.addItem(.sectionHeader(title: "Save a Copy in"))
        for f in actions.env.store.folders() {
            m.addItem(ClosureMenuItem(f.name, key: "", symbol: "folder") { actions.saveScratchAsNote(id, toFolder: f.id) })
        }
        return m
    }

    /// Right click in an entry of a Scratch note: a copy of that entry's text as a note.
    static func saveEntryAsNoteItem(text: String, noteID id: NoteID, actions: NoteActions) -> NSMenuItem {
        let item = NSMenuItem(title: "Save Entry as Note", action: nil, keyEquivalent: "")
        let m = NSMenu()
        m.autoenablesItems = false
        m.addItem(.sectionHeader(title: "Save a Copy in"))
        for f in actions.env.store.folders() {
            m.addItem(ClosureMenuItem(f.name, key: "", symbol: "folder") {
                actions.saveScratchAsNote(id, toFolder: f.id, entryText: text)
            })
        }
        item.submenu = m
        return item
    }

    /// Right click on a Scratch card.
    static func scratchContextMenu(for note: Note, actions: NoteActions, role: ScratchRole) -> NSMenu {
        let m = NSMenu()
        m.autoenablesItems = false
        let env = actions.env
        let save = NSMenuItem(title: "Save as Note", action: nil, keyEquivalent: "")
        save.image = Symbols.image("doc.badge.plus", size: 13)
        save.submenu = saveAsNoteMenu(for: note.id, actions: actions)
        m.addItem(save)
        m.addItem(ClosureMenuItem("Copy Text", key: "", symbol: "doc.on.doc") { actions.copyText(note.id) })
        m.addItem(.separator())
        let isExpanded = actions.root?.notesList.expandedNoteID == note.id
        m.addItem(ClosureMenuItem(isExpanded ? "Collapse" : "Expand", key: "e", modifiers: [.command, .shift],
                                  symbol: isExpanded ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right") {
            actions.toggleExpand(note.id)
        })
        if role == .today {
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
        }
        m.addItem(.separator())
        if role == .today {
            m.addItem(ClosureMenuItem("Clear Scratch", key: "", symbol: "eraser", enabled: !note.body.isEmpty) {
                actions.clearScratch(note.id)
            })
        } else {
            m.addItem(ClosureMenuItem("Delete This Day", key: "", symbol: "trash") { actions.delete(note.id) })
        }
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
        let isExpanded = actions.root?.notesList.expandedNoteID == note.id
        m.addItem(ClosureMenuItem(isExpanded ? "Collapse" : "Expand", key: "e", modifiers: [.command, .shift],
                                  symbol: isExpanded ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right") {
            actions.toggleExpand(note.id)
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
        if !env.store.isInArchive(note) {
            // Archived notes (also those of an archived folder) are not moved (unarchive first).
            let moveItem = NSMenuItem(title: "Move", action: nil, keyEquivalent: "")
            moveItem.image = Symbols.image("arrow.up.and.down.and.arrow.left.and.right", size: 13)
            moveItem.submenu = moveMenu(for: note, actions: actions)
            m.addItem(moveItem)
        }
        m.addItem(.separator())
        m.addItem(ClosureMenuItem("Copy Text", key: "", symbol: "doc.on.doc") { actions.copyText(note.id) })
        m.addItem(.separator())
        m.addItem(ClosureMenuItem("Delete Note", key: "", symbol: "trash") { actions.delete(note.id) })
        return m
    }

    /// Right click on a folder chip in the header. (A click opens the folder, so there is no Open.)
    static func folderContextMenu(for folder: Folder, actions: NoteActions) -> NSMenu {
        let m = NSMenu()
        m.autoenablesItems = false
        let env = actions.env
        m.addItem(ClosureMenuItem("New Folder", key: "", symbol: "folder.badge.plus") { actions.newFolder() })
        m.addItem(.separator())
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
        m.addItem(ClosureMenuItem("Archive Folder", key: "", symbol: "archivebox",
                                  enabled: env.store.folders().count > 1) {
            actions.toggleArchiveFolder(folder.id)
        })
        m.addItem(ClosureMenuItem("Delete Folder…", key: "", symbol: "trash", enabled: env.store.folders().count > 1) {
            actions.deleteFolder(folder.id)
        })
        return m
    }

    /// Archive in the "…" menu of the header: the archived notes, then every archived folder with
    /// Open / Unarchive / Delete.
    static func archiveMenu(actions: NoteActions) -> NSMenu {
        let m = NSMenu()
        m.autoenablesItems = false
        let store = actions.env.store
        let ago = RelativeDateTimeFormatter()
        ago.unitsStyle = .full
        func count(_ n: Int) -> String { "\(n) \(n == 1 ? "note" : "notes")" }
        let notes = ClosureMenuItem("Archived Notes", key: "", symbol: "doc.text") { actions.root?.showArchive() }
        notes.subtitle = count(store.archivedNotes().count)
        m.addItem(notes)
        let folders = store.archivedFolders()
        if !folders.isEmpty { m.addItem(.sectionHeader(title: "Folders")) }
        for f in folders {
            let it = NSMenuItem(title: f.name, action: nil, keyEquivalent: "")
            it.image = Symbols.image("folder", size: 13)
            it.subtitle = count(store.noteCount(in: f.id))
                + (f.archivedAt.map { " · Archived " + ago.localizedString(for: $0, relativeTo: Date()) } ?? "")
            let sub = NSMenu()
            sub.autoenablesItems = false
            sub.addItem(ClosureMenuItem("Open", key: "", symbol: "folder") { actions.root?.showArchivedFolder(f.id) })
            sub.addItem(ClosureMenuItem("Unarchive", key: "", symbol: "tray.and.arrow.up") { actions.toggleArchiveFolder(f.id) })
            sub.addItem(.separator())
            sub.addItem(ClosureMenuItem("Delete Folder…", key: "", symbol: "trash") { actions.deleteFolder(f.id) })
            it.submenu = sub
            m.addItem(it)
        }
        return m
    }
}
