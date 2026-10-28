import AppKit
import NoteBarCore
import NoteBarEditor

/// GFM pipe tables: parsing (`TableSyntax`, `BlockScanner`) and the rendered grid in the editor.
@MainActor
enum TableChecks {
    static let sample = """
    CR Backlog
       ### Pending (waiting on review)

       | CR | Summary | Last touched |
       |---|---|---|
       | [CR-302351028](https://code.amazon.com/reviews/CR-302351028) | [NeuronUcode] [perf] Update PERF_TEST XT tracing to show src lines | 2026-10-21 |
       | [CR-313883834](https://code.amazon.com/reviews/CR-313883834) | [NeuronUcode] [DO NOT MERGE] [dge] Never pick a reshape whose spray steps overflow int32 | 2026-10-21 |

       ### To cancel

       - [ ] [CR-241351380](https://code.amazon.com/reviews/CR-241351380): build_env.sh shell prompt 'sourcing'
    """

    /// The CR backlog note from the feature request (indented by 3 spaces, as pasted).
    static let backlog = """
    CR Backlog
       ### Pending (waiting on review)

       | CR | Summary | Last touched |
       |---|---|---|
       | [CR-302351028](https://code.amazon.com/reviews/CR-302351028) | [NeuronUcode] [perf] Update PERF_TEST XT tracing to show src lines | 2026-10-21 |
       | [CR-313883834](https://code.amazon.com/reviews/CR-313883834) | [NeuronUcode] [DO NOT MERGE] [dge] Never pick a reshape whose spray steps overflow int32 | 2026-10-21 |
       | [CR-313519870](https://code.amazon.com/reviews/CR-313519870) | [NeuronUcode] Generate tieport stubs from src/test/gtest/tieport_stubs/ | 2026-10-21 |
       | [CR-313535547](https://code.amazon.com/reviews/CR-313535547) | [mav] Remove adisp_choose_all path, and remove hard-coded reset for code-fetch semaphore | 2026-10-20 |
       | [CR-313535448](https://code.amazon.com/reviews/CR-313535448) | [mav][dge] Bind only the code-fetch slot in SYNC, and remove semihosted fill logic from fallback | 2026-10-20 |
       | [CR-305232755](https://code.amazon.com/reviews/CR-305232755) | [NeuronUcode] [mav][dge] Reduce code fetch watcher overhead | 2026-09-15 |

       ### Open (unpublished / draft)

       | CR | Summary | Last touched |
       |---|---|---|
       | [CR-307515516](https://code.amazon.com/reviews/CR-307515516) | [NeuronUcode] [mav][dge] Avoid extract_AR state hazards | 2026-09-23 |
       | [CR-305238204](https://code.amazon.com/reviews/CR-305238204) | [MlaUcodeTeamUpdate] Add favicon to weekly update pages | 2026-09-15 |
       | [CR-300440335](https://code.amazon.com/reviews/CR-300440335) | [NeuronArchIsaSource] Add indirect DMA ISA check for src_elem_size != dst_elem_size | 2026-09-03 |
       | [CR-301948954](https://code.amazon.com/reviews/CR-301948954) | [NeuronUcode] [mav][dge] Improve dge_state.hpp helpers | 2026-09-02 |

       ### To cancel

       - [ ] [CR-241351380](https://code.amazon.com/reviews/CR-241351380): build_env.sh shell prompt 'sourcing' (couldn't get it working)
       - [ ] [CR-313535506](https://code.amazon.com/reviews/CR-313535506): older adisp_choose_all CR (replaced by CR-313535547)
       - [ ] [CR-309282061](https://code.amazon.com/reviews/CR-309282061): FIND_INDEX8 instrumentation (experiment, no longer needed)
    """

    static func run() {
        syntaxChecks()
        scannerChecks()
        editorChecks()
        cursorChecks()
    }

