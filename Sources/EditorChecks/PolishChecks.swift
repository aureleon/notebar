import AppKit
import NoteBarCore
import NoteBarEditor

/// Checks for the fix round: spell-check skipping (B2), code lines that do not word-wrap (B5),
/// the formatting toolbar at the minimum panel width (B6), file tiles on their own line and the
/// file icon for text files (B7), and search marks (B3).
@MainActor
enum PolishChecks {
    static func run() {
        spellSkipping()
        searchMarks()
        codeWrapping()
        toolbarWidth()
        fileTiles()
    }

    /// Returns the storage range of the first occurrence of `needle`.
    static func range(of needle: String, in h: BehaviorChecks.Harness) -> NSRange {
        (h.tv.string as NSString).range(of: needle)
    }

    static func spellSkipping() {
        let body = "plain words here `codeSpan` and https://example.com/page and #ff8800 and <u>under</u>\n\n```\nlet fenced = 1\n```"
        let h = BehaviorChecks.Harness(body)
        h.focus(at: 0)
        Check.expect(h.editor.spellCheckingEnabledForTesting, "spell check on in focused standard note")
        Check.expect(!h.editor.spellSkippedForTesting(range(of: "plain", in: h)), "plain words are spell checked")
        Check.expect(!h.editor.spellSkippedForTesting(range(of: "words", in: h)), "plain word 2 is spell checked")
        Check.expect(h.editor.spellSkippedForTesting(range(of: "codeSpan", in: h)), "inline code is skipped")
        Check.expect(h.editor.spellSkippedForTesting(range(of: "example.com", in: h)), "URL is skipped")
        Check.expect(h.editor.spellSkippedForTesting(range(of: "#ff8800", in: h)), "hex color is skipped")
        Check.expect(h.editor.spellSkippedForTesting(range(of: "fenced", in: h)), "code block line is skipped")
        Check.expect(h.editor.spellSkippedForTesting(range(of: "<u>", in: h)), "<u> tag is skipped")

        // Unfocused editor: spell check off.
        let u = BehaviorChecks.Harness("some text")
        Check.expect(!u.editor.spellCheckingEnabledForTesting, "unfocused editor has spell check off")

        // Code note: always off.
        let c = BehaviorChecks.Harness("let x = 1", mode: .code)
        c.focus(at: 0)
        Check.expect(!c.editor.spellCheckingEnabledForTesting, "code note never spell checks")
        Check.expect(c.editor.spellSkippedForTesting(NSRange(location: 0, length: 3)), "code note: everything skipped")
    }

    static func searchMarks() {
        let h = BehaviorChecks.Harness("list one\n2. list two\nno match here\nLIST three")
        h.tv.setSelectedRange(NSRange(location: 0, length: 0))
        h.editor.highlightSearch("list")
        Check.equal(h.editor.searchMatchCount, 3, "search finds all three matches")
        let lm = h.tv.layoutManager!
        for m in ["list one", "list two", "LIST three"] {
            let loc = (h.tv.string as NSString).range(of: m, options: .caseInsensitive).location
            Check.expect(lm.temporaryAttribute(.backgroundColor, atCharacterIndex: loc, effectiveRange: nil) != nil,
                         "match marked: \(m)")
        }
        let nomatch = (h.tv.string as NSString).range(of: "no match").location
        Check.expect(lm.temporaryAttribute(.backgroundColor, atCharacterIndex: nomatch, effectiveRange: nil) == nil,
                     "non-match not marked")
        Check.equal(h.tv.selectedRange(), NSRange(location: 0, length: 0), "marks do not touch the selection")
        h.editor.clearSearchHighlight()
        Check.expect(lm.temporaryAttribute(.backgroundColor, atCharacterIndex: 0, effectiveRange: nil) == nil,
                     "clear removes marks")
        // A new query replaces the old marks.
        h.editor.highlightSearch("three")
        Check.equal(h.editor.searchMatchCount, 1, "new query replaces marks")
        Check.expect(lm.temporaryAttribute(.backgroundColor, atCharacterIndex: 0, effectiveRange: nil) == nil,
                     "old marks removed on new query")
        // Switching light -> dark gives the marks the dark highlight color.
        let threeLoc = (h.tv.string as NSString).range(of: "three").location
        h.editor.appearance = NSAppearance(named: .aqua)
        let lightMark = lm.temporaryAttribute(.backgroundColor, atCharacterIndex: threeLoc, effectiveRange: nil) as? NSColor
        h.editor.appearance = NSAppearance(named: .darkAqua)
        let darkMark = lm.temporaryAttribute(.backgroundColor, atCharacterIndex: threeLoc, effectiveRange: nil) as? NSColor
        Check.expect(darkMark != nil && h.editor.searchMatchCount == 1, "marks stay after an appearance change")
        Check.expect(darkMark != lightMark, "marks follow the appearance")
    }

