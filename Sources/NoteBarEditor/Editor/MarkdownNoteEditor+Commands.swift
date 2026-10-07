import AppKit
import NoteBarCore

/// Text colors offered by the toolbar (hex values are stored in the markdown).
public enum TextColorPalette {
    public static let colors: [(name: String, hex: String)] = [
        ("Red", "#E5484D"), ("Orange", "#F76B15"), ("Yellow", "#D69E00"), ("Green", "#30A46C"),
        ("Teal", "#12A594"), ("Blue", "#0D74CE"), ("Purple", "#8E4EC6"), ("Pink", "#D6409F"), ("Gray", "#8B8D98"),
    ]
}

extension MarkdownNoteEditor {
    // MARK: Format actions

    public func perform(_ action: FormatAction) {
        if action == .copy { copyToPasteboard(); return }
        guard mode == .standard, textView.isEditable else { return }
        switch action {
        case .copy: break
        case .bold: transform("Bold") { FormatEditing.toggle(.bold, text: $0, selection: $1) }
        case .italic: transform("Italic") { FormatEditing.toggle(.italic, text: $0, selection: $1) }
        case .strikethrough: transform("Strikethrough") { FormatEditing.toggle(.strike, text: $0, selection: $1) }
        case .highlight: transform("Highlight") { FormatEditing.toggle(.highlight, text: $0, selection: $1) }
        case .underline: transform("Underline") { FormatEditing.toggle(.underline, text: $0, selection: $1) }
        case .inlineCode: transform("Code") { FormatEditing.toggle(.code, text: $0, selection: $1) }
        case .codeBlock: transform("Code Block") { FormatEditing.toggleCodeBlock(text: $0, selection: $1) }
        case .bulletList: transform("Bulleted List") { FormatEditing.toggleList(.bullet, text: $0, selection: $1) }
        case .numberedList: transform("Numbered List") { FormatEditing.toggleList(.numbered, text: $0, selection: $1) }
        case .checklist: transform("Checklist") { FormatEditing.toggleList(.checklist, text: $0, selection: $1) }
        case .quote: transform("Quote") { FormatEditing.toggleQuote(text: $0, selection: $1) }
        case .heading: transform("Heading") { FormatEditing.cycleHeading(text: $0, selection: $1) }
        case .clearFormatting: transform("Clear Formatting") { FormatEditing.clearFormatting(text: $0, selection: $1) }
        case .link:
            let url = Self.clipboardURL()
            transform("Link") { FormatEditing.toggleLink(text: $0, selection: $1, url: url) }
        case .textColor:
            showColorMenu(relativeTo: nil)
        }
        scheduleToolbarUpdate()
    }

    /// Sets (or with nil removes) the text color of the selection.
    public func applyTextColor(hex: String?) {
        guard mode == .standard else { return }
        transform(hex == nil ? "Remove Color" : "Text Color") { FormatEditing.setColor(hex, text: $0, selection: $1) }
        scheduleToolbarUpdate()
    }

    /// Heading level for the selected lines (0 = plain paragraph).
    public func setHeading(level: Int) {
        guard mode == .standard else { return }
        transform("Heading") { FormatEditing.setHeading(level == 0 ? nil : level, text: $0, selection: $1, toggle: level != 0) }
    }

    func transform(_ name: String, _ f: (String, NSRange) -> TextEditResult?) {
        let md = markdown
        guard let r = f(md, markdownSelection) else { return }
        replaceMarkdown(r.text, selection: r.selection, undoable: true, actionName: name)
    }

    func copyToPasteboard() {
        let sel = textView.selectedRange()
        let text = sel.length > 0 ? markdown(for: sel) : markdown
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }

    static func clipboardURL() -> String? {
        guard let s = NSPasteboard.general.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !s.contains(where: { $0.isWhitespace }), s.count < 2048 else { return nil }
        if let u = URL(string: s), let scheme = u.scheme?.lowercased(), ["http", "https", "mailto", "file", "ftp"].contains(scheme) || scheme.count > 2 && u.host != nil {
            return s
        }
        if s.lowercased().hasPrefix("www.") { return "https://" + s }
        return nil
    }

