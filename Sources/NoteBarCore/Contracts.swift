import AppKit

/// Formatting commands (formatting toolbar, keyboard shortcuts, menus).
public enum FormatAction: String, CaseIterable, Sendable {
    case copy, bulletList, checklist, numberedList, textColor, heading
    case bold, italic, highlight, strikethrough, underline, link
    case inlineCode, codeBlock, quote, clearFormatting
}

/// Events the editor sends to its host (the note card).
public enum EditorEvent: Sendable {
    /// Escape pressed.
    case escape
    /// Up arrow on the first line / down arrow on the last line: move focus to the previous/next card.
    case focusPrevious, focusNext
    /// ⌘↩ or similar "done editing".
    case commit
}

/// One editable note body. Created by a `NoteEditorFactory`, hosted inside a note card by NoteBarUI.
///
/// Layout contract: the editor uses Auto Layout. The host constrains its width; the editor reports its
/// height through `intrinsicContentSize.height` (text height at the current width, no internal
/// scrolling) and calls `onLayoutChange` whenever it changes.
@MainActor
public protocol NoteEditing: NSView {
    var noteID: NoteID { get }
    /// Called on every user edit with the full markdown body. Host forwards to `store.updateNoteBody`.
    var onBodyChange: ((String) -> Void)? { get set }
    var onLayoutChange: (() -> Void)? { get set }
    var onFocusChange: ((Bool) -> Void)? { get set }
    var onEvent: ((EditorEvent) -> Void)? { get set }
    /// Apply an external change (mode, color, or body changed elsewhere). Must not reset the caret
    /// if `note.body` equals the current text.
    func apply(note: Note)
    func focus(atEnd: Bool)
    var isEditingFocused: Bool { get }
    func perform(_ action: FormatAction)
    /// Insert attachment tokens at the caret (or at the end if not focused) and render them.
    func insertAttachments(_ attachments: [Attachment])
    /// Marks every match of `query` in the text (search results). Empty = clear. Does not move the
    /// selection or scroll.
    func highlightSearch(_ query: String)
    /// Scrolls to the first marked match and shows the find indicator. Call only on the first result.
    func revealFirstSearchMatch()
}

@MainActor
public protocol NoteEditorFactory: AnyObject {
    func makeEditor(for note: Note, env: AppEnvironment) -> any NoteEditing
}

/// Implemented by the app delegate. Any module may call it via `env.controller`.
@MainActor
public protocol AppController: AnyObject {
    var isPanelVisible: Bool { get }
    func showPanel()
    func hidePanel()
    func togglePanel()
    /// Creates a note. `folderName == nil` uses the current/last folder (or the first folder).
    /// `reveal` shows the panel and focuses the new note.
    @discardableResult func createNote(text: String?, folderName: String?, reveal: Bool) -> Note?
    func revealNote(_ id: NoteID)
    func showSearch()
    /// Shows the panel with the search field filled with `query` (blank = like `showSearch()`).
    func showSearch(query: String)
    func toggleFloatPanel()
    func openSettings()
}

public extension AppController {
    func showSearch(query: String) { showSearch() }
    func toggleFloatPanel() {}
}

/// Implemented by the notes UI (NoteBarUI.NotesRootViewController).
@MainActor
public protocol NotesPresenting: AnyObject {
    /// nil = folder list.
    var currentFolderId: FolderID? { get }
    /// Height of the visible content elements from the top down (header to last item).
    var contentHeight: CGFloat { get }
    func showFolderList()
    func showFolder(_ id: FolderID)
    /// Scrolls to the note (switching folder if needed). `edit` focuses its editor.
    func reveal(noteId: NoteID, edit: Bool)
    func beginSearch()
    /// Starts search with `query` already typed into the search field (blank = like `beginSearch()`).
    func beginSearch(query: String)
    /// Called by the panel right after it slides in / before it slides out.
    func panelDidShow()
    func panelDidShow(focused: Bool)
    func panelFocusChanged(_ focused: Bool)
    func panelWillHide()
}

public extension NotesPresenting {
    var contentHeight: CGFloat { 0 }
    func beginSearch(query: String) { beginSearch() }
    func panelDidShow(focused: Bool) { panelDidShow() }
    func panelFocusChanged(_ focused: Bool) {}
}

/// Shared services. Created once by the app delegate and passed to every module.
@MainActor
public final class AppEnvironment {
    public let store: NoteStore
    public let backups: BackupService?
    public let settings: AppSettings
    public let themes: ThemeManager
    public let editorFactory: NoteEditorFactory
    public weak var controller: AppController?
    public weak var presenter: NotesPresenting?

    public init(store: NoteStore, backups: BackupService?, settings: AppSettings,
                themes: ThemeManager, editorFactory: NoteEditorFactory) {
        self.store = store; self.backups = backups; self.settings = settings
        self.themes = themes; self.editorFactory = editorFactory
    }
}

