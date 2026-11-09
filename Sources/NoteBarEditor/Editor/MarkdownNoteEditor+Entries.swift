import AppKit
import NoteBarCore

/// Scratch entries (`ScratchEntries`) in the editor.
///
/// A marker is one attachment character on a line of its own (`EntryCell` draws the hairline and the
/// time). The caret never rests on that line, so text is never typed next to a marker. An edit that
/// leaves a marker with text on its line (Backspace at the start of an entry) removes the marker, which
/// joins the entry with the one above.
extension MarkdownNoteEditor {
    var usesEntries: Bool { note.isScratch }

    /// How strongly the text of an entry shows, by its distance from the newest entry.
    static let entryFades: [CGFloat] = [1, 0.82, 0.7, 0.6]

    func entryToken(at i: Int) -> ScratchEntries.Marker? {
        guard usesEntries, i < textStorage.length,
              let a = textStorage.attribute(.attachment, at: i, effectiveRange: nil) as? EmbedAttachment,
              case .entry(let m) = a.token else { return nil }
        return m
    }

    func isEntryMarker(at i: Int) -> Bool { entryToken(at: i) != nil }

    // MARK: Styling

    /// The entry of each line (as `ScratchEntries.entries` counts them), for the styler: older entries
    /// fade (not the one with the caret, and not in a read-only note) and done entries are struck
    /// through. Also tells each marker whether it shows its time.
    func updateEntryStyle(_ lines: [MarkdownLine]) {
        guard usesEntries else {
            entryOfLine = []
            styler.entryFade = []
            styler.entryDone = []
            return
        }
        let s = textStorage.string as NSString
        var entry = 0
        var started = false
        var of = [Int](repeating: 0, count: lines.count)
        var done: [Bool] = [false]
        var markers: [(index: Int, marker: ScratchEntries.Marker)] = []
        for (i, line) in lines.enumerated() {
            if line.kind == .entry, let m = entryToken(at: line.range.location) {
                if started { entry += 1; done.append(false) }
                started = true
                done[entry] = m.isDone
                markers.append((line.range.location, m))
            } else if !started, line.range.length > 0,
                      !s.substring(with: line.range).trimmingCharacters(in: .whitespaces).isEmpty {
                started = true
            }
            of[i] = entry
        }
        entryOfLine = of
        activeEntry = isEditingFocused ? entryIndex(at: textView.selectedRange().location, lines: lines) : nil
        let fades = !isReadOnly
        styler.entryFade = of.map { e in
            guard fades, e != activeEntry else { return 1 }
            return Self.entryFades[min(entry - e, Self.entryFades.count - 1)]
        }
        styler.entryDone = of.map { done[$0] }

        let shows = ScratchEntries.showsTime(markers.map(\.marker))
        for (k, m) in markers.enumerated() {
            guard let a = textStorage.attribute(.attachment, at: m.index, effectiveRange: nil) as? NSTextAttachment,
                  let cell = a.attachmentCell as? EntryCell, cell.showsTime != shows[k] else { continue }
            cell.showsTime = shows[k]
            layoutManagerNB.invalidateDisplay(forCharacterRange: NSRange(location: m.index, length: 1))
        }
    }

    func entryIndex(at location: Int, lines: [MarkdownLine]) -> Int? {
        guard usesEntries, !lines.isEmpty, entryOfLine.count == lines.count else { return nil }
        return entryOfLine[BlockScanner.lineIndex(in: lines, containing: location)]
    }

    /// The caret moved to another entry: that one shows in full, the one it left fades.
    func entrySelectionChanged() {
        // During an edit `textDidChange` restyles (a restyle here would drop its dirty range).
        guard usesEntries, isEditingFocused, !isReadOnly, !textView.hasMarkedText(), !hasPendingEdit else { return }
        guard entryIndex(at: textView.selectedRange().location, lines: currentLines()) != activeEntry else { return }
        restyle(dirty: nil)
    }

