import AppKit
import NoteBarCore

/// The text view inside a `MarkdownNoteEditor`. Forwards focus, keys, mouse, pasteboard and drag events.
final class MarkdownTextView: NSTextView {
    weak var editor: MarkdownNoteEditor?

    override var acceptsFirstResponder: Bool { true }

    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if ok { editor?.focusDidChange(true) }
        return ok
    }

    override func resignFirstResponder() -> Bool {
        let ok = super.resignFirstResponder()
        if ok { editor?.focusDidChange(false) }
        return ok
    }

    // MARK: Keys

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags.contains(.command), event.keyCode == 36 || event.keyCode == 76 {
            editor?.onEvent?(.commit)
            return
        }
        if let editor, editor.vimHandleKeyDown(event) { return }
        super.keyDown(with: event)
    }

    // MARK: Vim block caret

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let editor, let r = editor.blockCaretRect, r.intersects(dirtyRect) else { return }
        editor.style.text.withAlphaComponent(0.4).setFill()
        NSBezierPath(roundedRect: r, xRadius: 1.5, yRadius: 1.5).fill()
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if window?.firstResponder === self, let editor {
            if let level = editor.headingShortcutLevel(event) { editor.setHeading(level: level); return true }
            if let action = editor.shortcutAction(for: event) { editor.perform(action); return true }
        }
        return super.performKeyEquivalent(with: event)
    }

    // MARK: Mouse

    override func mouseDown(with event: NSEvent) {
        if editor?.handleMouseDown(event) == true { return }
        editor?.isTrackingMouse = true
        super.mouseDown(with: event)
        editor?.isTrackingMouse = false
        editor?.mouseTrackingEnded()
    }

    private var hoverArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        // The panel does not activate the app: track moves even when it is not active.
        let t = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                               owner: self, userInfo: nil)
        addTrackingArea(t)
        hoverArea = t
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        let p = convert(event.locationInWindow, from: nil)
        if !visibleRect.contains(p) { editor?.hideCodeCopyButton() }
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        let p = convert(event.locationInWindow, from: nil)
        editor?.updateCodeCopyButton(at: p)
        // super.mouseMoved sets the I-beam; the copy button on the text gets the arrow.
        if let b = editor?.codeCopyButton, !b.isHidden, b.frame.contains(p) { NSCursor.arrow.set(); return }
        if editor?.clickableAttachment(at: p) == true { NSCursor.pointingHand.set() }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let base = super.menu(for: event)
        return editor?.contextMenu(for: event, base: base) ?? base
    }

    // MARK: Pasteboard

    static let filePromiseTypes: [NSPasteboard.PasteboardType] = NSFilePromiseReceiver.readableDraggedTypes.map { NSPasteboard.PasteboardType($0) }

    override var readablePasteboardTypes: [NSPasteboard.PasteboardType] {
        [.fileURL, .png, .tiff, NSPasteboard.PasteboardType("public.jpeg"), .string]
    }

    override var acceptableDragTypes: [NSPasteboard.PasteboardType] {
        [.fileURL, .png, .tiff, NSPasteboard.PasteboardType("public.jpeg"), .string] + Self.filePromiseTypes
    }

    override var writablePasteboardTypes: [NSPasteboard.PasteboardType] { [.string] }

    override func writeSelection(to pboard: NSPasteboard, type: NSPasteboard.PasteboardType) -> Bool {
        guard type == .string, let editor else { return super.writeSelection(to: pboard, type: type) }
        return pboard.setString(editor.markdown(for: selectedRange()), forType: .string)
    }

    override func writeSelection(to pboard: NSPasteboard, types: [NSPasteboard.PasteboardType]) -> Bool {
        guard editor != nil else { return super.writeSelection(to: pboard, types: types) }
        pboard.declareTypes([.string], owner: nil)
        return writeSelection(to: pboard, type: .string)
    }

    override func paste(_ sender: Any?) {
        if editor?.readPasteboard(.general, plainTextOnly: false) != true { super.paste(sender) }
    }

    override func pasteAsPlainText(_ sender: Any?) {
        if editor?.readPasteboard(.general, plainTextOnly: true) != true { super.pasteAsPlainText(sender) }
    }

    override func pasteAsRichText(_ sender: Any?) { paste(sender) }

    override func readSelection(from pboard: NSPasteboard, type: NSPasteboard.PasteboardType) -> Bool {
        editor?.readPasteboard(pboard, plainTextOnly: false) ?? super.readSelection(from: pboard, type: type)
    }

    override func readSelection(from pboard: NSPasteboard) -> Bool {
        editor?.readPasteboard(pboard, plainTextOnly: false) ?? super.readSelection(from: pboard)
    }

    // MARK: Drag and drop

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let pb = sender.draggingPasteboard
        let hasFiles = pb.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
        let hasPromises = !(pb.readObjects(forClasses: [NSFilePromiseReceiver.self], options: nil)?.isEmpty ?? true)
        let hasImage = pb.availableType(from: [.png, .tiff, NSPasteboard.PasteboardType("public.jpeg")]) != nil
        if (hasFiles || hasPromises || hasImage), sender.draggingSource as? NSTextView !== self, let editor {
            let p = convert(sender.draggingLocation, from: nil)
            let index = characterIndexForInsertion(at: p)
            return editor.handleDrop(sender, at: index)
        }
        return super.performDragOperation(sender)
    }

    override func dragOperation(for dragInfo: NSDraggingInfo, type: NSPasteboard.PasteboardType) -> NSDragOperation {
        if dragInfo.draggingSource as? NSTextView === self { return super.dragOperation(for: dragInfo, type: type) }
        return .copy
    }
}
