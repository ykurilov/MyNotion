import Foundation

/// Таблица, как её показывают (data-model.md, «Правила»; research R3): столбцы и строки по порядку ключей,
/// ячейка — на пересечении строки и столбца. Отсутствующая ячейка пустая и создаётся при первом вводе;
/// ячейка удалённого столбца не показывается. Правки — обычные блоки (`BlockChanges`), которые применяет документ.
public struct TableGrid: Sendable, Hashable {
    public let table: Block
    public let columns: [Block]
    public let rows: [Block]
    /// Ячейки по строке и столбцу.
    private let cells: [UUID: [UUID: Block]]

    /// `flow` — блоки контейнера по порядку (`PageDocument.flow`).
    public init(table: Block, flow: (UUID) -> [Block]) {
        self.table = table
        let members = flow(table.id)
        columns = members.filter { $0.kind == .tableColumn }
        rows = members.filter { $0.kind == .tableRow }
        let columnIds = Set(columns.map(\.id))
        var cells: [UUID: [UUID: Block]] = [:]
        for row in rows {
            var byColumn: [UUID: Block] = [:]
            for cell in flow(row.id) where cell.kind == .tableCell {
                // Две ячейки одного столбца (правки двух Mac) — показывается первая по порядку.
                guard let columnId = cell.props.columnId, columnIds.contains(columnId), byColumn[columnId] == nil else { continue }
                byColumn[columnId] = cell
            }
            cells[row.id] = byColumn
        }
        self.cells = cells
    }

    public var columnCount: Int { columns.count }
    public var rowCount: Int { rows.count }
    public var hasHeaderRow: Bool { table.props.hasHeaderRow ?? false }
    public var hasHeaderColumn: Bool { table.props.hasHeaderColumn ?? false }

    /// Ширина столбца в точках.
    public func width(ofColumn column: Int) -> Double {
        columns[column].props.width ?? Self.defaultColumnWidth
    }

    public static let defaultColumnWidth: Double = 120
    /// Ширина, уже которой столбец не протянуть.
    public static let minimumColumnWidth: Double = 32

    public func cell(row: Int, column: Int) -> Block? {
        guard rows.indices.contains(row), columns.indices.contains(column) else { return nil }
        return cells[rows[row].id]?[columns[column].id]
    }

    public func text(row: Int, column: Int) -> InlineText {
        cell(row: row, column: column)?.text ?? .empty
    }

    /// Строка и столбец ячейки по её id.
    public func position(ofCell cellId: UUID) -> (row: Int, column: Int)? {
        for (rowIndex, row) in rows.enumerated() {
            for (columnIndex, column) in columns.enumerated() where cells[row.id]?[column.id]?.id == cellId {
                return (rowIndex, columnIndex)
            }
        }
        return nil
    }

    // MARK: Новая таблица

    /// Первый столбец таблицы из «/» (Notion 7.39: 240).
    public static let newTableFirstColumnWidth: Double = 240

    /// Ширины двух столбцов таблицы из «/» во всю ширину `available`, как у Notion 7.39: первый 240, второй — остаток;
    /// узко — пополам; не уже `minimumColumnWidth`.
    public static func columnWidths(ofNewTableFitting available: Double) -> [Double] {
        let first = max(minimumColumnWidth, min(newTableFirstColumnWidth, (available / 2).rounded(.down)))
        return [first, max(minimumColumnWidth, available - first)]
    }

    /// Столбцы и строки новой таблицы, без ячеек; `widths` — ширины столбцов по порядку.
    public static func contents(ofNewTable table: Block, columns: Int, rows: Int, widths: [Double] = []) -> [Block] {
        var key: FractionalSortKey?
        func nextKey() -> FractionalSortKey {
            key = .between(key, nil)
            return key!
        }
        let columnBlocks = (0..<columns).map { index in
            var props = BlockProps.defaults(for: .tableColumn)
            if index < widths.count { props.width = widths[index] }
            return Block(pageId: table.pageId, kind: .tableColumn, sortKey: nextKey(), containerId: table.id, props: props)
        }
        let rowBlocks = (0..<rows).map { _ in Block(pageId: table.pageId, kind: .tableRow, sortKey: nextKey(), containerId: table.id) }
        return columnBlocks + rowBlocks
    }

