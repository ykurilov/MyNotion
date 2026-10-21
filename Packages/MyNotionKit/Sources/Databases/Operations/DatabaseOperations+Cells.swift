import Foundation
import NotesCore

/// Строка, в которую пишется значение: уже есть или добавляется этой же правкой (вставка за последнюю строку).
public enum CellRowTarget: Sendable, Hashable {
    case existing(UUID)
    /// Номер новой строки среди добавленных, с нуля.
    case appended(Int)
}

/// Одно значение правки блока ячеек. У «Названия» значение — текст (`.string`), пишется в `Page.title`.
public struct CellWrite: Sendable, Hashable {
    public var row: CellRowTarget
    public var propertyId: UUID
    public var value: JSONValue?

    public init(row: CellRowTarget, propertyId: UUID, value: JSONValue?) {
        self.row = row
        self.propertyId = propertyId
        self.value = value
    }
}

/// Правка ячеек (US1, contracts/database-ui.md, «Ячейки и клавиши»): название строки, вставка блока из буфера, ⌫ по
/// выбранным ячейкам — одним шагом отмены вместе с добавленными строками (research R11).
extension DatabaseOperations {
    /// Название строки (правка ячейки «Название» и заголовка страницы строки).
    public func setTitle(of rowId: UUID, to title: String) throws {
        try perform("Правка названия") { transaction in
            guard var page = try transaction.page(rowId) else { throw NotesStoreError.pageNotFound(rowId) }
            let previous = page.title
            page.title = Self.singleLine(title)
            try transaction.updatePage(page)
            return ((), { try $0.setTitle(of: rowId, to: previous) })
        }
    }

    /// Записать блок значений; `appendingRows` новых строк встают в конец вида. Ячейки, которые не правятся (ID,
    /// создано, изменено, формула, сводка, связь), пропускаются. Возвращает добавленные строки.
    @discardableResult
    public func writeCells(_ writes: [CellWrite], appendingRows count: Int, to databaseId: UUID, in viewId: UUID?) throws -> [UUID] {
        try perform("Правка значений") { transaction in
            var appended: [UUID] = []
            for _ in 0..<count {
                appended.append(try Self.writeRow(in: databaseId, viewId: viewId, placement: .bottom, title: "", transaction))
            }
            var batch = CellBatch()
            for write in writes {
                let rowId: UUID
                switch write.row {
                case .existing(let id): rowId = id
                case .appended(let index):
                    guard appended.indices.contains(index) else { continue }
                    rowId = appended[index]
                }
                batch.add(rowId: rowId, propertyId: write.propertyId, value: write.value)
            }
            let previous = try batch.write(in: transaction)
            var undo = previous
            undo.trashing = appended
            return (appended, { try $0.applyCellBatch(undo) })
        }
    }

    /// Записать снимок значений, названий и корзины строк; шаг повтора — то, что было перед записью.
    func applyCellBatch(_ batch: CellBatch) throws {
        try perform("Правка значений") { transaction in
            let previous = try batch.write(in: transaction)
            return ((), { try $0.applyCellBatch(previous) })
        }
    }

    nonisolated static func singleLine(_ text: String) -> String {
        text.replacingOccurrences(of: "\r\n", with: " ").replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: " ")
    }
}

/// Значения ячеек, названия строк и строки в корзину или из неё — одной записью.
struct CellBatch: Sendable {
    struct Key: Hashable, Sendable {
        let rowId: UUID
        let propertyId: UUID
    }

    var cells: [Key: JSONValue?] = [:]
    var titles: [UUID: String] = [:]
    var trashing: [UUID] = []
    var restoring: [UUID] = []
    private var order: [Key] = []

    /// Правка по свойству: «Название» — в название, остальное — в ячейку (если тип её хранит).
    mutating func add(rowId: UUID, propertyId: UUID, value: JSONValue?) {
        let key = Key(rowId: rowId, propertyId: propertyId)
        if cells[key] == nil { order.append(key) }
        cells[key] = value
    }

    /// Записать и вернуть обратный снимок: прежние значения, прежние названия, корзина наоборот.
    func write(in transaction: NotesTransaction) throws -> CellBatch {
        var previous = CellBatch()
        previous.trashing = restoring
        previous.restoring = trashing
        let now = Date()
        for rowId in restoring + trashing {
            guard var page = try transaction.page(rowId) else { continue }
            page.trashedAt = trashing.contains(rowId) ? now : nil
            try transaction.updatePage(page)
        }
        var properties: [UUID: DatabaseProperty?] = [:]
        for (rowId, title) in titles {
            guard var page = try transaction.page(rowId) else { continue }
            previous.titles[rowId] = page.title
            page.title = title
            try transaction.updatePage(page)
        }
        for key in order {
            guard let value = cells[key] else { continue }
            if properties[key.propertyId] == nil { properties[key.propertyId] = .some(try transaction.property(key.propertyId)) }
            guard let property = properties[key.propertyId] ?? nil else { continue }
            if property.kind == .title {
                guard var page = try transaction.page(key.rowId) else { continue }
                if previous.titles[key.rowId] == nil { previous.titles[key.rowId] = page.title }
                page.title = DatabaseOperations.singleLine(value?.string ?? "")
                try transaction.updatePage(page)
            } else if property.kind.storesCells, PropertyTypes.type(for: property.kind).isEditable {
                previous.add(rowId: key.rowId, propertyId: key.propertyId, value: try transaction.cell(rowId: key.rowId, propertyId: key.propertyId)?.value)
                try transaction.setCell(rowId: key.rowId, propertyId: key.propertyId, value: value)
            }
        }
        return previous
    }
}
