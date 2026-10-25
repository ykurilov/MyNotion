import Databases
import Foundation
import NotesCore

/// База текстом таблицы — для страницы по ссылке: колонки первого вида (без скрытых), строки по порядку,
/// значения как в выгрузке CSV. Связь показывает только те строки, которые разрешает `relationTitle`.
public struct DatabaseTableText: Sendable, Hashable {
    public struct Row: Sendable, Hashable {
        public let page: Page
        public let cells: [String]
    }

    public let columns: [String]
    public let rows: [Row]

    /// `nil` — страница не база.
    public static func read(_ databaseId: UUID, from store: NotesStore,
                            relationTitle: (_ targetRowId: UUID, _ title: String) -> String?) throws -> DatabaseTableText? {
        guard let snapshot = try DatabaseExportSnapshot.read(databaseId, from: store) else { return nil }
        let values = DatabaseValueText(snapshot: snapshot)
        let hidden = Set((snapshot.views.first?.columns.array ?? []).compactMap { entry -> UUID? in
            guard entry["isVisible"]?.bool == false else { return nil }
            return entry["propertyId"]?.string.flatMap(UUID.init(uuidString:))
        })
        let shown = values.columns.indices.filter { values.columns[$0].kind == .title || !hidden.contains(values.columns[$0].id) }
        let rows = snapshot.rows.map { row in
            Row(page: row, cells: shown.map { index in
                guard values.columns[index].kind == .relation else { return values.text(at: index, of: row) { _ in "" } }
                let targets = snapshot.relations[row.id]?[values.columns[index].id] ?? []
                return targets.compactMap { relationTitle($0, values.title(ofTarget: $0)) }.joined(separator: ", ")
            })
        }
        return DatabaseTableText(columns: shown.map { values.columns[$0].name }, rows: rows)
    }
}