// MARK: - Plain fallback editor (used until / unless NoteBarEditor is wired in)

@MainActor
public final class PlainNoteEditorFactory: NoteEditorFactory {
    public init() {}
    public func makeEditor(for note: Note, env: AppEnvironment) -> any NoteEditing { PlainNoteEditor(note: note, env: env) }
}

/// A minimal NSTextView-based editor that satisfies the `NoteEditing` contract. No markdown styling.
@MainActor
public final class PlainNoteEditor: NSView, NoteEditing, NSTextViewDelegate {
    public let noteID: NoteID
    public var onBodyChange: ((String) -> Void)?
    public var onLayoutChange: (() -> Void)?
    public var onFocusChange: ((Bool) -> Void)?
    public var onEvent: ((EditorEvent) -> Void)?
    private let textView: FocusTextView
    private let env: AppEnvironment

    public init(note: Note, env: AppEnvironment) {
        self.noteID = note.id
        self.env = env
        textView = FocusTextView(frame: .zero)
        super.init(frame: .zero)
        textView.isRichText = false
        textView.drawsBackground = false
        textView.font = .systemFont(ofSize: env.themes.fontSize)
        textView.textContainerInset = .zero
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true
        textView.isVerticallyResizable = false
        textView.allowsUndo = true
        textView.string = note.body
        textView.delegate = self
        textView.onFocus = { [weak self] in self?.onFocusChange?($0) }
        textView.translatesAutoresizingMaskIntoConstraints = true
        textView.autoresizingMask = [.width, .height]
        addSubview(textView)
        apply(note: note)
    }

    required init?(coder: NSCoder) { fatalError() }

    public override var isFlipped: Bool { true }

    public override var intrinsicContentSize: NSSize {
        guard let lm = textView.layoutManager, let tc = textView.textContainer else { return NSSize(width: NSView.noIntrinsicMetric, height: 18) }
        tc.containerSize = NSSize(width: max(bounds.width, 1), height: .greatestFiniteMagnitude)
        lm.ensureLayout(for: tc)
        let h = ceil(lm.usedRect(for: tc).height)
        return NSSize(width: NSView.noIntrinsicMetric, height: max(h, ceil(textView.font?.boundingRectForFont.height ?? 16)))
    }

    public override func layout() {
        super.layout()
        textView.frame = bounds
        invalidateIntrinsicContentSize()
    }

    public func textDidChange(_ notification: Notification) {
        onBodyChange?(textView.string)
        invalidateIntrinsicContentSize()
        onLayoutChange?()
    }

    public func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(cancelOperation(_:)) { onEvent?(.escape); return true }
        return false
    }

    public func apply(note: Note) {
        if textView.string != note.body { textView.string = note.body; invalidateIntrinsicContentSize(); onLayoutChange?() }
        let code = note.mode == .code
        textView.font = code ? .monospacedSystemFont(ofSize: env.themes.fontSize - 1, weight: .regular) : .systemFont(ofSize: env.themes.fontSize)
        textView.isAutomaticQuoteSubstitutionEnabled = !code
        textView.isAutomaticDashSubstitutionEnabled = !code
        textView.isAutomaticSpellingCorrectionEnabled = !code
        textView.textColor = env.themes.color(\.text, appearance: effectiveAppearance)
    }

    public func focus(atEnd: Bool) {
        window?.makeFirstResponder(textView)
        if atEnd { textView.setSelectedRange(NSRange(location: (textView.string as NSString).length, length: 0)) }
    }

    public var isEditingFocused: Bool { window?.firstResponder === textView }

    public func perform(_ action: FormatAction) {
        if action == .copy { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(textView.string, forType: .string) }
    }

    public func insertAttachments(_ attachments: [Attachment]) {
        let text = attachments.map(AttachmentLink.markdown(for:)).joined(separator: "\n")
        let loc = isEditingFocused ? textView.selectedRange() : NSRange(location: (textView.string as NSString).length, length: 0)
        textView.insertText((loc.location == 0 ? "" : "\n") + text, replacementRange: loc)
    }

    public func revealFirstSearchMatch() {}

    public func highlightSearch(_ query: String) {
        guard !query.isEmpty else { return }
        let r = (textView.string as NSString).range(of: query, options: .caseInsensitive)
        if r.location != NSNotFound { textView.showFindIndicator(for: r) }
    }
}

final class FocusTextView: NSTextView {
    var onFocus: ((Bool) -> Void)?
    override func becomeFirstResponder() -> Bool { let r = super.becomeFirstResponder(); if r { onFocus?(true) }; return r }
    override func resignFirstResponder() -> Bool { let r = super.resignFirstResponder(); if r { onFocus?(false) }; return r }
}
