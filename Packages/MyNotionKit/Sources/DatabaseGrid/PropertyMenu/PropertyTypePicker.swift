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

extension PropertyTypePicker {
    /// Стрелка в списке типов.
    public enum Direction: Sendable {
        case up, down, left, right
    }

    /// Куда встаёт подсветка от типа `kind` по стрелке: ↑↓ — ближайшая строка с доступным типом, та же колонка (нет её
    /// или серая — соседняя); ←→ — соседняя колонка строки. Края не прокручиваются; без подсветки — первый доступный тип.
    public static func move(from kind: PropertyKind?, _ direction: Direction, in rows: [[Entry]]) -> PropertyKind? {
        let firstEnabled = rows.lazy.flatMap { $0 }.first { $0.isEnabled }?.kind
        guard let kind, let row = rows.firstIndex(where: { $0.contains { $0.kind == kind } }),
              let column = rows[row].firstIndex(where: { $0.kind == kind }) else { return firstEnabled }
        switch direction {
        case .left, .right:
            let step = direction == .right ? 1 : -1
            var next = column + step
            while rows[row].indices.contains(next) {
                if rows[row][next].isEnabled { return rows[row][next].kind }
                next += step
            }
            return kind
        case .up, .down:
            let candidates = direction == .down ? Array(rows.indices.dropFirst(row + 1)) : Array(rows.indices.prefix(row).reversed())
            for index in candidates {
                let entries = rows[index]
                let preferred = min(column, entries.count - 1)
                if entries.indices.contains(preferred), entries[preferred].isEnabled { return entries[preferred].kind }
                if let other = entries.first(where: \.isEnabled) { return other.kind }
            }
            return kind
        }
    }
}
