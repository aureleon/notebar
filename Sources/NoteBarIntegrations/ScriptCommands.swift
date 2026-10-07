import AppKit
import NoteBarCore

// AppleScript commands. Each class is referenced by name from Resources/NoteBar.sdef
// (`<cocoa class="NBxxxCommand"/>`), so the @objc names must not change.
// Argument keys are the `<cocoa key="…"/>` values in the sdef.
//
// Cocoa Scripting runs commands on the main thread. If a command arrives before the app has
// finished launching, it is suspended and resumed once the UI exists.

enum ScriptKey {
    static let text = "Text"
    static let folder = "Folder"
    static let show = "Show"
    static let query = "Query"
    static let kind = "ResultKind"
    static let noteID = "NoteID"
}

/// FourCharCodes of the `search result kind` enumerators in the sdef.
enum ScriptEnum {
    static let identifiers = fourCC("NBri")
    static let bodies = fourCC("NBrb")
    static let titles = fourCC("NBrt")

    static func fourCC(_ s: String) -> UInt32 { s.utf8.reduce(0) { $0 << 8 | UInt32($1) } }
}

@objc(NBScriptCommand)
class NBScriptCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        MainActor.assumeIsolated {
            guard let actions = IntegrationActions.current else {
                fail(.general("NoteBar integrations are not installed."))
                return nil
            }
            if actions.isReady { return execute(actions) }
            suspendExecution()
            actions.whenReady { [self] in resumeExecution(withResult: execute(actions)) }
            return nil
        }
    }

    /// Subclasses implement the command. Throw `IntegrationError` to report a script error.
    @MainActor func run(_ actions: IntegrationActions) throws -> Any? { nil }

    @MainActor private func execute(_ actions: IntegrationActions) -> Any? {
        do {
            return try run(actions)
        } catch let e as IntegrationError {
            fail(e)
        } catch {
            fail(.general(error.localizedDescription))
        }
        return nil
    }

    private func fail(_ e: IntegrationError) {
        scriptErrorNumber = e.code
        scriptErrorString = e.message
    }

    // MARK: Argument helpers

    func string(_ key: String) -> String? {
        switch evaluatedArguments?[key] {
        case let s as String: s
        case let n as NSNumber: n.stringValue
        case let a as NSAttributedString: a.string
        default: nil
        }
    }

    func bool(_ key: String) -> Bool? { (evaluatedArguments?[key] as? NSNumber)?.boolValue }

    func uint32(_ key: String) -> UInt32? { (evaluatedArguments?[key] as? NSNumber)?.uint32Value }

    /// Direct parameter as text (`new note "…"`, `search notes "…"`).
    var directString: String? {
        switch directParameter {
        case let s as String: s
        case let n as NSNumber: n.stringValue
        case let a as NSAttributedString: a.string
        case let d as NSAppleEventDescriptor: d.stringValue
        default: nil
        }
    }

    /// Note id from `id N` or the direct parameter (`get note text 5`).
    func noteID() throws -> NoteID {
        let raw: Any? = evaluatedArguments?[ScriptKey.noteID] ?? directParameter
        switch raw {
        case let n as NSNumber where n.int64Value > 0: return n.int64Value
        case let s as String:
            if let v = Int64(s.trimmingCharacters(in: .whitespaces)), v > 0 { return v }
            throw IntegrationError.invalid("note id \"\(s)\"")
        case nil: throw IntegrationError.missing("note id (use: id 42)")
        default: throw IntegrationError.invalid("note id")
        }
    }

    static func scriptInteger(_ id: NoteID) -> NSNumber {
        id <= Int64(Int32.max) ? NSNumber(value: Int32(id)) : NSNumber(value: Double(id))
    }

    static func scriptIntegerDescriptor(_ id: NoteID) -> NSAppleEventDescriptor {
        id <= Int64(Int32.max) ? NSAppleEventDescriptor(int32: Int32(id)) : NSAppleEventDescriptor(double: Double(id))
    }
}

/// `new note [with text "…"] [in folder "…"] [show boolean]` → note id (integer).
/// The text may also be the direct parameter: `new note "Buy milk"`.
@objc(NBNewNoteCommand)
final class NBNewNoteCommand: NBScriptCommand {
    override func run(_ actions: IntegrationActions) throws -> Any? {
        let text = string(ScriptKey.text) ?? directString
        let note = try actions.createNote(text: text, folder: string(ScriptKey.folder), show: bool(ScriptKey.show) ?? true)
        return Self.scriptInteger(note.id)
    }
}

