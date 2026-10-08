import AppKit
import NoteBarCore
import NoteBarUI

// Renders the notes UI offscreen (no window is ever shown) to PNGs and runs behavior checks.
// Usage: swift run UISnapshot [/tmp/nb-snap]
// Exit code != 0 if a check fails.

@MainActor
final class Backdrop: NSView {
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        let g = NSGradient(colors: [NSColor(srgbRed: 0.05, green: 0.10, blue: 0.32, alpha: 1),
                                    NSColor(srgbRed: 0.16, green: 0.36, blue: 0.78, alpha: 1),
                                    NSColor(srgbRed: 0.07, green: 0.14, blue: 0.42, alpha: 1)])
        g?.draw(in: bounds, angle: -60)
    }
}

/// Stands in for the real editor's text view: handles ⌘1–⌘3 like `MarkdownTextView` does.
@MainActor
final class HeadingKeyTextView: NSTextView {
    var receivedHeading: Int?
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if window?.firstResponder === self, event.modifierFlags.intersection([.command, .shift, .option, .control]) == [.command],
           let ch = event.charactersIgnoringModifiers, let level = Int(ch), (1...3).contains(level) {
            receivedHeading = level
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

@MainActor
func seed(_ store: InMemoryNoteStore) -> (notes: Folder, work: Folder, ideas: Folder, empty: Folder) {
    let notes = store.folders()[0]
    let work = store.createFolder(name: "Work")
    let ideas = store.createFolder(name: "Ideas")
    let shopping = store.createFolder(name: "Shopping")
    let empty = store.createFolder(name: "Empty")
    var w = work; w.isPinned = true; store.updateFolder(w)
    var s = shopping; s.color = .green; store.updateFolder(s)

    func add(_ f: Folder, _ body: String, color: NoteColor = .none, folded: Bool = false, pinned: Bool = false,
             mode: NoteMode = .standard) {
        var n = store.createNote(in: f.id, body: body, mode: mode, position: .bottom)
        n.color = color; n.isFolded = folded; n.isPinned = pinned
        store.updateNote(n)
    }
    add(notes, "Hello!\nNoteBar is a notes panel that lives on the side of your screen.\nhttp://example.com\nIt supports a subset of Markdown, colors, tasks, pictures and file shortcuts.", color: .purple)
    add(notes, "Colors\nHere are some colors: #ffcc00 #34c759 #ff3b30\nThey are written in #rrggbb format.", color: .yellow)
    add(notes, "Today's Goals\n- [ ] Reply to e-mails\n- [ ] Review calendar\n- [x] Pay the bills\n- [ ] Do shopping", color: .purple, folded: true)
    add(notes, "Tasks\n- [x] first task\n- [ ] second task\n- [ ] third task")
    add(notes, "Breakfast Shopping List\n- [ ] Eggs\n- [ ] Avocado\n- [ ] Bacon", color: .cream, pinned: true)
    add(notes, "snippet.swift\nlet answer = 42\nprint(answer)", mode: .code)
    add(notes, "Green note\nA short one.", color: .green)
    add(notes, "Pink note\nAnother color.", color: .pink)
    add(notes, "Blue note\nBlue as the sky.", color: .blue)
    add(work, "# Meeting notes\n> Remember the agenda\n==important== `code`", color: .blue)
    add(work, "Quarterly plan\nShip the panel.\nPolish the editor.", color: .green)
    add(ideas, "Ideas\nA notes bar that slides in from the edge.")
    add(shopping, "Groceries\nMilk\nBread")
    return (notes, work, ideas, empty)
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    app.setActivationPolicy(.prohibited)
    NoteBarUIOptions.useGlass = false
    NoteBarUIOptions.animations = false

    let out = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "/tmp/nb-snap")
    try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

    let suite = "NoteBarUISnapshot"
    UserDefaults().removePersistentDomain(forName: suite)
    let settings = AppSettings(defaults: UserDefaults(suiteName: suite)!)
    let store = InMemoryNoteStore(seed: false)
    let folders = seed(store)
    let themes = ThemeManager(settings: settings, store: store)
    let env = AppEnvironment(store: store, backups: nil, settings: settings, themes: themes,
                             editorFactory: PlainNoteEditorFactory())

    let vc = NotesRootViewController(env: env)
    vc.stateDefaults = UserDefaults(suiteName: suite)!
    env.presenter = vc
    let probe = vc.probe
    // Same default width as the panel on a 1512 pt wide screen (about 27 %, clamped to 380...600).
    let panelSize = NSSize(width: PanelWidth.automatic(visibleWidth: 1512 * 0.9), height: 720)
    let backdrop = Backdrop(frame: NSRect(x: 0, y: 0, width: panelSize.width + 30, height: panelSize.height + 20))
    vc.view.frame = NSRect(x: 15, y: 10, width: panelSize.width, height: panelSize.height)
    backdrop.addSubview(vc.view)
    // Never ordered on screen: it only provides a responder chain for focus checks.
    let window = NSWindow(contentRect: backdrop.frame, styleMask: [.borderless], backing: .buffered, defer: true)
    window.contentView = backdrop
    window.isReleasedWhenClosed = false

    @MainActor func spin() { RunLoop.current.run(until: Date().addingTimeInterval(0.03)) }

    var written: [String] = []
    @MainActor func render(_ name: String, dark: Bool = false) {
        let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)!
        window.appearance = appearance
        backdrop.appearance = appearance
        spin()
        probe.layoutNow()
        spin()
        probe.layoutNow()
        backdrop.layoutSubtreeIfNeeded()
        backdrop.display()
        guard let rep = backdrop.bitmapImageRepForCachingDisplay(in: backdrop.bounds) else { return }
        backdrop.cacheDisplay(in: backdrop.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: out.appendingPathComponent(name + ".png"))
        written.append(name)
    }

