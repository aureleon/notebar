import AppKit
import NoteBarCore
import NoteBarEditor

/// Vim keys: the pure text engine (`VimText`, `VimEx`) and a live editor fed through `vimKeysForTesting`.
@MainActor
enum VimChecks {
    static func run() {
        MarkdownNoteEditor.vimPasteboardForTesting = NSPasteboard(name: NSPasteboard.Name("NoteBarVimChecks"))
        textChecks()
        exChecks()
        editorChecks()
        checkboxChecks()
    }

    /// Checkboxes are line markers: the Normal-mode caret skips them and line edits keep them.
    static func checkboxChecks() {
        // Storage: "Title⏎☐first task⏎☐second⏎plain line⏎☐third" (☐ = one attachment character).
        let body = "Title\n- [ ] first task\n- [x] second\nplain line\n- [ ] third"
        func run(_ keys: String) -> BehaviorChecks.Harness {
            let h = harness(body)
            h.focus(at: 0)
            h.editor.vimKeysForTesting(keys)
            return h
        }
        func at(_ keys: String) -> Int { run(keys).editor.selectedRangeForTesting.location }

        // Traversal.
        Check.equal(at("j"), 7, "checkbox: j lands on the text, not on the checkbox")
        Check.equal(at("jj"), 19, "checkbox: j onto the next checklist line")
        Check.equal(at("jjj"), 26, "checkbox: j keeps the wanted column (start of a plain line)")
        Check.equal(at("jjjk"), 19, "checkbox: k back onto a checklist line")
        Check.equal(at("jjjjkkkk"), 0, "checkbox: j / k there and back keep the column")
        Check.equal(at("$jk"), 4, "checkbox: k after j returns to the same column")
        Check.equal(at("jw0"), 7, "checkbox: 0 stops after the checkbox")
        Check.equal(at("jw^"), 7, "checkbox: ^ stops after the checkbox")
        Check.equal(at("jh"), 7, "checkbox: h stops after the checkbox")
        Check.equal(at("jwb"), 7, "checkbox: b stops at the first word")
        Check.equal(at("jbb"), 0, "checkbox: b skips the checkbox to the previous line")
        Check.equal(at("w"), 7, "checkbox: w from the line above lands on the text")
        Check.equal(at("e"), 4, "e: end of the title")
        Check.equal(at("ee"), 11, "checkbox: e skips the checkbox")
        Check.equal(at("G"), 38, "checkbox: G lands on the text")
        Check.equal(at("Ggg"), 0, "gg")

        // Edits keep the checkbox.
        Check.equal(run("jI!<Esc>").body, "Title\n- [ ] !first task\n- [x] second\nplain line\n- [ ] third", "checkbox: I inserts after the checkbox")
        Check.equal(run("j0x").body, "Title\n- [ ] irst task\n- [x] second\nplain line\n- [ ] third", "checkbox: 0x deletes text, not the checkbox")
        Check.equal(run("jX").body, body, "checkbox: X at the text start does not delete the checkbox")
        Check.equal(run("j$d0").body, "Title\n- [ ] k\n- [x] second\nplain line\n- [ ] third", "checkbox: d0 keeps the checkbox")
        Check.equal(run("j$d^").body, "Title\n- [ ] k\n- [x] second\nplain line\n- [ ] third", "checkbox: d^ keeps the checkbox")
        Check.equal(run("jcc!<Esc>").body, "Title\n- [ ] !\n- [x] second\nplain line\n- [ ] third", "checkbox: cc keeps the checkbox")
        Check.equal(run("jS!<Esc>").body, "Title\n- [ ] !\n- [x] second\nplain line\n- [ ] third", "checkbox: S keeps the checkbox")
        Check.equal(run("jdd").body, "Title\n- [x] second\nplain line\n- [ ] third", "checkbox: dd still deletes the whole line")
        Check.equal(run("jI<Esc>").editor.selectedRangeForTesting.location, 7, "checkbox: Esc after I stays off the checkbox")

        // j / k move by visual line in a wrapped paragraph, and k comes back to the same character.
        let long = String(repeating: "word ", count: 40) + "end\nnext"
        let w = harness(long)
        w.focus(at: 0)
        w.editor.vimKeysForTesting("ll")
        w.editor.vimKeysForTesting("j")
        let down = w.editor.selectedRangeForTesting.location
        Check.expect(down > 2 && down < 200, "j moves one visual line down inside a wrapped line (got \(down))")
        w.editor.vimKeysForTesting("k")
        Check.equal(w.editor.selectedRangeForTesting.location, 2, "k returns to the same character")

        // Pure VimText with a marker.
        let s = "\u{FFFC}task\n  \u{FFFC} x\n\u{FFFC}" as NSString
        let marker: VimText.Marker = { s.character(at: $0) == 0xFFFC }
        Check.equal(VimText.clampNormal(s, 0, marker: marker), 1, "clampNormal skips a checkbox")
        Check.equal(VimText.clampNormal(s, 6, marker: marker), 10, "clampNormal skips indent + checkbox + blank")
        Check.equal(VimText.clampNormal(s, 12, marker: marker), 12, "an empty checklist line keeps the caret on its checkbox")
        Check.equal(VimText.firstNonBlank(s, 7, marker: marker), 10, "firstNonBlank skips the marker prefix")
        Check.equal(VimText.firstNonBlank(s, 7), 8, "firstNonBlank without a marker is unchanged")
    }

