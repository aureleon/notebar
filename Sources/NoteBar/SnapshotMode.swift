import AppKit
import NoteBarCore
import NoteBarStore
import NoteBarEditor
import NoteBarUI
import NoteBarPanel

/// `NoteBar --snapshot <dir>`: renders the REAL panel content (GRDB store + Markdown editors) offscreen
/// to PNG files, then exits. No window is ever ordered on screen.
///
/// Data goes to `$NOTEBAR_DATA_DIR` (it must not contain a database yet). Without it, a new temporary
/// directory is used. Settings go to a throwaway UserDefaults suite, so the real preferences and the
/// real notes are never touched.
@MainActor
enum SnapshotMode {
    static func run(outputPath: String) -> Never {
        let fm = FileManager.default
        let out = URL(fileURLWithPath: outputPath, isDirectory: true)
        try? fm.createDirectory(at: out, withIntermediateDirectories: true)

        // Data directory: never the real one.
        let realDefault = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("NoteBar", isDirectory: true).standardizedFileURL.path
        if (ProcessInfo.processInfo.environment["NOTEBAR_DATA_DIR"] ?? "").isEmpty {
            let tmp = fm.temporaryDirectory.appendingPathComponent("notebar-snapshot-\(UUID().uuidString)", isDirectory: true)
            setenv("NOTEBAR_DATA_DIR", tmp.path, 1)
        }
        let dataDir = AppPaths.supportDirectory
        guard dataDir.standardizedFileURL.path != realDefault else {
            fail("NOTEBAR_DATA_DIR points at the real data folder; use an empty temporary directory")
        }
        guard !fm.fileExists(atPath: dataDir.appendingPathComponent("notebar.sqlite").path) else {
            fail("\(dataDir.path) already holds a database; use an empty NOTEBAR_DATA_DIR")
        }
        AppPaths.ensureDirectories()

        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        NoteBarUIOptions.useGlass = false   // Liquid Glass cannot be captured offscreen
        NoteBarUIOptions.animations = false

        let suite = "local.dhguz.NoteBar.snapshot-\(ProcessInfo.processInfo.processIdentifier)"
        let defaults = UserDefaults(suiteName: suite)!
        let settings = AppSettings(defaults: defaults)

        let store: GRDBNoteStore
        do { store = try GRDBNoteStore(directory: dataDir) } catch { fail("cannot open store: \(error)") }
        let seeded = seed(store, dataDir: dataDir)
        let themes = ThemeManager(settings: settings, store: store)
        let env = AppEnvironment(store: store, backups: nil, settings: settings, themes: themes,
                                 editorFactory: MarkdownEditorFactory())
        let root = NotesRootViewController(env: env)
        env.presenter = root
        let probe = root.probe

        let backdrop = Backdrop(frame: .zero)
        backdrop.addSubview(root.view)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100), styleMask: [.borderless],
                              backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.contentView = backdrop

        func spin(_ t: TimeInterval) { RunLoop.current.run(until: Date().addingTimeInterval(t)) }
        func setSize(_ size: NSSize) {
            let m: CGFloat = 12
            backdrop.frame = NSRect(x: 0, y: 0, width: size.width + 2 * m, height: size.height + 2 * m)
            window.setContentSize(backdrop.frame.size)
            root.view.frame = NSRect(x: m, y: m, width: size.width, height: size.height)
        }

