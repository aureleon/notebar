import AppKit

// MARK: - Days

/// Scratch days. A day is keyed "yyyy-MM-dd" (sorts like the dates it names) and starts at
/// `AppSettings.scratchRolloverHour` local time, so with 4 the hours from midnight to 4 AM still
/// belong to the day before.
public enum ScratchDay {
    /// The day `date` belongs to.
    public static func key(for date: Date, rolloverHour: Int, calendar: Calendar = .current) -> String {
        var day = calendar.startOfDay(for: date)
        if calendar.component(.hour, from: date) < clampHour(rolloverHour) {
            day = calendar.date(byAdding: .day, value: -1, to: day) ?? day
        }
        let c = calendar.dateComponents([.year, .month, .day], from: day)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// Noon of the day (a time that exists on every calendar day).
    public static func date(of key: String, calendar: Calendar = .current) -> Date? {
        let parts = key.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2], hour: 12))
    }

    /// The key `days` days after (negative: before) `key`.
    public static func key(_ key: String, addingDays days: Int, calendar: Calendar = .current) -> String {
        guard let d = date(of: key, calendar: calendar), let moved = calendar.date(byAdding: .day, value: days, to: d)
        else { return key }
        return Self.key(for: moved, rolloverHour: 0, calendar: calendar)
    }

    /// When the day after the one `date` belongs to starts.
    public static func nextRollover(after date: Date, rolloverHour: Int, calendar: Calendar = .current) -> Date {
        let h = clampHour(rolloverHour)
        let start = calendar.date(bySettingHour: h, minute: 0, second: 0, of: date) ?? date
        if start > date { return start }
        return calendar.date(byAdding: .day, value: 1, to: start) ?? date.addingTimeInterval(86_400)
    }

    /// "Today", "Yesterday", "Mon, May 11" (with the year when it is not this year's).
    public static func title(for key: String, today: String, calendar: Calendar = .current) -> String {
        if key == today { return "Today" }
        if key == Self.key(today, addingDays: -1, calendar: calendar) { return "Yesterday" }
        guard let d = date(of: key, calendar: calendar) else { return key }
        let f = DateFormatter()
        f.calendar = calendar
        f.timeZone = calendar.timeZone
        let sameYear = key.prefix(4) == today.prefix(4)
        f.setLocalizedDateFormatFromTemplate(sameYear ? "EEE MMM d" : "EEE MMM d yyyy")
        return f.string(from: d)
    }

    /// The full date for an expired note's heading ("Monday, May 11, 2026").
    public static func longTitle(for key: String, calendar: Calendar = .current) -> String {
        guard let d = date(of: key, calendar: calendar) else { return key }
        let f = DateFormatter()
        f.calendar = calendar
        f.timeZone = calendar.timeZone
        f.dateStyle = .full
        f.timeStyle = .none
        return f.string(from: d)
    }

    static func clampHour(_ h: Int) -> Int { max(0, min(23, h)) }
}

public extension Notification.Name {
    /// Posted by `ScratchService` when a new Scratch day starts (rollover, wake, clock or setting change).
    static let scratchDayDidChange = Notification.Name("NoteBar.scratchDayDidChange")
}

// MARK: - Service

/// The daily Scratch note: which day it is, today's note, the earlier days still kept, and the sweep
/// that drops the rest.
///
/// Sweep (at launch, at every rollover, on wake, and when the Scratch settings change):
/// - An empty note of an earlier day is deleted (nothing to keep).
/// - A note older than `scratchKeepDays` days before today leaves Scratch: it becomes a normal note
///   in the last / first folder, headed with its date, and goes to the trash (Settings › Data ›
///   Keep deleted items decides how long it stays restorable). A note that was in the trash already
///   stays there.
@MainActor
public final class ScratchService {
    private let store: NoteStore
    private let settings: AppSettings
    private let calendar: Calendar
    /// Checks set the clock.
    public var now: () -> Date = Date.init
    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []
    public private(set) var todayKey: String

    public init(store: NoteStore, settings: AppSettings, calendar: Calendar = .current) {
        self.store = store
        self.settings = settings
        self.calendar = calendar
        todayKey = ScratchDay.key(for: Date(), rolloverHour: settings.scratchRolloverHour, calendar: calendar)
    }

