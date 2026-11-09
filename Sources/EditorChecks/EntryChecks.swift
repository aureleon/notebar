import AppKit
import NoteBarCore
import NoteBarEditor

/// Scratch entries in a live editor: markers as attachment characters, the caret rules, the fade, the
/// sparse times, a new entry and its pruning, and the entry menu.
@MainActor
enum EntryChecks {
    typealias Harness = BehaviorChecks.Harness
    static let obj = "\u{FFFC}"
    static let entries = CodecOptions(checkboxes: true, attachments: true, entries: true)

    static func run() {
        codec()
        loading()
        caret()
        editing()
        newEntry()
        styling()
        menu()
        vim()
    }

    /// Vim keys: the Normal-mode caret skips marker lines, and a deleted entry line takes its marker along.
    static func vim() {
        // 0: marker, 1: \n, 2...9 "call Sam", 10: \n, 11: marker, 12: \n, 13...20 "ping Raj", 21: \n, 22... "more"
        let h = Harness("--- 09:14 ---\ncall Sam\n--- 09:20 ---\nping Raj\nmore", scratch: true)
        h.env.settings.vimKeybinds = true
        h.focus(at: 2)
        Check.equal(h.editor.vimMode, .normal, "entries, vim: Normal mode")
        h.editor.vimKeysForTesting("j")
        Check.equal(h.editor.selectedRangeForTesting.location, 13, "entries, vim: j skips the marker line")
        h.editor.vimKeysForTesting("k")
        let up = h.editor.selectedRangeForTesting.location
        Check.expect(up >= 2 && up <= 10, "entries, vim: k skips it on the way back (\(up))")
        h.editor.vimKeysForTesting("jdd")
        Check.equal(h.body, "--- 09:14 ---\ncall Sam\n--- 09:20 ---\nmore", "entries, vim: dd deletes a line of the entry")
        h.editor.vimKeysForTesting("dd")
        BehaviorChecks.spin()
        Check.equal(ScratchEntries.entries(in: h.body).count, 1, "entries, vim: dd of the last line leaves no empty entry (\(h.body.debugDescription))")
        Check.expect(h.body.hasPrefix("--- 09:14 ---\ncall Sam"), "entries, vim: the entry above is kept")
    }

    static func codec() {
        for s in ["--- 09:14 ---", "--- 09:14 ---\na", "a\n--- 09:14 x ---\nb\n--- 10:00 ---\n", "a\r\n--- 09:14 ---\r\nb",
                  "```\n--- 09:14 ---\n```", "- [ ] a\n--- 09:14 ---\n- [x] b", "x --- 09:14 ---"] {
            CodecChecks.roundTrip(s, entries)
        }
        let attr = MarkdownCodec.attributedString(from: "a\n--- 09:14 ---\nb", options: entries)
        Check.equal(attr.string, "a\n\(obj)\nb", "entries: a marker is one character in storage")
        Check.equal(CodecChecks.embedCount("--- 09:14 ---\na"), 0, "entries: a marker in a normal note stays text")
        Check.equal(CodecChecks.embedCount("```\n--- 09:14 ---\n```", entries), 0, "entries: no marker in fenced code")
        let lines = BlockScanner.scan(attr.string as NSString, entry: { $0 == 2 }, titles: false)
        Check.equal(lines.map(\.kind), [.paragraph, .entry, .paragraph], "entries: the marker line has its own kind")
        Check.expect(!lines.contains(where: \.isTitle), "entries: a Scratch note has no title line")
    }

    static func loading() {
        let body = "--- 09:14 ---\ncall Sam\n--- 09:20 ---\nping Raj"
        let h = Harness(body, scratch: true)
        Check.equal(h.tv.string, "\(obj)\ncall Sam\n\(obj)\nping Raj", "entries: storage of a Scratch note")
        Check.equal(h.body, body, "entries: the body is kept")
        let n = Harness(body)
        Check.equal(n.tv.string, body, "entries: a normal note shows the marker as text")
        for mode in [NoteMode.plain, .code] {
            Check.equal(Harness(body, mode: mode, scratch: true).tv.string, "\(obj)\ncall Sam\n\(obj)\nping Raj",
                        "entries: \(mode.rawValue) Scratch notes have entries too")
        }
    }

