import AppKit
import NoteBarCore
import UniformTypeIdentifiers

extension MarkdownNoteEditor {
    struct AttachmentHit {
        var index: Int
        var attachment: EmbedAttachment
        var rect: NSRect
    }

    // MARK: Hit testing

    func attachmentHit(at viewPoint: NSPoint) -> AttachmentHit? {
        let len = textStorage.length
        guard len > 0 else { return nil }
        let lm = layoutManagerNB
        let origin = textView.textContainerOrigin
        let p = NSPoint(x: viewPoint.x - origin.x, y: viewPoint.y - origin.y)
        var fraction: CGFloat = 0
        let g = lm.glyphIndex(for: p, in: container, fractionOfDistanceThroughGlyph: &fraction)
        guard g < lm.numberOfGlyphs else { return nil }
        for glyph in [g, g + 1, g - 1] where glyph >= 0 && glyph < lm.numberOfGlyphs {
            let ci = lm.characterIndexForGlyph(at: glyph)
            guard ci < len, (textStorage.string as NSString).character(at: ci) == UC.attachment,
                  let a = textStorage.attribute(.attachment, at: ci, effectiveRange: nil) as? EmbedAttachment else { continue }
            let rect = lm.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: container)
            if rect.contains(p) {
                return AttachmentHit(index: ci, attachment: a, rect: rect.offsetBy(dx: origin.x, dy: origin.y))
            }
        }
        return nil
    }

    func clickableAttachment(at viewPoint: NSPoint) -> Bool {
        guard let hit = attachmentHit(at: viewPoint) else { return false }
        if case .attachment(_, true, _, _) = hit.attachment.token { return false }
        return true
    }

    // MARK: Mouse

    /// Returns true when the click was handled (checkbox toggle, file open, image select/open).
    func handleMouseDown(_ event: NSEvent) -> Bool {
        guard event.type == .leftMouseDown, !event.modifierFlags.contains(.control) else { return false }
        let p = textView.convert(event.locationInWindow, from: nil)
        guard let hit = attachmentHit(at: p) else { return false }
        switch hit.attachment.token {
        case .checkbox:
            if event.clickCount == 1 { toggleCheckbox(at: hit.index) }
            return true
        case .attachment(let id, let isImage, _, _):
            if isImage {
                if event.clickCount >= 2 {
                    openAttachment(id, inPreview: true)
                } else {
                    window?.makeFirstResponder(textView)
                    textView.setSelectedRange(NSRange(location: hit.index, length: 1))
                }
            } else if event.clickCount == 1 {
                openAttachment(id, inPreview: false)
            }
            return true
        }
    }

    /// Toggles the checkbox at storage index `index` (undoable, updates the body).
    public func toggleCheckbox(at index: Int) {
        guard index < textStorage.length,
              let a = textStorage.attribute(.attachment, at: index, effectiveRange: nil) as? EmbedAttachment,
              a.token.isCheckbox else { return }
        let range = NSRange(location: index, length: 1)
        var attrs = textStorage.attributes(at: index, effectiveRange: nil)
        attrs[.attachment] = context.makeAttachment(a.token.toggled())
        let sel = textView.selectedRange()
        textView.breakUndoCoalescing()
        guard textView.shouldChangeText(in: range, replacementString: "\u{FFFC}") else { return }
        isApplyingInternal = true
        textStorage.replaceCharacters(in: range, with: NSAttributedString(string: "\u{FFFC}", attributes: attrs))
        textView.didChangeText()
        isApplyingInternal = false
        undo.setActionName("Toggle Checkbox")
        textView.setSelectedRange(sel)
        restyle(dirty: range)
        reportBody()
        layoutDidChange()
    }

    // MARK: Open / reveal / remove

    /// Re-creates attachment cells after the store changed (restore from backup, attachment added/removed
    /// elsewhere). `all == false` only rebuilds cells whose file could not be found.
    func refreshAttachmentCells(all: Bool) {
        context.forgetURLs()
        if all { AttachmentResources.shared.reset() } else { AttachmentResources.shared.forgetMissing() }
        let len = textStorage.length
        guard len > 0 else { return }
        var changed: [NSRange] = []
        textStorage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: len), options: []) { v, r, _ in
            guard let a = v as? EmbedAttachment, case .attachment = a.token else { return }
            let missing = (a.attachmentCell as? ImageAttachmentCell)?.isMissing == true
                || (a.attachmentCell as? FileAttachmentCell)?.isMissing == true
            guard all || missing else { return }
            a.attachmentCell = context.makeCell(a.token)
            changed.append(r)
        }
        guard !changed.isEmpty else { return }
        for r in changed {
            layoutManagerNB.invalidateLayout(forCharacterRange: r, actualCharacterRange: nil)
            layoutManagerNB.invalidateDisplay(forCharacterRange: r)
        }
        layoutDidChange()
        textView.needsDisplay = true
    }

    func openAttachment(_ id: AttachmentID, inPreview: Bool) {
        guard let url = context.url(for: id) else { NSSound.beep(); return }
        if inPreview, let preview = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Preview") {
            NSWorkspace.shared.open([url], withApplicationAt: preview, configuration: NSWorkspace.OpenConfiguration())
        } else {
            NSWorkspace.shared.open(url)
        }
    }

    func revealAttachment(_ id: AttachmentID) {
        guard let url = context.url(for: id) else { NSSound.beep(); return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    /// Removes the attachment character (undoable). The store record is kept so undo can restore it.
    func removeAttachment(at index: Int) {
        guard index < textStorage.length else { return }
        var range = NSRange(location: index, length: 1)
        let s = textStorage.string as NSString
        // Also drop the line break an image used for its own line.
        if index + 1 < s.length, UC.isLineTerminator(s.character(at: index + 1)),
           index == 0 || UC.isLineTerminator(s.character(at: index - 1)) {
            range.length += 1
        }
        textView.breakUndoCoalescing()
        guard textView.shouldChangeText(in: range, replacementString: "") else { return }
        textStorage.replaceCharacters(in: range, with: "")
        textView.didChangeText()
        undo.setActionName("Remove Attachment")
    }

    // MARK: Context menu

    func contextMenu(for event: NSEvent, base: NSMenu?) -> NSMenu? {
        let p = textView.convert(event.locationInWindow, from: nil)
        if let hit = attachmentHit(at: p), case .attachment(let id, let isImage, _, _) = hit.attachment.token {
            let menu = NSMenu(title: "Attachment")
            func add(_ title: String, _ block: @escaping () -> Void) {
                let item = ClosureMenuItem(title: title, block: block)
                menu.addItem(item)
            }
            add("Open") { [weak self] in self?.openAttachment(id, inPreview: false) }
            if isImage { add("Open in Preview") { [weak self] in self?.openAttachment(id, inPreview: true) } }
            add("Reveal in Finder") { [weak self] in self?.revealAttachment(id) }
            if isImage {
                add("Copy Image") { [weak self] in
                    guard let url = self?.context.url(for: id), let img = NSImage(contentsOf: url) else { return }
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.writeObjects([img])
                }
            } else {
                add("Copy Path") { [weak self] in
                    guard let url = self?.context.url(for: id) else { return }
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(url.path, forType: .string)
                }
            }
            menu.addItem(.separator())
            add("Remove") { [weak self] in self?.removeAttachment(at: hit.index) }
            return menu
        }
        guard let base, mode == .standard else { return base }
        let format = NSMenuItem(title: "Format", action: nil, keyEquivalent: "")
        format.submenu = formatMenu()
        base.insertItem(format, at: 0)
        base.insertItem(.separator(), at: 1)
        return base
    }

    // MARK: Paste

    /// Handles paste and text drops. Files → attachments; image data → image attachment; text → markdown.
    @discardableResult
    func readPasteboard(_ pb: NSPasteboard, plainTextOnly: Bool) -> Bool {
        let range = textView.rangeForUserTextChange
        guard range.location != NSNotFound else { return false }
        if !plainTextOnly {
            if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
                insertFiles(urls, at: range)
                return true
            }
            let str = pb.string(forType: .string)
            if str == nil || Self.isSingleURL(str!), let (data, ext) = Self.imageData(from: pb) {
                insertImageData(data, ext: ext, at: range)
                return true
            }
        }
        guard let str = pb.string(forType: .string) else { return false }
        insertText(str, at: range)
        return true
    }

    static func isSingleURL(_ s: String) -> Bool {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return !t.contains(where: { $0.isWhitespace }) && (t.hasPrefix("http://") || t.hasPrefix("https://"))
    }

    static func imageData(from pb: NSPasteboard) -> (Data, String)? {
        if let d = pb.data(forType: .png) { return (d, "png") }
        if let d = pb.data(forType: NSPasteboard.PasteboardType("public.jpeg")) { return (d, "jpg") }
        if let d = pb.data(forType: .tiff), let rep = NSBitmapImageRep(data: d), let png = rep.representation(using: .png, properties: [:]) {
            return (png, "png")
        }
        if let img = NSImage(pasteboard: pb), let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
           let png = rep.representation(using: .png, properties: [:]) {
            return (png, "png")
        }
        return nil
    }

    /// Inserts pasted text as markdown (checklists / attachment tokens become live).
    /// Attachment tokens from other notes are cloned into this note first (see `AttachmentRehoming`).
    func insertText(_ pasted: String, at range: NSRange) {
        let str = AttachmentRehoming.rehome(pasted, into: noteID, store: env.store)
        let s = textStorage.string as NSString
        let atLineStart = range.location == 0 || UC.isLineTerminator(s.character(at: range.location - 1))
        var opts = codecOptions
        let lines = currentLines()
        if lines.indices.contains(BlockScanner.lineIndex(in: lines, containing: range.location)),
           lines[BlockScanner.lineIndex(in: lines, containing: range.location)].isCode { opts.checkboxes = false }
        let attr: NSMutableAttributedString
        if atLineStart {
            attr = MarkdownCodec.attributedString(from: str, options: opts, attributes: baseAttributes, makeAttachment: context.makeAttachment)
        } else {
            // Parse as if preceded by text so a leading "- [ ] " is not treated as a line start.
            attr = MarkdownCodec.attributedString(from: "x" + str, options: opts, attributes: baseAttributes, makeAttachment: context.makeAttachment)
            attr.deleteCharacters(in: NSRange(location: 0, length: 1))
        }
        guard textView.shouldChangeText(in: range, replacementString: attr.string) else { return }
        textStorage.replaceCharacters(in: range, with: attr)
        textView.setSelectedRange(NSRange(location: range.location + attr.length, length: 0))
        textView.didChangeText()
        textView.scrollRangeToVisible(textView.selectedRange())
    }

    /// Adds the files as attachments and inserts their tokens. Returns (file, attachment) per added file.
    @discardableResult
    func insertFiles(_ urls: [URL], at range: NSRange?) -> [(URL, Attachment)] {
        var added: [(URL, Attachment)] = []
        var failed = false
        for u in urls {
            do { added.append((u, try env.store.addAttachment(to: noteID, fileURL: u))) } catch { failed = true }
        }
        if failed { NSSound.beep() }
        insertAttachmentTokens(added.map(\.1), at: range)
        return added
    }

    func insertImageData(_ data: Data, ext: String, at range: NSRange?) {
        do {
            let a = try env.store.addImageAttachment(to: noteID, data: data, fileExtension: ext, displayName: "Pasted Image.\(ext)")
            insertAttachmentTokens([a], at: range)
        } catch {
            NSSound.beep()
        }
    }

    /// Inserts tokens at a storage range (or the caret / end).
    func insertAttachmentTokens(_ attachments: [Attachment], at range: NSRange?) {
        guard !attachments.isEmpty else { return }
        guard let range else { insertAttachments(attachments); return }
        let md = markdown
        let mdRange = MarkdownCodec.markdownRange(forStorageRange: range, embeds: MarkdownCodec.embeds(in: textStorage))
        let items = attachments.map { (AttachmentLink.markdown(for: $0), $0.kind == .image) }
        let r = AttachmentInsertion.insert(items, into: md, selection: mdRange)
        replaceMarkdown(r.text, selection: r.selection, undoable: true, actionName: "Insert Attachment")
        textView.scrollRangeToVisible(textView.selectedRange())
    }

    // MARK: Drop

    func handleDrop(_ info: NSDraggingInfo, at index: Int) -> Bool {
        let pb = info.draggingPasteboard
        let range = NSRange(location: min(index, textStorage.length), length: 0)
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            window?.makeFirstResponder(textView)
            insertFiles(urls, at: range)
            return true
        }
        if let (data, ext) = Self.imageData(from: pb) {
            window?.makeFirstResponder(textView)
            insertImageData(data, ext: ext, at: range)
            return true
        }
        if let promises = pb.readObjects(forClasses: [NSFilePromiseReceiver.self], options: nil) as? [NSFilePromiseReceiver], !promises.isEmpty {
            // A persistent folder: non-image files become bookmarks to the received copy.
            guard let dir = DroppedFileStorage.makeDropFolder() else { NSSound.beep(); return false }
            let mdOffset = MarkdownCodec.markdownOffset(forStorageOffset: range.location, embeds: MarkdownCodec.embeds(in: textStorage))
            DroppedFileStorage.receive(promises, into: dir) { [weak self] received in
                guard let self else {
                    DroppedFileStorage.finishImport(folder: dir, received: received, added: [])
                    return
                }
                if received.isEmpty { NSSound.beep() }
                let embeds = MarkdownCodec.embeds(in: self.textStorage)
                let loc = MarkdownCodec.storageOffset(forMarkdownOffset: min(mdOffset, (self.markdown as NSString).length), embeds: embeds)
                let added = self.insertFiles(received, at: NSRange(location: min(loc, self.textStorage.length), length: 0))
                DroppedFileStorage.finishImport(folder: dir, received: received, added: added)
                Self.pruneDroppedFilesOnce(store: self.env.store)
            }
            return true
        }
        return false
    }

    private static var didPruneDroppedFiles = false

    /// Removes unreferenced drop folders once per process, after the first promise drop.
    static func pruneDroppedFilesOnce(store: NoteStore) {
        guard !didPruneDroppedFiles else { return }
        didPruneDroppedFiles = true
        DroppedFileStorage.pruneUnreferenced(store: store)
    }
}

/// Menu item that runs a closure.
final class ClosureMenuItem: NSMenuItem {
    private let block: () -> Void

    init(title: String, block: @escaping () -> Void) {
        self.block = block
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
    }

    required init(coder: NSCoder) { fatalError("not supported") }

    @objc private func run() { block() }
}
