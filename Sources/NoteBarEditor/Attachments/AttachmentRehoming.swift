import Foundation
import NoteBarCore

/// Gives pasted / dropped markdown its own attachment rows.
///
/// Copy, cut and drag write plain markdown, so an image or file tile moved to another note carries the
/// `attachment:ID` of the source note. The store deletes a note's attachments (and image files) together
/// with the note, so the target note would lose the image when the source note is deleted. Before the
/// text goes into a note, every token that belongs to a different note is cloned into the target note
/// (the image file is copied, the file shortcut gets a new bookmark) and the token is rewritten.
@MainActor
public enum AttachmentRehoming {
    /// Returns `markdown` with every attachment token that belongs to another note pointing to a clone
    /// owned by `noteId`. Tokens of unknown attachments, of `noteId` itself, or whose file cannot be found
    /// stay unchanged. The same source ID is cloned once per call.
    public static func rehome(_ markdown: String, into noteId: NoteID, store: NoteStore) -> String {
        guard markdown.contains("](attachment:") else { return markdown }
        let matches = AttachmentLink.matches(in: markdown)
        guard !matches.isEmpty else { return markdown }
        var clones: [AttachmentID: Attachment] = [:]
        var failed = Set<AttachmentID>()
        let out = NSMutableString(string: markdown)
        // Back to front so earlier ranges stay valid.
        for m in matches.reversed() {
            guard let source = store.attachment(id: m.attachmentID), source.noteId != noteId,
                  !failed.contains(source.id) else { continue }
            let clone: Attachment
            if let c = clones[source.id] {
                clone = c
            } else if let c = self.clone(source, into: noteId, store: store) {
                clones[source.id] = c
                clone = c
            } else {
                failed.insert(source.id)
                continue
            }
            out.replaceCharacters(in: m.nsRange, with: token(name: m.name, for: clone))
        }
        return out as String
    }

    /// Copies one attachment into `noteId`. Returns nil when the source file is gone.
    public static func clone(_ source: Attachment, into noteId: NoteID, store: NoteStore) -> Attachment? {
        guard store.note(id: noteId) != nil, let url = store.url(for: source) else { return nil }
        switch source.kind {
        case .image:
            guard let data = try? Data(contentsOf: url), !data.isEmpty else { return nil }
            let ext = url.pathExtension.isEmpty ? (source.displayName as NSString).pathExtension : url.pathExtension
            return try? store.addImageAttachment(to: noteId, data: data, fileExtension: ext.isEmpty ? "png" : ext,
                                                 displayName: source.displayName)
        case .fileBookmark:
            guard FileManager.default.fileExists(atPath: url.path) else { return nil }
            return try? store.addAttachment(to: noteId, fileURL: url)
        }
    }

    /// The token for `attachment`, keeping the label the user saw.
    static func token(name: String, for attachment: Attachment) -> String {
        let label = name.replacingOccurrences(of: "]", with: ")")
        let bang = attachment.kind == .image ? "!" : ""
        return "\(bang)[\(label)](\(AttachmentLink.scheme):\(attachment.id))"
    }
}