    func entryFocusChanged() {
        guard usesEntries else { return }
        if isEditingFocused { beginEntryIfBlank() } else { pruneEmptyEntry() }
        restyle(dirty: nil)
        layoutDidChange()
    }

    // MARK: Caret

    /// The caret skips marker lines: forward to the start of the entry's text, back to the end of the
    /// text above. nil: `new` is not on a marker line.
    func entryCaret(from old: NSRange, to new: NSRange) -> NSRange? {
        guard usesEntries, new.length == 0 else { return nil }
        let lines = currentLines()
        guard !lines.isEmpty else { return nil }
        let li = BlockScanner.lineIndex(in: lines, containing: new.location)
        guard lines[li].kind == .entry else { return nil }
        var up = li, down = li
        while up >= 0, lines[up].kind == .entry { up -= 1 }
        while down < lines.count, lines[down].kind == .entry { down += 1 }
        let above = up >= 0 ? NSRange(location: lines[up].range.end, length: 0) : nil
        let below = down < lines.count ? NSRange(location: lines[down].range.location, length: 0) : nil
        let back = old.length == 0 && new.location < old.location
        return (back ? above ?? below : below ?? above) ?? new
    }

    // MARK: Keeping markers whole

    /// Removes the markers an edit left in a wrong place: with text on their line (the entry joins the
    /// one above), or right above another marker (an entry whose lines were all deleted).
    func normalizeEntries() {
        guard usesEntries, !undo.isUndoing, !undo.isRedoing, textStorage.length > 0 else { return }
        let s = textStorage.string as NSString
        let len = s.length
        var ranges: [NSRange] = []
        textStorage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: len), options: []) { v, r, _ in
            guard let a = v as? EmbedAttachment, a.token.isEntry else { return }
            for k in r.location..<r.end where s.character(at: k) == UC.attachment {
                let startsLine = k == 0 || UC.isLineTerminator(s.character(at: k - 1))
                let endsLine = k + 1 < len && UC.isLineTerminator(s.character(at: k + 1))
                guard startsLine, endsLine else { ranges.append(NSRange(location: k, length: 1)); continue }
                let line = s.paragraphRange(for: NSRange(location: k, length: 0))
                if line.end < len, isEntryMarker(at: line.end), line.end + 1 < len,
                   UC.isLineTerminator(s.character(at: line.end + 1)) {
                    ranges.append(line)
                }
            }
        }
        guard !ranges.isEmpty else { return }
        textView.breakUndoCoalescing()
        guard textView.shouldChangeText(inRanges: ranges.map { NSValue(range: $0) },
                                        replacementStrings: ranges.map { _ in "" }) else { return }
        var caret = textView.selectedRange().location
        for r in ranges.reversed() {
            if r.end <= caret { caret -= r.length } else if r.location < caret { caret = r.location }
        }
        isApplyingInternal = true
        textStorage.beginEditing()
        for r in ranges.reversed() { textStorage.replaceCharacters(in: r, with: "") }
        textStorage.endEditing()
        textView.didChangeText()
        isApplyingInternal = false
        textView.breakUndoCoalescing()
        textView.setSelectedRange(NSRange(location: min(caret, textStorage.length), length: 0))
    }

    // MARK: New entry

    public func beginEntry(at date: Date) {
        guard usesEntries, !isReadOnly, !textView.hasMarkedText() else { return }
        let base = provisionalBase ?? lastBody
        let new = ScratchEntries.beginningEntry(in: markdown, minutes: ScratchEntries.minutes(of: date))
        let end = NSRange(location: (new as NSString).length, length: 0)
        replaceMarkdown(new, selection: end, undoable: false)
        provisionalBase = base
        textView.scrollRangeToVisible(textView.selectedRange())
    }

    /// An empty note that has the focus (a click into it, Clear Scratch): what is typed next is the
    /// first entry.
    func beginEntryIfBlank() {
        guard usesEntries, isEditingFocused, !isReadOnly else { return }
        let md = markdown
        guard ScratchEntries.isBlank(md), ScratchEntries.markers(in: md).isEmpty else { return }
        beginEntry(at: env.scratch.now())
    }

    /// Drops the empty entries at the end (opened, nothing typed). The host hears of it only when its
    /// body had them.
    func pruneEmptyEntry() {
        guard usesEntries, !isReadOnly, !textView.hasMarkedText() else { return }
        let md = markdown
        var pruned = ScratchEntries.pruningEmptyTail(md)
        guard pruned != md else { return }
        // The line break `beginEntry` put after the last text goes with it.
        if let base = provisionalBase, pruned == base + "\n" { pruned = base }
        let base = provisionalBase
        replaceMarkdown(pruned, selection: nil, undoable: false)
        if base == nil || base != pruned { reportReplacedBody() } else { provisionalBase = nil }
    }

    // MARK: Menu

    /// Items for the entry under `p` (text view coordinates): the host's (Save Entry as Note), Copy
    /// Entry, and in an editable note Mark Done and Delete.
    func entryMenu(at p: NSPoint) -> [NSMenuItem] {
        guard usesEntries, textStorage.length > 0 else { return [] }
        let md = markdown
        let all = ScratchEntries.entries(in: md)
        let index = textView.characterIndexForInsertion(at: p)
        guard let e = entryIndex(at: index, lines: currentLines()), all.indices.contains(e),
              let text = ScratchEntries.text(ofEntry: e, in: md), !text.isEmpty else { return [] }
        var items = entryMenuItems?(text) ?? []
        items.append(ClosureMenuItem(title: "Copy Entry") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        })
        guard !isReadOnly else { return items }
        if let m = all[e].marker {
            items.append(ClosureMenuItem(title: m.isDone ? "Mark Entry Not Done" : "Mark Entry Done") { [weak self] in
                self?.setEntryDone(!m.isDone, entry: e)
            })
        }
        items.append(ClosureMenuItem(title: "Delete Entry") { [weak self] in self?.deleteEntry(e) })
        return items
    }

    public func setEntryDone(_ done: Bool, entry: Int) {
        guard usesEntries, !isReadOnly else { return }
        replaceMarkdown(ScratchEntries.settingDone(done, entry: entry, in: markdown), selection: nil, undoable: true,
                        actionName: done ? "Mark Entry Done" : "Mark Entry Not Done")
    }

    public func deleteEntry(_ entry: Int) {
        guard usesEntries, !isReadOnly else { return }
        replaceMarkdown(ScratchEntries.removingEntry(entry, from: markdown), selection: nil, undoable: true,
                        actionName: "Delete Entry")
    }

    // MARK: Testing

    /// For checks: per marker in order, whether it shows its time.
    public var entryTimesShownForTesting: [Bool] {
        var out: [Bool] = []
        let len = textStorage.length
        guard len > 0 else { return out }
        textStorage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: len), options: []) { v, _, _ in
            if let c = (v as? NSTextAttachment)?.attachmentCell as? EntryCell { out.append(c.showsTime) }
        }
        return out
    }

    /// For checks: the alpha of the text color at each line start (1 for an empty line).
    public var lineAlphasForTesting: [CGFloat] {
        currentLines().map { l in
            guard l.range.length > 0, l.kind != .entry,
                  let c = textStorage.attribute(.foregroundColor, at: l.range.location, effectiveRange: nil) as? NSColor else { return 1 }
            return (c.alphaComponent * 100).rounded() / 100
        }
    }

    /// For checks: the menu titles for the entry that holds storage index `index`.
    public func entryMenuTitlesForTesting(atStorage index: Int) -> [String] {
        let g = layoutManagerNB.glyphIndexForCharacter(at: min(index, max(0, textStorage.length - 1)))
        let r = layoutManagerNB.boundingRect(forGlyphRange: NSRange(location: g, length: 1), in: container)
        return entryMenu(at: NSPoint(x: r.minX + 1, y: r.midY)).map(\.title)
    }
}
