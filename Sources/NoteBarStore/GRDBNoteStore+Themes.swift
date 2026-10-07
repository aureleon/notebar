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
        guard let data = try? JSONEncoder().encode(theme) else { return }
        write("save theme") { db in
            try db.execute(sql: """
                INSERT INTO theme (id, name, json, updatedAt) VALUES (?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET name = excluded.name, json = excluded.json, updatedAt = excluded.updatedAt
                """, arguments: [theme.id, theme.name, data, Date().timeIntervalSince1970])
        }
        themeMap[theme.id] = theme
    }

    public func deleteTheme(id: String) {
        guard themeMap[id] != nil else { return }
        write("delete theme") { db in try db.execute(sql: "DELETE FROM theme WHERE id = ?", arguments: [id]) }
        themeMap[id] = nil
    }
}
