import AppKit
import NoteBarCore
import NoteBarEditor

/// Checked items move below the open ones; the "N completed" row folds them.
@MainActor
enum ChecklistChecks {
    static func sort(_ md: String, at line: Int) -> String? {
        let ns = md as NSString
        let lines = BlockScanner.scan(ns)
        return ChecklistSort.sorted(md, itemAt: lines[line].range.location)?.text
    }

    static func run() {
        // Blocks.
        let md = "Title\n- [x] a\n- [ ] b\n\t- child\n- [x] c\n\n- [ ] d\n- [x] e"
        let lines = BlockScanner.scan(md as NSString)
        let blocks = ChecklistSort.blocks(in: lines)
        Check.equal(blocks.count, 2, "two blocks (blank line splits)")
        Check.equal(blocks.first?.items, [1..<2, 2..<4, 4..<5], "child stays with its item")
        Check.equal(blocks.first?.completedTail, 2..<3, "completed tail")
        Check.equal(blocks.last?.completedLines, 7..<8, "completed lines of the 2nd block")
        Check.equal(ChecklistSort.blocks(in: BlockScanner.scan("- [ ] title\n- [x] a" as NSString)).first?.items, [1..<2],
                    "the title is not an item")

        // Sorting.
        Check.equal(sort(md, at: 1), "Title\n- [ ] b\n\t- child\n- [x] a\n- [x] c\n\n- [ ] d\n- [x] e", "checked item moves down with order kept")
        Check.equal(sort(md, at: 6), nil, "sorted block: nothing to do")
        Check.equal(sort("L\n- [x] a\n- [ ] b", at: 1), "L\n- [ ] b\n- [x] a", "last line without terminator")
        Check.equal(sort("- [x] a\n- [ ] b", at: 0), nil, "the title line does not move")
        Check.equal(sort("L\n- [ ] a\n- [x] b\n- [ ] c\n", at: 2), "L\n- [ ] a\n- [ ] c\n- [x] b\n", "unchecked goes to the end of the open items")
        Check.equal(sort("L\n- [x] a\n- b\n- [ ] c", at: 1), nil, "a bullet at the same indent ends the block")
        Check.equal(sort("L\n- [ ] p\n\t- [x] a\n\t- [ ] b\n- [ ] q", at: 2), "L\n- [ ] p\n\t- [ ] b\n\t- [x] a\n- [ ] q", "nested level sorts on its own")
        Check.equal(sort("L\n- [x] a\n- [ ] b\n\t- sub\n\t\tT-1\n    T-2\n- [ ] c", at: 1),
                    "L\n- [ ] b\n\t- sub\n\t\tT-1\n    T-2\n- [ ] c\n- [x] a", "indented text lines stay with their item")
        Check.equal(sort("L\n- [x] a\nplain\n- [ ] b", at: 1), nil, "unindented text ends the block")
        Check.equal(sort("L\r\n- [x] a\r\n- [ ] b\r\n", at: 1), "L\r\n- [ ] b\r\n- [x] a\r\n", "CRLF")

        // Offset map follows the moved text.
        let src = "L\n- [x] a\n- [ ] bb"
        if let r = ChecklistSort.sorted(src, itemAt: 2) {
            let ns = src as NSString, out = r.text as NSString
            for o in [2, 8, 10, 15, 18] where o < ns.length {
                Check.equal(out.character(at: r.map(o)), ns.character(at: o), "map keeps character at \(o)")
            }
            Check.equal(r.map(0), 0, "map before block")
        } else {
            Check.expect(false, "sort for the map check")
        }

        editorChecks()
    }

