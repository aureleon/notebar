import AppKit
import NoteBarCore
import NoteBarEditor

/// Fenced code blocks in Standard notes: fixed fence bars, language label, editing guards.
@MainActor
enum CodeBlockChecks {
    static func run() {
        renderingChecks()
        copyButtonChecks()
        editingChecks()
    }

    static func index(of needle: String, in h: BehaviorChecks.Harness) -> Int {
        (h.tv.string as NSString).range(of: needle).location
    }

    // MARK: A + B: fence bars, language label

    static func renderingChecks() {
        let h = BehaviorChecks.Harness("Title\n```swift\nlet x = 1\n```\nafter", hideMarkup: true)
        h.focus(at: nil)
        let outside = h.editor.intrinsicContentSize.height
        let tick = index(of: "```swift", in: h)
        let lang = index(of: "swift", in: h)
        Check.expect(h.editor.glyphIsHiddenForTesting(at: tick), "backticks hidden when the caret is outside the block")
        Check.expect(!h.editor.glyphIsHiddenForTesting(at: lang), "language label visible when the caret is outside")
        h.tv.setSelectedRange(NSRange(location: index(of: "let", in: h), length: 0))
        BehaviorChecks.spin()
        Check.expect(!h.editor.glyphIsHiddenForTesting(at: tick), "backticks shown when the caret is inside the block")
        Check.equal(h.editor.intrinsicContentSize.height, outside, "no height jump when the caret enters the block")
        h.tv.setSelectedRange(NSRange(location: 0, length: 0))
        BehaviorChecks.spin()
        Check.equal(h.editor.intrinsicContentSize.height, outside, "no height jump when the caret leaves the block")

        // The same with dimmed (not hidden) markup.
        let d = BehaviorChecks.Harness("Title\n```\ncode\n```", hideMarkup: false)
        d.focus(at: nil)
        let h1 = d.editor.intrinsicContentSize.height
        d.tv.setSelectedRange(NSRange(location: 0, length: 0))
        BehaviorChecks.spin()
        Check.equal(d.editor.intrinsicContentSize.height, h1, "dimmed markup: no height change")
    }

    // MARK: B: copy button

    static func copyButtonChecks() {
        MarkdownNoteEditor.codeCopyPasteboardForTesting = NSPasteboard(name: NSPasteboard.Name("NoteBarCodeCopyChecks"))
        let h = BehaviorChecks.Harness("Title\n```swift\nlet x = 1\nprint(x)\n```\nafter", hideMarkup: true)
        h.focus(at: 0)
        let code = h.editor.lineRectForTesting(at: index(of: "print", in: h))
        let frame = h.editor.hoverForTesting(NSPoint(x: code.minX + 4, y: code.midY))
        Check.expect(frame != nil, "copy button shows when the pointer is on a code block")
        if let frame {
            let bar = h.editor.lineRectForTesting(at: index(of: "```swift", in: h))
            Check.expect(frame.midY >= bar.minY && frame.midY <= bar.maxY, "copy button sits on the fence bar")
            Check.expect(frame.maxX <= h.tv.bounds.maxX, "copy button inside the text")
        }
        h.editor.clickCodeCopyForTesting()
        Check.equal(MarkdownNoteEditor.codeCopyPasteboardForTesting.string(forType: .string), "let x = 1\nprint(x)",
                    "copy button copies the code without the fences")
        let title = h.editor.lineRectForTesting(at: 0)
        Check.equal(h.editor.hoverForTesting(NSPoint(x: title.minX + 4, y: title.midY)), nil, "no button outside code blocks")
        _ = h.editor.hoverForTesting(NSPoint(x: code.minX + 4, y: code.midY))
        Check.equal(h.editor.hoverForTesting(nil), nil, "pointer gone: button hidden")

        // Plain and Code notes have no fenced blocks.
        let c = BehaviorChecks.Harness("```\nx\n```", mode: .code)
        c.focus(at: 0)
        let r = c.editor.lineRectForTesting(at: 4)
        Check.equal(c.editor.hoverForTesting(NSPoint(x: r.minX + 2, y: r.midY)), nil, "no copy button in Code notes")
    }

    // MARK: C + D: Return / Backspace / Delete

    static func sel(_ l: Int) -> NSRange { NSRange(location: l, length: 0) }

