import AppKit
import NoteBarCore

/// The Scratch screen: one day's Scratch note. Its chip in the header is open and holds ‹ day ›.
/// The note is a log of entries (`ScratchEntries`): opening it to type (hotkey, the + button, menu
/// bar, URL) starts a new entry at the end. A click into the text edits in place.
/// Today's note is editable; earlier days are read-only (Save as Note keeps a copy). The screen follows
/// the day when a new one starts, except while the user is typing in it.
extension NotesRootViewController {
    var isScratchScreen: Bool { if case .scratch = screen { return true }; return false }
    var isScratchOrigin: Bool { if case .scratch? = search?.origin { return true }; return false }

    var scratchToolTip: String {
        "Scratch" + (env.settings.hotkeys[.scratch].map { " (\($0.displayString))" } ?? "")
    }

    /// Hotkey, + on Scratch, menu bar, `notebar://scratch`: today's note, `edit` = ready to type. The
    /// Scratch chip shows it without the caret (`edit` false).
    public func showScratch(edit: Bool) {
        _ = view
        guard env.settings.scratchEnabled, let note = env.scratch.todayNote(create: true) else { return }
        if edit {
            scratchEntryPending = true
            revealNote(note.id, edit: true, insert: true)
            // Still set only while the reveal waits for the window (`pendingFocus`).
            if pendingFocus == nil { scratchEntryPending = false }
        } else {
            showScratchDay(env.scratch.todayKey)
        }
    }

    func showScratchDay(_ day: String) {
        _ = view
        guard env.settings.scratchEnabled else { return }
        if search != nil { endSearch(restore: false, focusRoot: false) }
        let s = env.scratch
        if day == s.todayKey { s.todayNote(create: true) }
        scratchFollowsToday = day == s.todayKey
        if screen != .scratch(day) {
            let hadFocus = isFocusInsideNotes
            clearNotesList()
            focusedNoteID = nil
            screen = .scratch(day)
            reloadNotes(animated: false)
            // Today is a log: the newest entry is at the end, so it opens there. An earlier day reads
            // from its start.
            if day == s.todayKey {
                rootView.layoutSubtreeIfNeeded()
                notesList.scrollToBottom()
            } else {
                notesList.scrollToTop()
            }
            if hadFocus { focusRoot() }
        } else {
            reloadNotes(animated: false)
        }
        folderTabs.endRename()
        updateHeader()
        rootView.needsLayout = true
    }

    /// The card of `day`. A day that is gone (deleted, expired) shows the next later day, else today.
    func reloadScratch(day: String, animated: Bool) {
        let s = env.scratch
        var note = s.note(for: day)
        if note == nil, day == s.todayKey { note = s.todayNote(create: true) }
        guard let note else {
            let next = s.days().filter { $0 > day }.last ?? s.todayKey
            scratchFollowsToday = next == s.todayKey
            screen = .scratch(next)
            reloadScratch(day: next, animated: false)
            updateHeader()
            return
        }
        notesList.setNotes([note], animated: animated, forceUnfolded: true)
        notesList.allowsReorder = false
        notesList.setEmptyState(title: nil, subtitle: nil)
        if let card = notesList.card(for: note.id) {
            // The card being typed in when the day changes stays editable until the typing ends.
            let keepsToday = card.scratchRole == .today && card.isEditorFocused
            card.scratchRole = day == s.todayKey || keepsToday ? .today : .past
        }
    }

    /// ‹ (-1) an earlier day with a note, › (+1) a later one (at last today).
    func stepScratchDay(_ delta: Int) {
        guard case .scratch(let day) = screen, search == nil else { return }
        let s = env.scratch
        let days = s.days() // newest first
        let target = delta < 0 ? days.first { $0 < day } : (days.last { $0 > day } ?? (day < s.todayKey ? s.todayKey : nil))
        guard let target else { NSSound.beep(); return }
        showScratchDay(target)
    }

    func scratchDayChanged() {
        guard isScratchScreen else { return }
        followTodayIfNeeded()
        if isScratchScreen, search == nil { reloadNotes(animated: false); updateHeader() }
    }

    /// After a day change: moves the Scratch screen from yesterday to today unless the user is typing there.
    func followTodayIfNeeded() {
        guard case .scratch(let day) = screen, search == nil, scratchFollowsToday else { return }
        let today = env.scratch.todayKey
        guard day != today else { return }
        if isEditingText, isFocusInsideNotes { return }
        showScratchDay(today)
    }

    func scratchSettingsChanged() {
        guard header != nil else { return }
        // Scratch was turned off while it shows: the last folder.
        if !env.settings.scratchEnabled, isScratchScreen || isScratchOrigin {
            showLastFolder()
            return
        }
        updateHeader()
    }
}