    static func codeWrapping() {
        let long = "func greet(_ name: String, _ punctuation: String, _ greeting: String) -> String {"
        let h = BehaviorChecks.Harness("Title\n\n```\n\(long)\n```")
        let idx = range(of: "func greet", in: h).location
        let style = h.tv.textStorage?.attribute(.paragraphStyle, at: idx, effectiveRange: nil) as? NSParagraphStyle
        Check.expect(style.map { EditorDiagnostics.isCharWrapped($0) } ?? false, "code block line does not word-wrap")
        Check.expect((style?.headIndent ?? 0) > 0, "wrapped code row has a continuation indent")
        let para = h.tv.textStorage?.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle
        Check.expect(!(para.map { EditorDiagnostics.isCharWrapped($0) } ?? true), "prose still word-wraps")

        let c = BehaviorChecks.Harness(long, mode: .code)
        let cs = c.tv.textStorage?.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle
        Check.expect(cs.map { EditorDiagnostics.isCharWrapped($0) } ?? false, "code note does not word-wrap")
        // Height contract: a long code line is taller than one row, and the editor reports it (no internal scroll).
        c.editor.frame = NSRect(x: 0, y: 0, width: 200, height: 20)
        c.editor.layoutSubtreeIfNeeded()
        Check.expect(c.editor.intrinsicContentSize.height > 20, "code note grows with its (wrapped) height")
    }

    static func toolbarWidth() {
        let w = EditorDiagnostics.toolbarWidth
        Check.expect(w > 0, "toolbar built")
        Check.expect(w <= 280, "toolbar (\(w) pt) fits the minimum panel width (280 pt)")
        Check.expect(w <= EditorDiagnostics.toolbarMaxWidth, "toolbar within margin budget (\(w) pt)")
    }

    static func fileTiles() {
        // File tile = a block: text before and after it is on other lines.
        let h = BehaviorChecks.Harness("before text")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("nb-editor-tile.txt")
        try? "hi".write(to: url, atomically: true, encoding: .utf8)
        if let a = try? h.env.store.addAttachment(to: h.note.id, fileURL: url) {
            h.editor.insertAttachments([a])
            BehaviorChecks.spin()
            let body = h.body
            Check.expect(body.contains("before text\n[nb-editor-tile.txt]"), "file tile starts its own line: \(body.debugDescription)")
            Check.expect(body.hasSuffix("\n[nb-editor-tile.txt](attachment:\(a.id))"), "file tile ends its own line")
        }

        Check.expect(EditorDiagnostics.usesFileIcon(name: "notes.txt"), "txt uses file icon")
        Check.expect(EditorDiagnostics.usesFileIcon(name: "main.swift"), "swift uses file icon")
        Check.expect(EditorDiagnostics.usesFileIcon(name: "README.md"), "markdown uses file icon")
        Check.expect(EditorDiagnostics.usesFileIcon(name: "data.json"), "json uses file icon")
        Check.expect(!EditorDiagnostics.usesFileIcon(name: "paper.pdf"), "pdf uses Quick Look")
        Check.expect(!EditorDiagnostics.usesFileIcon(name: "photo.png"), "png uses Quick Look")
        Check.expect(!EditorDiagnostics.usesFileIcon(name: "archive.zip"), "zip uses Quick Look")
    }
}
