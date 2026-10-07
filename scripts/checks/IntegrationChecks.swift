// Checks for NoteBarIntegrations. Compiled and run by scripts/check-integrations.sh
// (there is no XCTest and no test target for this module). Does not show any window.
import AppKit
import NoteBarCore
import NoteBarIntegrations

// MARK: - Fake app controller (records calls, creates notes like the real AppDelegate)

@MainActor
final class FakeController: AppController {
    let env: AppEnvironment
    var calls: [String] = []
    var visible = false
    var currentFolder: FolderID?

    init(env: AppEnvironment) { self.env = env }

    var isPanelVisible: Bool { visible }
    func showPanel() { calls.append("show"); visible = true }
    func hidePanel() { calls.append("hide"); visible = false }
    func togglePanel() { calls.append("toggle"); visible.toggle() }

    func createNote(text: String?, folderName: String?, reveal: Bool) -> Note? {
        calls.append("create(reveal:\(reveal))")
        let store = env.store
        let folder: Folder
        if let folderName, !folderName.isEmpty { folder = store.folderNamedOrCreate(folderName) }
        else if let id = currentFolder, let f = store.folder(id: id) { folder = f }
        else { folder = store.folders()[0] }
        let note = store.createNote(in: folder.id, body: text ?? "", mode: env.settings.defaultNoteMode, position: .top)
        if reveal { revealNote(note.id) }
        return note
    }

    func revealNote(_ id: NoteID) { calls.append("reveal(\(id))"); visible = true }
    func showSearch() { calls.append("search"); visible = true }
    func openSettings() { calls.append("settings") }
}

func parse(_ s: String) -> NoteBarURLCommand? {
    if case .success(let p) = NoteBarURLParser.parse(s) { return p.command }
    return nil
}

func parseError(_ s: String) -> NoteBarURLError? {
    if case .failure(let e) = NoteBarURLParser.parse(s) { return e }
    return nil
}

