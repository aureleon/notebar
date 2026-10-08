import Foundation
import NoteBarCore

/// Writes every note as a Markdown file:
///
///     <directory>/<Folder name>/<Note title>.md
///     <directory>/<Folder name>/attachments/<file>
///
/// Attachment links (`![name](attachment:42)`) are rewritten to relative paths into the folder's
/// `attachments/` subfolder. Linked folders (file shortcuts to directories) are not copied; they become
/// `file://` links. Existing files in `directory` are never overwritten (names get " 2", " 3"…).
@MainActor
public struct MarkdownExporter {
    public let store: NoteStore

    public init(store: NoteStore) { self.store = store }

    public func export(to directory: URL) throws {
        let fm = FileManager.default
        store.flush()
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        var folderNames = FileNames.existingNames(in: directory)

        let archived = Dictionary(grouping: store.archivedNotes(), by: \.folderId)
        for folder in store.folders() {
            let folderDir = directory.appendingPathComponent(
                FileNames.unique(FileNames.sanitize(folder.name, fallback: "Folder"), ext: "", taken: &folderNames),
                isDirectory: true)
            try fm.createDirectory(at: folderDir, withIntermediateDirectories: true)
            var context = FolderContext(directory: folderDir)
            // Archived notes are exported with their folder.
            for note in store.notes(in: folder.id) + (archived[folder.id] ?? []) {
                let body = rewriteLinks(in: note.body, context: &context)
                let base = FileNames.sanitize(note.title, fallback: "Untitled")
                let file = folderDir.appendingPathComponent(FileNames.unique(base, ext: "md", taken: &context.noteNames))
                do {
                    try Data(body.utf8).write(to: file, options: .atomic)
                } catch {
                    throw NoteStoreError.io("Cannot write \(file.lastPathComponent): \(error.localizedDescription)")
                }
                try? fm.setAttributes([.creationDate: note.createdAt, .modificationDate: note.updatedAt],
                                      ofItemAtPath: file.path)
            }
        }
    }

    // MARK: Links

    private struct FolderContext {
        let directory: URL
        var noteNames: Set<String>
        var attachmentNames: Set<String> = []
        var attachmentsReady = false
        /// Attachment id → link target already exported for this folder.
        var exported: [AttachmentID: String] = [:]

        init(directory: URL) {
            self.directory = directory
            noteNames = FileNames.existingNames(in: directory)
        }

        var attachmentsDirectory: URL { directory.appendingPathComponent("attachments", isDirectory: true) }
    }

    private func rewriteLinks(in body: String, context: inout FolderContext) -> String {
        let matches = AttachmentLink.matches(in: body)
        guard !matches.isEmpty else { return body }
        var result = body
        for m in matches.reversed() {
            let replacement: String
            if let target = linkTarget(for: m.attachmentID, context: &context) {
                replacement = "\(m.isImage ? "!" : "")[\(m.name)](\(target))"
            } else {
                replacement = "\(m.name) (missing attachment)"
            }
            result.replaceSubrange(m.range, with: replacement)
        }
        return result
    }

    /// Copies the attachment into the folder's `attachments/` (once) and returns the link target.
    private func linkTarget(for id: AttachmentID, context: inout FolderContext) -> String? {
        if let done = context.exported[id] { return done }
        guard let a = store.attachment(id: id), let source = store.url(for: a) else { return nil }
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: source.path, isDirectory: &isDir) else { return nil }
        if isDir.boolValue {
            // Do not copy whole folders (could be huge); link to the original location.
            let target = source.absoluteString
            context.exported[id] = target
            return target
        }
        if !context.attachmentsReady {
            try? fm.createDirectory(at: context.attachmentsDirectory, withIntermediateDirectories: true)
            context.attachmentNames = FileNames.existingNames(in: context.attachmentsDirectory)
            context.attachmentsReady = true
        }
        // Prefer the display name; images stored under a UUID keep their real extension.
        var name = a.displayName
        let realExt = source.pathExtension
        if (name as NSString).pathExtension.isEmpty, !realExt.isEmpty { name += "." + realExt }
        let ext = (name as NSString).pathExtension
        let base = FileNames.sanitize((name as NSString).deletingPathExtension, fallback: "attachment")
        let fileName = FileNames.unique(base, ext: FileNames.sanitize(ext, fallback: realExt, maxLength: 10),
                                        taken: &context.attachmentNames)
        do {
            try fm.copyItem(at: source, to: context.attachmentsDirectory.appendingPathComponent(fileName))
        } catch {
            NSLog("NoteBarStore: export could not copy %@: %@", source.path, error.localizedDescription)
            return nil
        }
        let target = FileNames.linkPath("attachments/" + fileName)
        context.exported[id] = target
        return target
    }
}