    // MARK: Folder list
    vc.showFolderList()
    render("01-folders-light")
    render("02-folders-dark", dark: true)
    Check.expect(probe.folderRowsVisible, "folder list visible at root")
    Check.equal(probe.folderRowIDs.first, folders.work.id, "pinned folder first")
    Check.equal(probe.headerTitle, "NoteBar", "root title")
    Check.expect(probe.isSettingsButtonVisible, "settings button visible at root")

    // MARK: Notes list
    vc.showFolder(folders.notes.id)
    Check.equal(settings.lastFolderId, folders.notes.id, "lastFolderId remembered")
    Check.equal(probe.headerTitle, "Notes", "folder title")
    Check.expect(!probe.isSettingsButtonVisible, "settings button hidden in folder")
    let ids = store.notes(in: folders.notes.id).map(\.id)
    Check.equal(probe.displayedNoteIDs, ids, "cards follow store order")
    render("03-notes-light")
    render("04-notes-dark", dark: true)

    // Hovered footer + keyboard selection.
    let hello = ids[1]
    probe.setHovered(hello, true)
    render("05-hover-footer-light")
    Check.equal(probe.hiddenActionCount(hello), 2, "medium card shows top actions with rest in … menu")
    probe.setHovered(hello, false)
    // One-line card: only the pin and "…" fit; every action is in the menu.
    let short = store.createNote(in: folders.notes.id, body: "One line", mode: .standard, position: .top)
    probe.setHovered(short.id, true)
    render("05b-hover-short-light")
    Check.equal(probe.hiddenActionCount(short.id), 4, "one-line card puts actions in the … menu")
    probe.setHovered(short.id, false)
    store.deleteNote(id: short.id)

    // Left-bar color style.
    settings.colorStyle = .leftBar
    render("06-leftbar-light")
    render("07-leftbar-dark", dark: true)
    settings.colorStyle = .background

    // Folded card.
    let goalsID = store.notes(in: folders.notes.id).first { $0.title == "Today's Goals" }!.id
    Check.equal(probe.isCardFolded(goalsID), true, "folded card")
    Check.expect(probe.editor(of: goalsID) == nil, "folded card has no editor")
    // Folded card = title row + padding only; title matches the expanded card's title.
    let foldedH = probe.cardVisibleHeight(goalsID) ?? 0
    Check.expect(foldedH <= 58, "folded card is short (\(foldedH) pt)")
    let foldedSize = probe.cardTitlePointSize(goalsID) ?? 0
    let foldedX = probe.cardTitleOrigin(goalsID)?.x ?? -1
    probe.setHovered(goalsID, true)
    render("08-folded-hover-light")
    probe.setHovered(goalsID, false)
    probe.clickCard(goalsID)
    Check.equal(store.note(id: goalsID)?.isFolded, false, "click unfolds")
    let openSize = probe.cardTitlePointSize(goalsID) ?? 0
    Check.equal(foldedSize, openSize, "folded and open titles have the same size")
    Check.equal(foldedX, probe.cardTitleOrigin(goalsID)?.x ?? -2, "folded and open titles have the same x")
    var g = store.note(id: goalsID)!; g.isFolded = true; store.updateNote(g)

    // Selection ring.
    probe.select(hello)
    render("09-selected-light")

    // Editor identity survives body + metadata changes.
    probe.layoutNow()
    let editorBefore = probe.editorIdentity(of: hello)
    Check.expect(editorBefore != nil, "visible card has a live editor")
    store.updateNoteBody(id: hello, body: (store.note(id: hello)?.body ?? "") + "\nmore text")
    var hn = store.note(id: hello)!; hn.color = .green; store.updateNote(hn)
    Check.equal(probe.editorIdentity(of: hello), editorBefore, "editor kept across .noteBody/.note")
    hn = store.note(id: hello)!; hn.color = .purple; store.updateNote(hn)

    // Reorder keeps card views.
    let cardBefore = probe.cardIdentity(of: hello)
    probe.moveByKeyboard(hello, up: false)
    Check.equal(probe.cardIdentity(of: hello), cardBefore, "card kept across reorder")
    Check.equal(probe.displayedNoteIDs, store.notes(in: folders.notes.id).map(\.id), "order after move down")
    probe.moveNote(hello, toGap: 1)
    Check.equal(store.notes(in: folders.notes.id).map(\.id)[1], hello, "drag to gap 1 (after pinned)")
    // Unpinned notes cannot be dragged above pinned ones.
    probe.moveNote(hello, toGap: 0)
    Check.equal(store.notes(in: folders.notes.id).map(\.id)[1], hello, "pinned zone respected")

    // New note: top of the unpinned zone, focused.
    let beforeCount = store.notes(in: folders.notes.id).count
    probe.press(keyCode: 45, characters: "n", modifiers: [.command])
    let afterNotes = store.notes(in: folders.notes.id)
    Check.equal(afterNotes.count, beforeCount + 1, "⌘N creates a note")
    let newID = afterNotes.first { $0.body.isEmpty }?.id
    Check.expect(newID != nil, "new empty note exists")
    if let newID {
        Check.equal(probe.focusedNoteID, newID, "new note focused")
        Check.expect(probe.editor(of: newID)?.isEditingFocused == true, "new note editor is first responder")
        // Esc from editor -> leaves the card (no editing, no selection).
        probe.pressEscape()
        Check.expect(probe.selectedNoteID == nil, "Esc leaves the edited note")
        Check.expect(probe.focusedNoteID == nil, "Esc ends editing")
        // Delete with undo. (spin: each action is its own event in the app; undo groups by event)
        spin()
        probe.deleteWithUndo(newID)
        Check.expect(!probe.displayedNoteIDs.contains(newID), "deleted card hidden")
        Check.expect(store.note(id: newID) == nil && store.trashedNotes().contains { $0.id == newID }, "deleted note is in the trash")
        Check.expect(probe.isToastVisible, "undo toast visible")
        render("10-toast-light")
        probe.undoDelete()
        Check.expect(probe.displayedNoteIDs.contains(newID), "undo restores card")
        probe.deleteWithUndo(newID)
        probe.commitDelete()
        Check.expect(store.note(id: newID) == nil, "toast gone: the note stays deleted")
        Check.expect(!probe.isToastVisible, "toast hidden")
    }

