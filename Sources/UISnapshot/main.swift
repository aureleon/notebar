import AppKit
import NoteBarCore
import NoteBarUI
import NoteBarEditor
@testable import NoteBarPanel

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

/// The panel window takes clicks only where its pixels are not fully transparent: over the rendered
/// content (the near-invisible fill), not in the empty part below it.
@MainActor
func panelClickRegionChecks() {
    let view = PanelContentView(frame: NSRect(x: 0, y: 0, width: 400, height: 800))
    func alpha(atTop y: CGFloat) -> CGFloat {
        view.layoutSubtreeIfNeeded()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return -1 }
        view.cacheDisplay(in: view.bounds, to: rep)
        let scale = CGFloat(rep.pixelsHigh) / view.bounds.height
        return rep.colorAt(x: Int(200 * scale), y: Int(y * scale))?.alphaComponent ?? -1
    }
    Check.expect(alpha(atTop: 700) > 0, "no content height yet: the whole panel takes clicks")
    view.solidHeight = 200
    view.layoutSubtreeIfNeeded()
    Check.equal(view.solidFrameForChecks, NSRect(x: 0, y: 600, width: 400, height: 200), "fill covers the top 200 pt")
    Check.expect(alpha(atTop: 100) > 0, "rendered region takes clicks (gaps between cards too)")
    Check.equal(alpha(atTop: 700), 0, "below the content: clicks go to the app below")
    Check.expect(view.resizeHandle.frame.minY >= 600, "the resize handle stays in the rendered region")
    view.solidHeight = 5000
    Check.expect(alpha(atTop: 790) > 0, "content taller than the panel: all of it takes clicks")
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
    // Never put a dialog on the screen: an unexpected one is a failed check, answered Cancel.
    ModalSupport.testResponder = { title in
        Check.expect(false, "unexpected dialog: \(title)")
        return .cancel
    }
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

    @MainActor func spin() { RunLoop.current.run(until: Date().addingTimeInterval(0.002)) }

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
    Check.equal(probe.hiddenActionCount(hello), 0, "the bottom tray holds copy, archive and delete")
    if let aa = probe.formatButtonFrame(of: hello), let tray = probe.actionTrayFrame(of: hello),
       let mb = probe.modeButtonFrame(of: hello),
       let line = probe.firstLineFrame(of: hello), let card = probe.cardFrame(of: hello) {
        Check.expect(abs(aa.midY - tray.midY) < 0.5, "Aa and the action tray share the bottom row")
        Check.expect(aa.minX < tray.minX && tray.maxX > card.midX, "Aa on the left, the tray on the right")
        Check.expect(mb.minX - card.minX < 30, "the mode button sits at the left edge of the text")
        _ = line
    } else { Check.expect(false, "Aa and tray frames") }
    // Fold button below the pin, on hover only.
    if let fold = probe.foldButtonFrame(of: hello), let pin = probe.pinFrame(of: hello) {
        Check.expect(abs(fold.midX - pin.midX) < 0.5 && fold.minY > pin.minY, "fold button sits below the pin")
    } else { Check.expect(false, "fold button shown on hover") }
    probe.setHovered(hello, false)
    probe.layoutNow()
    Check.equal(probe.foldButtonFrame(of: hello), nil, "fold button hidden without hover")
    probe.layoutNow()
    Check.expect(probe.formatButtonFrame(of: hello) != nil, "Aa is visible without hover")
    // Aa (Standard only) and the mode button (symbol = mode, opens Color & Mode) on the bottom-left.
    Check.expect(probe.isFormatButtonShown(hello), "Standard: Aa is shown")
    Check.equal(probe.modeButtonSymbol(hello), "paragraphsign", "Standard: ¶ mode button")
    if let aa = probe.formatButtonFrame(of: hello), let mb = probe.modeButtonFrame(of: hello) {
        Check.expect(abs(aa.midY - mb.midY) < 0.5 && aa.minX > mb.maxX && aa.minX - mb.maxX < 6, "Aa sits right of the mode button")
    } else { Check.expect(false, "Aa and mode button frames") }
    let modeX = probe.modeButtonFrame(of: hello)?.minX
    probe.setMode(.code, of: hello)
    probe.layoutNow()
    Check.expect(!probe.isFormatButtonShown(hello), "Code: no Aa")
    Check.equal(probe.modeButtonSymbol(hello), "curlybraces", "Code: { } mode button")
    Check.equal(probe.modeButtonFrame(of: hello)?.minX, modeX, "Code: the mode button stays at the left edge")
    render("05c-code-mode-button-light")
    probe.setMode(.plain, of: hello)
    probe.layoutNow()
    Check.equal(probe.modeButtonSymbol(hello), "text.alignleft", "Plain: ≡ mode button")
    render("05c-plain-mode-button-light")
    probe.setMode(.standard, of: hello)
    probe.layoutNow()
    Check.expect(probe.isFormatButtonShown(hello), "back to Standard: Aa again")
    Check.equal(probe.actionTrayFrame(of: hello), nil, "the action tray is hidden without hover")
    // One-line card: the bottom row still has the whole tray; no room for the fold button.
    let short = store.createNote(in: folders.notes.id, body: "One line", mode: .standard, position: .top)
    probe.setHovered(short.id, true)
    render("05b-hover-short-light")
    Check.equal(probe.foldButtonFrame(of: short.id), nil, "one-line card: no room for the fold button (Fold is in the … menu)")
    Check.equal(probe.hiddenActionCount(short.id), 0, "one-line card: the tray fits in the bottom row")
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
    let restingBadge = probe.foldedRowFrames(goalsID)?.badge
    probe.setHovered(goalsID, true)
    render("08-folded-hover-light")
    // Right to left: expand button, date, "+ N lines" badge. The badge does not move on hover.
    if let f = probe.foldedRowFrames(goalsID), let badge = f.badge, let date = f.date {
        Check.expect(date.maxX <= f.expand.minX && badge.maxX <= date.minX, "folded row: badge, date, buttons (\(badge), \(date))")
        Check.equal(badge, restingBadge, "the badge stays put when the date shows on hover")
    } else {
        Check.expect(false, "folded hover shows the badge and the date")
    }
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

    // Short folder: the toast sits just below the last card, not at the bottom of the panel, and the
    // rendered region (where the panel takes clicks) grows to include it while it shows.
    do {
        vc.showFolder(folders.ideas.id)
        probe.layoutNow()
        let shortNote = store.createNote(in: folders.ideas.id, body: "Short", mode: .standard, position: .top).id
        probe.layoutNow()
        spin()
        probe.deleteWithUndo(shortNote)
        probe.layoutNow()
        let listH = probe.listContentHeight
        let tf = probe.toastFrame
        Check.expect(probe.isToastVisible, "short folder: toast visible")
        Check.expect(listH < panelSize.height / 2, "short folder: the list is short (\(listH) pt)")
        Check.expect(tf.minY >= listH - 20 && tf.minY <= listH + 20, "toast sits below the last card (\(tf.minY) vs \(listH))")
        Check.expect(probe.rootContentHeight >= tf.maxY, "the rendered region includes the toast")
        Check.expect(probe.rootContentHeight < panelSize.height, "the rendered region stops below the toast")
        render("10b-toast-short-light")
        probe.commitDelete()
        probe.layoutNow()
        Check.expect(!probe.isToastVisible, "short folder: toast hidden")
        Check.equal(probe.rootContentHeight, probe.listContentHeight, "without the toast, the region is the list")
        vc.showFolder(folders.notes.id)
        probe.layoutNow()
    }

    panelClickRegionChecks()

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
    Check.expect(moveItems.contains("Move to a New Folder…") && moveItems.contains("Move Up") && moveItems.contains("Move to Folder"),
                 "move menu items: \(moveItems)")
    Check.equal(Array(moveItems.prefix(2)), ["Move to Folder", "Move to a New Folder…"], "existing and new folder side by side, first")
    let gear = probe.gearMenuItems(for: hello)
    Check.expect(gear.contains("<colors>") && gear.contains("Standard (Markdown) ✓") && gear.contains("Code"), "gear menu: \(gear)")
    Check.expect(!gear.contains { $0.hasPrefix("Pin") || $0.hasPrefix("Unpin") || $0.hasPrefix("Fold") || $0.hasPrefix("Unfold") },
                 "gear menu has no Pin / Fold (they are card buttons)")
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
    // Tab / Shift+Tab: field → results → field.
    probe.searchFieldTab(backward: false)
    Check.equal(probe.selectedNoteID, resultIDs.first, "Tab in the search field selects the first result")
    Check.equal(probe.isSearchFieldFocused, false, "Tab moves focus to the results")
    _ = probe.press(keyCode: 48, characters: "\t")
    Check.equal(probe.selectedNoteID, resultIDs[1], "Tab selects the next result")
    _ = probe.press(keyCode: 48, characters: "\u{19}", modifiers: [.shift])
    Check.equal(probe.selectedNoteID, resultIDs[0], "Shift+Tab selects the previous result")
    _ = probe.press(keyCode: 48, characters: "\u{19}", modifiers: [.shift])
    Check.equal(probe.isSearchFieldFocused, true, "Shift+Tab on the first result goes back to the field")
    Check.equal(probe.searchQuery, "note", "the query is kept")
    probe.searchFieldTab(backward: true)
    Check.equal(probe.selectedNoteID, resultIDs.last, "Shift+Tab in the field selects the last result")
    _ = probe.press(keyCode: 48, characters: "\t")
    Check.equal(probe.isSearchFieldFocused, true, "Tab on the last result goes back to the field")
    probe.select(nil)
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

    // ⌘digits never switch folders (⌘1–⌘3 are headings while editing).
    vc.showFolder(folders.ideas.id)
    probe.focusList()
    probe.press(keyCode: 18, characters: "1", modifiers: [.command])
    Check.equal(vc.currentFolderId, folders.ideas.id, "⌘1 in the list does not switch folders")
    let headingProbe = HeadingKeyTextView(frame: NSRect(x: 0, y: 0, width: 50, height: 20))
    vc.view.addSubview(headingProbe)
    window.makeFirstResponder(headingProbe)
    probe.press(keyCode: 19, characters: "2", modifiers: [.command])
    Check.equal(vc.currentFolderId, folders.ideas.id, "⌘2 while editing does not switch folders")
    Check.equal(headingProbe.receivedHeading, 2, "⌘2 while editing reaches the text view")
    Check.expect(window.firstResponder === headingProbe, "⌘2 while editing keeps focus")
    headingProbe.removeFromSuperview()
    vc.showFolderList()
    Check.equal(settings.lastFolderId, folders.ideas.id, "folder list keeps lastFolderId for new-note hotkeys")

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

    // 1. Pin in the top-right corner, the expand button below it in the same column (hover only).
    if let pin = probe.pinFrame(of: noteMid.id), let exp = probe.expandButtonFrame(of: noteMid.id) {
        Check.expect(exp.minY >= pin.maxY, "expand button sits below the pin (\(exp.minY) >= \(pin.maxY))")
        Check.equal(pin.minX, exp.minX, "pin and expand buttons are in the same action column")
    } else {
        Check.expect(false, "expand / pin button frames exist")
    }
    probe.mouseMoved()
    Check.equal(probe.isExpandButtonShown(noteMid.id), false, "expand button hidden without hover")
    probe.setHovered(noteMid.id, true)
    Check.equal(probe.isExpandButtonShown(noteMid.id), true, "expand button shown on hover")
    probe.setHovered(noteMid.id, false)

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
    Check.equal(probe.isExpandButtonShown(noteMid.id), true, "an expanded card keeps its collapse button without hover")
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

    // A note that grows (typing, pasting) grows the backdrop at once, also past the panel height: an
    // animated backdrop would trail behind and the card's glass would show below its bottom edge.
    NoteBarUIOptions.animations = true
    let shortBody = "Single Note\nSome content"
    let tallBody = shortBody + String(repeating: "\nmore content", count: 80)
    // As typing does: the live editor changes its text (and height), then the store follows.
    @MainActor func setBody(_ body: String) {
        store.updateNoteBody(id: singleNote.id, body: body)
        if let n = store.note(id: singleNote.id) { probe.editor(of: singleNote.id)?.apply(note: n) }
        probe.layoutNow(); spin(); probe.layoutNow()
    }
    setBody(tallBody)
    Check.equal(probe.lastBackdropChangeAnimated, false, "a growing note grows the backdrop without animation")
    Check.equal(probe.backdropFrame.height, vc.view.bounds.height, "a note taller than the panel: the backdrop takes the full height")
    // The card runs past the panel bottom: it stays inside the backdrop, cut with card corners
    // `outerMargin` above its bottom edge instead of drawn over the backdrop's rounded corners.
    Check.expect((probe.cardVisibleHeight(singleNote.id) ?? 0) > vc.view.bounds.height, "the tall card runs past the panel bottom")
    let vb = vc.view.bounds
    let mm: CGFloat = 6
    Check.equal(probe.listClipShows(NSPoint(x: vb.midX, y: vb.height - mm - 2)), true, "list clip: shows the card just above the bottom margin")
    Check.equal(probe.listClipShows(NSPoint(x: vb.midX, y: vb.height - 2)), false, "list clip: hides the bottom margin")
    Check.equal(probe.listClipShows(NSPoint(x: mm + 2, y: vb.height - mm - 2)), false, "list clip: rounded bottom-left corner")
    Check.equal(probe.listClipShows(NSPoint(x: vb.width - mm - 2, y: vb.height - mm - 2)), false, "list clip: rounded bottom-right corner")
    Check.equal(probe.listClipShows(NSPoint(x: 2, y: vb.midY)), true, "list clip: full width above the corners (side shadows)")
    setBody(shortBody)
    Check.equal(probe.lastBackdropChangeAnimated, true, "a shrinking note animates the backdrop (the cards stay inside it)")
    NoteBarUIOptions.animations = false
    probe.layoutNow(); spin(); probe.layoutNow()
    NoteBarUIOptions.useGlass = false

    // MARK: Vim keys
    vimChecks(vc: vc, probe: probe, store: store, settings: settings, folders: folders, spin: spin)
    vimScrollChecks(spin: spin)
    written += scratchEntryChecks(out: out, spin: spin)

    // MARK: Panel undo (⌘Z / ⇧⌘Z on the list)
    renderHook = { render($0) }
    undoChecks(vc: vc, probe: probe, store: store, folders: folders, spin: spin)

    // MARK: Archive
    archiveChecks(vc: vc, probe: probe, store: store, spin: spin)
    folderArchiveChecks(vc: vc, probe: probe, store: store, spin: spin)

    // MARK: Scratch
    scratchChecks(vc: vc, probe: probe, store: store, env: env, spin: spin, render: { render($0, dark: $1) })

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

    // MARK: Keyboard selection hides the hover of the card under a still pointer
    do {
        let ids = probe.displayedNoteIDs
        if ids.count >= 2 {
            probe.select(nil)
            probe.mouseMoved()   // earlier checks used the keyboard
            probe.setHovered(ids[0], true)
            Check.equal(probe.cardShowsHover(ids[0]), true, "hover: pointer over the first card")
            _ = probe.press(keyCode: 125, characters: "\u{F701}")   // ↓
            _ = probe.press(keyCode: 125, characters: "\u{F701}")
            Check.equal(probe.selectedNoteID, ids[1], "hover: ↓ selected the second card")
            Check.equal(probe.cardShowsHover(ids[0]), false, "hover: keyboard selection hides the hover on the first card")
            probe.mouseMoved()
            Check.equal(probe.cardShowsHover(ids[0]), true, "hover: a mouse move shows it again")
            settings.vimKeybinds = true
            probe.focusList()
            _ = probe.press(keyCode: 38, characters: "j")
            Check.equal(probe.cardShowsHover(ids[0]), false, "hover: vim j hides it too")
            settings.vimKeybinds = false
            probe.mouseMoved()
            probe.setHovered(ids[0], false)
            probe.select(nil)
        } else { Check.expect(false, "hover: two notes") }
        vc.showFolderList()
        probe.layoutNow(); spin(); probe.layoutNow()
        let fids = probe.folderRowIDs
        probe.setFolderRowHovered(fids[0], true)
        Check.equal(probe.folderRowShowsHover(fids[0]), true, "hover: pointer over the first folder")
        _ = probe.press(keyCode: 125, characters: "\u{F701}")
        _ = probe.press(keyCode: 125, characters: "\u{F701}")
        Check.equal(probe.folderRowShowsHover(fids[0]), false, "hover: ↓ on the folder list hides the folder hover")
        probe.mouseMoved()
        Check.equal(probe.folderRowShowsHover(fids[0]), true, "hover: mouse move shows the folder hover again")
        probe.setFolderRowHovered(fids[0], false)
    }

    // MARK: Fold: ⌥⌘← / ⌥⌘→ and the fold button
    do {
        let ff = store.createFolder(name: "Fold Test")
        let tall = store.createNote(in: ff.id, body: "Fold me\n1\n2\n3\n4\n5\n6", mode: .standard, position: .bottom)
        vc.showFolder(ff.id)
        probe.layoutNow(); spin(); probe.layoutNow()
        probe.ensureEditor(of: tall.id)
        probe.clickCard(tall.id)
        probe.layoutNow(); spin()
        Check.equal(probe.isEditorFocused(tall.id), true, "fold: editing the note")
        _ = probe.press(keyCode: 123, characters: "\u{F702}", modifiers: [.command, .option])
        Check.equal(store.note(id: tall.id)?.isFolded, true, "⌥⌘← folds the note being edited")
        Check.equal(probe.selectedNoteID, tall.id, "the folded note stays selected")
        probe.panelFocusChanged(true)
        Check.equal(probe.cardShowsSelectionRing(tall.id), true, "ring on the selected folded card")
        _ = probe.press(keyCode: 124, characters: "\u{F703}", modifiers: [.command, .option])
        Check.equal(store.note(id: tall.id)?.isFolded, false, "⌥⌘→ unfolds the selected note")
        Check.equal(probe.cardShowsSelectionRing(tall.id), false, "no ring on the selected unfolded card")
        probe.toggleExpand(tall.id)
        Check.equal(probe.cardShowsSelectionRing(tall.id), true, "ring on the selected expanded card")
        probe.toggleExpand(tall.id)
        Check.equal(probe.cardShowsSelectionRing(tall.id), false, "no ring after collapsing")
        probe.layoutNow(); spin(); probe.layoutNow()
        probe.mouseMoved()
        probe.setHovered(tall.id, true)
        probe.layoutNow()
        Check.expect(probe.foldButtonFrame(of: tall.id) != nil, "fold button on hover")
        probe.select(tall.id)
        _ = probe.press(keyCode: 49, characters: " ")
        Check.equal(store.note(id: tall.id)?.isFolded, false, "Space does not fold the selected note")
        _ = probe.press(keyCode: 49, characters: " ", modifiers: [.shift])
        Check.equal(store.note(id: tall.id)?.isFolded, false, "⇧Space does not fold the selected note")
        _ = probe.press(keyCode: 14, characters: "e", modifiers: [.command])
        Check.equal(probe.isExpanded(tall.id), false, "⌘E in the list does not expand (⇧⌘E does)")
        probe.layoutNow(); spin(); probe.layoutNow()
        probe.mouseMoved()
        probe.setHovered(tall.id, true)
        probe.layoutNow()
        probe.clickFoldButton(tall.id)
        Check.equal(store.note(id: tall.id)?.isFolded, true, "the fold button folds the note")
        probe.layoutNow()
        Check.equal(probe.foldButtonFrame(of: tall.id), nil, "no fold button on a folded card")
        probe.setHovered(tall.id, false)
    }

    print("Wrote \(written.count) snapshots to \(out.path): \(written.joined(separator: ", "))")
    Check.finish()
}