    // MARK: VimText

    static func textChecks() {
        let s = "hello world, foo_bar\n\n  indented line\nlast" as NSString
        // Lines.
        Check.equal(VimText.lineStart(s, 8), 0, "lineStart")
        Check.equal(VimText.lineEnd(s, 3), 20, "lineEnd")
        Check.equal(VimText.firstNonBlank(s, 25), 24, "firstNonBlank skips indent")
        Check.equal(VimText.lineIndex(s, 24), 2, "lineIndex")
        Check.equal(VimText.lineCount(s), 4, "lineCount")
        Check.equal(VimText.startOfLine(s, 3), 38, "startOfLine")
        Check.equal(VimText.clampNormal(s, 20), 19, "normal caret never sits on the line break")
        Check.equal(VimText.clampNormal(s, 21), 21, "empty line keeps its caret")

        // Words.
        Check.equal(VimText.target(.wordForward(big: false), in: s, from: 0), 6, "w")
        Check.equal(VimText.target(.wordForward(big: false), in: s, from: 6), 11, "w stops at punctuation")
        Check.equal(VimText.target(.wordForward(big: false), in: s, from: 11), 13, "w after punctuation")
        Check.equal(VimText.target(.wordForward(big: false), in: s, from: 13), 21, "w stops on an empty line")
        Check.equal(VimText.target(.wordForward(big: false), in: s, from: 21), 24, "w from an empty line")
        Check.equal(VimText.target(.wordForward(big: true), in: s, from: 6), 13, "W skips punctuation")
        Check.equal(VimText.target(.wordEnd(big: false), in: s, from: 0), 4, "e")
        Check.equal(VimText.target(.wordEnd(big: false), in: s, from: 4), 10, "e from a word end")
        Check.equal(VimText.target(.wordBackward(big: false), in: s, from: 13), 11, "b to punctuation")
        Check.equal(VimText.target(.wordBackward(big: false), in: s, from: 10), 6, "b inside a word")
        Check.equal(VimText.target(.wordBackward(big: false), in: s, from: 24), 21, "b stops on an empty line")
        Check.equal(VimText.target(.wordForward(big: false), in: s, from: 0, count: 3), 13, "3w")

        // Line motions.
        Check.equal(VimText.target(.lineEnd, in: s, from: 2), 19, "$")
        Check.equal(VimText.target(.lineStart, in: s, from: 30), 22, "0")
        Check.equal(VimText.target(.firstNonBlank, in: s, from: 30), 24, "^")
        Check.equal(VimText.target(.fileEnd(line: nil), in: s, from: 0), 38, "G")
        Check.equal(VimText.target(.fileStart(line: nil), in: s, from: 40), 0, "gg")
        Check.equal(VimText.target(.fileStart(line: 2), in: s, from: 0), 24, "3gg")
        Check.equal(VimText.target(.down, in: s, from: 3, count: 2), 25, "2j keeps the column")
        Check.equal(VimText.target(.left, in: s, from: 22), 22, "h stops at the line start")
        Check.equal(VimText.target(.right, in: s, from: 19), 19, "l stops at the last character")

        // Operator ranges.
        Check.equal(VimText.operatorRange(.wordForward(big: false), in: s, from: 0)?.range, NSRange(location: 0, length: 6), "dw")
        Check.equal(VimText.operatorRange(.wordForward(big: false), in: s, from: 0, change: true)?.range,
                    NSRange(location: 0, length: 5), "cw = ce")
        Check.equal(VimText.operatorRange(.wordForward(big: false), in: s, from: 13)?.range,
                    NSRange(location: 13, length: 7), "dw on the last word stops at the line end")
        Check.equal(VimText.operatorRange(.lineEnd, in: s, from: 6)?.range, NSRange(location: 6, length: 14), "D")
        Check.equal(VimText.operatorRange(.wordBackward(big: false), in: s, from: 10)?.range, NSRange(location: 6, length: 4), "db")
        let dj = VimText.operatorRange(.down, in: s, from: 2)
        Check.equal(dj?.range, NSRange(location: 0, length: 22), "dj: two whole lines")
        Check.expect(dj?.linewise == true, "dj is linewise")

        // Linewise delete at the end eats the line break before.
        let two = "one\ntwo" as NSString
        Check.equal(VimText.linewiseDeleteRange(two, VimText.linesRange(two, from: 5, to: 5).range),
                    NSRange(location: 3, length: 4), "dd on the last line")

        // Paste.
        Check.equal(VimText.paste("XY", linewise: false, before: false, in: "abc" as NSString, at: 0),
                    VimEdit(range: NSRange(location: 1, length: 0), text: "XY", caret: 2), "p charwise")
        Check.equal(VimText.paste("XY", linewise: false, before: true, in: "abc" as NSString, at: 1),
                    VimEdit(range: NSRange(location: 1, length: 0), text: "XY", caret: 2), "P charwise")
        Check.equal(VimText.paste("new\n", linewise: true, before: false, in: "a\nb" as NSString, at: 0),
                    VimEdit(range: NSRange(location: 2, length: 0), text: "new\n", caret: 2), "p linewise")
        Check.equal(VimText.paste("new\n", linewise: true, before: false, in: "a\nb" as NSString, at: 2),
                    VimEdit(range: NSRange(location: 3, length: 0), text: "\nnew", caret: 4), "p linewise on the last line")
        Check.equal(VimText.paste("  new\n", linewise: true, before: true, in: "a\nb" as NSString, at: 2),
                    VimEdit(range: NSRange(location: 2, length: 0), text: "  new\n", caret: 4), "P linewise → first non-blank")
    }

