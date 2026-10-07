import AppKit
import NoteBarCore
import NoteBarUI

// Owned by the UI agent. Renders the notes UI offscreen (no window on screen) to PNGs.
// Usage: swift run UISnapshot /tmp/nb-snap
MainActor.assumeIsolated {
    _ = NSApplication.shared
    let out = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "/tmp/nb-snap")
    try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
    let store = InMemoryNoteStore(seed: true)
    let settings = AppSettings(defaults: UserDefaults(suiteName: "NoteBarSnapshot")!)
    let env = AppEnvironment(store: store, backups: nil, settings: settings,
                             themes: ThemeManager(settings: settings, store: store), editorFactory: PlainNoteEditorFactory())
    let vc = NotesRootViewController(env: env)
    vc.view.frame = NSRect(x: 0, y: 0, width: 300, height: 700)
    func render(_ name: String, appearance: NSAppearance.Name) {
        vc.view.appearance = NSAppearance(named: appearance)
        vc.view.layoutSubtreeIfNeeded()
        guard let rep = vc.view.bitmapImageRepForCachingDisplay(in: vc.view.bounds) else { return }
        vc.view.cacheDisplay(in: vc.view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: out.appendingPathComponent(name + ".png"))
    }
    render("folders-light", appearance: .aqua)
    vc.showFolder(store.folders()[0].id)
    render("notes-light", appearance: .aqua)
    render("notes-dark", appearance: .darkAqua)
    print("Wrote snapshots to \(out.path)")
}
