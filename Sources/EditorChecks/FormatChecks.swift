import AppKit
import NoteBarCore
import NoteBarEditor

@MainActor
enum FormatChecks {
    static func r(_ text: String, _ loc: Int, _ len: Int = 0) -> (String, NSRange) { (text, NSRange(location: loc, length: len)) }

    static func expect(_ result: TextEditResult, _ text: String, _ sel: NSRange? = nil, _ msg: String, line: UInt = #line) {
        Check.expect(result.text == text, "\(msg): text \(result.text.debugDescription) != \(text.debugDescription)", line: line)
        if let sel {
            Check.expect(result.selection == sel, "\(msg): selection \(result.selection) != \(sel)", line: line)
        }
    }

    static func sel(_ a: Int, _ b: Int = 0) -> NSRange { NSRange(location: a, length: b) }

    static func run() {
        // Bold on / off.
        let b1 = FormatEditing.toggle(.bold, text: "hello world", selection: sel(6, 5))
        expect(b1, "hello **world**", sel(8, 5), "bold wrap")
        expect(FormatEditing.toggle(.bold, text: b1.text, selection: b1.selection), "hello world", sel(6, 5), "bold unwrap")
        expect(FormatEditing.toggle(.bold, text: "hello **world**", selection: sel(6, 9)), "hello world", nil, "bold unwrap with markers selected")
        expect(FormatEditing.toggle(.bold, text: "a  word  b", selection: sel(1, 8)), "a  **word**  b", sel(5, 4), "bold trims whitespace")
        // Combining.
        expect(FormatEditing.toggle(.italic, text: "**x**", selection: sel(2, 1)), "***x***", sel(3, 1), "italic inside bold")
        expect(FormatEditing.toggle(.bold, text: "***x***", selection: sel(3, 1)), "*x*", nil, "remove bold from bold italic")
        expect(FormatEditing.toggle(.italic, text: "***x***", selection: sel(3, 1)), "**x**", nil, "remove italic from bold italic")
        expect(FormatEditing.toggle(.bold, text: "a **b** c", selection: sel(0, 9)), "**a b c**", nil, "bold merges inner spans")
        // Empty selection.
        expect(FormatEditing.toggle(.bold, text: "ab ", selection: sel(3)), "ab ****", sel(5), "empty pair")
        expect(FormatEditing.toggle(.bold, text: "hello", selection: sel(2)), "**hello**", sel(4), "wrap word at caret")
        expect(FormatEditing.toggle(.bold, text: "**hello**", selection: sel(4)), "hello", sel(2), "unwrap at caret")
        // Other styles.
        expect(FormatEditing.toggle(.strike, text: "abc", selection: sel(0, 3)), "~~abc~~", sel(2, 3), "strike")
        expect(FormatEditing.toggle(.highlight, text: "abc", selection: sel(0, 3)), "==abc==", sel(2, 3), "highlight")
        expect(FormatEditing.toggle(.code, text: "abc", selection: sel(0, 3)), "`abc`", sel(1, 3), "inline code")
        expect(FormatEditing.toggle(.code, text: "`abc`", selection: sel(1, 3)), "abc", sel(0, 3), "inline code off")
        expect(FormatEditing.toggle(.underline, text: "abc", selection: sel(0, 3)), "<u>abc</u>", sel(3, 3), "underline")
        expect(FormatEditing.toggle(.underline, text: "<u>abc</u>", selection: sel(3, 3)), "abc", sel(0, 3), "underline off")
        expect(FormatEditing.toggle(.italic, text: "a\nb", selection: sel(0, 3)), "*a*\n*b*", nil, "multi-line italic")
        expect(FormatEditing.toggle(.bold, text: "- item", selection: sel(0, 6)), "- **item**", nil, "bold skips list marker")

        // Links.
        expect(FormatEditing.toggleLink(text: "go here", selection: sel(3, 4), url: nil), "go [here](https://)", sel(10, 8), "link placeholder")
        expect(FormatEditing.toggleLink(text: "go here", selection: sel(3, 4), url: "https://x.y"), "go [here](https://x.y)", sel(22), "link with url")
        expect(FormatEditing.toggleLink(text: "[here](u)", selection: sel(1, 4), url: nil), "here", sel(0, 4), "unlink")
        expect(FormatEditing.toggleLink(text: "see https://a.b", selection: sel(4, 11), url: nil), "see [https://a.b](https://a.b)", nil, "link from url text")
        expect(FormatEditing.toggleLink(text: "x", selection: sel(1), url: nil), "x[](https://)", sel(2), "empty link")

        // Colors.
        let c1 = FormatEditing.setColor("#E5484D", text: "red", selection: sel(0, 3))
        expect(c1, "<span style=\"color:#E5484D\">red</span>", nil, "color wrap")
        expect(FormatEditing.setColor("#0D74CE", text: c1.text, selection: c1.selection), "<span style=\"color:#0D74CE\">red</span>", nil, "color change")
        expect(FormatEditing.setColor(nil, text: c1.text, selection: c1.selection), "red", sel(0, 3), "color remove")

        // Headings.
        expect(FormatEditing.setHeading(1, text: "Title", selection: sel(2)), "# Title", sel(4), "h1")
        expect(FormatEditing.setHeading(1, text: "# Title", selection: sel(4)), "Title", sel(2), "h1 toggle off")
        expect(FormatEditing.setHeading(2, text: "# Title", selection: sel(4)), "## Title", nil, "h1 -> h2")
        expect(FormatEditing.setHeading(nil, text: "### T", selection: sel(5)), "T", sel(1), "plain paragraph")
        expect(FormatEditing.cycleHeading(text: "T", selection: sel(1)), "# T", nil, "cycle 1")
        expect(FormatEditing.cycleHeading(text: "# T", selection: sel(3)), "## T", nil, "cycle 2")
        expect(FormatEditing.cycleHeading(text: "## T", selection: sel(4)), "### T", nil, "cycle 3")
        expect(FormatEditing.cycleHeading(text: "### T", selection: sel(5)), "T", nil, "cycle off")

        // Lists.
        expect(FormatEditing.toggleList(.bullet, text: "a\nb", selection: sel(0, 3)), "- a\n- b", nil, "bullets on")
        expect(FormatEditing.toggleList(.bullet, text: "- a\n- b", selection: sel(0, 7)), "a\nb", nil, "bullets off")
        expect(FormatEditing.toggleList(.numbered, text: "a\nb", selection: sel(0, 3)), "1. a\n2. b", nil, "numbers")
        expect(FormatEditing.toggleList(.checklist, text: "- a", selection: sel(3)), "- [ ] a", sel(7), "bullet -> checklist")
        expect(FormatEditing.toggleList(.checklist, text: "- [ ] a", selection: sel(7)), "a", sel(1), "checklist off")
        expect(FormatEditing.toggleList(.bullet, text: "", selection: sel(0)), "- ", sel(2), "bullet on empty line")
        expect(FormatEditing.toggleList(.bullet, text: "a\n\nb", selection: sel(0, 4)), "- a\n\n- b", nil, "skip blank lines")
        expect(FormatEditing.toggleQuote(text: "q", selection: sel(1)), "> q", sel(3), "quote on")
        expect(FormatEditing.toggleQuote(text: "> q", selection: sel(3)), "q", sel(1), "quote off")

        // Code blocks.
        expect(FormatEditing.toggleCodeBlock(text: "a\nb", selection: sel(0, 3)), "```\na\nb\n```", sel(4, 3), "code block wrap")
        expect(FormatEditing.toggleCodeBlock(text: "```\na\nb\n```", selection: sel(5)), "a\nb", nil, "code block unwrap")
        expect(FormatEditing.toggleCodeBlock(text: "", selection: sel(0)), "```\n\n```", sel(4), "empty code block")
        expect(FormatEditing.toggleCodeBlock(text: "x\n```\ny\n```\nz", selection: sel(7)), "x\ny\nz", nil, "unwrap middle block")

        // Clear formatting.
        expect(FormatEditing.clearFormatting(text: "**a** *b* `c` [d](u) ~~e~~ ==f== <u>g</u>", selection: sel(0, 40)),
               "a b c d e f g", nil, "clear all inline")
        expect(FormatEditing.clearFormatting(text: "# Head", selection: sel(3)), "Head", nil, "clear heading")
        expect(FormatEditing.clearFormatting(text: "- [ ] **x**", selection: sel(0, 11)), "- [ ] x", nil, "clear keeps checklist")
        expect(FormatEditing.clearFormatting(text: "**a** **b**", selection: sel(8, 1)), "**a** b", nil, "clear only selected span")

        // Attachment tokens are images / file tiles, not links: clear formatting and ⌘K keep them.
        let img = "Title\n![Pasted Image.png](attachment:5)\nmore"
        expect(FormatEditing.clearFormatting(text: img, selection: sel(0, (img as NSString).length)), img, nil, "clear keeps image")
        expect(FormatEditing.clearFormatting(text: "see [report.pdf](attachment:3) **now**", selection: sel(2)),
               "see [report.pdf](attachment:3) now", nil, "clear keeps file tile on caret line")
        expect(FormatEditing.clearFormatting(text: "[my_file_x.pdf](attachment:3) *a*", selection: sel(0, 33)),
               "[my_file_x.pdf](attachment:3) a", nil, "clear keeps tile label")
        expect(FormatEditing.clearFormatting(text: "**![a.png](attachment:1)**", selection: sel(0, 26)),
               "![a.png](attachment:1)", nil, "clear removes bold around image")
        expect(FormatEditing.toggleLink(text: img, selection: sel(6, 33), url: nil), img, sel(6, 33), "cmd-K keeps image")
        expect(FormatEditing.toggleLink(text: "see [report.pdf](attachment:3)", selection: sel(8), url: nil),
               "see [report.pdf](attachment:3)", sel(8), "cmd-K keeps file tile")
        expect(FormatEditing.toggleLink(text: "see [d](https://x.y)", selection: sel(6), url: nil), "see d", nil, "cmd-K unwraps a real link")
    }
}