    // MARK: VimEx

    static func exChecks() {
        Check.equal(VimEx.parse("pin"), .card(.togglePin), ":pin")
        Check.equal(VimEx.parse("p"), .card(.togglePin), ":p")
        Check.equal(VimEx.parse("fold"), .card(.setFolded(true)), ":fold")
        Check.equal(VimEx.parse("unfold"), .card(.setFolded(false)), ":unfold")
        Check.equal(VimEx.parse("color blue"), .card(.setColor(.blue)), ":color blue")
        Check.equal(VimEx.parse("color pur"), .card(.setColor(.purple)), ":color prefix")
        Check.equal(VimEx.parse("color default"), .card(.setColor(.none)), ":color default")
        Check.equal(VimEx.parse("color"), .card(.showColorMenu), "bare :color opens the menu")
        if case .error = VimEx.parse("color mauve") {} else { Check.expect(false, ":color with an unknown name is an error") }
        Check.equal(VimEx.parse("mode code"), .card(.setMode(.code)), ":mode code")
        Check.equal(VimEx.parse("mode plain"), .card(.setMode(.plain)), ":mode plain")
        Check.equal(VimEx.parse("mode standard"), .card(.setMode(.standard)), ":mode standard")
        Check.equal(VimEx.parse("move Work Stuff"), .card(.moveToFolder("Work Stuff")), ":move <folder> keeps spaces")
        Check.equal(VimEx.parse("m ideas"), .card(.moveToFolder("ideas")), ":m <folder>")
        Check.equal(VimEx.parse("move"), .card(.showMoveMenu), "bare :move opens the menu")
        Check.equal(VimEx.parse("copy"), .card(.copyNote), ":copy")
        Check.equal(VimEx.parse("archive"), .card(.setArchived(true)), ":archive")
        Check.equal(VimEx.parse("unarchive"), .card(.setArchived(false)), ":unarchive")
        Check.equal(VimEx.parse("y"), .card(.copyNote), ":y")
        Check.equal(VimEx.parse("delete"), .card(.delete), ":delete")
        Check.equal(VimEx.parse("d"), .card(.delete), ":d")
        Check.equal(VimEx.parse("w"), .write, ":w")
        Check.equal(VimEx.parse("q"), .card(.quit), ":q")
        Check.equal(VimEx.parse("wq"), .card(.quit), ":wq")
        Check.equal(VimEx.parse("12"), .goToLine(12), ":12")
        Check.equal(VimEx.parse("  "), .none, "empty command line")
        if case .error = VimEx.parse("frobnicate") {} else { Check.expect(false, "unknown command is an error") }
    }