    // MARK: Text color menu

    func colorMenu() -> NSMenu {
        let menu = NSMenu(title: "Text Color")
        for (name, hex) in TextColorPalette.colors {
            let item = NSMenuItem(title: name, action: #selector(colorMenuPicked(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = hex
            item.image = Self.swatchImage(NSColor(hex: hex) ?? .labelColor)
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let none = NSMenuItem(title: "Default Color", action: #selector(colorMenuPicked(_:)), keyEquivalent: "")
        none.target = self
        menu.addItem(none)
        return menu
    }

    /// Shows the palette below `view` (toolbar button) or at the selection.
    func showColorMenu(relativeTo view: NSView?) {
        let menu = colorMenu()
        if let view {
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: view.bounds.height + 4), in: view)
            return
        }
        let sel = textView.selectedRange()
        let g = layoutManagerNB.glyphRange(forCharacterRange: NSRange(location: sel.location, length: max(1, min(sel.length, textStorage.length - sel.location))),
                                           actualCharacterRange: nil)
        var rect = layoutManagerNB.boundingRect(forGlyphRange: g, in: container)
        if textStorage.length == 0 { rect = .zero }
        menu.popUp(positioning: nil, at: NSPoint(x: rect.minX, y: rect.maxY + 4), in: textView)
    }

    @objc func colorMenuPicked(_ sender: NSMenuItem) {
        applyTextColor(hex: sender.representedObject as? String)
    }

    static func swatchImage(_ color: NSColor) -> NSImage {
        NSImage(size: NSSize(width: 14, height: 14), flipped: false) { r in
            let p = NSBezierPath(ovalIn: r.insetBy(dx: 1, dy: 1))
            color.setFill()
            p.fill()
            NSColor.black.withAlphaComponent(0.15).setStroke()
            p.lineWidth = 0.5
            p.stroke()
            return true
        }
    }

    // MARK: Keyboard shortcuts

    /// ⌘B bold · ⌘I italic · ⌘U underline · ⇧⌘X strike · ⇧⌘H highlight · ⌘K link · ⌘E inline code ·
    /// ⌥⌘C code block · ⇧⌘L checklist · ⇧⌘8 bullets · ⇧⌘7 numbers · ⌘' quote · ⌘1/2/3 headings · ⌘0 paragraph ·
    /// ⌘\ clear formatting.
    func shortcutAction(for event: NSEvent) -> FormatAction? {
        guard event.type == .keyDown, mode == .standard else { return nil }
        let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
        switch flags {
        case [.command]:
            switch key {
            case "b": return .bold
            case "i": return .italic
            case "u": return .underline
            case "k": return .link
            case "e": return .inlineCode
            case "'": return .quote
            case "\\": return .clearFormatting
            default: break
            }
            return nil
        case [.command, .shift]:
            switch key {
            case "x": return .strikethrough
            case "h": return .highlight
            case "l": return .checklist
            default: break
            }
            switch event.keyCode {
            case 0x1C: return .bulletList   // 8
            case 0x1A: return .numberedList // 7
            case 0x19: return .checklist    // 9
            default: return nil
            }
        case [.command, .option]:
            if event.keyCode == 0x08 { return .codeBlock } // C
            return nil
        default:
            return nil
        }
    }

    /// ⌘1 / ⌘2 / ⌘3 heading level, ⌘0 plain paragraph.
    func headingShortcutLevel(_ event: NSEvent) -> Int? {
        guard event.type == .keyDown, mode == .standard,
              event.modifierFlags.intersection([.command, .shift, .option, .control]) == [.command] else { return nil }
        switch event.keyCode {
        case 0x12: return 1
        case 0x13: return 2
        case 0x14: return 3
        case 0x1D: return 0
        default: return nil
        }
    }

    // MARK: Text view commands

    func handleCommand(_ sel: Selector) -> Bool {
        switch sel {
        case #selector(NSResponder.cancelOperation(_:)):
            FormattingToolbar.shared.hide(for: self)
            onEvent?(.escape)
            return true
        case #selector(NSResponder.moveUp(_:)):
            if caretOnFirstLine() { onEvent?(.focusPrevious); return onEvent != nil }
            return false
        case #selector(NSResponder.moveDown(_:)):
            if caretOnLastLine() { onEvent?(.focusNext); return onEvent != nil }
            return false
        case #selector(NSResponder.insertNewline(_:)):
            if NSApp.currentEvent?.modifierFlags.contains(.shift) == true { return false }
            return handleNewline()
        case #selector(NSResponder.insertTab(_:)):
            return handleTab(outdent: false)
        case #selector(NSResponder.insertBacktab(_:)):
            return handleTab(outdent: true)
        default:
            return false
        }
    }

    private func handleNewline() -> Bool {
        guard !textView.hasMarkedText() else { return false }
        let md = markdown
        let sel = markdownSelection
        let r: TextEditResult?
        switch mode {
        case .standard: r = ListEditing.newline(text: md, selection: sel)
        case .code: r = sel.length == 0 ? ListEditing.newlineKeepingIndent(text: md, selection: sel) : nil
        case .plain: r = nil
        }
        guard let r else { return false }
        replaceMarkdown(r.text, selection: r.selection, undoable: true, actionName: "Typing")
        textView.scrollRangeToVisible(textView.selectedRange())
        return true
    }

    private func handleTab(outdent: Bool) -> Bool {
        let md = markdown
        let sel = markdownSelection
        switch mode {
        case .code:
            let r = ListEditing.codeIndent(text: md, selection: sel, outdent: outdent)
            replaceMarkdown(r.text, selection: r.selection, undoable: true, actionName: outdent ? "Outdent" : "Indent")
            return true
        case .standard:
            if let r = ListEditing.indent(text: md, selection: sel, outdent: outdent) {
                replaceMarkdown(r.text, selection: r.selection, undoable: true, actionName: outdent ? "Outdent" : "Indent")
                return true
            }
            return outdent
        case .plain:
            return outdent
        }
    }

    // MARK: Caret position

    private func lineRect(forCharacter loc: Int) -> NSRect {
        let lm = layoutManagerNB
        lm.ensureLayout(for: container)
        if textStorage.length == 0 { return lm.extraLineFragmentRect }
        if loc >= textStorage.length {
            if lm.extraLineFragmentTextContainer != nil { return lm.extraLineFragmentRect }
            return lm.lineFragmentRect(forGlyphAt: max(0, lm.numberOfGlyphs - 1), effectiveRange: nil)
        }
        return lm.lineFragmentRect(forGlyphAt: lm.glyphIndexForCharacter(at: loc), effectiveRange: nil)
    }

    func caretOnFirstLine() -> Bool {
        guard textStorage.length > 0, layoutManagerNB.numberOfGlyphs > 0 else { return true }
        let first = layoutManagerNB.lineFragmentRect(forGlyphAt: 0, effectiveRange: nil)
        return lineRect(forCharacter: textView.selectedRange().location).minY <= first.minY + 0.5
    }

    func caretOnLastLine() -> Bool {
        guard textStorage.length > 0, layoutManagerNB.numberOfGlyphs > 0 else { return true }
        let lm = layoutManagerNB
        let last = lm.extraLineFragmentTextContainer != nil ? lm.extraLineFragmentRect
                                                             : lm.lineFragmentRect(forGlyphAt: lm.numberOfGlyphs - 1, effectiveRange: nil)
        return lineRect(forCharacter: textView.selectedRange().end).minY >= last.minY - 0.5
    }

    // MARK: Context menu

    func formatMenu() -> NSMenu {
        let menu = NSMenu(title: "Format")
        let items: [(String, FormatAction, String, NSEvent.ModifierFlags)] = [
            ("Bold", .bold, "b", [.command]), ("Italic", .italic, "i", [.command]),
            ("Underline", .underline, "u", [.command]), ("Strikethrough", .strikethrough, "x", [.command, .shift]),
            ("Highlight", .highlight, "h", [.command, .shift]), ("Inline Code", .inlineCode, "e", [.command]),
            ("Link", .link, "k", [.command]),
        ]
        for (t, a, k, m) in items { menu.addItem(formatItem(t, a, k, m)) }
        let color = NSMenuItem(title: "Text Color", action: nil, keyEquivalent: "")
        color.submenu = colorMenu()
        menu.addItem(color)
        menu.addItem(.separator())
        menu.addItem(formatItem("Heading", .heading, "", []))
        menu.addItem(formatItem("Quote", .quote, "'", [.command]))
        menu.addItem(formatItem("Code Block", .codeBlock, "c", [.command, .option]))
        menu.addItem(.separator())
        menu.addItem(formatItem("Bulleted List", .bulletList, "8", [.command, .shift]))
        menu.addItem(formatItem("Numbered List", .numberedList, "7", [.command, .shift]))
        menu.addItem(formatItem("Checklist", .checklist, "l", [.command, .shift]))
        menu.addItem(.separator())
        menu.addItem(formatItem("Clear Formatting", .clearFormatting, "\\", [.command]))
        return menu
    }

    private func formatItem(_ title: String, _ action: FormatAction, _ key: String, _ mods: NSEvent.ModifierFlags) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(formatMenuPicked(_:)), keyEquivalent: key)
        item.keyEquivalentModifierMask = mods
        item.target = self
        item.representedObject = action.rawValue
        return item
    }

    @objc func formatMenuPicked(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let a = FormatAction(rawValue: raw) else { return }
        perform(a)
    }
}