    /// Links in a grid get pointing-hand rects; a table that fits has no scroll bar area.
    static func cursorChecks() {
        let h = BehaviorChecks.Harness("T\n| a | b |\n|---|---|\n| [site](https://example.com) | y |\nafter", hideMarkup: true)
        let links = h.editor.tableLinkRectsForTesting
        Check.equal(links.count, 1, "one link rect in the grid")
        Check.expect(links.first.map { $0.width > 10 } == true, "link rect covers the link text")
        if let t = h.editor.renderedTablesForTesting.first?.frame {
            Check.expect(!h.editor.isTableScrollerForTesting(at: NSPoint(x: t.midX, y: t.maxY - 2)), "no scroll bar on a table that fits")
        }
    }

    static func editorChecks() {
        let body = "Sizes\n| Size | Price |\n|:--|--:|\n| **S** | [one](https://example.com) |\n| XL | \\| 2 |\nafter"
        let h = BehaviorChecks.Harness(body, hideMarkup: true)
        h.editor.frame.size.width = 360
        h.editor.layoutSubtreeIfNeeded()
        var tables = h.editor.renderedTablesForTesting
        Check.equal(tables.count, 1, "not focused: the table is drawn as a grid")
        Check.equal(tables.first?.cells ?? [], [["Size", "Price"], ["S", "one"], ["XL", "| 2"]], "grid cells: markers removed, escaped pipe shown")
        let collapsedHeight = h.editor.intrinsicContentSize.height
        Check.expect(collapsedHeight > 100, "the grid takes room (\(collapsedHeight))")

        // Caret into the table: raw rows, no grid.
        h.focus(at: 8)
        Check.equal(h.editor.renderedTablesForTesting.count, 0, "caret in the table: raw rows")
        Check.equal(h.body, body, "collapsing / expanding does not edit")
        // Caret out again: grid.
        h.tv.setSelectedRange(NSRange(location: 1, length: 0))
        BehaviorChecks.spin()
        Check.equal(h.editor.renderedTablesForTesting.count, 1, "caret out of the table: grid again")
        Check.expect(abs(h.editor.intrinsicContentSize.height - collapsedHeight) < 0.5, "same height after expand + collapse")

        // A click on a cell edits the table with the caret on that cell.
        h.editor.clickTableCellForTesting(table: 0, row: 2, column: 0)
        BehaviorChecks.spin()
        let s = h.tv.string as NSString
        Check.equal(h.tv.selectedRange().location, s.range(of: "XL").location, "click on a cell: caret on its text")
        Check.equal(h.editor.renderedTablesForTesting.count, 0, "click on a cell shows the raw rows")

        // Edit a cell, leave the table: the grid shows the new text.
        h.type("2")
        h.tv.setSelectedRange(NSRange(location: 0, length: 0))
        BehaviorChecks.spin()
        tables = h.editor.renderedTablesForTesting
        Check.equal(tables.first?.cells.last?.first, "2XL", "the grid follows edits")

        // Vim: j from the title enters the table.
        let v = BehaviorChecks.Harness(body, hideMarkup: true)
        v.env.settings.vimKeybinds = true
        v.editor.frame.size.width = 360
        v.focus(at: 0)
        Check.equal(v.editor.renderedTablesForTesting.count, 1, "vim: caret on the title, grid shown")
        v.editor.vimKeysForTesting("j")
        Check.equal(v.editor.renderedTablesForTesting.count, 0, "vim: j moves into the table")
        v.editor.vimKeysForTesting("G")
        Check.equal(v.editor.renderedTablesForTesting.count, 1, "vim: G leaves the table")

        // A wide table scrolls sideways; its grid fits the editor width.
        let wide = BehaviorChecks.Harness(backlog, hideMarkup: true)
        wide.editor.frame.size.width = 360
        wide.editor.layoutSubtreeIfNeeded()
        let wt = wide.editor.renderedTablesForTesting
        Check.equal(wt.count, 2, "backlog: two tables")
        Check.expect(wt.allSatisfy { $0.frame.width <= 360 && $0.documentWidth > $0.frame.width }, "backlog tables scroll sideways")
        Check.equal(wt.first?.cells.first ?? [], ["CR", "Summary", "Last touched"], "backlog header")
        Check.equal(wt.first?.cells[1].first, "CR-302351028", "link cell shows its text")

        // Code and Plain notes have no tables.
        for mode in [NoteMode.code, .plain] {
            let c = BehaviorChecks.Harness(body, mode: mode)
            c.editor.layoutSubtreeIfNeeded()
            Check.equal(c.editor.renderedTablesForTesting.count, 0, "\(mode) note: no table grid")
        }
    }