        var written: [String] = []
        func render(_ name: String, dark: Bool, settle: TimeInterval = 0.1) {
            let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)!
            window.appearance = appearance
            backdrop.appearance = appearance
            for _ in 0..<3 { probe.layoutNow(); spin(settle / 3) }
            // Images and Quick Look thumbnails load asynchronously.
            spin(0.6)
            probe.layoutNow()
            spin(0.05)
            probe.layoutNow()
            backdrop.layoutSubtreeIfNeeded()
            backdrop.display()
            guard let rep = backdrop.bitmapImageRepForCachingDisplay(in: backdrop.bounds) else { return }
            backdrop.cacheDisplay(in: backdrop.bounds, to: rep)
            let url = out.appendingPathComponent(name + ".png")
            if (try? rep.representation(using: .png, properties: [:])?.write(to: url)) != nil { written.append(url.path) }
        }

        // The same width rule as the panel: automatic (27 % of the main screen, 380...600) unless the user set one.
        let panelWidth = PanelSizing.width(requested: PanelSizing.requestedWidth(settings),
                                           visibleWidth: NSScreen.main?.visibleFrame.width ?? 0)
        let panelSize = NSSize(width: panelWidth, height: 760)
        setSize(panelSize)

        root.showFolderList()
        render("01-folders-light", dark: false)
        render("02-folders-dark", dark: true)

        root.showFolder(seeded.notes)
        probe.createAllEditors()
        render("03-notes-light", dark: false, settle: 0.4)
        render("04-notes-dark", dark: true)

        // Tall render: every card of the folder, top to bottom.
        probe.createAllEditors()
        // Lay out at the panel height first to learn the content height, then size the window to it.
        probe.layoutNow()
        setSize(NSSize(width: panelWidth, height: max(panelSize.height, probe.contentHeight + 20)))
        probe.layoutNow()
        render("05-notes-tall-light", dark: false, settle: 0.4)
        render("06-notes-tall-dark", dark: true)

        // Invisible Markdown is the default; this one shows the dimmed-markers alternative.
        setSize(panelSize)
        settings.hideMarkup = false
        render("07-notes-visible-markup-light", dark: false, settle: 0.3)
        settings.hideMarkup = true

        // Other folders.
        root.showFolder(seeded.work)
        probe.createAllEditors()
        render("08-work-light", dark: false, settle: 0.3)
        settings.colorStyle = .leftBar
        root.showFolder(seeded.notes)
        probe.createAllEditors()
        render("09-notes-leftbar-dark", dark: true, settle: 0.3)
        settings.colorStyle = .background

        // Search started with a query (the URL scheme / AppleScript path).
        root.beginSearch(query: "list")
        probe.createAllEditors()
        render("10-search-light", dark: false, settle: 0.3)
        let searchOK = probe.isSearching && probe.searchQuery == "list" && probe.cardCount == 2

        let editors = probe.liveEditorCount
        store.flush()
        try? store.close()
        window.close()

        defaults.removePersistentDomain(forName: suite)
        print("NoteBar snapshot: data in \(dataDir.path)")
        print("  markdown editors live: \(editors), editor type: \(seeded.editorType(probe))")
        for w in written { print("  wrote \(w)") }
        guard written.count == 10 else { fail("only \(written.count) of 10 PNGs written") }
        guard searchOK else { fail("beginSearch(query:) did not show the expected results") }
        exit(0)
    }

    private static func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data("NoteBar --snapshot: \(message)\n".utf8))
        exit(1)
    }

    // MARK: Sample data

    struct Seeded {
        var notes: FolderID
        var work: FolderID
        var firstNote: NoteID
        @MainActor func editorType(_ probe: NotesUIProbe) -> String {
            probe.editor(of: firstNote).map { String(describing: type(of: $0)) } ?? "none"
        }
    }

    private static func seed(_ store: GRDBNoteStore, dataDir: URL) -> Seeded {
        let notes = store.folders()[0]
        let work = store.createFolder(name: "Work")
        let ideas = store.createFolder(name: "Ideas")
        let shopping = store.createFolder(name: "Shopping")
        _ = store.createFolder(name: "Archive")
        var w = work; w.isPinned = true; store.updateFolder(w)
        var i = ideas; i.color = .purple; store.updateFolder(i)
        var s = shopping; s.color = .green; store.updateFolder(s)

        @discardableResult
        func add(_ folder: FolderID, _ body: String, color: NoteColor = .none, mode: NoteMode = .standard,
                 pinned: Bool = false, folded: Bool = false) -> Note {
            var n = store.createNote(in: folder, body: body, mode: mode, position: .bottom)
            n.color = color; n.isPinned = pinned; n.isFolded = folded
            store.updateNote(n)
            return store.note(id: n.id) ?? n
        }

        let pinned = add(notes.id, "Breakfast Shopping List\n- [ ] Eggs\n- [x] Avocado\n- [ ] Bacon",
                         color: .cream, pinned: true)
        add(notes.id, """
            # Markdown styles
            *italic*, **bold**, ***bold italic***, ~~strike~~
            Inline `code` and ==marked== text, a [link](https://example.com)
            > A quote in italic brown
            ## Second level header
            ```
            let answer = 42
            print(answer)
            ```
            """, color: .purple)
        add(notes.id, "Today's Goals\n- [ ] Reply to e-mails\n- [x] Pay the bills\n- [ ] Review calendar\n1. numbered\n2. list\n- bullet",
            color: .blue)
        add(notes.id, "Colors\nAccent: #ff8800 and #34c759\nWritten in #rrggbb format.", color: .yellow)

        // Image attachment generated in code + a file shortcut.
        let media = add(notes.id, "Picture & file")
        var mediaBody = "Picture & file\n"
        if let img = try? store.addImageAttachment(to: media.id, data: samplePNG(width: 900, height: 520),
                                                    fileExtension: "png", displayName: "sunset.png") {
            mediaBody += AttachmentLink.markdown(for: img) + "\n"
        }
        let fixture = dataDir.appendingPathComponent("Fixtures", isDirectory: true)
        try? FileManager.default.createDirectory(at: fixture, withIntermediateDirectories: true)
        let doc = fixture.appendingPathComponent("Project Plan.txt")
        try? "Project plan\n1. Panel\n2. Editor\n3. Ship\n".write(to: doc, atomically: true, encoding: .utf8)
        if let file = try? store.addAttachment(to: media.id, fileURL: doc) {
            mediaBody += "File shortcut: " + AttachmentLink.markdown(for: file)
        }
        var m = store.note(id: media.id)!; m.body = mediaBody; m.color = .green; store.updateNote(m)

        add(notes.id, "snippet.swift\nfunc greet(_ name: String) -> String {\n    \"Hello, \\(name)!\"\n}\nprint(greet(\"NoteBar\"))",
            mode: .code)
        add(notes.id, "Folded long note\nLine two\nLine three\nLine four\nLine five", color: .pink, folded: true)
        add(notes.id, "Plain text note\nNo **styling** here, # not a header.", mode: .plain)

        add(work.id, "# Meeting notes\n> Remember the agenda\n- [ ] Send minutes\n==important== `code`", color: .blue)
        add(work.id, "Quarterly plan\nShip the panel.\nPolish the editor.", color: .green)
        add(ideas.id, "Ideas\nA notes bar that slides in from the edge.")
        add(shopping.id, "Groceries\n- [ ] Milk\n- [ ] Bread")
        store.flush()
        return Seeded(notes: notes.id, work: work.id, firstNote: pinned.id)
    }

    /// A landscape PNG (gradient sky, sun, hill).
    private static func samplePNG(width: Int, height: Int) -> Data {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8,
                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                   bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        let w = CGFloat(width), h = CGFloat(height)
        NSGradient(starting: NSColor(srgbRed: 0.99, green: 0.60, blue: 0.33, alpha: 1),
                   ending: NSColor(srgbRed: 0.33, green: 0.52, blue: 0.95, alpha: 1))!
            .draw(in: NSRect(x: 0, y: 0, width: w, height: h), angle: 90)
        NSColor(srgbRed: 1, green: 0.93, blue: 0.6, alpha: 1).setFill()
        NSBezierPath(ovalIn: NSRect(x: w * 0.62, y: h * 0.45, width: h * 0.28, height: h * 0.28)).fill()
        NSColor(srgbRed: 0.2, green: 0.45, blue: 0.3, alpha: 1).setFill()
        let hill = NSBezierPath()
        hill.move(to: .zero)
        hill.curve(to: NSPoint(x: w, y: h * 0.22), controlPoint1: NSPoint(x: w * 0.3, y: h * 0.6),
                   controlPoint2: NSPoint(x: w * 0.6, y: 0))
        hill.line(to: NSPoint(x: w, y: 0))
        hill.close()
        hill.fill()
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])!
    }

    /// Desktop-like background behind the panel.
    final class Backdrop: NSView {
        override var isFlipped: Bool { true }
        override func draw(_ dirtyRect: NSRect) {
            NSGradient(colors: [NSColor(srgbRed: 0.05, green: 0.10, blue: 0.32, alpha: 1),
                                NSColor(srgbRed: 0.16, green: 0.36, blue: 0.78, alpha: 1),
                                NSColor(srgbRed: 0.07, green: 0.14, blue: 0.42, alpha: 1)])?.draw(in: bounds, angle: -60)
        }
    }
}