    /// Таблица из текста: ячейки по строкам (выгрузка, импорт, вставка). Столбцов — по самой длинной строке.
    public static func contents(ofTable table: Block, cells texts: [[InlineText]], widths: [Double?] = []) -> [Block] {
        let columnCount = max(1, texts.map(\.count).max() ?? 1)
        let structure = contents(ofNewTable: table, columns: columnCount, rows: max(1, texts.count))
        var columns = structure.filter { $0.kind == .tableColumn }
        for index in columns.indices where index < widths.count {
            if let width = widths[index] { columns[index].props.width = width }
        }
        let rows = structure.filter { $0.kind == .tableRow }
        var cells: [Block] = []
        for (rowIndex, rowTexts) in texts.enumerated() {
            var key: FractionalSortKey?
            for (columnIndex, text) in rowTexts.enumerated() where !text.string.isEmpty {
                key = .between(key, nil)
                var props = BlockProps()
                props.columnId = columns[columnIndex].id
                cells.append(Block(pageId: table.pageId, kind: .tableCell, text: text, sortKey: key!, containerId: rows[rowIndex].id, props: props))
            }
        }
        return columns + rows + cells
    }

    // MARK: Правки

    /// Текст ячейки; отсутствующая создаётся — с id `newCellId`, если он дан (поле правки уже показывает её этим id).
    public func settingText(_ text: InlineText, row: Int, column: Int, newCellId: UUID? = nil) -> BlockChanges {
        let text = text.normalized()
        if var cell = cell(row: row, column: column) {
            guard cell.text != text else { return BlockChanges() }
            cell.text = text
            return BlockChanges(upserts: [cell])
        }
        guard rows.indices.contains(row), columns.indices.contains(column), !text.string.isEmpty else { return BlockChanges() }
        let rowId = rows[row].id
        // Ячейки строки идут по порядку столбцов: новая встаёт после ячеек левее.
        let existing = (0..<columnCount).compactMap { self.cell(row: row, column: $0) }
        let before = (0..<column).compactMap { self.cell(row: row, column: $0) }.last?.sortKey
        let after = existing.map(\.sortKey).filter { key in before.map { key > $0 } ?? true }.min()
        var props = BlockProps()
        props.columnId = columns[column].id
        let cell = Block(id: newCellId ?? .timeOrdered(), pageId: table.pageId, kind: .tableCell, text: text, sortKey: .between(before, after),
                         containerId: rowId, props: props)
        return BlockChanges(upserts: [cell])
    }

    /// Пустая строка на месте `index` (0…rowCount).
    public func insertingRow(at index: Int) -> BlockChanges {
        let key = Self.key(at: index, in: rows, all: rows + columns)
        return BlockChanges(upserts: [Block(pageId: table.pageId, kind: .tableRow, sortKey: key, containerId: table.id)])
    }

    /// Пустой столбец на месте `index` (0…columnCount): ширина как у соседа слева или по умолчанию.
    public func insertingColumn(at index: Int) -> BlockChanges {
        let key = Self.key(at: index, in: columns, all: rows + columns)
        var column = Block(pageId: table.pageId, kind: .tableColumn, sortKey: key, containerId: table.id, props: .defaults(for: .tableColumn))
        if index > 0, let width = columns[safe: index - 1]?.props.width { column.props.width = width }
        return BlockChanges(upserts: [column])
    }

    /// Строка с её ячейками; последняя строка — вся таблица.
    public func removingRow(at index: Int) -> BlockChanges {
        guard rows.indices.contains(index) else { return BlockChanges() }
        guard rowCount > 1 else { return BlockChanges(removals: [table.id]) }
        return BlockChanges(removals: [rows[index].id])
    }

