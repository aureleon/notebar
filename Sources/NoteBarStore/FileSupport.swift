import Foundation

/// File-name helpers for exports and backups.
enum FileNames {
    /// A safe single path component: no `/` `:` or control characters, no leading dots, trimmed,
    /// at most `maxLength` characters. Empty input gives `fallback`.
    static func sanitize(_ raw: String, fallback: String, maxLength: Int = 80) -> String {
        let forbidden = CharacterSet(charactersIn: "/\\:?%*|\"<>").union(.controlCharacters).union(.newlines)
        var s = String(String.UnicodeScalarView(raw.unicodeScalars.map { forbidden.contains($0) ? "-" : $0 }))
        s = s.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        s = s.trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: ".")))
        if s.count > maxLength {
            s = String(s.prefix(maxLength)).trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: ".")))
        }
        // Stay well below the 255-byte file-name limit even with multi-byte characters.
        while s.utf8.count > 200 { s.removeLast() }
        return s.isEmpty ? fallback : s
    }

    /// Returns `base.ext`, or `base 2.ext`, `base 3.ext`… so that the name is not in `taken`
    /// (compared case-insensitively, like APFS). Adds the result to `taken`.
    static func unique(_ base: String, ext: String, taken: inout Set<String>) -> String {
        func make(_ n: Int) -> String {
            let b = n == 1 ? base : "\(base) \(n)"
            return ext.isEmpty ? b : "\(b).\(ext)"
        }
        var n = 1
        while taken.contains(make(n).lowercased()) { n += 1 }
        let name = make(n)
        taken.insert(name.lowercased())
        return name
    }

    /// Lower-cased names already present in `directory`.
    static func existingNames(in directory: URL) -> Set<String> {
        let items = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return Set(items.map { $0.lowercased() })
    }

    /// Percent-encodes a relative path for a Markdown link target.
    static func linkPath(_ path: String) -> String {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~/")
        return path.addingPercentEncoding(withAllowedCharacters: allowed) ?? path
    }
}

/// Runs `/usr/bin/ditto` to create / extract zip archives.
enum Ditto {
    static func zip(contentsOf directory: URL, to archive: URL) throws {
        try run(["-c", "-k", "--sequesterRsrc", directory.path, archive.path])
    }

    static func unzip(_ archive: URL, to directory: URL) throws {
        try run(["-x", "-k", archive.path, directory.path])
    }

    private static func run(_ args: [String]) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        p.arguments = args
        let err = Pipe()
        p.standardError = err
        p.standardOutput = FileHandle.nullDevice
        do { try p.run() } catch {
            throw BackupError.archive("Cannot run ditto: \(error.localizedDescription)")
        }
        let data = err.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            let msg = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            throw BackupError.archive("ditto failed (\(p.terminationStatus)): \(msg)")
        }
    }
}

public enum BackupError: Error, LocalizedError {
    case archive(String)
    case invalidBackup(String)
    case restoreFailed(String)

    public var errorDescription: String? {
        switch self {
        case .archive(let s): "Backup archive error: \(s)"
        case .invalidBackup(let s): "This is not a valid NoteBar backup: \(s)"
        case .restoreFailed(let s): "Restore failed: \(s)"
        }
    }
}
