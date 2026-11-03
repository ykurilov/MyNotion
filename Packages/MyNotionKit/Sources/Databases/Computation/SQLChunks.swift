import Foundation
import GRDB
import NotesCore

/// Запросы `IN (…)` по id строк — пачками по 500: ниже даже старого предела SQLite в 999 параметров, с запасом на
/// другие параметры запроса.
enum SQLChunks {
    static let size = 500

    /// `body` получает метки `?,?,…` и id пачки.
    static func forEach(_ ids: some Collection<UUID>, _ body: (String, StatementArguments) throws -> Void) rethrows {
        let all = Array(ids)
        for start in stride(from: 0, to: all.count, by: size) {
            let chunk = all[start..<min(start + size, all.count)]
            try body(Array(repeating: "?", count: chunk.count).joined(separator: ","), StatementArguments(chunk.map(\.databaseText)))
        }
    }
}