/// Scratch entries in the panel: opening Scratch to type starts an entry, Save as Note, a long day.
/// Uses the real markdown editor (the main checks use plain editors, which have no entries).
@MainActor
func scratchEntryChecks(out: URL, spin: () -> Void) -> [String] {
    let suite = "NoteBarUISnapshotEntries"
    UserDefaults().removePersistentDomain(forName: suite)
    let settings = AppSettings(defaults: UserDefaults(suiteName: suite)!)
    let store = InMemoryNoteStore(seed: false)
    _ = store.createFolder(name: "Notes")
    _ = store.createFolder(name: "Work")
    let env = AppEnvironment(store: store, backups: nil, settings: settings,
                             themes: ThemeManager(settings: settings, store: store), editorFactory: MarkdownEditorFactory())
    let vc = NotesRootViewController(env: env)
    vc.stateDefaults = UserDefaults(suiteName: suite)!
    env.presenter = vc
    let probe = vc.probe
    let backdrop = Backdrop(frame: NSRect(x: 0, y: 0, width: 450, height: 740))
    vc.view.frame = NSRect(x: 15, y: 10, width: 420, height: 720)
    backdrop.addSubview(vc.view)
    let window = NSWindow(contentRect: backdrop.frame, styleMask: [.borderless], backing: .buffered, defer: true)
    window.isReleasedWhenClosed = false
    window.contentView = backdrop
    window.appearance = NSAppearance(named: .aqua)
    defer { window.contentView = nil; UserDefaults().removePersistentDomain(forName: suite) }
    var written: [String] = []
    func render(_ name: String) {
        spin(); probe.layoutNow(); spin(); probe.layoutNow()
        backdrop.layoutSubtreeIfNeeded()
        guard let rep = backdrop.bitmapImageRepForCachingDisplay(in: backdrop.bounds) else { return }
        backdrop.cacheDisplay(in: backdrop.bounds, to: rep)
        if let data = rep.representation(using: .png, properties: [:]) {
            try? data.write(to: out.appendingPathComponent(name + ".png"))
            written.append(name)
        }
    }
    // The clock is two hours ahead of the notes' edit times: the merge window has always passed.
    let scratch = env.scratch
    scratch.now = { Date().addingTimeInterval(7200) }
    scratch.refresh()

    // Entries: opening Scratch to type starts a new entry at the end. The store hears of it with the
    // first text.
    vc.showFolderList()
    let e = scratch.todayNote(create: true)!
    probe.showScratch(edit: true)
    probe.layoutNow(); spin()
    if let ed = probe.editor(of: e.id) as? MarkdownNoteEditor {
        Check.equal(ScratchEntries.markers(in: ed.markdown).count, 1, "entries: opening Scratch starts an entry")
        Check.equal(store.note(id: e.id)?.body, "", "entries: the store has no empty entry")
        let tv = ed.textViewForTesting
        tv.insertText("first thought", replacementRange: tv.selectedRange())
        spin()
        let first = store.note(id: e.id)?.body ?? ""
        Check.expect(first.hasSuffix("---\nfirst thought") && ScratchEntries.markers(in: first).count == 1,
                     "entries: the first text saves its entry (\(first.debugDescription))")
        vc.showFolderList()
        probe.showScratch(edit: true)
        probe.layoutNow(); spin()
        let again = probe.editor(of: e.id) as? MarkdownNoteEditor
        Check.equal(ScratchEntries.markers(in: again?.markdown ?? "").count, 2, "entries: opening again starts the next entry")
        Check.equal(again?.selectedRangeForTesting.location, again?.textViewForTesting.string.utf16.count,
                    "entries: the caret is in the new entry")
        Check.equal(store.note(id: e.id)?.body, first, "entries: not saved before text is typed")
        render("30-scratch-entries-light")
        // Leaving without typing drops it.
        vc.showFolderList()
        spin()
        Check.equal(store.note(id: e.id)?.body, first, "entries: an entry left empty is not kept")
        // Showing Scratch without the caret (the day stepper, reveal) starts nothing.
        probe.showScratch(edit: false)
        probe.layoutNow(); spin()
        Check.equal(ScratchEntries.markers(in: (probe.editor(of: e.id) as? MarkdownNoteEditor)?.markdown ?? first).count, 1,
                    "entries: showing Scratch without typing starts no entry")

        // Save as Note: the copy has no markers. Save Entry as Note: one entry's text.
        let target = store.folders()[0]
        probe.saveScratchAsNote(e.id, toFolder: target.id)
        let saved = store.notes(in: target.id).first { !$0.isPinned }
        Check.equal(saved?.body, "first thought", "entries: Save as Note leaves the markers out")
        if let saved { store.deleteNote(id: saved.id) }
        probe.dismissToast()
        probe.ensureEditor(of: e.id)
        let items = probe.editor(of: e.id)?.entryMenuItems?("one entry") ?? []
        Check.equal(items.map(\.title), ["Save Entry as Note"], "entries: the card adds Save Entry as Note")
        let folders = items.first?.submenu?.items.filter { !$0.isSectionHeader } ?? []
        Check.equal(folders.map(\.title), store.folders().map(\.name), "entries: with the folders to save in")
        if let item = folders.first, let action = item.action { NSApp.sendAction(action, to: item.target, from: item) }
        let copy = store.notes(in: target.id).first { !$0.isPinned }
        Check.equal(copy?.body, "one entry", "entries: Save Entry as Note copies that entry")
        if let copy { store.deleteNote(id: copy.id) }
        probe.dismissToast()

        // A long day opens at its end, where the newest entry is.
        let long = (0..<40).map { "--- \(String(format: "%02d", 8 + $0 / 4)):\(String(format: "%02d", ($0 % 4) * 15)) ---\nentry \($0)\nmore text" }
            .joined(separator: "\n")
        store.updateNoteBody(id: e.id, body: long)
        vc.showFolderList()
        probe.showScratch(edit: false)
        probe.layoutNow(); spin(); probe.layoutNow()
        Check.expect(probe.listScrollOffset > 100 && probe.listIsScrolledToEnd,
                     "entries: a long day opens scrolled to its end (\(probe.listScrollOffset))")
        // To type: the caret is in a new entry at the end, and the end shows.
        vc.showFolderList()
        probe.showScratch(edit: true)
        probe.layoutNow(); spin(); probe.layoutNow()
        Check.expect(probe.listIsScrolledToEnd, "entries: opening a long day to type shows its end")
        render("32-scratch-entries-long-typing-light")
        render("31-scratch-entries-long-light")
    } else {
        Check.expect(false, "entries: today's editor")
    }

    return written
}