    deinit {
        timer?.invalidate()
        for o in observers {
            NotificationCenter.default.removeObserver(o)
            NSWorkspace.shared.notificationCenter.removeObserver(o)
        }
    }

    /// Sweeps now, then at every rollover.
    public func start() {
        refresh()
        let nc = NotificationCenter.default
        observers.append(nc.addObserver(forName: .appSettingsDidChange, object: nil, queue: .main) { [weak self] n in
            let key = n.userInfo?["key"] as? String
            guard key == "scratchKeepDays" || key == "scratchRolloverHour" || key == "scratchEnabled" else { return }
            MainActor.assumeIsolated { self?.refresh() }
        })
        for name in [NSNotification.Name.NSSystemClockDidChange, .NSSystemTimeZoneDidChange, .NSCalendarDayChanged] {
            observers.append(nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            })
        }
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        })
    }

    /// Recomputes today, sweeps, and re-arms the rollover timer. Posts `.scratchDayDidChange` when the
    /// day changed.
    public func refresh() {
        let date = now()
        let key = ScratchDay.key(for: date, rolloverHour: settings.scratchRolloverHour, calendar: calendar)
        let changed = key != todayKey
        todayKey = key
        sweep()
        schedule(after: date)
        if changed { NotificationCenter.default.post(name: .scratchDayDidChange, object: self) }
    }

    private func schedule(after date: Date) {
        timer?.invalidate()
        let next = ScratchDay.nextRollover(after: date, rolloverHour: settings.scratchRolloverHour, calendar: calendar)
        // A second late, so the new day has surely begun.
        let t = Timer(fire: next.addingTimeInterval(1), interval: 0, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    // MARK: Notes

    /// The oldest day still kept.
    public var oldestKeptKey: String { ScratchDay.key(todayKey, addingDays: -Self.clampKeepDays(settings.scratchKeepDays), calendar: calendar) }

    /// Today's note; created (empty) when `create` and there is none.
    @discardableResult
    public func todayNote(create: Bool) -> Note? {
        if let n = note(for: todayKey) { return n }
        guard create else { return nil }
        return store.createScratchNote(day: todayKey, mode: settings.defaultNoteMode)
    }

    public func note(for day: String) -> Note? {
        store.scratchNotes(includingTrashed: false).first { $0.scratchDay == day }
    }

    /// Days with a note, newest first: today (if it has a note) and the earlier days that are kept and
    /// not empty.
    public func days() -> [String] {
        let oldest = oldestKeptKey
        var seen = Set<String>()
        var out: [String] = []
        for n in store.scratchNotes(includingTrashed: false) {
            guard let d = n.scratchDay, d >= oldest, d <= todayKey, !seen.contains(d) else { continue }
            if d != todayKey, isBlank(n) { continue }
            seen.insert(d)
            out.append(d)
        }
        return out
    }

    public func title(for day: String) -> String { ScratchDay.title(for: day, today: todayKey, calendar: calendar) }

    // MARK: Sweep

    public func sweep() {
        let oldest = oldestKeptKey
        for n in store.scratchNotes(includingTrashed: true) {
            guard let d = n.scratchDay, d < todayKey else { continue }
            if isBlank(n) {
                store.deleteNote(id: n.id)
            } else if d < oldest {
                let heading = "# Scratch · \(ScratchDay.longTitle(for: d, calendar: calendar))"
                store.expireScratchNote(id: n.id, toFolder: expiryFolder(), body: heading + "\n" + n.body)
            }
        }
    }

    private func expiryFolder() -> FolderID {
        if let id = settings.lastFolderId, store.folder(id: id) != nil { return id }
        return store.folders()[0].id
    }

    private func isBlank(_ n: Note) -> Bool {
        n.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && store.attachments(for: n.id).isEmpty
    }

    public static let keepDaysRange = 1...30
    public static func clampKeepDays(_ d: Int) -> Int { max(keepDaysRange.lowerBound, min(keepDaysRange.upperBound, d)) }
}
