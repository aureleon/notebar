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

    // MARK: Start: there is no folder list, a folder is always open
    _ = vc.view
    Check.equal(settings.lastFolderId, folders.work.id, "start: no folder was open before, the first folder opens")
    Check.equal(vc.currentFolderId, store.folders()[0].id, "start: the first folder is open")
    Check.equal(store.folders()[0].id, folders.work.id, "pinned folder first")
    Check.expect(probe.folderTabsVisible, "start: the header has the folder chips")
    Check.equal(probe.folderTabKeys.dropFirst().first, NotesUIProbe.folderTabKey(folders.work.id), "the pinned folder's chip is first")
    Check.equal(probe.headerTitle, "Work", "start: the folder's name")
    render("01-start-light")
    render("02-start-dark", dark: true)

    // MARK: Notes list
    vc.showFolder(folders.notes.id)
    Check.equal(settings.lastFolderId, folders.notes.id, "lastFolderId remembered")
    Check.equal(probe.headerTitle, "Notes", "folder title")
    Check.expect(!probe.isBackButtonVisible, "no back arrow in a folder")
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
    Check.equal(vc.currentFolderId, folders.work.id, "Esc does not leave the folder")
    // Go up (⌘[) from a folder: nothing is above it.
    probe.press(keyCode: 33, characters: "[", modifiers: [.command])
    Check.equal(vc.currentFolderId, folders.work.id, "⌘[ in a folder does nothing")
    probe.press(keyCode: 123, characters: "\u{F702}")
    Check.equal(vc.currentFolderId, folders.work.id, "← in a folder does nothing")
    Check.equal(settings.lastFolderId, folders.work.id, "lastFolderId is the open folder")

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
    // The archive is the only screen with something above it: back shows the last folder.
    vc.showArchive()
    Check.expect(!probe.folderTabsVisible && probe.isBackButtonVisible, "archive: title and back arrow, no chips")
    Check.equal(settings.lastFolderId, folders.ideas.id, "the archive keeps lastFolderId for new-note hotkeys")
    probe.goBack()
    Check.equal(vc.currentFolderId, folders.ideas.id, "back from the archive shows the last folder")

    // Chip drag across the pinned boundary: Ideas to the start of the unpinned group.
    probe.moveFolder(folders.ideas.id, toGap: 1)
    Check.equal(store.folders().map(\.id)[1], folders.ideas.id, "chip drag to the gap after the pinned folder")
    probe.moveFolder(folders.ideas.id, toGap: 0)
    Check.equal(store.folders().map(\.id)[0], folders.work.id, "pinned folder stays first")
    Check.equal(Array(probe.folderTabKeys.dropFirst().dropLast()), store.folders().map { NotesUIProbe.folderTabKey($0.id) },
                "the chips follow the folder order")

    // Inline rename on the chip.
    probe.beginRename(folders.ideas.id)
    Check.equal(probe.renamingFolderID, folders.ideas.id, "rename starts on the chip")
    render("16-rename-light")
    probe.endRename()
    Check.equal(probe.renamingFolderID, nil, "rename ended")

    // New folder from the "…" menu. + always makes a note.
    let folderCount = store.folders().count
    probe.moreMenuRun("New Folder")
    Check.equal(store.folders().count, folderCount + 1, "New Folder in the … menu creates a folder")
    probe.endRename()
    let noteCount = store.notes(in: vc.currentFolderId ?? 0).count
    probe.plus()
    Check.equal(store.folders().count, folderCount + 1, "+ does not create a folder")
    Check.equal(store.notes(in: vc.currentFolderId ?? 0).count, noteCount + 1, "+ in a folder creates a note")
    probe.focusList()

    // The open folder goes away: the first folder shows (it was the last one open, so there is no other).
    let tmpFolder = store.createFolder(name: "Temp")
    vc.showFolder(tmpFolder.id)
    store.deleteFolder(id: tmpFolder.id)
    Check.equal(vc.currentFolderId, store.folders()[0].id, "deleted open folder: the first folder shows")
    Check.expect(probe.folderTabsVisible && probe.activeFolderTabKey == NotesUIProbe.folderTabKey(store.folders()[0].id),
                 "and its chip is the open one")

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
    written += folderTabChecks(out: out, spin: spin)

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