    static func caret() {
        // 0: marker, 1: \n, 2...9 "call Sam", 10: \n, 11: marker, 12: \n, 13... "ping Raj"
        let h = Harness("--- 09:14 ---\ncall Sam\n--- 09:20 ---\nping Raj", scratch: true)
        h.focus(at: 13)
        Check.equal(h.tv.selectedRange().location, 13, "entries: the start of an entry's text holds the caret")
        h.tv.moveLeft(nil)
        Check.equal(h.tv.selectedRange().location, 10, "entries: left from an entry goes to the end of the text above")
        h.tv.moveRight(nil)
        Check.equal(h.tv.selectedRange().location, 13, "entries: right from the text above goes into the entry")
        h.tv.setSelectedRange(NSRange(location: 11, length: 0))
        Check.expect(h.tv.selectedRange().location != 11 && h.tv.selectedRange().location != 12,
                     "entries: the caret is never on a marker line (\(h.tv.selectedRange().location))")
        h.tv.setSelectedRange(NSRange(location: 2, length: 0))
        h.tv.moveLeft(nil)
        Check.equal(h.tv.selectedRange().location, 2, "entries: nothing above the first marker, the caret stays")
        h.tv.setSelectedRange(NSRange(location: 4, length: 12))
        Check.equal(h.tv.selectedRange(), NSRange(location: 4, length: 12), "entries: a selection can span a marker")
    }

    static func editing() {
        // Backspace at the start of an entry joins it with the one above.
        let h = Harness("--- 09:14 ---\ncall Sam\n--- 09:20 ---\nping Raj", scratch: true)
        h.focus(at: 13)
        h.tv.deleteBackward(nil)
        BehaviorChecks.spin()
        Check.equal(h.body, "--- 09:14 ---\ncall Sam\nping Raj", "entries: Backspace at the start of an entry removes its marker")
        Check.equal(h.tv.selectedRange().location, 11, "entries: the caret stays before the joined text")
        Check.equal(h.bodies.last, "--- 09:14 ---\ncall Sam\nping Raj", "entries: the join is reported")

        // Typing never lands next to a marker.
        let t = Harness("--- 09:14 ---\ncall Sam\n--- 09:20 ---\nping Raj", scratch: true)
        t.focus(at: 10)
        t.type("!")
        t.tv.moveRight(nil)
        t.type("> ")
        Check.equal(t.body, "--- 09:14 ---\ncall Sam!\n--- 09:20 ---\n> ping Raj", "entries: typing around a marker keeps it")

        // Deleting every line of an entry removes its marker too.
        let d = Harness("--- 09:14 ---\ncall Sam\n--- 09:20 ---\nping Raj", scratch: true)
        d.focus()
        d.tv.setSelectedRange(NSRange(location: 2, length: 9))
        d.tv.deleteBackward(nil)
        BehaviorChecks.spin()
        Check.equal(d.body, "--- 09:20 ---\nping Raj", "entries: an entry without lines goes away")

        // A marker line that is typed or pasted becomes a marker.
        let p = Harness("a\n", scratch: true)
        p.focus()
        p.type("--- 10:00 ---\nb")
        Check.equal(p.tv.string, "a\n\(obj)\nb", "entries: a typed marker line becomes a marker")
        Check.equal(p.body, "a\n--- 10:00 ---\nb", "entries: typed marker body")

        // Done / delete are text edits with undo.
        let e = Harness("lead\n--- 09:14 ---\ncall Sam\n--- 09:20 ---\nping Raj", scratch: true)
        e.focus()
        e.editor.setEntryDone(true, entry: 1)
        Check.equal(e.body, "lead\n--- 09:14 x ---\ncall Sam\n--- 09:20 ---\nping Raj", "entries: mark done")
        Check.equal(e.bodies.last, e.body, "entries: mark done is reported")
        BehaviorChecks.spin()
        e.editor.deleteEntry(2)
        Check.equal(e.body, "lead\n--- 09:14 x ---\ncall Sam\n", "entries: delete entry")
        BehaviorChecks.spin()
        e.editor.undoManagerForTesting.undo()
        BehaviorChecks.spin()
        Check.equal(e.body, "lead\n--- 09:14 x ---\ncall Sam\n--- 09:20 ---\nping Raj", "entries: undo delete entry")
    }