    // MARK: Live editor

    static func harness(_ body: String, mode: NoteMode = .standard) -> BehaviorChecks.Harness {
        let h = BehaviorChecks.Harness(body, mode: mode)
        h.env.settings.vimKeybinds = true
        return h
    }

    static func editorChecks() {
        // Focus starts in Normal mode; keys do not type.
        var h = harness("hello world\nsecond line")
        h.focus(at: 0)
        Check.equal(h.editor.vimMode, .normal, "focus starts in Normal mode")
        Check.expect(h.editor.vimBlockCaretRectForTesting != nil, "Normal mode draws a block caret")
        h.editor.vimKeysForTesting("w")
        Check.equal(h.editor.selectedRangeForTesting.location, 6, "w moves the caret")
        Check.equal(h.body, "hello world\nsecond line", "Normal-mode keys do not insert text")
        h.editor.vimKeysForTesting("qQ;")
        Check.equal(h.body, "hello world\nsecond line", "unknown Normal-mode keys do nothing")

        // Insert / Escape.
        h.editor.vimKeysForTesting("iX")
        Check.equal(h.editor.vimMode, .insert, "i enters Insert mode")
        Check.equal(h.body, "hello Xworld\nsecond line", "Insert mode types")
        h.editor.vimKeysForTesting("<Esc>")
        Check.equal(h.editor.vimMode, .normal, "Esc returns to Normal mode")
        Check.equal(h.editor.selectedRangeForTesting.location, 6, "Esc moves the caret one left")
        Check.expect(h.editor.vimBlockCaretRectForTesting != nil, "block caret back in Normal mode")
        h.editor.vimKeysForTesting("A!<C-[>")
        Check.equal(h.body, "hello Xworld!\nsecond line", "A appends at the line end; ⌃[ leaves Insert mode")
        Check.equal(h.editor.vimMode, .normal, "⌃[ in Insert mode = Esc")
        Check.expect(h.events.isEmpty, "⌃[ in Insert mode does not navigate up")

        // x, dd, u, ⌃R, p, P, yy, r.
        h = harness("one\ntwo\nthree")
        h.focus(at: 0)
        h.editor.vimKeysForTesting("x")
        Check.equal(h.body, "ne\ntwo\nthree", "x")
        h.editor.vimKeysForTesting("u")
        Check.equal(h.body, "one\ntwo\nthree", "u undoes")
        h.editor.vimKeysForTesting("<C-r>")
        Check.equal(h.body, "ne\ntwo\nthree", "⌃R redoes")
        h.editor.vimKeysForTesting("u")
        h.editor.vimKeysForTesting("jdd")
        Check.equal(h.body, "one\nthree", "dd deletes the line")
        h.editor.vimKeysForTesting("p")
        Check.equal(h.body, "one\nthree\ntwo", "p pastes the line below")
        h.editor.vimKeysForTesting("ggP")
        Check.equal(h.body, "two\none\nthree\ntwo", "P pastes the line above")
        h.editor.vimKeysForTesting("yyjp")
        Check.equal(h.body, "two\none\ntwo\nthree\ntwo", "yy yanks the line")
        h.editor.vimKeysForTesting("ggrT")
        Check.equal(h.body, "Two\none\ntwo\nthree\ntwo", "r replaces the character")
        h.editor.vimKeysForTesting("Gk2dd")
        Check.equal(h.body, "Two\none\ntwo", "count + dd at the end")

        // Operators with motions, D / C, o / O.
        h = harness("alpha beta gamma")
        h.focus(at: 0)
        h.editor.vimKeysForTesting("dw")
        Check.equal(h.body, "beta gamma", "dw")
        h.editor.vimKeysForTesting("cwBETA<Esc>")
        Check.equal(h.body, "BETA gamma", "cw changes the word")
        h.editor.vimKeysForTesting("wD")
        Check.equal(h.body, "BETA ", "D deletes to the line end")
        h.editor.vimKeysForTesting("0C new<Esc>")
        Check.equal(h.body, " new", "C changes to the line end")
        h.editor.vimKeysForTesting("onext<Esc>")
        Check.equal(h.body, " new\nnext", "o opens a line below")
        h.editor.vimKeysForTesting("Otop<Esc>")
        Check.equal(h.body, " new\ntop\nnext", "O opens a line above")

        // o in a list continues the list (same as Return).
        h = harness("- item")
        h.focus(at: 0)
        h.editor.vimKeysForTesting("osecond<Esc>")
        Check.equal(h.body, "- item\n- second", "o continues a bullet list")

        // Checkbox tokens survive yank / paste.
        h = harness("- [ ] task")
        h.focus(at: 0)
        h.editor.vimKeysForTesting("yyp")
        Check.equal(h.body, "- [ ] task\n- [ ] task", "yy / p keep checklist markdown")
        Check.equal(h.editor.attachmentStatesForTesting.filter { $0 == "checkbox" }.count, 2, "pasted checkbox is a checkbox")

        // / search, n / N, Esc clears.
        h = harness("cat dog cat bird cat")
        h.focus(at: 0)
        h.editor.vimKeysForTesting("/ca")
        Check.equal(h.editor.vimPromptTextForTesting, "/ca", "/ opens the search prompt")
        Check.expect((h.editor.vimPromptFrameForTesting?.height ?? 0) > 0, "prompt is shown in the editor")
        Check.equal(h.editor.searchMatchCount, 3, "incremental search marks matches")
        h.editor.vimKeysForTesting("t<CR>")
        Check.equal(h.editor.vimPromptTextForTesting, nil, "Return closes the prompt")
        Check.equal(h.editor.selectedRangeForTesting.location, 8, "Return jumps to the next match")
        h.editor.vimKeysForTesting("n")
        Check.equal(h.editor.selectedRangeForTesting.location, 17, "n: next match")
        h.editor.vimKeysForTesting("n")
        Check.equal(h.editor.selectedRangeForTesting.location, 0, "n wraps around")
        h.editor.vimKeysForTesting("N")
        Check.equal(h.editor.selectedRangeForTesting.location, 17, "N: previous match")
        h.editor.vimKeysForTesting("<Esc>")
        Check.equal(h.editor.searchMatchCount, 0, "Esc clears the search marks")
        Check.expect(h.events.isEmpty, "first Esc only clears the marks")
        h.editor.vimKeysForTesting("/zzz<CR>")
        Check.equal(h.events.last.map { "\($0)" }, "\(EditorEvent.vim(.message("Pattern not found: zzz")))", "no match → message")

        // : commands → card events, prompt height.
        h = harness("note")
        h.focus(at: 0)
        let before = h.editor.intrinsicContentSize.height
        h.editor.vimKeysForTesting(":col")
        Check.equal(h.editor.vimPromptTextForTesting, ":col", ": opens the command prompt")
        Check.expect(h.editor.intrinsicContentSize.height > before, "the prompt adds to the editor height")
        h.editor.vimKeysForTesting("or blue<CR>")
        Check.expect(h.editor.intrinsicContentSize.height == before, "closing the prompt restores the height")
        func lastVim() -> VimCardCommand? { if case .vim(let c)? = h.events.last { return c }; return nil }
        Check.equal(lastVim(), .setColor(.blue), ":color blue sends setColor")
        h.editor.vimKeysForTesting(":pin<CR>")
        Check.equal(lastVim(), .togglePin, ":pin")
        h.editor.vimKeysForTesting(":move Ideas<CR>")
        Check.equal(lastVim(), .moveToFolder("Ideas"), ":move Ideas")
        h.editor.vimKeysForTesting(":q<CR>")
        Check.equal(lastVim(), .quit, ":q")
        let n = h.events.count
        h.editor.vimKeysForTesting(":pin<Esc>")
        Check.equal(h.events.count, n, "Esc cancels the command line")
        h.editor.vimKeysForTesting(":x<BS><BS>")
        Check.equal(h.editor.vimPromptTextForTesting, nil, "Backspace on an empty command line closes it")

        // Direct card keys (g prefix), za / Tab, ⌃W chord, ⌃[.
        let keys: [(String, VimCardCommand)] = [
            ("gp", .togglePin), ("gc", .showColorMenu), ("gm", .showMoveMenu), ("gy", .copyNote),
            ("gf", .showFormatMenu), ("ge", .toggleExpand), ("ga", .toggleArchive), ("gx", .delete), ("za", .toggleFold), ("zc", .setFolded(true)), ("zo", .setFolded(false)),
            ("<C-w>j", .focusNextCard), ("<C-w>k", .focusPreviousCard), ("<C-w><C-j>", .focusNextCard),
            ("<C-[>", .navigateUp),
        ]
        for (k, cmd) in keys {
            h.events.removeAll()
            h.editor.vimKeysForTesting(k)
            Check.equal(lastVim(), cmd, "\(k) sends \(cmd)")
        }
        h.events.removeAll()
        let tabBody = h.body
        h.editor.vimKeysForTesting("<Tab>")
        Check.equal(lastVim(), nil, "Tab in Normal mode does not fold")
        Check.equal(h.body, tabBody, "Tab in Normal mode does not type")
        Check.equal(h.body, "note", "card keys do not change the text")
        // Uppercase keys keep their vim meaning.
        h = harness("first\nsecond")
        h.focus(at: 0)
        h.editor.vimKeysForTesting("Yp")
        Check.equal(h.body, "first\nfirst\nsecond", "Y yanks the line, p pastes")
        Check.expect(h.events.isEmpty, "Y / P are text keys, not card actions")

        // Esc in Normal mode (nothing pending) leaves the card.
        h.editor.vimKeysForTesting("<Esc>")
        if case .escape? = h.events.last {} else { Check.expect(false, "Esc in Normal mode sends .escape") }

        // New notes start in Insert mode.
        h = harness("")
        h.editor.focus(atEnd: true, insertMode: true)
        BehaviorChecks.spin()
        Check.equal(h.editor.vimMode, .insert, "focus(insertMode:) starts in Insert mode")
        h.editor.vimKeysForTesting("typed")
        Check.equal(h.body, "typed", "typing right away in a new note")

        visualChecks()
        dotChecks()

        // Turning vim off: plain editing, no block caret.
        h = harness("text")
        h.focus(at: 0)
        h.env.settings.vimKeybinds = false
        BehaviorChecks.spin()
        Check.equal(h.editor.vimMode, nil, "vimMode is nil when vim keys are off")
        Check.equal(h.editor.vimBlockCaretRectForTesting, nil, "no block caret when vim keys are off")
        Check.expect(!h.editor.vimKeysForTesting("x"), "vim keys off: the vim layer takes no keys")
    }

