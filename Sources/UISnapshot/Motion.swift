import AppKit
import NoteBarCore
import NoteBarUI

// `swift run UISnapshot --motion /tmp/out`: runs list animations with real glass and checks that the
// backdrop moves together with the cards. Animations run only in a window the window server has, so
// this mode orders a window in, far outside every display: nothing shows on the screen.
// For each scenario it samples what is on screen (presentation layers) every frame and writes a strip
// of captured frames to `<out>/motion-<name>.png`.

/// Window image from the window server (own windows need no screen recording permission).
/// `CGWindowListCreateImage` is not in the SDK any more, so it is looked up at run time.
private func captureWindow(_ number: Int) -> CGImage? {
    typealias Fn = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
    guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage") else { return nil }
    // .optionIncludingWindow, .boundsIgnoreFraming | .nominalResolution
    return unsafeBitCast(sym, to: Fn.self)(.null, 1 << 3, UInt32(number), 1 | 1 << 4)?.takeRetainedValue()
}

/// Bottom edges (points from the top) of the backdrop and of the lowest card in a captured frame, read
/// from one pixel column over a white window: white, then the backdrop's color, then the card's.
private func edges(in image: CGImage, x: Int) -> (backdrop: Int, card: Int)? {
    let w = image.width, h = image.height
    var px = [UInt8](repeating: 0, count: w * h * 4)
    guard let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                              space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
    func level(_ y: Int) -> Int { Int(px[(y * w + x) * 4]) }   // row 0 is the top
    var y = h - 1
    while y >= 0, level(y) > 200 { y -= 1 }
    guard y >= 8 else { return nil }
    let backdropBottom = y + 1
    let ref = level(y - 2)
    var c = y - 2
    while c >= 0, abs(level(c) - ref) <= 1 { c -= 1 }
    return (backdropBottom, c + 1)
}

