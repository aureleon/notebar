import AppKit
import NoteBarCore
import NoteBarEditor

/// Fenced code blocks in Standard notes: fixed fence bars, language label, editing guards.
@MainActor
enum CodeBlockChecks {
    static func run() {
        renderingChecks()
        copyButtonChecks()
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
}
