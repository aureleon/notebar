import AppKit
import NoteBarCore

/// Persistent home for files that arrive as file promises (Mail attachments, Messages files, ...).
///
/// The store copies images into `attachments/`, but other files become bookmarks to wherever they are.
/// A promise is written to a folder the receiver chooses, so that folder must outlive `$TMPDIR` (macOS
/// purges it). Files live in `<support>/Received Files/<uuid>/<name>`
/// (the same folder NoteBarUI uses for promises dropped onto the panel). The folder is outside
/// `attachments/` because the store deletes every unknown item there at launch.
@MainActor
public enum DroppedFileStorage {
    public static var rootDirectory: URL {
        AppPaths.supportDirectory.appendingPathComponent("Received Files", isDirectory: true)
    }

    /// Creates a new, empty folder to receive promised files into.
    static func makeDropFolder() -> URL? {
        let dir = rootDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            return dir
        } catch {
            return nil
        }
    }

    /// Receives every promised file into `folder` and calls `completion` once on the main thread with the
    /// files that arrived (in drop order). The reader block of `NSFilePromiseReceiver` runs once per file,
    /// so the expected count is the number of promised file types. A timeout finishes stalled promises.
    static func receive(_ promises: [NSFilePromiseReceiver], into folder: URL, timeout: TimeInterval = 120,
                        completion: @escaping @MainActor ([URL]) -> Void) {
        final class Collector {
            var slots: [[URL]]
            var pending: Int
            var done = false
            init(count: Int, pending: Int) { slots = Array(repeating: [], count: count); self.pending = pending }
        }
        let expected = promises.map { max(1, $0.fileTypes.count) }
        let c = Collector(count: promises.count, pending: expected.reduce(0, +))
        func finish() {
            guard !c.done else { return }
            c.done = true
            let files = c.slots.flatMap { $0 }
            MainActor.assumeIsolated { completion(files) }
        }
        for (i, p) in promises.enumerated() {
            p.receivePromisedFiles(atDestination: folder, options: [:], operationQueue: .main) { url, error in
                guard !c.done else { return }
                if error == nil, FileManager.default.fileExists(atPath: url.path) { c.slots[i].append(url) }
                c.pending -= 1
                if c.pending <= 0 { finish() }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { finish() }
    }

    /// After import: removes received files the store copied (images) and the folder when it is empty.
    static func finishImport(folder: URL, received: [URL], added: [(URL, Attachment)]) {
        let fm = FileManager.default
        let kept = Set(added.filter { $0.1.kind == .fileBookmark }.map { $0.0.standardizedFileURL.path })
        for url in received where !kept.contains(url.standardizedFileURL.path) {
            try? fm.removeItem(at: url)
        }
        removeIfEmpty(folder)
    }

    static func removeIfEmpty(_ folder: URL) {
        let fm = FileManager.default
        let items = (try? fm.contentsOfDirectory(atPath: folder.path)) ?? []
        if items.allSatisfy({ $0.hasPrefix(".") }) { try? fm.removeItem(at: folder) }
    }

    /// Deletes drop folders that no file-shortcut attachment points into any more (the note or the
    /// tile was deleted). Folders newer than `age` are kept, so an undo in the same session still works.
    /// Returns the number of removed folders.
    @discardableResult
    public static func pruneUnreferenced(store: NoteStore, olderThan age: TimeInterval = 7 * 24 * 3600,
                                         root rootURL: URL? = nil) -> Int {
        let fm = FileManager.default
        let root = (rootURL ?? rootDirectory).standardizedFileURL.resolvingSymlinksInPath()
        guard let folders = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.creationDateKey],
                                                        options: [.skipsHiddenFiles]), !folders.isEmpty else { return 0 }
        var used = Set<String>()
        let rootPath = root.path + "/"
        for folder in store.folders() {
            for note in store.notes(in: folder.id) {
                for a in store.attachments(for: note.id) where a.kind == .fileBookmark {
                    guard let url = store.url(for: a)?.standardizedFileURL.resolvingSymlinksInPath() else { continue }
                    let p = url.path
                    guard p.hasPrefix(rootPath) else { continue }
                    if let first = p.dropFirst(rootPath.count).split(separator: "/").first { used.insert(String(first)) }
                }
            }
        }
        let cutoff = Date().addingTimeInterval(-age)
        var removed = 0
        for f in folders where !used.contains(f.lastPathComponent) {
            let created = (try? f.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
            guard created < cutoff else { continue }
            if (try? fm.removeItem(at: f)) != nil { removed += 1 }
        }
        return removed
    }
}
