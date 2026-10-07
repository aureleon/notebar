import Foundation
import GRDB
import NoteBarCore

// MARK: - Custom themes

extension GRDBNoteStore {
    public func customThemes() -> [Theme] {
        themeMap.values.sorted {
            let c = $0.name.localizedStandardCompare($1.name)
            return c == .orderedSame ? $0.id < $1.id : c == .orderedAscending
        }
    }

    public func saveTheme(_ theme: Theme) {
        guard (try? JSONEncoder().encode(theme)) != nil else { return }
        themeMap[theme.id] = theme
        pendingThemeDeletes.remove(theme.id)
        pendingThemeIDs.insert(theme.id)
        flush()
    }

    public func deleteTheme(id: String) {
        guard themeMap[id] != nil else { return }
        themeMap[id] = nil
        pendingThemeIDs.remove(id)
        pendingThemeDeletes.insert(id)
        flush()
    }
}
