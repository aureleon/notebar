import Foundation

// MARK: - Ex commands

/// Result of parsing a `:` command line.
public enum VimExCommand: Equatable, Sendable {
    case card(VimCardCommand)
    /// `:w`.
    case write
    /// `:{n}`: 1-based line.
    case goToLine(Int)
    /// `:noh`.
    case noHighlight
    case error(String)
    /// Empty command line.
    case none
}

public enum VimEx {
    static let colorAliases: [String: NoteColor] = ["default": .none, "none": .none, "clear": .none, "no": .none]
    static let modeAliases: [String: NoteMode] = ["standard": .standard, "markdown": .standard, "md": .standard,
                                                  "code": .code, "plain": .plain, "text": .plain]

    public static func parse(_ line: String) -> VimExCommand {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return .none }
        if let n = Int(trimmed) { return .goToLine(max(1, n)) }
        let parts = trimmed.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        let name = parts[0].lowercased()
        let arg = parts.count > 1 ? String(parts[1]).trimmingCharacters(in: .whitespaces) : ""
        switch name {
        case "w", "w!", "write": return .write
        case "q", "q!", "quit", "wq", "wq!", "x", "x!", "xit", "exit": return .card(.quit)
        case "pin", "p", "unpin": return .card(.togglePin)
        case "fold", "fo": return .card(.setFolded(true))
        case "unfold", "foldopen": return .card(.setFolded(false))
        case "copy", "y", "yank", "co": return .card(.copyNote)
        case "delete", "d", "del": return .card(.delete)
        case "noh", "nohl", "nohlsearch": return .noHighlight
        case "archive", "arch": return .card(.setArchived(true))
        case "unarchive", "unarch": return .card(.setArchived(false))
        case "format", "fmt": return .card(.showFormatMenu)
        case "color", "colour", "col":
            guard !arg.isEmpty else { return .card(.showColorMenu) }
            guard let c = color(named: arg) else { return .error("Unknown color “\(arg)”") }
            return .card(.setColor(c))
        case "mode":
            guard !arg.isEmpty else { return .card(.showColorMenu) }
            guard let m = mode(named: arg) else { return .error("Unknown mode “\(arg)” (standard, code, plain)") }
            return .card(.setMode(m))
        case "move", "m", "mv":
            return arg.isEmpty ? .card(.showMoveMenu) : .card(.moveToFolder(arg))
        case "folder", "f", "b", "buffer":
            return arg.isEmpty ? .error("Usage: :folder name") : .card(.openFolder(arg))
        case "tabn", "tabnext", "bn", "bnext": return .card(.stepFolder(1))
        case "tabp", "tabprevious", "bp", "bprevious": return .card(.stepFolder(-1))
        case "scratch", "sc": return .card(.openScratch)
        case "newfolder", "nf", "mkdir": return .card(.newFolder(arg))
        case "rename", "ren": return .card(.renameFolder(arg))
        case "pinfolder", "pf": return .card(.toggleFolderPin)
        case "archivefolder", "af": return .card(.archiveFolder)
        case "deletefolder", "df", "rmdir": return .card(.deleteFolder)
        default:
            return .error("Not a command: \(trimmed)")
        }
    }

    /// Tab completion of a `:` line. `:move` / `:m` / `:mv` and `:folder` / `:f` / `:b` complete a folder name from `folders`:
    /// names that start with the typed text first, then names that contain it (any case), each in
    /// list order. Returns the text before the name (`head`, ends with a space) and the matches; nil
    /// when the line is not a command that completes.
    public static func completions(_ line: String, folders: [String]) -> (head: String, matches: [String])? {
        let lead = line.prefix { $0 == " " }
        let rest = line.dropFirst(lead.count)
        let cmd = rest.prefix { $0 != " " }
        guard ["move", "m", "mv", "folder", "f", "b", "buffer"].contains(cmd.lowercased()) else { return nil }
        let arg = rest.dropFirst(cmd.count).drop { $0 == " " }
        let typed = arg.lowercased()
        let head = String(lead) + String(cmd) + " "
        let starts = folders.filter { $0.lowercased().hasPrefix(typed) }
        let contains = folders.filter { !$0.lowercased().hasPrefix(typed) && $0.lowercased().contains(typed) }
        return (head, typed.isEmpty ? folders : starts + contains)
    }

    /// Exact name or alias first, then a unique prefix ("pur" = purple).
    static func color(named raw: String) -> NoteColor? {
        let k = raw.lowercased()
        if let c = colorAliases[k] ?? NoteColor(rawValue: k) { return c }
        let hits = NoteColor.allCases.filter { $0 != .none && $0.rawValue.hasPrefix(k) }
        return hits.count == 1 ? hits[0] : nil
    }

    static func mode(named raw: String) -> NoteMode? {
        let k = raw.lowercased()
        if let m = modeAliases[k] { return m }
        let hits = Set(modeAliases.filter { $0.key.hasPrefix(k) }.map(\.value))
        return hits.count == 1 ? hits.first : nil
    }
}