/// ⌃D / ⌃U in a long note scroll the notes list.
/// Uses the real markdown editor (the main checks use plain editors, which have no vim layer).
@MainActor
func vimScrollChecks(spin: () -> Void) {
    let suite = "NoteBarUISnapshotVimScroll"
    UserDefaults().removePersistentDomain(forName: suite)
    let settings = AppSettings(defaults: UserDefaults(suiteName: suite)!)
    settings.vimKeybinds = true
    let store = InMemoryNoteStore(seed: false)
    let folder = store.createFolder(name: "Long")
    let body = (0..<200).map { $0 % 10 == 9 ? "" : "line \($0)" }.joined(separator: "\n")
    let note = store.createNote(in: folder.id, body: body, mode: .standard, position: .top)
    let env = AppEnvironment(store: store, backups: nil, settings: settings,
                             themes: ThemeManager(settings: settings, store: store), editorFactory: MarkdownEditorFactory())
    let vc = NotesRootViewController(env: env)
    vc.stateDefaults = UserDefaults(suiteName: suite)!
    env.presenter = vc
    let probe = vc.probe
    vc.view.frame = NSRect(x: 0, y: 0, width: 420, height: 720)
    let window = NSWindow(contentRect: vc.view.frame, styleMask: [.borderless], backing: .buffered, defer: true)
    window.isReleasedWhenClosed = false
    window.contentView = vc.view
    defer { window.contentView = nil; UserDefaults().removePersistentDomain(forName: suite) }

    vc.showFolder(folder.id)
    probe.layoutNow(); spin(); probe.layoutNow()
    probe.focusList()
    probe.select(note.id)
    probe.press(keyCode: 37, characters: "l")
    probe.layoutNow(); spin(); probe.layoutNow()
    Check.equal(probe.focusedNoteID, note.id, "vim scroll: l edits the long note")
    Check.equal(probe.editor(of: note.id)?.vimMode, .normal, "vim scroll: the editor is in Normal mode")
    func key(_ ch: String, _ code: UInt16, _ mods: NSEvent.ModifierFlags = []) {
        probe.pressInFirstResponder(keyCode: code, characters: ch, modifiers: mods)
        probe.layoutNow()
    }
    key("g", 5); key("g", 5)
    let top = probe.listScrollOffset
    key("d", 2, [.control])
    let down = probe.listScrollOffset
    Check.expect(down > top + 50, "⌃D scrolls the list down (\(top) → \(down))")
    key("d", 2, [.control])
    let down2 = probe.listScrollOffset
    Check.expect(down2 > down + 50, "⌃D again scrolls further (\(down) → \(down2))")
    // A fixed number of lines each time (pixel distances differ a little: empty lines are shorter).
    Check.expect(abs((down2 - down) - (down - top)) < 0.1 * (down - top),
                 "⌃D scrolls about the same distance each time (\(top) → \(down) → \(down2))")
    Check.expect(down - top > 0.3 * 720 && down - top < 0.6 * 720, "⌃D scrolls about half the list (\(down - top))")
    key("u", 32, [.control])
    Check.expect(abs(probe.listScrollOffset - down) < 2, "⌃U scrolls back by the same distance (\(probe.listScrollOffset) vs \(down))")
    Check.equal(probe.editor(of: note.id)?.vimMode, .normal, "still in Normal mode")
    Check.equal(store.note(id: note.id)?.body, body, "⌃D / ⌃U do not edit")
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
    var deleteAlerts = 0
    probe.onDestructiveAlert { _ in deleteAlerts += 1; return false }
    probe.vimCommand(.delete, on: c.id)
    Check.equal(deleteAlerts, 1, "gx / :delete asks first")
    Check.expect(store.note(id: c.id) != nil, "Cancel in the alert keeps the note")
    probe.confirmDestructiveAlerts(true)
    probe.vimCommand(.delete, on: c.id)
    Check.equal(probe.pendingDeletion, c.id, "gx / :delete deletes with undo after the alert")
    probe.undoDelete()
    probe.confirmDestructiveAlerts(nil)
    probe.vimCommand(.navigateUp, on: a.id)
    Check.expect(probe.folderRowsVisible, "⌃[ in Normal mode goes up")

    // Card keys on the folder list.
    var menus: [NSMenu] = []
    probe.captureMenus { menus.append($0) }
    probe.focusList()
    key("G")
    if probe.trashRowCount != nil {
        Check.equal(probe.selectedSpecialRow, "trash", "vim: G selects the last row (Recently Deleted)")
        key("k")
    }
    if probe.archiveRowCount != nil { key("k") }
    Check.equal(probe.selectedFolderID, probe.folderRowIDs.last, "vim: G, then k past the special rows: the last folder")
    key("g"); key("g"); Check.equal(probe.selectedFolderID, probe.folderRowIDs.first, "vim: gg selects the first folder")
    while probe.selectedFolderID != vf.id { key("j") }
    key("g"); key("p"); Check.equal(store.folder(id: vf.id)?.isPinned, true, "vim: gp pins the folder")
    key("g"); key("p"); Check.equal(store.folder(id: vf.id)?.isPinned, false, "vim: gp again unpins it")
    key("g"); key("c")
    Check.equal(menus.count, 1, "vim: gc pops up the folder color menu")
    Check.equal(menus.last?.items.first?.title, "Color", "vim: gc menu is the color menu")
    key("c"); key("w"); Check.equal(probe.renamingFolderID, vf.id, "vim: cw renames the folder")
    probe.endRename()
    probe.focusList()
    let before = Set(probe.folderRowIDs)
    key("o")
    let added = Set(probe.folderRowIDs).subtracting(before)
    Check.equal(added.count, 1, "vim: o adds a folder")
    Check.equal(probe.renamingFolderID, added.first, "vim: o starts renaming the new folder")
    probe.endRename()
    probe.focusList()
    if let nf = added.first {
        key("g"); key("g")
        for _ in 0..<(probe.folderRowIDs.firstIndex(of: nf) ?? 0) { key("j") }
        Check.equal(probe.selectedFolderID, nf, "vim: selected the new folder")
        probe.confirmDestructiveAlerts(true)
        key("d"); key("d")
        Check.expect(store.folder(id: nf) == nil, "vim: dd deletes the folder (after the alert)")
        probe.confirmDestructiveAlerts(nil)
    }

    // Card keys on a selected note (no editing).
    vc.showFolder(vf.id)
    probe.layoutNow(); spin(); probe.layoutNow()
    probe.focusList()
    key("g"); key("g"); Check.equal(probe.selectedNoteID, a.id, "vim: gg selects the first note")
    key("G"); Check.equal(probe.selectedNoteID, c.id, "vim: G selects the last note")
    key("g"); key("p"); Check.equal(store.note(id: c.id)?.isPinned, true, "vim: gp pins the selected note")
    key("g"); key("p")
    key("z"); key("a"); Check.equal(store.note(id: c.id)?.isFolded, true, "vim: za folds the selected note")
    key("z"); key("o"); Check.equal(store.note(id: c.id)?.isFolded, false, "vim: zo unfolds it")
    key("z"); key("c"); Check.equal(store.note(id: c.id)?.isFolded, true, "vim: zc folds it")
    key("z"); key("o")
    Check.equal(probe.isEditorFocused(c.id), false, "vim: list keys do not start editing")
    key("g"); key("e"); Check.equal(probe.isExpanded(c.id), true, "vim: ge expands the selected card")
    key("g"); key("e"); Check.equal(probe.isExpanded(c.id), false, "vim: ge again collapses it")
    probe.vimCommand(.toggleExpand, on: c.id)
    Check.equal(probe.isExpanded(c.id), true, "vim: ge in a note expands the card")
    probe.vimCommand(.toggleExpand, on: c.id)
    Check.equal(probe.isExpanded(c.id), false, "vim: ge in a note collapses it")
    probe.focusList()
    probe.select(c.id)
    menus = []
    key("g"); key("c"); Check.equal(menus.count, 1, "vim: gc pops up the note color menu")
    key("g"); key("m"); Check.equal(menus.count, 2, "vim: gm pops up the move menu")
    probe.confirmDestructiveAlerts(true)
    key("d"); key("d"); Check.equal(probe.pendingDeletion, c.id, "vim: dd deletes the selected note (after the alert, with undo)")
    probe.confirmDestructiveAlerts(nil)
    probe.undoDelete()
    probe.focusList()
    probe.select(a.id)
    key("g"); key("q")   // not a command: beeps, does nothing
    Check.equal(probe.selectedNoteID, a.id, "vim: an unknown g command does nothing")
    // gj / gk reorder the selected note in its folder; it stays selected.
    let order = probe.displayedNoteIDs
    if let i = order.firstIndex(of: a.id), i + 1 < order.count, !(store.note(id: order[i + 1])?.isPinned ?? true) || store.note(id: a.id)!.isPinned {
        key("g"); key("j")
        Check.equal(probe.displayedNoteIDs.firstIndex(of: a.id), i + 1, "vim: gj moves the note down")
        Check.equal(probe.selectedNoteID, a.id, "vim: the moved note stays selected")
        key("g"); key("k")
        Check.equal(probe.displayedNoteIDs, order, "vim: gk moves it back up")
    } else {
        Check.expect(false, "vim: gj / gk need a note with a same-zone note below (\(order))")
    }
    probe.captureMenus(nil)
    settings.vimKeybinds = false
}