/// `show notebar`
@objc(NBShowCommand)
final class NBShowCommand: NBScriptCommand {
    override func run(_ actions: IntegrationActions) throws -> Any? { actions.showPanel(); return nil }
}

/// `hide notebar`
@objc(NBHideCommand)
final class NBHideCommand: NBScriptCommand {
    override func run(_ actions: IntegrationActions) throws -> Any? { actions.hidePanel(); return nil }
}

/// `toggle notebar`
@objc(NBToggleCommand)
final class NBToggleCommand: NBScriptCommand {
    override func run(_ actions: IntegrationActions) throws -> Any? { actions.togglePanel(); return nil }
}

/// `search notes for "…" [in folder "…"] [returning identifiers|bodies|titles]` → list.
/// `search notes` with no query lists every note. Does not touch the UI.
@objc(NBSearchNotesCommand)
final class NBSearchNotesCommand: NBScriptCommand {
    override func run(_ actions: IntegrationActions) throws -> Any? {
        let query = string(ScriptKey.query) ?? directString ?? ""
        let notes = try actions.findNotes(query: query, folder: string(ScriptKey.folder))
        // Built as a descriptor: Cocoa Scripting cannot coerce Swift arrays to the sdef type "any".
        let items: [NSAppleEventDescriptor]
        switch uint32(ScriptKey.kind) ?? ScriptEnum.identifiers {
        case ScriptEnum.bodies: items = notes.map { NSAppleEventDescriptor(string: $0.body) }
        case ScriptEnum.titles: items = notes.map { NSAppleEventDescriptor(string: $0.title) }
        default: items = notes.map { Self.scriptIntegerDescriptor($0.id) }
        }
        let list = NSAppleEventDescriptor.list()
        for (i, item) in items.enumerated() { list.insert(item, at: i + 1) }
        return list
    }
}

/// `get note text id N` → the note's markdown body.
@objc(NBGetNoteTextCommand)
final class NBGetNoteTextCommand: NBScriptCommand {
    override func run(_ actions: IntegrationActions) throws -> Any? { try actions.noteText(id: try noteID()) }
}

/// `reveal note id N` → shows the panel and focuses the note.
@objc(NBRevealNoteCommand)
final class NBRevealNoteCommand: NBScriptCommand {
    override func run(_ actions: IntegrationActions) throws -> Any? { try actions.revealNote(id: try noteID()); return nil }
}

/// `list folders` → folder names in panel order.
@objc(NBListFoldersCommand)
final class NBListFoldersCommand: NBScriptCommand {
    override func run(_ actions: IntegrationActions) throws -> Any? { actions.folderNames() }
}

/// `search notebar [for "…"]` → opens the panel's search field (UI), optionally with a query.
@objc(NBOpenSearchCommand)
final class NBOpenSearchCommand: NBScriptCommand {
    override func run(_ actions: IntegrationActions) throws -> Any? {
        actions.beginSearch(query: string(ScriptKey.query) ?? directString ?? "")
        return nil
    }
}

/// `open notebar settings`
@objc(NBOpenSettingsCommand)
final class NBOpenSettingsCommand: NBScriptCommand {
    override func run(_ actions: IntegrationActions) throws -> Any? { actions.openSettings(); return nil }
}

extension NSApplication {
    /// AppleScript `panel visible` property of the application (sdef cocoa key "notebarPanelVisible").
    @objc var notebarPanelVisible: Bool { IntegrationActions.current?.isPanelVisible ?? false }
}

enum ScriptCommandClasses {
    /// Touches every command class so the Objective-C runtime has realized them before Cocoa
    /// Scripting looks them up by name (`NSClassFromString`).
    static let all: [AnyClass] = [
        NBNewNoteCommand.self, NBShowCommand.self, NBHideCommand.self, NBToggleCommand.self,
        NBSearchNotesCommand.self, NBGetNoteTextCommand.self, NBRevealNoteCommand.self,
        NBListFoldersCommand.self, NBOpenSearchCommand.self, NBOpenSettingsCommand.self,
    ]
}
