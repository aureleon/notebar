import Foundation

/// Checked items sort below the open ones ("Move checked items to the bottom").
///
/// A block is one run of sibling checklist items: checklist lines at the same indent with nothing
/// between them but their own children (list lines indented deeper). A blank line, a paragraph, or a
/// list line at the same or a smaller indent that is not a checklist ends the block. The title line
/// is never part of a block. Children move with their item.
///
/// Works on raw markdown lines and on the editor's storage lines (both come from `BlockScanner`).
public enum ChecklistSort {
    public struct Block: Equatable, Sendable {
        /// Line indices of each item: the checklist line and its children.
        public var items: [Range<Int>]
        public var checked: [Bool]
        public var indent: Int

        /// Lines of the whole block.
        public var lines: Range<Int> { items.first!.lowerBound..<items.last!.upperBound }

        /// The checked items at the end of the block (the ones the "N completed" row folds), or nil.
        public var completedTail: Range<Int>? {
            var k = items.count
            while k > 0, checked[k - 1] { k -= 1 }
            guard k < items.count else { return nil }
            return k..<items.count
        }

        /// Lines of `completedTail`.
        public var completedLines: Range<Int>? {
            completedTail.map { items[$0.lowerBound].lowerBound..<items[$0.upperBound - 1].upperBound }
        }
    }

    static func isItem(_ line: MarkdownLine, indent: Int) -> Bool {
        guard case .checklist = line.kind, !line.isTitle else { return false }
        return line.indent == indent
    }

    static func isChecked(_ line: MarkdownLine) -> Bool {
        if case .checklist(let c) = line.kind { return c }
        return false
    }

    /// The block whose item line (not a child line) is `t`, or nil when `t` is not a checklist item.
    public static func block(in lines: [MarkdownLine], item t: Int) -> Block? {
        guard t >= 0, t < lines.count, isItem(lines[t], indent: lines[t].indent) else { return nil }
        let base = lines[t].indent
        func isChild(_ i: Int) -> Bool { lines[i].kind.isList && lines[i].indent > base }
        var first = t
        var i = t - 1
        while i >= 0 {
            if isItem(lines[i], indent: base) { first = i } else if !isChild(i) { break }
            i -= 1
        }
        var items: [Range<Int>] = []
        var start = first
        i = first + 1
        while i < lines.count {
            if isItem(lines[i], indent: base) {
                items.append(start..<i)
                start = i
            } else if !isChild(i) {
                break
            }
            i += 1
        }
        items.append(start..<i)
        return Block(items: items, checked: items.map { isChecked(lines[$0.lowerBound]) }, indent: base)
    }

    /// Every block in the note, at every nesting level, in line order of their first item.
    public static func blocks(in lines: [MarkdownLine]) -> [Block] {
        var out: [Block] = []
        var seen = Set<Int>()
        for i in lines.indices where !seen.contains(i) {
            guard let b = block(in: lines, item: i) else { continue }
            for r in b.items { seen.insert(r.lowerBound) }
            out.append(b)
        }
        return out.sorted { $0.lines.lowerBound < $1.lines.lowerBound }
    }

    public struct Result {
        public var text: String
        /// Old offset in the text -> offset of the same character in `text`.
        public var map: (Int) -> Int
    }

    /// Moves the checked items of the block around the item at `offset` below its open items (open
    /// first, then checked, each in their current order). nil when the block is already in order.
    public static func sorted(_ text: String, itemAt offset: Int) -> Result? {
        let ns = text as NSString
        let lines = BlockScanner.scan(ns)
        guard !lines.isEmpty else { return nil }
        let t = BlockScanner.lineIndex(in: lines, containing: offset)
        guard let b = block(in: lines, item: t), b.items.count > 1 else { return nil }
        let open = b.items.indices.filter { !b.checked[$0] }
        let done = b.items.indices.filter { b.checked[$0] }
        let order = open + done
        guard order != Array(b.items.indices) else { return nil }

        let itemRanges = b.items.map { r in
            NSRange(location: lines[r.lowerBound].range.location, length: lines[r.upperBound - 1].range.end - lines[r.lowerBound].range.location)
        }
        let region = NSRange(location: itemRanges.first!.location, length: itemRanges.last!.end - itemRanges.first!.location)
        let lastLine = lines[b.items[0].upperBound - 1]
        var sep = ns.substring(with: NSRange(location: lastLine.range.end, length: lastLine.fullRange.end - lastLine.range.end))
        if sep.isEmpty { sep = "\n" }
        let sepLen = (sep as NSString).length

        var newStart = [Int](repeating: 0, count: b.items.count)
        var body = ""
        var pos = region.location
        for (n, k) in order.enumerated() {
            if n > 0 { body += sep; pos += sepLen }
            newStart[k] = pos
            body += ns.substring(with: itemRanges[k])
            pos += itemRanges[k].length
        }
        let out = ns.replacingCharacters(in: region, with: body)
        let delta = (body as NSString).length - region.length
        let map: (Int) -> Int = { o in
            if o < region.location { return o }
            if o > region.end { return o + delta }
            // The item holding `o` (a separator belongs to the item before it).
            var k = itemRanges.count - 1
            while k > 0, o < itemRanges[k].location { k -= 1 }
            return newStart[k] + min(o - itemRanges[k].location, itemRanges[k].length)
        }
        return Result(text: out, map: map)
    }
}
