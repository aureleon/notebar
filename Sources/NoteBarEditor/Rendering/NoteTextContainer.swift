import AppKit

/// Text container of note editors. Lines of a list item with children end `nbChevronRoom` short of
/// the container width, so the fold chevron after the item's text always has room. The room is not
/// part of any glyph: the caret, selection and clicks at the end of the line work as usual.
final class NoteTextContainer: NSTextContainer {
    override var isSimpleRectangularTextContainer: Bool { false }

    override func lineFragmentRect(forProposedRect proposedRect: NSRect, at characterIndex: Int,
                                   writingDirection baseWritingDirection: NSWritingDirection,
                                   remaining remainingRect: UnsafeMutablePointer<NSRect>?) -> NSRect {
        var r = super.lineFragmentRect(forProposedRect: proposedRect, at: characterIndex,
                                       writingDirection: baseWritingDirection, remaining: remainingRect)
        if let storage = layoutManager?.textStorage, characterIndex < storage.length,
           let room = storage.attribute(.nbChevronRoom, at: characterIndex, effectiveRange: nil) as? CGFloat {
            r.size.width = max(0, r.size.width - room)
        }
        return r
    }
}
