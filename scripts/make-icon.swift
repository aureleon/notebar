// Draws the NoteBar app icon and writes an .iconset folder.
// Usage: swift scripts/make-icon.swift <out.iconset>   (scripts/make-icon.sh wraps this + iconutil)
import AppKit

let out = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.iconset")
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}

func withShadow(_ alpha: CGFloat, _ blur: CGFloat, _ dy: CGFloat, _ draw: () -> Void) {
    NSGraphicsContext.saveGraphicsState()
    let s = NSShadow()
    s.shadowColor = NSColor.black.withAlphaComponent(alpha)
    s.shadowBlurRadius = blur
    s.shadowOffset = NSSize(width: 0, height: dy)
    s.set()
    draw()
    NSGraphicsContext.restoreGraphicsState()
}

func pill(_ r: NSRect, _ c: NSColor) {
    c.setFill()
    NSBezierPath(roundedRect: r, xRadius: r.height / 2, yRadius: r.height / 2).fill()
}

func roundedStroke(_ r: NSRect, radius: CGFloat, _ c: NSColor) {
    c.setStroke()
    let p = NSBezierPath(roundedRect: r.insetBy(dx: 1.5, dy: 1.5), xRadius: radius - 1.5, yRadius: radius - 1.5)
    p.lineWidth = 3
    p.stroke()
}

/// Draws the icon into a 1024x1024 coordinate space: a dark desktop with the NoteBar glass panel on
/// the right edge (dark header pill with title + settings / search / new, a yellow and a white note).
func drawIcon() {
    // macOS icon grid: 824pt body centered in 1024, corner radius ~185.
    let body = NSRect(x: 100, y: 100, width: 824, height: 824)
    let bodyPath = NSBezierPath(roundedRect: body, xRadius: 185, yRadius: 185)

    withShadow(0.35, 28, -12) { rgb(0x1F2A44).setFill(); bodyPath.fill() }

    NSGraphicsContext.saveGraphicsState()
    bodyPath.addClip()
    NSGradient(colors: [rgb(0x101A33), rgb(0x23345E)], atLocations: [0, 1], colorSpace: .sRGB)!.draw(in: body, angle: -90)

    // The glass panel.
    let panel = NSRect(x: body.maxX - 470, y: body.minY + 70, width: 410, height: body.height - 140)
    withShadow(0.4, 34, -8) {
        rgb(0xFFFFFF, 0.16).setFill()
        NSBezierPath(roundedRect: panel, xRadius: 70, yRadius: 70).fill()
    }
    roundedStroke(panel, radius: 70, rgb(0xFFFFFF, 0.38))

    // Header pill: title, then settings / search / new.
    let header = NSRect(x: panel.minX + 30, y: panel.maxY - 30 - 96, width: panel.width - 60, height: 96)
    withShadow(0.3, 10, -3) {
        rgb(0x16213D).setFill()
        NSBezierPath(roundedRect: header, xRadius: 48, yRadius: 48).fill()
    }
    roundedStroke(header, radius: 48, rgb(0xFFFFFF, 0.14))
    pill(NSRect(x: header.minX + 34, y: header.midY - 13, width: 120, height: 26), rgb(0xFFFFFF, 0.92))
    for i in 0..<3 {
        let d: CGFloat = 44
        let cx = header.maxX - 30 - d / 2 - CGFloat(i) * 56
        rgb(0xFFFFFF, i == 0 ? 0.85 : 0.3).setFill()
        NSBezierPath(ovalIn: NSRect(x: cx - d / 2, y: header.midY - d / 2, width: d, height: d)).fill()
    }

    // Two notes: yellow and white (default color).
    let top = header.minY - 30
    let h = (top - (panel.minY + 30) - 26) / 2
    for (i, color) in [rgb(0xFFE27A), rgb(0xFFFFFF)].enumerated() {
        let r = NSRect(x: panel.minX + 30, y: top - h - CGFloat(i) * (h + 26), width: panel.width - 60, height: h)
        withShadow(0.25, 12, -4) {
            color.setFill()
            NSBezierPath(roundedRect: r, xRadius: 44, yRadius: 44).fill()
        }
        let t = r.insetBy(dx: 40, dy: 40)
        pill(NSRect(x: t.minX, y: t.maxY - 28.6, width: 160, height: 28.6), rgb(0x2B2B2B, 0.85))
        for (k, w) in [250, 250, 170].enumerated() {
            pill(NSRect(x: t.minX, y: t.maxY - 28.6 - 34 - CGFloat(k) * 44, width: CGFloat(w), height: 22), rgb(0x2B2B2B, 0.32))
        }
    }
    NSGraphicsContext.restoreGraphicsState()

    roundedStroke(body, radius: 185, rgb(0xFFFFFF, 0.22))
}

func render(pixels: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: pixels, height: pixels)
    NSGraphicsContext.saveGraphicsState()
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = ctx
    ctx.imageInterpolation = .high
    let scale = CGFloat(pixels) / 1024
    let t = NSAffineTransform()
    t.scale(by: scale)
    t.concat()
    drawIcon()
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = scale == 1 ? "icon_\(size)x\(size).png" : "icon_\(size)x\(size)@2x.png"
        try! render(pixels: size * scale).write(to: out.appendingPathComponent(name))
    }
}
print("Wrote \(out.path)")
