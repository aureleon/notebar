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
    Check.equal(s.search("TWO", in: nil).map(\.id), [n2.id], "search")
    Check.equal(KeyCombo(keyCode: 0x2D, carbonModifiers: KeyCombo.cmd | KeyCombo.option).displayString, "⌥⌘N")
}
Check.finish()
