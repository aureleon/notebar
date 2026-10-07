import AppKit
import NoteBarCore
import UniformTypeIdentifiers

/// Internal drag types (card / folder reorder). External apps never see them.
extension NSPasteboard.PasteboardType {
    static let noteBarNoteID = NSPasteboard.PasteboardType("com.notebar.note-id")
    static let noteBarFolderID = NSPasteboard.PasteboardType("com.notebar.folder-id")
}

/// Content dropped or pasted onto the panel.
enum ImportPayload {
    case text(String)
    case files([URL])
    case image(Data, fileExtension: String, name: String?)
}

/// Reads drops / the clipboard and turns them into notes or attachments.
@MainActor
enum PasteboardImport {
    /// Types the panel accepts from other apps.
    static let externalTypes: [NSPasteboard.PasteboardType] = [
        .fileURL, .URL, .png, .tiff, NSPasteboard.PasteboardType(UTType.jpeg.identifier),
        NSPasteboard.PasteboardType(UTType.heic.identifier), .string,
    ]

    /// Types that carry a file or an image (accepted on an existing card's chrome).
    static let attachmentTypes: [NSPasteboard.PasteboardType] = [
        .fileURL, .png, .tiff, NSPasteboard.PasteboardType(UTType.jpeg.identifier),
        NSPasteboard.PasteboardType(UTType.heic.identifier), .string,
    ]

    static func hasInternalNote(_ pb: NSPasteboard) -> Bool { pb.availableType(from: [.noteBarNoteID]) != nil }
    static func hasInternalFolder(_ pb: NSPasteboard) -> Bool { pb.availableType(from: [.noteBarFolderID]) != nil }

    static func noteID(from pb: NSPasteboard) -> NoteID? {
        pb.string(forType: .noteBarNoteID).flatMap { Int64($0) }
    }

    static func folderID(from pb: NSPasteboard) -> FolderID? {
        pb.string(forType: .noteBarFolderID).flatMap { Int64($0) }
    }

    /// Files first, then image data, then a web URL / text.
    static func payload(from pb: NSPasteboard) -> ImportPayload? {
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
           !urls.isEmpty {
            return .files(urls)
        }
        let imageTypes: [(NSPasteboard.PasteboardType, String)] = [
            (.png, "png"), (NSPasteboard.PasteboardType(UTType.jpeg.identifier), "jpg"),
            (NSPasteboard.PasteboardType(UTType.heic.identifier), "heic"),
        ]
        for (type, ext) in imageTypes {
            if let data = pb.data(forType: type), !data.isEmpty { return .image(data, fileExtension: ext, name: nil) }
        }
        if pb.availableType(from: [.string]) == nil, let tiff = pb.data(forType: .tiff),
           let rep = NSBitmapImageRep(data: tiff), let png = rep.representation(using: .png, properties: [:]) {
            return .image(png, fileExtension: "png", name: nil)
        }
        if let s = pb.string(forType: .string), !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .text(s)
        }
        if let url = pb.readObjects(forClasses: [NSURL.self], options: nil)?.first as? URL {
            return .text(url.absoluteString)
        }
        if let tiff = pb.data(forType: .tiff), let rep = NSBitmapImageRep(data: tiff),
           let png = rep.representation(using: .png, properties: [:]) {
            return .image(png, fileExtension: "png", name: nil)
        }
        return nil
    }

    static func canImport(_ pb: NSPasteboard) -> Bool {
        pb.availableType(from: externalTypes) != nil
    }

    /// Adds files / an image as attachments of `noteId`. Returns the attachments that were added.
    static func attachments(for payload: ImportPayload, noteId: NoteID, store: NoteStore) -> (added: [Attachment], failed: Int) {
        var added: [Attachment] = []
        var failed = 0
        switch payload {
        case .text: break
        case .files(let urls):
            for url in urls {
                do { added.append(try store.addAttachment(to: noteId, fileURL: url)) } catch { failed += 1 }
            }
        case .image(let data, let ext, let name):
            do {
                added.append(try store.addImageAttachment(to: noteId, data: data, fileExtension: ext,
                                                          displayName: name ?? "Image.\(ext)"))
            } catch { failed += 1 }
        }
        return (added, failed)
    }

    /// Creates a new note at the top of `folderId` holding the payload. Returns nil if nothing usable.
    @discardableResult
    static func createNote(from payload: ImportPayload, in folderId: FolderID, env: AppEnvironment) -> Note? {
        let store = env.store
        let mode = env.settings.defaultNoteMode
        switch payload {
        case .text(let text):
            return store.createNote(in: folderId, body: text, mode: mode, position: .top)
        case .files, .image:
            let note = store.createNote(in: folderId, body: "", mode: mode, position: .top)
            let result = attachments(for: payload, noteId: note.id, store: store)
            guard !result.added.isEmpty else {
                store.deleteNote(id: note.id)
                return nil
            }
            var n = store.note(id: note.id) ?? note
            n.body = result.added.map(AttachmentLink.markdown(for:)).joined(separator: "\n")
            store.updateNote(n)
            return store.note(id: note.id) ?? n
        }
    }

    /// Appends the payload to an existing note (via its editor when there is one).
    @discardableResult
    static func add(_ payload: ImportPayload, to noteId: NoteID, editor: (any NoteEditing)?, env: AppEnvironment) -> Bool {
        let store = env.store
        switch payload {
        case .text(let text):
            guard var n = store.note(id: noteId) else { return false }
            n.body = n.body.isEmpty ? text : (n.body.hasSuffix("\n") ? n.body + text : n.body + "\n" + text)
            store.updateNote(n)
            return true
        case .files, .image:
            let result = attachments(for: payload, noteId: noteId, store: store)
            guard !result.added.isEmpty else { return false }
            if let editor {
                editor.insertAttachments(result.added)
            } else if var n = store.note(id: noteId) {
                let tokens = result.added.map(AttachmentLink.markdown(for:)).joined(separator: "\n")
                n.body = n.body.isEmpty ? tokens : (n.body.hasSuffix("\n") ? n.body + tokens : n.body + "\n" + tokens)
                store.updateNote(n)
            }
            return true
        }
    }
}
