import AppKit
import NoteBarCore

/// Creates `MarkdownNoteEditor`s. Wire with `AppEnvironment(..., editorFactory: MarkdownEditorFactory())`.
@MainActor
public final class MarkdownEditorFactory: NoteEditorFactory {
    public init() {}

    public func makeEditor(for note: Note, env: AppEnvironment) -> any NoteEditing {
        MarkdownNoteEditor(note: note, env: env)
    }
}
