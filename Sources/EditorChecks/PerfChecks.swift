import AppKit
import NoteBarCore
import NoteBarEditor

/// Rough performance guards for long notes. Bounds are loose (debug build); they catch accidental O(n²) work.
@MainActor
enum PerfChecks {
    static func time(_ block: () -> Void) -> Double {
        let t = CFAbsoluteTimeGetCurrent()
        block()
        return (CFAbsoluteTimeGetCurrent() - t) * 1000
    }

    static func longBody(lines: Int) -> String {
        var out: [String] = ["Long note"]
        for i in 0..<lines {
            switch i % 10 {
            case 0: out.append("## Section \(i)")
            case 1: out.append("- [ ] task \(i) with **bold** and `code`")
            case 2: out.append("- [x] done \(i) ~~old~~")
            case 3: out.append("Paragraph \(i) with *italic*, ==mark== and https://example.com/\(i) #ff8800")
            case 4: out.append("```")
            case 5: out.append("let x\(i) = \(i) // code")
            case 6: out.append("```")
            case 7: out.append("> quote \(i)")
            case 8: out.append("1. numbered \(i) [link](https://apple.com)")
            default: out.append("")
            }
        }
        return out.joined(separator: "\n")
    }

    static func run(verbose: Bool) {
        // Many small editors (a folder with 60 notes).
        let env = BehaviorChecks.makeEnv()
        let folder = env.store.folders()[0]
        let sample = "Breakfast\n- [ ] Eggs\n- [x] Bacon\nSome **bold** and *italic* text with `code`\n> quote\nhttps://example.com #ff8800"
        let notes = (0..<60).map { env.store.createNote(in: folder.id, body: sample + " \($0)", mode: .standard, position: .bottom) }
        var editors: [MarkdownNoteEditor] = []
        let many = time {
            for n in notes {
                let e = MarkdownNoteEditor(note: n, env: env)
                e.frame = NSRect(x: 0, y: 0, width: 260, height: 20)
                _ = e.intrinsicContentSize
                editors.append(e)
            }
        }
        if verbose { print(String(format: "perf: 60 small editors created + measured in %.0f ms", many)) }
        Check.expect(many < 3000, "60 editors \(many) ms")
        let restyle = time { NotificationCenter.default.post(name: .themeDidChange, object: nil) }
        if verbose { print(String(format: "perf: theme change restyle of 60 editors %.0f ms", restyle)) }
        editors.removeAll()

        for hide in [false, true] {
            let body = longBody(lines: 3000)
            var h: BehaviorChecks.Harness!
            let load = time { h = BehaviorChecks.Harness(body, hideMarkup: hide) }
            var height: CGFloat = 0
            let measure = time { height = h.editor.intrinsicContentSize.height }
            Check.expect(height > 3000 * 10, "long note height \(height)")
            h.focus(at: (h.tv.string as NSString).length / 2)
            var worst = 0.0
            var total = 0.0
            for ch in ["a", "*", "b", "*", " ", "`", "c", "`"] {
                let t = time {
                    h.tv.insertText(ch, replacementRange: h.tv.selectedRange())
                    _ = h.editor.intrinsicContentSize
                }
                worst = max(worst, t)
                total += t
            }
            let caretMoves = time {
                for _ in 0..<20 { h.tv.moveDown(nil) }
            }
            if verbose {
                print(String(format: "perf hide=%@: load %.0f ms, height %.0f ms, keystroke avg %.1f ms worst %.1f ms, 20 caret moves %.0f ms",
                             "\(hide)", load, measure, total / 8, worst, caretMoves))
            }
            Check.expect(load < 4000, "long note load \(load) ms")
            Check.expect(worst < 250, "long note keystroke \(worst) ms")
            Check.expect(caretMoves < 1500, "caret moves \(caretMoves) ms")
            Check.expect(h.body.contains("a*b* `c`"), "typed text in long note")
        }
    }
}
