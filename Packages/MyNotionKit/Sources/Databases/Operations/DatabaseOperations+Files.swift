import Foundation
import NotesCore

/// Правка ячейки «Файлы и медиа» (US2, сценарий 5): файлы и ссылки встают в конец, убираются по одному. Копирует файл
/// в папку копий окно (модуль вложений); здесь — только значение ячейки. Каждая правка — один шаг ⌘Z.
extension DatabaseOperations {
    public func addFiles(_ items: [FilesValue.Item], rowId: UUID, propertyId: UUID) throws {
        guard !items.isEmpty else { return }
        try editFiles(rowId: rowId, propertyId: propertyId, actionName: "Добавление файла") { $0 += items }
    }

    public func removeFile(at index: Int, rowId: UUID, propertyId: UUID) throws {
        try editFiles(rowId: rowId, propertyId: propertyId, actionName: "Удаление файла") { items in
            if items.indices.contains(index) { items.remove(at: index) }
        }
    }

    private func editFiles(rowId: UUID, propertyId: UUID, actionName: String, _ edit: (inout [FilesValue.Item]) -> Void) throws {
        try performChange(actionName) { transaction in
            let previous = try transaction.cell(rowId: rowId, propertyId: propertyId)?.value
            var items = FilesValue.items(previous)
            edit(&items)
            let next = FilesValue.json(items)
            guard next != previous else { return nil }
            try transaction.setCell(rowId: rowId, propertyId: propertyId, value: next)
            return { try $0.setCell(rowId: rowId, propertyId: propertyId, value: previous) }
        }
    }
}
