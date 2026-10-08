import AppKit
import NoteBarCore

/// One key as the vim layer sees it.
enum VimKey: Equatable {
    case char(Character)
    case ctrl(Character)
    case escape, enter, backspace, tab
    /// Arrows, Home / End, Page Up / Down: the text view moves the caret.
    case navigation
    /// ⌘ shortcuts: the text view handles them.
    case other
    /// Any other key. Normal mode ignores it (it must not edit the text).
    case ignored

    static func from(_ e: NSEvent) -> VimKey {
        let mods = e.modifierFlags.intersection([.command, .control, .option, .shift])
        if mods.contains(.command) { return .other }
        switch e.keyCode {
        case 53: return .escape
        case 36, 76: return mods.isEmpty || mods == [.shift] ? .enter : .ignored
        case 51: return mods.isEmpty ? .backspace : .ignored
        case 117: return mods.isEmpty ? .char("x") : .ignored
        case 48: return mods.isEmpty ? .tab : .ignored
        case 123, 124, 125, 126, 115, 119, 116, 121: return .navigation
        default: break
        }
        if mods.contains(.control) {
            if e.keyCode == 33 { return .ctrl("[") }
            guard let c = e.charactersIgnoringModifiers?.lowercased().first else { return .ignored }
            return .ctrl(c)
        }
        guard let s = e.characters, s.count == 1, let c = s.first,
              let u = c.unicodeScalars.first, u.value >= 0x20, u.value != 0x7F, !(0xF700...0xF8FF).contains(u.value) else {
            return .ignored
        }
        return .char(c)
    }
}

/// The unnamed register, shared by every note. Yanks also go to the system clipboard; `p` pastes the
/// clipboard instead when another app changed it after the last yank / delete.
@MainActor
enum VimRegister {
    static var text = ""
    static var linewise = false
    static var pasteboardChangeCount = -1
    /// The system clipboard (checks use a private pasteboard).
    static var pasteboard: NSPasteboard = .general

    static func store(_ text: String, linewise: Bool, toPasteboard: Bool) {
        self.text = text
        self.linewise = linewise
        let pb = pasteboard
        if toPasteboard {
            pb.clearContents()
            pb.setString(text, forType: .string)
        }
        pasteboardChangeCount = pb.changeCount
    }

    static func current() -> (text: String, linewise: Bool) {
        let pb = pasteboard
        if pb.changeCount != pasteboardChangeCount, let s = pb.string(forType: .string), !s.isEmpty {
            return (s, s.hasSuffix("\n"))
        }
        return (text, linewise)
    }
}

/// Vim state of one editor.
struct VimState {
    enum PromptKind: Character { case command = ":", searchForward = "/", searchBackward = "?" }
    struct Prompt {
        var kind: PromptKind
        var text = ""
        /// Caret when the prompt opened (search starts there; Esc goes back there).
        var origin: Int
    }

    var mode: VimMode = .normal
    var count: Int?
    var pendingOperator: Character?
    var operatorCount: Int?
    var pendingG = false
    var pendingZ = false
    var pendingReplace = false
    /// ⌃W pressed at this time; the next j / k picks the card.
    var windowArmedAt: Date?
    var prompt: Prompt?
    var lastSearch: (text: String, forward: Bool)?
    /// The next focus starts in Insert mode (new notes).
    var startInInsert = false

    // Visual mode: the fixed end and the moving end of the selection.
    var visualAnchor = 0
    var visualCursor = 0

    // Dot repeat. `changeKeys`: the keys of the command being typed. `insertRecording`: the command
    // entered Insert mode, so typed keys are recorded until Esc. `lastChange`: what `.` replays.
    var changeKeys: [VimKey] = []
    var insertRecording = false
    var lastChange: [VimKey] = []
    var replaying = false
    /// Set by every text edit of the vim layer (tells a finished command was a change).
    var didChange = false
    /// j / k keep this x (text container coordinates) while the caret stays where the last j / k put it,
    /// as vim keeps its wanted column across short lines and checkboxes.
    var goalX: CGFloat?
    var goalCaret: Int?

    var hasPending: Bool { count != nil || pendingOperator != nil || pendingG || pendingZ || pendingReplace || windowArmedAt != nil }

    mutating func resetPending() {
        count = nil; pendingOperator = nil; operatorCount = nil
        pendingG = false; pendingZ = false; pendingReplace = false; windowArmedAt = nil
    }
}

extension MarkdownNoteEditor {
    static let windowChordTimeout: TimeInterval = 1.5

    var vimEnabled: Bool { env.settings.vimKeybinds }
    var isVimNormal: Bool { vimEnabled && vim.mode == .normal }
    var isVimVisual: Bool { vimEnabled && (vim.mode == .visual || vim.mode == .visualLine) }
    /// Normal and Visual mode hide the bar caret (Normal draws a block, Visual shows the selection).
    var hidesBarCaret: Bool { vimEnabled && vim.mode != .insert }
    var storageString: NSString { textStorage.string as NSString }
    var caret: Int { min(textView.selectedRange().location, textStorage.length) }

    public var vimMode: VimMode? { vimEnabled ? vim.mode : nil }

    public func focus(atEnd: Bool, insertMode: Bool) {
        vim.startInInsert = insertMode
        focus(atEnd: atEnd)
        // Already first responder: focusDidChange is not called again.
        if insertMode, vimEnabled, isEditingFocused { setVimMode(.insert) }
        vim.startInInsert = false
    }

