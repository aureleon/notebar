import AppKit
import ImageIO
import QuickLookThumbnailing

/// Process-wide caches for attachment images, Quick Look thumbnails and file icons.
/// Loading happens off the main thread; completions run on the main thread.
@MainActor
final class AttachmentResources {
    static let shared = AttachmentResources()

    private let images = NSCache<NSString, NSImage>()
    private let thumbnails = NSCache<NSString, NSImage>()
    private var pendingImages: [String: [(NSImage?) -> Void]] = [:]
    private var pendingThumbs: [String: [(NSImage?) -> Void]] = [:]
    private var missing = Set<String>()

    private init() {
        images.totalCostLimit = 256 * 1024 * 1024
        thumbnails.countLimit = 400
    }

    // MARK: Images

    func cachedImage(_ url: URL) -> NSImage? { images.object(forKey: url.path as NSString) }

    func isMissing(_ url: URL) -> Bool { missing.contains(url.path) }

    /// Forgets files that failed to load (they may exist again, e.g. after a backup restore).
    func forgetMissing() { missing.removeAll() }

    /// Drops every cached image and thumbnail (after a restore the same paths may hold other files).
    func reset() {
        missing.removeAll()
        images.removeAllObjects()
        thumbnails.removeAllObjects()
    }

    /// Decodes the image (downsampled to at most `maxPixel` on the long side) on a background queue.
    func loadImage(_ url: URL, maxPixel: Int = 2400, completion: @escaping (NSImage?) -> Void) {
        let key = url.path
        if let img = images.object(forKey: key as NSString) { completion(img); return }
        if missing.contains(key) { completion(nil); return }
        if pendingImages[key] != nil { pendingImages[key]!.append(completion); return }
        pendingImages[key] = [completion]
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Self.decode(url, maxPixel: maxPixel)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    let image = result.map { r -> NSImage in
                        let img = NSImage(cgImage: r.image, size: r.pointSize)
                        return img
                    }
                    if let image, let r = result {
                        self.images.setObject(image, forKey: key as NSString, cost: r.image.width * r.image.height * 4)
                    } else {
                        self.missing.insert(key)
                    }
                    let waiters = self.pendingImages.removeValue(forKey: key) ?? []
                    for w in waiters { w(image) }
                }
            }
        }
    }

    private struct Decoded: @unchecked Sendable { var image: CGImage; var pointSize: NSSize }

    nonisolated private static func decode(_ url: URL, maxPixel: Int) -> Decoded? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] ?? [:]
        var pw = (props[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue ?? 0
        var ph = (props[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue ?? 0
        let orientation = (props[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        if orientation >= 5 { swap(&pw, &ph) }
        let dpi = (props[kCGImagePropertyDPIWidth] as? NSNumber)?.doubleValue ?? 72
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
        if pw <= 0 || ph <= 0 { pw = Double(cg.width); ph = Double(cg.height) }
        let scale = dpi > 0 ? 72 / dpi : 1
        return Decoded(image: cg, pointSize: NSSize(width: pw * scale, height: ph * scale))
    }

    // MARK: Thumbnails

    func cachedThumbnail(_ url: URL) -> NSImage? { thumbnails.object(forKey: url.path as NSString) }

    /// Quick Look thumbnail (falls back to nil; callers show the file icon meanwhile).
    func loadThumbnail(_ url: URL, size: NSSize, completion: @escaping (NSImage?) -> Void) {
        let key = url.path
        if let t = thumbnails.object(forKey: key as NSString) { completion(t); return }
        if pendingThumbs[key] != nil { pendingThumbs[key]!.append(completion); return }
        pendingThumbs[key] = [completion]
        let request = QLThumbnailGenerator.Request(fileAt: url, size: size, scale: 2, representationTypes: .thumbnail)
        request.iconMode = false
        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { rep, _ in
            let cg = rep?.cgImage
            let box = UncheckedBox(cg)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    var image: NSImage?
                    if let cg = box.value {
                        image = NSImage(cgImage: cg, size: NSSize(width: CGFloat(cg.width) / 2, height: CGFloat(cg.height) / 2))
                        self.thumbnails.setObject(image!, forKey: key as NSString)
                    }
                    let waiters = self.pendingThumbs.removeValue(forKey: key) ?? []
                    for w in waiters { w(image) }
                }
            }
        }
    }

    func icon(for url: URL) -> NSImage {
        NSWorkspace.shared.icon(forFile: url.path)
    }
}

struct UncheckedBox<T>: @unchecked Sendable {
    let value: T
    init(_ value: T) { self.value = value }
}
