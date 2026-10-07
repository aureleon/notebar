import AppKit
import NoteBarCore

// STUB — owned by the UI agent. Keep: public final class NotesRootViewController: NSViewController, NotesPresenting { public init(env:) }
@MainActor
public final class NotesRootViewController: NSViewController, NotesPresenting {
    private let env: AppEnvironment
    public init(env: AppEnvironment) { self.env = env; super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { fatalError() }
    public override func loadView() { view = NSView() }
    public var currentFolderId: FolderID? { nil }
    public func showFolderList() {}
    public func showFolder(_ id: FolderID) {}
    public func reveal(noteId: NoteID, edit: Bool) {}
    public func beginSearch() {}
    public func panelDidShow() {}
    public func panelWillHide() {}
}