    /// Столбец с его ячейками; последний столбец — вся таблица.
    public func removingColumn(at index: Int) -> BlockChanges {
        guard columns.indices.contains(index) else { return BlockChanges() }
        guard columnCount > 1 else { return BlockChanges(removals: [table.id]) }
        let columnId = columns[index].id
        let cellIds = rows.compactMap { cells[$0.id]?[columnId]?.id }
        return BlockChanges(removals: [columnId] + cellIds)
    }

    /// Текст из буфера (строки ячеек) — в ячейки начиная с `row`, `column`; таблица растёт под него строками и столбцами.
    public func pasting(_ texts: [[InlineText]], at row: Int, column: Int) -> BlockChanges {
        guard !texts.isEmpty else { return BlockChanges() }
        var upserts: [Block] = []
        var columnIds = columns.map(\.id)
        var rowIds = rows.map(\.id)
        var lastKey = (rows + columns).map(\.sortKey).max()
        let neededColumns = column + (texts.map(\.count).max() ?? 0)
        while columnIds.count < neededColumns {
            lastKey = .between(lastKey, nil)
            var newColumn = Block(pageId: table.pageId, kind: .tableColumn, sortKey: lastKey!, containerId: table.id,
                                  props: .defaults(for: .tableColumn))
            if let width = columns.last?.props.width { newColumn.props.width = width }
            upserts.append(newColumn)
            columnIds.append(newColumn.id)
        }
        while rowIds.count < row + texts.count {
            lastKey = .between(lastKey, nil)
            let newRow = Block(pageId: table.pageId, kind: .tableRow, sortKey: lastKey!, containerId: table.id)
            upserts.append(newRow)
            rowIds.append(newRow.id)
        }
        for (rowOffset, rowTexts) in texts.enumerated() {
            let rowId = rowIds[row + rowOffset]
            let existingKeys = rowId == rows[safe: row + rowOffset]?.id ? (cells[rowId] ?? [:]).values.map(\.sortKey) : []
            var key = existingKeys.max()
            for (columnOffset, text) in rowTexts.enumerated() {
                let columnId = columnIds[column + columnOffset]
                let text = text.normalized()
                if var cell = cells[rowId]?[columnId] {
                    guard cell.text != text else { continue }
                    cell.text = text
                    upserts.append(cell)
                } else if !text.string.isEmpty {
                    key = .between(key, nil)
                    var props = BlockProps()
                    props.columnId = columnId
                    upserts.append(Block(pageId: table.pageId, kind: .tableCell, text: text, sortKey: key!, containerId: rowId, props: props))
                }
            }
        }
        return BlockChanges(upserts: upserts)
    }

    public func settingHeaders(row: Bool, column: Bool) -> BlockChanges {
        guard row != hasHeaderRow || column != hasHeaderColumn else { return BlockChanges() }
        var table = table
        table.props.hasHeaderRow = row
        table.props.hasHeaderColumn = column
        return BlockChanges(upserts: [table])
    }

    public func settingWidth(_ width: Double, ofColumn index: Int) -> BlockChanges {
        guard columns.indices.contains(index) else { return BlockChanges() }
        var column = columns[index]
        let width = max(Self.minimumColumnWidth, width.rounded())
        guard column.props.width != width else { return BlockChanges() }
        column.props.width = width
        return BlockChanges(upserts: [column])
    }

    /// Ключ нового элемента на месте `index` среди `items` (строк или столбцов). В потоке таблицы строки
    /// и столбцы перемешаны ключами — ключ берётся строго между соседями из `items`, не задевая остальных.
    private static func key(at index: Int, in items: [Block], all: [Block]) -> FractionalSortKey {
        let before = index > 0 ? items[safe: index - 1]?.sortKey : nil
        let after = items[safe: index]?.sortKey
        if let before, let after { return .between(before, after) }
        if let after { return .between(nil, after) }
        let last = all.map(\.sortKey).max()
        return .between(before.map { max($0, last ?? $0) } ?? last, nil)
    }
}

extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

@MainActor
extension PageDocument {
    /// Таблица по id блока `table`; `nil` — такой таблицы нет.
    public func tableGrid(_ tableId: UUID) -> TableGrid? {
        guard let table = block(tableId), table.kind == .table else { return nil }
        return TableGrid(table: table, flow: flow)
    }
}