    // Deleting the same note twice (undo in between) keeps the second deletion pending.
    let victim = store.createNote(in: folders.notes.id, body: "Victim", mode: .standard, position: .top).id
    probe.deleteWithUndo(victim)
    probe.undoDelete()
    Check.expect(!probe.isToastVisible, "undo hides the toast")
    probe.deleteWithUndo(victim)
    Check.expect(store.trashedNotes().contains { $0.id == victim }, "second delete: in the trash")
    probe.commitDelete()
    Check.expect(store.note(id: victim) == nil, "second delete stays")
    Check.expect(!probe.isToastVisible, "commit hides the toast")

    // Move to top / bottom stay inside the unpinned zone.
    let order0 = store.notes(in: folders.notes.id)
    let last = order0[order0.count - 1].id
    probe.moveToTop(last)
    Check.equal(store.notes(in: folders.notes.id)[1].id, last, "Move to Top lands below pinned notes")
    probe.moveToBottom(last)
    Check.equal(store.notes(in: folders.notes.id).last?.id, last, "Move to Bottom")

    // Arrow navigation from the list.
    probe.focusList()
    probe.select(nil)
    probe.press(keyCode: 125, characters: "\u{F701}")
    Check.equal(probe.selectedNoteID, probe.displayedNoteIDs.first, "↓ selects first card")
    probe.press(keyCode: 125, characters: "\u{F701}")
    Check.equal(probe.selectedNoteID, probe.displayedNoteIDs[1], "↓ selects next card")

    // Menus.
    let moveItems = probe.showMoveMenuItems(for: hello)
    Check.expect(moveItems.contains("Move to a New Folder…") && moveItems.contains("Move Up") && moveItems.contains("Folder"),
                 "move menu items: \(moveItems)")
    let gear = probe.gearMenuItems(for: hello)
    Check.expect(gear.contains("<colors>") && gear.contains("Standard (Markdown) ✓") && gear.contains("Code"), "gear menu: \(gear)")
    Check.expect(probe.cardMenuItems(for: hello).contains("Move"), "card menu has Move")

    // Drops.
    let before = store.notes(in: folders.notes.id).count
    probe.dropOnBackground(text: "Dropped text\nfrom another app")
    Check.equal(store.notes(in: folders.notes.id).count, before + 1, "text drop creates a note")
    let tmpFile = FileManager.default.temporaryDirectory.appendingPathComponent("nb-snap-file.txt")
    try? "hello".write(to: tmpFile, atomically: true, encoding: .utf8)
    let target = probe.displayedNoteIDs[2]
    let ok = probe.dropFiles([tmpFile], onCard: target)
    Check.expect(ok, "file drop on card")
    Check.expect(store.note(id: target)?.body.contains("(attachment:") == true, "attachment token added to card body")
    probe.dropFiles([tmpFile])
    Check.expect(store.notes(in: folders.notes.id).contains { $0.body.hasPrefix("[nb-snap-file.txt](attachment:") }, "file drop creates note")

    // Search.
    probe.setSearchQuery("note", allFolders: true)
    Check.expect(probe.isSearching, "search active")
    Check.expect(probe.cardCount >= 3, "search results across folders (\(probe.cardCount))")
    // Every result card asks for its marks (not only the first card).
    let resultIDs = probe.displayedNoteIDs
    Check.expect(resultIDs.count >= 2, "several results to mark")
    Check.expect(resultIDs.allSatisfy { probe.cardHighlightedQuery($0) == "note" }, "every result card marks the query")
    render("12-search-light")
    render("13-search-dark", dark: true)
    probe.setSearchQuery("note", allFolders: false)
    let scoped = probe.displayedNoteIDs
    Check.expect(scoped.allSatisfy { store.note(id: $0)?.folderId == folders.notes.id }, "scoped search")
    probe.setSearchQuery("")
    Check.expect(probe.displayedNoteIDs.allSatisfy { probe.cardHighlightedQuery($0) == "" }, "clearing the search clears every mark")
    probe.setSearchQuery("note", allFolders: true)
    probe.setSearchQuery("zzzz-nothing")
    render("14-search-empty-light")
    probe.pressEscape()
    Check.equal(probe.searchQuery, "", "Esc in the field clears the query first")
    Check.expect(probe.isSearching, "search still open after clearing")
    probe.pressEscape()
    Check.expect(!probe.isSearching, "Esc closes search")
    Check.equal(probe.headerTitle, "Notes", "back in origin folder")

    // Another theme.
    settings.themeId = "graphite"
    render("18-graphite-light")
    render("19-graphite-dark", dark: true)
    settings.themeId = "default"

    // Revealing a note of the origin folder from search reloads that folder.
    probe.setSearchQuery("Hello", allFolders: false)
    vc.reveal(noteId: hello, edit: false)
    Check.expect(!probe.isSearching, "reveal ends search")
    Check.equal(probe.displayedNoteIDs, store.notes(in: folders.notes.id).map(\.id), "origin folder reloaded after reveal")
    Check.equal(probe.selectedNoteID, hello, "revealed note selected")

    // Empty folder.
    vc.showFolder(folders.empty.id)
    Check.equal(probe.cardCount, 0, "empty folder")
    render("15-empty-light")

    // Reveal switches folder.
    let workNote = store.notes(in: folders.work.id)[0].id
    vc.reveal(noteId: workNote, edit: false)
    Check.equal(vc.currentFolderId, folders.work.id, "reveal switches folder")
    Check.equal(probe.selectedNoteID, workNote, "reveal selects")