    // MARK: Visual mode

    static func visualChecks() {
        var h = harness("alpha beta gamma\nsecond line\nthird")
        h.focus(at: 0)
        h.editor.vimKeysForTesting("v")
        Check.equal(h.editor.vimMode, .visual, "v enters Visual mode")
        Check.equal(h.editor.selectedRangeForTesting, NSRange(location: 0, length: 1), "v selects the character")
        Check.equal(h.editor.vimBlockCaretRectForTesting, nil, "no block caret in Visual mode")
        h.editor.vimKeysForTesting("e")
        Check.equal(h.editor.selectedRangeForTesting, NSRange(location: 0, length: 5), "e extends the selection")
        h.editor.vimKeysForTesting("o")
        h.editor.vimKeysForTesting("<Esc>")
        Check.equal(h.editor.vimMode, .normal, "Esc leaves Visual mode")
        Check.equal(h.editor.selectedRangeForTesting, NSRange(location: 0, length: 0), "o swapped ends: caret at the anchor")
        Check.equal(h.body, "alpha beta gamma\nsecond line\nthird", "moving in Visual mode does not edit")

        h.editor.vimKeysForTesting("wvey")
        Check.equal(h.editor.vimMode, .normal, "y leaves Visual mode")
        Check.equal(h.editor.selectedRangeForTesting.location, 6, "y: caret at the selection start")
        h.editor.vimKeysForTesting("$p")
        Check.equal(h.body, "alpha beta gammabeta\nsecond line\nthird", "visual y / p")
        h.editor.vimKeysForTesting("u0vlld")
        Check.equal(h.body, "ha beta gamma\nsecond line\nthird", "visual d")

        // Linewise.
        BehaviorChecks.spin()
        h.editor.vimKeysForTesting("Vjd")
        Check.equal(h.body, "third", "V j d deletes two lines")
        BehaviorChecks.spin()
        h.editor.vimKeysForTesting("u")
        h.editor.vimKeysForTesting("ggVy")
        h.editor.vimKeysForTesting("Gp")
        Check.equal(h.body, "ha beta gamma\nsecond line\nthird\nha beta gamma", "V y yanks the line")

        // Change, case, replace.
        h = harness("hello world")
        h.focus(at: 0)
        h.editor.vimKeysForTesting("veU")
        Check.equal(h.body, "HELLO world", "visual U")
        h.editor.vimKeysForTesting("wve~")
        Check.equal(h.body, "HELLO WORLD", "visual ~")
        h.editor.vimKeysForTesting("0veu")
        Check.equal(h.body, "hello WORLD", "visual u")
        h.editor.vimKeysForTesting("wverx")
        Check.equal(h.body, "hello xxxxx", "visual r")
        h.editor.vimKeysForTesting("0vecbye<Esc>")
        Check.equal(h.body, "bye xxxxx", "visual c")
        Check.equal(h.editor.vimMode, .normal, "Esc after visual c")

        // Visual p replaces the selection.
        h = harness("one two")
        h.focus(at: 0)
        h.editor.vimKeysForTesting("yewvep")
        Check.equal(h.body, "one one", "visual p replaces the selection")

        // Checkboxes are kept by case changes.
        h = harness("- [ ] task")
        h.focus(at: 0)
        h.editor.vimKeysForTesting("VU")
        Check.equal(h.body, "- [ ] TASK", "visual U keeps the checkbox")
    }

