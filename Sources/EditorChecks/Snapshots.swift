import AppKit
import NoteBarCore
import NoteBarEditor

/// Offscreen PNG snapshots of representative notes (light/dark × dimmed/hidden markup).
@MainActor
enum Snapshots {
    /// A generated landscape-ish PNG (gradient sky, sun, hills).
    static func samplePNG(width: Int, height: Int) -> Data {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8,
                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                   bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        let r = NSRect(x: 0, y: 0, width: width, height: height)
        NSGradient(starting: NSColor(srgbRed: 0.98, green: 0.62, blue: 0.35, alpha: 1),
                   ending: NSColor(srgbRed: 0.35, green: 0.55, blue: 0.95, alpha: 1))!.draw(in: r, angle: 90)
        NSColor(srgbRed: 1, green: 0.93, blue: 0.6, alpha: 1).setFill()
        let s = CGFloat(min(width, height))
        NSBezierPath(ovalIn: NSRect(x: CGFloat(width) * 0.65, y: CGFloat(height) * 0.5, width: s * 0.25, height: s * 0.25)).fill()
        NSColor(srgbRed: 0.2, green: 0.45, blue: 0.3, alpha: 1).setFill()
        let hill = NSBezierPath()
        hill.move(to: .zero)
        hill.curve(to: NSPoint(x: CGFloat(width), y: CGFloat(height) * 0.2),
                   controlPoint1: NSPoint(x: CGFloat(width) * 0.3, y: CGFloat(height) * 0.55),
                   controlPoint2: NSPoint(x: CGFloat(width) * 0.6, y: 0))
        hill.line(to: NSPoint(x: CGFloat(width), y: 0))
        hill.close()
        hill.fill()
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])!
    }

    final class CardView: NSView {
        var fill: NSColor = .white
        override var isFlipped: Bool { true }
        override func draw(_ dirtyRect: NSRect) {
            fill.setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 8, dy: 6), xRadius: 16, yRadius: 16).fill()
        }
    }

    final class Canvas: NSView {
        var fill: NSColor = .black
        override var isFlipped: Bool { true }
        override func draw(_ dirtyRect: NSRect) { fill.setFill(); bounds.fill() }
    }

    struct Sample {
        var name: String
        var body: String
        var color: NoteColor
        var mode: NoteMode = .standard
        var caret: Int? = nil
    }

    static func run(outputDirectory dir: URL) {
        let fm = FileManager.default
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let scratch = dir.appendingPathComponent("fixtures", isDirectory: true)
        try? fm.createDirectory(at: scratch, withIntermediateDirectories: true)
        let photo = scratch.appendingPathComponent("photo.png")
        try? samplePNG(width: 1200, height: 760).write(to: photo)
        let report = scratch.appendingPathComponent("Quarterly Report.txt")
        try? "Quarterly report\nRevenue: up\nCosts: down\n".write(to: report, atomically: true, encoding: .utf8)

        for dark in [false, true] {
            for hide in [false, true] {
                let env = BehaviorChecks.makeEnv(hideMarkup: hide)
                let folder = env.store.folders()[0]
                // Attachments need a note id first.
                let attNote = env.store.createNote(in: folder.id, body: "", mode: .standard, position: .bottom)
                let img = try? env.store.addAttachment(to: attNote.id, fileURL: photo)
                let file = try? env.store.addAttachment(to: attNote.id, fileURL: report)
                let dirA = try? env.store.addAttachment(to: attNote.id, fileURL: scratch)
                let attBody = "Pictures & files\nDropped from Finder:\n"
                    + (img.map(AttachmentLink.markdown(for:)) ?? "") + "\n"
                    + [file, dirA].compactMap { $0.map(AttachmentLink.markdown(for:)) }.joined(separator: " ")
                    + "\nMissing: ![gone.png](attachment:9999)"

                let samples: [Sample] = [
                    Sample(name: "markdown", body: "Markdown\nSelect text to show the formatting toolbar, or type the markers. Examples:\n\n*italic*  **bold**. ***bold italic***. ~~strike~~. `code` ==marked text==\n> quote\n\n```c\nint main(int argc) {\n    print(\"Hello!\")\n}\n```", color: .blue),
                    Sample(name: "checklist", body: "Breakfast Shopping List\n- [ ] Eggs\n- [ ] Avocado\n- [x] Bacon\n- [ ] Orange juice #ff8800\n  - [ ] nested item that is long enough to wrap onto a second line", color: .cream),
                    Sample(name: "hello", body: "Hello!\n*NoteBar* keeps notes in a panel on the edge of the screen.\n\nIt styles a subset of Markdown and supports colors, checklists, images and file shortcuts", color: .green),
                    Sample(name: "blocks", body: "# Heading 1\n## Heading 2\n### Heading 3\n- bullet one\n- bullet two\n\t- nested bullet\n1. first\n2. second\nVisit [Apple](https://apple.com) or https://example.com\n<u>underlined</u> and <span style=\"color:#E5484D\">red text</span>\n---\nColors: #ff8800, #3a7 and #0A66D8", color: .none),
                    Sample(name: "attachments", body: attBody, color: .purple),
                    Sample(name: "code", body: "snippet.swift\nlet x = 42\nfunc f() {\n\tprint(\"**not bold**\")\n}\n- [ ] not a checkbox", color: .none, mode: .code),
                    Sample(name: "plain", body: "Plain note\n**not bold** and - [ ] raw\n# not a heading", color: .yellow, mode: .plain),
                ]
                var all = samples
                if hide {
                    all.append(Sample(name: "focused", body: "Focused\nCaret in **bold** span and `code`\n```\nlet a = 1\n```", color: .pink, caret: 17))
                }
                let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)!
                for s in all {
                    var note = env.store.createNote(in: folder.id, body: s.body, mode: s.mode, position: .bottom)
                    note.color = s.color
                    env.store.updateNote(note)
                    let url = dir.appendingPathComponent("\(dark ? "dark" : "light")-\(hide ? "hidden" : "dimmed")-\(s.name).png")
                    render(note: env.store.note(id: note.id)!, env: env, appearance: appearance, caret: s.caret, to: url)
                }
            }
        }
        for dark in [false, true] {
            let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)!
            let bar = EditorDiagnostics.toolbarContentView()
            let canvas = Canvas(frame: NSRect(x: 0, y: 0, width: bar.frame.width + 40, height: bar.frame.height + 40))
            canvas.appearance = appearance
            canvas.fill = dark ? NSColor(white: 0.15, alpha: 1) : NSColor(white: 0.93, alpha: 1)
            bar.setFrameOrigin(NSPoint(x: 20, y: 20))
            canvas.addSubview(bar)
            canvas.layoutSubtreeIfNeeded()
            write(canvas, appearance: appearance, to: dir.appendingPathComponent("\(dark ? "dark" : "light")-toolbar.png"))
        }
        print("snapshots written to \(dir.path)")
    }

    static func render(note: Note, env: AppEnvironment, appearance: NSAppearance, caret: Int?, to url: URL) {
        let width: CGFloat = 260
        let pad: CGFloat = 16
        let canvas = Canvas(frame: NSRect(x: 0, y: 0, width: width + 2 * pad + 16, height: 200))
        canvas.appearance = appearance
        canvas.fill = appearance.name == .darkAqua ? NSColor(white: 0.08, alpha: 1) : NSColor(white: 0.86, alpha: 1)
        let card = CardView(frame: canvas.bounds)
        card.fill = env.themes.cardBackground(note.color, appearance: appearance)
        canvas.addSubview(card)
        let editor = MarkdownNoteEditor(note: note, env: env)
        card.addSubview(editor)
        editor.frame = NSRect(x: pad + 8, y: pad + 6, width: width, height: 20)

        var window: NSWindow?
        if let caret {
            // Focus needs a window; it is never ordered on screen.
            let w = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: canvas.frame.width, height: 600),
                             styleMask: [.borderless], backing: .buffered, defer: true)
            w.isReleasedWhenClosed = false
            w.appearance = appearance
            w.contentView = canvas
            window = w
            editor.focus(atEnd: false)
            editor.textViewForTesting.setSelectedRange(NSRange(location: caret, length: 0))
        }

        // Let async image / thumbnail loads finish.
        let deadline = Date().addingTimeInterval(4)
        var lastH: CGFloat = -1
        var stable = 0
        while Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
            let h = editor.intrinsicContentSize.height
            if h == lastH { stable += 1 } else { stable = 0; lastH = h }
            if stable >= 6 { break }
        }
        let h = editor.intrinsicContentSize.height
        editor.frame = NSRect(x: pad + 8, y: pad + 6, width: width, height: h)
        canvas.frame.size.height = h + 2 * pad + 12
        card.frame = canvas.bounds
        canvas.layoutSubtreeIfNeeded()

        write(canvas, appearance: appearance, to: url)
        Check.expect(h > 10, "snapshot \(url.lastPathComponent) has height")
        window?.contentView = nil
        window?.close()
    }

    static func write(_ canvas: NSView, appearance: NSAppearance, to url: URL) {
        let scale: CGFloat = 2
        let size = canvas.bounds.size
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return }
        rep.size = size
        appearance.performAsCurrentDrawingAppearance {
            canvas.cacheDisplay(in: canvas.bounds, to: rep)
        }
        if let data = rep.representation(using: .png, properties: [:]) {
            try? data.write(to: url)
        }
    }
}