@MainActor var renderHook: ((String) -> Void)?

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
    probe.confirmDestructiveAlerts(true)
    probe.deleteFolder(uf.id)
    Check.equal(store.folder(id: uf.id), nil, "folder deleted (trash)")
    Check.equal(store.note(id: n1.id), nil, "its notes are hidden")
    Check.expect(probe.isToastVisible, "folder delete toast")
    cmdZ()
    Check.expect(store.folder(id: uf.id) != nil && store.note(id: n1.id) != nil, "⌘Z restores the folder and its notes")
    probe.deleteFolder(uf.id)
    probe.undoDelete()
    Check.expect(store.folder(id: uf.id) != nil, "folder toast Undo restores")

    // Recently Deleted row and menu: shown whenever the trash has items (any Keep deleted items).
    let settings = probe.settings
    store.purgeTrash(deletedBefore: .distantFuture)
    vc.showFolderList()
    Check.equal(probe.trashRowCount, nil, "no row while the trash is empty")
    let gone = store.createNote(in: uf.id, body: "Gone note\nbody", mode: .standard, position: .top)
    vc.showFolder(uf.id)
    probe.deleteWithUndo(gone.id)
    vc.showFolderList()
    probe.layoutNow(); spin()
    Check.equal(probe.trashRowCount, 1, "Recently Deleted row shows the count")
    let titles = probe.trashMenuTitles
    Check.expect(titles.contains("Gone note"), "trash menu lists the note (\(titles))")
    Check.expect(titles.contains("Empty Recently Deleted…"), "trash menu has Empty")
    probe.trashMenuRun("Gone note", "Restore")
    Check.expect(store.note(id: gone.id) != nil, "Restore from the menu")
    Check.equal(probe.trashRowCount, nil, "row hidden when the trash is empty again")
    probe.deleteWithUndo(gone.id)
    var foreverAlerts: [String] = []
    probe.onDestructiveAlert { foreverAlerts.append($0); return false }
    probe.trashMenuRun("Gone note", "Delete Now")
    Check.equal(foreverAlerts, ["Delete “Gone note” for good?"], "Delete Now asks first")
    Check.equal(store.trashedNotes().map(\.id), [gone.id], "Cancel keeps it in the trash")
    probe.confirmDestructiveAlerts(true)
    probe.trashMenuRun("Gone note", "Delete Now")
    Check.expect(store.trashedNotes().isEmpty && store.note(id: gone.id) == nil, "Delete Now removes it for good")
    let g2 = store.createNote(in: uf.id, body: "Another\nx", mode: .standard, position: .top)
    probe.deleteWithUndo(g2.id)
    probe.confirmDestructiveAlerts(true)
    probe.trashMenuRun("Empty Recently Deleted…")
    Check.expect(store.trashedNotes().isEmpty, "Empty Recently Deleted")
    probe.confirmDestructiveAlerts(nil)
    let g3 = store.createNote(in: uf.id, body: "Shown in the row\nx", mode: .standard, position: .top)
    probe.deleteWithUndo(g3.id)
    probe.dismissToast()
    vc.showFolderList()
    probe.layoutNow(); spin()
    renderHook?("23-recently-deleted-light")
    settings.deletedItemsRetention = .recentlyDeleted
    Check.equal(probe.trashRowCount, 1, "the row stays with 30 days")
    settings.deletedItemsRetention = .oneHour
    Check.equal(probe.trashRowCount, 1, "the row stays with the default 1 hour")
    Check.expect(store.trashedNotes().count == 1, "changing the setting deletes nothing at once")
    store.purgeTrash(deletedBefore: .distantFuture)
}