    // Esc never goes up a folder: first it clears the selection, then (panel only) it hides.
    probe.focusList()
    probe.pressEscape()
    Check.expect(probe.selectedNoteID == nil, "Esc clears the selection")
    Check.expect(!probe.folderRowsVisible, "Esc does not go back to the folder list")
    probe.goBack()
    Check.expect(probe.folderRowsVisible, "back goes to the folder list")
    Check.expect(UserDefaults(suiteName: suite)!.bool(forKey: "NoteBarUI.showsFolderList"), "folder list remembered")
    Check.equal(settings.lastFolderId, folders.work.id, "lastFolderId keeps the last opened folder at the folder list")

    // ⌘1 opens the first folder.
    probe.press(keyCode: 18, characters: "1", modifiers: [.command])
    Check.equal(vc.currentFolderId, store.folders()[0].id, "⌘1 opens folder 1")

    // ⌘digits while editing: the editor gets them first (⌘1–⌘3 = headings in the real editor).
    vc.showFolder(folders.ideas.id)
    let headingProbe = HeadingKeyTextView(frame: NSRect(x: 0, y: 0, width: 50, height: 20))
    vc.view.addSubview(headingProbe)
    window.makeFirstResponder(headingProbe)
    probe.press(keyCode: 19, characters: "2", modifiers: [.command])
    Check.equal(vc.currentFolderId, folders.ideas.id, "⌘2 while editing does not switch folders")
    Check.equal(headingProbe.receivedHeading, 2, "⌘2 while editing reaches the text view")
    Check.expect(window.firstResponder === headingProbe, "⌘2 while editing keeps focus")
    // A key the editor does not use still switches folders.
    probe.press(keyCode: 21, characters: "4", modifiers: [.command])
    Check.equal(vc.currentFolderId, store.folders()[3].id, "unused ⌘4 while editing opens folder 4")
    headingProbe.removeFromSuperview()
    vc.showFolderList()
    Check.equal(settings.lastFolderId, store.folders()[3].id, "folder list keeps lastFolderId for new-note hotkeys")

    // Folder reorder across the pinned boundary: Ideas to the top of the unpinned zone.
    probe.moveFolder(folders.ideas.id, toGap: 1)
    Check.equal(store.folders().map(\.id)[1], folders.ideas.id, "folder drag below pinned folder")
    probe.moveFolder(folders.ideas.id, toGap: 0)
    Check.equal(store.folders().map(\.id)[0], folders.work.id, "pinned folder stays first")

    // Inline rename.
    probe.beginRename(folders.ideas.id)
    render("16-rename-light")
    probe.endRename()

    // New folder via + at root.
    let folderCount = store.folders().count
    probe.plus()
    Check.equal(store.folders().count, folderCount + 1, "+ at root creates a folder")
    probe.endRename()

    // Deleting the open folder returns to the list.
    let tmpFolder = store.createFolder(name: "Temp")
    vc.showFolder(tmpFolder.id)
    store.deleteFolder(id: tmpFolder.id)
    Check.expect(probe.folderRowsVisible, "deleted open folder -> folder list")

    // Performance: 200 notes.
    let big = store.createFolder(name: "Big")
    for i in 0..<200 {
        let lines = (0..<(i % 7 + 1)).map { "Line \($0) of note \(i) with some words to wrap around the card width." }
        _ = store.createNote(in: big.id, body: "Note \(i)\n" + lines.joined(separator: "\n"), mode: .standard, position: .bottom)
    }
    let t0 = Date()
    vc.showFolder(big.id)
    probe.layoutNow()
    let dt = Date().timeIntervalSince(t0)
    print(String(format: "200 notes: shown in %.0f ms, %d live editors", dt * 1000, probe.liveEditorCount))
    Check.equal(probe.cardCount, 200, "200 cards")
    Check.expect(probe.liveEditorCount < 60, "editors created lazily (\(probe.liveEditorCount))")
    Check.expect(dt < 1.5, "200 notes show fast (\(dt)s)")
    let t1 = Date()
    let firstBig = store.notes(in: big.id)[0].id
    for k in 0..<30 { store.updateNoteBody(id: firstBig, body: "Note 0 edited \(k)\nmore") }
    print(String(format: "30 body updates: %.0f ms", Date().timeIntervalSince(t1) * 1000))
    render("17-big-light")
    // Reveal deep in the list: scrolls there, creates editors around it, cards never overlap.
    let bigIDs = store.notes(in: big.id).map(\.id)
    vc.reveal(noteId: bigIDs[120], edit: false)
    probe.layoutNow(); spin(); probe.layoutNow()
    if let f = probe.cardFrame(of: bigIDs[120]) {
        Check.expect(f.minY >= 56 && f.maxY <= panelSize.height, "revealed card visible: \(f)")
    } else { Check.expect(false, "revealed card frame") }
    Check.expect(probe.editor(of: bigIDs[120]) != nil, "editor created near the viewport")
    Check.expect(probe.editor(of: bigIDs[199]) == nil || probe.liveEditorCount < 60, "far cards stay previews")
    var overlaps = 0
    for k in 0..<(bigIDs.count - 1) {
        if let a = probe.cardFrame(of: bigIDs[k]), let b = probe.cardFrame(of: bigIDs[k + 1]), a.maxY + 9 > b.minY { overlaps += 1 }
    }
    Check.equal(overlaps, 0, "cards keep their gaps")
    render("20-big-scrolled-light")

