import AppKit
import NoteBarCore

// STUB — owned by the Editor agent. Keep: public final class MarkdownEditorFactory: NoteEditorFactory { public init() }
@MainActor
public final class MarkdownEditorFactory: NoteEditorFactory {
    public init() {}
    public func makeEditor(for note: Note, env: AppEnvironment) -> any NoteEditing { PlainNoteEditor(note: note, env: env) }
}
