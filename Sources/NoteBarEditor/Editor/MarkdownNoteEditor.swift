import AppKit
import NoteBarCore

/// Markdown note editor (TextKit 1). One per visible note card.
///
/// - The text storage holds the markdown verbatim, except checklist prefixes and attachment tokens,
///   which are single attachment characters that remember their source (`EmbedAttachment`).
///   `MarkdownCodec` converts losslessly; `onBodyChange` always receives the serialized markdown.
/// - Styling is attribute-only (`MarkdownStyler`), incremental per paragraph.
/// - Invisible markdown hides marker glyphs outside the caret's spans (`NoteLayoutManager`).
/// - Layout: no internal scrolling; height = text height at the current width (`intrinsicContentSize`).
@MainActor
public final class MarkdownNoteEditor: NSView, NoteEditing, NSTextViewDelegate, @preconcurrency NSTextStorageDelegate {
    public let noteID: NoteID
    public var onBodyChange: ((String) -> Void)?
    public var onLayoutChange: (() -> Void)?
    public var onFocusChange: ((Bool) -> Void)?
    public var onEvent: ((EditorEvent) -> Void)?

    let env: AppEnvironment
    private(set) var note: Note
    var mode: NoteMode { note.mode }

    let textStorage = NSTextStorage()
    let layoutManagerNB = NoteLayoutManager()
    let container: NSTextContainer
    let textView: MarkdownTextView
    let context: EditorContext
    let styler: MarkdownStyler
    let undo = UndoManager()

    /// Paragraph structure of the storage (rescanned after edits).
    private(set) var lines: [MarkdownLine] = []
    private var linesStale = true
    /// Lines as of the last restyle (to detect block-context changes).
    private var styledLines: [MarkdownLine] = []
    /// Characters edited since the last restyle.
    private var pendingDirty: NSRange?
    /// Last body reported to / received from the host.
    private(set) var lastBody: String
    /// Suppresses the change pipeline while the editor itself edits the storage.
    var isApplyingInternal = false
    var isTrackingMouse = false
    private var reportedHeight: CGFloat = -1
    private var cachedHeight: (width: CGFloat, height: CGFloat)?
    private var observers: [NSObjectProtocol] = []
    private var scrollObserver: NSObjectProtocol?
    private var windowObservers: [NSObjectProtocol] = []
    private var toolbarWork: DispatchWorkItem?
    /// Ranges marked by the current search (temporary highlight, see `highlightSearch`).
    private(set) var searchRanges: [NSRange] = []
    /// True while this editor has keyboard focus. Spell-check dots are shown only then.
    private var isSpellActive = false
    /// Vim keys (`env.settings.vimKeybinds`): mode, pending keys, `:` / `/` prompt.
    var vim = VimState()
    var vimPrompt: VimPromptView?
    /// Copy button on the hovered code block, and that block's storage range.
    var codeCopyButton: NSButton?
    var codeCopyBlock: NSRange?

    var style: EditorStyle { styler.style }
    var codecOptions: CodecOptions { .forMode(mode) }