    // MARK: Import rules outside the editor
    do {
        let pb = NSPasteboard(name: NSPasteboard.Name("NoteBarUISnapshot-\(UUID().uuidString)"))
        let img = NSImage(size: NSSize(width: 4, height: 4))
        img.lockFocus(); NSColor.red.setFill(); NSRect(x: 0, y: 0, width: 4, height: 4).fill(); img.unlockFocus()
        let tiff = img.tiffRepresentation!
        pb.clearContents(); pb.setData(tiff, forType: .tiff)
        Check.equal(NotesUIProbe.importKind(of: pb), "image", "TIFF only -> image")
        pb.clearContents(); pb.setData(tiff, forType: .tiff); pb.setString("https://example.com/cat.png", forType: .string)
        Check.equal(NotesUIProbe.importKind(of: pb), "image", "TIFF + its web URL (browser Copy Image) -> image")
        pb.clearContents(); pb.setData(tiff, forType: .tiff); pb.setString("Some copied words", forType: .string)
        Check.equal(NotesUIProbe.importKind(of: pb), "text", "TIFF + real text -> text")
        pb.clearContents(); pb.setString("Plain text", forType: .string)
        Check.equal(NotesUIProbe.importKind(of: pb), "text", "text -> text")
        pb.releaseGlobally()
        let promiseTypes = NSFilePromiseReceiver.readableDraggedTypes.map { NSPasteboard.PasteboardType($0) }
        Check.expect(!promiseTypes.isEmpty && promiseTypes.allSatisfy(NotesUIProbe.acceptsDragType),
                     "file-promise drags accepted outside the editor")
    }

    // MARK: Pin corner keeps the title clear
    let pinFolder = store.createFolder(name: "Pins")
    var longPinned = store.createNote(in: pinFolder.id, body: "A pinned note title which is long ok yes\nBody", mode: .standard, position: .bottom)
    longPinned.isPinned = true; longPinned.color = .cream; store.updateNote(longPinned)
    let longPlain = store.createNote(in: pinFolder.id, body: "Unpinned long title that runs to it now\nBody", mode: .standard, position: .bottom)
    vc.showFolder(pinFolder.id)
    probe.ensureEditor(of: longPinned.id)
    probe.ensureEditor(of: longPlain.id)
    probe.setHovered(longPlain.id, true)
    probe.layoutNow(); spin(); probe.layoutNow()
    render("21-pin-corner-light")
    for id in [longPinned.id, longPlain.id] {
        if let pin = probe.pinFrame(of: id), let line = probe.firstLineFrame(of: id) {
            Check.expect(line.maxX <= pin.minX, "first line ends before the pin (\(line.maxX) <= \(pin.minX))")
        } else { Check.expect(false, "pin / first line frames") }
    }
    probe.setHovered(longPlain.id, false)
    // Far cards are previews: the same corner is kept free there.
    var farNote = store.note(id: bigIDs[199])!
    // Not pinned (pinned notes sort to the top); the corner is reserved on every card anyway.
    farNote.body = "An unpinned far away title that is long\nBody"
    store.updateNote(farNote)
    vc.showFolder(big.id)
    probe.layoutNow(); spin(); probe.layoutNow()
    Check.expect(probe.editor(of: farNote.id) == nil, "far card is a preview")
    if let pin = probe.pinFrame(of: farNote.id), let line = probe.firstLineFrame(of: farNote.id) {
        Check.expect(line.maxX <= pin.minX, "preview first line ends before the pin (\(line.maxX) <= \(pin.minX))")
    } else { Check.expect(false, "preview pin / first line frames") }

    // MARK: Unfocused open and focus change
    Check.expect(probe.showsSelection, "shows selection when focused")
    probe.panelFocusChanged(false)
    Check.expect(!probe.showsSelection, "unfocused hides selection ring")
    probe.panelFocusChanged(true)
    Check.expect(probe.showsSelection, "focused restores selection ring")
    probe.press(keyCode: 0x2D, characters: "n", modifiers: [.command, .option, .shift])
    Check.expect(settings.pinnedOpen, "⌥⇧⌘N toggles pinnedOpen = true")
    probe.press(keyCode: 0x2D, characters: "n", modifiers: [.command, .option, .shift])
    Check.expect(!settings.pinnedOpen, "⌥⇧⌘N toggles pinnedOpen = false")

    // MARK: Card Expansion
    let expFolder = store.createFolder(name: "Expansion Test")
    let noteTop = store.createNote(in: expFolder.id, body: "Top Note\nShort note above", mode: .standard, position: .bottom)
    let noteMid = store.createNote(in: expFolder.id, body: "Middle Note\nThis note will be expanded to fill the viewport height.", mode: .standard, position: .bottom)
    let noteBot = store.createNote(in: expFolder.id, body: "Bottom Note\nShort note below", mode: .standard, position: .bottom)
    vc.showFolder(expFolder.id)
    probe.layoutNow(); spin(); probe.layoutNow()

    // 1. Expand button exists at top right, pin button is below it in the same column
    if let pin = probe.pinFrame(of: noteMid.id), let exp = probe.expandButtonFrame(of: noteMid.id) {
        Check.expect(pin.minY >= exp.maxY, "pin button is shifted below the expand button (\(pin.minY) >= \(exp.maxY))")
        Check.equal(pin.minX, exp.minX, "pin and expand buttons are in the same action column")
    } else {
        Check.expect(false, "expand / pin button frames exist")
    }

    let unexpandedH = probe.cardVisibleHeight(noteMid.id) ?? 0
    Check.expect(unexpandedH < 200, "middle note starts with natural height (\(unexpandedH) < 200)")
    Check.expect(!probe.isExpanded(noteMid.id), "not expanded initially")

    // Context menu offers "Expand"
    let menuItemsInitial = probe.cardMenuItems(for: noteMid.id)
    Check.expect(menuItemsInitial.contains("Expand"), "context menu contains 'Expand'")

    // 2. Expand noteMid
    probe.toggleExpand(noteMid.id)
    probe.layoutNow(); spin(); probe.layoutNow()
    Check.expect(probe.isExpanded(noteMid.id), "isExpanded is true after toggle")
    Check.equal(probe.expandedNoteID, noteMid.id, "expandedNoteID is noteMid")
    let expandedH = probe.cardVisibleHeight(noteMid.id) ?? 0
    Check.expect(expandedH > unexpandedH + 300, "card height expanded to fill viewport (\(expandedH) > \(unexpandedH + 300))")

