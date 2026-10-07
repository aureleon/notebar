import AppKit
import NoteBarCore
import os

let integrationsLog = Logger(subsystem: "local.dhguz.NoteBar", category: "integrations")

/// Errors reported back to URL callers (x-error), AppleScript (error number + message) and Services.
public struct IntegrationError: Error, Equatable, CustomStringConvertible {
    public var code: Int
    public var message: String
    public init(code: Int, message: String) { self.code = code; self.message = message }
    public var description: String { message }

    /// errAENoSuchObject
    public static func notFound(_ what: String) -> IntegrationError { .init(code: -1728, message: "\(what) not found.") }
    /// errAEParamMissed
    public static func missing(_ what: String) -> IntegrationError { .init(code: -1715, message: "Missing \(what).") }
    /// errAEWrongDataType / paramErr style
    public static func invalid(_ what: String) -> IntegrationError { .init(code: -1703, message: "Invalid \(what).") }
    /// errOSAGeneralError
    public static func general(_ msg: String) -> IntegrationError { .init(code: -2700, message: msg) }
}

/// What a search returns to AppleScript.
public enum SearchResultKind: Sendable {
    case identifiers, bodies, titles
}

/// The single place that turns integration requests (URL scheme, Services, AppleScript) into
/// `AppController` / `NoteStore` calls. Everything is main-actor.
///
/// Requests that arrive before the app has finished launching (URL that launched the app,
/// AppleScript sent during launch) are queued with `whenReady` and run right after
/// `applicationDidFinishLaunching` returns, when the panel and notes UI exist.
@MainActor
public final class IntegrationActions {
    /// Set by `IntegrationsController.install()`. Used by the NSScriptCommand subclasses,
    /// which Cocoa Scripting instantiates itself.
    public internal(set) static var current: IntegrationActions?

    public let env: AppEnvironment
    public private(set) var isReady = false
    private var pending: [() -> Void] = []

    public init(env: AppEnvironment) { self.env = env }

    // MARK: Readiness

    /// Runs `work` now if the app is ready, else after launch.
    public func whenReady(_ work: @escaping () -> Void) {
        if isReady { work() } else { pending.append(work) }
    }

    /// Marks the app as ready and drains the queue (in order).
    public func markReady() {
        guard !isReady else { return }
        isReady = true
        let work = pending
        pending.removeAll()
        work.forEach { $0() }
    }

    private var store: NoteStore { env.store }

    // MARK: Panel

    public var isPanelVisible: Bool { env.controller?.isPanelVisible ?? false }
    public func showPanel() { env.controller?.showPanel() }
    public func hidePanel() { env.controller?.hidePanel() }
    public func togglePanel() { env.controller?.togglePanel() }
    public func openSettings() { env.controller?.openSettings() }

    // MARK: Notes

    /// Creates a note. `folder` is created if missing (nil/blank = current or last folder).
    /// `color` / `mode` are raw `NoteColor` / `NoteMode` values; unknown values throw.
    @discardableResult
    public func createNote(text: String?, folder: String?, show: Bool,
                           color: String? = nil, mode: String? = nil) throws -> Note {
        let parsedColor = try color.map { raw -> NoteColor in
            guard let c = NoteColor.parse(raw) else { throw IntegrationError.invalid("color \"\(raw)\"") }
            return c
        }
        let parsedMode = try mode.map { raw -> NoteMode in
            guard let m = NoteMode.parse(raw) else { throw IntegrationError.invalid("mode \"\(raw)\"") }
            return m
        }
        let body = text.map(Self.normalizeNewlines)
        let folderName = folder?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        let needsUpdate = parsedColor != nil || parsedMode != nil

        let created: Note?
        if let controller = env.controller {
            created = controller.createNote(text: body, folderName: folderName, reveal: show && !needsUpdate)
        } else {
            created = createDirectly(text: body, folderName: folderName)
        }
        guard var note = created else { throw IntegrationError.general("Could not create the note.") }

        if needsUpdate {
            if let parsedColor { note.color = parsedColor }
            if let parsedMode { note.mode = parsedMode }
            store.updateNote(note)
            note = store.note(id: note.id) ?? note
            if show { env.controller?.revealNote(note.id) }
        }
        integrationsLog.info("Created note \(note.id) in folder \(note.folderId)")
        return note
    }