    static func editorChecks() {
        typealias H = BehaviorChecks.Harness
        // Toggle moves the item; one undo restores both.
        let h = H("List\n- [ ] milk\n- [ ] eggs\n- [x] tea")
        h.editor.toggleCheckbox(at: 5)
        Check.equal(h.body, "List\n- [ ] eggs\n- [x] milk\n- [x] tea", "checked item moves below the open ones")
        Check.equal(h.env.store.note(id: h.note.id)?.body, h.body, "sorted body saved")
        BehaviorChecks.spin()
        h.editor.undoManagerForTesting.undo()
        BehaviorChecks.spin()
        Check.equal(h.body, "List\n- [ ] milk\n- [ ] eggs\n- [x] tea", "one undo: toggle + move")

        // Setting off: no move.
        let h2 = H("List\n- [ ] milk\n- [ ] eggs")
        h2.env.settings.sortCheckedItems = false
        h2.editor.toggleCheckbox(at: 5)
        Check.equal(h2.body, "List\n- [x] milk\n- [ ] eggs", "no move with the setting off")

        // Caret follows its text.
        let h3 = H("List\n- [ ] milk\n- [ ] eggs")
        h3.focus(at: 9)   // "mi|lk" → storage: "List\n" (5) + box (1) + "mil"
        h3.editor.toggleCheckbox(at: 5)
        let caret = h3.tv.selectedRange().location
        let s3 = h3.tv.string as NSString
        Check.equal(s3.substring(with: NSRange(location: caret - 3, length: 3)), "mil", "caret stays in the moved item")

        // Completed row: collapse hides the checked lines, the setting persists per note.
        let h4 = H("List\n- [ ] milk\n- [x] eggs\n- [x] tea")
        h4.editor.frame.size.height = h4.editor.intrinsicContentSize.height
        h4.editor.layoutSubtreeIfNeeded()
        Check.equal(h4.editor.completedRowsForTesting.map(\.count), [2], "one row: 2 completed")
        if let f = h4.editor.completedRowsForTesting.first?.frame {
            Check.expect(h4.editor.isFoldControlForTesting(at: NSPoint(x: f.minX + 4, y: f.midY)), "pointing hand on the completed row")
            Check.expect(!h4.editor.isFoldControlForTesting(at: NSPoint(x: f.maxX - 2, y: f.midY)), "I-beam past the row label")
        }
        let open = h4.editor.intrinsicContentSize.height
        h4.editor.toggleCompletedForTesting(row: 0)
        BehaviorChecks.spin()
        Check.equal(h4.env.store.note(id: h4.note.id)?.hidesCompletedItems, true, "collapsed state saved on the note")
        let folded = h4.editor.intrinsicContentSize.height
        Check.expect(folded < open - 20, "collapsed card is shorter (\(open) -> \(folded))")
        Check.equal(h4.editor.completedRowsForTesting.first?.collapsed, true, "row shows collapsed")
        // Caret in a hidden item shows the items again (not saved).
        h4.focus(at: h4.tv.string.utf16.count)
        Check.expect(h4.editor.intrinsicContentSize.height > folded + 20, "caret in the completed items shows them")
        Check.equal(h4.env.store.note(id: h4.note.id)?.hidesCompletedItems, true, "still saved collapsed")
        h4.editor.toggleCompletedForTesting(row: 0)
        BehaviorChecks.spin()
        Check.equal(h4.env.store.note(id: h4.note.id)?.hidesCompletedItems, false, "expand saved")

        // Backspace right after folded items shows them instead of joining a line to a hidden item.
        let h6 = H("List\n- [ ] a\n- [x] b\nafter")
        h6.editor.toggleCompletedForTesting(row: 0)
        let afterAt = (h6.tv.string as NSString).range(of: "after").location
        h6.focus(at: afterAt)
        let shut = h6.editor.intrinsicContentSize.height
        h6.editor.doCommandForTesting(#selector(NSResponder.deleteBackward(_:)))
        BehaviorChecks.spin()
        Check.equal(h6.body, "List\n- [ ] a\n- [x] b\nafter", "backspace after folded items keeps the text")
        Check.expect(h6.editor.intrinsicContentSize.height > shut, "backspace after folded items shows them")

        // No row with the setting off, or without checked items at the end.
        let h5 = H("List\n- [x] done\n- [ ] open")
        Check.equal(h5.editor.completedRowsForTesting.count, 0, "no row when checked items are not at the end")

        // Folded items at the end of the note: the height does not change when the style is rebuilt.
        let env = BehaviorChecks.makeEnv()
        var n = env.store.createNote(in: env.store.folders()[0].id, body: "G\n- [ ] Milk\n- [x] Eggs\n\nTrip\n- [ ] Hotel\n- [x] Flights",
                                     mode: .standard, position: .top)
        n.hidesCompletedItems = true
        env.store.updateNote(n)
        let e = MarkdownNoteEditor(note: env.store.note(id: n.id)!, env: env)
        e.frame = NSRect(x: 0, y: 0, width: 260, height: 20)
        let h0 = e.intrinsicContentSize.height
        e.appearance = NSAppearance(named: .darkAqua)
        e.appearance = NSAppearance(named: .aqua)
        Check.equal(e.intrinsicContentSize.height, h0, "folded height is stable across restyles")
        Check.equal(e.completedRowsForTesting.map(\.collapsed), [true, true], "both rows folded")
    }
}