    // Context menu offers "Collapse"
    let menuItemsExpanded = probe.cardMenuItems(for: noteMid.id)
    Check.expect(menuItemsExpanded.contains("Collapse"), "context menu contains 'Collapse'")

    // Top note is pushed above middle note, bottom note is pushed below
    if let topF = probe.cardFrame(of: noteTop.id),
       let midF = probe.cardFrame(of: noteMid.id),
       let botF = probe.cardFrame(of: noteBot.id) {
        Check.expect(topF.maxY <= midF.minY + 10, "top note is pushed above middle note")
        Check.expect(botF.minY >= midF.maxY - 10, "bottom note is pushed below middle note")
    }

    render("22-card-expanded-light")

    // 3. Toggle via keyboard shortcut ⇧⌘E
    probe.select(noteMid.id)
    probe.press(keyCode: 14, characters: "e", modifiers: [.command, .shift])
    probe.layoutNow(); spin(); probe.layoutNow()
    Check.expect(!probe.isExpanded(noteMid.id), "⇧⌘E collapses the note")
    Check.equal(probe.cardVisibleHeight(noteMid.id), unexpandedH, "restored natural height")

    // 4. Re-expand via ⇧⌘E and collapse via Escape
    probe.press(keyCode: 14, characters: "e", modifiers: [.command, .shift])
    probe.layoutNow(); spin(); probe.layoutNow()
    Check.expect(probe.isExpanded(noteMid.id), "⇧⌘E re-expands the note")
    probe.pressEscape()
    probe.layoutNow(); spin(); probe.layoutNow()
    Check.expect(!probe.isExpanded(noteMid.id), "Escape collapses expanded note")

    // Single note test
    NoteBarUIOptions.useGlass = true
    settings.blurBackdrop = true
    let singleFolder = store.createFolder(name: "Single Note Test")
    let singleNote = store.createNote(in: singleFolder.id, body: "Single Note\nSome content", mode: .standard, position: .top)
    vc.showFolder(singleFolder.id)
    probe.layoutNow(); spin(); probe.layoutNow()
    print("Initial rootContentHeight:", probe.rootContentHeight)
    print("Initial backdrop height:", probe.backdropFrame.height)
    print("Initial cardVisibleHeight:", probe.cardVisibleHeight(singleNote.id) ?? 0)
    probe.toggleExpand(singleNote.id)
    probe.layoutNow(); spin(); probe.layoutNow()
    print("Expanded rootContentHeight:", probe.rootContentHeight)
    print("Expanded backdrop height:", probe.backdropFrame.height)
    print("Expanded cardVisibleHeight:", probe.cardVisibleHeight(singleNote.id) ?? 0)
    probe.toggleExpand(singleNote.id)
    probe.layoutNow(); spin(); probe.layoutNow()
    print("Contracted rootContentHeight:", probe.rootContentHeight)
    print("Contracted backdrop height:", probe.backdropFrame.height)
    print("Contracted cardVisibleHeight:", probe.cardVisibleHeight(singleNote.id) ?? 0)
    Check.equal(probe.backdropFrame.height, probe.rootContentHeight, "backdrop returns to initial height after collapse")
    NoteBarUIOptions.useGlass = false

    // MARK: Vim keys
    vimChecks(vc: vc, probe: probe, store: store, settings: settings, folders: folders, spin: spin)

    // MARK: Panel undo (⌘Z / ⇧⌘Z on the list)
    undoChecks(vc: vc, probe: probe, store: store, folders: folders, spin: spin)

    // MARK: Cursor over card buttons: arrow, not the text I-beam
    vc.showFolder(folders.notes.id)
    probe.layoutNow(); spin(); probe.layoutNow()
    if let cid = probe.displayedNoteIDs.first {
        probe.ensureEditor(of: cid)
        probe.setHovered(cid, true)
        probe.layoutNow(); spin(); probe.layoutNow()
        if let pin = probe.pinFrame(of: cid) {
            Check.equal(probe.wantsArrowCursor(at: NSPoint(x: pin.midX, y: pin.midY)), true, "arrow cursor over the pin button")
        } else { Check.expect(false, "pin frame") }
        if let line = probe.firstLineFrame(of: cid) {
            Check.equal(probe.wantsArrowCursor(at: NSPoint(x: line.minX + 6, y: line.midY)), false, "I-beam over the note text")
        } else { Check.expect(false, "first line frame") }
        probe.setHovered(cid, false)
    }

    print("Wrote \(written.count) snapshots to \(out.path): \(written.joined(separator: ", "))")
    Check.finish()
}