    static func cells(_ line: String) -> [String] {
        let s = line as NSString
        return TableSyntax.row(s, NSRange(location: 0, length: s.length)).cells.map { s.substring(with: $0) }
    }

    static func aligns(_ line: String) -> [TableAlignment]? {
        let s = line as NSString
        return TableSyntax.delimiterAlignments(s, NSRange(location: 0, length: s.length))
    }

    static func syntaxChecks() {
        Check.equal(cells("| a | b |"), ["a", "b"], "row with outer pipes")
        Check.equal(cells("a | b"), ["a", "b"], "row without outer pipes")
        Check.equal(cells("   |a|b|c|"), ["a", "b", "c"], "indented row, no spaces")
        Check.equal(cells("| a | |"), ["a", ""], "empty last cell")
        Check.equal(cells("| | b |"), ["", "b"], "empty first cell")
        Check.equal(cells("| a \\| b | c |"), ["a \\| b", "c"], "escaped pipe stays in the cell")
        Check.equal(cells("| [x](http://a.b) | **y** |"), ["[x](http://a.b)", "**y**"], "inline markup in cells")
        let r = TableSyntax.row("| a | b |" as NSString, NSRange(location: 0, length: 9))
        Check.equal(r.pipes, [0, 4, 8], "pipe positions")

        Check.equal(aligns("|---|---|"), [.none, .none], "delimiter row")
        Check.equal(aligns("| :-- | :-: | --: |"), [.left, .center, .right], "alignments")
        Check.equal(aligns("---|---"), [.none, .none], "delimiter without outer pipes")
        Check.expect(aligns("---") == nil, "a rule is not a delimiter row (no pipe)")
        Check.expect(aligns("| --- | x |") == nil, "text in a delimiter cell")
        Check.expect(aligns("| : |") == nil, "a colon alone is not a delimiter cell")
        Check.expect(aligns("    |---|") == nil, "4 spaces of indent: not a delimiter row")
    }

    static func kinds(_ body: String) -> [String] {
        BlockScanner.scan(body as NSString).map { l in
            l.kind == .table ? "t\(l.table).\(l.tableRow)" : l.kind == .paragraph ? (l.isTitle ? "title" : "p") : "\(l.kind)"
        }
    }

    static func scannerChecks() {
        Check.equal(kinds("T\n| a | b |\n|---|---|\n| 1 | 2 |\n| 3 | 4 |\nafter"),
                    ["title", "t0.0", "t0.1", "t0.2", "t0.3", "p"], "a body row needs a pipe; the table ends there")
        Check.equal(kinds("T\n| a | b |\n|---|---|\n\n| a |\n|-|\n| x |"),
                    ["title", "t0.0", "t0.1", "blank", "t1.0", "t1.1", "t1.2"], "a blank line ends a table; ordinals count up")
        Check.equal(kinds("T\n| a | b |\n|---|"), ["title", "p", "p"], "header and delimiter cell counts must match")
        Check.equal(kinds("T\n| a | b |\nnot a delimiter"), ["title", "p", "p"], "no delimiter row: not a table")
        Check.equal(kinds("T\n| a |\n|---|\n- item | x"), ["title", "t0.0", "t0.1", "bullet"], "a list item ends the table")
        Check.equal(kinds("| a |\n|---|\n| b |"), ["t0.0", "t0.1", "t0.2"], "a table on the first line is not a title")
        Check.equal(kinds("T\n```\n| a |\n|---|\n```"), ["title", "fence", "code", "code", "fence"], "no tables in code blocks")
        Check.equal(BlockScanner.scan("T\n| a |\n|---|" as NSString, tables: false).map(\.kind), [.paragraph, .paragraph, .paragraph],
                    "tables: false (Code / Plain notes)")

        let lines = BlockScanner.scan(sample as NSString)
        let tableLines = lines.filter { $0.kind == .table }
        Check.equal(tableLines.count, 4, "sample: header, delimiter and 2 rows")
        Check.equal(lines.filter { $0.kind == .checklist(checked: false) }.count, 1, "sample: the checklist after the table")
    }
}
