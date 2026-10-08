import AppKit
import NoteBarCore
import NoteBarEditor

/// Fenced code blocks in Standard notes: fixed fence bars, language label, editing guards.
@MainActor
enum CodeBlockChecks {
    static func run() {
        renderingChecks()
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
}
