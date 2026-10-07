// Draws the NoteBar app icon and writes an .iconset folder.
// Usage: swift scripts/make-icon.swift <out.iconset>   (scripts/make-icon.sh wraps this + iconutil)
import AppKit

let out = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.iconset")
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}

/// Draws the icon into a 1024x1024 coordinate space.
func drawIcon() {
    // macOS icon grid: 824pt body centered in 1024, corner radius ~185.
    let body = NSRect(x: 100, y: 100, width: 824, height: 824)
    let bodyPath = NSBezierPath(roundedRect: body, xRadius: 185, yRadius: 185)

    // Drop shadow.
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
    shadow.shadowBlurRadius = 28
    shadow.shadowOffset = NSSize(width: 0, height: -12)
    shadow.set()
    rgb(0x1F2A44).setFill()
    bodyPath.fill()
    NSGraphicsContext.restoreGraphicsState()

    // Background: a "desktop" gradient.
    NSGraphicsContext.saveGraphicsState()
    bodyPath.addClip()
    NSGradient(colors: [rgb(0x3A7BD5), rgb(0x6A5ACD), rgb(0x9B59B6)], atLocations: [0, 0.6, 1],
               colorSpace: .sRGB)!.draw(in: body, angle: -60)

    // The side panel: frosted glass slab on the right edge.
    let panel = NSRect(x: body.maxX - 430, y: body.minY - 20, width: 470, height: body.height + 40)
    rgb(0xFFFFFF, 0.22).setFill()
    NSBezierPath(rect: panel).fill()
    rgb(0xFFFFFF, 0.45).setFill()
    NSBezierPath(rect: NSRect(x: panel.minX, y: panel.minY, width: 5, height: panel.height)).fill()

    // Note cards in the panel.
    let cardX = panel.minX + 42
    let cardW: CGFloat = 330
    let cards: [(y: CGFloat, h: CGFloat, color: NSColor, lines: Int)] = [
        (body.maxY - 250, 170, rgb(0xFFE27A), 3),
        (body.maxY - 450, 170, rgb(0xFFFFFF), 3),
        (body.maxY - 640, 160, rgb(0xA8E6A1), 2),
    ]
    for c in cards {
        let r = NSRect(x: cardX, y: c.y, width: cardW, height: c.h)
        NSGraphicsContext.saveGraphicsState()
        let s = NSShadow()
        s.shadowColor = NSColor.black.withAlphaComponent(0.25)
        s.shadowBlurRadius = 14
        s.shadowOffset = NSSize(width: 0, height: -5)
        s.set()
        c.color.setFill()
        NSBezierPath(roundedRect: r, xRadius: 34, yRadius: 34).fill()
        NSGraphicsContext.restoreGraphicsState()
        // Title bar + text lines.
        rgb(0x2B2B2B, 0.85).setFill()
        NSBezierPath(roundedRect: NSRect(x: r.minX + 34, y: r.maxY - 58, width: 180, height: 22), xRadius: 11, yRadius: 11).fill()
        rgb(0x2B2B2B, 0.35).setFill()
        for i in 0..<c.lines {
            let w: CGFloat = i == c.lines - 1 ? 150 : 250
            NSBezierPath(roundedRect: NSRect(x: r.minX + 34, y: r.maxY - 100 - CGFloat(i) * 32, width: w, height: 16),
                         xRadius: 8, yRadius: 8).fill()
        }
    }

    // Open Bar tab on the panel's edge.
    rgb(0xFFFFFF, 0.9).setFill()
    NSBezierPath(roundedRect: NSRect(x: panel.minX - 34, y: body.midY - 80, width: 22, height: 160), xRadius: 11, yRadius: 11).fill()

    // Gloss.
    NSGradient(colors: [rgb(0xFFFFFF, 0.18), rgb(0xFFFFFF, 0)], atLocations: [0, 1], colorSpace: .sRGB)!
        .draw(in: NSRect(x: body.minX, y: body.midY, width: body.width, height: body.height / 2), angle: -90)
    NSGraphicsContext.restoreGraphicsState()

    // Hairline border.
    rgb(0xFFFFFF, 0.25).setStroke()
    let border = NSBezierPath(roundedRect: body.insetBy(dx: 1.5, dy: 1.5), xRadius: 184, yRadius: 184)
    border.lineWidth = 3
    border.stroke()
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
