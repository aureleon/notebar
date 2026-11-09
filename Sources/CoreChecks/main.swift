import Foundation
import NoteBarCore

MainActor.assumeIsolated {
    Check.equal(NoteText.title(of: "\n# **Hello** world\nbody"), "Hello world", "title")
    Check.equal(NoteText.title(of: "- [ ] task"), "task", "checklist title")
    Check.equal(NoteText.linesAfterTitle(in: "a\nb\nc\n\n"), 2, "lines after title")
    let a = Attachment(id: 7, noteId: 1, kind: .image, relativePath: "x.png", displayName: "x.png")
    let md = AttachmentLink.markdown(for: a)
    Check.equal(md, "![x.png](attachment:7)")
    Check.equal(AttachmentLink.attachmentIDs(in: "hi \(md) and [f](attachment:9)"), [7, 9])
    Check.expect(SortIndex.between(1, 2) == 1.5, "between")

    let s = InMemoryNoteStore()
    let f = s.folders()[0]
    let n1 = s.createNote(in: f.id, body: "one")
    let n2 = s.createNote(in: f.id, body: "two")
    Check.equal(s.notes(in: f.id).map(\.id), [n2.id, n1.id], "new notes go on top")
    s.moveNote(id: n2.id, toIndex: 1)
    Check.equal(s.notes(in: f.id).map(\.id), [n1.id, n2.id], "reorder")
    let n3 = s.createNote(in: f.id, body: "three")
    var p = s.note(id: n2.id)!; p.isPinned = true; s.updateNote(p)
    Check.equal(s.notes(in: f.id).map(\.id), [n2.id, n3.id, n1.id], "pinned first")
    s.moveNote(id: n1.id, toIndex: 0)
    Check.equal(s.notes(in: f.id).map(\.id), [n2.id, n1.id, n3.id], "reorder stays below pinned")
    s.moveNote(id: n2.id, toIndex: 2)
    Check.equal(s.notes(in: f.id).first?.id, n2.id, "pinned stays in pinned zone")
    let f2 = s.createFolder(name: "B")
    var pf = f; pf.isPinned = true; s.updateFolder(pf)
    s.moveFolder(id: f2.id, toIndex: 0)
    Check.equal(s.folders().map(\.id), [f.id, f2.id], "folder reorder stays below pinned")
    Check.equal(s.search("TWO", in: nil).map(\.id), [n2.id], "search")
    Check.equal(KeyCombo(keyCode: 0x2D, carbonModifiers: KeyCombo.cmd | KeyCombo.option).displayString, "⌥⌘N")
    Check.equal(HotkeyAction.defaults[.toggleFloatPanel]?.displayString, "⌥⇧⌘N", "float panel default hotkey")
    Check.equal(HotkeyAction.defaults[.toggleFloatPanel]?.menuKeyEquivalent, "n", "menu key equivalent")
    Check.expect(HotkeyAction.defaults[.toggleFloatPanel]?.modifierFlags == [.command, .option, .shift], "menu modifiers")
    Check.equal(HotkeyAction.toggleFloatPanel.displayName, "Float / Stay Open", "display name")

    let testDefaults = UserDefaults(suiteName: "local.dhguz.NoteBar.testSettings")!
    testDefaults.removePersistentDomain(forName: "local.dhguz.NoteBar.testSettings")

    // Keep deleted items: default, persistence, purge times.
    do {
        let d = UserDefaults(suiteName: "local.dhguz.NoteBar.trashSettings")!
        d.removePersistentDomain(forName: "local.dhguz.NoteBar.trashSettings")
        let st = AppSettings(defaults: d)
        Check.equal(st.deletedItemsRetention, .oneHour, "Keep deleted items defaults to 1 hour")
        Check.equal(st.deletedItemsRetentionChangedAt, nil, "no change date by default")
        st.deletedItemsRetention = .recentlyDeleted
        let reread = AppSettings(defaults: d)
        Check.equal(reread.deletedItemsRetention, .recentlyDeleted, "retention persisted")
        Check.expect(reread.deletedItemsRetentionChangedAt != nil, "change date persisted")
        d.removePersistentDomain(forName: "local.dhguz.NoteBar.trashSettings")

        let now = Date(timeIntervalSince1970: 1_000_000)
        let hour = TrashPurger.cutoff(.oneHour, moment: .periodic, now: now, policyChangedAt: nil)
        Check.equal(hour, now.addingTimeInterval(-3600), "1 hour: items older than an hour go")
        Check.equal(TrashPurger.cutoff(.recentlyDeleted, moment: .launch, now: now, policyChangedAt: nil),
                    now.addingTimeInterval(-30 * 86_400), "Recently Deleted: 30 days")
        Check.equal(TrashPurger.cutoff(.untilQuit, moment: .periodic, now: now, policyChangedAt: nil), nil,
                    "until quit: nothing while running")
        Check.equal(TrashPurger.cutoff(.untilQuit, moment: .quit, now: now, policyChangedAt: nil), now, "until quit: all at quit")
        Check.equal(TrashPurger.cutoff(.untilQuit, moment: .launch, now: now, policyChangedAt: nil), now, "until quit: all at launch")
        Check.equal(TrashPurger.cutoff(.oneHour, moment: .periodic, now: now, policyChangedAt: now.addingTimeInterval(-60)), nil,
                    "a recent change deletes nothing at once")
        Check.equal(TrashPurger.cutoff(.oneHour, moment: .periodic, now: now, policyChangedAt: now.addingTimeInterval(-7200)),
                    now.addingTimeInterval(-3600), "an hour after the change the new time applies")

        // Purger on a real store.
        let ps = InMemoryNoteStore()
        let pn = ps.createNote(in: ps.folders()[0].id, body: "old")
        ps.trashNote(id: pn.id)
        let pd = UserDefaults(suiteName: "local.dhguz.NoteBar.trashPurger")!
        pd.removePersistentDomain(forName: "local.dhguz.NoteBar.trashPurger")
        let pset = AppSettings(defaults: pd)
        let purger = TrashPurger(store: ps, settings: pset)
        purger.purge(.periodic, now: Date())
        Check.equal(ps.trashedNotes().count, 1, "a fresh delete stays in the trash")
        purger.purge(.periodic, now: Date().addingTimeInterval(3601))
        Check.equal(ps.trashedNotes().count, 0, "purged after an hour")
        pd.removePersistentDomain(forName: "local.dhguz.NoteBar.trashPurger")
    }
    scratchEntryChecks()
    let testSettings = AppSettings(defaults: testDefaults)
    Check.expect(!testSettings.hotSideEnabled, "hot side is opt-in (disabled by default)")
    Check.equal(testSettings.hotSideArea, .edge, "default area is edge")
    testSettings.hotSideArea = .corner
    Check.equal(testSettings.hotSideArea, .corner, "corner area persists")
    testSettings.hotSideArea = .quadrant
    Check.equal(testSettings.hotSideArea, .quadrant, "quadrant area persists")
    testSettings.hotSideArea = .dynamic
    Check.equal(testSettings.hotSideArea, .dynamic, "dynamic area persists")
    testDefaults.removePersistentDomain(forName: "local.dhguz.NoteBar.testSettings")
}
Check.finish()