@MainActor
func runMotionChecks() -> Never {
    let out = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first(where: { !$0.hasPrefix("--") }) ?? "/tmp/nb-motion")
    try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
    ModalSupport.testResponder = { _ in .cancel }
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    NoteBarUIOptions.useGlass = true
    NoteBarUIOptions.animations = true

    let suite = "NoteBarUIMotion"
    UserDefaults().removePersistentDomain(forName: suite)
    let settings = AppSettings(defaults: UserDefaults(suiteName: suite)!)
    settings.blurBackdrop = true
    let store = InMemoryNoteStore(seed: false)
    let folders = seed(store)
    let themes = ThemeManager(settings: settings, store: store)
    let env = AppEnvironment(store: store, backups: nil, settings: settings, themes: themes,
                             editorFactory: PlainNoteEditorFactory())
    let vc = NotesRootViewController(env: env)
    vc.stateDefaults = UserDefaults(suiteName: suite)!
    env.presenter = vc
    let probe = vc.probe

    let verbose = CommandLine.arguments.contains("--verbose")
    let size = NSSize(width: 410, height: 720)
    let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: -20000, y: -20000), size: size),
                          styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.isOpaque = false
    window.backgroundColor = .white
    window.appearance = NSAppearance(named: .darkAqua)
    vc.view.frame = NSRect(origin: .zero, size: size)
    window.contentView = vc.view
    window.orderFrontRegardless()
    Check.expect(NSScreen.screens.allSatisfy { !$0.frame.intersects(window.frame) }, "the motion window is outside every display")

    @MainActor func run(_ seconds: TimeInterval) { RunLoop.current.run(until: Date().addingTimeInterval(seconds)) }
    @MainActor func settle() { probe.layoutNow(); run(0.6); probe.layoutNow(); run(0.1) }

    /// Runs `action`, then follows the screen for 0.5 s. Cards and backdrop must stay together:
    /// the backdrop's bottom edge `outerMargin` (6 pt) below the lowest card's, in every frame.
    /// `fadesIn`: a card comes in by opacity at its final place; the backdrop is there at once (the
    /// captured frames cannot see a faint card's edge, so only the layer values are checked).
    @MainActor func scenario(_ name: String, fadesIn: Bool = false, moves: Bool = true, _ action: () -> Void) {
        settle()
        var frames: [CGImage] = []
        var worst: CGFloat = 0
        var worstGlass: CGFloat = 0
        var moved: CGFloat = 0
        var log: [String] = []
        var shown: [String] = []
        var worstShown: CGFloat = 0
        let start = Date()
        let first = probe.motionSample()
        action()
        var nextShot = 0.0
        while true {
            // First the end of the run loop turn the action ran in: layers get their frames there.
            run(1.0 / 120)
            let t = Date().timeIntervalSince(start)
            if t > 0.5 { break }
            if let s = probe.motionSample() {
                // A card that runs past the panel bottom is cut `outerMargin` above the backdrop's edge.
                let cardEdge = min(s.card, size.height - 6)
                let gap = s.backdrop - cardEdge
                worst = max(worst, abs(gap - 6))
                // The glass is the card's, and never below the line the list is cut at.
                if let g = s.glass { worstGlass = max(worstGlass, s.card <= size.height - 6 ? abs(g - cardEdge) : g - cardEdge) }
                if let first { moved = max(moved, abs(s.backdrop - first.backdrop)) }
                log.append(String(format: "%3.0f ms  card %6.1f  glass %6.1f  backdrop %6.1f  gap %5.1f  scroll %6.1f", t * 1000, s.card, s.glass ?? -1, s.backdrop, gap, probe.listScrollOffset))
            }
            if let img = captureWindow(window.windowNumber) {
                // What the window server shows: the truth for "together on the screen".
                if let e = edges(in: img, x: 300), e.backdrop < Int(size.height) - 1 {
                    let off = abs(CGFloat(e.backdrop - e.card) - 6)
                    worstShown = max(worstShown, off)
                    shown.append(String(format: "%3.0f ms  card %4d  backdrop %4d  gap %3d", t * 1000, e.card, e.backdrop, e.backdrop - e.card))
                }
                if t >= nextShot, frames.count < 6 { frames.append(img); nextShot += 0.05 }
            }
        }
        print("— \(name)")
        if verbose {
            for line in log { print("   layers " + line) }
            for line in shown { print("   shown  " + line) }
        }
        if moves { Check.expect(moved > 20, "\(name): the backdrop changes height (moved \(Int(moved)) pt)") }
        Check.expect(worst <= 1.5, "\(name): the backdrop is at the cards in every frame (worst offset \(String(format: "%.1f", worst)) pt)")
        if !fadesIn {
            Check.expect(worstShown <= 2, "\(name): backdrop and cards are together in the captured frames (worst offset \(Int(worstShown)) pt, \(shown.count) frames)")
        }
        Check.expect(worstGlass <= 1.5, "\(name): the glass stays with its card, inside the backdrop (worst offset \(String(format: "%.1f", worstGlass)) pt)")
        // Strip of frames, 50 ms apart.
        guard let f0 = frames.first else { Check.expect(false, "\(name): no frames captured"); return }
        let w = f0.width, h = f0.height
        guard let ctx = CGContext(data: nil, width: w * frames.count, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        for (i, f) in frames.enumerated() { ctx.draw(f, in: CGRect(x: i * w, y: 0, width: w, height: h)) }
        if let strip = ctx.makeImage(), let data = NSBitmapImageRep(cgImage: strip).representation(using: .png, properties: [:]) {
            try? data.write(to: out.appendingPathComponent("motion-\(name).png"))
        }
    }

    // A folder with two short notes: the content is shorter than the panel.
    let f = store.createFolder(name: "Motion")
    let a = store.createNote(in: f.id, body: "First\nline\nline\nline\nline\nline\nline\nline", mode: .standard, position: .bottom)
    let b = store.createNote(in: f.id, body: "Second\nline\nline\nline\nline\nline\nline\nline", mode: .standard, position: .bottom)
    vc.showFolder(f.id)

    scenario("fold") { probe.setFolded(true, b.id) }
    scenario("unfold") { probe.setFolded(false, b.id) }
    scenario("fold-first") { probe.setFolded(true, a.id) }
    scenario("unfold-first") { probe.setFolded(false, a.id) }
    scenario("expand") { probe.toggleExpand(b.id) }
    scenario("collapse") { probe.toggleExpand(b.id) }
    scenario("grow-text") {
        store.updateNoteBody(id: b.id, body: "Second" + String(repeating: "\nline", count: 14))
        if let n = store.note(id: b.id) { probe.editor(of: b.id)?.apply(note: n) }
        probe.layoutNow()
    }
    scenario("shrink-text") {
        store.updateNoteBody(id: b.id, body: "Second\nline")
        if let n = store.note(id: b.id) { probe.editor(of: b.id)?.apply(note: n) }
        probe.layoutNow()
    }
    scenario("delete") { probe.deleteWithUndo(b.id) }
    scenario("undo-delete", fadesIn: true) { probe.undoDelete() }
    scenario("delete-first") { probe.deleteWithUndo(a.id) }
    scenario("undo-delete-first", fadesIn: true) { probe.undoDelete() }
    scenario("new-note", fadesIn: true) { probe.createNewNote() }
    scenario("move-to-top", moves: false) { probe.moveToTop(b.id) }
    scenario("to-long-folder") { vc.showFolder(folders.notes.id) }
    // A list taller than the panel: the backdrop has the full height, a card at the bottom edge is cut.
    if let last = probe.displayedNoteIDs.last {
        scenario("long-expand-last", moves: false) { probe.toggleExpand(last) }
        scenario("long-collapse-last", moves: false) { probe.toggleExpand(last) }
    }
    if let first = probe.displayedNoteIDs.first {
        scenario("long-expand-first", moves: false) { probe.toggleExpand(first) }
        scenario("long-collapse-first", moves: false) { probe.toggleExpand(first) }
    }
    scenario("to-short-folder") { vc.showFolder(f.id) }

    window.orderOut(nil)
    Check.finish()
}
