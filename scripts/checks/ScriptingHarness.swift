// Runtime check for Cocoa Scripting + the kAEGetURL handler, in-process. Compiled by
// scripts/check-integrations.sh into a stub .app bundle (holds Resources/NoteBar.sdef) and run
// directly from the shell. Activation policy .prohibited: no Dock icon, no menu bar, no windows.
// AppleScripts are sent to `current application` (this process), so no Automation (TCC) prompt.
import AppKit
import NoteBarCore
import NoteBarIntegrations

@MainActor
final class FakeController: AppController {
    let env: AppEnvironment
    var calls: [String] = []
    var visible = false
    init(env: AppEnvironment) { self.env = env }
    var isPanelVisible: Bool { visible }
    func showPanel() { calls.append("show"); visible = true }
    func hidePanel() { calls.append("hide"); visible = false }
    func togglePanel() { calls.append("toggle"); visible.toggle() }
    func createNote(text: String?, folderName: String?, reveal: Bool) -> Note? {
        calls.append("create(reveal:\(reveal))")
        let folder = folderName.map { env.store.folderNamedOrCreate($0) } ?? env.store.folders()[0]
        let note = env.store.createNote(in: folder.id, body: text ?? "", mode: .standard, position: .top)
        if reveal { revealNote(note.id) }
        return note
    }
    func revealNote(_ id: NoteID) { calls.append("reveal(\(id))"); visible = true }
    func showSearch() { calls.append("search"); visible = true }
    func openSettings() { calls.append("settings") }
}

@MainActor
final class Harness: NSObject, NSApplicationDelegate {
    var env: AppEnvironment!
    var controller: FakeController!
    var integrations: IntegrationsController!

    func applicationWillFinishLaunching(_ notification: Notification) {
        let defaults = UserDefaults(suiteName: "NoteBarScriptingHarness")!
        defaults.removePersistentDomain(forName: "NoteBarScriptingHarness")
        let settings = AppSettings(defaults: defaults)
        let store = InMemoryNoteStore(seed: false)
        env = AppEnvironment(store: store, backups: nil, settings: settings,
                             themes: ThemeManager(settings: settings, store: store), editorFactory: PlainNoteEditorFactory())
        controller = FakeController(env: env)
        env.controller = controller
        integrations = IntegrationsController(env: env)
        integrations.install()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Let IntegrationsController mark itself ready (it does so asynchronously after launch).
        DispatchQueue.main.async { DispatchQueue.main.async { MainActor.assumeIsolated { self.run() } } }
    }

    func script(_ source: String) -> NSAppleEventDescriptor? {
        var err: NSDictionary?
        let s = NSAppleScript(source: source)!
        let r = s.executeAndReturnError(&err)
        if let err { print("script error: \(err[NSAppleScript.errorMessage] ?? err)"); return nil }
        return r
    }

    func scriptError(_ source: String) -> Int? {
        var err: NSDictionary?
        _ = NSAppleScript(source: source)!.executeAndReturnError(&err)
        return (err?[NSAppleScript.errorNumber] as? NSNumber)?.intValue
    }

