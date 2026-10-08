import AppKit

/// How long deleted notes and folders stay restorable (Settings › Data › Keep deleted items).
public enum DeletedItemsRetention: String, CaseIterable, Codable, Sendable {
    /// Until NoteBar quits (emptied at quit and at the next launch).
    case untilQuit
    /// One hour after the delete.
    case oneHour
    /// 30 days, listed in the "Recently Deleted" row of the folder list.
    case recentlyDeleted

    public var displayName: String {
        switch self {
        case .untilQuit: "Until NoteBar quits"
        case .oneHour: "For 1 hour"
        case .recentlyDeleted: "In Recently Deleted (\(TrashPurger.recentlyDeletedDays) days)"
        }
    }

    /// Seconds an item stays in the trash (nil: until quit).
    public var duration: TimeInterval? {
        switch self {
        case .untilQuit: nil
        case .oneHour: 3600
        case .recentlyDeleted: TimeInterval(TrashPurger.recentlyDeletedDays) * 86_400
        }
    }
}

/// Empties the store's trash by `AppSettings.deletedItemsRetention`: at launch, every few minutes,
/// and at quit. A setting change deletes nothing at once: items get the new time from the change.
@MainActor
public final class TrashPurger {
    public nonisolated static let recentlyDeletedDays = 30
    public static let interval: TimeInterval = 300

    public enum Moment: Sendable { case launch, periodic, quit }

    private let store: NoteStore
    private let settings: AppSettings
    private var timer: Timer?
    private var observer: NSObjectProtocol?

    public init(store: NoteStore, settings: AppSettings) {
        self.store = store
        self.settings = settings
    }

    deinit {
        timer?.invalidate()
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    public func start() {
        purge(.launch)
        let t = Timer(timeInterval: Self.interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.purge(.periodic) }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        observer = NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil,
                                                          queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.purge(.quit) }
        }
    }

    public func purge(_ moment: Moment, now: Date = Date()) {
        guard let cutoff = Self.cutoff(settings.deletedItemsRetention, moment: moment, now: now,
                                       policyChangedAt: settings.deletedItemsRetentionChangedAt) else { return }
        store.purgeTrash(deletedBefore: cutoff)
    }

    /// Items deleted before the returned date are deleted for good (nil: nothing now).
    public static func cutoff(_ policy: DeletedItemsRetention, moment: Moment, now: Date, policyChangedAt: Date?) -> Date? {
        guard let duration = policy.duration else {
            // Until quit: the trash is emptied at quit and at launch only.
            return moment == .periodic ? nil : now
        }
        let limit = now.addingTimeInterval(-duration)
        // A shorter time chosen recently counts from the change, not from the delete.
        if let changed = policyChangedAt, changed > limit { return nil }
        return limit
    }
}