/// The folder chips in the header pill: the one and only navigation (there is no folder list screen).
@MainActor
func folderTabChecks(out: URL, spin: () -> Void) -> [String] {
    let suite = "NoteBarUISnapshotTabs"
    UserDefaults().removePersistentDomain(forName: suite)
    let settings = AppSettings(defaults: UserDefaults(suiteName: suite)!)
    let store = InMemoryNoteStore(seed: false)
    let notes = store.folders()[0]
    func folder(_ name: String, _ color: NoteColor) -> Folder {
        var f = store.createFolder(name: name)
        f.color = color
        store.updateFolder(f)
        return f
    }
    let work = folder("Work", .blue)
    let ideas = folder("Ideas", .yellow)
    let shopping = folder("Shopping", .green)
    let reading = folder("Reading", .pink)
    func add(_ f: Folder, _ body: String, _ color: NoteColor = .none) {
        var n = store.createNote(in: f.id, body: body, mode: .standard, position: .bottom)
        n.color = color
        store.updateNote(n)
    }
    add(notes, "Hello!\nNoteBar is a notes panel that lives on the side of your screen.", .purple)
    add(notes, "Tasks\n- [x] first task\n- [ ] second task\n- [ ] third task")
    add(notes, "Colors\nHere are some colors.\nThey are written in #rrggbb format.", .yellow)
    add(work, "Meeting notes\nRemember the agenda.\nAsk about the release date.", .blue)
    add(work, "Quarterly plan\nShip the panel.\nPolish the editor.")
    add(work, "Review\nTwo changes wait for a second look.", .green)
    add(ideas, "Ideas\nA notes bar that slides in from the edge.")
    add(shopping, "Groceries\nMilk\nBread", .green)
    add(reading, "Books\nThe Soul of a New Machine", .pink)

    let env = AppEnvironment(store: store, backups: nil, settings: settings,
                             themes: ThemeManager(settings: settings, store: store), editorFactory: PlainNoteEditorFactory())
    let vc = NotesRootViewController(env: env)
    env.presenter = vc
    let probe = vc.probe
    var width: CGFloat = 420
    let height: CGFloat = 420
    let backdrop = Backdrop(frame: .zero)
    backdrop.addSubview(vc.view)
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100), styleMask: [.borderless],
                          backing: .buffered, defer: true)
    window.isReleasedWhenClosed = false
    window.contentView = backdrop
    window.appearance = NSAppearance(named: .aqua)
    backdrop.appearance = NSAppearance(named: .aqua)
    defer { window.contentView = nil; UserDefaults().removePersistentDomain(forName: suite) }
    func layout() { probe.layoutNow(); spin(); probe.layoutNow() }
    func resize() {
        window.setContentSize(NSSize(width: width + 40, height: height + 20))
        backdrop.frame = NSRect(x: 0, y: 0, width: width + 40, height: height + 20)
        vc.view.frame = NSRect(x: 20, y: 10, width: width, height: height)
        layout()
    }
    var written: [String] = []
    func render(_ name: String, dark: Bool = false) {
        let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)!
        window.appearance = appearance
        backdrop.appearance = appearance
        spin(); layout()
        backdrop.layoutSubtreeIfNeeded()
        backdrop.display()
        // At 2x, so the chips can be judged.
        let b = backdrop.bounds
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(b.width * 2), pixelsHigh: Int(b.height * 2),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return }
        rep.size = b.size
        backdrop.cacheDisplay(in: backdrop.bounds, to: rep)
        if let data = rep.representation(using: .png, properties: [:]) {
            try? data.write(to: out.appendingPathComponent(name + ".png"))
            written.append(name)
        }
        window.appearance = NSAppearance(named: .aqua)
        backdrop.appearance = NSAppearance(named: .aqua)
        layout()
    }
    func key(_ f: Folder) -> String { NotesUIProbe.folderTabKey(f.id) }
    func ctrlTab(shift: Bool = false) { probe.press(keyCode: 48, characters: "\t", modifiers: shift ? [.control, .shift] : [.control]) }
    /// The chips never reach the buttons on the right, and everything is inside the pill.
    func checkNoOverlap(_ label: String) {
        let strip = probe.folderTabsFrame, search = probe.searchButtonFrame, plus = probe.plusButtonFrame, pill = probe.headerPillFrame
        Check.expect(strip.maxX <= search.minX, "\(label): the chips end before search (\(strip.maxX) vs \(search.minX))")
        Check.expect(search.maxX <= plus.minX && plus.maxX <= pill.maxX, "\(label): search and + are inside the pill")
        Check.expect(strip.minX >= pill.minX, "\(label): the chips start inside the pill")
        if let more = probe.folderTabFrame("more") {
            Check.expect(more.maxX <= strip.maxX + 0.5 && more.width >= 30, "\(label): the … button is whole (\(more))")
            for k in probe.folderTabKeys where k != "more" && probe.isFolderTabInView(k) {
                Check.expect((probe.folderTabFrame(k)?.maxX ?? 0) <= more.minX, "\(label): \(k) ends before the … button")
            }
            if let s = probe.folderTabFrame("scratch") { Check.expect(s.maxX <= more.minX, "\(label): Scratch ends before the … button") }
        } else { Check.expect(false, "\(label): the … button") }
    }

    // Start: no folder was open before, so the first one is. The strip: Scratch, the folders, "…".
    resize()
    let all = [notes, work, ideas, shopping, reading]
    Check.equal(vc.currentFolderId, notes.id, "tabs: the first folder is open at the start")
    Check.expect(probe.folderTabsVisible, "tabs: shown")
    Check.equal(store.folders().map(\.id), all.map(\.id), "tabs: the seed order")
    Check.equal(probe.folderTabKeys, ["scratch"] + all.map(key) + ["more"], "tabs: Scratch, the folders in order, the … button")
    Check.equal(all.map { probe.folderTabTitle(key($0)) }, ["Notes", "Work", "Ideas", "Shopping", "Reading"], "tabs: a chip has the folder name")
    // Note counts are not on screen: the tooltip has them. The chips keep their labels.
    Check.equal(probe.folderTabToolTip(key(work)), "Work · 3 notes", "tabs: the tooltip has the note count")
    Check.equal(probe.folderTabToolTip(key(ideas)), "Ideas · 1 note", "tabs: one note")
    Check.equal(probe.folderTabAccessibilityLabel(key(work)), "Work · 3 notes", "tabs: a chip has its accessibility label")
    Check.equal(probe.folderTabAccessibilityLabel("scratch"), "Scratch", "tabs: the Scratch chip has its label")
    Check.equal(probe.folderTabsAccessibilityRole, .tabGroup, "tabs: the strip is a tab group")
    Check.equal(probe.folderTabToolTip("scratch")?.hasPrefix("Scratch"), true, "tabs: Scratch tooltip")
    add(ideas, "Second idea")
    Check.equal(probe.folderTabToolTip(key(ideas)), "Ideas · 2 notes", "tabs: the count follows the notes")
    // Colors: the open chip is filled with the folder's strong color, the others have a dot in it.
    Check.expect(Set(all.map { probe.folderTabFill(key($0)) }).count == 5, "tabs: colors differ by folder")
    Check.expect(!probe.folderTabShowsDot(key(notes)) && probe.folderTabShowsDot(key(work)), "tabs: a dot only for a folder with a color")
    let lightFill = probe.folderTabFill(key(work))
    backdrop.appearance = NSAppearance(named: .darkAqua)!
    layout()
    Check.expect(probe.folderTabFill(key(work)) != lightFill, "tabs: the color follows the appearance")
    backdrop.appearance = NSAppearance(named: .aqua)!
    layout()
    settings.themeId = "graphite"
    layout()
    Check.expect(probe.folderTabFill(key(work)) != nil && probe.folderTabInk(key(work)) != probe.folderTabFill(key(work)),
                 "tabs: another theme, the chip has a fill and a text color")
    settings.themeId = "default"
    layout()
    Check.equal(probe.folderTabFill(key(work)), lightFill, "tabs: back to the default theme")
    Check.equal(probe.activeFolderTabKey, key(notes), "tabs: the open folder's chip is the open one")
    checkNoOverlap("tabs")

    // One click switches folder.
    probe.clickFolderTab(key(work))
    layout()
    Check.equal(vc.currentFolderId, work.id, "tabs: a click opens the folder")
    Check.equal(probe.displayedNoteIDs, store.notes(in: work.id).map(\.id), "tabs: the folder's notes show")
    Check.equal(probe.activeFolderTabKey, key(work), "tabs: the clicked chip is the open one")
    Check.equal(settings.lastFolderId, work.id, "tabs: lastFolderId follows")
    Check.expect(probe.isPlusButtonVisible && probe.isSearchButtonVisible && !probe.isBackButtonVisible,
                 "tabs: search and +, no back arrow")
    Check.equal(probe.plusButtonToolTip, "New Note (⌘N)", "tabs: + in a folder is New Note")
    render("40-header-folder-light")
    render("41-header-folder-dark", dark: true)
    vc.showFolder(ideas.id)
    Check.equal(probe.activeFolderTabKey, key(ideas), "tabs: the open chip follows showFolder")
    settings.hideMarkup.toggle()
    layout()
    Check.equal(probe.activeFolderTabKey, key(ideas), "tabs: hideMarkup does not touch the chips")
    settings.hideMarkup.toggle()

    // ⌃Tab / ⌃⇧Tab: the next / previous chip, around the ends. Scratch is part of the round.
    probe.focusList()
    ctrlTab()
    Check.equal(vc.currentFolderId, shopping.id, "tabs: ⌃Tab opens the next folder")
    ctrlTab(shift: true)
    Check.equal(vc.currentFolderId, ideas.id, "tabs: ⌃⇧Tab opens the previous folder")
    probe.pressKeyEquivalent(keyCode: 48, characters: "\t", modifiers: [.control])
    Check.equal(vc.currentFolderId, shopping.id, "tabs: ⌃Tab as a key equivalent (how it reaches the panel)")
    ctrlTab()
    Check.equal(vc.currentFolderId, reading.id, "tabs: ⌃Tab again")
    ctrlTab()
    Check.equal(probe.activeFolderTabKey, "scratch", "tabs: ⌃Tab on the last folder goes around to Scratch")
    Check.equal(probe.focusedNoteID, nil, "tabs: ⌃Tab to Scratch does not start typing")
    ctrlTab()
    Check.equal(vc.currentFolderId, notes.id, "tabs: ⌃Tab on Scratch opens the first folder")
    ctrlTab(shift: true); ctrlTab(shift: true)
    Check.equal(vc.currentFolderId, reading.id, "tabs: ⌃⇧Tab goes around the other way")
    vc.reveal(noteId: store.notes(in: reading.id)[0].id, edit: true)
    Check.equal(probe.focusedNoteID, store.notes(in: reading.id)[0].id, "tabs: editing a note")
    probe.pressKeyEquivalent(keyCode: 48, characters: "\t", modifiers: [.control, .shift])
    Check.equal(vc.currentFolderId, shopping.id, "tabs: ⌃⇧Tab also works while a note is edited")
    Check.equal(probe.focusedNoteID, nil, "tabs: and ends the editing")
    vc.beginSearch()
    ctrlTab()
    Check.expect(probe.isSearching && vc.currentFolderId == shopping.id, "tabs: ⌃Tab does nothing in search")
    probe.goBack()

    // Scratch chip: opens today without the caret. Open, it holds ‹ day ›. + starts typing.
    let scratch = env.scratch
    var clock = Date()
    scratch.now = { clock }
    scratch.refresh()
    probe.clickFolderTab("scratch")
    layout()
    Check.equal(probe.scratchDay, scratch.todayKey, "tabs: the Scratch chip opens today's Scratch")
    Check.equal(probe.activeFolderTabKey, "scratch", "tabs: Scratch is the open chip")
    Check.equal(probe.focusedNoteID, nil, "tabs: the Scratch chip does not start typing")
    Check.equal(probe.scratchChipTitle, "Today", "tabs: the open Scratch chip shows the day")
    Check.equal(probe.folderTabToolTip("scratch"), nil, "tabs: no tooltip over the stepper")
    Check.equal(probe.plusButtonToolTip, "New Entry", "tabs: + on Scratch is New Entry")
    Check.expect((probe.folderTabFrame("scratch")?.width ?? 0) > 80, "tabs: the open Scratch chip is wide")
    checkNoOverlap("tabs, Scratch open")
    let first = scratch.todayNote(create: false)
    probe.clickPlusButton()
    layout()
    Check.expect(first != nil && probe.focusedNoteID == first?.id, "tabs: + on Scratch starts typing in today's note")
    Check.equal(probe.scratchDay, scratch.todayKey, "tabs: + stays on Scratch")
    Check.equal(store.folders().count, 5, "tabs: + on Scratch makes no folder")
    probe.focusList()
    render("42-header-scratch-today-light")
    // An earlier day: ‹ › in the chip step through the days.
    if let first { store.updateNoteBody(id: first.id, body: "Call back about the build\nBook the room") }
    let day1 = scratch.todayKey
    clock = Calendar.current.date(byAdding: .day, value: 1, to: clock)!
    scratch.refresh()
    layout()
    let day2 = scratch.todayKey
    Check.equal(probe.scratchDay, day2, "tabs: Scratch follows the new day")
    Check.expect(probe.canStepToEarlierDay && !probe.canStepToLaterDay, "tabs: ‹ on, › off on today")
    Check.expect(!probe.clickScratchChipStepper(1) && probe.scratchDay == day2, "tabs: › does nothing on today")
    Check.expect(probe.clickScratchChipStepper(-1), "tabs: ‹ steps")
    layout()
    Check.equal(probe.scratchDay, day1, "tabs: ‹ shows the earlier day")
    Check.equal(probe.scratchChipTitle, "Yesterday", "tabs: the chip shows that day")
    Check.expect(!probe.canStepToEarlierDay && probe.canStepToLaterDay, "tabs: ‹ off, › on on the oldest day")
    Check.equal(probe.activeFolderTabKey, "scratch", "tabs: still the Scratch chip")
    checkNoOverlap("tabs, Scratch on an earlier day")
    render("43-header-scratch-earlier-day-light")
    Check.expect(probe.clickScratchChipStepper(1) && probe.scratchDay == day2, "tabs: › goes back to today")
    // A chip leaves Scratch. Search keeps the chip of its screen, and the chips make room for the field.
    probe.clickFolderTab(key(work))
    Check.equal(vc.currentFolderId, work.id, "tabs: a folder chip leaves Scratch")
    Check.equal(probe.scratchChipTitle, nil, "tabs: the closed Scratch chip is a round button")
    vc.beginSearch()
    Check.expect(!probe.folderTabsVisible && probe.folderTabKeys.isEmpty, "tabs: hidden in search")
    Check.equal(probe.activeFolderTabKey, key(work), "tabs: search keeps the chip of its folder")
    probe.pressEscape()
    Check.expect(probe.folderTabsVisible && vc.currentFolderId == work.id, "tabs: back after search")

    // Scratch off: no Scratch chip. Turned off while it shows: the last folder.
    probe.clickFolderTab("scratch")
    settings.scratchEnabled = false
    layout()
    Check.equal(probe.folderTabKeys.first, key(notes), "tabs: Scratch off, no Scratch chip")
    Check.equal(vc.currentFolderId, work.id, "tabs: Scratch off while it shows, the last folder opens")
    checkNoOverlap("tabs, Scratch off")
    ctrlTab(shift: true); ctrlTab(shift: true)
    Check.equal(vc.currentFolderId, reading.id, "tabs: Scratch off, ⌃⇧Tab goes around the folders only")
    vc.showFolder(work.id)
    render("47-header-scratch-off-light")
    settings.scratchEnabled = true
    layout()
    Check.equal(probe.folderTabKeys.first, "scratch", "tabs: Scratch on, the chip is back")
    for n in store.scratchNotes(includingTrashed: true) { store.deleteNote(id: n.id) }
    scratch.now = Date.init
    scratch.refresh()

    // The "…" menu: New Folder first, Archive and Recently Deleted, Settings last.
    Check.equal(probe.moreMenuItems, ["New Folder", "-", "Archive", "Recently Deleted", "-", "Settings…"], "tabs: the … menu")
    Check.expect(probe.moreMenuItemIsEnabled("Archive") && !probe.moreMenuItemIsEnabled("Recently Deleted"),
                 "tabs: Recently Deleted is off while the trash is empty")
    var menus: [NSMenu] = []
    probe.captureMenus { menus.append($0) }
    probe.clickFolderTab("more")
    Check.equal(menus.last?.items.map { $0.isSeparatorItem ? "-" : $0.title }, probe.moreMenuItems, "tabs: a click on … opens that menu")
    Check.equal(vc.currentFolderId, work.id, "tabs: … is not a screen")
    probe.captureMenus(nil)
    // Right click on a chip: the folder menu (no Open: a click does that).
    Check.equal(probe.folderMenuItems(for: ideas.id),
                ["New Folder", "New Note in Folder", "Rename", "Pin", "Color", "Archive Folder", "Delete Folder…"],
                "tabs: the menu of a chip")
    probe.folderMenuRun(ideas.id, "New Note in Folder")
    layout()
    Check.equal(vc.currentFolderId, ideas.id, "tabs: New Note in Folder opens the folder")
    Check.expect(probe.focusedNoteID != nil && store.note(id: probe.focusedNoteID ?? 0)?.folderId == ideas.id,
                 "tabs: and starts a note in it")
    if let id = probe.focusedNoteID { probe.focusList(); store.deleteNote(id: id) }
    probe.folderMenuRun(reading.id, "Pin")
    layout()
    Check.equal(probe.folderTabKeys[1], key(reading), "tabs: Pin moves the chip to the front")
    Check.equal(probe.folderTabToolTip(key(reading)), "Reading · 1 note · pinned", "tabs: the tooltip says pinned")
    Check.equal(probe.folderMenuItems(for: reading.id)[3], "Unpin", "tabs: the menu offers Unpin")
    probe.folderMenuRun(reading.id, "Unpin")
    Check.equal(probe.folderTabKeys, ["scratch"] + all.map(key) + ["more"], "tabs: Unpin puts it back")
    probe.folderMenuRun(notes.id, "Color", "Purple")
    Check.equal(store.folder(id: notes.id)?.color, .purple, "tabs: Color in the menu sets the folder color")
    Check.expect(probe.folderTabShowsDot(key(notes)), "tabs: and the chip gets its dot")
    probe.folderMenuRun(notes.id, "Color", "None")
    Check.expect(!probe.folderTabShowsDot(key(notes)), "tabs: None takes it away")

    // Inline rename: the chip becomes a text field in place.
    vc.showFolder(ideas.id)
    layout()
    let chipBefore = probe.folderTabFrame(key(ideas)) ?? .zero
    probe.folderMenuRun(ideas.id, "Rename")
    layout()
    Check.equal(probe.renamingFolderID, ideas.id, "rename: Rename in the menu starts on the chip")
    Check.equal(probe.renameFieldText, "Ideas", "rename: the field has the name")
    Check.expect(probe.isRenameFieldFocused, "rename: the field has the keyboard focus")
    Check.equal(probe.renameFieldFont?.pointSize, env.themes.fontSize - 1.5, "rename: the chip's font")
    if let f = probe.renameFieldFrame, let c = probe.folderTabFrame(key(ideas)) {
        Check.expect(c.insetBy(dx: -0.5, dy: -0.5).contains(f), "rename: the field is inside the chip (\(f) in \(c))")
        Check.expect(abs(c.width - chipBefore.width) <= 8, "rename: the chip keeps about its width (\(c.width) vs \(chipBefore.width))")
    } else { Check.expect(false, "rename: frames") }
    probe.typeInRenameField("Ideas and plans for later")
    layout()
    Check.expect((probe.folderTabFrame(key(ideas))?.width ?? 0) > chipBefore.width + 40, "rename: the chip grows while typing")
    Check.expect((probe.folderTabFrame(key(ideas))?.width ?? 999) <= 160, "rename: up to the widest chip")
    Check.expect(probe.isFolderTabInView(key(ideas)), "rename: the chip stays in view")
    checkNoOverlap("rename")
    render("45-header-rename-light")
    probe.typeInRenameField("Plans")
    probe.pressInRenameField(return: true)
    layout()
    Check.equal(store.folder(id: ideas.id)?.name, "Plans", "rename: Return commits")
    Check.equal(probe.renamingFolderID, nil, "rename: ended")
    Check.equal(probe.folderTabTitle(key(ideas)), "Plans", "rename: the chip has the new name")
    Check.equal(probe.undoActionName, "Rename Folder", "rename: it is undoable")
    spin()
    probe.press(keyCode: 6, characters: "z", modifiers: [.command])
    spin()
    Check.equal(store.folder(id: ideas.id)?.name, "Ideas", "rename: ⌘Z brings the old name back")
    probe.dismissToast()
    probe.beginRename(ideas.id)
    probe.typeInRenameField("Nope")
    probe.pressInRenameField(return: false)
    Check.expect(store.folder(id: ideas.id)?.name == "Ideas" && probe.renamingFolderID == nil, "rename: Escape cancels")
    probe.beginRename(ideas.id)
    probe.typeInRenameField("   ")
    probe.pressInRenameField(return: true)
    Check.expect(store.folder(id: ideas.id)?.name == "Ideas" && probe.renamingFolderID == nil, "rename: an empty name cancels")
    probe.beginRename(ideas.id)
    probe.typeInRenameField("Lost focus")
    probe.focusList()
    Check.expect(store.folder(id: ideas.id)?.name == "Lost focus" && probe.renamingFolderID == nil, "rename: a focus loss commits")
    probe.beginRename(ideas.id)
    probe.typeInRenameField("Ideas")
    probe.clickFolderTab(key(work))
    Check.expect(store.folder(id: ideas.id)?.name == "Ideas" && probe.renamingFolderID == nil, "rename: opening another folder commits")
    // A chip that is not open is renamed in place too. From search, its folder opens first.
    probe.beginRename(shopping.id)
    Check.expect(probe.renamingFolderID == shopping.id && vc.currentFolderId == work.id, "rename: a chip that is not open, in place")
    probe.pressInRenameField(return: false)
    vc.beginSearch()
    probe.beginRename(shopping.id)
    Check.expect(!probe.isSearching && vc.currentFolderId == shopping.id && probe.renamingFolderID == shopping.id,
                 "rename: from search, the folder opens and its chip is renamed")
    vc.panelWillHide()
    Check.equal(probe.renamingFolderID, nil, "rename: hiding the panel ends it")

    // New Folder: the folder opens, its chip is in view and ready for a name.
    vc.showFolder(notes.id)
    probe.moreMenuRun("New Folder")
    layout()
    Check.equal(store.folders().count, 6, "new folder: created")
    let travel = store.folders().last!
    Check.equal(vc.currentFolderId, travel.id, "new folder: it opens")
    Check.equal(probe.activeFolderTabKey, key(travel), "new folder: its chip is the open one")
    Check.expect(probe.isFolderTabInView(key(travel)), "new folder: its chip is in view")
    Check.expect(probe.renamingFolderID == travel.id && probe.renameFieldText == "New Folder", "new folder: the name is being edited")
    probe.typeInRenameField("Travel")
    probe.pressInRenameField(return: true)
    Check.equal(store.folder(id: travel.id)?.name, "Travel", "new folder: the typed name")
    Check.equal(probe.folderTabToolTip(key(travel)), "Travel · 0 notes", "new folder: an empty folder")
    probe.folderMenuRun(work.id, "New Folder")
    Check.expect(store.folders().count == 7 && probe.renamingFolderID == store.folders().last?.id, "new folder: also from a chip's menu")
    probe.pressInRenameField(return: false)
    let second = store.folders().last!
    Check.equal(second.name, "New Folder", "new folder: Escape keeps the folder with its default name")
    probe.focusList()
    probe.press(keyCode: 45, characters: "n", modifiers: [.command, .shift])
    Check.expect(store.folders().count == 8 && probe.renamingFolderID == vc.currentFolderId, "new folder: ⇧⌘N")
    probe.endRename()
    let third = store.folders().last!

    // Deleting folders. The open one: the first folder shows (the last one open is gone).
    probe.confirmDestructiveAlerts(true)
    vc.showFolder(second.id)
    spin()  // each action is its own event in the app (undo groups by event)
    probe.folderMenuRun(third.id, "Delete Folder…")
    Check.expect(store.folder(id: third.id) == nil && vc.currentFolderId == second.id, "delete: another folder, the open one stays")
    spin()
    probe.folderMenuRun(second.id, "Delete Folder…")
    layout()
    Check.equal(store.folder(id: second.id), nil, "delete: the open folder")
    Check.equal(vc.currentFolderId, notes.id, "delete: the open folder is gone, the first folder shows")
    Check.equal(probe.activeFolderTabKey, key(notes), "delete: and its chip is the open one")
    Check.expect(!probe.folderTabKeys.contains(key(second)), "delete: the chip is gone")
    Check.equal(probe.toastMessage, "Folder deleted", "delete: toast")
    Check.equal(probe.moreMenuBadge("Recently Deleted"), 2, "delete: both are in Recently Deleted")
    probe.undoDelete()
    Check.expect(store.folder(id: second.id) != nil && probe.folderTabKeys.contains(key(second)), "delete: Undo brings the chip back")
    Check.equal(vc.currentFolderId, notes.id, "delete: Undo does not switch folder")
    probe.folderMenuRun(second.id, "Delete Folder…")
    probe.confirmDestructiveAlerts(nil)
    probe.dismissToast()
    store.purgeTrash(deletedBefore: .distantFuture)
    // Back from the archive: the folder that was open last.
    vc.showFolder(shopping.id)
    vc.showArchive()
    Check.expect(!probe.folderTabsVisible && probe.isBackButtonVisible && !probe.isPlusButtonVisible, "archive: title, back arrow, no +")
    probe.clickBackButton()
    Check.equal(vc.currentFolderId, shopping.id, "archive: back shows the folder that was open last")

    // Reorder: a chip dragged to a gap (the drop goes through the same call).
    Check.equal(store.folders().map(\.id), [notes, work, ideas, shopping, reading, travel].map(\.id), "reorder: the order before")
    if let w = probe.folderTabFrame(key(work)), let i = probe.folderTabFrame(key(ideas)) {
        Check.equal(probe.folderTabGapIndex(atX: w.minX + 2), 1, "reorder: left half of a chip, the gap before it")
        Check.equal(probe.folderTabGapIndex(atX: w.maxX - 2), 2, "reorder: right half, the gap after it")
        Check.equal(probe.folderTabGapIndex(atX: i.minX + 2), 2, "reorder: the same gap from the next chip")
    } else { Check.expect(false, "reorder: frames") }
    probe.moveFolder(reading.id, toGap: 1)
    layout()
    Check.equal(store.folders().map(\.id), [notes, reading, work, ideas, shopping, travel].map(\.id), "reorder: dropped before Work")
    Check.equal(probe.folderTabKeys, ["scratch"] + store.folders().map(key) + ["more"], "reorder: the chips follow")
    Check.equal(probe.undoActionName, "Move Folder", "reorder: undoable")
    probe.moveFolder(reading.id, toGap: 6)
    Check.equal(store.folders().last?.id, reading.id, "reorder: dropped after the last chip")
    probe.moveFolder(reading.id, toGap: 4)
    Check.equal(store.folders().map(\.id), [notes, work, ideas, shopping, reading, travel].map(\.id), "reorder: back in place")
    probe.moveFolder(work.id, toGap: 2)
    Check.equal(store.folders()[1].id, work.id, "reorder: a drop beside itself changes nothing")
    // Drops on a chip: a note moves, text makes a note.
    let moved = store.notes(in: work.id)[0].id
    probe.dropNote(moved, onFolder: travel.id)
    Check.equal(store.note(id: moved)?.folderId, travel.id, "drop: a note on a chip moves to that folder")
    probe.dropNote(moved, onFolder: work.id)
    probe.dismissToast()
    probe.dropText("Dropped on a chip", onFolder: travel.id)
    layout()
    Check.expect(store.notes(in: travel.id).contains { $0.body == "Dropped on a chip" }, "drop: text on a chip makes a note in that folder")
    Check.equal(vc.currentFolderId, travel.id, "drop: and shows it")
    probe.focusList()
    Check.expect(NotesUIProbe.folderTabsAcceptedDragTypes.allSatisfy(probe.folderTabsRegisteredDragTypes.contains),
                 "drop: the strip takes folder chips, notes, files, and text")
    store.deleteFolder(id: travel.id)
    layout()

    // A long name: cut with an ellipsis at the widest chip. The tooltip has all of it.
    let long = folder("A very long folder name that goes on and on", .cream)
    vc.showFolder(long.id)
    layout()
    Check.expect((probe.folderTabFrame(key(long))?.width ?? 999) <= 160, "long name: the chip is at most 160 pt wide")
    Check.expect((probe.folderTabFrame(key(long))?.width ?? 0) >= 120, "long name: and not tiny")
    Check.equal(probe.folderTabToolTip(key(long)), "A very long folder name that goes on and on · 0 notes", "long name: the tooltip has all of it")
    Check.expect(probe.isFolderTabInView(key(long)), "long name: the open chip is in view")
    checkNoOverlap("long name")

    // The minimum panel width: the chips never reach the buttons, with Scratch on, open, and off.
    width = PanelWidth.minWidth
    resize()
    Check.equal(vc.view.bounds.width, 280, "minimum width: 280 pt")
    checkNoOverlap("minimum width, long name")
    Check.expect(probe.folderTabsCanScroll, "minimum width: the chips scroll")
    Check.expect((probe.folderTabFrame(key(long))?.width ?? 999) <= probe.folderTabsFrame.width - 60, "minimum width: the long chip fits its room")
    render("46-header-minimum-width-light")
    vc.showFolder(work.id)
    layout()
    checkNoOverlap("minimum width")
    Check.expect(probe.isFolderTabInView(key(work)), "minimum width: the open chip is in view")
    probe.clickFolderTab("scratch")
    layout()
    checkNoOverlap("minimum width, Scratch open")
    if let s = probe.folderTabFrame("scratch"), let more = probe.folderTabFrame("more") {
        Check.expect(more.minX - s.maxX >= 56, "minimum width: the folder chips keep room beside the open Scratch chip (\(more.minX - s.maxX))")
    }
    Check.expect(probe.canStepToEarlierDay == false && probe.activeFolderTabKey == "scratch", "minimum width: Scratch is open")
    probe.beginRename(work.id)
    Check.equal(probe.renamingFolderID, work.id, "minimum width: rename a chip beside the open Scratch chip")
    probe.typeInRenameField("Work and more work to do")
    layout()
    checkNoOverlap("minimum width, rename")
    probe.pressInRenameField(return: false)
    settings.scratchEnabled = false
    layout()
    checkNoOverlap("minimum width, Scratch off")
    settings.scratchEnabled = true
    for n in store.scratchNotes(includingTrashed: true) { store.deleteNote(id: n.id) }
    store.deleteFolder(id: long.id)
    width = 420
    resize()

    // Many folders: the chips scroll sideways and fade at an end that has more.
    vc.showFolder(notes.id)
    width = 600
    resize()
    Check.expect(!probe.folderTabsCanScroll, "scroll: five folders fit in a wide panel")
    Check.expect(!probe.folderTabsFade.left && !probe.folderTabsFade.right, "scroll: no fade while all fit")
    width = 420
    resize()
    Check.expect(probe.folderTabsCanScroll && probe.folderTabsFade.right, "scroll: at the default width the fifth chip is cut and fades")
    let names = ["Archive Ideas", "Budget", "Code", "Design", "Errands", "Fitness", "Garden", "House", "Journal"]
    let colors: [NoteColor] = [.none, .purple, .cream, .blue, .none, .green, .yellow, .none, .pink]
    var many: [Folder] = []
    for (n, c) in zip(names, colors) { many.append(folder(n, c)) }
    layout()
    Check.equal(probe.folderTabKeys.count, 16, "scroll: 14 folder chips, Scratch, and …")
    Check.expect(probe.folderTabsCanScroll, "scroll: 14 folders scroll")
    Check.equal(probe.folderTabScrollOffset, 0, "scroll: a new folder elsewhere does not scroll the chips")
    Check.expect(!probe.folderTabsFade.left && probe.folderTabsFade.right, "scroll: at the start, only the right end fades")
    Check.expect(!probe.isFolderTabInView(key(many.last!)), "scroll: the last chip is out of view")
    checkNoOverlap("scroll")
    // Opening a folder brings its chip into view, with a bit of each neighbor.
    vc.showFolder(many[5].id)
    layout()
    Check.expect(probe.isFolderTabInView(key(many[5])), "scroll: the open chip is scrolled into view")
    Check.expect(probe.folderTabScrollOffset > 0, "scroll: scrolled")
    Check.expect(probe.folderTabsFade.left && probe.folderTabsFade.right, "scroll: in the middle, both ends fade")
    if let c = probe.folderTabFrame(key(many[5])), let next = probe.folderTabFrame(key(many[6])), let more = probe.folderTabFrame("more") {
        Check.expect(next.minX < more.minX - 4 && c.maxX < more.minX - 20, "scroll: a bit of the next chip shows (\(next.minX) vs \(more.minX))")
    }
    render("44-header-14-folders-light")
    render("48-header-14-folders-dark", dark: true)
    // A scroll by hand stays through a re-layout and a store change. It ends when another folder opens.
    probe.scrollFolderTabs(by: -10_000)
    Check.equal(probe.folderTabScrollOffset, 0, "scroll: by hand to the start")
    Check.expect(!probe.isFolderTabInView(key(many[5])), "scroll: the open chip is out of view now")
    layout()
    var touched = store.folder(id: reading.id)!
    touched.color = .purple
    store.updateFolder(touched)
    add(notes, "One more")
    layout()
    Check.equal(probe.folderTabScrollOffset, 0, "scroll: a re-layout and store changes keep the scroll by hand")
    probe.scrollFolderTabs(by: 10_000)
    Check.equal(probe.folderTabScrollOffset, probe.folderTabMaxScrollOffset, "scroll: by hand to the end, and no further")
    Check.expect(probe.folderTabsFade.left && !probe.folderTabsFade.right, "scroll: at the end, only the left end fades")
    Check.expect(probe.isFolderTabInView(key(many.last!)), "scroll: the last chip is in view")
    probe.clickFolderTab(key(many.last!))
    Check.equal(probe.folderTabScrollOffset, probe.folderTabMaxScrollOffset, "scroll: opening a chip in view does not move the chips")
    vc.showFolder(notes.id)
    layout()
    Check.equal(probe.folderTabScrollOffset, 0, "scroll: opening the first folder scrolls back to it")
    for f in many { store.deleteFolder(id: f.id) }
    layout()
    Check.equal(probe.folderTabScrollOffset, 0, "scroll: fewer folders, back at the start")
    return written
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
    vc.showLastFolder()
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
        vc.showLastFolder()
        probe.showScratch(edit: true)
        probe.layoutNow(); spin()
        let again = probe.editor(of: e.id) as? MarkdownNoteEditor
        Check.equal(ScratchEntries.markers(in: again?.markdown ?? "").count, 2, "entries: opening again starts the next entry")
        Check.equal(again?.selectedRangeForTesting.location, again?.textViewForTesting.string.utf16.count,
                    "entries: the caret is in the new entry")
        Check.equal(store.note(id: e.id)?.body, first, "entries: not saved before text is typed")
        render("30-scratch-entries-light")
        // Leaving without typing drops it.
        vc.showLastFolder()
        spin()
        Check.equal(store.note(id: e.id)?.body, first, "entries: an entry left empty is not kept")
        // Showing Scratch without the caret (the day stepper, reveal) starts nothing.
        probe.showScratch(edit: false)
        probe.layoutNow(); spin()
        Check.equal(ScratchEntries.markers(in: (probe.editor(of: e.id) as? MarkdownNoteEditor)?.markdown ?? first).count, 1,
                    "entries: showing Scratch without typing starts no entry")
        // + on the Scratch screen starts an entry, like the hotkey.
        Check.equal(probe.plusButtonToolTip, "New Entry", "entries: + on Scratch is New Entry")
        probe.clickPlusButton()
        probe.layoutNow(); spin()
        Check.equal(ScratchEntries.markers(in: (probe.editor(of: e.id) as? MarkdownNoteEditor)?.markdown ?? "").count, 2,
                    "entries: + on Scratch starts an entry")
        Check.equal(probe.focusedNoteID, e.id, "entries: with the caret in it")
        vc.showLastFolder()
        spin()
        Check.equal(store.note(id: e.id)?.body, first, "entries: the entry from + is dropped when left empty")
        probe.showScratch(edit: false)
        probe.layoutNow(); spin()

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
        vc.showLastFolder()
        probe.showScratch(edit: false)
        probe.layoutNow(); spin(); probe.layoutNow()
        Check.expect(probe.listScrollOffset > 100 && probe.listIsScrolledToEnd,
                     "entries: a long day opens scrolled to its end (\(probe.listScrollOffset))")
        // To type: the caret is in a new entry at the end, and the end shows.
        vc.showLastFolder()
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

    func tabKey(_ f: Folder) -> String { NotesUIProbe.folderTabKey(f.id) }
    // Off (default): a letter in a folder does nothing. In the search results it types into the query.
    settings.vimKeybinds = false
    vc.showFolder(folders.notes.id)
    probe.focusList()
    key("j", 38)
    Check.expect(!probe.isSearching, "vim off: a letter in a folder does not start search")
    probe.setSearchQuery("no")
    probe.focusList()
    key("t", 17)
    Check.equal(probe.searchQuery, "not", "vim off: a letter on the search results types into the search field")
    probe.goBack()
    Check.expect(!probe.isSearching, "search closed")
    key("g", 5); key("t", 17)
    Check.equal(vc.currentFolderId, folders.notes.id, "vim off: gt does nothing")

    settings.vimKeybinds = true
    vc.showFolder(folders.notes.id)
    probe.focusList()
    key("x", 7)
    Check.expect(!probe.isSearching, "vim: other letters do nothing in a folder")
    let before0 = store.folders().count
    key("o", 31); key("R", 15, [.shift])
    Check.expect(store.folders().count == before0 && probe.renamingFolderID == nil, "vim: o and R are not folder keys any more")

    // gt / gT: the next / previous chip (Scratch, then the folders), around the ends.
    let strip = Array(probe.folderTabKeys.dropLast())
    Check.equal(strip.first, "scratch", "vim: the strip starts with Scratch")
    guard let at = strip.firstIndex(of: tabKey(folders.notes)) else { Check.expect(false, "vim: chip of Notes"); return }
    key("g", 5); key("t", 17)
    Check.equal(probe.activeFolderTabKey, strip[(at + 1) % strip.count], "vim: gt opens the next folder")
    key("g", 5); key("T", 17, [.shift])
    Check.equal(probe.activeFolderTabKey, tabKey(folders.notes), "vim: gT opens the previous folder")
    vc.showFolder(store.folders().last!.id)
    key("g", 5); key("t", 17)
    Check.equal(probe.activeFolderTabKey, "scratch", "vim: gt on the last folder goes around to Scratch")
    key("g", 5); key("T", 17, [.shift])
    Check.equal(vc.currentFolderId, store.folders().last!.id, "vim: gT on Scratch goes around to the last folder")
    for n in store.scratchNotes(includingTrashed: true) { store.deleteNote(id: n.id) }

    // ⌃[ in a folder goes nowhere. ⌘/ searches all folders.
    vc.showFolder(folders.notes.id)
    probe.layoutNow(); spin(); probe.layoutNow()
    key("\u{1b}", 33, [.control])
    Check.equal(vc.currentFolderId, folders.notes.id, "vim: ⌃[ in a folder does nothing")
    vc.showArchive()
    key("\u{1b}", 33, [.control])
    Check.equal(vc.currentFolderId, folders.notes.id, "vim: ⌃[ in the archive goes back to the last folder")
    vc.showArchive()
    key("h", 4)
    Check.equal(vc.currentFolderId, folders.notes.id, "vim: h in the archive goes back too")
    key("h", 4)
    Check.equal(vc.currentFolderId, folders.notes.id, "vim: h in a folder does nothing")
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
    Check.equal(vc.currentFolderId, vf.id, "⌃[ in Normal mode stays in the folder")

    // Folders have no keyboard selection: their commands are in the chip's menu.
    var menus: [NSMenu] = []
    probe.captureMenus { menus.append($0) }
    probe.focusList()
    probe.select(nil)
    key("g"); key("p")
    Check.equal(store.folder(id: vf.id)?.isPinned, false, "vim: gp without a selected note does not pin the folder")
    probe.confirmDestructiveAlerts(true)
    key("d"); key("d")
    probe.confirmDestructiveAlerts(nil)
    Check.expect(store.folder(id: vf.id) != nil, "vim: dd without a selected note does not delete the folder")
    probe.folderMenuRun(vf.id, "Pin")
    Check.equal(store.folder(id: vf.id)?.isPinned, true, "the chip's menu pins the folder")
    probe.folderMenuRun(vf.id, "Unpin")
    Check.equal(store.folder(id: vf.id)?.isPinned, false, "and unpins it")
    probe.folderMenuRun(vf.id, "Rename")
    Check.equal(probe.renamingFolderID, vf.id, "the chip's menu renames the folder")
    probe.endRename()
    probe.focusList()

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
    probe.focusList()
    probe.newFolder()
    let made = vc.currentFolderId
    Check.expect(made != nil && made != uf.id && probe.renamingFolderID == made, "New Folder opens the folder and renames it")
    probe.endRename()
    probe.focusList()
    Check.equal(store.folders().count, before + 1, "New Folder")
    cmdZ()
    Check.equal(store.folders().count, before, "⌘Z removes the new folder")
    Check.equal(vc.currentFolderId, store.folders()[0].id, "⌘Z of New Folder: the open folder is gone, the first folder shows")
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
    vc.showFolder(uf.id)
    probe.focusList()
    probe.confirmDestructiveAlerts(true)
    probe.deleteFolder(uf.id)
    Check.equal(store.folder(id: uf.id), nil, "folder deleted (trash)")
    Check.equal(vc.currentFolderId, store.folders()[0].id, "the open folder is deleted: the first folder shows")
    Check.equal(store.note(id: n1.id), nil, "its notes are hidden")
    Check.expect(probe.isToastVisible, "folder delete toast")
    cmdZ()
    Check.expect(store.folder(id: uf.id) != nil && store.note(id: n1.id) != nil, "⌘Z restores the folder and its notes")
    probe.deleteFolder(uf.id)
    probe.undoDelete()
    Check.expect(store.folder(id: uf.id) != nil, "folder toast Undo restores")

    // Recently Deleted in the … menu: open whenever the trash has items (any Keep deleted items).
    let settings = probe.settings
    store.purgeTrash(deletedBefore: .distantFuture)
    Check.expect(!probe.moreMenuItemIsEnabled("Recently Deleted"), "Recently Deleted is off while the trash is empty")
    Check.equal(probe.moreMenuBadge("Recently Deleted"), nil, "and has no count")
    let gone = store.createNote(in: uf.id, body: "Gone note\nbody", mode: .standard, position: .top)
    vc.showFolder(uf.id)
    probe.deleteWithUndo(gone.id)
    probe.layoutNow(); spin()
    Check.expect(probe.moreMenuItemIsEnabled("Recently Deleted"), "Recently Deleted is on with an item in the trash")
    Check.equal(probe.moreMenuBadge("Recently Deleted"), 1, "Recently Deleted shows the count")
    Check.expect(probe.moreMenuSubmenuTitles("Recently Deleted").contains("Gone note"), "its submenu is the trash menu")
    let titles = probe.trashMenuTitles
    Check.expect(titles.contains("Gone note"), "trash menu lists the note (\(titles))")
    Check.expect(titles.contains("Empty Recently Deleted…"), "trash menu has Empty")
    probe.trashMenuRun("Gone note", "Restore")
    Check.expect(store.note(id: gone.id) != nil, "Restore from the menu")
    Check.expect(!probe.moreMenuItemIsEnabled("Recently Deleted"), "off again when the trash is empty again")
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
    probe.layoutNow(); spin()
    settings.deletedItemsRetention = .recentlyDeleted
    Check.equal(probe.moreMenuBadge("Recently Deleted"), 1, "the item stays with 30 days")
    settings.deletedItemsRetention = .oneHour
    Check.equal(probe.moreMenuBadge("Recently Deleted"), 1, "the item stays with the default 1 hour")
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
    Check.equal(probe.moreMenuBadge("Archive"), nil, "no count on Archive while nothing is archived")
    Check.equal(probe.moreMenuSubmenuTitles("Archive"), ["Archived Notes"], "the Archive menu still opens the (empty) archive")

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

    // Archive in the … menu, and the archive screen.
    vc.showFolder(af.id)
    probe.layoutNow(); spin()
    Check.equal(probe.moreMenuBadge("Archive"), 2, "Archive shows the count")
    probe.archiveMenuRun("Archived Notes")
    probe.layoutNow(); spin()
    Check.equal(probe.headerTitle, "Archive", "Archived Notes opens the archive")
    Check.expect(!probe.folderTabsVisible && probe.isBackButtonVisible, "the archive has a title and a back arrow, no chips")
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
    probe.clickBackButton()
    Check.equal(vc.currentFolderId, af.id, "back from the archive shows the last folder")
    Check.expect(probe.folderTabsVisible && !probe.isBackButtonVisible, "with the chips again, and no back arrow")

    // Keyboard: ← and ⌘[ leave the archive. ⌃Tab does nothing there (no chips).
    vc.showArchive()
    probe.focusList()
    probe.press(keyCode: 48, characters: "\t", modifiers: [.control])
    Check.equal(probe.headerTitle, "Archive", "⌃Tab in the archive does nothing")
    probe.press(keyCode: 123, characters: "\u{F702}")
    Check.equal(vc.currentFolderId, af.id, "← in the archive goes back")
    vc.showArchive()
    probe.press(keyCode: 33, characters: "[", modifiers: [.command])
    Check.equal(vc.currentFolderId, af.id, "⌘[ in the archive goes back")

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
    vc.showLastFolder()
    Check.equal(probe.moreMenuBadge("Archive"), nil, "no count when the archive is empty again")
    store.deleteFolder(id: af.id)
}


