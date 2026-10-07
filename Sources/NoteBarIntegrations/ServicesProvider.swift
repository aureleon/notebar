import AppKit
import NoteBarCore

/// `NSApp.servicesProvider`. Methods match the `NSMessage` values in Resources/Info.plist:
///
/// - "NoteBar/New Note from Selection" → `newNoteFromSelection:userData:error:` (selected text)
/// - "NoteBar/New Note with Files"     → `newNoteWithFiles:userData:error:` (files selected in Finder)
///
/// The new note is revealed (panel slides in, note focused) so the user sees what happened.
/// Set `defaults write local.dhguz.NoteBar NoteBarServicesRevealNote -bool NO` to create notes silently.
@MainActor
@objc(NBServicesProvider)
final class ServicesProvider: NSObject {
    static let revealDefaultsKey = "NoteBarServicesRevealNote"

    private let actions: IntegrationActions

    init(actions: IntegrationActions) {
        self.actions = actions
        super.init()
    }

    private var reveal: Bool {
        (UserDefaults.standard.object(forKey: Self.revealDefaultsKey) as? Bool) ?? true
    }

    @objc func newNoteFromSelection(_ pboard: NSPasteboard, userData: String?,
                                    error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        guard let text = Self.text(from: pboard) else {
            error.pointee = "NoteBar: no text was selected." as NSString
            return
        }
        let reveal = self.reveal
        actions.whenReady { [actions] in
            do { try actions.createNote(text: text, folder: nil, show: reveal) }
            catch { integrationsLog.error("Service failed: \(String(describing: error), privacy: .public)") }
        }
    }

    @objc func newNoteWithFiles(_ pboard: NSPasteboard, userData: String?,
                                error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        let urls = (pboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        guard !urls.isEmpty else {
            // No files: fall back to text (e.g. a path copied as text).
            newNoteFromSelection(pboard, userData: userData, error: error)
            return
        }
        let reveal = self.reveal
        actions.whenReady { [actions] in
            do { try actions.createNote(withFiles: urls, show: reveal) }
            catch { integrationsLog.error("Service failed: \(String(describing: error), privacy: .public)") }
        }
    }

    /// Plain text from the service pasteboard (UTF-8 plain text, legacy NSStringPboardType, or rich text).
    static func text(from pboard: NSPasteboard) -> String? {
        var s = pboard.string(forType: .string)
        if s == nil, let legacy = pboard.string(forType: NSPasteboard.PasteboardType("NSStringPboardType")) { s = legacy }
        if s == nil, let objs = pboard.readObjects(forClasses: [NSAttributedString.self, NSString.self]) {
            s = objs.lazy.compactMap { ($0 as? NSAttributedString)?.string ?? ($0 as? String) }.first
        }
        guard let s, !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        // Drop blank lines around the selection so the first line becomes the title (keep indentation).
        return s.trimmingCharacters(in: .newlines)
    }
}
