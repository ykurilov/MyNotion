import Foundation
import NotesCore

/// Список типов «+» и «Сменить тип» (contracts/property-types.md, «Список типов»): строки по две колонки в порядке
/// Notion 7.39, разделители — пустые строки; «Название» в списке нет; ID — серый, если в базе уже есть.
public enum PropertyTypePicker {
    public struct Entry: Sendable, Hashable {
        public let kind: PropertyKind
        public let title: String
        public let symbol: String
        public let isEnabled: Bool
    }

    static let layout: [[PropertyKind]] = [
        [.text, .number], [.select, .multiSelect], [.status, .date], [.files, .checkbox], [.url, .phone], [.email],
        [], [.relation, .rollup], [.formula, .uniqueId], [], [.createdTime, .lastEditedTime],
    ]

    /// Строки списка; `matching` — поиск по названию типа (тогда без разделителей и пустых строк).
    public static func rows(existingKinds: Set<PropertyKind>, matching query: String = "") -> [[Entry]] {
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        let rows = layout.map { row in
            row.map { kind -> Entry in
                let cell = CellKind.for(kind)
                return Entry(kind: kind, title: cell.title, symbol: cell.symbol,
                             isEnabled: !(kind == .uniqueId && existingKinds.contains(.uniqueId)))
            }.filter { needle.isEmpty || $0.title.lowercased().contains(needle) }
        }
        return needle.isEmpty ? rows : rows.filter { !$0.isEmpty }
    }
}