    static func newEntry() {
        var cal = Calendar.current
        cal.timeZone = .current
        let at = cal.date(from: DateComponents(year: 2026, month: 5, day: 11, hour: 14, minute: 32))!

        let h = Harness("call Sam", scratch: true)
        h.focus()
        h.editor.beginEntry(at: at)
        Check.equal(h.body, "call Sam\n--- 14:32 ---\n", "entries: a new entry at the end")
        Check.equal(h.tv.selectedRange().location, h.tv.string.utf16.count, "entries: the caret is in the new entry")
        Check.equal(h.bodies.count, 0, "entries: an entry nothing was typed in is not reported")
        Check.equal(h.env.store.note(id: h.note.id)?.body, "call Sam", "entries: the store keeps its body")
        // The host re-applies its body (a store notification): the new entry stays.
        h.editor.apply(note: h.env.store.note(id: h.note.id)!)
        Check.equal(h.body, "call Sam\n--- 14:32 ---\n", "entries: the host's body does not remove the new entry")
        h.type("idea")
        Check.equal(h.bodies.last, "call Sam\n--- 14:32 ---\nidea", "entries: the first text typed reports the entry")

        // Left empty: gone with the focus, and the store never hears of it.
        let p = Harness("call Sam", scratch: true)
        p.focus()
        p.editor.beginEntry(at: at)
        p.window.makeFirstResponder(nil)
        BehaviorChecks.spin(0.05)
        Check.equal(p.body, "call Sam", "entries: an empty entry goes away when the focus leaves")
        Check.equal(p.bodies.count, 0, "entries: nothing reported for an entry left empty")

        // Opened again before anything was typed: one entry, with the new time.
        let r = Harness("call Sam\n", scratch: true)
        r.focus()
        r.editor.beginEntry(at: at)
        r.editor.beginEntry(at: at.addingTimeInterval(600))
        Check.equal(r.body, "call Sam\n--- 14:42 ---\n", "entries: an empty entry is replaced, not stacked")

        // Backspace in the empty new entry cancels it.
        let b = Harness("call Sam", scratch: true)
        b.focus()
        b.editor.beginEntry(at: at)
        b.tv.deleteBackward(nil)
        BehaviorChecks.spin()
        Check.equal(b.body, "call Sam\n", "entries: Backspace in an empty new entry removes its marker")

        // An empty note that gets the focus starts its first entry.
        let e = Harness("", scratch: true)
        e.focus()
        BehaviorChecks.spin(0.05)
        Check.equal(ScratchEntries.markers(in: e.body).count, 1, "entries: focus in an empty note starts the first entry")
        e.type("first")
        Check.expect(e.bodies.last?.hasSuffix("---\nfirst") == true, "entries: the first text is in the first entry")

        // A read-only note (an earlier day) gets none.
        let ro = Harness("call Sam", scratch: true)
        ro.editor.isReadOnly = true
        ro.editor.beginEntry(at: at)
        Check.equal(ro.body, "call Sam", "entries: no new entry in a read-only note")
        // Nor does a normal note.
        let n = Harness("call Sam")
        n.focus()
        n.editor.beginEntry(at: at)
        Check.equal(n.body, "call Sam", "entries: no new entry in a normal note")
    }