@MainActor
func archiveChecks(vc: NotesRootViewController, probe: NotesUIProbe, store: InMemoryNoteStore, spin: () -> Void) {
    func cmdZ() { spin(); probe.press(keyCode: 6, characters: "z", modifiers: [.command]); spin() }
    func optCmdA() { probe.press(keyCode: 0, characters: "a", modifiers: [.command, .option]) }
    let af = store.createFolder(name: "Archive Test")
    let a = store.createNote(in: af.id, body: "Keep me\nfirst", mode: .standard, position: .bottom)
    let b = store.createNote(in: af.id, body: "Old plan\nsecond", mode: .standard, position: .bottom)
    let c = store.createNote(in: af.id, body: "Old idea\nthird", mode: .standard, position: .bottom)
    for n in store.archivedNotes() { store.unarchiveNote(id: n.id) }
    vc.showFolderList()
    Check.equal(probe.archiveRowCount, nil, "no Archive row while nothing is archived")

    // ⌥⌘A on the selected note.
    vc.showFolder(af.id)
    probe.layoutNow(); spin()
    probe.select(b.id)
    optCmdA()
    Check.expect(store.note(id: b.id)?.isArchived == true, "⌥⌘A archives the selected note")
    Check.equal(probe.displayedNoteIDs, [a.id, c.id], "the archived note leaves the folder")
    Check.equal(probe.selectedNoteID, c.id, "the next note gets the selection")
    Check.equal(probe.toastMessage, "Note archived", "archive toast")
    probe.tapToastAction()
    Check.expect(store.note(id: b.id)?.isArchived == false, "toast Undo unarchives")
    Check.equal(probe.displayedNoteIDs, [a.id, b.id, c.id], "and the note is back at its place")
    probe.select(b.id)
    optCmdA()
    cmdZ()
    Check.expect(store.note(id: b.id)?.isArchived == false, "⌘Z unarchives")
    probe.select(b.id)
    optCmdA()
    Check.expect(store.note(id: b.id)?.isArchived == true, "archived again")

    // The archive button on the card.
    probe.layoutNow()
    probe.mouseMoved()
    probe.setHovered(c.id, true)
    probe.layoutNow()
    Check.equal(probe.archiveButtonToolTip(c.id), "Archive (⌥⌘A)", "archive button on the card")
    Check.equal(probe.hiddenActionCount(c.id), 0, "the tray holds copy, archive and delete")
    var trashAlerts = 0
    probe.onDestructiveAlert { _ in trashAlerts += 1; return false }
    probe.clickTrashButton(c.id)
    Check.equal(trashAlerts, 1, "the card's trash button asks first")
    Check.expect(store.note(id: c.id) != nil, "Cancel keeps the note")
    probe.confirmDestructiveAlerts(nil)
    probe.clickArchiveButton(c.id)
    probe.setHovered(c.id, false)
    Check.expect(store.note(id: c.id)?.isArchived == true, "the archive button archives the note")

    // vim: ga on a selected note, :archive / :unarchive from the editor.
    probe.select(a.id)
    probe.press(keyCode: 5, characters: "g"); probe.press(keyCode: 0, characters: "a")
    Check.expect(store.note(id: a.id)?.isArchived != true, "ga does nothing with vim keys off")
    probe.settings.vimKeybinds = true
    probe.select(a.id)
    probe.press(keyCode: 5, characters: "g"); probe.press(keyCode: 0, characters: "a")
    Check.expect(store.note(id: a.id)?.isArchived == true, "vim: ga archives the selected note")
    probe.settings.vimKeybinds = false
    store.unarchiveNote(id: a.id)
    probe.vimCommand(.setArchived(true), on: a.id)
    Check.expect(store.note(id: a.id)?.isArchived == true, ":archive archives the note")
    vc.showArchive()
    probe.layoutNow(); spin()
    probe.vimCommand(.setArchived(false), on: a.id)
    Check.expect(store.note(id: a.id)?.isArchived == false, ":unarchive in the archive brings it back")

    // The Archive row and screen.
    vc.showFolderList()
    probe.layoutNow(); spin()
    Check.equal(probe.archiveRowCount, 2, "Archive row shows the count")
    renderHook?("24-folders-archive-light")
    probe.clickArchiveRow()
    probe.layoutNow(); spin()
    Check.equal(probe.headerTitle, "Archive", "the Archive row opens the archive")
    Check.equal(probe.displayedNoteIDs, [c.id, b.id], "archive lists the archived notes, most recent first")
    Check.equal(probe.cardFolderLabel(c.id), "Archive Test", "archived cards show their folder")
    Check.expect(!probe.isPlusButtonVisible, "no + button in the archive")
    Check.expect(!probe.cardMenuItems(for: c.id).contains("Move"), "no Move in the menu of an archived note")
    var moveMenus = 0
    probe.captureMenus { _ in moveMenus += 1 }
    probe.select(c.id)
    probe.press(keyCode: 46, characters: "m", modifiers: [.command, .shift])
    Check.equal(moveMenus, 0, "⇧⌘M does nothing on an archived note")
    probe.captureMenus(nil)
    renderHook?("25-archive-light")
    probe.layoutNow()
    probe.mouseMoved()
    probe.setHovered(b.id, true)
    probe.layoutNow()
    Check.equal(probe.archiveButtonToolTip(b.id), "Unarchive (⌥⌘A)", "the button unarchives in the archive")
    probe.setHovered(b.id, false)
    probe.select(b.id)
    optCmdA()
    Check.expect(store.note(id: b.id)?.isArchived == false, "⌥⌘A in the archive unarchives")
    Check.equal(probe.toastMessage, "Moved back to “Archive Test”", "unarchive toast names the folder")
    Check.equal(probe.displayedNoteIDs, [c.id], "the note leaves the archive")
    probe.goBack()
    Check.expect(probe.folderRowsVisible, "back from the archive goes to the folder list")
    Check.equal(probe.selectedSpecialRow, "archive", "back from the archive selects the Archive row")

    // Keyboard: ↓ past the last folder reaches Archive, then Recently Deleted; ↩ opens them.
    let trashed = store.createNote(in: af.id, body: "Trashed for the row", mode: .standard, position: .top)
    store.trashNote(id: trashed.id)
    probe.focusList()
    probe.press(keyCode: 115, characters: "\u{F729}")  // Home
    Check.expect(probe.selectedFolderID != nil && probe.selectedSpecialRow == nil, "Home selects the first folder")
    probe.press(keyCode: 119, characters: "\u{F72B}")  // End
    Check.equal(probe.selectedSpecialRow, "trash", "End selects Recently Deleted")
    Check.equal(probe.selectedFolderID, nil, "no folder selected with it")
    probe.press(keyCode: 126, characters: "\u{F700}")  // ↑
    Check.equal(probe.selectedSpecialRow, "archive", "↑ selects Archive")
    probe.press(keyCode: 126, characters: "\u{F700}")
    Check.expect(probe.selectedSpecialRow == nil && probe.selectedFolderID == probe.folderRowIDs.last, "↑ again: the last folder")
    probe.press(keyCode: 125, characters: "\u{F701}")  // ↓
    probe.press(keyCode: 36, characters: "\r")
    Check.equal(probe.headerTitle, "Archive", "↩ on the Archive row opens the archive")
    probe.goBack()
    var trashMenus = 0
    probe.captureMenus { _ in trashMenus += 1 }
    probe.press(keyCode: 125, characters: "\u{F701}")
    Check.equal(probe.selectedSpecialRow, "trash", "↓ from Archive: Recently Deleted")
    probe.press(keyCode: 36, characters: "\r")
    Check.equal(trashMenus, 1, "↩ on Recently Deleted opens its menu")
    probe.captureMenus(nil)
    store.purgeTrash(deletedBefore: .distantFuture)
    Check.equal(probe.selectedSpecialRow, nil, "the selection goes when its row goes")

    // Search: archived notes only with the Archive chip; search from the archive finds only archived notes.
    vc.showFolder(af.id)
    probe.setSearchQuery("old", allFolders: true)
    Check.equal(probe.displayedNoteIDs, [b.id], "search skips archived notes")
    Check.expect(probe.isArchiveChipVisible, "the Archive chip is shown")
    probe.setSearchIncludesArchive(true)
    Check.equal(Set(probe.displayedNoteIDs), [b.id, c.id], "the Archive chip finds archived notes too")
    Check.equal(probe.cardFolderLabel(c.id), "Archive Test · Archived", "archived results are marked")
    probe.goBack()
    vc.showArchive()
    probe.setSearchQuery("old")
    Check.equal(probe.displayedNoteIDs, [c.id], "search from the archive finds archived notes only")
    Check.expect(!probe.isArchiveChipVisible, "no Archive chip when searching the archive")
    probe.goBack()
    Check.equal(probe.headerTitle, "Archive", "Esc from search returns to the archive")
    for n in store.archivedNotes() { store.unarchiveNote(id: n.id) }
    vc.showFolderList()
    Check.equal(probe.archiveRowCount, nil, "row hidden when the archive is empty again")
    store.deleteFolder(id: af.id)
}


