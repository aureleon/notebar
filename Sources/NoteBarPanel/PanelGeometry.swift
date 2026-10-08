import AppKit
import NoteBarCore

/// Sizes used by the panel and the Hot Side.
enum PanelMetrics {
    /// Gap between the panel and the screen edge / menu bar / bottom of the visible frame.
    static let edgeInset: CGFloat = 8
    static let minWidth: CGFloat = PanelWidth.minWidth
    static let maxWidth: CGFloat = PanelWidth.maxWidth
    static let animationDuration: TimeInterval = 0.18


    /// After a programmatic show (URL, AppleScript, hotkey, status item) focus changes are ignored for
    /// this long. Only a real click outside the panel hides it during that time.
    static let showGrace: TimeInterval = 0.5

    /// Hot Side strip thickness (1 pt = 2 px on Retina; the cursor stops on the last pixel column).
    static let hotSideThickness: CGFloat = 1
    /// Vertical areas of the edge that never trigger (hot corners, Dock corners).
    static let hotSideBottomExclusion: CGFloat = 16
    static let hotSideMinTopExclusion: CGFloat = 28
    static let hotSideMinSegment: CGFloat = 60
}

/// The panel width rule. Shared by the panel, the snapshot mode and (through `PanelMetrics`) the Hot Side.
public enum PanelSizing {
    /// The width the user set, or nil while the width follows the screen (`panelWidthIsAutomatic`).
    @MainActor public static func requestedWidth(_ settings: AppSettings) -> Double? {
        settings.panelWidthIsAutomatic ? nil : settings.panelWidth
    }

    /// nil = automatic (about 27 % of `visibleWidth`, 380...600 pt). Otherwise the clamped user width.
    public static func width(requested: Double?, visibleWidth: CGFloat) -> CGFloat {
        guard let requested else { return PanelWidth.automatic(visibleWidth: visibleWidth) }
        return clamp(requested)
    }

    /// Clamps a user-set width to 280...720 pt.
    public static func clamp(_ width: Double) -> CGFloat {
        guard width.isFinite else { return PanelWidth.fallback }
        return min(max(CGFloat(width), PanelMetrics.minWidth), PanelMetrics.maxWidth)
    }
}

/// Pure frame math for one screen. All rects are in global (Cocoa, bottom-left origin) coordinates.
struct PanelGeometry: Equatable {
    var screenFrame: CGRect
    var visibleFrame: CGRect
    var side: PanelSide
    /// User-set width (unclamped), or nil for automatic width.
    var requestedWidth: Double?
    /// True if another display touches this screen on the panel side. The panel then must not slide
    /// across the edge (it would show up on the neighbor display) and only fades.
    var hasNeighborOnSide: Bool

    /// Width for this screen. Also fits on small screens (the panel keeps the edge inset on both sides).
    var width: CGFloat {
        let w = PanelSizing.width(requested: requestedWidth, visibleWidth: visibleFrame.width)
        let fit = visibleFrame.width - 2 * PanelMetrics.edgeInset
        return w > fit ? max(fit, 160) : w
    }

    var shownFrame: CGRect {
        let inset = PanelMetrics.edgeInset
        let w = width
        let h = max(visibleFrame.height - 2 * inset, 100)
        let x = side == .right ? visibleFrame.maxX - inset - w : visibleFrame.minX + inset
        return CGRect(x: round(x), y: round(visibleFrame.minY + inset), width: round(w), height: round(h))
    }

    /// Frame the panel slides from / to. With a neighbor display only a short slide is used.
    var hiddenFrame: CGRect {
        let shown = shownFrame
        let distance: CGFloat
        if hasNeighborOnSide {
            distance = PanelMetrics.edgeInset
        } else {
            let edgeGap = side == .right ? screenFrame.maxX - shown.maxX : shown.minX - screenFrame.minX
            distance = shown.width + max(edgeGap, 0) + 2
        }
        return shown.offsetBy(dx: side == .right ? distance : -distance, dy: 0)
    }

