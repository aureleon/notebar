import AppKit
import NoteBarCore
import NoteBarEditor

@MainActor
enum CodecChecks {
    static func roundTrip(_ md: String, _ options: CodecOptions = .standard, line: UInt = #line) {
        let attr = MarkdownCodec.attributedString(from: md, options: options)
        let back = MarkdownCodec.markdown(from: attr)
        Check.expect(back == md, "round trip \(md.debugDescription) -> \(back.debugDescription)", line: line)
        // Offset mapping is consistent at every storage offset.
        let embeds = MarkdownCodec.embeds(in: attr)
        for i in 0...attr.length {
            let m = MarkdownCodec.markdownOffset(forStorageOffset: i, embeds: embeds)
            let s = MarkdownCodec.storageOffset(forMarkdownOffset: m, embeds: embeds)
            if s != i { Check.expect(false, "offset map \(md.debugDescription) storage \(i) -> md \(m) -> \(s)", line: line); break }
        }
    }

    static func embedCount(_ md: String, _ options: CodecOptions = .standard) -> Int {
        MarkdownCodec.embeds(in: MarkdownCodec.attributedString(from: md, options: options)).count
    }

    static func run() {
        let samples = [
            "", "a", "\n", "\n\n", "- [ ] a", "- [x] done\n- [ ] todo", "- [ ]", "- [ ]\n", "* [X] up", "+ [ ] plus",
            "  - [ ] nested", "\t- [x] tab", "-  [ ] two spaces", "- [ ]a", "x - [ ] mid", "- [ ]  two after",
            "```\n- [ ] in code\n```\n- [ ] out", "![img](attachment:12)", "[file.pdf](attachment:3) and ![x](attachment:4)",
            "emoji 😀 **bold** 👍🏽\n- [ ] 🎉 party", "CRLF\r\n- [ ] a\r\n- [x] b\r\n", "\u{FFFC} literal", "[](attachment:1)",
            "![a]b](attachment:1)", "[a](attachment:)", "- [ ] ![img](attachment:5)", "- [y] no", "1. [ ] numbered",
            "> - [ ] quoted", "trailing\n- [ ]", "   - [x]\tx", "# Title\n\n**bold** *it* `code` ~~s~~ ==m==",
            "unclosed **bold and `code", "\r", "a\rb\r- [ ] c", "- [ ] a\u{2028}b", "日本語 - [ ] テキスト\n- [ ] 日本",
        ]
        for s in samples { roundTrip(s) }
        for s in samples { roundTrip(s, .raw) }

        Check.equal(embedCount("- [ ] a\n- [x] b"), 2, "two checkboxes")
        Check.equal(embedCount("- [ ] a", .raw), 0, "raw mode keeps checkboxes as text")
        Check.equal(embedCount("![i](attachment:1) [f](attachment:2)", .raw), 2, "attachments in raw mode")
        Check.equal(embedCount("```\n- [ ] x\n```"), 0, "no checkbox inside fence")
        Check.equal(embedCount("- [ ]a"), 0, "checkbox needs a space")
        Check.equal(embedCount("- [ ]"), 1, "checkbox at end of line")

        // Storage layout.
        let attr = MarkdownCodec.attributedString(from: "- [ ] ab\n![i](attachment:1)c", options: .standard)
        Check.equal(attr.string, "\u{FFFC}ab\n\u{FFFC}c", "storage string")
        let embeds = MarkdownCodec.embeds(in: attr)
        Check.equal(MarkdownCodec.markdownOffset(forStorageOffset: 1, embeds: embeds), 6, "md offset after checkbox")
        Check.equal(MarkdownCodec.markdownOffset(forStorageOffset: 4, embeds: embeds), 9, "md offset after newline")
        Check.equal(MarkdownCodec.storageOffset(forMarkdownOffset: 3, embeds: embeds), 0, "inside token rounds down")
        Check.equal(MarkdownCodec.storageOffset(forMarkdownOffset: 3, embeds: embeds, roundUp: true), 1, "inside token rounds up")
        Check.equal(MarkdownCodec.storageOffset(forMarkdownOffset: 28, embeds: embeds), 6, "end offset")

        // A checkbox without trailing space gets one when text follows it.
        let m = NSMutableAttributedString(attributedString: MarkdownCodec.attributedString(from: "- [ ]", options: .standard))
        m.append(NSAttributedString(string: "text"))
        Check.equal(MarkdownCodec.markdown(from: m), "- [ ] text", "space added after bare checkbox")

        // Partial ranges.
        Check.equal(MarkdownCodec.markdown(from: attr, range: NSRange(location: 4, length: 2)), "![i](attachment:1)c", "partial serialization")
        let part = MarkdownCodec.attributedString(from: "x\n- [ ] y\nz", options: .standard, range: NSRange(location: 2, length: 7))
        Check.equal(part.string, "\u{FFFC}y", "partial parse")

        // Toggling keeps the bullet and spacing.
        Check.equal(EmbedToken.checkbox(checked: false, source: "- [ ] ").toggled(), .checkbox(checked: true, source: "- [x] "), "toggle on")
        Check.equal(EmbedToken.checkbox(checked: true, source: "* [X]\t").toggled(), .checkbox(checked: false, source: "* [ ]\t"), "toggle off")

        // Fuzz: random markdown-ish strings are lossless.
        var rng = SeededGenerator(seed: 42)
        let alphabet = ["-", " ", "[", "]", "x", "X", "(", ")", "!", "attachment:", "1", "23", "\n", "\r\n", "*", "`", "a",
                        "😀", "\t", "\u{FFFC}", "#", "> ", "```", "~", "=", "_", "<u>", "é", "\r"]
        var failures = 0
        for _ in 0..<3000 {
            let n = Int.random(in: 0...40, using: &rng)
            let s = (0..<n).map { _ in alphabet[Int.random(in: 0..<alphabet.count, using: &rng)] }.joined()
            let a = MarkdownCodec.attributedString(from: s, options: .standard)
            if MarkdownCodec.markdown(from: a) != s {
                failures += 1
                if failures < 4 { print("fuzz mismatch: \(s.debugDescription)") }
            }
        }
        Check.equal(failures, 0, "fuzz round trips")
    }
}

/// Deterministic RNG for the fuzz checks.
struct SeededGenerator: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed &+ 0x9E3779B97F4A7C15 }
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}
