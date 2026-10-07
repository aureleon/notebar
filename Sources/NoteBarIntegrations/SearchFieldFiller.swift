import AppKit

/// Types a query into the panel's search field after `AppController.showSearch()`.
///
/// `NotesPresenting.beginSearch()` has no query parameter (see "Core requests"), so this finds the
/// focused field editor of the visible floating panel and inserts the text, which sends the normal
/// text-change notifications to the search field. The panel slides in with an animation, so it
/// retries for a short time until the field has focus.
@MainActor
enum SearchFieldFiller {
    private static var generation = 0

    static func fill(_ query: String, attempts: Int = 25, interval: TimeInterval = 0.04) {
        generation += 1
        let gen = generation
        attempt(query, remaining: attempts, interval: interval, generation: gen)
    }

    private static func attempt(_ query: String, remaining: Int, interval: TimeInterval, generation gen: Int) {
        guard gen == generation else { return } // a newer search request replaced this one
        if let editor = focusedSearchEditor() {
            let all = NSRange(location: 0, length: (editor.string as NSString).length)
            if editor.shouldChangeText(in: all, replacementString: query) {
                editor.replaceCharacters(in: all, with: query)
                editor.didChangeText()
            }
            editor.setSelectedRange(NSRange(location: (query as NSString).length, length: 0))
            return
        }
        guard remaining > 0 else {
            integrationsLog.notice("Search field not found; query not filled in")
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + interval) {
            attempt(query, remaining: remaining - 1, interval: interval, generation: gen)
        }
    }

    /// The field editor of a visible floating panel (the NoteBar side panel), if focused.
    private static func focusedSearchEditor() -> NSTextView? {
        let candidates = NSApp.windows.filter { $0.isVisible && $0 is NSPanel && $0.level.rawValue >= NSWindow.Level.floating.rawValue }
        let ordered = candidates.sorted { a, b in a.isKeyWindow && !b.isKeyWindow }
        for w in ordered {
            if let tv = w.firstResponder as? NSTextView, tv.isFieldEditor, tv.delegate is NSTextField {
                return tv
            }
        }
        return nil
    }
}
