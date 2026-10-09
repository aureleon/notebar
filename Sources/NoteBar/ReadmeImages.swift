import AppKit
import NoteBarCore
import NoteBarStore
import NoteBarEditor
import NoteBarUI
import NoteBarSettings

/// `NoteBar --readme-images <dir>`: renders the pictures for README.md offscreen, then exits.
/// Each picture shows the light appearance on the left and the dark appearance on the right.
/// No window is ever ordered on screen. Data goes to an empty `NOTEBAR_DATA_DIR` (see `SnapshotMode`).
///
/// Regenerate with `scripts/readme-images.sh` (writes to docs/images/).
@MainActor
enum ReadmeImages {
    static func run(outputPath: String) -> Never {
        let out = URL(fileURLWithPath: outputPath, isDirectory: true)
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let dataDir = SnapshotMode.prepareDataDirectory()

        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        NoteBarUIOptions.useGlass = false   // Liquid Glass cannot be captured offscreen
        NoteBarUIOptions.animations = false

        let suite = "local.dhguz.NoteBar.readme-\(ProcessInfo.processInfo.processIdentifier)"
        let defaults = UserDefaults(suiteName: suite)!
        let settings = AppSettings(defaults: defaults)

        let store: GRDBNoteStore
        do { store = try GRDBNoteStore(directory: dataDir) } catch { SnapshotMode.fail("cannot open store: \(error)") }
        let seeded = seed(store)
        let themes = ThemeManager(settings: settings, store: store)
        let env = AppEnvironment(store: store, backups: nil, settings: settings, themes: themes,
                                 editorFactory: MarkdownEditorFactory())
        let root = NotesRootViewController(env: env)
        env.presenter = root
        let probe = root.probe

        let backdrop = SnapshotMode.Backdrop(frame: .zero)
        backdrop.addSubview(root.view)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100), styleMask: [.borderless],
                              backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.contentView = backdrop

        func spin(_ t: TimeInterval) { RunLoop.current.run(until: Date().addingTimeInterval(t)) }
        let panelSize = NSSize(width: 408, height: 640)
        let margin: CGFloat = 16
        backdrop.frame = NSRect(x: 0, y: 0, width: panelSize.width + 2 * margin, height: panelSize.height + 2 * margin)
        window.setContentSize(backdrop.frame.size)
        root.view.frame = NSRect(x: margin, y: margin, width: panelSize.width, height: panelSize.height)

