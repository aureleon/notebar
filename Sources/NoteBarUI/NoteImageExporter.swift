import AppKit
import NoteBarCore

/// Renders a note as a standalone card image (2x, transparent margin with the card shadow).
@MainActor
enum NoteImageExporter {
    static func render(note: Note, width: CGFloat, appearance: NSAppearance, env: AppEnvironment,
                       scale: CGFloat = 2) -> NSBitmapImageRep? {
        var n = note
        n.isFolded = false
        let card = NoteCardView(note: n, env: env, isExport: true)
        card.appearance = appearance
        let host = FlippedView(frame: NSRect(x: 0, y: 0, width: width + 2 * Metrics.cardShadowPad, height: 100))
        host.appearance = appearance
        host.addSubview(card)
        card.ensureEditor()
        let pad = Metrics.cardShadowPad
        // Two passes: the first gives the editor its width, the second reads the final height.
        for _ in 0..<2 {
            let h = card.cardHeight(forWidth: width)
            card.frame = NSRect(x: 0, y: 0, width: width + 2 * pad, height: h + 2 * pad)
            host.frame.size = card.frame.size
            card.invalidateHeight()
            card.needsLayout = true
            host.layoutSubtreeIfNeeded()
        }
        card.restyle()
        card.display()
        return card.renderBitmap(scale: scale)
    }
}
