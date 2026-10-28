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

        foldChecks()
    }

    static func foldChecks() {
        // Tree helpers.
        let md = "T\n- [x] a\n\tx\n\t- b\n\t\ty\n- c\n\nplain"
        let lines = BlockScanner.scan(md as NSString)
        Check.equal(ListEditing.childLines(in: lines, of: 1), 2..<5, "children of an item")
        Check.equal(ListEditing.childLines(in: lines, of: 5), 6..<6, "no children")
        Check.equal((0..<lines.count).map { ListEditing.parentItem(in: lines, of: $0) }, [nil, nil, 1, 1, 3, nil, nil, nil], "parents")
        Check.equal((0..<lines.count).map { ListEditing.hasCheckedAncestor(in: lines, line: $0) },
                    [false, false, true, true, true, false, false, false], "under a checked item")

        typealias H = BehaviorChecks.Harness
        let h = H("List\n- [ ] a\n\tnote\n- [ ] b")
        h.editor.frame.size.height = h.editor.intrinsicContentSize.height
        h.editor.layoutSubtreeIfNeeded()
        Check.equal(h.editor.foldChevronsForTesting.map(\.collapsed), [false], "one open chevron (only items with children)")
        if let f = h.editor.foldChevronsForTesting.first?.frame {
            let lm = h.tv.layoutManager!
            let a = (h.tv.string as NSString).range(of: "a").location
            let ga = lm.boundingRect(forGlyphRange: NSRange(location: lm.glyphIndexForCharacter(at: a), length: 1), in: h.tv.textContainer!)
            Check.expect(f.minX >= ga.minX + 1 && f.midY > ga.minY && f.midY < ga.maxY, "chevron sits after the item text (\(f) vs \(ga))")
            Check.expect(h.editor.isFoldControlForTesting(at: NSPoint(x: f.midX, y: f.midY)), "pointing hand on the chevron")
            Check.equal(h.editor.handCursorFramesForTesting.count, 3, "hand cursor areas: the chevron and both checkboxes")
            // A click just after the last letter puts the caret at the end of the line, not before the letter.
            let end = h.tv.characterIndexForInsertion(at: NSPoint(x: ga.maxX + 1, y: ga.midY))
            Check.equal(end, a + 1, "click after the last letter: caret at the end of the item")
            Check.expect(f.minX >= ga.maxX, "chevron is after the last letter")
            Check.expect(!h.editor.isFoldControlForTesting(at: NSPoint(x: ga.minX + 1, y: ga.midY)), "I-beam on the item text")
        }
        let open = h.editor.intrinsicContentSize.height
        h.editor.toggleFoldForTesting(0)
        BehaviorChecks.spin()
        Check.equal(h.env.store.note(id: h.note.id)?.foldOverrides, ["a"], "fold saved on the note")
        Check.equal(h.editor.foldChevronsForTesting.map(\.collapsed), [true], "chevron shows folded")
        let folded = h.editor.intrinsicContentSize.height
        Check.expect(folded < open - 5, "folded children take less space (\(open) -> \(folded))")
        let note = (h.tv.string as NSString).range(of: "note").location
        Check.expect(h.editor.glyphIsHiddenForTesting(at: note), "folded children are hidden")
        // The caret in the children shows them (not saved).
        h.focus(at: note + 2)
        Check.expect(!h.editor.glyphIsHiddenForTesting(at: note), "caret in folded children shows them")
        Check.equal(h.env.store.note(id: h.note.id)?.foldOverrides, ["a"], "still saved folded")
        h.editor.toggleFoldForTesting(0)
        BehaviorChecks.spin()
        Check.equal(h.env.store.note(id: h.note.id)?.foldOverrides, [], "unfold saved")

        // A long item wraps early enough for the chevron to fit, whatever its length.
        var misses: [Int] = []
        for n in 1...24 {
            let w = H("List\n- [ ] " + String(repeating: "wd ", count: n) + "x\n\tnote")
            w.editor.frame.size.height = w.editor.intrinsicContentSize.height
            w.editor.layoutSubtreeIfNeeded()
            guard let f = w.editor.foldChevronsForTesting.first?.frame, f.maxX <= w.tv.textContainer!.size.width + 0.5 else {
                misses.append(n); continue
            }
        }
        Check.equal(misses, [], "chevron fits in the line for every item length")

        // Checking an item folds its children and strikes them through; unfolding keeps the strike.
        let c = H("List\n- [ ] a\n\tnote\n- [ ] b")
        c.env.settings.sortCheckedItems = false
        c.editor.toggleCheckbox(at: 5)
        BehaviorChecks.spin()
        let cn = (c.tv.string as NSString).range(of: "note").location
        Check.expect(c.editor.glyphIsHiddenForTesting(at: cn), "checked item: children folded")
        Check.expect(c.tv.textStorage?.attribute(.strikethroughStyle, at: cn, effectiveRange: nil) != nil, "children of a checked item are struck")
        c.editor.toggleFoldForTesting(0)
        BehaviorChecks.spin()
        Check.expect(!c.editor.glyphIsHiddenForTesting(at: cn), "checked item: unfolded")
        Check.equal(c.env.store.note(id: c.note.id)?.foldOverrides, ["a"], "unfolded checked item is an override")
        // Unchecking drops the override: open items show their children.
        c.editor.toggleCheckbox(at: 5)
        BehaviorChecks.spin()
        Check.equal(c.env.store.note(id: c.note.id)?.foldOverrides, [], "toggling a checkbox resets the fold")
        Check.expect(!c.editor.glyphIsHiddenForTesting(at: cn), "unchecked item: children shown")
        Check.expect(c.tv.textStorage?.attribute(.strikethroughStyle, at: cn, effectiveRange: nil) == nil, "unchecked: no strike")
    }
}