    // MARK: Dot repeat

    static func dotChecks() {
        var h = harness("a b c d e f")
        h.focus(at: 0)
        h.editor.vimKeysForTesting("x.")
        Check.equal(h.body, "b c d e f", ". repeats x")
        h.editor.vimKeysForTesting("dw..")
        Check.equal(h.body, "e f", ". repeats dw")

        h = harness("one\ntwo\nthree\nfour\nfive")
        h.focus(at: 0)
        h.editor.vimKeysForTesting("dd.")
        Check.equal(h.body, "three\nfour\nfive", ". repeats dd")
        // Each key is its own event in the app (undo groups by event).
        BehaviorChecks.spin()
        h.editor.vimKeysForTesting("2.")
        Check.equal(h.body, "five", "a count replaces the count of the change")
        BehaviorChecks.spin()
        h.editor.vimKeysForTesting("u")
        Check.equal(h.body, "three\nfour\nfive", "u undoes the repeated change at once")

        // Inserts are repeated with their text.
        h = harness("x\ny")
        h.focus(at: 0)
        h.editor.vimKeysForTesting("A!<Esc>j.")
        Check.equal(h.body, "x!\ny!", ". repeats A + typed text")
        h.editor.vimKeysForTesting("onew<Esc>.")
        Check.equal(h.body, "x!\ny!\nnew\nnew", ". repeats o + typed text")

        h = harness("foo bar baz")
        h.focus(at: 0)
        h.editor.vimKeysForTesting("cwqux<Esc>w.")
        Check.equal(h.body, "qux qux baz", ". repeats cw + typed text")
        h.editor.vimKeysForTesting("wrZ.")
        Check.equal(h.body, "qux qux Zaz", ". repeats r (same character)")

        // Motions, yanks and undo are not changes.
        h = harness("abc def")
        h.focus(at: 0)
        h.editor.vimKeysForTesting("xwyy.")
        Check.equal(h.body, "bc ef", "motions and yanks keep the last change for .")

        // Visual changes repeat on the same size.
        h = harness("one\ntwo\nthree\nfour\nfive")
        h.focus(at: 0)
        h.editor.vimKeysForTesting("Vjd.")
        Check.equal(h.body, "five", ". after V j d deletes two more lines")
        h = harness("abcdefgh")
        h.focus(at: 0)
        h.editor.vimKeysForTesting("vld.")
        Check.equal(h.body, "efgh", ". after v l d deletes two more characters")
        h = harness("aaa bbb ccc")
        h.focus(at: 0)
        h.editor.vimKeysForTesting("veczz<Esc>ww.")
        Check.equal(h.body, "zz bbb zz", ". after visual c changes the same number of characters")
    }
}