@MainActor
func folderArchiveChecks(vc: NotesRootViewController, probe: NotesUIProbe, store: InMemoryNoteStore, spin: () -> Void) {
    func cmdZ() { spin(); probe.press(keyCode: 6, characters: "z", modifiers: [.command]); spin() }
    func optCmdA() { probe.press(keyCode: 0, characters: "a", modifiers: [.command, .option]) }
    let shelf = store.createFolder(name: "Shelf")
    let s1 = store.createNote(in: shelf.id, body: "Quince jam\nfirst", mode: .standard, position: .bottom)
    let s2 = store.createNote(in: shelf.id, body: "Shelf two", mode: .standard, position: .bottom)
    vc.showFolderList()
    probe.layoutNow(); spin()
    Check.equal(probe.archiveRowCount, nil, "folder archive: nothing archived yet")

    // Folder menu.
    Check.expect(probe.folderMenuItems(for: shelf.id).contains("Archive Folder"), "the folder menu has Archive Folder")
    probe.folderMenuRun(shelf.id, "Archive Folder")
    Check.expect(store.archivedFolder(id: shelf.id) != nil, "Archive Folder archives the folder")
    Check.expect(!probe.folderRowIDs.contains(shelf.id), "the archived folder leaves the folder list")
    Check.equal(probe.archiveRowCount, 1, "the Archive row counts the folder")
    Check.equal(probe.toastMessage, "Folder archived", "folder archive toast")
    probe.tapToastAction()
    Check.expect(store.folder(id: shelf.id) != nil, "toast Undo unarchives the folder")
    Check.expect(probe.folderRowIDs.contains(shelf.id), "and it is back in the list")

    // ⌥⌘A on the selected folder row, ⌘Z.
    probe.focusList()
    probe.selectFolder(shelf.id)
    let ids = probe.folderRowIDs
    let next = ids.firstIndex(of: shelf.id).map { $0 + 1 < ids.count ? ids[$0 + 1] : ids[$0 - 1] }
    optCmdA()
    Check.expect(store.archivedFolder(id: shelf.id) != nil, "⌥⌘A archives the selected folder")
    Check.equal(probe.selectedFolderID, next, "the neighbor row gets the selection")
    cmdZ()
    Check.expect(store.folder(id: shelf.id) != nil, "⌘Z unarchives the folder")

    // vim: ga on the selected folder.
    probe.settings.vimKeybinds = true
    probe.focusList()
    probe.selectFolder(shelf.id)
    probe.press(keyCode: 5, characters: "g"); probe.press(keyCode: 0, characters: "a")
    Check.expect(store.archivedFolder(id: shelf.id) != nil, "vim: ga archives the selected folder")
    probe.settings.vimKeybinds = false

    // The Archive row opens the Archive menu while folders are archived.
    var menus = 0
    probe.captureMenus { _ in menus += 1 }
    probe.clickArchiveRow()
    Check.equal(menus, 1, "the Archive row opens the Archive menu")
    probe.captureMenus(nil)
    Check.expect(probe.archiveMenuTitles.contains("Archived Notes") && probe.archiveMenuTitles.contains("Shelf"),
                 "the Archive menu lists the archived notes and the folder")

    // Open: the archived folder's notes, no + and no Move.
    probe.archiveMenuRun("Shelf", "Open")
    probe.layoutNow(); spin()
    Check.equal(probe.headerTitle, "Shelf", "Open shows the archived folder")
    Check.equal(probe.displayedNoteIDs, [s1.id, s2.id], "with its notes")
    Check.expect(!probe.isPlusButtonVisible, "no + button in an archived folder")
    Check.expect(!probe.cardMenuItems(for: s1.id).contains("Move"), "no Move for notes of an archived folder")
    renderHook?("26-archived-folder-light")
    probe.goBack()
    Check.expect(probe.folderRowsVisible, "back from the archived folder goes to the folder list")
    Check.equal(probe.selectedSpecialRow, "archive", "and selects the Archive row")

    // Unarchive while it is open: it becomes a normal folder.
    probe.archiveMenuRun("Shelf", "Open")
    probe.archiveMenuRun("Shelf", "Unarchive")
    probe.layoutNow(); spin()
    Check.expect(store.folder(id: shelf.id) != nil, "Unarchive puts the folder back")
    Check.equal(probe.headerTitle, "Shelf", "the open archived folder stays open as a normal folder")
    Check.expect(probe.isPlusButtonVisible, "with its + button")
    Check.equal(probe.toastMessage, "“Shelf” is back in the folder list", "unarchive toast")

    // Search: notes of archived folders only with the Archive chip, and from the archive.
    store.archiveFolder(id: shelf.id)
    vc.showFolderList()
    probe.setSearchQuery("quince", allFolders: true)
    Check.equal(probe.displayedNoteIDs, [], "search skips archived folders")
    probe.setSearchIncludesArchive(true)
    Check.equal(probe.displayedNoteIDs, [s1.id], "the Archive chip finds notes of archived folders")
    Check.equal(probe.cardFolderLabel(s1.id), "Shelf · Archived", "and marks them")
    probe.goBack()
    vc.showArchive()
    probe.setSearchQuery("quince")
    Check.equal(probe.displayedNoteIDs, [s1.id], "search from the archive finds notes of archived folders")
    probe.goBack()

    // Delete from the Archive menu: to the trash, restored it is archived again.
    vc.showFolderList()
    probe.confirmDestructiveAlerts(true)
    probe.archiveMenuRun("Shelf", "Delete Folder…")
    probe.confirmDestructiveAlerts(nil)
    Check.equal(store.trashedFolders().map(\.id), [shelf.id], "Delete Folder… moves the archived folder to the trash")
    Check.equal(probe.archiveRowCount, nil, "the Archive row goes with it")
    store.restoreFolder(id: shelf.id)
    Check.expect(store.archivedFolder(id: shelf.id) != nil, "restored, it is archived again")
    probe.commitDelete()
    store.deleteFolder(id: shelf.id)
    vc.showFolderList()
    Check.equal(probe.archiveRowCount, nil, "folder archive: clean at the end")
}