    /// Creates a note that holds file shortcuts / images for `urls` (Finder Services).
    @discardableResult
    public func createNote(withFiles urls: [URL], show: Bool) throws -> Note {
        guard !urls.isEmpty else { throw IntegrationError.missing("files") }
        let note = try createNote(text: "", folder: nil, show: false)
        var links: [String] = []
        for url in urls {
            do {
                links.append(AttachmentLink.markdown(for: try store.addAttachment(to: note.id, fileURL: url)))
            } catch {
                integrationsLog.error("Cannot attach \(url.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
        guard !links.isEmpty else {
            store.deleteNote(id: note.id)
            throw IntegrationError.general("Could not add the files to a note.")
        }
        var updated = store.note(id: note.id) ?? note
        updated.body = links.joined(separator: "\n")
        store.updateNote(updated)
        if show { env.controller?.revealNote(note.id) }
        return store.note(id: note.id) ?? updated
    }

    /// Fallback when no AppController is wired (should not happen in the app; used by checks).
    private func createDirectly(text: String?, folderName: String?) -> Note? {
        let folder: Folder
        if let folderName { folder = store.folderNamedOrCreate(folderName) }
        else if let id = env.settings.lastFolderId, let f = store.folder(id: id) { folder = f }
        else if let f = store.folders().first { folder = f }
        else { folder = store.createFolder(name: "Notes") }
        return store.createNote(in: folder.id, body: text ?? "", mode: env.settings.defaultNoteMode, position: .top)
    }

    public func revealNote(id: NoteID) throws {
        guard store.note(id: id) != nil else { throw IntegrationError.notFound("Note \(id)") }
        env.controller?.revealNote(id)
    }

    public func showFolder(named name: String) throws {
        guard let folder = store.folder(named: name) else { throw IntegrationError.notFound("Folder \"\(name)\"") }
        env.controller?.showPanel()
        env.presenter?.showFolder(folder.id)
    }

    /// Opens the panel's search field and types `query` into it.
    public func beginSearch(query: String) {
        env.controller?.showSearch(query: query.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    public func noteText(id: NoteID) throws -> String {
        guard let note = store.note(id: id) else { throw IntegrationError.notFound("Note \(id)") }
        return note.body
    }

    public func folderNames() -> [String] { store.folders().map(\.name) }

    /// Store search. Blank query = all notes (of the folder, or of every folder in list order).
    public func findNotes(query: String, folder: String?) throws -> [Note] {
        var folderId: FolderID?
        if let name = folder?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty {
            guard let f = store.folder(named: name) else { throw IntegrationError.notFound("Folder \"\(name)\"") }
            folderId = f.id
        }
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if q.isEmpty {
            if let folderId { return store.notes(in: folderId) }
            return store.folders().flatMap { store.notes(in: $0.id) }
        }
        return store.search(q, in: folderId)
    }

    // MARK: URL scheme

    /// Runs a parsed URL command. Returns x-success reply parameters.
    @discardableResult
    public func perform(_ command: NoteBarURLCommand) throws -> [(String, String)] {
        switch command {
        case .newNote(let r):
            let note = try createNote(text: r.text, folder: r.folder, show: r.show, color: r.color, mode: r.mode)
            return [("id", String(note.id)), ("folder", store.folder(id: note.folderId)?.name ?? "")]
        case .show: showPanel()
        case .hide: hidePanel()
        case .toggle: togglePanel()
        case .search(let q): beginSearch(query: q)
        case .openNote(let id): try revealNote(id: id)
        case .openFolder(let name): try showFolder(named: name)
        case .settings: openSettings()
        }
        return []
    }

    static func normalizeNewlines(_ s: String) -> String {
        s.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
    }
}

extension NoteColor {
    /// Case-insensitive raw value or display name; "red" = pink, "white"/"default" = none.
    static func parse(_ raw: String) -> NoteColor? {
        let s = raw.trimmingCharacters(in: .whitespaces).lowercased()
        if let c = NoteColor(rawValue: s) { return c }
        switch s {
        case "red": return .pink
        case "white", "default", "": return NoteColor.none
        default: return NoteColor.allCases.first { $0.displayName.lowercased() == s }
        }
    }
}

extension NoteMode {
    /// "standard"/"markdown"/"md", "plain"/"text", "code".
    static func parse(_ raw: String) -> NoteMode? {
        let s = raw.trimmingCharacters(in: .whitespaces).lowercased()
        if let m = NoteMode(rawValue: s) { return m }
        switch s {
        case "markdown", "md", "rich": return .standard
        case "text", "plaintext", "plain text", "txt": return .plain
        case "monospace", "mono": return .code
        default: return nil
        }
    }
}