@MainActor
func folderArchiveChecks(vc: NotesRootViewController, probe: NotesUIProbe, store: InMemoryNoteStore, spin: () -> Void) {
    func cmdZ() { spin(); probe.press(keyCode: 6, characters: "z", modifiers: [.command]); spin() }
    func optCmdA() { probe.press(keyCode: 0, characters: "a", modifiers: [.command, .option]) }
    let shelf = store.createFolder(name: "Shelf")
    let s1 = store.createNote(in: shelf.id, body: "Quince jam\nfirst", mode: .standard, position: .bottom)
    let s2 = store.createNote(in: shelf.id, body: "Shelf two", mode: .standard, position: .bottom)
    let shelfKey = NotesUIProbe.folderTabKey(shelf.id)
    vc.showFolder(shelf.id)
    probe.layoutNow(); spin()
    Check.equal(probe.moreMenuBadge("Archive"), nil, "folder archive: nothing archived yet")

    // Folder menu.
    Check.expect(probe.folderMenuItems(for: shelf.id).contains("Archive Folder"), "the folder menu has Archive Folder")
    probe.folderMenuRun(shelf.id, "Archive Folder")
    Check.expect(store.archivedFolder(id: shelf.id) != nil, "Archive Folder archives the folder")
    Check.expect(!probe.folderTabKeys.contains(shelfKey), "the archived folder loses its chip")
    Check.equal(vc.currentFolderId, store.folders()[0].id, "the open folder is archived: the first folder shows")
    Check.equal(probe.moreMenuBadge("Archive"), 1, "Archive counts the folder")
    Check.equal(probe.toastMessage, "Folder archived", "folder archive toast")
    probe.tapToastAction()
    Check.expect(store.folder(id: shelf.id) != nil, "toast Undo unarchives the folder")
    Check.expect(probe.folderTabKeys.contains(shelfKey), "and its chip is back")

    // Archive a folder that is not open, ⌘Z. ⌥⌘A never archives a folder (it is a note key).
    let openBefore = vc.currentFolderId
    probe.focusList()
    probe.folderMenuRun(shelf.id, "Archive Folder")
    Check.expect(store.archivedFolder(id: shelf.id) != nil, "Archive Folder on a chip that is not open")
    Check.equal(vc.currentFolderId, openBefore, "the open folder stays")
    cmdZ()
    Check.expect(store.folder(id: shelf.id) != nil, "⌘Z unarchives the folder")
    vc.showFolder(shelf.id)
    probe.focusList()
    probe.select(nil)
    optCmdA()
    Check.expect(store.folder(id: shelf.id) != nil, "⌥⌘A does not archive the open folder")
    for n in store.archivedNotes() { store.unarchiveNote(id: n.id) }
    probe.dismissToast()
    probe.folderMenuRun(shelf.id, "Archive Folder")
    Check.expect(store.archivedFolder(id: shelf.id) != nil, "archived again")

    // The … button opens its menu. Archive lists the archived notes and folders.
    var menus: [NSMenu] = []
    probe.captureMenus { menus.append($0) }
    probe.clickMoreButton()
    Check.equal(menus.count, 1, "the … button opens a menu")
    Check.equal(menus.first?.items.first?.title, "New Folder", "which starts with New Folder")
    probe.captureMenus(nil)
    Check.equal(probe.moreMenuSubmenuTitles("Archive"), probe.archiveMenuTitles, "Archive in the … menu is the Archive menu")
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
    Check.expect(!probe.folderTabsVisible && probe.isBackButtonVisible, "an archived folder has a title and a back arrow")
    probe.goBack()
    Check.expect(probe.folderTabsVisible && vc.currentFolderId == store.folders()[0].id,
                 "back from the archived folder shows the last folder (here the first)")

    // Unarchive while it is open: it becomes a normal folder.
    probe.archiveMenuRun("Shelf", "Open")
    probe.archiveMenuRun("Shelf", "Unarchive")
    probe.layoutNow(); spin()
    Check.expect(store.folder(id: shelf.id) != nil, "Unarchive puts the folder back")
    Check.equal(probe.headerTitle, "Shelf", "the open archived folder stays open as a normal folder")
    Check.expect(probe.isPlusButtonVisible, "with its + button")
    Check.equal(probe.toastMessage, "“Shelf” is back with the folders", "unarchive toast")
    Check.equal(probe.activeFolderTabKey, shelfKey, "and its chip is the open one")

    // Search: notes of archived folders only with the Archive chip, and from the archive.
    store.archiveFolder(id: shelf.id)
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
    vc.showLastFolder()
    probe.confirmDestructiveAlerts(true)
    probe.archiveMenuRun("Shelf", "Delete Folder…")
    probe.confirmDestructiveAlerts(nil)
    Check.equal(store.trashedFolders().map(\.id), [shelf.id], "Delete Folder… moves the archived folder to the trash")
    Check.equal(probe.moreMenuBadge("Archive"), nil, "the Archive count goes with it")
    store.restoreFolder(id: shelf.id)
    Check.expect(store.archivedFolder(id: shelf.id) != nil, "restored, it is archived again")
    probe.commitDelete()
    store.deleteFolder(id: shelf.id)
    Check.equal(probe.moreMenuBadge("Archive"), nil, "folder archive: clean at the end")
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

    // The Scratch chip is the first one in the header.
    vc.showLastFolder()
    Check.expect(probe.isScratchChipVisible && probe.folderTabKeys.first == "scratch", "scratch: its chip is first in the header")
    settings.scratchEnabled = false
    Check.expect(!probe.isScratchChipVisible && !probe.folderTabKeys.contains("scratch"), "scratch: off hides the chip")
    probe.showScratch(edit: false)
    Check.equal(probe.scratchDay, nil, "scratch: off, nothing opens")
    settings.scratchEnabled = true
    Check.expect(probe.isScratchChipVisible, "scratch: on shows the chip again")

    // Today.
    probe.clickFolderTab("scratch")
    probe.layoutNow(); spin(); probe.layoutNow()
    let today = scratch.todayKey
    Check.equal(probe.scratchDay, today, "scratch: the chip opens today")
    Check.equal(probe.headerTitle, "Scratch · Today", "scratch: the screen's name")
    Check.equal(probe.activeFolderTabKey, "scratch", "scratch: its chip is the open one")
    Check.equal(probe.scratchChipTitle, "Today", "scratch: the open chip shows the day")
    Check.expect(probe.isPlusButtonVisible && probe.isSearchButtonVisible, "scratch: search and + stay")
    Check.expect(!probe.canStepToEarlierDay && !probe.canStepToLaterDay, "scratch: nothing to step to yet")
    Check.expect(!probe.clickScratchChipStepper(-1) && probe.scratchDay == today, "scratch: ‹ is off without an earlier day")
    guard let todayNote = scratch.todayNote(create: false) else { Check.expect(false, "scratch: today's note"); return }
    Check.equal(probe.displayedNoteIDs, [todayNote.id], "scratch: one card, today's note")
    Check.equal(probe.focusedNoteID, nil, "scratch: the chip does not start typing")
    probe.clickPlusButton()
    probe.layoutNow(); spin(); probe.layoutNow()
    Check.equal(probe.focusedNoteID, todayNote.id, "scratch: + focuses the note")
    Check.equal(probe.isCardReadOnly(todayNote.id), false, "scratch: today is editable")
    Check.equal(probe.isEditorReadOnly(todayNote.id), false, "scratch: today's editor is editable")
    Check.equal(store.folders().map(\.id), foldersBefore, "scratch: its folder is not in the folder list")
    store.updateNoteBody(id: todayNote.id, body: "zebra scratch line\n- call back re: build")
    Check.equal(store.search("zebra", in: nil, includeArchived: true).map(\.id), [], "scratch: search skips Scratch")
    probe.setHovered(todayNote.id, true)
    probe.layoutNow()
    Check.equal(probe.isPinButtonHidden(todayNote.id), true, "scratch: no pin button")
    Check.equal(probe.trashButtonToolTip(todayNote.id), "Clear Scratch", "scratch: the trash button clears today")
    Check.equal(probe.cardHasDate(todayNote.id), false, "scratch: no date on the card, also on hover")
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
    Check.equal(probe.scratchChipTitle, "Yesterday", "scratch: the chip shows Yesterday")
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
    Check.equal(probe.cardHasDate(todayNote.id), false, "scratch: no date on an earlier day's card")
    render("28-scratch-yesterday-light", false)
    render("29-scratch-yesterday-dark", true)
    probe.setHovered(todayNote.id, false)
    Check.expect(probe.clickScratchChipStepper(1), "scratch: › in the chip is on")
    Check.equal(probe.scratchDay, day2, "scratch: › goes back to today")
    Check.expect(probe.clickScratchChipStepper(-1) && probe.scratchDay == today, "scratch: ‹ in the chip steps to yesterday")
    probe.stepScratchDay(1)

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
    vc.showLastFolder()
    vc.reveal(noteId: t.id, edit: false)
    Check.equal(probe.scratchDay, t.scratchDay, "scratch: reveal opens the note's day")

    // Turning Scratch off while it shows: the last folder.
    settings.scratchEnabled = false
    Check.expect(probe.scratchDay == nil && vc.currentFolderId == (settings.lastFolderId ?? -1),
                 "scratch: off shows the last folder")
    settings.scratchEnabled = true
    settings.scratchKeepDays = 7
    for n in store.scratchNotes(includingTrashed: true) { store.deleteNote(id: n.id) }
    probe.dismissToast()
}