@MainActor
func vimChecks(vc: NotesRootViewController, probe: NotesUIProbe, store: InMemoryNoteStore, settings: AppSettings,
               folders: (notes: Folder, work: Folder, ideas: Folder, empty: Folder), spin: () -> Void) {
    func key(_ ch: String, _ code: UInt16 = 0, _ mods: NSEvent.ModifierFlags = []) { probe.press(keyCode: code, characters: ch, modifiers: mods) }

    // Off (default): letters on the folder list type into search.
    settings.vimKeybinds = false
    vc.showFolderList()
    probe.focusList()
    key("j", 38)
    Check.expect(probe.isSearching, "vim off: a letter on the folder list starts search")
    probe.goBack()
    Check.expect(!probe.isSearching, "search closed")

    settings.vimKeybinds = true
    vc.showFolderList()
    probe.focusList()
    let ids = probe.folderRowIDs
    for _ in ids { key("k", 40) }
    Check.expect(!probe.isSearching, "vim: j / k do not start search")
    Check.equal(probe.selectedFolderID, ids.first, "vim: k moves the folder selection up to the top")
    key("j", 38)
    Check.equal(probe.selectedFolderID, ids[1], "vim: j moves the folder selection down")
    key("k", 40)
    Check.equal(probe.selectedFolderID, ids[0], "vim: k moves it back")
    key("x", 7)
    Check.expect(!probe.isSearching, "vim: other letters do nothing on the folder list")
    key("R", 15, [.shift])
    Check.equal(probe.renamingFolderID, ids[0], "vim: R renames the selected folder")
    probe.endRename()
    Check.equal(probe.renamingFolderID, nil, "rename ended")

    // l opens; ⌃[ goes up; ⌘/ searches all folders.
    guard let notesIndex = ids.firstIndex(of: folders.notes.id) else { Check.expect(false, "folder rows"); return }
    for _ in 0..<notesIndex { key("j", 38) }
    Check.equal(probe.selectedFolderID, folders.notes.id, "selected the Notes folder")
    key("l", 37)
    Check.equal(probe.headerTitle, "Notes", "vim: l opens the folder")
    probe.layoutNow(); spin(); probe.layoutNow()
    key("\u{1b}", 33, [.control])
    Check.expect(probe.folderRowsVisible, "vim: ⌃[ goes up to the folder list")
    key("/", 44, [.command])
    Check.expect(probe.isSearching, "⌘/ starts search")
    Check.equal(probe.searchAllFolders, true, "⌘/ searches all folders")
    probe.goBack()

    // Notes list: j / k select, ⌃W J / K edit the neighbor card (folded cards unfold).
    let vf = store.createFolder(name: "Vim Test")
    let a = store.createNote(in: vf.id, body: "A note\nfirst", mode: .standard, position: .bottom)
    var b = store.createNote(in: vf.id, body: "B note\nsecond", mode: .standard, position: .bottom)
    b.isFolded = true
    store.updateNote(b)
    let c = store.createNote(in: vf.id, body: "C note\nthird", mode: .standard, position: .bottom)
    vc.showFolder(vf.id)
    probe.layoutNow(); spin(); probe.layoutNow()
    probe.focusList()
    key("j", 38)
    Check.equal(probe.selectedNoteID, a.id, "vim: j selects the first card")
    key("j", 38)
    Check.equal(probe.selectedNoteID, b.id, "vim: j selects the next card")
    key("k", 40)
    Check.equal(probe.selectedNoteID, a.id, "vim: k selects the previous card")
    key("w", 13, [.control])
    key("j", 38)
    Check.equal(probe.focusedNoteID, b.id, "⌃W J from the list edits the next card")
    Check.equal(probe.isCardFolded(b.id), false, "⌃W J unfolds a folded card")
    probe.vimCommand(.focusNextCard, on: b.id)
    Check.equal(probe.focusedNoteID, c.id, "⌃W J in an editor edits the next card")
    probe.vimCommand(.focusPreviousCard, on: c.id)
    Check.equal(probe.focusedNoteID, b.id, "⌃W K edits the previous card")

    // Card commands.
    probe.vimCommand(.togglePin, on: b.id)
    Check.expect(store.note(id: b.id)?.isPinned == true, "gp / :pin pins")
    probe.vimCommand(.togglePin, on: b.id)
    probe.vimCommand(.setColor(.blue), on: b.id)
    Check.equal(store.note(id: b.id)?.color, .blue, ":color blue")
    probe.vimCommand(.setMode(.code), on: b.id)
    Check.equal(store.note(id: b.id)?.mode, .code, ":mode code")
    probe.vimCommand(.toggleFold, on: b.id)
    Check.equal(store.note(id: b.id)?.isFolded, true, "za folds")
    Check.equal(probe.selectedNoteID, b.id, "the folded card stays selected")
    Check.equal(probe.focusedNoteID, nil, "folding ends editing")
    probe.vimCommand(.setFolded(false), on: b.id)
    Check.equal(store.note(id: b.id)?.isFolded, false, ":unfold")
    probe.vimCommand(.quit, on: b.id)
    Check.equal(probe.selectedNoteID, b.id, ":q keeps the card selected")
    probe.vimCommand(.moveToFolder("nosuchfolder"), on: b.id)
    Check.equal(store.note(id: b.id)?.folderId, vf.id, ":move to an unknown folder does nothing")
    Check.expect(probe.isToastVisible, ":move to an unknown folder shows a message")
    probe.vimCommand(.moveToFolder("ide"), on: b.id)
    Check.equal(store.note(id: b.id)?.folderId, folders.ideas.id, ":move ide → Ideas (prefix match)")
    probe.vimCommand(.delete, on: c.id)
    Check.equal(probe.pendingDeletion, c.id, "gx / :delete deletes with undo")
    probe.undoDelete()
    probe.vimCommand(.navigateUp, on: a.id)
    Check.expect(probe.folderRowsVisible, "⌃[ in Normal mode goes up")
    settings.vimKeybinds = false
}