    static func styling() {
        // Times: 09:14 shown, 09:20 not (6 minutes), 11:02 shown.
        let body = "lead\n--- 09:14 ---\none\n--- 09:20 x ---\ntwo\n--- 11:02 ---\nthree\n--- 11:05 ---\nfour\n--- 11:06 ---\nfive"
        let h = Harness(body, scratch: true)
        Check.equal(h.editor.entryTimesShownForTesting, [true, false, true, false, false], "entries: sparse times in the editor")
        // Lines: lead, marker, one, marker, two, marker, three, marker, four, marker, five.
        let a = h.editor.lineAlphasForTesting
        Check.equal(a.last, 1, "entries: the newest entry shows in full")
        Check.expect(a[8] < 1 && a[6] < a[8] && a[2] <= a[6] && a[0] <= a[2], "entries: older entries fade (\(a))")
        Check.expect(a[0] >= 0.55, "entries: the oldest entry stays readable (\(a[0]))")
        let s = h.tv.string as NSString
        let two = s.range(of: "two").location
        Check.expect(h.tv.textStorage?.attribute(.strikethroughStyle, at: two, effectiveRange: nil) != nil,
                     "entries: a done entry is struck through")
        Check.expect(h.tv.textStorage?.attribute(.strikethroughStyle, at: s.range(of: "three").location, effectiveRange: nil) == nil,
                     "entries: the entry after a done one is not")

        // The entry with the caret shows in full, and so does the newest one.
        h.focus(at: s.range(of: "one").location)
        BehaviorChecks.spin(0.05)
        let f = h.editor.lineAlphasForTesting
        Check.equal(f[2], 1, "entries: the entry with the caret shows in full")
        Check.equal(f.last, 1, "entries: the newest entry still shows in full")
        Check.expect(f[6] < 1, "entries: the others stay faded")

        // A read-only note (an earlier day) does not fade.
        let ro = Harness(body, scratch: true)
        ro.editor.isReadOnly = true
        Check.expect(ro.editor.lineAlphasForTesting.enumerated().allSatisfy { $0.offset == 4 || $0.element == 1 },
                     "entries: no fade in a read-only note (\(ro.editor.lineAlphasForTesting))")

        // The marker line is lower than a text line.
        let m = h.editor.lineRectForTesting(at: s.range(of: obj).location)
        let t = h.editor.lineRectForTesting(at: two)
        Check.expect(m.height > 8 && m.height <= t.height + 8, "entries: marker line height \(m.height) vs text \(t.height)")
    }

    static func menu() {
        let h = Harness("lead\n--- 09:14 ---\ncall Sam\n--- 09:20 x ---\nping Raj", scratch: true)
        var got: [String] = []
        h.editor.entryMenuItems = { text in
            got.append(text)
            return [NSMenuItem(title: "Save Entry as Note", action: nil, keyEquivalent: "")]
        }
        h.editor.frame.size.height = h.editor.intrinsicContentSize.height
        h.editor.layoutSubtreeIfNeeded()
        let s = h.tv.string as NSString
        Check.equal(h.editor.entryMenuTitlesForTesting(atStorage: s.range(of: "call").location),
                    ["Save Entry as Note", "Copy Entry", "Mark Entry Done", "Delete Entry"], "entries: menu of an entry")
        Check.equal(got.last, "call Sam", "entries: the host gets the entry's text")
        Check.equal(h.editor.entryMenuTitlesForTesting(atStorage: s.range(of: "ping").location),
                    ["Save Entry as Note", "Copy Entry", "Mark Entry Not Done", "Delete Entry"], "entries: menu of a done entry")
        Check.equal(h.editor.entryMenuTitlesForTesting(atStorage: 0), ["Save Entry as Note", "Copy Entry", "Delete Entry"],
                    "entries: the text before the first marker cannot be marked done")
        h.editor.isReadOnly = true
        Check.equal(h.editor.entryMenuTitlesForTesting(atStorage: s.range(of: "call").location),
                    ["Save Entry as Note", "Copy Entry"], "entries: a read-only note only copies")
        Check.equal(Harness("--- 09:14 ---\ncall Sam").editor.entryMenuTitlesForTesting(atStorage: 16), [],
                    "entries: no entry menu in a normal note")
    }

    /// Offscreen PNGs of a Scratch note: not focused, and with the caret in a new entry.
    static func snapshots(outputDirectory dir: URL) {
        let body = """
        --- 09:14 ---
        call Sam re: budget
        - wants Q3 numbers by Friday
        --- 09:20 x ---
        ping Raj about the CR
        --- 11:02 ---
        idea: tabs on the outer edge of the panel, one per folder
        --- 11:09 ---
        - [ ] book the room
        - [x] send the agenda
        --- 14:32 ---
        retro notes: the merge window feels right at two minutes
        """
        for (name, appearance) in [("light", NSAppearance(named: .aqua)!), ("dark", NSAppearance(named: .darkAqua)!)] {
            let env = BehaviorChecks.makeEnv(hideMarkup: true)
            let n = env.store.createScratchNote(day: "2026-05-11", mode: .standard)
            env.store.updateNoteBody(id: n.id, body: body)
            guard let note = env.store.note(id: n.id) else { continue }
            Snapshots.render(note: note, env: env, appearance: appearance, caret: nil,
                             to: dir.appendingPathComponent("scratch-entries-\(name).png"))
            Snapshots.render(note: note, env: env, appearance: appearance, caret: 30,
                             to: dir.appendingPathComponent("scratch-entries-editing-\(name).png"))
        }
    }
}