        /// Captures the panel in one appearance.
        func capturePanel(dark: Bool) -> NSBitmapImageRep? {
            let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)!
            window.appearance = appearance
            backdrop.appearance = appearance
            // Colors that are resolved when a view is made follow the appearance after a few passes.
            for _ in 0..<4 { probe.createAllEditors(); probe.layoutNow(); spin(0.1) }
            spin(0.6)   // images load asynchronously
            probe.layoutNow()
            backdrop.layoutSubtreeIfNeeded()
            backdrop.display()
            guard let rep = backdrop.bitmapImageRepForCachingDisplay(in: backdrop.bounds) else { return nil }
            backdrop.cacheDisplay(in: backdrop.bounds, to: rep)
            return rep
        }

        /// Captures one Settings pane in one appearance.
        /// `maxHeight` (points) cuts the pane off at the bottom, at a row boundary.
        func capturePane(_ tab: SettingsTab, models: SettingsModels, dark: Bool, maxHeight: CGFloat? = nil) -> NSBitmapImageRep? {
            let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)!
            let view = SettingsViews.makeHostingView(for: tab, models: models)
            let w = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            w.isReleasedWhenClosed = false
            w.appearance = appearance
            w.backgroundColor = .windowBackgroundColor
            w.contentView = view
            view.appearance = appearance
            for _ in 0..<3 { view.layoutSubtreeIfNeeded(); spin(0.05) }
            view.display()
            guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
            view.cacheDisplay(in: view.bounds, to: rep)
            let height = view.bounds.height
            w.contentView = nil
            guard let maxHeight, maxHeight < height, let cg = rep.cgImage else { return rep }
            let scale = CGFloat(rep.pixelsHigh) / height
            guard let top = cg.cropping(to: CGRect(x: 0, y: 0, width: CGFloat(cg.width), height: (maxHeight * scale).rounded()))
            else { return rep }
            return NSBitmapImageRep(cgImage: top)
        }

        var written: [String] = []
        func save(_ name: String, light: NSBitmapImageRep?, dark: NSBitmapImageRep?, rounded: Bool = false) {
            guard let light, let dark, let data = sideBySide(light, dark, rounded: rounded) else { return }
            let url = out.appendingPathComponent(name + ".png")
            if (try? data.write(to: url)) != nil { written.append(url.path) }
        }
        func panelPair(_ name: String) { save(name, light: capturePanel(dark: false), dark: capturePanel(dark: true)) }

        root.showFolderList()
        panelPair("folders")

        root.showFolder(seeded.notes)
        panelPair("notes")

        root.showFolder(seeded.notes)
        probe.layoutNow()
        probe.setHovered(seeded.hovered, true)
        panelPair("note-actions")
        probe.setHovered(seeded.hovered, false)

        root.beginSearch(query: "trip")
        probe.setSearchQuery("trip", allFolders: true)
        panelPair("search")
        let searchOK = probe.isSearching && probe.cardCount >= 2
        probe.pressEscape()

        let models = SettingsModels(env: env)
        // Appearance: stop after the Theme section (the rows below are cut by the pane height).
        for (tab, maxHeight) in [(SettingsTab.general, CGFloat?.none), (.appearance, 415)] {
            save("settings-\(tab.rawValue)", light: capturePane(tab, models: models, dark: false, maxHeight: maxHeight),
                 dark: capturePane(tab, models: models, dark: true, maxHeight: maxHeight), rounded: true)
        }

        store.flush()
        try? store.close()
        window.close()
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: dataDir)

        for w in written { print("wrote \(w)") }
        guard written.count == 6 else { SnapshotMode.fail("only \(written.count) of 6 PNGs written") }
        guard searchOK else { SnapshotMode.fail("the search picture does not show the expected results") }
        exit(0)
    }

    /// Puts two bitmaps next to each other on a transparent background.
    private static func sideBySide(_ a: NSBitmapImageRep, _ b: NSBitmapImageRep, rounded: Bool) -> Data? {
        let gap = 32, pad = rounded ? 24 : 0
        let w = a.pixelsWide + gap + b.pixelsWide + 2 * pad
        let h = max(a.pixelsHigh, b.pixelsHigh) + 2 * pad
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h, bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        func draw(_ img: NSBitmapImageRep, x: Int) {
            let r = NSRect(x: x, y: h - pad - img.pixelsHigh, width: img.pixelsWide, height: img.pixelsHigh)
            NSGraphicsContext.saveGraphicsState()
            if rounded {
                // A window-like card with a soft shadow.
                let shadow = NSShadow()
                shadow.shadowColor = NSColor.black.withAlphaComponent(0.25)
                shadow.shadowBlurRadius = 16
                shadow.shadowOffset = NSSize(width: 0, height: -4)
                shadow.set()
                let path = NSBezierPath(roundedRect: r, xRadius: 24, yRadius: 24)
                NSColor.white.setFill()
                path.fill()
                NSShadow().set()
                path.addClip()
            }
            img.draw(in: r)
            NSGraphicsContext.restoreGraphicsState()
        }
        draw(a, x: pad)
        draw(b, x: pad + a.pixelsWide + gap)
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])
    }

    // MARK: Sample data

    struct Seeded {
        var notes: FolderID
        var hovered: NoteID
    }

    private static func seed(_ store: GRDBNoteStore) -> Seeded {
        var personal = store.folders()[0]
        personal.name = "Personal"; store.updateFolder(personal)
        let work = store.createFolder(name: "Work")
        let travel = store.createFolder(name: "Travel")
        let recipes = store.createFolder(name: "Recipes")
        let ideas = store.createFolder(name: "Ideas")
        var w = work; w.isPinned = true; store.updateFolder(w)
        var t = travel; t.color = .green; store.updateFolder(t)
        var r = recipes; r.color = .yellow; store.updateFolder(r)
        var i = ideas; i.color = .purple; store.updateFolder(i)

        @discardableResult
        func add(_ folder: FolderID, _ body: String, color: NoteColor = .none, mode: NoteMode = .standard,
                 pinned: Bool = false, folded: Bool = false) -> Note {
            var n = store.createNote(in: folder, body: body, mode: mode, position: .bottom)
            n.color = color; n.isPinned = pinned; n.isFolded = folded
            store.updateNote(n)
            return store.note(id: n.id) ?? n
        }

        add(personal.id, "Groceries\n- [ ] Milk\n- [x] Eggs\n- [ ] Avocados\n- [ ] Coffee beans",
            color: .cream, pinned: true)
        let weekend = add(personal.id, """
            Weekend
            Call **Mom** about Sunday lunch.
            Pick up the *camera* from the shop.
            > Book the trip to Lisbon before Friday!
            """, color: .purple)
        add(personal.id, "Reading list\n1. The Hobbit\n2. Project Hail Mary\n3. Dune", color: .blue, folded: true)

        let photo = add(personal.id, "Sunset at the lake")
        if let img = try? store.addImageAttachment(to: photo.id, data: SnapshotMode.samplePNG(width: 900, height: 420),
                                                    fileExtension: "png", displayName: "sunset.png") {
            var p = store.note(id: photo.id)!
            p.body = "Sunset at the lake\n" + AttachmentLink.markdown(for: img)
            p.color = .green
            store.updateNote(p)
        }
        add(personal.id, "Gift ideas\nA nice ==notebook== for Sam.", color: .pink)

        add(work.id, "# Team meeting\n- [ ] Send the notes\n- [ ] Plan the trip budget\n==Friday 10:00==", color: .blue)
        add(work.id, "Quarterly goals\nShip the new website.\nHire one designer.", color: .green)
        add(travel.id, "Lisbon trip\n- [x] Flights\n- [ ] Hotel\n- [ ] Pastéis de nata", color: .green)
        add(travel.id, "Packing list\nPassport, charger, sunglasses.")
        add(recipes.id, "Pancakes\n2 eggs, 1 cup flour, 1 cup milk.", color: .yellow)
        add(ideas.id, "App ideas\nA notes bar that slides in from the edge.")
        store.flush()
        return Seeded(notes: personal.id, hovered: weekend.id)
    }
}