@MainActor
enum ListChecks {
    static func sel(_ a: Int, _ b: Int = 0) -> NSRange { NSRange(location: a, length: b) }

    static func nl(_ text: String, _ caret: Int, _ expected: String?, _ caretAfter: Int? = nil, line: UInt = #line) {
        let r = ListEditing.newline(text: text, selection: sel(caret))
        Check.expect(r?.text == expected, "newline \(text.debugDescription)@\(caret): \(String(describing: r?.text)) != \(String(describing: expected))", line: line)
        if let caretAfter { Check.expect(r?.selection == sel(caretAfter), "newline caret \(String(describing: r?.selection)) != \(caretAfter)", line: line) }
    }

    static func run() {
        nl("- a", 3, "- a\n- ", 6)
        nl("* a", 3, "* a\n* ", 6)
        nl("1. a", 4, "1. a\n2. ", 8)
        nl("9) a", 4, "9) a\n10) ", 9)
        nl("- [x] a", 7, "- [x] a\n- [ ] ", 14)
        nl("- ", 2, "", 0)
        nl("- [ ] ", 6, "", 0)
        nl("a\n- ", 4, "a\n", 2)
        nl("\t- ", 3, "- ", 2)
        nl("> q", 3, "> q\n> ", 6)
        nl(">", 1, "", 0)
        nl("para", 4, nil)
        nl("- ab", 3, "- a\n- b", 6)
        nl("- a", 1, nil)
        nl("  - a", 5, "  - a\n  - ", 10)
        nl("```\n    x\n```", 9, "```\n    x\n    \n```", 14)

        let i1 = ListEditing.indent(text: "- a", selection: sel(3), outdent: false)
        Check.equal(i1?.text, "\t- a", "indent list item")
        Check.equal(i1?.selection, sel(4), "indent caret")
        Check.equal(ListEditing.indent(text: "\t- a", selection: sel(4), outdent: true)?.text, "- a", "outdent tab")
        Check.equal(ListEditing.indent(text: "    - a", selection: sel(7), outdent: true)?.text, "- a", "outdent spaces")
        Check.expect(ListEditing.indent(text: "plain", selection: sel(2), outdent: false) == nil, "no indent for paragraphs")
        Check.equal(ListEditing.indent(text: "- a\n- b", selection: sel(0, 7), outdent: false)?.text, "\t- a\n\t- b", "indent several")

        Check.equal(ListEditing.codeIndent(text: "ab", selection: sel(2), outdent: false).text, "ab  ", "code tab to stop")
        Check.equal(ListEditing.codeIndent(text: "a\nb", selection: sel(0, 3), outdent: false).text, "    a\n    b", "code indent lines")
        Check.equal(ListEditing.codeIndent(text: "    a\n  b", selection: sel(0, 9), outdent: true).text, "a\nb", "code outdent lines")
        Check.equal(ListEditing.newlineKeepingIndent(text: "    x", selection: sel(5))?.text, "    x\n    ", "code auto indent")
        Check.expect(ListEditing.newlineKeepingIndent(text: "x", selection: sel(1)) == nil, "no indent to keep")

        // Attachment placement.
        // Images and file tiles are both blocks (own line).
        let img = ("![i](attachment:1)", true), file = ("[f](attachment:2)", true)
        Check.equal(AttachmentInsertion.insert([img], into: "abc", selection: sel(3)).text, "abc\n![i](attachment:1)", "image on own line")
        Check.equal(AttachmentInsertion.insert([file], into: "abc", selection: sel(3)).text, "abc\n[f](attachment:2)", "file tile on own line")
        Check.equal(AttachmentInsertion.insert([img], into: "ab", selection: sel(1)).text, "a\n![i](attachment:1)\nb", "image splits line")
        Check.equal(AttachmentInsertion.insert([img, file], into: "", selection: sel(0)).text, "![i](attachment:1)\n[f](attachment:2)", "image then file")
        Check.equal(AttachmentInsertion.insert([file, file], into: "x\n", selection: sel(2)).text, "x\n[f](attachment:2)\n[f](attachment:2)", "two files, one per line")
        let ins = AttachmentInsertion.insert([img], into: "a\n", selection: sel(2))
        Check.equal(ins.selection, sel(20), "caret after inserted image")
    }
}
