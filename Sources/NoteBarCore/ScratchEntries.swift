import Foundation

/// Entries of a Scratch note. An entry is the text written in one visit. A marker line starts it:
///
///     --- 14:32 ---        the entry began at 14:32 (24 h, local time)
///     --- 14:32 x ---      the same, marked done
///
/// The marker is a line of its own, outside fenced code. The editor shows it as a hairline (with the
/// time after a gap of `labelGapMinutes`). In the body it stays this plain text. Text before the first
/// marker is an entry without a marker. Only Scratch notes have entries: a copy that leaves Scratch
/// goes through `exported`.
public enum ScratchEntries {
    /// Opening Scratch this soon after the last edit continues the last entry.
    public static let mergeWindow: TimeInterval = 120
    /// A marker shows its time when this many minutes passed since the last shown time.
    public static let labelGapMinutes = 30

    public struct Marker: Hashable, Sendable {
        /// Minutes after midnight, 0..<1440.
        public var minutes: Int
        public var isDone: Bool

        public init(minutes: Int, isDone: Bool = false) {
            self.minutes = max(0, min(1439, minutes))
            self.isDone = isDone
        }

        /// Parses a whole line (no terminator). nil when the line is not exactly a marker.
        public init?(line: String) {
            let u = Array(line.utf16)
            guard let m = Marker(u[...]) else { return nil }
            self = m
        }

        init?(_ u: ArraySlice<UInt16>) {
            guard u.count == 13 || u.count == 15 else { return nil }
            let a = Array(u)
            func digit(_ i: Int) -> Int? { a[i] >= 48 && a[i] <= 57 ? Int(a[i]) - 48 : nil }
            let dash: UInt16 = 45, space: UInt16 = 32, colon: UInt16 = 58, x: UInt16 = 120
            guard a[0] == dash, a[1] == dash, a[2] == dash, a[3] == space, a[6] == colon,
                  let h1 = digit(4), let h2 = digit(5), let m1 = digit(7), let m2 = digit(8) else { return nil }
            var i = 9
            var done = false
            if a.count == 15 {
                guard a[9] == space, a[10] == x else { return nil }
                done = true
                i = 11
            }
            guard a[i] == space, a[i + 1] == dash, a[i + 2] == dash, a[i + 3] == dash else { return nil }
            let h = h1 * 10 + h2, m = m1 * 10 + m2
            guard h < 24, m < 60 else { return nil }
            minutes = h * 60 + m
            isDone = done
        }

        public var line: String {
            String(format: "--- %02d:%02d%@ ---", minutes / 60, minutes % 60, isDone ? " x" : "")
        }
    }

    /// A marker line in a body (UTF-16 ranges).
    public struct Found: Equatable, Sendable {
        public var marker: Marker
        /// The line without its terminator.
        public var range: NSRange
        /// The line with its terminator.
        public var fullRange: NSRange
    }

    public struct Entry: Equatable, Sendable {
        /// nil: the text before the first marker.
        public var marker: Marker?
        /// The marker line with its terminator (empty for the text before the first marker).
        public var markerRange: NSRange
        /// The text of the entry, up to the next marker.
        public var contentRange: NSRange
        /// Marker and text.
        public var fullRange: NSRange { NSUnionRange(markerRange, contentRange) }
    }

    // MARK: Reading

    public static func markers(in body: String) -> [Found] {
        let s = body as NSString
        // "--- " is in every marker: most bodies leave here.
        guard s.range(of: "--- ").location != NSNotFound else { return [] }
        var out: [Found] = []
        var pos = 0
        var fence: (char: unichar, count: Int)?
        while pos < s.length {
            var start = 0, end = 0, contentsEnd = 0
            s.getParagraphStart(&start, end: &end, contentsEnd: &contentsEnd, for: NSRange(location: pos, length: 0))
            let range = NSRange(location: start, length: contentsEnd - start)
            if let f = fenceRun(s, range) {
                if let open = fence {
                    if f.char == open.char, f.count >= open.count, f.restIsBlank { fence = nil }
                } else {
                    fence = (f.char, f.count)
                }
            } else if fence == nil, range.length == 13 || range.length == 15 {
                var buf = [unichar](repeating: 0, count: range.length)
                s.getCharacters(&buf, range: range)
                if let m = Marker(buf[...]) {
                    out.append(Found(marker: m, range: range, fullRange: NSRange(location: start, length: end - start)))
                }
            }
            pos = max(end, pos + 1)
        }
        return out
    }

    /// Up to three spaces, then three or more backticks or tildes.
    private static func fenceRun(_ s: NSString, _ range: NSRange) -> (char: unichar, count: Int, restIsBlank: Bool)? {
        var i = range.location
        let end = range.location + range.length
        var spaces = 0
        while i < end, s.character(at: i) == 32, spaces < 4 { i += 1; spaces += 1 }
        guard spaces <= 3, i < end else { return nil }
        let c = s.character(at: i)
        guard c == 96 || c == 126 else { return nil }
        var n = 0
        while i < end, s.character(at: i) == c { i += 1; n += 1 }
        guard n >= 3 else { return nil }
        var blank = true
        while i < end {
            let ch = s.character(at: i)
            if ch != 32 && ch != 9 { blank = false }
            i += 1
        }
        return (c, n, blank)
    }

    /// The entries in order. Text before the first marker is the first entry (left out when blank).
    public static func entries(in body: String) -> [Entry] {
        let s = body as NSString
        let found = markers(in: body)
        var out: [Entry] = []
        let firstStart = found.first?.fullRange.location ?? s.length
        let lead = NSRange(location: 0, length: firstStart)
        if !isBlank(s.substring(with: lead)) {
            out.append(Entry(marker: nil, markerRange: NSRange(location: 0, length: 0), contentRange: lead))
        }
        for (i, f) in found.enumerated() {
            let start = f.fullRange.location + f.fullRange.length
            let end = i + 1 < found.count ? found[i + 1].fullRange.location : s.length
            out.append(Entry(marker: f.marker, markerRange: f.fullRange, contentRange: NSRange(location: start, length: end - start)))
        }
        return out
    }

