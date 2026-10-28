import AppKit

/// Cursor rects that must not overlap: while the window is key, AppKit switches the cursor as it
/// re-evaluates overlapping rects, which shows as a flicker between two cursors.
enum CursorRects {
    /// `rect` minus `holes`, as rectangles that do not overlap the holes.
    static func subtract(_ holes: [NSRect], from rect: NSRect) -> [NSRect] {
        var pieces = [rect]
        for h in holes {
            pieces = pieces.flatMap { r -> [NSRect] in
                let i = r.intersection(h)
                guard !i.isEmpty else { return [r] }
                return [NSRect(x: r.minX, y: r.minY, width: r.width, height: i.minY - r.minY),          // above
                        NSRect(x: r.minX, y: i.maxY, width: r.width, height: r.maxY - i.maxY),          // below
                        NSRect(x: r.minX, y: i.minY, width: i.minX - r.minX, height: i.height),         // left
                        NSRect(x: i.maxX, y: i.minY, width: r.maxX - i.maxX, height: i.height)]         // right
                    .filter { $0.width > 0 && $0.height > 0 }
            }
        }
        return pieces
    }
}
