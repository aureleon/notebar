import AppKit
import NoteBarCore
import NoteBarEditor

/// Sub-lines: indented text under a list item (Shift-Enter), flush with the item's text.
@MainActor
enum SubLineChecks {
    static func sel(_ l: Int) -> NSRange { NSRange(location: l, length: 0) }

    static func expect(_ r: TextEditResult?, _ text: String?, _ caret: Int?, _ msg: String) {
        Check.equal(r?.text, text, msg)
        if let caret { Check.equal(r?.selection.location, caret, msg + " (caret)") }
    }

    static func run() {
        // Owner.
        let lines = BlockScanner.scan("T\n- [ ] a\n\tx\n\t- b\n\t\ty\n\tz\n\t\nplain\n\tq" as NSString)
        Check.equal((0..<lines.count).map { ListEditing.subLineOwner(in: lines, line: $0) },
                    [nil, nil, 1, nil, 3, 1, 1, nil, nil], "sub-line owners")

        // Shift-Enter.
        expect(ListEditing.lineBreak(text: "T\n- [ ] a", selection: sel(9)), "T\n- [ ] a\n\t", 11, "shift-enter on an item starts a sub-line")
        expect(ListEditing.lineBreak(text: "T\n\t- b", selection: sel(6)), "T\n\t- b\n\t\t", 9, "nested item: one level deeper")
        expect(ListEditing.lineBreak(text: "T\n- [ ] a\n\tx", selection: sel(12)), "T\n- [ ] a\n\tx\n\t", 14, "shift-enter on a sub-line")
        expect(ListEditing.lineBreak(text: "T\nplain", selection: sel(7)), nil, nil, "shift-enter on text: default")
        expect(ListEditing.lineBreak(text: "- [ ] title", selection: sel(11)), nil, nil, "shift-enter on the title: default")

        // Enter on a sub-line: another one; on an empty one: the next item.
        expect(ListEditing.newline(text: "T\n- [ ] a\n\tx", selection: sel(12)), "T\n- [ ] a\n\tx\n\t", 14, "enter on a sub-line keeps the indent")
        expect(ListEditing.newline(text: "T\n- [ ] a\n\tx\n\t", selection: sel(14)), "T\n- [ ] a\n\tx\n- [ ] ", 19, "enter on an empty sub-line: next checkbox")
        expect(ListEditing.newline(text: "T\n2. a\n\t", selection: sel(8)), "T\n2. a\n3. ", 10, "numbered owner: next number")
        expect(ListEditing.newline(text: "T\n\t- b\n\t\t", selection: sel(9)), "T\n\t- b\n\t- ", 10, "nested owner keeps its level")
        expect(ListEditing.newline(text: "T\n\tq", selection: sel(4)), nil, nil, "indented text without an item: default")

        // Backspace at the text start joins the line above.
        expect(ListEditing.joinSubLine(text: "T\n- [ ] a\n\tx", selection: sel(11)), "T\n- [ ] ax", 9, "backspace joins a sub-line")
        expect(ListEditing.joinSubLine(text: "T\n- [ ] a\n\tx", selection: sel(12)), nil, nil, "backspace inside the text: default")

        // The sub-line stays with its item when checked items sort.
        let h = BehaviorChecks.Harness("List\n- [ ] a\n- [ ] b")
        h.focus(at: 7)   // "List\n" + box + "a" | end of item a
        h.editor.doCommandForTesting(#selector(NSResponder.insertLineBreak(_:)))
        h.type("note")
        Check.equal(h.body, "List\n- [ ] a\n\tnote\n- [ ] b", "typed sub-line")
        h.editor.toggleCheckbox(at: 5)
        Check.equal(h.body, "List\n- [ ] b\n- [x] a\n\tnote", "sub-line moves with its item")

        // Rendering: the indent is hidden and the text is flush with the item's text.
        let r = BehaviorChecks.Harness("List\n- [ ] item\n\tnote")
        let s = r.tv.string as NSString
        let tab = s.range(of: "\t").location
        Check.expect(r.editor.glyphIsHiddenForTesting(at: tab), "sub-line indent is hidden")
        func x(_ i: Int) -> CGFloat {
            let lm = r.tv.layoutManager!
            lm.ensureLayout(for: r.tv.textContainer!)
            return lm.location(forGlyphAt: lm.glyphIndexForCharacter(at: i)).x
        }
        Check.equal(x(tab + 1), x(s.range(of: "item").location), "sub-line text is flush with the item text")
        // The caret does not rest in the hidden indent.
        r.focus(at: tab)
        Check.equal(r.tv.selectedRange().location, tab + 1, "caret snaps past the hidden indent")
        r.tv.moveLeft(nil)
        Check.equal(r.tv.selectedRange().location, tab - 1, "left arrow from the text start goes to the line above")
    }
}
