import AppKit
import NoteBarCore
import UniformTypeIdentifiers

/// File promises: drags from Mail, Photos, Safari and other apps that write the file only when the
/// drop happens. They arrive asynchronously, so drop targets use `receive(from:completion:)`.
@MainActor
extension PasteboardImport {
    static let filePromiseTypes: [NSPasteboard.PasteboardType] =
        NSFilePromiseReceiver.readableDraggedTypes.map { NSPasteboard.PasteboardType($0) }

    static func filePromises(in pb: NSPasteboard) -> [NSFilePromiseReceiver] {
        guard pb.availableType(from: filePromiseTypes) != nil else { return [] }
        return pb.readObjects(forClasses: [NSFilePromiseReceiver.self], options: nil) as? [NSFilePromiseReceiver] ?? []
    }

    /// Reads a drop. Synchronous content calls `completion` at once; file promises call it when the
    /// files are written. Returns false (and never calls `completion`) when there is nothing usable.
    /// Call it from `performDragOperation` (promises can only be received during the drop).
    @discardableResult
    static func receive(from pb: NSPasteboard, completion: @escaping (ImportPayload) -> Void) -> Bool {
        // Real file URLs (Finder) win over promises; promises win over flattened image data,
        // because the promised file keeps its name and original format.
        if hasFileURLs(pb), let payload = payload(from: pb) {
            completion(payload)
            return true
        }
        let promises = filePromises(in: pb)
        if !promises.isEmpty {
            let fallback = payload(from: pb)
            receivePromisedFiles(promises) { urls in
                if !urls.isEmpty { completion(.files(urls)) } else if let fallback { completion(fallback) }
            }
            return true
        }
        guard let payload = payload(from: pb) else { return false }
        completion(payload)
        return true
    }

    static func hasFileURLs(_ pb: NSPasteboard) -> Bool {
        pb.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
    }

    /// Receives every promised file. Images go to a temporary folder (the store copies them);
    /// other files go to `receivedFilesDirectory`, because the store keeps only a bookmark to them.
    private static func receivePromisedFiles(_ promises: [NSFilePromiseReceiver], completion: @escaping ([URL]) -> Void) {
        let fm = FileManager.default
        let tempDir = fm.temporaryDirectory.appendingPathComponent("NoteBarDrops-\(UUID().uuidString)", isDirectory: true)
        try? fm.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let collector = PromiseCollector(expected: promises.reduce(0) { $0 + max(1, $1.fileTypes.count) }) { urls in
            let kept = urls.compactMap(keepReceivedFile)
            completion(kept)
            // Images were copied by the store by now; drop the temporary copies.
            try? fm.removeItem(at: tempDir)
        }
        let queue = OperationQueue()
        queue.qualityOfService = .userInitiated
        for promise in promises {
            promise.receivePromisedFiles(atDestination: tempDir, options: [:], operationQueue: queue) { url, error in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { collector.add(error == nil ? url : nil) }
                }
            }
        }
        // Safety net: a source that never delivers must not leave the drop hanging forever.
        DispatchQueue.main.asyncAfter(deadline: .now() + 60) {
            MainActor.assumeIsolated { collector.finish() }
        }
    }

    /// Images stay where they are (temporary). Other files move to a permanent folder.
    private static func keepReceivedFile(_ url: URL) -> URL? {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return nil }
        let isImage = UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) ?? false
        if isImage { return url }
        guard let base = receivedFilesDirectory else { return url }
        let dir = base.appendingPathComponent(UUID().uuidString, isDirectory: true)
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            let dest = dir.appendingPathComponent(url.lastPathComponent)
            try fm.moveItem(at: url, to: dest)
            return dest
        } catch {
            return url
        }
    }

    /// `<data folder>/Received Files` (honors `NOTEBAR_DATA_DIR`): non-image files dropped as promises.
    /// Same folder as the editor's `DroppedFileStorage`.
    static var receivedFilesDirectory: URL? {
        AppPaths.supportDirectory.appendingPathComponent("Received Files", isDirectory: true)
    }
}

/// Collects promised files until all arrived (or the timeout), then calls `done` once.
@MainActor
private final class PromiseCollector {
    private var remaining: Int
    private var urls: [URL] = []
    private var done: (([URL]) -> Void)?

    init(expected: Int, done: @escaping ([URL]) -> Void) {
        remaining = max(1, expected)
        self.done = done
    }

    func add(_ url: URL?) {
        if let url { urls.append(url) }
        remaining -= 1
        if remaining <= 0 { finish() }
    }

    func finish() {
        guard let done else { return }
        self.done = nil
        done(urls)
    }
}