// MARK: - Diagnostics (used by EditorChecks)

extension MarkdownNoteEditor {
    /// The underlying text view (for checks and snapshot tooling).
    public var textViewForTesting: NSTextView { textView }
    public var undoManagerForTesting: UndoManager { undo }
    /// Character ranges whose markers are currently revealed.
    public var revealedRangesForTesting: [NSRange] { layoutManagerNB.revealed }

    /// "image:loaded" / "image:missing" / "image:pending" / "file:ok" / "file:missing" / "checkbox" per attachment.
    public var attachmentStatesForTesting: [String] {
        var out: [String] = []
        let len = textStorage.length
        guard len > 0 else { return out }
        textStorage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: len), options: []) { v, _, _ in
            guard let a = v as? NSTextAttachment else { return }
            switch a.attachmentCell {
            case let c as ImageAttachmentCell: out.append(c.isMissing ? "image:missing" : c.loadedImage != nil ? "image:loaded" : "image:pending")
            case let c as FileAttachmentCell: out.append(c.isMissing ? "file:missing" : "file:ok")
            case is CheckboxCell: out.append("checkbox")
            default: out.append("other")
            }
        }
        return out
    }

    /// True when the glyph for storage character `index` is suppressed (hidden marker).
    public func glyphIsHiddenForTesting(at index: Int) -> Bool {
        let lm = layoutManagerNB
        guard index < textStorage.length else { return false }
        lm.ensureGlyphs(forCharacterRange: NSRange(location: 0, length: textStorage.length))
        let g = lm.glyphIndexForCharacter(at: index)
        guard g < lm.numberOfGlyphs else { return false }
        let p = lm.propertyForGlyph(at: g)
        return p == .null || (p.contains(.controlCharacter) && !UC.isLineTerminator((textStorage.string as NSString).character(at: index)))
    }

    /// Feeds a pasteboard through the paste path (files → attachments, image data, markdown text).
    @discardableResult
    public func pasteForTesting(_ pb: NSPasteboard) -> Bool { readPasteboard(pb, plainTextOnly: false) }

    /// Runs a text view command (insertNewline:, insertTab:, ...) through the editor's command handling.
    public func doCommandForTesting(_ selector: Selector) {
        if !handleCommand(selector) { textView.doCommand(by: selector) }
    }
}