    static func expect(_ r: TextEditResult?, _ text: String?, _ caret: Int?, _ msg: String) {
        guard let text, let caret else { Check.expect(r == nil, "\(msg): keeps the default key (got \(String(describing: r)))"); return }
        Check.equal(r?.text, text, msg)
        Check.equal(r?.selection, sel(caret), "\(msg) (caret)")
    }

    static func editingChecks() {
        // C: Return after an opening fence adds the closing fence.
        expect(CodeBlockEditing.newline(text: "```", selection: sel(3)), "```\n\n```", 4, "Return after ``` closes the block")
        expect(CodeBlockEditing.newline(text: "x\n```swift", selection: sel(10)), "x\n```swift\n\n```", 11, "keeps the language")
        expect(CodeBlockEditing.newline(text: "  ~~~~", selection: sel(6)), "  ~~~~\n\n  ~~~~", 7, "same fence and indent")
        expect(CodeBlockEditing.newline(text: "```\nbelow", selection: sel(3)), "```\n\n```\nbelow", 4,
               "text below an unclosed fence stays outside")
        expect(CodeBlockEditing.newline(text: "```\na\n```", selection: sel(3)), nil, nil, "closed block: plain Return")
        expect(CodeBlockEditing.newline(text: "``", selection: sel(2)), nil, nil, "not a fence")

        // D3: Return on an empty last line exits the block.
        expect(CodeBlockEditing.newline(text: "```\na\n\n```", selection: sel(6)), "```\na\n```\n", 10, "Return twice exits the block")
        expect(CodeBlockEditing.newline(text: "```\na\n\n```\nnext", selection: sel(6)), "```\na\n```\n\nnext", 10,
               "exit adds a line before the next text")
        expect(CodeBlockEditing.newline(text: "```\na\n\n```\n\nnext", selection: sel(6)), "```\na\n```\n\nnext", 10,
               "exit reuses an empty line after the block")
        expect(CodeBlockEditing.newline(text: "```\n\n```", selection: sel(4)), nil, nil, "empty block: Return adds a line")

        // D1: Backspace at the start of the first code line.
        expect(CodeBlockEditing.backspace(text: "x\n```\n\n```", selection: sel(6)), "x", 1, "Backspace removes an empty block")
        expect(CodeBlockEditing.backspace(text: "```\n\n```\ny", selection: sel(4)), "y", 0, "empty block at the start")
        expect(CodeBlockEditing.backspace(text: "x\n```\ncode\n```", selection: sel(6)), "x\n```\ncode\n```", 1,
               "block with code: caret goes above the block")
        expect(CodeBlockEditing.backspace(text: "```\ncode\n```", selection: sel(4)), "```\ncode\n```", 4,
               "block at the note start: the key does nothing")
        expect(CodeBlockEditing.backspace(text: "```\ncode\n```", selection: sel(5)), nil, nil, "inside the line: plain Backspace")

        // D2: Forward Delete at the end of the last code line.
        expect(CodeBlockEditing.forwardDelete(text: "```\ncode\n```", selection: sel(8)), "```\ncode\n```", 8,
               "Delete does not join the closing fence")
        expect(CodeBlockEditing.forwardDelete(text: "```\ncode\nmore\n```", selection: sel(8)), nil, nil, "Delete between code lines")

        // The same through the live editor (text view commands).
        let h = BehaviorChecks.Harness("Title\n```")
        h.focus(at: nil)
        h.editor.doCommandForTesting(#selector(NSResponder.insertNewline(_:)))
        Check.equal(h.body, "Title\n```\n\n```", "editor: Return after ``` closes the block")
        h.type("let a")
        h.editor.doCommandForTesting(#selector(NSResponder.insertNewline(_:)))
        h.editor.doCommandForTesting(#selector(NSResponder.insertNewline(_:)))
        Check.equal(h.body, "Title\n```\nlet a\n```\n", "editor: Return twice leaves the block")
        h.type("after")
        Check.equal(h.body, "Title\n```\nlet a\n```\nafter", "typing continues below the block")
        h.tv.setSelectedRange(NSRange(location: (h.tv.string as NSString).range(of: "let").location, length: 0))
        h.editor.doCommandForTesting(#selector(NSResponder.deleteBackward(_:)))
        Check.equal(h.body, "Title\n```\nlet a\n```\nafter", "editor: Backspace keeps the block")
        Check.equal(h.tv.selectedRange().location, 5, "editor: caret at the end of the title line")
    }
}