@MainActor
func scratchChecks(vc: NotesRootViewController, probe: NotesUIProbe, store: InMemoryNoteStore, env: AppEnvironment,
                   spin: () -> Void, render: (String, Bool) -> Void) {
    let settings = env.settings
    let scratch = env.scratch
    let start = Date()
    var clock = start
    scratch.now = { clock }
    scratch.refresh()
    func advance(days: Int) {
        clock = Calendar.current.date(byAdding: .day, value: days, to: clock)!
        scratch.refresh()
        probe.layoutNow(); spin()
    }
    let foldersBefore = store.folders().map(\.id)

    // Header button at the top level only.
    vc.showFolderList()
    Check.expect(probe.isScratchButtonVisible, "scratch: header button on the folder list")
    settings.scratchEnabled = false
    Check.expect(!probe.isScratchButtonVisible, "scratch: off hides the header button")
    probe.showScratch(edit: false)
    Check.equal(probe.scratchDay, nil, "scratch: off, nothing opens")
    settings.scratchEnabled = true
    Check.expect(probe.isScratchButtonVisible, "scratch: on shows the button again")

    // Today.
    probe.clickScratchButton()
    probe.layoutNow(); spin(); probe.layoutNow()
    let today = scratch.todayKey
    Check.equal(probe.scratchDay, today, "scratch: the button opens today")
    Check.equal(probe.headerTitle, "Scratch · Today", "scratch: header title")
    Check.expect(probe.isDayStepperVisible, "scratch: day stepper shown")
    Check.expect(!probe.isPlusButtonVisible, "scratch: no + button")
    Check.expect(!probe.canStepToEarlierDay && !probe.canStepToLaterDay, "scratch: nothing to step to yet")
    guard let todayNote = scratch.todayNote(create: false) else { Check.expect(false, "scratch: today's note"); return }
    Check.equal(probe.displayedNoteIDs, [todayNote.id], "scratch: one card, today's note")
    Check.equal(probe.focusedNoteID, todayNote.id, "scratch: the button focuses the note")
    Check.equal(probe.isCardReadOnly(todayNote.id), false, "scratch: today is editable")
    Check.equal(probe.isEditorReadOnly(todayNote.id), false, "scratch: today's editor is editable")
    Check.equal(store.folders().map(\.id), foldersBefore, "scratch: its folder is not in the folder list")
    store.updateNoteBody(id: todayNote.id, body: "zebra scratch line\n- call back re: build")
    Check.equal(store.search("zebra", in: nil, includeArchived: true).map(\.id), [], "scratch: search skips Scratch")
    probe.setHovered(todayNote.id, true)
    probe.layoutNow()
    Check.equal(probe.isPinButtonHidden(todayNote.id), true, "scratch: no pin button")
    Check.equal(probe.trashButtonToolTip(todayNote.id), "Clear Scratch", "scratch: the trash button clears today")
    render("27-scratch-today-light", false)
    probe.setHovered(todayNote.id, false)
    let menu = probe.cardMenuTitles(todayNote.id)
    Check.expect(menu.contains("Save as Note") && menu.contains("Clear Scratch") && !menu.contains("Pin")
                 && !menu.contains("Move"), "scratch: today's card menu")

    // Clear (the delete action on today's note) with undo.
    probe.deleteNoteAction(todayNote.id)
    Check.equal(store.note(id: todayNote.id)?.body, "", "scratch: delete on today clears it")
    Check.equal(probe.toastMessage, "Scratch cleared", "scratch: clear toast")
    probe.tapToastAction()
    Check.equal(store.note(id: todayNote.id)?.body, "zebra scratch line\n- call back re: build", "scratch: toast Undo brings the text back")
    probe.dismissToast()

    // Pin / archive / fold never apply.
    probe.select(todayNote.id)
    probe.press(keyCode: 0, characters: "a", modifiers: [.command, .option])
    Check.expect(store.note(id: todayNote.id)?.isArchived == false, "scratch: ⌥⌘A does not archive")

    // Save as Note: a copy at the top of the folder, Scratch keeps its text.
    let target = store.folders()[0]
    probe.saveScratchAsNote(todayNote.id, toFolder: target.id)
    let saved = store.notes(in: target.id).first { !$0.isPinned }
    Check.equal(saved?.body, "zebra scratch line\n- call back re: build", "scratch: Save as Note copies the text")
    Check.expect(saved?.isScratch == false && saved?.id != todayNote.id, "scratch: the copy is a normal note")
    Check.equal(store.note(id: todayNote.id)?.body, "zebra scratch line\n- call back re: build", "scratch: today keeps its text")
    Check.equal(probe.scratchDay, today, "scratch: still on Scratch after saving")
    if let saved { store.deleteNote(id: saved.id) }
    probe.dismissToast()

    // A new day: the screen moves on to an empty today; yesterday is read-only.
    probe.select(nil)
    probe.focusList()
    advance(days: 1)
    let day2 = scratch.todayKey
    Check.expect(day2 > today, "scratch: the day changed")
    Check.equal(probe.scratchDay, day2, "scratch: the screen follows the new day")
    Check.equal(probe.headerTitle, "Scratch · Today", "scratch: title of the new day")
    let day2Note = scratch.todayNote(create: false)
    Check.equal(day2Note?.body, "", "scratch: the new day starts empty")
    Check.expect(probe.canStepToEarlierDay && !probe.canStepToLaterDay, "scratch: ◀ enabled, ▶ disabled on today")
    probe.press(keyCode: 33, characters: "{", modifiers: [.command, .shift])
    probe.layoutNow(); spin()
    Check.equal(probe.scratchDay, today, "scratch: ⇧⌘[ steps to yesterday")
    Check.equal(probe.headerTitle, "Scratch · Yesterday", "scratch: yesterday's title")
    Check.equal(probe.displayedNoteIDs, [todayNote.id], "scratch: yesterday's note")
    Check.equal(probe.isCardReadOnly(todayNote.id), true, "scratch: yesterday is read-only")
    probe.ensureEditor(of: todayNote.id)
    Check.equal(probe.isEditorReadOnly(todayNote.id), true, "scratch: yesterday's editor is read-only")
    Check.expect(!probe.canStepToEarlierDay && probe.canStepToLaterDay, "scratch: ◀ disabled, ▶ enabled on the oldest day")
    let pastMenu = probe.cardMenuTitles(todayNote.id)
    Check.expect(pastMenu.contains("Save as Note") && pastMenu.contains("Delete This Day") && !pastMenu.contains("Color"),
                 "scratch: an earlier day's card menu")
    probe.layoutNow(); spin(); probe.layoutNow()
    probe.mouseMoved()   // earlier checks used the keyboard (it hides the hover)
    probe.setHovered(todayNote.id, true)
    Check.expect(probe.cardShowsHover(todayNote.id), "scratch: an earlier day's card shows its tray on hover")
    render("28-scratch-yesterday-light", false)
    render("29-scratch-yesterday-dark", true)
    probe.setHovered(todayNote.id, false)
    probe.stepScratchDay(1)
    Check.equal(probe.scratchDay, day2, "scratch: ▶ goes back to today")

    // An empty earlier day is dropped; days beyond the window go to the trash as normal notes.
    settings.scratchKeepDays = 2
    advance(days: 1)
    Check.expect(store.note(id: day2Note?.id ?? 0) == nil && store.trashedNotes().allSatisfy { $0.id != day2Note?.id },
                 "scratch: an empty day is deleted at rollover")
    Check.equal(scratch.days().count, 2, "scratch: today and the kept earlier day")
    advance(days: 2)
    Check.equal(store.note(id: todayNote.id), nil, "scratch: a day beyond the window leaves Scratch")
    let expired = store.trashedNotes().first { $0.id == todayNote.id }
    Check.expect(expired != nil && expired?.isScratch == false, "scratch: it is in the trash as a normal note")
    Check.expect(expired?.body.hasPrefix("# Scratch · ") == true, "scratch: headed with its date")
    Check.expect(expired?.body.hasSuffix("zebra scratch line\n- call back re: build") == true, "scratch: with its text")
    Check.equal(expired?.folderId, settings.lastFolderId ?? store.folders()[0].id, "scratch: in the last folder")
    store.restoreNote(id: todayNote.id)
    Check.expect(store.note(id: todayNote.id)?.isScratch == false
                 && store.notes(in: expired?.folderId ?? 0).contains { $0.id == todayNote.id },
                 "scratch: restored, it is a normal note in that folder")
    store.deleteNote(id: todayNote.id)

    // Delete an earlier day (alert, then the trash).
    let t = scratch.todayNote(create: true)!
    store.updateNoteBody(id: t.id, body: "old day")
    advance(days: 1)
    probe.stepScratchDay(-1)
    Check.equal(probe.displayedNoteIDs, [t.id], "scratch: on the earlier day")
    probe.confirmDestructiveAlerts(true)
    probe.deleteNoteAction(t.id)
    probe.confirmDestructiveAlerts(nil)
    Check.expect(store.note(id: t.id) == nil && store.trashedNotes().contains { $0.id == t.id }, "scratch: Delete This Day trashes it")
    Check.equal(probe.scratchDay, scratch.todayKey, "scratch: the screen moves to today")
    probe.panelUndo()
    Check.equal(store.note(id: t.id)?.isScratch, true, "scratch: ⌘Z brings the day back to Scratch")
    probe.commitDelete()

    // reveal(noteId:) of a Scratch note opens its day.
    vc.showFolderList()
    vc.reveal(noteId: t.id, edit: false)
    Check.equal(probe.scratchDay, t.scratchDay, "scratch: reveal opens the note's day")

    // Turning Scratch off while it shows: back to the folder list.
    settings.scratchEnabled = false
    Check.expect(probe.folderRowsVisible && probe.scratchDay == nil, "scratch: off goes back to the folder list")
    settings.scratchEnabled = true
    settings.scratchKeepDays = 7
    for n in store.scratchNotes(includingTrashed: true) { store.deleteNote(id: n.id) }
    probe.dismissToast()
}
