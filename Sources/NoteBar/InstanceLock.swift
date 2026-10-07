import AppKit
import Darwin
import NoteBarCore

/// One NoteBar process per data folder.
///
/// Every process keeps the whole database in an in-memory cache and writes full rows from it, so two
/// processes on one folder overwrite each other's notes (and both run the launch-time cleanups and
/// register the same hotkeys). The first process takes an exclusive `flock` on
/// `<data folder>/.notebar.lock` and keeps the descriptor open until it exits (the kernel releases
/// it on exit or crash). A second process for the same folder asks the first one to show its panel
/// and quits before it opens the database.
///
/// The lock is per data folder, not per bundle id, so runs with their own `NOTEBAR_DATA_DIR` work
/// next to the real app.
@MainActor
enum InstanceLock {
    /// Distributed notification: "show your panel". `object` is the data folder path, so only the
    /// process that owns that folder reacts.
    static let showPanelNotification = Notification.Name("local.dhguz.NoteBar.showPanel")

    private static var fd: Int32 = -1

    static var lockURL: URL { AppPaths.supportDirectory.appendingPathComponent(".notebar.lock") }

    /// The key that identifies the data folder in `showPanelNotification`.
    static var folderKey: String { AppPaths.supportDirectory.standardizedFileURL.resolvingSymlinksInPath().path }

    enum Result { case acquired, heldByOther(pid: Int32?), failed(String) }

    /// Takes the lock (idempotent). Call before the store is opened.
    static func acquire() -> Result {
        if fd >= 0 { return .acquired }
        let path = lockURL.path
        let f = open(path, O_RDWR | O_CREAT | O_CLOEXEC, 0o644)
        guard f >= 0 else { return .failed(String(cString: strerror(errno))) }
        if flock(f, LOCK_EX | LOCK_NB) != 0 {
            let err = errno
            let pid = readPID(f)
            close(f)
            return err == EWOULDBLOCK ? .heldByOther(pid: pid) : .failed(String(cString: strerror(err)))
        }
        // Record our pid (diagnostics, and to name the other process in the log).
        ftruncate(f, 0)
        let text = "\(getpid())\n"
        _ = text.withCString { write(f, $0, strlen($0)) }
        fd = f
        return .acquired
    }

    private static func readPID(_ f: Int32) -> Int32? {
        var buf = [UInt8](repeating: 0, count: 32)
        let n = pread(f, &buf, buf.count - 1, 0)
        guard n > 0 else { return nil }
        return Int32(String(decoding: buf[0..<n], as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// In the process that owns the lock: shows the panel when another launch asks for it.
    /// `.deliverImmediately`: AppKit suspends distributed notifications while the app is inactive,
    /// which an accessory app nearly always is.
    static func listenForShowRequests(_ handler: @escaping @MainActor () -> Void) {
        guard listener == nil else { return }
        let l = ShowRequestListener(handler)
        DistributedNotificationCenter.default().addObserver(
            l, selector: #selector(ShowRequestListener.received(_:)), name: showPanelNotification,
            object: folderKey, suspensionBehavior: .deliverImmediately)
        listener = l
    }

    private static var listener: ShowRequestListener?

    /// In the second process: asks the owner to show its panel, then exits.
    static func handOffAndExit(ownerPID: Int32?) -> Never {
        NSLog("NoteBar: another NoteBar (pid %@) already uses %@. Showing its panel and quitting.",
              ownerPID.map { String($0) } ?? "?", folderKey)
        DistributedNotificationCenter.default().postNotificationName(
            showPanelNotification, object: folderKey, userInfo: nil, deliverImmediately: true)
        // Give distnoted a moment before the process goes away.
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        exit(0)
    }
}

private final class ShowRequestListener: NSObject {
    private let handler: @MainActor () -> Void
    init(_ handler: @escaping @MainActor () -> Void) { self.handler = handler }
    @objc func received(_ note: Notification) {
        DispatchQueue.main.async { MainActor.assumeIsolated { self.handler() } }
    }
}