@MainActor
func runChecks() {
    // MARK: Decoding
    Check.equal(NoteBarURLParser.decodeComponent("a+b%20c"), "a b c", "plus and %20")
    Check.equal(NoteBarURLParser.decodeComponent("%E2%9C%93%20done"), "\u{2713} done", "UTF-8 escapes")
    Check.equal(NoteBarURLParser.decodeComponent("100%"), "100%", "stray percent at end")
    Check.equal(NoteBarURLParser.decodeComponent("50%zz"), "50%zz", "invalid escape kept")
    Check.equal(NoteBarURLParser.decodeComponent("%2B1"), "+1", "encoded plus stays plus")
    Check.equal(NoteBarURLParser.decodeComponent("line1%0Aline2"), "line1\nline2", "newline")
    Check.equal(NoteBarURLParser.decodeComponent("%FF"), "\u{FFFD}", "invalid UTF-8 becomes U+FFFD")
    Check.equal(NoteBarURLParser.decodeComponent("caf\u{E9}"), "caf\u{E9}", "raw unicode kept")

    // MARK: Parsing
    Check.equal(parse("notebar://new?text=Buy+milk&folder=Inbox&show=0"),
                .newNote(NewNoteRequest(text: "Buy milk", folder: "Inbox", show: false)), "new full")
    Check.equal(parse("notebar://new"), .newNote(NewNoteRequest()), "new empty, show defaults to true")
    Check.equal(parse("NOTEBAR://New?Text=Hi"), .newNote(NewNoteRequest(text: "Hi")), "case-insensitive scheme/action/keys")
    Check.equal(parse("notebar:new?text=x"), .newNote(NewNoteRequest(text: "x")), "no slashes")
    Check.equal(parse("notebar:///new?text=x"), .newNote(NewNoteRequest(text: "x")), "three slashes")
    Check.equal(parse("notebar://x-callback-url/new?text=x&x-success=foo://ok"), .newNote(NewNoteRequest(text: "x")), "x-callback-url host")
    Check.equal(parse("notebar://new/?text=x"), .newNote(NewNoteRequest(text: "x")), "trailing slash")
    Check.equal(parse("notebar://new?text=Color #ff0000 #tag"), .newNote(NewNoteRequest(text: "Color #ff0000 #tag")), "# is literal text")
    Check.equal(parse("notebar://new?text=a=b&show=yes"), .newNote(NewNoteRequest(text: "a=b", show: true)), "= inside value")
    Check.equal(parse("notebar://new?text=x&show=false"), .newNote(NewNoteRequest(text: "x", show: false)), "show=false")
    Check.equal(parse("notebar://new?text=x&show"), .newNote(NewNoteRequest(text: "x", show: true)), "bare show")
    Check.equal(parse("notebar://new?folder=%20%20"), .newNote(NewNoteRequest()), "blank folder = default")
    Check.equal(parse("notebar://new?text=x&color=Yellow&mode=code"),
                .newNote(NewNoteRequest(text: "x", color: "yellow", mode: "code")), "color + mode")
    Check.equal(parseError("notebar://new?show=maybe"), .invalidParameter(name: "show", value: "maybe"), "bad show")
    Check.equal(parse("  notebar://show \n"), .show, "whitespace trimmed")
    Check.equal(parse("notebar://hide"), .hide, "hide")
    Check.equal(parse("notebar://toggle"), .toggle, "toggle")
    Check.equal(parse("notebar://search?q=foo+bar"), .search(query: "foo bar"), "search")
    Check.equal(parse("notebar://search"), .search(query: ""), "search without query")
    Check.equal(parse("notebar://open?note=42"), .openNote(id: 42), "open note")
    Check.equal(parse("notebar://open/42"), .openNote(id: 42), "open note path form")
    Check.equal(parse("notebar://open?folder=Work"), .openFolder(name: "Work"), "open folder")
    Check.equal(parse("notebar://open"), .show, "open without args = show")
    Check.equal(parseError("notebar://open?note=abc"), .invalidParameter(name: "note", value: "abc"), "bad id")
    Check.equal(parseError("notebar://open?note=-3"), .invalidParameter(name: "note", value: "-3"), "negative id")
    Check.equal(parse("notebar://settings"), .settings, "settings")
    Check.equal(parseError("notebar://frobnicate"), .unknownAction("frobnicate"), "unknown action")
    Check.equal(parseError("notebar://"), .unknownAction(""), "missing action")
    Check.equal(parseError("https://example.com"), .notNoteBarURL, "other scheme")
    if case .success(let p) = NoteBarURLParser.parse("notebar://new?text=x&x-success=app%3A%2F%2Fok&x-error=app://err") {
        Check.equal(p.successURL, "app://ok", "x-success decoded")
        Check.equal(p.errorURL, "app://err", "x-error")
    } else { Check.expect(false, "x-callback parse") }

    // MARK: Encoding
    Check.equal(NoteBarURLParser.encodeComponent("a b&c=d/\u{E9}"), "a%20b%26c%3Dd%2F%C3%A9", "encode")
    Check.equal(NoteBarURLParser.decodeComponent(NoteBarURLParser.encodeComponent("Ünïcødé + 100% #x\n")), "Ünïcødé + 100% #x\n", "round trip")
    Check.equal(NoteBarURLParser.appendingQuery("app://cb", [("id", "5")]), "app://cb?id=5", "append to bare")
    Check.equal(NoteBarURLParser.appendingQuery("app://cb?x=1", [("id", "5")]), "app://cb?x=1&id=5", "append to query")

    // MARK: Action layer
    let defaults = UserDefaults(suiteName: "NoteBarIntegrationChecks-\(ProcessInfo.processInfo.processIdentifier)")!
    let settings = AppSettings(defaults: defaults)
    let store = InMemoryNoteStore(seed: false)
    let env = AppEnvironment(store: store, backups: nil, settings: settings,
                             themes: ThemeManager(settings: settings, store: store), editorFactory: PlainNoteEditorFactory())
    let controller = FakeController(env: env)
    env.controller = controller
    let integrations = IntegrationsController(env: env)
    let actions = integrations.actions

    // Requests before launch finished are queued.
    integrations.handleURL("notebar://new?text=Early&show=0")
    Check.equal(store.search("Early", in: nil).count, 0, "queued before ready")
    actions.markReady()
    Check.equal(store.search("Early", in: nil).count, 1, "drained after ready")

    integrations.handleURL("notebar://new?text=Hello%0Aworld&folder=Inbox")
    let inbox = store.folder(named: "inbox")
    Check.expect(inbox != nil, "folder created on demand (case-insensitive lookup)")
    if let inbox {
        Check.equal(store.notes(in: inbox.id).map(\.body), ["Hello\nworld"], "note body in Inbox")
    }
    Check.equal(controller.calls.last.map { $0.hasPrefix("reveal(") }, true, "show defaults to reveal")

    integrations.handleURL("notebar://new?text=Again&folder=INBOX&show=0")
    Check.equal(store.folders().filter { $0.name.lowercased() == "inbox" }.count, 1, "existing folder reused")
    Check.equal(controller.calls.last, "create(reveal:false)", "show=0 does not reveal")

    integrations.handleURL("notebar://new?text=Windows%0D%0Aline&show=0")
    Check.equal(store.search("Windows", in: nil).first?.body, "Windows\nline", "CRLF normalized")

    integrations.handleURL("notebar://new?text=Tinted&color=yellow&mode=code&show=0")
    let tinted = store.search("Tinted", in: nil).first
    Check.equal(tinted?.color, .yellow, "color applied")
    Check.equal(tinted?.mode, .code, "mode applied")
    let before = store.search("Bad", in: nil).count
    integrations.handleURL("notebar://new?text=Bad&color=chartreuse&show=0")
    Check.equal(store.search("Bad", in: nil).count, before, "invalid color creates nothing")

    controller.calls.removeAll()
    integrations.handleURL("notebar://show")
    integrations.handleURL("notebar://hide")
    integrations.handleURL("notebar://toggle")
    integrations.handleURL("notebar://settings")
    integrations.handleURL("notebar://search")
    Check.equal(controller.calls, ["show", "hide", "toggle", "settings", "search"], "panel commands")

    controller.calls.removeAll()
    let target = store.search("Again", in: nil).first!
    integrations.handleURL("notebar://open?note=\(target.id)")
    Check.equal(controller.calls, ["reveal(\(target.id))"], "open note reveals it")
    controller.calls.removeAll()
    integrations.handleURL("notebar://open?note=999999")
    Check.equal(controller.calls, [], "unknown note id does nothing")

    // AppleScript-facing helpers.
    Check.expect(actions.folderNames().contains("Inbox"), "folder names")
    Check.equal(Set(try! actions.findNotes(query: "again", folder: nil).map(\.id)), [target.id], "find case-insensitive")
    Check.equal(try! actions.findNotes(query: "", folder: "Inbox").count, 2, "blank query lists folder")
    Check.equal(try! actions.findNotes(query: "", folder: nil).count, store.folders().map { store.noteCount(in: $0.id) }.reduce(0, +), "blank query lists all")
    Check.expect((try? actions.findNotes(query: "x", folder: "Nope")) == nil, "unknown folder throws")
    Check.equal(try! actions.noteText(id: target.id), "Again", "note text")
    do { _ = try actions.noteText(id: 424242); Check.expect(false, "missing note should throw") }
    catch let e as IntegrationError { Check.equal(e.code, -1728, "errAENoSuchObject") }
    catch { Check.expect(false, "wrong error type") }

    // Direct creation without a controller (fallback path).
    env.controller = nil
    let direct = try? actions.createNote(text: "No controller", folder: "Fresh", show: true)
    Check.equal(direct.flatMap { store.folder(id: $0.folderId)?.name }, "Fresh", "fallback creates folder")
    env.controller = controller

    defaults.removePersistentDomain(forName: "NoteBarIntegrationChecks-\(ProcessInfo.processInfo.processIdentifier)")
}

MainActor.assumeIsolated { runChecks() }
Check.finish()