@MainActor
func undoChecks(vc: NotesRootViewController, probe: NotesUIProbe, store: InMemoryNoteStore,
                folders: (notes: Folder, work: Folder, ideas: Folder, empty: Folder), spin: () -> Void) {
    func cmdZ(shift: Bool = false) {
        spin()  // each key is its own event in the app (undo groups by event)
        probe.press(keyCode: 6, characters: "z", modifiers: shift ? [.command, .shift] : [.command])
        spin()
    }
    let uf = store.createFolder(name: "Undo Test")
    let n1 = store.createNote(in: uf.id, body: "First\nnote", mode: .standard, position: .bottom)
    let n2 = store.createNote(in: uf.id, body: "Second\nnote", mode: .standard, position: .bottom)
    vc.showFolder(uf.id)
    probe.layoutNow(); spin()
    probe.focusList()

    probe.setColor(.green, of: n1.id)
    Check.equal(probe.undoActionName, "Color", "undo name")
    cmdZ()
    Check.equal(store.note(id: n1.id)?.color, NoteColor.none, "⌘Z undoes a color change")
    cmdZ(shift: true)
    Check.equal(store.note(id: n1.id)?.color, .green, "⇧⌘Z redoes it")
    Check.expect(probe.isToastVisible, "undo / redo show a short toast")

    probe.togglePin(n2.id)
    cmdZ()
    Check.equal(store.note(id: n2.id)?.isPinned, false, "⌘Z undoes pin")

    probe.setFolded(true, n1.id)
    cmdZ()
    Check.equal(store.note(id: n1.id)?.isFolded, false, "⌘Z undoes fold")

    probe.moveByKeyboard(n2.id, up: true)
    Check.equal(store.notes(in: uf.id).map(\.id), [n2.id, n1.id], "moved up")
    cmdZ()
    Check.equal(store.notes(in: uf.id).map(\.id), [n1.id, n2.id], "⌘Z undoes a reorder")

    probe.moveToFolder(n2.id, folders.ideas.id)
    Check.equal(store.note(id: n2.id)?.folderId, folders.ideas.id, "moved to Ideas")
    cmdZ()
    Check.equal(store.note(id: n2.id)?.folderId, uf.id, "⌘Z moves the note back")
    Check.equal(store.notes(in: uf.id).map(\.id), [n1.id, n2.id], "back at its old place")
    cmdZ(shift: true)
    Check.equal(store.note(id: n2.id)?.folderId, folders.ideas.id, "⇧⌘Z moves it again")
    cmdZ()

    // Move to a new folder: one step undoes the move and the new folder.
    let before = store.folders().count
    probe.moveToNewFolder(n1.id)
    probe.endRename()
    vc.showFolder(uf.id)
    probe.focusList()
    Check.equal(store.folders().count, before + 1, "new folder created")
    cmdZ()
    Check.equal(store.note(id: n1.id)?.folderId, uf.id, "⌘Z: note back from the new folder")
    Check.equal(store.folders().count, before, "⌘Z: the new folder is gone")

    // Folders.
    probe.renameFolder(uf.id, "Renamed")
    cmdZ()
    Check.equal(store.folder(id: uf.id)?.name, "Undo Test", "⌘Z undoes a folder rename")
    vc.showFolderList()
    probe.focusList()
    probe.newFolder()
    probe.endRename()
    probe.focusList()
    Check.equal(store.folders().count, before + 1, "New Folder")
    cmdZ()
    Check.equal(store.folders().count, before, "⌘Z removes the new folder")
    cmdZ(shift: true)
    Check.equal(store.folders().count, before + 1, "⇧⌘Z brings it back")
    cmdZ()

    // New note.
    vc.showFolder(uf.id)
    probe.createNewNote()
    let created = probe.focusedNoteID
    probe.focusList()
    cmdZ()
    Check.expect(created != nil && store.note(id: created!) == nil, "⌘Z on the list removes a new note")

    // While text is edited, ⌘Z belongs to the text.
    probe.setColor(.blue, of: n1.id)
    vc.reveal(noteId: n1.id, edit: true)
    probe.press(keyCode: 6, characters: "z", modifiers: [.command])
    Check.equal(store.note(id: n1.id)?.color, .blue, "⌘Z in a note does not undo panel actions")
    probe.focusList()

    // Changes from outside the panel clear the history.
    Check.expect(probe.canUndo, "history before an external change")
    NotificationCenter.default.post(name: .notesChangedExternally, object: nil)
    Check.expect(!probe.canUndo && !probe.canRedo, "external change clears the history")
    probe.press(keyCode: 6, characters: "z", modifiers: [.command])
    Check.equal(store.note(id: n1.id)?.color, .blue, "nothing to undo after an external change")

    // Delete: ⌘Z and the toast run the same restore.
    vc.showFolder(uf.id)
    probe.layoutNow(); spin()
    probe.focusList()
    probe.deleteWithUndo(n1.id)
    Check.equal(probe.undoActionName, "Delete Note", "delete is undoable")
    cmdZ()
    Check.expect(store.note(id: n1.id) != nil, "⌘Z restores a deleted note")
    Check.expect(!probe.isToastVisible || probe.pendingDeletion == nil, "the delete toast is gone after ⌘Z")
    cmdZ(shift: true)
    Check.equal(store.note(id: n1.id), nil, "⇧⌘Z deletes it again")
    cmdZ()
    probe.deleteWithUndo(n1.id)
    probe.undoDelete()
    Check.expect(store.note(id: n1.id) != nil, "toast Undo restores")
    Check.expect(probe.canRedo, "toast Undo is the same step as ⌘Z (redo available)")
    // Toast Undo after another action: direct restore, the history stays.
    probe.deleteWithUndo(n1.id)
    probe.togglePin(n2.id)
    probe.undoDelete()
    Check.expect(store.note(id: n1.id) != nil, "toast Undo after another action still restores")
    Check.equal(probe.undoActionName, "Pin", "the newer action stays on top of the history")
    cmdZ()

    // Folder delete: undoable, restores its notes.
    vc.showFolderList()
    probe.focusList()
    probe.confirmFolderDeletes(true)
    probe.deleteFolder(uf.id)
    Check.equal(store.folder(id: uf.id), nil, "folder deleted (trash)")
    Check.equal(store.note(id: n1.id), nil, "its notes are hidden")
    Check.expect(probe.isToastVisible, "folder delete toast")
    cmdZ()
    Check.expect(store.folder(id: uf.id) != nil && store.note(id: n1.id) != nil, "⌘Z restores the folder and its notes")
    probe.deleteFolder(uf.id)
    probe.undoDelete()
    Check.expect(store.folder(id: uf.id) != nil, "folder toast Undo restores")
    probe.confirmFolderDeletes(nil)
}
