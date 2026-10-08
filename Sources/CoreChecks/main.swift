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

    let testDefaults = UserDefaults(suiteName: "local.dhguz.NoteBar.testSettings")!
    testDefaults.removePersistentDomain(forName: "local.dhguz.NoteBar.testSettings")
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