    // MARK: Mode

    /// Focus gained / lost. Every focus starts in Normal mode (unless `startInInsert`).
    func vimFocusChanged(_ focused: Bool) {
        vim.resetPending()
        vim.insertRecording = false
        vim.changeKeys = []
        closePrompt()
        guard vimEnabled else { vim.mode = .normal; updateCaretStyle(); return }
        if focused {
            setVimMode(vim.startInInsert ? .insert : .normal)
        } else {
            vim.mode = .normal
            updateCaretStyle()
        }
    }

    func setVimMode(_ m: VimMode) {
        vim.mode = m
        vim.resetPending()
        if m == .normal, textStorage.length > 0 {
            let r = textView.selectedRange()
            if r.length == 0 { setCaret(VimText.clampNormal(storageString, r.location, marker: vimMarker)) }
        }
        updateCaretStyle()
    }

    /// Settings changed (vim keys turned on / off).
    func vimSettingsChanged() {
        if !vimEnabled { closePrompt(); vim.resetPending() }
        vim.mode = vimEnabled && isEditingFocused ? .normal : vim.mode
        updateCaretStyle()
    }

    /// Normal mode draws a block caret (`MarkdownTextView.draw`) and hides the bar caret.
    func updateCaretStyle() {
        textView.insertionPointColor = hidesBarCaret ? .clear : style.text
        textView.needsDisplay = true
    }

    /// The block caret rectangle in text view coordinates (Normal mode, focused), else nil.
    var blockCaretRect: NSRect? {
        guard isVimNormal, isEditingFocused, textView.selectedRange().length == 0 else { return nil }
        let lm = layoutManagerNB
        lm.ensureLayout(for: container)
        let s = storageString
        let len = s.length
        let pos = min(textView.selectedRange().location, len)
        let font = mode == .code ? style.monoFont : style.bodyFont
        let fallbackW = max(4, ceil(("x" as NSString).size(withAttributes: [.font: font]).width))
        let lineH = ceil(lm.defaultLineHeight(for: font))
        let origin = textView.textContainerOrigin
        if len == 0 || (pos >= len && isNL(s.character(at: len - 1))) {
            let r = lm.extraLineFragmentRect
            return NSRect(x: r.minX + origin.x, y: r.minY + origin.y, width: fallbackW, height: lineH)
        }
        let charPos = pos >= len ? len - 1 : pos
        let g = lm.glyphIndexForCharacter(at: charPos)
        guard g < lm.numberOfGlyphs else { return nil }
        let frag = lm.lineFragmentRect(forGlyphAt: g, effectiveRange: nil)
        let br = lm.boundingRect(forGlyphRange: NSRange(location: g, length: 1), in: container)
        var x = br.minX, w = fallbackW
        if pos >= len {
            x = br.maxX
        } else if isNL(s.character(at: pos)) {
            x = frag.minX + lm.location(forGlyphAt: g).x
        } else if br.width > 0.5 {
            w = br.width
        }
        let h = max(8, min(frag.height, max(lineH, frag.height - style.lineSpacing)))
        return NSRect(x: x + origin.x, y: frag.minY + origin.y, width: w, height: h)
    }

    private func isNL(_ c: unichar) -> Bool { UC.isLineTerminator(c) }

    // MARK: Key entry points

    /// Called by `MarkdownTextView.keyDown`. True = the vim layer used the key.
    func vimHandleKeyDown(_ event: NSEvent) -> Bool {
        guard vimEnabled else { return false }
        return handleVimKey(VimKey.from(event))
    }

    /// Escape through the command path (cancelOperation:).
    func vimHandleEscape() -> Bool {
        guard vimEnabled else { return false }
        return handleVimKey(.escape)
    }

    func handleVimKey(_ key: VimKey) -> Bool {
        if vim.prompt != nil { return handlePromptKey(key) }
        switch vim.mode {
        case .insert:
            let handled = handleInsertKey(key)
            recordInsertKey(key)
            return handled
        case .normal: return handleNormalKey(key)
        case .visual, .visualLine: return handleVisualKey(key)
        }
    }