/// `ScratchEntries`: marker lines, entries, times, edits and the export for a normal note.
@MainActor func scratchEntryChecks() {
    typealias E = ScratchEntries
    Check.equal(E.Marker(minutes: 14 * 60 + 32).line, "--- 14:32 ---", "entries: marker line")
    Check.equal(E.Marker(minutes: 5, isDone: true).line, "--- 00:05 x ---", "entries: done marker line")
    Check.equal(E.Marker(line: "--- 09:14 ---"), E.Marker(minutes: 554), "entries: parse")
    Check.equal(E.Marker(line: "--- 09:14 x ---"), E.Marker(minutes: 554, isDone: true), "entries: parse done")
    for bad in ["---", "--- 9:14 ---", "--- 24:00 ---", "--- 09:60 ---", "--- 09:14 ---  ", " --- 09:14 ---", "--- 09:14 y ---",
                "--- 09:14 --", "--- ab:cd ---", "---- 09:14 ---"] {
        Check.equal(E.Marker(line: bad), nil, "entries: \(bad.debugDescription) is not a marker")
    }

    let body = "old text\n--- 09:14 ---\ncall Sam\n- Q3 numbers\n--- 09:20 x ---\nping Raj\n--- 11:02 ---\nidea\n"
    let all = E.entries(in: body)
    Check.equal(all.map { $0.marker?.minutes }, [nil, 554, 560, 662], "entries: text before the first marker is an entry")
    Check.equal(all.map { $0.marker?.isDone ?? false }, [false, false, true, false], "entries: done state")
    Check.equal(E.text(ofEntry: 1, in: body), "call Sam\n- Q3 numbers", "entries: text of an entry")
    Check.equal(E.text(ofEntry: 0, in: body), "old text", "entries: text before the first marker")
    Check.equal(E.entries(in: "\n--- 09:14 ---\na").count, 1, "entries: blank text before the first marker is no entry")
    Check.equal(E.entries(in: "").count, 0, "entries: none in an empty body")
    Check.equal(E.markers(in: "```\n--- 09:14 ---\n```\n--- 10:00 ---\nx").map(\.marker.minutes), [600],
                "entries: a marker in fenced code is text")
    Check.equal(E.markers(in: "a --- 09:14 ---\n--- 09:14 --- b").count, 0, "entries: a marker is a whole line")
    Check.equal(E.markers(in: "a\r\n--- 09:14 ---\r\nb").map(\.fullRange), [NSRange(location: 3, length: 15)],
                "entries: CRLF line ends")

    Check.expect(E.isBlank(""), "entries: empty is blank")
    Check.expect(E.isBlank("\n--- 09:14 ---\n  \n--- 10:00 ---"), "entries: only markers is blank")
    Check.expect(!E.isBlank("--- 09:14 ---\nx"), "entries: text is not blank")

    // Times shown: the first, then each one 30 minutes or more after the last shown one.
    func shown(_ minutes: [Int]) -> [Bool] { E.showsTime(minutes.map { E.Marker(minutes: $0) }) }
    Check.equal(shown([540, 545, 569, 570, 575, 600]), [true, false, false, true, false, true], "entries: sparse times")
    Check.equal(shown([540, 565, 590]), [true, false, true], "entries: the gap counts from the last shown time")
    Check.equal(shown([1430, 5, 20, 40]), [true, false, true, false], "entries: after midnight is later, not earlier")
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(identifier: "Europe/Lisbon")!
    let date = cal.date(from: DateComponents(year: 2026, month: 5, day: 11, hour: 14, minute: 32, second: 50))!
    Check.equal(E.minutes(of: date, calendar: cal), 872, "entries: minutes of a date")
    Check.equal(E.timeText(minutes: 872, locale: Locale(identifier: "en_GB")), "14:32", "entries: time text, 24 h")
    Check.expect(E.timeText(minutes: 872, locale: Locale(identifier: "en_US")).hasPrefix("2:32"), "entries: time text, 12 h")

    // A new entry at the end.
    Check.equal(E.beginningEntry(in: "", minutes: 554), "--- 09:14 ---\n", "entries: first entry")
    Check.equal(E.beginningEntry(in: "a", minutes: 554), "a\n--- 09:14 ---\n", "entries: new entry after text")
    Check.equal(E.beginningEntry(in: "a\n", minutes: 554), "a\n--- 09:14 ---\n", "entries: no extra blank line")
    Check.equal(E.beginningEntry(in: "a\n--- 09:00 ---\n\n", minutes: 554), "a\n--- 09:14 ---\n",
                "entries: an empty entry at the end gets the new time")
    Check.equal(E.pruningEmptyTail("a\n--- 09:00 ---\n--- 09:05 ---\n "), "a\n", "entries: empty entries at the end go")
    Check.equal(E.pruningEmptyTail("--- 09:00 ---\nx"), "--- 09:00 ---\nx", "entries: an entry with text stays")

    // Entry edits.
    Check.equal(E.removingEntry(2, from: body), "old text\n--- 09:14 ---\ncall Sam\n- Q3 numbers\n--- 11:02 ---\nidea\n",
                "entries: remove an entry")
    Check.equal(E.removingEntry(0, from: body), String(body.dropFirst(9)), "entries: remove the text before the first marker")
    Check.equal(E.removingEntry(9, from: body), body, "entries: remove out of range does nothing")
    let done = E.settingDone(true, entry: 1, in: body)
    Check.equal(E.entries(in: done).map { $0.marker?.isDone ?? false }, [false, true, true, false], "entries: mark done")
    Check.equal(E.settingDone(false, entry: 1, in: done), body, "entries: mark not done restores the body")
    Check.equal(E.settingDone(true, entry: 0, in: body), body, "entries: text without a marker cannot be done")
    Check.equal(E.settingDone(true, entry: 0, in: "--- 09:14 ---"), "--- 09:14 x ---", "entries: mark done, no line end")

    // Leaving Scratch: rules and times, no markers.
    let gb = Locale(identifier: "en_GB")
    Check.equal(E.exported(body, locale: gb),
                "old text\n---\n*09:14*\ncall Sam\n- Q3 numbers\n---\nping Raj\n---\n*11:02*\nidea\n", "entries: export")
    Check.equal(E.exported("--- 09:14 ---\nfirst\n--- 09:20 ---\nsecond", locale: gb), "*09:14*\nfirst\n---\nsecond",
                "entries: export, a marker at the start has no rule")
    Check.equal(E.exported("--- 09:14 ---\nfirst\n--- 09:20 ---\nsecond", leadingTime: false, locale: gb), "first\n---\nsecond",
                "entries: export without the leading time keeps the first line first")
    Check.equal(E.exported("plain\ntext"), "plain\ntext", "entries: export of a body without markers")
    Check.equal(E.markers(in: E.exported(body)).count, 0, "entries: nothing left to parse after export")
}
