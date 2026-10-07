import AppKit
import NoteBarCore
import NoteBarEditor

@MainActor
enum SyntaxChecks {
    static func spans(_ s: String) -> [InlineSpan] {
        InlineParser.parse(s as NSString, in: NSRange(location: 0, length: (s as NSString).length))
    }

    static func kinds(_ s: String) -> [String] {
        spans(s).map { "\($0.kind)" }
    }

    static func has(_ s: String, _ kind: InlineSpan.Kind, content: String, line: UInt = #line) {
        let ns = s as NSString
        let ok = spans(s).contains { $0.kind == kind && ns.substring(with: $0.content) == content }
        Check.expect(ok, "\(s.debugDescription) should contain \(kind) '\(content)', got \(kinds(s))", line: line)
    }

    static func none(_ s: String, line: UInt = #line) {
        let k = spans(s).filter { if case .escape = $0.kind { return false }; return true }
        Check.expect(k.isEmpty, "\(s.debugDescription) should have no spans, got \(kinds(s))", line: line)
    }

    static func run() {
        // Emphasis.
        let b = spans("**bold**")
        Check.equal(b.count, 1, "one bold span")
        if let s = b.first {
            Check.equal(s.kind, .bold, "bold kind")
            Check.equal(s.range, NSRange(location: 0, length: 8), "bold range")
            Check.equal(s.content, NSRange(location: 2, length: 4), "bold content")
            Check.equal(s.markers, [NSRange(location: 0, length: 2), NSRange(location: 6, length: 2)], "bold markers")
        }
        has("*it*", .italic, content: "it")
        has("_it_", .italic, content: "it")
        has("__b__", .bold, content: "b")
        has("***bi***", .bold, content: "bi")
        has("***bi***", .italic, content: "**bi**")
        has("*a **b** c*", .italic, content: "a **b** c")
        has("*a **b** c*", .bold, content: "b")
        has("x **y** z", .bold, content: "y")
        has("**bold**.", .bold, content: "bold")
        none("snake_case_name")
        none("**unclosed")
        none("a * b * c")
        has("~~s~~", .strike, content: "s")
        none("~s~")
        has("==m==", .highlight, content: "m")
        none("a == b == c")
        has("`co*de*`", .code, content: "co*de*")
        Check.expect(!spans("`co*de*`").contains { $0.kind == .italic }, "no emphasis inside code")
        has("``a`b``", .code, content: "a`b")
        none("`unclosed")
        let esc = spans("\\*not\\*")
        Check.expect(!esc.contains { $0.kind == .italic }, "escaped stars")
        Check.equal(esc.filter { $0.kind == .escape }.count, 2, "two escapes")

        // Links.
        has("[t](http://x.com)", .link("http://x.com"), content: "t")
        has("![alt](https://x.com/a.png)", .link("https://x.com/a.png"), content: "alt")
        has("[a **b**](u)", .bold, content: "b")
        has("see https://example.com/a_b_c.", .autolink("https://example.com/a_b_c"), content: "https://example.com/a_b_c")
        has("(https://en.wikipedia.org/wiki/Foo_(bar))", .autolink("https://en.wikipedia.org/wiki/Foo_(bar)"),
            content: "https://en.wikipedia.org/wiki/Foo_(bar)")
        has("go to www.apple.com now", .autolink("www.apple.com"), content: "www.apple.com")
        has("<https://a.b/c>", .autolink("https://a.b/c"), content: "https://a.b/c")
        Check.expect(!spans("[x](https://a.b/c_d_e)").contains { $0.kind == .italic }, "no emphasis inside link url")

        // Tags.
        has("<u>u</u>", .underline, content: "u")
        has("<span style=\"color:#E5484D\">red</span>", .color("#E5484D"), content: "red")
        has("<span style=\"color: #abc;\">x</span>", .color("#abc"), content: "x")
        Check.expect(!spans("<span style=\"color:#E5484D\">r</span>").contains { if case .hex = $0.kind { return true }; return false },
                     "no hex swatch inside color tag")
        none("<u>unclosed")

        // Hex colors.
        let hx = spans("#ff8800 and #abc and #12345 and a#fff and #GGGGGG and #abcdef0")
        Check.equal(hx.filter { if case .hex = $0.kind { return true }; return false }.count, 2, "hex count")
        has("color: #FF8800;", .hex("#FF8800"), content: "#FF8800")

        // UTF-16 offsets with emoji.
        let e = spans("😀 **b**")
        Check.equal(e.first?.content, NSRange(location: 5, length: 1), "emoji offsets")

        // Blocks.
        let doc = "# H\n## H2\n> q\n- b\n1. n\n- [ ] c\n- [x] d\n```swift\ncode\n```\n---\npara\n#tag\n#ff8800 x\n\n  * nested\n2) paren"
        let lines = BlockScanner.scan(doc as NSString)
        let expected: [MarkdownLine.Kind] = [.heading(1), .heading(2), .quote, .bullet, .numbered(1), .checklist(checked: false),
                                             .checklist(checked: true), .fence, .code, .fence, .rule, .paragraph, .paragraph,
                                             .paragraph, .blank, .bullet, .numbered(2)]
        Check.equal(lines.map(\.kind), expected, "block kinds")
        Check.equal(lines.filter(\.isTitle).count, 1, "one title")
        Check.expect(lines[0].isTitle, "first line is title")
        Check.equal(lines[7].codeBlock, 0, "fence block id")
        Check.equal(lines[15].indent, 2, "nested indent")
        Check.equal((doc as NSString).substring(with: lines[5].markerRange), "- [ ] ", "checklist marker")
        Check.equal((doc as NSString).substring(with: lines[0].contentRange), "H", "heading content")

        let t = BlockScanner.scan("\n\nTitle\nbody" as NSString)
        Check.equal(t.map(\.isTitle), [false, false, true, false], "title is first non-empty line")
        let unclosed = BlockScanner.scan("a\n```\nx\ny" as NSString)
        Check.equal(unclosed.map(\.kind), [.paragraph, .fence, .code, .code], "unclosed fence runs to the end")
        let tilde = BlockScanner.scan("~~~\nx\n~~~\nafter" as NSString)
        Check.equal(tilde.map(\.kind), [.fence, .code, .fence, .paragraph], "tilde fences")
        let inline = BlockScanner.scan("```code```" as NSString)
        Check.equal(inline.map(\.kind), [.paragraph], "inline triple backticks are not a fence")
        let trailing = BlockScanner.scan("a\n" as NSString)
        Check.equal(trailing.count, 2, "trailing newline creates an empty last line")
        Check.equal(BlockScanner.lineIndex(in: trailing, containing: 2), 1, "line index at end")
        let crlf = BlockScanner.scan("a\r\n- b" as NSString)
        Check.equal(crlf.map(\.kind), [.paragraph, .bullet], "CRLF lines")
    }
}
