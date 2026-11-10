import AppKit
import NoteBarCore

/// The `:` command line of the notes list (vim keys on, no note being edited). It opens below the
/// last note, where the toast sits, and the panel's content grows by it. The folder commands
/// (`:folder`, `:newfolder`, `:rename`, ...) run as they are. The note commands (`:pin`, `:move`, ...)
/// run on the selected note. In a note, the editor has its own `:` line.
extension NotesRootViewController {
    var isCommandLineOpen: Bool { commandLine?.isHidden == false }

    func beginCommandLine() {
        _ = view
        let bar: CommandLineView
        if let existing = commandLine { bar = existing } else {
            bar = CommandLineView(env: env)
            bar.onSubmit = { [weak self] text in self?.endCommandLine(run: text) }
            bar.onCancel = { [weak self] in self?.endCommandLine(run: nil) }
            bar.completions = { [weak self] line in
                guard let self else { return nil }
                let open = self.currentFolderId
                return VimEx.completions(line, folders: self.store.folders().filter { $0.id != open }.map(\.name))
            }
            rootView.addSubview(bar)
            commandLine = bar
        }
        bar.reset()
        bar.isHidden = false
        updateBackdrop()
        // Before the focus: a field whose frame changes while it is edited ends the editing.
        bar.layoutSubtreeIfNeeded()
        bar.focus()
    }

    func endCommandLine(run text: String?) {
        guard let bar = commandLine, !bar.isHidden else { return }
        bar.isHidden = true
        updateBackdrop()
        focusRoot()
        if let text { runCommandLine(text) }
    }

    /// Below the last element, like the toast (at the bottom when the list fills the panel).
    func layoutCommandLine() {
        guard let bar = commandLine, !bar.isHidden, rootView != nil else { return }
        let b = rootView.bounds
        let m = Metrics.outerMargin
        let h = CommandLineView.height
        var y = listContentHeight - m + Metrics.gap
        // A toast that shows keeps its place: the line goes below it.
        if let toast, !toast.isHidden { y = max(y, toast.frame.maxY + Metrics.gap) }
        y = min(y, b.height - m - h)
        let f = NSRect(x: b.minX + m, y: max(y, 0), width: max(0, b.width - 2 * m), height: h)
        if bar.frame != f { bar.frame = f }
    }

    func runCommandLine(_ text: String) {
        switch VimEx.parse(text) {
        case .none, .write, .noHighlight:
            break
        case .goToLine:
            showToast("Line numbers work in a note")
        case .error(let message):
            showToast(message)
        case .card(let cmd):
            switch cmd {
            case .stepFolder, .openFolder, .openScratch, .newFolder, .renameFolder, .toggleFolderPin, .archiveFolder, .deleteFolder:
                runVimFolderCommand(cmd)
            case .quit:
                env.controller?.hidePanel()
            case .message(let message):
                showToast(message)
            default:
                guard let id = notesList.selectedNoteID, let card = notesList.card(for: id) else {
                    showToast("Select a note first")
                    return
                }
                handleVimCommand(cmd, card: card)
            }
        }
    }
}

/// A pill with ":" and a text field. Return runs the line, Escape (or losing the focus) closes it,
/// Tab / ⇧Tab complete a folder name and cycle through the matches.
@MainActor
final class CommandLineView: FlippedView, NSTextFieldDelegate {
    static let height: CGFloat = 32
    var onSubmit: ((String) -> Void)?
    var onCancel: (() -> Void)?
    var completions: ((String) -> (head: String, matches: [String])?)?

    private let env: AppEnvironment
    private let colon = PassthroughLabel()
    let field = NSTextField()
    /// Tab completion in progress: valid while the text is what the last Tab put there.
    private var cycle: (head: String, matches: [String], index: Int, text: String)?

    init(env: AppEnvironment) {
        self.env = env
        super.init(frame: .zero)
        colon.stringValue = ":"
        addSubview(colon)
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.delegate = self
        field.placeholderString = "folder name · newfolder · rename · scratch"
        field.cell?.isScrollable = true
        field.cell?.usesSingleLineMode = true
        addSubview(field)
        isHidden = true
        setAccessibilityLabel("Command line")
    }

    required init?(coder: NSCoder) { fatalError() }

    var text: String { field.stringValue }
    func reset() { field.stringValue = ""; cycle = nil; restyle() }
    func focus() { window?.makeFirstResponder(field) }

    private func restyle() {
        let ui = env.themes.ui(effectiveAppearance)
        let font = NSFont.monospacedSystemFont(ofSize: env.themes.fontSize - 1, weight: .regular)
        colon.font = font
        colon.textColor = ui.text.withAlphaComponent(0.55)
        field.font = font
        field.textColor = ui.text
        needsDisplay = true
        needsLayout = true
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        restyle()
    }

    override func layout() {
        super.layout()
        let fh = ceil(field.intrinsicContentSize.height)
        let cw = ceil(colon.intrinsicContentSize.width)
        colon.frame = NSRect(x: 12, y: (bounds.height - fh) / 2, width: cw, height: fh)
        let f = NSRect(x: colon.frame.maxX + 2, y: (bounds.height - fh) / 2, width: max(0, bounds.width - colon.frame.maxX - 14), height: fh)
        if field.frame != f { field.frame = f }
    }

    override func draw(_ dirtyRect: NSRect) {
        let ui = env.themes.ui(effectiveAppearance)
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 10, yRadius: 10)
        ui.headerBackground.setFill()
        path.fill()
        ui.hairline.setStroke()
        path.lineWidth = 1
        path.stroke()
    }

    // MARK: Keys

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            onSubmit?(field.stringValue)
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            onCancel?()
            return true
        case #selector(NSResponder.insertTab(_:)):
            complete(1)
            return true
        case #selector(NSResponder.insertBacktab(_:)):
            complete(-1)
            return true
        case #selector(NSResponder.deleteBackward(_:)) where field.stringValue.isEmpty:
            // Backspace on the empty line closes it, as in vim.
            onCancel?()
            return true
        default:
            return false
        }
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        // Focus went elsewhere (a click): the line closes. Return and Escape have closed it already.
        if !isHidden { onCancel?() }
    }

    /// Tab: the first match. Tab again (text unchanged): the next one, around the end.
    func complete(_ delta: Int) {
        let text = field.stringValue
        if var c = cycle, c.text == text, !c.matches.isEmpty {
            c.index = ((c.index + delta) % c.matches.count + c.matches.count) % c.matches.count
            c.text = c.head + c.matches[c.index]
            cycle = c
        } else if let (head, matches) = completions?(text), !matches.isEmpty {
            let i = delta > 0 ? 0 : matches.count - 1
            cycle = (head, matches, i, head + matches[i])
        } else {
            NSSound.beep()
            return
        }
        guard let c = cycle else { return }
        field.stringValue = c.text
        field.currentEditor()?.selectedRange = NSRange(location: (c.text as NSString).length, length: 0)
    }
}