    /// No text besides markers and white space.
    public static func isBlank(_ body: String) -> Bool {
        let s = body as NSString
        var pos = 0
        for f in markers(in: body) {
            if !s.substring(with: NSRange(location: pos, length: f.fullRange.location - pos))
                .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return false }
            pos = f.fullRange.location + f.fullRange.length
        }
        return s.substring(from: pos).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// The text of entry `index` without the blank lines around it.
    public static func text(ofEntry index: Int, in body: String) -> String? {
        let all = entries(in: body)
        guard all.indices.contains(index) else { return nil }
        return trimmedLines((body as NSString).substring(with: all[index].contentRange))
    }

    // MARK: Times

    public static func minutes(of date: Date, calendar: Calendar = .current) -> Int {
        let c = calendar.dateComponents([.hour, .minute], from: date)
        return (c.hour ?? 0) * 60 + (c.minute ?? 0)
    }

    /// "2:32 PM" / "14:32", as the user's region writes times.
    public static func timeText(minutes: Int, locale: Locale = .current) -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 0) ?? .current
        let date = cal.date(from: DateComponents(year: 2001, month: 1, day: 1, hour: minutes / 60, minute: minutes % 60)) ?? Date()
        let f = DateFormatter()
        f.locale = locale
        f.timeZone = cal.timeZone
        f.dateStyle = .none
        f.timeStyle = .short
        return f.string(from: date)
    }

    /// Which markers show their time: the first one, then each one `labelGapMinutes` or more after the
    /// last shown time. A time earlier than the one before it is after midnight (a day runs to the
    /// rollover hour).
    public static func showsTime(_ markers: [Marker]) -> [Bool] {
        var out: [Bool] = []
        var last: Int?
        var previous = 0
        var dayOffset = 0
        for m in markers {
            if m.minutes < previous { dayOffset += 1440 }
            previous = m.minutes
            let t = m.minutes + dayOffset
            if let l = last, t - l < labelGapMinutes {
                out.append(false)
            } else {
                out.append(true)
                last = t
            }
        }
        return out
    }

    // MARK: Editing

    /// `body` without the empty entries at its end (a marker with no text after it).
    public static func pruningEmptyTail(_ body: String) -> String {
        var text = body
        while let last = entries(in: text).last, last.marker != nil,
              isBlank((text as NSString).substring(with: last.contentRange)) {
            text = (text as NSString).substring(to: last.markerRange.location)
        }
        return text
    }

    /// `body` with a new, empty entry at its end, ready to type in. An empty entry that is there
    /// already is replaced (it gets the new time).
    public static func beginningEntry(in body: String, minutes: Int) -> String {
        var text = pruningEmptyTail(body)
        if !text.isEmpty, !(text.hasSuffix("\n") || text.hasSuffix("\r")) { text += "\n" }
        return text + Marker(minutes: minutes).line + "\n"
    }

    /// `body` without entry `index` (marker and text).
    public static func removingEntry(_ index: Int, from body: String) -> String {
        let all = entries(in: body)
        guard all.indices.contains(index) else { return body }
        return (body as NSString).replacingCharacters(in: all[index].fullRange, with: "")
    }

    /// `body` with entry `index` marked done / not done. An entry without a marker cannot be marked.
    public static func settingDone(_ done: Bool, entry index: Int, in body: String) -> String {
        let all = entries(in: body)
        guard all.indices.contains(index), var m = all[index].marker, m.isDone != done else { return body }
        m.isDone = done
        let s = body as NSString
        let full = all[index].markerRange
        let terminator = s.substring(with: full).dropFirst(m.isDone ? 13 : 15)
        return s.replacingCharacters(in: full, with: m.line + terminator)
    }

    // MARK: Leaving Scratch

    /// The body for a normal note, which has no entries: each marker becomes a rule (`---`), and a
    /// marker that shows its time also a line with the time in italics. `leadingTime` false leaves out
    /// the time of a marker at the very start (so the first line of text stays the title).
    public static func exported(_ body: String, leadingTime: Bool = true, locale: Locale = .current) -> String {
        let found = markers(in: body)
        guard !found.isEmpty else { return body }
        let s = body as NSString
        let shows = showsTime(found.map(\.marker))
        var out = ""
        var pos = 0
        for (i, f) in found.enumerated() {
            out += s.substring(with: NSRange(location: pos, length: f.fullRange.location - pos))
            pos = f.fullRange.location + f.fullRange.length
            let terminator = s.substring(with: NSRange(location: f.range.location + f.range.length,
                                                       length: f.fullRange.length - f.range.length))
            let isLeading = isBlank(out)
            var lines: [String] = []
            if !isLeading { lines.append("---") }
            if shows[i], !isLeading || leadingTime { lines.append("*\(timeText(minutes: f.marker.minutes, locale: locale))*") }
            if lines.isEmpty { continue }
            let nl = terminator.isEmpty ? "\n" : terminator
            out += lines.joined(separator: nl) + terminator
        }
        out += s.substring(from: pos)
        return out
    }

    private static func trimmedLines(_ text: String) -> String {
        var lines = text.components(separatedBy: "\n")
        while let f = lines.first, f.trimmingCharacters(in: .whitespaces).isEmpty { lines.removeFirst() }
        while let l = lines.last, l.trimmingCharacters(in: .whitespaces).isEmpty { lines.removeLast() }
        return lines.joined(separator: "\n")
    }
}