    /// Feeds one key like typing it: keys the vim layer does not take are typed (Insert mode).
    /// Used by `.` to replay a change. False = the key had no effect.
    @discardableResult
    func feedVimKey(_ key: VimKey) -> Bool {
        if handleVimKey(key) { return true }
        guard vim.mode == .insert else { return false }
        switch key {
        case .char(let c): textView.insertText(String(c), replacementRange: textView.selectedRange())
        case .enter: if !handleCommand(#selector(NSResponder.insertNewline(_:))) { textView.insertNewline(nil) }
        case .tab: if !handleCommand(#selector(NSResponder.insertTab(_:))) { textView.insertTab(nil) }
        case .backspace: textView.deleteBackward(nil)
        default: return false
        }
        return true
    }

    // MARK: Dot repeat

    /// Insert mode after a change command (i, a, o, cw ...): record what is typed, until Esc.
    private func recordInsertKey(_ key: VimKey) {
        guard vim.insertRecording, !vim.replaying else { return }
        switch key {
        case .char, .enter, .backspace, .tab, .ctrl("w"):
            vim.changeKeys.append(key)
        case .escape, .ctrl("["):
            guard vim.mode == .normal else { return }
            vim.changeKeys.append(.escape)
            vim.lastChange = vim.changeKeys
            vim.changeKeys = []
            vim.insertRecording = false
        case .navigation:
            // The caret moved away while typing: this insert cannot be replayed.
            vim.changeKeys = []
            vim.insertRecording = false
        default:
            break
        }
    }

    /// `.`: replays the last change. A count replaces the count of the change.
    private func repeatLastChange() {
        let count = vim.count
        vim.resetPending()
        guard !vim.lastChange.isEmpty else { return }
        var keys = vim.lastChange
        if let count {
            while let first = keys.first, case .char(let c) = first, c.isASCII, c.isNumber { keys.removeFirst() }
            keys = String(count).map { VimKey.char($0) } + keys
            vim.lastChange = keys
        }
        vim.replaying = true
        defer { vim.replaying = false }
        for k in keys { feedVimKey(k) }
        if vim.mode == .insert { setVimMode(.normal) }
    }

    private func handleInsertKey(_ key: VimKey) -> Bool {
        guard !textView.hasMarkedText() else { return false }
        switch key {
        case .escape, .ctrl("["):
            FormattingToolbar.shared.hide(for: self)
            let p = caret
            setVimMode(.normal)
            if p > VimText.lineStart(storageString, p) { setCaret(VimText.clampNormal(storageString, p - 1, marker: vimMarker)) }
            return true
        case .ctrl("w"):
            textView.deleteWordBackward(nil)
            return true
        default:
            return false
        }
    }

    // MARK: Normal mode

    private func handleNormalKey(_ key: VimKey) -> Bool {
        let fresh = !vim.hasPending
        if key == .char("."), vim.pendingOperator == nil, !vim.pendingG, !vim.pendingZ, !vim.pendingReplace,
           vim.windowArmedAt == nil {
            repeatLastChange()
            return true
        }
        if fresh { vim.changeKeys = [] }
        vim.changeKeys.append(key)
        vim.didChange = false
        let before = vim.mode
        let handled = normalKeyCore(key)
        // A finished command: remember it for `.` when it changed the text or started Insert mode.
        if !vim.hasPending, vim.prompt == nil, !vim.replaying {
            if before == .normal, vim.mode == .insert {
                vim.insertRecording = true
            } else {
                if vim.didChange, vim.mode == .normal { vim.lastChange = vim.changeKeys }
                vim.changeKeys = []
            }
        }
        return handled
    }

    private func normalKeyCore(_ key: VimKey) -> Bool {
        // ⌃W chord.
        if let armed = vim.windowArmedAt {
            vim.windowArmedAt = nil
            if Date().timeIntervalSince(armed) <= Self.windowChordTimeout {
                switch key {
                case .char("j"), .ctrl("j"): send(.focusNextCard); return true
                case .char("k"), .ctrl("k"): send(.focusPreviousCard); return true
                case .ctrl("w"): send(.focusNextCard); return true
                default: vim.resetPending(); return true
                }
            }
        }
        if vim.pendingReplace {
            vim.pendingReplace = false
            if case .char(let c) = key { replaceChars(with: c, count: takeCount()) } else { vim.resetPending() }
            return true
        }
        if vim.pendingZ {
            vim.pendingZ = false
            if key == .char("a") { send(.toggleFold) }
            if key == .char("c") { send(.setFolded(true)) }
            if key == .char("o") { send(.setFolded(false)) }
            vim.resetPending()
            return true
        }
        if vim.pendingG {
            vim.pendingG = false
            guard case .char(let c) = key else { vim.resetPending(); return true }
            switch c {
            case "g":
                let line = vim.count.map { $0 - 1 }
                runMotion(.fileStart(line: line))
            default:
                let cmds: [Character: VimCardCommand] = ["p": .togglePin, "c": .showColorMenu, "m": .showMoveMenu,
                                                         "y": .copyNote, "f": .showFormatMenu, "x": .delete,
                                                         "e": .toggleExpand]
                if vim.pendingOperator == nil, let cmd = cmds[c] {
                    send(cmd)
                } else if vim.pendingOperator == nil, c == "j" || c == "k" {
                    // gj / gk: visual lines, the same as j / k here.
                    runMotion(c == "j" ? .down : .up)
                } else {
                    vim.resetPending()
                }
            }
            return true
        }

        switch key {
        case .navigation, .other:
            vim.resetPending()
            return false
        case .ignored:
            vim.resetPending()
            return true
        case .escape, .ctrl("["):
            if vim.hasPending { vim.resetPending(); return true }
            if key == .ctrl("[") { send(.navigateUp); return true }
            if !searchRanges.isEmpty { clearSearchHighlight(); return true }
            FormattingToolbar.shared.hide(for: self)
            onEvent?(.escape)
            return true
        case .ctrl("r"):
            let n = takeCount()
            for _ in 0..<n where undo.canRedo { undo.redo() }
            clampCaret()
            return true
        case .ctrl("w"):
            vim.resetPending()
            vim.windowArmedAt = Date()
            return true
        case .ctrl:
            // No other control key may edit the text in Normal mode (⌃K, ⌃D, ⌃T ...).
            vim.resetPending()
            return true
        case .tab:
            vim.resetPending()
            send(.toggleFold)
            return true
        case .enter:
            runMotion(.nextLineStart)
            return true
        case .backspace:
            runMotion(.left)
            return true
        case .char(let c):
            handleNormalChar(c)
            return true
        }
    }

    private func handleNormalChar(_ c: Character) {
        // Counts.
        if let d = c.wholeNumberValue, c.isASCII, d > 0 || vim.count != nil {
            vim.count = min(99_999, (vim.count ?? 0) * 10 + d)
            return
        }
        if let op = vim.pendingOperator {
            if c == op {
                // dd / cc / yy: count lines.
                let n = takeCount()
                let s = storageString
                let p = caret
                let lastLine = VimText.target(.down, in: s, from: p, count: n - 1)
                applyOperator(op, VimText.linesRange(s, from: p, to: n > 1 ? lastLine : p))
                return
            }
            if let m = motion(for: c) {
                let n = takeCount()
                if let r = VimText.operatorRange(m, in: storageString, from: caret, count: n, change: op == "c", marker: vimMarker) {
                    applyOperator(op, r)
                } else {
                    vim.resetPending()
                    if op == "c" { setVimMode(.insert) }
                }
                return
            }
            if c == "g" { vim.pendingG = true; return }
            vim.resetPending()
            return
        }
        if let m = motion(for: c) { runMotion(m); return }
        let s = storageString
        let p = caret
        switch c {
        case "d", "c", "y":
            if textView.selectedRange().length > 0 {
                applyOperator(c, VimOperatorRange(range: textView.selectedRange(), linewise: false))
                return
            }
            vim.pendingOperator = c
            vim.operatorCount = vim.count
            vim.count = nil
        case "g": vim.pendingG = true
        case "z": vim.pendingZ = true
        case "r": vim.pendingReplace = true
        case "i": enterInsert(at: p)
        case "a": enterInsert(at: p < VimText.lineEnd(s, p) ? p + 1 : p)
        case "I": enterInsert(at: VimText.firstNonBlank(s, p, marker: vimMarker))
        case "A": enterInsert(at: VimText.lineEnd(s, p))
        case "o":
            vim.resetPending()
            setCaret(VimText.lineEnd(s, p))
            setVimMode(.insert)
            // Same as Return at the end of the line: lists and code indentation continue.
            if !handleCommand(#selector(NSResponder.insertNewline(_:))) { textView.insertNewline(nil) }
        case "O":
            vim.resetPending()
            applyEdit(VimText.openLine(below: false, in: s, at: p))
            setVimMode(.insert)
        case "x", "X", "s":
            let n = takeCount()
            if textView.selectedRange().length > 0 {
                applyOperator(c == "s" ? "c" : "d", VimOperatorRange(range: textView.selectedRange(), linewise: false))
                return
            }
            let m: VimMotion = c == "X" ? .left : .right
            if let r = VimText.operatorRange(m, in: s, from: p, count: n, marker: vimMarker) {
                applyOperator(c == "s" ? "c" : "d", r)
            } else if c == "s" {
                setVimMode(.insert)
            }
        case "D", "C":
            let n = takeCount()
            if let r = VimText.operatorRange(.lineEnd, in: s, from: p, count: n) {
                applyOperator(c == "D" ? "d" : "c", r)
            } else if c == "C" {
                setVimMode(.insert)
            }
        case "S":
            let n = takeCount()
            applyOperator("c", VimText.linesRange(s, from: p, to: n > 1 ? VimText.target(.down, in: s, from: p, count: n - 1) : p))
        case "Y":
            let n = takeCount()
            applyOperator("y", VimText.linesRange(s, from: p, to: n > 1 ? VimText.target(.down, in: s, from: p, count: n - 1) : p))
        case "p", "P":
            let n = takeCount()
            let reg = VimRegister.current()
            if let e = VimText.paste(reg.text, linewise: reg.linewise, before: c == "P", in: s, at: p, count: n) {
                applyEdit(e, actionName: "Paste")
            }
            clampCaret()
        case "u":
            let n = takeCount()
            for _ in 0..<n where undo.canUndo { undo.undo() }
            clampCaret()
        case "n", "N":
            let n = takeCount()
            searchAgain(reverse: c == "N", count: n)
        case "v": enterVisual(lines: false)
        case "V": enterVisual(lines: true)
        case "/": openPrompt(.searchForward)
        case "?": openPrompt(.searchBackward)
        case ":": openPrompt(.command)
        default:
            vim.resetPending()
        }
    }

    private func motion(for c: Character) -> VimMotion? {
        switch c {
        case "h": .left
        case "l", " ": .right
        case "j": .down
        case "k": .up
        case "w": .wordForward(big: false)
        case "W": .wordForward(big: true)
        case "b": .wordBackward(big: false)
        case "B": .wordBackward(big: true)
        case "e": .wordEnd(big: false)
        case "E": .wordEnd(big: true)
        case "0": .lineStart
        case "^", "_": .firstNonBlank
        case "$": .lineEnd
        case "G": .fileEnd(line: vim.count.map { $0 - 1 })
        case "+": .nextLineStart
        default: nil
        }
    }

    private func takeCount() -> Int {
        let n = max(1, vim.count ?? 1) * max(1, vim.operatorCount ?? 1)
        vim.count = nil
        vim.operatorCount = nil
        return n
    }

    private func runMotion(_ m: VimMotion) {
        if let op = vim.pendingOperator {
            let n = takeCount()
            if let r = VimText.operatorRange(m, in: storageString, from: caret, count: n, change: op == "c", marker: vimMarker) {
                applyOperator(op, r)
            } else {
                vim.resetPending()
            }
            return
        }
        let n = takeCount()
        vim.resetPending()
        switch m {
        case .down, .up:
            // Plain j / k move by visual line (notes wrap a lot in the narrow panel).
            let goal = vim.goalCaret == caret ? (vim.goalX ?? caretX()) : caretX()
            for _ in 0..<n {
                if m == .down { if caretOnLastLine() { break } } else if caretOnFirstLine() { break }
                guard let p = visualLineTarget(down: m == .down, x: goal) else { break }
                // The caret never sits on a line break (unless the line is empty) or on a checkbox.
                setCaret(VimText.clampNormal(storageString, p, marker: vimMarker))
            }
            vim.goalX = goal
            vim.goalCaret = caret
            textView.scrollRangeToVisible(textView.selectedRange())
        default:
            setCaret(VimText.target(m, in: storageString, from: caret, count: n, marker: vimMarker), scroll: true)
        }
    }

    /// x of the Normal-mode caret (left edge of the character under the block caret), container coordinates.
    private func caretX() -> CGFloat {
        let lm = layoutManagerNB
        lm.ensureLayout(for: container)
        let s = storageString
        let p = caret
        guard p < s.length, lm.numberOfGlyphs > 0 else { return lineRect(forCharacter: p).minX }
        let g = lm.glyphIndexForCharacter(at: p)
        if isNL(s.character(at: p)) {
            return lm.lineFragmentRect(forGlyphAt: g, effectiveRange: nil).minX + lm.location(forGlyphAt: g).x
        }
        return lm.boundingRect(forGlyphRange: NSRange(location: g, length: 1), in: container).minX
    }

    /// The character under `x` on the visual line below / above the caret (nil at the first / last line).
    private func visualLineTarget(down: Bool, x: CGFloat) -> Int? {
        let lm = layoutManagerNB
        lm.ensureLayout(for: container)
        let len = textStorage.length
        let cur = lineRect(forCharacter: caret)
        let y = down ? cur.maxY + 1 : cur.minY - 1
        guard y >= 0 else { return nil }
        if lm.extraLineFragmentTextContainer != nil, y >= lm.extraLineFragmentRect.minY { return len }
        guard lm.numberOfGlyphs > 0 else { return nil }
        let g = lm.glyphIndex(for: NSPoint(x: max(0, x), y: y), in: container, fractionOfDistanceThroughGlyph: nil)
        return min(lm.characterIndexForGlyph(at: g), len)
    }

    private func enterInsert(at p: Int) {
        vim.resetPending()
        setVimMode(.insert)
        setCaret(p)
    }

    /// Checkbox attachments are line markers: the Normal-mode caret skips them (see `VimText.Marker`).
    var vimMarker: VimText.Marker { { [unowned self] in self.checkboxState(at: $0) != nil } }

    func setCaret(_ p: Int, scroll: Bool = false) {
        let loc = min(max(0, p), textStorage.length)
        textView.setSelectedRange(NSRange(location: loc, length: 0))
        if scroll { textView.scrollRangeToVisible(NSRange(location: loc, length: 0)) }
        textView.needsDisplay = true
    }

    private func clampCaret() {
        guard isVimNormal else { return }
        let r = textView.selectedRange()
        setCaret(VimText.clampNormal(storageString, r.location, marker: vimMarker))
    }

    // MARK: Edits

    private func applyOperator(_ op: Character, _ r: VimOperatorRange) {
        vim.resetPending()
        let s = storageString
        let text = markdown(for: r.range)
        switch op {
        case "y":
            VimRegister.store(r.linewise ? VimText.linewiseRegister(text) : text, linewise: r.linewise, toPasteboard: true)
            // Charwise: the caret goes to the start of the yanked text. Linewise: it stays unless the
            // yank started on an earlier line (yk).
            if !r.linewise {
                setCaret(r.range.location)
            } else if r.range.location < VimText.lineStart(s, caret) {
                setCaret(VimText.firstNonBlank(s, r.range.location, marker: vimMarker))
            }
            clampCaret()
        case "d":
            VimRegister.store(r.linewise ? VimText.linewiseRegister(text) : text, linewise: r.linewise, toPasteboard: false)
            let del = r.linewise ? VimText.linewiseDeleteRange(s, r.range) : r.range
            applyEdit(VimEdit(range: del, text: "", caret: del.location), actionName: "Delete")
            if r.linewise { setCaret(VimText.firstNonBlank(storageString, min(del.location, storageString.length), marker: vimMarker)) }
            clampCaret()
        case "c":
            VimRegister.store(r.linewise ? VimText.linewiseRegister(text) : text, linewise: r.linewise, toPasteboard: false)
            var range = r.range
            if r.linewise {
                // Keep the (last) line break: the caret stays on an empty line.
                let e = VimText.lineEnd(s, max(r.range.location, r.range.end - 1))
                // A checklist line keeps its checkbox (like autoindent keeps the indent).
                let fnb = VimText.firstNonBlank(s, r.range.location)
                let start = fnb < e && vimMarker(fnb) ? fnb + 1 : r.range.location
                range = NSRange(location: start, length: max(0, e - start))
            }
            setVimMode(.insert)
            applyEdit(VimEdit(range: range, text: "", caret: range.location), actionName: "Change")
        default:
            break
        }
    }

    private func replaceChars(with c: Character, count n: Int) {
        let s = storageString
        let p = caret
        let e = VimText.lineEnd(s, p)
        guard p + n <= e else { return }
        let rep = String(repeating: String(c), count: n)
        applyEdit(VimEdit(range: NSRange(location: p, length: n), text: rep, caret: p + (rep as NSString).length - 1),
                  actionName: "Replace")
    }

    /// One undoable change through the text view. Raw markdown (checkbox / attachment tokens) in
    /// `text` becomes attachments, as when typing.
    func applyEdit(_ e: VimEdit, actionName: String? = nil) {
        let len = textStorage.length
        let r = NSRange(location: min(e.range.location, len), length: min(e.range.length, len - min(e.range.location, len)))
        textView.breakUndoCoalescing()
        guard textView.shouldChangeText(in: r, replacementString: e.text) else { return }
        textStorage.replaceCharacters(in: r, with: NSAttributedString(string: e.text, attributes: baseAttributes))
        textView.setSelectedRange(NSRange(location: min(max(0, e.caret), textStorage.length), length: 0))
        textView.didChangeText()
        vim.didChange = true
        if let actionName { undo.setActionName(actionName) }
        textView.breakUndoCoalescing()
        textView.scrollRangeToVisible(textView.selectedRange())
        textView.needsDisplay = true
    }

    private func send(_ cmd: VimCardCommand) {
        vim.resetPending()
        onEvent?(.vim(cmd))
    }

    // MARK: Prompt (: / ?)

    var promptHeight: CGFloat { vimPrompt == nil ? 0 : VimPromptView.height(font: style.bodyFont) }

    private func openPrompt(_ kind: VimState.PromptKind) {
        vim.resetPending()
        vim.prompt = VimState.Prompt(kind: kind, origin: caret)
        if vimPrompt == nil {
            let v = VimPromptView(frame: .zero)
            addSubview(v)
            vimPrompt = v
        }
        refreshPrompt()
        needsLayout = true
        layoutDidChange()
        if let v = vimPrompt { scrollToVisible(v.frame) }
    }

    func closePrompt() {
        vim.prompt = nil
        guard let v = vimPrompt else { return }
        v.removeFromSuperview()
        vimPrompt = nil
        needsLayout = true
        layoutDidChange()
    }

    private func refreshPrompt() {
        guard let p = vim.prompt, let v = vimPrompt else { return }
        v.configure(prefix: String(p.kind.rawValue), text: p.text, font: mode == .code ? style.monoFont : style.bodyFont,
                    color: style.text, secondary: style.text.withAlphaComponent(0.55))
    }

    private func handlePromptKey(_ key: VimKey) -> Bool {
        guard var p = vim.prompt else { return false }
        switch key {
        case .escape, .ctrl("["), .ctrl("c"):
            if p.kind != .command { clearSearchHighlight(); setCaret(p.origin) }
            closePrompt()
        case .enter:
            closePrompt()
            runPrompt(p)
        case .backspace:
            if p.text.isEmpty {
                if p.kind != .command { clearSearchHighlight() }
                closePrompt()
                return true
            }
            p.text.removeLast()
            vim.prompt = p
            promptTextChanged()
        case .ctrl("u"):
            p.text = ""
            vim.prompt = p
            promptTextChanged()
        case .char(let c):
            p.text.append(c)
            vim.prompt = p
            promptTextChanged()
        case .tab, .ctrl, .ignored, .navigation:
            break
        case .other:
            return false
        }
        return true
    }

    private func promptTextChanged() {
        refreshPrompt()
        guard let p = vim.prompt, p.kind != .command else { return }
        // Incremental search: mark every match and scroll to the one the search would land on.
        highlightSearch(p.text)
        if let m = searchMatch(from: p.origin, forward: p.kind == .searchForward, count: 1) {
            textView.scrollRangeToVisible(m)
        }
    }

    private func runPrompt(_ p: VimState.Prompt) {
        switch p.kind {
        case .searchForward, .searchBackward:
            let q = p.text.isEmpty ? (vim.lastSearch?.text ?? "") : p.text
            guard !q.isEmpty else { return }
            vim.lastSearch = (q, p.kind == .searchForward)
            highlightSearch(q)
            if let m = searchMatch(from: p.origin, forward: p.kind == .searchForward, count: 1) {
                setCaret(m.location, scroll: true)
                if window?.isVisible == true { textView.showFindIndicator(for: m) }
            } else {
                setCaret(p.origin)
                send(.message("Pattern not found: \(q)"))
            }
        case .command:
            runEx(VimEx.parse(p.text))
        }
    }

    func runEx(_ cmd: VimExCommand) {
        switch cmd {
        case .none: break
        case .write: reportBody()
        case .card(let c):
            if c == .quit { reportBody() }
            send(c)
        case .goToLine(let n):
            setCaret(VimText.firstNonBlank(storageString, VimText.startOfLine(storageString, n - 1), marker: vimMarker), scroll: true)
        case .noHighlight: clearSearchHighlight()
        case .error(let msg): send(.message(msg))
        }
    }

    // MARK: Search (n / N)

    /// The match `count` steps from `pos` (exclusive) in the current marks, wrapping around.
    private func searchMatch(from pos: Int, forward: Bool, count: Int) -> NSRange? {
        let ranges = searchRanges
        guard !ranges.isEmpty else { return nil }
        var p = pos
        var hit: NSRange?
        for _ in 0..<max(1, count) {
            if forward {
                hit = ranges.first { $0.location > p } ?? ranges.first
            } else {
                hit = ranges.last { $0.location < p } ?? ranges.last
            }
            p = hit?.location ?? p
        }
        return hit
    }

    private func searchAgain(reverse: Bool, count: Int) {
        vim.resetPending()
        guard let last = vim.lastSearch else { return }
        if searchRanges.isEmpty { highlightSearch(last.text) }
        let forward = last.forward != reverse
        if let m = searchMatch(from: caret, forward: forward, count: count) {
            setCaret(m.location, scroll: true)
        } else {
            send(.message("Pattern not found: \(last.text)"))
        }
    }
}

// MARK: - Visual mode

extension MarkdownNoteEditor {
    func enterVisual(lines: Bool) {
        vim.resetPending()
        vim.visualAnchor = caret
        vim.visualCursor = caret
        vim.mode = lines ? .visualLine : .visual
        updateVisualSelection()
        updateCaretStyle()
    }

    /// Back to Normal mode with the caret on `at` (default: the moving end).
    func exitVisual(at p: Int? = nil) {
        vim.resetPending()
        vim.mode = .normal
        setCaret(VimText.clampNormal(storageString, p ?? vim.visualCursor, marker: vimMarker))
        updateCaretStyle()
    }

    /// The selected text: characters from end to end (inclusive), or whole lines.
    var visualRange: VimOperatorRange {
        let s = storageString
        let lo = min(vim.visualAnchor, vim.visualCursor), hi = max(vim.visualAnchor, vim.visualCursor)
        if vim.mode == .visualLine { return VimText.linesRange(s, from: lo, to: hi) }
        let end = min(s.length, hi + 1)
        return VimOperatorRange(range: NSRange(location: lo, length: max(0, end - lo)), linewise: false)
    }

    func updateVisualSelection() {
        let len = textStorage.length
        vim.visualAnchor = min(vim.visualAnchor, len)
        vim.visualCursor = min(vim.visualCursor, len)
        textView.setSelectedRange(visualRange.range)
        textView.scrollRangeToVisible(NSRange(location: vim.visualCursor, length: 0))
        textView.needsDisplay = true
    }

    func handleVisualKey(_ key: VimKey) -> Bool {
        if vim.pendingReplace {
            vim.pendingReplace = false
            if case .char(let c) = key { visualTransform { _ in String(c) } } else { vim.resetPending() }
            return true
        }
        if vim.pendingG {
            vim.pendingG = false
            if key == .char("g") { moveVisual(.fileStart(line: vim.count.map { $0 - 1 })) } else { vim.resetPending() }
            return true
        }
        switch key {
        case .escape, .ctrl("["):
            if vim.hasPending { vim.resetPending() } else { exitVisual() }
            return true
        case .other:
            return false
        case .navigation, .ignored, .ctrl, .tab:
            return true
        case .enter:
            moveVisual(.nextLineStart)
            return true
        case .backspace:
            moveVisual(.left)
            return true
        case .char(let c):
            if let d = c.wholeNumberValue, c.isASCII, d > 0 || vim.count != nil {
                vim.count = min(99_999, (vim.count ?? 0) * 10 + d)
                return true
            }
            if let m = visualMotion(for: c) { moveVisual(m); return true }
            let lines = vim.mode == .visualLine
            switch c {
            case "v": if lines { vim.mode = .visual; updateVisualSelection() } else { exitVisual() }
            case "V": if lines { exitVisual() } else { vim.mode = .visualLine; updateVisualSelection() }
            case "o", "O":
                (vim.visualAnchor, vim.visualCursor) = (vim.visualCursor, vim.visualAnchor)
                updateVisualSelection()
            case "g": vim.pendingG = true
            case "r": vim.pendingReplace = true
            case "d", "x": visualOperator("d", lines: lines)
            case "D", "X": visualOperator("d", lines: true)
            case "y": visualOperator("y", lines: lines)
            case "Y": visualOperator("y", lines: true)
            case "c", "s": visualOperator("c", lines: lines)
            case "C", "S", "R": visualOperator("c", lines: true)
            case "p", "P": visualPaste(keepRegister: c == "P")
            case "u": visualTransform { $0.lowercased() }
            case "U": visualTransform { $0.uppercased() }
            case "~": visualTransform { String($0.map { $0.isUppercase ? Character($0.lowercased()) : Character($0.uppercased()) }) }
            default: vim.resetPending()
            }
            return true
        }
    }

    private func visualMotion(for c: Character) -> VimMotion? {
        switch c {
        case "h": .left
        case "l", " ": .right
        case "j": .down
        case "k": .up
        case "w": .wordForward(big: false)
        case "W": .wordForward(big: true)
        case "b": .wordBackward(big: false)
        case "B": .wordBackward(big: true)
        case "e": .wordEnd(big: false)
        case "E": .wordEnd(big: true)
        case "0": .lineStart
        case "^", "_": .firstNonBlank
        case "$": .lineEnd
        case "G": .fileEnd(line: vim.count.map { $0 - 1 })
        case "+": .nextLineStart
        default: nil
        }
    }

    private func moveVisual(_ m: VimMotion) {
        let n = max(1, vim.count ?? 1)
        vim.resetPending()
        var t = VimText.target(m, in: storageString, from: vim.visualCursor, count: n, marker: vimMarker)
        // `w` may land after the last character; the selection end stays on a character.
        if t >= storageString.length { t = max(0, storageString.length - 1) }
        vim.visualCursor = t
        updateVisualSelection()
    }

    /// d / c / y on the selection. `.` repeats d and c on the same number of lines / characters.
    private func visualOperator(_ op: Character, lines: Bool) {
        let s = storageString
        var r = visualRange
        if lines, !r.linewise {
            r = VimText.linesRange(s, from: r.range.location, to: max(r.range.location, r.range.end - 1))
        }
        let repeatKeys = dotKeys(op, r)
        vim.resetPending()
        vim.mode = .normal
        setCaret(r.range.location)
        guard r.range.length > 0 else { updateCaretStyle(); return }
        applyOperator(op, r)
        updateCaretStyle()
        guard !vim.replaying, let repeatKeys else { return }
        if op == "d" {
            vim.lastChange = repeatKeys
        } else if op == "c" {
            vim.changeKeys = repeatKeys
            vim.insertRecording = true
        }
    }

    /// The Normal-mode keys that redo a visual change: `{n}dd` for lines, `d{n}l` within one line.
    /// nil: a charwise selection over several lines (not repeated).
    private func dotKeys(_ op: Character, _ r: VimOperatorRange) -> [VimKey]? {
        guard op != "y" else { return nil }
        let s = storageString
        func keys(_ str: String) -> [VimKey] { str.map { VimKey.char($0) } }
        if r.linewise {
            let n = VimText.lineIndex(s, max(r.range.location, r.range.end - 1)) - VimText.lineIndex(s, r.range.location) + 1
            return keys((n > 1 ? "\(n)" : "") + String(op) + String(op))
        }
        let sub = s.substring(with: r.range)
        guard !sub.contains(where: { $0.isNewline }) else { return nil }
        return keys(String(op) + "\(r.range.length)l")
    }

    /// p / P: replace the selection with the register. `p` puts the replaced text in the register.
    private func visualPaste(keepRegister: Bool) {
        let reg = VimRegister.current()
        let r = visualRange
        var text = reg.text
        if r.linewise, !reg.linewise { text += "\n" }
        if !r.linewise, reg.linewise, text.hasSuffix("\n") { text.removeLast() }
        let old = markdown(for: r.range)
        vim.resetPending()
        vim.mode = .normal
        applyEdit(VimEdit(range: r.range, text: text, caret: r.range.location), actionName: "Paste")
        if !keepRegister { VimRegister.store(old, linewise: r.linewise, toPasteboard: false) }
        clampCaretAfterVisual()
        updateCaretStyle()
    }

    /// r{c}, u, U, ~ on the selection. Attachments and line breaks are kept.
    private func visualTransform(_ f: (String) -> String) {
        let s = storageString
        let r = visualRange.range
        vim.resetPending()
        vim.mode = .normal
        var segments: [NSRange] = []
        var start: Int?
        for i in r.location..<r.end {
            let ch = s.character(at: i)
            let keep = ch == UC.attachment || UC.isLineTerminator(ch)
            if keep {
                if let a = start { segments.append(NSRange(location: a, length: i - a)); start = nil }
            } else if start == nil {
                start = i
            }
        }
        if let a = start { segments.append(NSRange(location: a, length: r.end - a)) }
        for seg in segments.reversed() {
            let text = s.substring(with: seg)
            let new = f(text)
            // r{c} replaces each character (one UTF-16 unit for most text).
            let out = new.count == 1 && text.count > 1 ? String(repeating: new, count: text.count) : new
            if out != text { applyEdit(VimEdit(range: seg, text: out, caret: r.location)) }
        }
        setCaret(r.location)
        clampCaretAfterVisual()
        updateCaretStyle()
    }

    private func clampCaretAfterVisual() {
        setCaret(VimText.clampNormal(storageString, caret, marker: vimMarker))
    }
}

// MARK: - Prompt view

/// The `:` / `/` line at the bottom of the editor. Keys still go to the text view (it keeps focus);
/// this view only shows the command line.
final class VimPromptView: NSView {
    private let label = NSTextField(labelWithString: "")
    private var lineColor: NSColor = .separatorColor

    static func height(font: NSFont) -> CGFloat { ceil(font.ascender - font.descender + font.leading) + 10 }

    override init(frame: NSRect) {
        super.init(frame: frame)
        label.lineBreakMode = .byTruncatingHead
        label.maximumNumberOfLines = 1
        label.setAccessibilityLabel("Vim command line")
        addSubview(label)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func configure(prefix: String, text: String, font: NSFont, color: NSColor, secondary: NSColor) {
        let s = NSMutableAttributedString(string: prefix, attributes: [.font: font, .foregroundColor: secondary])
        s.append(NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color]))
        s.append(NSAttributedString(string: "▏", attributes: [.font: font, .foregroundColor: color]))
        label.attributedStringValue = s
        lineColor = secondary.withAlphaComponent(0.3)
        needsLayout = true
        needsDisplay = true
    }

    /// For checks: the shown command line (without the caret mark).
    var displayedText: String { String(label.stringValue.dropLast()) }

    override func layout() {
        super.layout()
        let h = ceil(label.intrinsicContentSize.height)
        label.frame = NSRect(x: 0, y: 6 + max(0, (bounds.height - 6 - h) / 2), width: bounds.width, height: h)
    }

    override func draw(_ dirtyRect: NSRect) {
        lineColor.setFill()
        NSRect(x: 0, y: 2, width: bounds.width, height: 1).fill()
    }
}
