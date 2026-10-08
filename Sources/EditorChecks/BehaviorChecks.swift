import AppKit
import NoteBarCore
import NoteBarEditor

/// Exercises a live `MarkdownNoteEditor` in an offscreen window that is never ordered on screen.
@MainActor
enum BehaviorChecks {
    static func makeEnv(hideMarkup: Bool = false) -> AppEnvironment {
        let defaults = UserDefaults(suiteName: "NoteBarEditorChecks")!
        defaults.removePersistentDomain(forName: "NoteBarEditorChecks")
        let settings = AppSettings(defaults: defaults)
        settings.hideMarkup = hideMarkup
        let store = InMemoryNoteStore()
        let themes = ThemeManager(settings: settings, store: store)
        return AppEnvironment(store: store, backups: nil, settings: settings, themes: themes, editorFactory: MarkdownEditorFactory())
    }

    static func spin(_ seconds: TimeInterval = 0.002) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    @MainActor final class Harness {
        let env: AppEnvironment
        let note: Note
        let editor: MarkdownNoteEditor
        let window: NSWindow
        var bodies: [String] = []
        var events: [EditorEvent] = []
        var layoutChanges = 0

        init(_ body: String, mode: NoteMode = .standard, hideMarkup: Bool = false) {
            env = BehaviorChecks.makeEnv(hideMarkup: hideMarkup)
            let folder = env.store.folders()[0]
            note = env.store.createNote(in: folder.id, body: body, mode: mode, position: .top)
            editor = MarkdownNoteEditor(note: note, env: env)
            window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 300, height: 600), styleMask: [.borderless],
                              backing: .buffered, defer: true)
            window.isReleasedWhenClosed = false
            let content = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 600))
            window.contentView = content
            editor.frame = NSRect(x: 20, y: 20, width: 260, height: 40)
            content.addSubview(editor)
            editor.onBodyChange = { [unowned self] in self.bodies.append($0); self.env.store.updateNoteBody(id: self.note.id, body: $0) }
            editor.onEvent = { [unowned self] in self.events.append($0) }
            editor.onLayoutChange = { [unowned self] in self.layoutChanges += 1 }
        }

        var tv: NSTextView { editor.textViewForTesting }
        var body: String { editor.markdown }

        func focus(at loc: Int? = nil) {
            editor.focus(atEnd: loc == nil)
            if let loc { tv.setSelectedRange(NSRange(location: loc, length: 0)) }
            BehaviorChecks.spin()
        }

        func type(_ s: String) {
            tv.insertText(s, replacementRange: tv.selectedRange())
            BehaviorChecks.spin()
        }
    }

    static func run() {
        // Loading keeps the body exactly.
        for body in ["", "Title\n- [ ] a\n- [x] b", "![i](attachment:99) [f](attachment:98)\n```\n- [ ] x\n```", "a\r\nb", "😀 **x**"] {
            let h = Harness(body)
            Check.equal(h.body, body, "editor keeps body")
        }

        // Links get the pointing hand, also in a card that is not being edited.
        do {
            let h = Harness("See [docs](https://example.com) and http://x.com now")
            let s = h.tv.string as NSString
            Check.expect(h.editor.pointerIsLinkForTesting(atCharacter: s.range(of: "docs").location + 1), "link text: pointing hand (not editing)")
            Check.expect(h.editor.pointerIsLinkForTesting(atCharacter: s.range(of: "x.com").location), "bare URL: pointing hand")
            Check.expect(!h.editor.pointerIsLinkForTesting(atCharacter: s.range(of: "See").location), "plain text: no pointing hand")
        }

        // Height grows with content; layout callback fires.
        let h1 = Harness("one line")
        let hA = h1.editor.intrinsicContentSize.height
        Check.expect(hA > 10 && hA < 40, "single line height \(hA)")
        h1.focus()
        h1.type("\nsecond\nthird")
        let hB = h1.editor.intrinsicContentSize.height
        Check.expect(hB > hA * 2, "height grows \(hA) -> \(hB)")
        Check.expect(h1.layoutChanges > 0, "layout change reported")
        Check.equal(h1.bodies.last, "one line\nsecond\nthird", "typed body reported")

        // Formatting through perform().
        let h2 = Harness("hello world")
        h2.focus()
        h2.tv.setSelectedRange(NSRange(location: 6, length: 5))
        h2.editor.perform(.bold)
        Check.equal(h2.body, "hello **world**", "perform bold")
        Check.equal(h2.tv.selectedRange(), NSRange(location: 8, length: 5), "selection after bold")
        spin()
        h2.editor.undoManagerForTesting.undo()
        spin()
        Check.equal(h2.body, "hello world", "undo bold")
        Check.equal(h2.bodies.last, "hello world", "undo reported")
        h2.editor.undoManagerForTesting.redo()
        spin()
        Check.equal(h2.body, "hello **world**", "redo bold")

        // Checkbox toggle + undo.
        let h3 = Harness("List\n- [ ] milk\n- [x] eggs")
        h3.editor.toggleCheckbox(at: 5)
        Check.equal(h3.body, "List\n- [x] milk\n- [x] eggs", "toggle checkbox")
        Check.equal(h3.env.store.note(id: h3.note.id)?.body, "List\n- [x] milk\n- [x] eggs", "store updated")
        spin()
        h3.editor.undoManagerForTesting.undo()
        spin()
        Check.equal(h3.body, "List\n- [ ] milk\n- [x] eggs", "undo toggle")

        // Live conversion of typed checklist prefix.
        let h4 = Harness("")
        h4.focus()
        h4.type("- [ ] ")
        Check.equal(h4.tv.string, "\u{FFFC}", "typed prefix becomes checkbox")
        h4.type("buy")
        Check.equal(h4.body, "- [ ] buy", "checkbox body")
        // Enter continues the list.
        h4.editor.doCommandForTesting(#selector(NSResponder.insertNewline(_:)))
        Check.equal(h4.body, "- [ ] buy\n- [ ] ", "enter continues checklist")
        h4.editor.doCommandForTesting(#selector(NSResponder.insertNewline(_:)))
        Check.equal(h4.body, "- [ ] buy\n", "enter on empty item ends list")
        h4.type("- a")
        h4.editor.doCommandForTesting(#selector(NSResponder.insertTab(_:)))
        Check.equal(h4.body, "- [ ] buy\n\t- a", "tab indents list item")
        h4.editor.doCommandForTesting(#selector(NSResponder.insertBacktab(_:)))
        Check.equal(h4.body, "- [ ] buy\n- a", "shift-tab outdents")

        // Events.
        let h5 = Harness("first\nsecond")
        h5.focus(at: 2)
        h5.editor.doCommandForTesting(#selector(NSResponder.moveUp(_:)))
        Check.expect(h5.events.contains { if case .focusPrevious = $0 { return true }; return false }, "up on first line")
        h5.tv.setSelectedRange(NSRange(location: 8, length: 0))
        h5.editor.doCommandForTesting(#selector(NSResponder.moveDown(_:)))
        Check.expect(h5.events.contains { if case .focusNext = $0 { return true }; return false }, "down on last line")
        h5.editor.doCommandForTesting(#selector(NSResponder.cancelOperation(_:)))
        Check.expect(h5.events.contains { if case .escape = $0 { return true }; return false }, "escape event")
        Check.expect(h5.editor.isEditingFocused, "focused")

        // apply(note:) — same body keeps the caret, new body replaces text, mode switches codec.
        let h6 = Harness("abc\n- [ ] x")
        h6.focus(at: 2)
        var n = h6.env.store.note(id: h6.note.id)!
        n.color = .green
        h6.editor.apply(note: n)
        Check.equal(h6.tv.selectedRange(), NSRange(location: 2, length: 0), "apply same body keeps caret")
        n.body = "abc\n- [ ] x\nmore"
        h6.editor.apply(note: n)
        Check.equal(h6.body, "abc\n- [ ] x\nmore", "apply new body")
        Check.equal(h6.tv.selectedRange(), NSRange(location: 2, length: 0), "caret kept before change")
        n.mode = .code
        h6.editor.apply(note: n)
        Check.equal(h6.tv.string, "abc\n- [ ] x\nmore", "code mode shows raw checklist")
        Check.equal(h6.body, "abc\n- [ ] x\nmore", "code mode body unchanged")
        h6.tv.setSelectedRange(NSRange(location: 3, length: 0))
        h6.editor.doCommandForTesting(#selector(NSResponder.insertTab(_:)))
        Check.equal(h6.body, "abc \n- [ ] x\nmore", "code mode tab inserts spaces to tab stop")
        n.mode = .standard
        n.body = h6.body
        h6.editor.apply(note: n)
        Check.equal(h6.tv.string, "abc \n\u{FFFC}x\nmore", "standard mode restores checkbox")

        // Invisible markdown: markers hidden when unfocused, revealed around the caret.
        let h7 = Harness("Title\nsome **bold** text", hideMarkup: true)
        let star = 11 // first '*' of "**bold**"
        Check.expect(h7.editor.glyphIsHiddenForTesting(at: star), "marker hidden when unfocused")
        Check.expect(!h7.editor.glyphIsHiddenForTesting(at: star + 2), "content visible")
        h7.focus(at: 14)
        Check.expect(!h7.editor.glyphIsHiddenForTesting(at: star), "marker revealed with caret inside")
        h7.tv.setSelectedRange(NSRange(location: 2, length: 0))
        spin()
        Check.expect(h7.editor.glyphIsHiddenForTesting(at: star), "marker hidden again")
        h7.env.settings.hideMarkup = false
        spin()
        Check.expect(!h7.editor.glyphIsHiddenForTesting(at: star), "setting off shows markers live")

        // Paste markdown text: checklist prefix becomes a checkbox, attachment tokens render.
        let h8 = Harness("")
        h8.focus()
        let pb = NSPasteboard(name: NSPasteboard.Name("NoteBarEditorChecks-\(UUID().uuidString)"))
        pb.clearContents()
        pb.setString("- [ ] pasted\nline", forType: .string)
        h8.editor.pasteForTesting(pb)
        spin()
        Check.equal(h8.body, "- [ ] pasted\nline", "paste markdown")
        Check.equal(h8.tv.string, "\u{FFFC}pasted\nline", "pasted checkbox is live")
        // Paste image data → attachment token.
        pb.clearContents()
        pb.setData(Snapshots.samplePNG(width: 40, height: 20), forType: .png)
        h8.editor.pasteForTesting(pb)
        spin()
        Check.expect(h8.body.range(of: #"\n!\[Pasted Image\.png\]\(attachment:\d+\)$"#, options: .regularExpression) != nil,
                     "pasted image token: \(h8.body.debugDescription)")
        Check.equal(h8.env.store.attachments(for: h8.note.id).count, 1, "image attachment stored")
        pb.releaseGlobally()

        // insertAttachments at the end when unfocused.
        let h9 = Harness("note")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("nb-editor-check.txt")
        try? "hello".write(to: url, atomically: true, encoding: .utf8)
        if let a = try? h9.env.store.addAttachment(to: h9.note.id, fileURL: url) {
            h9.editor.insertAttachments([a])
            Check.equal(h9.body, "note\n[nb-editor-check.txt](attachment:\(a.id))", "insert file attachment at end (own line)")
        }

        // Search highlight selects the first match.
        let h10 = Harness("alpha beta Beta")
        h10.tv.setSelectedRange(NSRange(location: 0, length: 0))
        h10.editor.highlightSearch("beta")
        Check.equal(h10.tv.selectedRange(), NSRange(location: 0, length: 0), "search does not move the selection")
        Check.equal(h10.editor.searchMatchCount, 2, "search marks every match")
        h10.editor.clearSearchHighlight()
        Check.equal(h10.editor.searchMatchCount, 0, "clear removes search marks")
        h10.editor.highlightSearch("")

        // Copy writes markdown.
        let h11 = Harness("x\n- [x] **done**")
        h11.tv.setSelectedRange(NSRange(location: 2, length: 9))
        let cpb = NSPasteboard(name: NSPasteboard.Name("NoteBarEditorChecks-copy-\(UUID().uuidString)"))
        _ = h11.tv.writeSelection(to: cpb, types: [.string])
        Check.equal(cpb.string(forType: .string), "- [x] **done**", "copy as markdown")
        cpb.releaseGlobally()

        attachmentOwnershipChecks()
    }

    /// Pasting a tile from another note gives this note its own attachment row (and image file copy).
    static func attachmentOwnershipChecks() {
        let h = Harness("target")
        let store = h.env.store
        let other = store.createNote(in: store.folders()[0].id, body: "", mode: .standard, position: .top)
        guard let img = try? store.addImageAttachment(to: other.id, data: Snapshots.samplePNG(width: 8, height: 8),
                                                     fileExtension: "png", displayName: "Shot.png") else {
            Check.expect(false, "image attachment for ownership check"); return
        }
        let fileURL = FileManager.default.temporaryDirectory.appendingPathComponent("nb-editor-owner.txt")
        try? "x".write(to: fileURL, atomically: true, encoding: .utf8)
        guard let file = try? store.addAttachment(to: other.id, fileURL: fileURL) else {
            Check.expect(false, "file attachment for ownership check"); return
        }
        let own = try? store.addImageAttachment(to: h.note.id, data: Snapshots.samplePNG(width: 8, height: 8),
                                                fileExtension: "png", displayName: "Own.png")
        let pasted = "![Shot.png](attachment:\(img.id)) and [nb-editor-owner.txt](attachment:\(file.id)) again ![Shot.png](attachment:\(img.id))"
            + " own ![Own.png](attachment:\(own?.id ?? 0)) gone [x](attachment:999999)"
        h.focus()
        let pb = NSPasteboard(name: NSPasteboard.Name("NoteBarEditorChecks-own-\(UUID().uuidString)"))
        pb.clearContents()
        pb.setString(pasted, forType: .string)
        h.editor.pasteForTesting(pb)
        spin()
        pb.releaseGlobally()
        let ids = AttachmentLink.matches(in: h.body).map(\.attachmentID)
        Check.equal(ids.count, 5, "pasted tokens kept: \(h.body.debugDescription)")
        if ids.count == 5 {
            Check.expect(ids[0] != img.id && ids[1] != file.id, "foreign tokens rewritten")
            Check.equal(ids[0], ids[2], "same source cloned once")
            Check.equal(ids[3], own?.id ?? -1, "own attachment kept")
            Check.equal(ids[4], 999999, "unknown attachment left alone")
            for id in ids.prefix(2) {
                Check.equal(store.attachment(id: id)?.noteId, h.note.id, "clone owned by target note")
            }
            Check.equal(store.attachment(id: ids[0])?.kind, .image, "image clone kind")
            Check.equal(store.attachment(id: ids[0])?.displayName, "Shot.png", "image clone name")
            Check.equal(store.attachment(id: ids[1])?.kind, .fileBookmark, "file clone kind")
            let a = store.attachment(id: ids[0]).flatMap(store.url(for:))
            let b = store.url(for: img)
            Check.expect(a != nil && a != b, "image file copied")
        }
        Check.equal(store.attachment(id: img.id)?.noteId, other.id, "source attachment untouched")
        // Pure helper: nothing to do for own / plain text.
        Check.equal(AttachmentRehoming.rehome("plain", into: h.note.id, store: store), "plain", "rehome plain text")
        // Drop folders: an unreferenced, old folder is pruned; a referenced one is kept.
        // Never touches the real support folder: a private root.
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("nb-editor-drops-\(UUID().uuidString)", isDirectory: true)
        let old = root.appendingPathComponent("old", isDirectory: true)
        let ref = root.appendingPathComponent("ref", isDirectory: true)
        let young = root.appendingPathComponent("young", isDirectory: true)
        for d in [old, ref, young] { try? fm.createDirectory(at: d, withIntermediateDirectories: true) }
        let refFile = ref.appendingPathComponent("Mail.pdf")
        try? "pdf".write(to: refFile, atomically: true, encoding: .utf8)
        _ = try? store.addAttachment(to: h.note.id, fileURL: refFile)
        let past = Date().addingTimeInterval(-30 * 24 * 3600)
        for d in [old, ref] { try? fm.setAttributes([.creationDate: past], ofItemAtPath: d.path) }
        Check.equal(DroppedFileStorage.pruneUnreferenced(store: store, olderThan: 7 * 24 * 3600, root: root), 1, "prune old drop folder")
        Check.expect(!fm.fileExists(atPath: old.path), "old unreferenced folder removed")
        Check.expect(fm.fileExists(atPath: refFile.path), "referenced dropped file kept")
        Check.expect(fm.fileExists(atPath: young.path), "young folder kept")
        try? fm.removeItem(at: root)
    }
}