    /// Hot Side strips for a screen: the side edge minus the menu bar area, the bottom corner, and any
    /// part of the edge that touches another display (the cursor does not stop there).
    static func hotSideSegments(screenFrame: CGRect, visibleFrame: CGRect, side: PanelSide,
                                otherScreenFrames: [CGRect]) -> [CGRect] {
        let topExclusion = max(screenFrame.maxY - visibleFrame.maxY, PanelMetrics.hotSideMinTopExclusion) + 4
        var ranges: [ClosedRange<CGFloat>] = []
        let lo = screenFrame.minY + PanelMetrics.hotSideBottomExclusion
        let hi = screenFrame.maxY - topExclusion
        guard hi > lo else { return [] }
        ranges = [lo...hi]

        let edgeX = side == .right ? screenFrame.maxX : screenFrame.minX
        for other in otherScreenFrames {
            let touches = side == .right ? abs(other.minX - edgeX) < 1 : abs(other.maxX - edgeX) < 1
            guard touches else { continue }
            let oLo = other.minY, oHi = other.maxY
            ranges = ranges.flatMap { r -> [ClosedRange<CGFloat>] in
                if oHi <= r.lowerBound || oLo >= r.upperBound { return [r] }
                var out: [ClosedRange<CGFloat>] = []
                if oLo > r.lowerBound { out.append(r.lowerBound...oLo) }
                if oHi < r.upperBound { out.append(oHi...r.upperBound) }
                return out
            }
        }
        let t = PanelMetrics.hotSideThickness
        let x = side == .right ? screenFrame.maxX - t : screenFrame.minX
        return ranges
            .filter { $0.upperBound - $0.lowerBound >= PanelMetrics.hotSideMinSegment }
            .map { CGRect(x: x, y: $0.lowerBound, width: t, height: $0.upperBound - $0.lowerBound) }
    }

    /// True if any other screen touches `screenFrame` on `side` with a vertical overlap.
    static func hasNeighbor(screenFrame: CGRect, side: PanelSide, otherScreenFrames: [CGRect]) -> Bool {
        let edgeX = side == .right ? screenFrame.maxX : screenFrame.minX
        return otherScreenFrames.contains { other in
            let touches = side == .right ? abs(other.minX - edgeX) < 1 : abs(other.maxX - edgeX) < 1
            return touches && other.maxY > screenFrame.minY && other.minY < screenFrame.maxY
        }
    }
}

// MARK: - Screens

extension NSScreen {
    var nbDisplayID: CGDirectDisplayID? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }

    /// The screen under the cursor, falling back to the main / first screen.
    static var nbScreenWithMouse: NSScreen? {
        let p = NSEvent.mouseLocation
        let screens = NSScreen.screens
        // The cursor can sit exactly on maxX / maxY, which `contains` excludes; check exact first.
        return screens.first { $0.frame.contains(p) }
            ?? screens.first { $0.frame.insetBy(dx: -1, dy: -1).contains(p) }
            ?? NSScreen.main ?? screens.first
    }

    static func nbScreen(withID id: CGDirectDisplayID?) -> NSScreen? {
        guard let id else { return nil }
        return NSScreen.screens.first { $0.nbDisplayID == id }
    }

    func nbGeometry(side: PanelSide, width: Double?) -> PanelGeometry {
        let others = NSScreen.screens.filter { $0 != self }.map(\.frame)
        return PanelGeometry(screenFrame: frame, visibleFrame: visibleFrame, side: side,
                             requestedWidth: width,
                             hasNeighborOnSide: PanelGeometry.hasNeighbor(screenFrame: frame, side: side, otherScreenFrames: others))
    }
}

/// Collection behavior shared by NoteBar edge windows: on all Spaces, over
/// full-screen apps, not moved by Mission Control / Exposé, not in the window cycle.
let edgeWindowCollectionBehavior: NSWindow.CollectionBehavior = [
    .canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle,
]