    public init(note: Note, env: AppEnvironment) {
        self.noteID = note.id
        self.note = note
        self.env = env
        self.lastBody = note.body
        let appearance = NSApp?.effectiveAppearance ?? NSAppearance(named: .aqua)!
        let st = EditorStyle(themes: env.themes, appearance: appearance, color: note.color, mode: note.mode,
                             hideMarkup: env.settings.hideMarkup)
        styler = MarkdownStyler(style: st)
        context = EditorContext(env: env, style: st)
        container = NSTextContainer(size: NSSize(width: 260, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = false
        container.heightTracksTextView = false
        container.lineFragmentPadding = 0
        layoutManagerNB.addTextContainer(container)
        textStorage.addLayoutManager(layoutManagerNB)
        textView = MarkdownTextView(frame: NSRect(x: 0, y: 0, width: 260, height: 20), textContainer: container)
        super.init(frame: NSRect(x: 0, y: 0, width: 260, height: 20))

        textStorage.delegate = self
        context.onCellUpdate = { [weak self] a in self?.attachmentDidUpdate(a) }
        configureTextView()
        addSubview(textView)
        loadBody(note.body)
        installObservers()
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    deinit {
        for o in observers { NotificationCenter.default.removeObserver(o) }
        if let scrollObserver { NotificationCenter.default.removeObserver(scrollObserver) }
        for o in windowObservers { NotificationCenter.default.removeObserver(o) }
    }

    public override var isFlipped: Bool { true }

    // MARK: Setup

    private func configureTextView() {
        let tv = textView
        tv.editor = self
        tv.delegate = self
        tv.isRichText = false
        tv.importsGraphics = false
        tv.allowsImageEditing = false
        tv.isEditable = true
        tv.isSelectable = true
        tv.allowsUndo = true
        tv.drawsBackground = false
        tv.textContainerInset = .zero
        tv.isVerticallyResizable = false
        tv.isHorizontallyResizable = false
        tv.autoresizingMask = []
        tv.usesFontPanel = false
        tv.usesRuler = false
        tv.usesFindBar = false
        tv.isAutomaticLinkDetectionEnabled = false
        tv.isAutomaticDataDetectionEnabled = false
        tv.displaysLinkToolTips = true
        tv.focusRingType = .none
        tv.registerForDraggedTypes(tv.acceptableDragTypes)
        applyModeSettings()
        applyColorsToTextView()
    }

    private func applyModeSettings() {
        let tv = textView
        switch mode {
        case .code:
            tv.isAutomaticQuoteSubstitutionEnabled = false
            tv.isAutomaticDashSubstitutionEnabled = false
            tv.isAutomaticSpellingCorrectionEnabled = false
            tv.isAutomaticTextReplacementEnabled = false
            tv.isAutomaticTextCompletionEnabled = false
            tv.isContinuousSpellCheckingEnabled = false
            tv.isGrammarCheckingEnabled = false
            tv.smartInsertDeleteEnabled = false
        case .standard:
            // Markdown-friendly: no smart quotes / dashes (they break `code` and ---).
            tv.isAutomaticQuoteSubstitutionEnabled = false
            tv.isAutomaticDashSubstitutionEnabled = false
            tv.isAutomaticSpellingCorrectionEnabled = NSSpellChecker.isAutomaticSpellingCorrectionEnabled
            tv.isAutomaticTextReplacementEnabled = NSSpellChecker.isAutomaticTextReplacementEnabled
            tv.isAutomaticTextCompletionEnabled = false
            tv.isContinuousSpellCheckingEnabled = isSpellActive
            tv.smartInsertDeleteEnabled = true
        case .plain:
            tv.isAutomaticQuoteSubstitutionEnabled = NSSpellChecker.isAutomaticQuoteSubstitutionEnabled
            tv.isAutomaticDashSubstitutionEnabled = NSSpellChecker.isAutomaticDashSubstitutionEnabled
            tv.isAutomaticSpellingCorrectionEnabled = NSSpellChecker.isAutomaticSpellingCorrectionEnabled
            tv.isAutomaticTextReplacementEnabled = NSSpellChecker.isAutomaticTextReplacementEnabled
            tv.isAutomaticTextCompletionEnabled = false
            tv.isContinuousSpellCheckingEnabled = isSpellActive
            tv.smartInsertDeleteEnabled = true
        }
    }

    /// Turns spell checking on (focused editor) or off (unfocused editor, `.code` notes).
    /// Turning it off also removes the dots that are already drawn.
    private func setSpellCheckingActive(_ active: Bool) {
        isSpellActive = active
        textView.isContinuousSpellCheckingEnabled = active && mode != .code
        if !textView.isContinuousSpellCheckingEnabled {
            textView.setSpellingState(0, range: NSRange(location: 0, length: textStorage.length))
        }
    }

    private func applyColorsToTextView() {
        let st = style
        textView.insertionPointColor = hidesBarCaret ? .clear : st.text
        textView.linkTextAttributes = [.foregroundColor: st.link, .cursor: NSCursor.pointingHand]
        textView.typingAttributes = baseAttributes
        layoutManagerNB.hideMarkup = st.hideMarkup && mode == .standard
        layoutManagerNB.codeBlockColor = st.codeBackground
        layoutManagerNB.ruleColor = st.ruleColor
        layoutManagerNB.fenceBarHeight = st.fenceBarHeight
        layoutManagerNB.swatchDiameter = st.swatchDiameter
        layoutManagerNB.swatchGap = st.swatchGap
    }

    var baseAttributes: [NSAttributedString.Key: Any] {
        let st = style
        let p = st.paragraphStyle(EditorStyle.ParagraphKey(tab: st.tabInterval, lineSpacing: st.lineSpacing))
        return [.font: mode == .code ? st.monoFont : st.bodyFont, .foregroundColor: st.text, .paragraphStyle: p]
    }

    private func installObservers() {
        let nc = NotificationCenter.default
        observers.append(nc.addObserver(forName: .themeDidChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.rebuildStyle() }
        })
        observers.append(nc.addObserver(forName: .appSettingsDidChange, object: nil, queue: .main) { [weak self] n in
            let key = n.userInfo?["key"] as? String
            if key == "vimKeybinds" { MainActor.assumeIsolated { self?.vimSettingsChanged() }; return }
            guard key == nil || key == "hideMarkup" else { return }
            MainActor.assumeIsolated { self?.rebuildStyle() }
        })
        observers.append(nc.addObserver(forName: .noteStoreDidChange, object: nil, queue: .main) { [weak self] n in
            guard let change = n.storeChange else { return }
            MainActor.assumeIsolated {
                guard let self else { return }
                switch change {
                case .all: self.refreshAttachmentCells(all: true)
                case .attachments(let id) where id == self.noteID: self.refreshAttachmentCells(all: false)
                default: break
                }
            }
        })
    }

    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        rebuildStyle()
    }

    public override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        if newWindow == nil { FormattingToolbar.shared.hide(for: self) }
        for o in windowObservers { NotificationCenter.default.removeObserver(o) }
        windowObservers.removeAll()
        if let s = scrollObserver { NotificationCenter.default.removeObserver(s); scrollObserver = nil }
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else { return }
        let nc = NotificationCenter.default
        for name in [NSWindow.didResignKeyNotification, NSWindow.didMoveNotification, NSWindow.didResizeNotification] {
            windowObservers.append(nc.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { if let self { FormattingToolbar.shared.hide(for: self) } }
            })
        }
        if let clip = enclosingScrollView?.contentView {
            clip.postsBoundsChangedNotifications = true
            scrollObserver = nc.addObserver(forName: NSView.boundsDidChangeNotification, object: clip, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { if let self { FormattingToolbar.shared.hide(for: self) } }
            }
        }
        rebuildStyle()
    }

    /// Re-resolves fonts/colors (theme, appearance, note color, mode, hideMarkup) and restyles everything.
    func rebuildStyle() {
        let st = EditorStyle(themes: env.themes, appearance: effectiveAppearance, color: note.color, mode: mode,
                             hideMarkup: env.settings.hideMarkup)
        let hideChanged = layoutManagerNB.hideMarkup != (st.hideMarkup && mode == .standard)
        styler.style = st
        context.style = st
        applyColorsToTextView()
        restyle(dirty: nil)
        let full = NSRange(location: 0, length: textStorage.length)
        if hideChanged {
            layoutManagerNB.revealed = computeReveal()
            layoutManagerNB.invalidateGlyphs(forCharacterRange: full, changeInLength: 0, actualCharacterRange: nil)
        }
        layoutManagerNB.invalidateLayout(forCharacterRange: full, actualCharacterRange: nil)
        textView.needsDisplay = true
        layoutDidChange()
    }

    // MARK: Body

    private func loadBody(_ body: String) {
        isApplyingInternal = true
        let attr = MarkdownCodec.attributedString(from: body, options: codecOptions, attributes: baseAttributes,
                                                  makeAttachment: context.makeAttachment)
        textStorage.setAttributedString(attr)
        isApplyingInternal = false
        lastBody = body
        restyle(dirty: nil)
    }

    /// The current markdown body.
    public var markdown: String { MarkdownCodec.markdown(from: textStorage) }

    func markdown(for range: NSRange) -> String {
        let r = NSIntersectionRange(range, NSRange(location: 0, length: textStorage.length))
        return MarkdownCodec.markdown(from: textStorage, range: r)
    }

    func reportBody() {
        guard !textView.hasMarkedText() else { return }
        let md = markdown
        guard md != lastBody else { return }
        lastBody = md
        onBodyChange?(md)
    }

    var markdownSelection: NSRange {
        MarkdownCodec.markdownRange(forStorageRange: textView.selectedRange(), embeds: MarkdownCodec.embeds(in: textStorage))
    }

    func setMarkdownSelection(_ r: NSRange) {
        let sr = MarkdownCodec.storageRange(forMarkdownRange: r, embeds: MarkdownCodec.embeds(in: textStorage))
        let len = textStorage.length
        let a = min(sr.location, len)
        textView.setSelectedRange(NSRange(location: a, length: min(sr.length, len - a)))
    }

    /// Replaces the body with `newText` by rewriting only the changed lines.
    /// `undoable` edits go through the text view's undo; external changes clear the undo stack.
    func replaceMarkdown(_ newText: String, selection: NSRange?, undoable: Bool, actionName: String? = nil) {
        let oldText = markdown
        let M = oldText as NSString, N = newText as NSString
        if M.isEqual(to: newText as String) {
            if let selection { setMarkdownSelection(selection) }
            return
        }
        let minLen = min(M.length, N.length)
        var p = 0
        while p < minLen, M.character(at: p) == N.character(at: p) { p += 1 }
        var sfx = 0
        while sfx < minLen - p, M.character(at: M.length - 1 - sfx) == N.character(at: N.length - 1 - sfx) { sfx += 1 }
        var start = p
        while start > 0, !UC.isLineTerminator(M.character(at: start - 1)) { start -= 1 }
        var endM = M.length - sfx
        while endM < M.length, !UC.isLineTerminator(M.character(at: endM)) { endM += 1 }
        let endN = N.length - (M.length - endM)
        let embeds = MarkdownCodec.embeds(in: textStorage)
        let storageRange = MarkdownCodec.storageRange(forMarkdownRange: NSRange(location: start, length: endM - start), embeds: embeds)
        let repl = MarkdownCodec.attributedString(from: newText, options: codecOptions,
                                                  range: NSRange(location: start, length: max(0, endN - start)),
                                                  attributes: baseAttributes, makeAttachment: context.makeAttachment)
        let oldSelMd = markdownSelection
        if undoable {
            textView.breakUndoCoalescing()
            guard textView.shouldChangeText(in: storageRange, replacementString: repl.string) else { return }
            isApplyingInternal = true
            textStorage.replaceCharacters(in: storageRange, with: repl)
            textView.didChangeText()
            isApplyingInternal = false
            if let actionName { undo.setActionName(actionName) }
            textView.breakUndoCoalescing()
        } else {
            isApplyingInternal = true
            textStorage.replaceCharacters(in: storageRange, with: repl)
            isApplyingInternal = false
            undo.removeAllActions()
        }
        restyle(dirty: NSRange(location: storageRange.location, length: repl.length))
        if let selection {
            setMarkdownSelection(selection)
        } else {
            // Keep the caret: shift it if it was after the changed region.
            let delta = N.length - M.length
            var s = oldSelMd
            if s.location >= endM { s.location += delta } else if s.location > start { s.location = min(s.location, endN); s.length = 0 }
            setMarkdownSelection(NSRange(location: max(0, min(s.location, N.length)), length: max(0, min(s.length, N.length - s.location))))
        }
        if undoable { reportBody() } else { lastBody = newText }
        clearSearchHighlight()
        updateReveal()
        layoutDidChange()
    }

    // MARK: Styling pipeline

    func checkboxState(at i: Int) -> Bool? {
        guard i < textStorage.length, let a = textStorage.attribute(.attachment, at: i, effectiveRange: nil) as? EmbedAttachment,
              case .checkbox(let checked, _) = a.token else { return nil }
        return checked
    }

    func currentLines() -> [MarkdownLine] {
        if linesStale {
            lines = BlockScanner.scan(textStorage.string as NSString, checkbox: { [unowned self] in self.checkboxState(at: $0) })
            linesStale = false
        }
        return lines
    }

    /// Restyles the paragraphs touched by `dirty` plus any paragraph whose block context changed
    /// (code fences, title). `nil` restyles everything.
    func restyle(dirty: NSRange?) {
        let old = styledLines
        linesStale = true
        let new = currentLines()
        let len = textStorage.length
        var indices: [Int] = []
        if dirty == nil || old.isEmpty || len < 2000 {
            indices = Array(new.indices)
        } else if let d = dirty {
            let delta = new.count - old.count
            let dr = NSRange(location: min(d.location, len), length: min(d.length, max(0, len - d.location)))
            for (i, l) in new.enumerated() {
                if l.fullRange.touches(dr) { indices.append(i); continue }
                let oi = l.fullRange.location < dr.location ? i : i - delta
                guard oi >= 0, oi < old.count else { indices.append(i); continue }
                let o = old[oi]
                if o.kind != l.kind || o.isTitle != l.isTitle || o.codeBlock != l.codeBlock || o.range.length != l.range.length {
                    indices.append(i)
                }
            }
        }
        isApplyingInternal = true
        styler.style(textStorage, lines: new, indices: indices)
        isApplyingInternal = false
        styledLines = new
        pendingDirty = nil
    }

    /// Turns raw `- [ ] ` / attachment tokens typed or pasted as text into attachment characters.
    private func convertRawTokens(in dirty: NSRange) {
        guard !undo.isUndoing, !undo.isRedoing else { return }
        let s = textStorage.string as NSString
        guard s.length > 0 else { return }
        let d = NSRange(location: min(dirty.location, s.length), length: min(dirty.length, s.length - min(dirty.location, s.length)))
        let para = s.paragraphRange(for: d)
        let sub = s.substring(with: para)
        guard sub.contains("[") else { return }
        var tokens = MarkdownCodec.tokens(in: sub, options: codecOptions)
        guard !tokens.isEmpty else { return }
        let lines = BlockScanner.scan(s)
        tokens = tokens.filter { t in
            guard t.token.isCheckbox else { return true }
            guard let last = t.token.source.utf16.last, UC.isSpaceOrTab(last) else { return false }
            let li = BlockScanner.lineIndex(in: lines, containing: para.location + t.range.location)
            return !lines[li].isCode
        }
        guard !tokens.isEmpty else { return }
        let ranges = tokens.map { $0.range.offset(by: para.location) }
        textView.breakUndoCoalescing()
        guard textView.shouldChangeText(inRanges: ranges.map { NSValue(range: $0) },
                                        replacementStrings: ranges.map { _ in "\u{FFFC}" }) else { return }
        var sel = textView.selectedRange()
        func mapPos(_ p: Int) -> Int {
            var out = p
            for r in ranges {
                if r.end <= p { out -= r.length - 1 } else if r.location < p { out -= p - r.location - 1 }
            }
            return out
        }
        sel = NSRange(location: mapPos(sel.location), length: 0)
        isApplyingInternal = true
        textStorage.beginEditing()
        for (t, r) in zip(tokens, ranges).reversed() {
            var attrs = textStorage.attributes(at: r.location, effectiveRange: nil)
            attrs[.attachment] = context.makeAttachment(t.token)
            textStorage.replaceCharacters(in: r, with: NSAttributedString(string: "\u{FFFC}", attributes: attrs))
        }
        textStorage.endEditing()
        textView.didChangeText()
        isApplyingInternal = false
        textView.breakUndoCoalescing()
        textView.setSelectedRange(sel)
    }

    // MARK: NSTextStorageDelegate

    public func textStorage(_ textStorage: NSTextStorage, didProcessEditing editedMask: NSTextStorageEditActions,
                            range editedRange: NSRange, changeInLength delta: Int) {
        guard editedMask.contains(.editedCharacters) else { return }
        linesStale = true
        cachedHeight = nil
        if let p = pendingDirty {
            var shifted = p
            if p.location >= editedRange.location { shifted.location = max(editedRange.location, p.location + delta) }
            else if p.end > editedRange.location { shifted.length = max(0, p.length + delta) }
            pendingDirty = NSUnionRange(shifted, editedRange)
        } else {
            pendingDirty = editedRange
        }
    }

    // MARK: NSTextViewDelegate

    public func undoManager(for view: NSTextView) -> UndoManager? { undo }

    public func textDidChange(_ notification: Notification) {
        guard !isApplyingInternal else { return }
        if textView.hasMarkedText() { layoutDidChange(); return }
        if let d = pendingDirty { convertRawTokens(in: d) }
        hideCodeCopyButton()
        restyle(dirty: pendingDirty ?? NSRange(location: 0, length: textStorage.length))
        clearSearchHighlight()
        reportBody()
        updateReveal()
        layoutDidChange()
    }

    public func textViewDidChangeSelection(_ notification: Notification) {
        guard !isApplyingInternal else { return }
        if !isTrackingMouse { updateReveal() }
        if isVimNormal { textView.needsDisplay = true }
        scheduleToolbarUpdate()
    }

    public func textView(_ textView: NSTextView, shouldChangeTypingAttributes oldTypingAttributes: [String: Any] = [:],
                         toAttributes newTypingAttributes: [NSAttributedString.Key: Any] = [:]) -> [NSAttributedString.Key: Any] {
        var a = newTypingAttributes
        for k in [NSAttributedString.Key.nbMarker, .nbFence, .nbBullet, .nbSwatch, .nbHighlight, .nbRule, .link, .kern, .attachment] {
            a[k] = nil
        }
        return a
    }

    /// Spell check skips markup: code spans and blocks, URLs, hex colors, `<u>` / `<span>` tags,
    /// markers, rules and attachment tokens. Words in plain text stay checked.
    public func textView(_ textView: NSTextView, shouldSetSpellingState value: Int, range affectedCharRange: NSRange) -> Int {
        isSpellSkipped(affectedCharRange) ? 0 : value
    }

    /// True when `r` touches a code line, a rule, a markup marker, a URL, a hex color or an attachment token.
    func isSpellSkipped(_ r: NSRange) -> Bool {
        let len = textStorage.length
        let rr = NSIntersectionRange(r, NSRange(location: 0, length: len))
        guard rr.length > 0 else { return false }
        let s = textStorage.string as NSString
        if mode == .code { return true }
        let all = currentLines()
        guard !all.isEmpty else { return false }
        let i0 = BlockScanner.lineIndex(in: all, containing: rr.location)
        let i1 = BlockScanner.lineIndex(in: all, containing: rr.end - 1)
        for i in i0...max(i0, i1) where i < all.count {
            let line = all[i]
            if line.isCode || line.codeBlock >= 0 || line.kind == .rule { return true }
            if line.markerRange.length > 0, NSIntersectionRange(line.markerRange, rr).length > 0 { return true }
            guard line.contentRange.length > 0 else { continue }
            for span in InlineParser.parse(s, in: line.contentRange) {
                var zones = span.markers
                switch span.kind {
                case .code, .hex, .autolink: zones.append(span.range)
                default: break
                }
                if zones.contains(where: { NSIntersectionRange($0, rr).length > 0 }) { return true }
            }
        }
        return false
    }

    public func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
        var url: URL?
        if let u = link as? URL { url = u } else if let s = link as? String { url = styler.linkURL(s) }
        guard let url else { return false }
        NSWorkspace.shared.open(url)
        return true
    }

    public func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        handleCommand(commandSelector)
    }

    func mouseTrackingEnded() {
        updateReveal()
        scheduleToolbarUpdate()
    }

    func focusDidChange(_ focused: Bool) {
        setSpellCheckingActive(focused)
        vimFocusChanged(focused)
        if !focused { FormattingToolbar.shared.hide(for: self) }
        // Defer: the window's first responder is updated after become/resign returns.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.updateReveal()
        }
        onFocusChange?(focused)
    }

    // MARK: Invisible markdown

    func computeReveal() -> [NSRange] {
        guard layoutManagerNB.hideMarkup, isEditingFocused, !textView.hasMarkedText() else { return [] }
        let lines = currentLines()
        guard !lines.isEmpty else { return [] }
        let s = textStorage.string as NSString
        let sel = textView.selectedRange()
        var out: [NSRange] = []
        let i0 = BlockScanner.lineIndex(in: lines, containing: sel.location)
        let i1 = BlockScanner.lineIndex(in: lines, containing: sel.end)
        var i = i0
        while i <= i1 && i < lines.count {
            let line = lines[i]
            if line.codeBlock >= 0 {
                var a = i, b = i
                while a > 0, lines[a - 1].codeBlock == line.codeBlock { a -= 1 }
                while b + 1 < lines.count, lines[b + 1].codeBlock == line.codeBlock { b += 1 }
                out.append(NSUnionRange(lines[a].fullRange, lines[b].range))
                i = b + 1
                continue
            }
            switch line.kind {
            case .heading, .quote, .rule: out.append(line.range)
            default: break
            }
            if line.contentRange.length > 0, line.contentRange.end <= s.length {
                for span in InlineParser.parse(s, in: line.contentRange) where !span.markers.isEmpty && span.range.touches(sel) {
                    out.append(span.range)
                }
            }
            i += 1
        }
        return out.sorted { $0.location < $1.location }
    }

    func updateReveal() {
        let new = computeReveal()
        let old = layoutManagerNB.revealed
        guard new != old else { return }
        layoutManagerNB.revealed = new
        guard layoutManagerNB.hideMarkup else { return }
        let len = textStorage.length
        for r in old + new {
            let c = NSIntersectionRange(r, NSRange(location: 0, length: len))
            let rr = c.length > 0 ? c : (r.location < len ? NSRange(location: r.location, length: 1) : NSRange(location: 0, length: 0))
            guard rr.length > 0 else { continue }
            layoutManagerNB.invalidateGlyphs(forCharacterRange: rr, changeInLength: 0, actualCharacterRange: nil)
            layoutManagerNB.invalidateLayout(forCharacterRange: rr, actualCharacterRange: nil)
            layoutManagerNB.invalidateDisplay(forCharacterRange: rr)
        }
        cachedHeight = nil
        layoutDidChange()
    }

    // MARK: Layout

    var minimumHeight: CGFloat {
        let f = mode == .code ? style.monoFont : style.bodyFont
        return ceil(layoutManagerNB.defaultLineHeight(for: f) + style.lineSpacing)
    }

    func measuredHeight(width: CGFloat) -> CGFloat {
        let w = width > 1 ? width : 260
        if let c = cachedHeight, c.width == w { return c.height }
        if container.size.width != w { container.size = NSSize(width: w, height: CGFloat.greatestFiniteMagnitude) }
        layoutManagerNB.ensureLayout(for: container)
        let used = layoutManagerNB.usedRect(for: container)
        let h = ceil(max(used.maxY, minimumHeight))
        cachedHeight = (w, h)
        return h
    }

    public override var intrinsicContentSize: NSSize {
        let h = measuredHeight(width: bounds.width) + promptHeight
        if bounds.width > 1 { reportedHeight = h }
        return NSSize(width: NSView.noIntrinsicMetric, height: h)
    }

    public override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        layoutTextView()
    }

    public override func layout() {
        super.layout()
        layoutTextView()
    }

    private func layoutTextView() {
        let w = bounds.width
        guard w > 1 else { return }
        if container.size.width != w {
            container.size = NSSize(width: w, height: CGFloat.greatestFiniteMagnitude)
            cachedHeight = nil
        }
        let ph = promptHeight
        let measured = measuredHeight(width: w)
        let h = max(bounds.height - ph, measured)
        let f = NSRect(x: 0, y: 0, width: w, height: h)
        if textView.frame != f { textView.frame = f }
        // The vim prompt sits at the bottom of the editor (of the card when it is expanded).
        vimPrompt?.frame = NSRect(x: 0, y: max(measured, bounds.height - ph), width: w, height: ph)
        if abs(measured + ph - reportedHeight) > 0.5, reportedHeight >= 0 {
            // Width change altered the height: tell the host after this layout pass.
            DispatchQueue.main.async { [weak self] in self?.layoutDidChange() }
        }
    }

    /// Recomputes the height and notifies the host when it changed.
    func layoutDidChange() {
        cachedHeight = nil
        let ph = promptHeight
        let measured = measuredHeight(width: bounds.width)
        let h = measured + ph
        let w = bounds.width
        if w > 1 {
            let f = NSRect(x: 0, y: 0, width: w, height: max(bounds.height - ph, measured))
            if textView.frame != f { textView.frame = f }
            vimPrompt?.frame = NSRect(x: 0, y: max(measured, bounds.height - ph), width: w, height: ph)
        }
        if abs(h - reportedHeight) > 0.5 {
            reportedHeight = h
            invalidateIntrinsicContentSize()
            onLayoutChange?()
        }
    }

    private func attachmentDidUpdate(_ attachment: NSTextAttachment) {
        let len = textStorage.length
        guard len > 0 else { return }
        textStorage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: len), options: []) { v, r, stop in
            guard (v as AnyObject?) === attachment else { return }
            layoutManagerNB.invalidateLayout(forCharacterRange: r, actualCharacterRange: nil)
            layoutManagerNB.invalidateDisplay(forCharacterRange: r)
            stop.pointee = true
        }
        layoutDidChange()
        textView.needsDisplay = true
    }

    // MARK: NoteEditing

    public func apply(note new: Note) {
        let old = note
        note = new
        if new.mode != old.mode {
            let sel = markdownSelection
            applyModeSettings()
            styler.style = EditorStyle(themes: env.themes, appearance: effectiveAppearance, color: new.color, mode: new.mode,
                                       hideMarkup: env.settings.hideMarkup)
            context.style = styler.style
            applyColorsToTextView()
            undo.removeAllActions()
            loadBody(new.body)
            setMarkdownSelection(NSRange(location: min(sel.location, (lastBody as NSString).length), length: 0))
            rebuildStyle()
            return
        }
        if new.body != markdown {
            replaceMarkdown(new.body, selection: nil, undoable: false)
        }
        if new.color != old.color { rebuildStyle() }
    }

    public func focus(atEnd: Bool) {
        guard let window else { return }
        window.makeFirstResponder(textView)
        if atEnd {
            textView.setSelectedRange(NSRange(location: textStorage.length, length: 0))
        }
        textView.scrollRangeToVisible(textView.selectedRange())
    }

    public var isEditingFocused: Bool {
        guard let window else { return false }
        return window.firstResponder === textView
    }

    public func insertAttachments(_ attachments: [Attachment]) {
        guard !attachments.isEmpty else { return }
        let md = markdown
        let sel = isEditingFocused ? markdownSelection : NSRange(location: (md as NSString).length, length: 0)
        // Every attachment is a block (image or file tile), so each one gets its own line.
        let items = attachments.map { (AttachmentLink.markdown(for: $0), true) }
        let r = AttachmentInsertion.insert(items, into: md, selection: sel)
        replaceMarkdown(r.text, selection: r.selection, undoable: true, actionName: "Insert Attachment")
    }

    /// Marks every match of `query` with a temporary highlight (theme `highlight` color).
    /// Does not change the selection or scroll. Empty query = clear. Safe to call on any editor at any time,
    /// including an editor created after the search started. Call `revealFirstSearchMatch()` on one editor
    /// to scroll to the first match and show the find indicator.
    public func highlightSearch(_ query: String) {
        clearSearchHighlight()
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        let s = textStorage.string as NSString
        var r = NSRange(location: 0, length: s.length)
        var found: [NSRange] = []
        while r.length > 0 {
            let m = s.range(of: q, options: [.caseInsensitive, .diacriticInsensitive], range: r)
            guard m.location != NSNotFound, m.length > 0 else { break }
            found.append(m)
            r = NSRange(location: m.end, length: s.length - m.end)
        }
        guard !found.isEmpty else { return }
        searchRanges = found
        let color = style.highlight
        for m in found { layoutManagerNB.addTemporaryAttribute(.backgroundColor, value: color, forCharacterRange: m) }
    }

    /// Number of matches marked by the current search.
    public var searchMatchCount: Int { searchRanges.count }

    /// Scrolls to the first match of the current search and shows the find indicator (if visible).
    public func revealFirstSearchMatch() {
        guard let first = searchRanges.first, first.end <= textStorage.length else { return }
        textView.scrollRangeToVisible(first)
        if window?.isVisible == true { textView.showFindIndicator(for: first) }
    }

    /// Removes the search marks. Also runs on every edit.
    public func clearSearchHighlight() {
        guard !searchRanges.isEmpty else { return }
        searchRanges = []
        layoutManagerNB.removeTemporaryAttribute(.backgroundColor, forCharacterRange: NSRange(location: 0, length: textStorage.length))
    }

    // MARK: Toolbar

    func scheduleToolbarUpdate() {
        toolbarWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.updateToolbar() }
        toolbarWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
    }

    func updateToolbar() {
        let sel = textView.selectedRange()
        guard mode == .standard, isEditingFocused, !isTrackingMouse, let window, window.isVisible, window.isKeyWindow,
              sel.length > 0, !textView.hasMarkedText(), NSEvent.pressedMouseButtons == 0 else {
            FormattingToolbar.shared.hide(for: self)
            return
        }
        let rect = textView.firstRect(forCharacterRange: sel, actualRange: nil)
        guard rect.width > 0 || rect.height > 0 else { return }
        FormattingToolbar.shared.show(for: self, selectionRect: rect)
    }
}