    func run() {
        let store = env.store
        Check.expect(integrations.actions.isReady, "ready after launch")

        // new note with text … in folder … show false → integer id
        let r = script(#"tell current application to «event NBarNewN» given «class NBtx»:"Buy milk", «class NBfd»:"Inbox", «class NBsh»:false"#)
        Check.equal(r?.descriptorType, typeSInt32, "new note returns an integer")
        let id = NoteID(r?.int32Value ?? 0)
        Check.equal(store.note(id: id)?.body, "Buy milk", "note created with text")
        Check.equal(store.note(id: id).flatMap { store.folder(id: $0.folderId)?.name }, "Inbox", "folder created")
        Check.equal(controller.calls.last, "create(reveal:false)", "show false")

        // Direct parameter form, default show = true.
        let r2 = script(#"tell current application to «event NBarNewN» "Direct\nsecond line""#)
        let id2 = NoteID(r2?.int32Value ?? 0)
        Check.equal(store.note(id: id2)?.body, "Direct\nsecond line", "direct parameter text")
        Check.equal(controller.calls.last, "reveal(\(id2))", "show defaults to true")

        // get note text id N / direct
        Check.equal(script("tell current application to «event NBarGtxt» given id:\(id)")?.stringValue, "Buy milk", "get note text id")
        Check.equal(script("tell current application to «event NBarGtxt» \(id2)")?.stringValue, "Direct\nsecond line", "get note text direct")
        Check.equal(scriptError("tell current application to «event NBarGtxt» given id:99999"), -1728, "missing note error")

        // search notes → ids / bodies / titles
        let ids = script(#"tell current application to «event NBarSrch» given «class NBqr»:"MILK""#)
        Check.equal(ids?.numberOfItems, 1, "search result count")
        Check.equal(ids?.atIndex(1)?.int32Value, Int32(id), "search returns ids")
        let bodies = script(#"tell current application to «event NBarSrch» "milk" given «class NBrk»:«constant NBrkNBrb»"#)
        Check.equal(bodies?.atIndex(1)?.stringValue, "Buy milk", "search returning bodies")
        let titles = script(#"tell current application to «event NBarSrch» given «class NBrk»:«constant NBrkNBrt»"#)
        Check.equal(titles?.numberOfItems, 2, "search without query lists all")
        Check.equal(scriptError(#"tell current application to «event NBarSrch» given «class NBqr»:"x", «class NBfd»:"Nope""#), -1728, "unknown folder error")

        // list folders
        let folders = script("tell current application to «event NBarLsFd»")
        let names = (1...max(1, folders?.numberOfItems ?? 0)).compactMap { folders?.atIndex($0)?.stringValue }
        Check.expect(names.contains("Inbox") && names.contains("Notes"), "list folders: \(names)")

        // Panel commands + property
        controller.calls.removeAll()
        _ = script("tell current application to «event NBarShow»")
        Check.equal((NSApp.value(forKey: "notebarPanelVisible") as? Bool), true, "panel visible via KVC")
        // Raw-code form needs "of current application" (else AppleScript returns the bare class constant).
        Check.equal(script("get «class NBpv» of current application")?.booleanValue, true, "panel visible property")
        _ = script("tell current application to «event NBarHide»")
        _ = script("tell current application to «event NBarTogl»")
        _ = script("tell current application to «event NBarRevl» given id:\(id)")
        _ = script("tell current application to «event NBarSett»")
        Check.equal(controller.calls, ["show", "hide", "toggle", "reveal(\(id))", "settings"], "panel commands")

        // Services provider: call the NSMessage selector the way AppKit does.
        let pb = NSPasteboard(name: NSPasteboard.Name("NoteBarHarness-\(ProcessInfo.processInfo.processIdentifier)"))
        pb.clearContents()
        pb.setString("\n\nSelected text\nmore\n", forType: .string)
        typealias ServiceIMP = @convention(c) (AnyObject, Selector, NSPasteboard, NSString?, AutoreleasingUnsafeMutablePointer<NSString?>) -> Void
        let sel = NSSelectorFromString("newNoteFromSelection:userData:error:") // string, as AppKit builds it from NSMessage
        if let provider = NSApp.servicesProvider as AnyObject?, provider.responds(to: sel),
           let imp = provider.method(for: sel) {
            var err: NSString?
            unsafeBitCast(imp, to: ServiceIMP.self)(provider, sel, pb, nil, &err)
            Check.equal(err, nil, "service error")
            Check.equal(store.search("Selected text", in: nil).first?.body, "Selected text\nmore", "service creates trimmed note")
            pb.clearContents()
            unsafeBitCast(imp, to: ServiceIMP.self)(provider, sel, pb, nil, &err)
            Check.expect(err != nil, "empty selection reports an error")
        } else {
            Check.expect(false, "services provider does not respond to newNoteFromSelection:userData:error:")
        }
        pb.releaseGlobally()

        // URL scheme through a real kAEGetURL Apple Event.
        _ = script(#"tell current application to «event GURLGURL» "notebar://new?text=From+URL%20%E2%9C%93&folder=Web&show=0""#)
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                let n = store.search("From URL", in: nil).first
                Check.equal(n?.body, "From URL \u{2713}", "URL event creates note")
                Check.equal(n.flatMap { store.folder(id: $0.folderId)?.name }, "Web", "URL event folder")
                Check.expect(NSApp.value(forKey: "version") != nil, "application version key (sdef Standard Suite)")
                self.expectingQuit = true
                // Standard Suite quit -> applicationWillTerminate -> Check.finish().
                _ = self.script("tell current application to «event aevtquit»")
            }
        }
    }

    var expectingQuit = false
    func applicationWillTerminate(_ notification: Notification) {
        Check.expect(expectingQuit, "unexpected terminate")
        Check.finish()
    }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    app.setActivationPolicy(.prohibited)
    let harness = Harness()
    app.delegate = harness
    // Safety net: never hang.
    DispatchQueue.main.asyncAfter(deadline: .now() + 20) { print("timeout (quit did not terminate?)"); exit(2) }
    withExtendedLifetime(harness) { app.run() }
}
