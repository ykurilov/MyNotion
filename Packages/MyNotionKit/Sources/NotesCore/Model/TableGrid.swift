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
    /// Все ячейки столбца, вместе со вторыми в той же строке, которые не показываются.
    private let cellIdsByColumn: [UUID: [UUID]]

    /// `flow` — блоки контейнера по порядку (`PageDocument.flow`).
    public init(table: Block, flow: (UUID) -> [Block]) {
        self.table = table
        let members = flow(table.id)
        columns = members.filter { $0.kind == .tableColumn }
        rows = members.filter { $0.kind == .tableRow }
        let columnIds = Set(columns.map(\.id))
        var cells: [UUID: [UUID: Block]] = [:]
        var cellIdsByColumn: [UUID: [UUID]] = [:]
        for row in rows {
            var byColumn: [UUID: Block] = [:]
            for cell in flow(row.id) where cell.kind == .tableCell {
                guard let columnId = cell.props.columnId, columnIds.contains(columnId) else { continue }
                cellIdsByColumn[columnId, default: []].append(cell.id)
                // Две ячейки одного столбца (правки двух Mac) — показывается первая по порядку.
                if byColumn[columnId] == nil { byColumn[columnId] = cell }
            }
            cells[row.id] = byColumn
        }
        self.cells = cells
        self.cellIdsByColumn = cellIdsByColumn
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

    /// Порог, до которого столбцы сужаются сами: новая таблица и добавленный столбец. Как у Notion (новый столбец 120),
    /// в 100 ещё помещается пара коротких слов шрифтом таблицы, а 7 столбцов умещаются в стандартную колонку текста.
    /// Дальше таблица шире колонки и прокручивается вбок. Руками протянуть уже можно — до `minimumColumnWidth`.
    public static let narrowestFittedColumnWidth: Double = 100

    /// Ширины `count` столбцов новой таблицы во всю ширину `available`: поровну, остаток округления — последнему;
    /// не уже `narrowestFittedColumnWidth`.
    public static func columnWidths(ofNewTable count: Int, fitting available: Double) -> [Double] {
        guard count > 0 else { return [] }
        let share = (available / Double(count)).rounded(.down)
        guard share > narrowestFittedColumnWidth else {
            let width = max(narrowestFittedColumnWidth, share)
            return Array(repeating: width, count: count - 1) + [max(width, available - width * Double(count - 1))]
        }
        return Array(repeating: share, count: count - 1) + [available - share * Double(count - 1)]
    }

    /// Ширины `widths`, сжатые в `target` пропорционально: столбец не уже `narrowestFittedColumnWidth`, а уже узкий
    /// (протянут руками) не меняется. Не влезает — сумма больше `target`, таблица шире.
    static func shrinking(_ widths: [Double], toFit target: Double) -> [Double] {
        let limit = narrowestFittedColumnWidth
        var result = widths
        var free = Set(widths.indices.filter { widths[$0] > limit })
        var factor = 1.0
        while !free.isEmpty {
            let fixed = widths.indices.filter { !free.contains($0) }.map { result[$0] }.reduce(0, +)
            let freeSum = free.map { widths[$0] }.reduce(0, +)
            factor = min(1, (target - fixed) / freeSum)
            let hitting = free.filter { widths[$0] * factor < limit }
            if hitting.isEmpty { break }
            for index in hitting {
                result[index] = limit
                free.remove(index)
            }
        }
        guard !free.isEmpty, factor < 1 else { return result }
        for index in free { result[index] = (widths[index] * factor).rounded(.down) }
        let leftover = target - result.reduce(0, +)
        if leftover > 0, let widest = free.max(by: { result[$0] < result[$1] }) { result[widest] += leftover }
        return result
    }

    // MARK: Ширина под таблицей без окна

    /// Ширина колонки текста страницы без окна: `Metrics.Page.columnWidth` 720 без полей строки 2 × 2. Так встают
    /// таблицы, созданные командой, агентом, записью Markdown и импортом; в окне — по его колонке текста.
    public static let standardTextWidth: Double = 716
    /// Сдвиг вложенного блока на уровень (`Metrics.Page.indentPerLevel`).
    public static let standardIndentWidth: Double = 32
    /// Просвет между колонками страницы (`Metrics.Columns.gap`).
    public static let standardColumnsGap: Double = 46

    /// Ширина под блоком `table` без окна: колонка текста за вычетом отступа; в колонке страницы — её доля.
    /// `lookup` — блок по id, `columns` — колонки списка колонок по порядку.
    public static func standardWidth(under table: Block, lookup: (UUID) -> Block?, columns: (UUID) -> [Block]) -> Double {
        func available(_ block: Block) -> Double {
            let indent = Double(block.indent) * standardIndentWidth
            guard let containerId = block.containerId, let column = lookup(containerId), column.kind == .column,
                  let listId = column.containerId, let list = lookup(listId) else { return standardTextWidth - indent }
            let siblings = columns(listId)
            let ratios = ColumnLayout.ratios(of: siblings)
            guard let position = siblings.firstIndex(where: { $0.id == column.id }) else { return standardTextWidth - indent }
            let usable = available(list) - standardColumnsGap * Double(max(0, siblings.count - 1))
            return (usable * ratios[position]).rounded(.down) - indent
        }
        return available(table)
    }

    /// Новые таблицы среди `blocks`: у таблицы, ни одному столбцу которой ширина не задана, столбцы поровну делят
    /// ширину под ней `width`. Заданные источником ширины остаются. `table` — таблица по id.
    public static func fittingNewTables(in blocks: [Block], table: (UUID) -> Block?, width: (Block) -> Double) -> [Block] {
        var result = blocks
        let columnsByTable = Dictionary(grouping: blocks.indices.filter { blocks[$0].kind == .tableColumn }) { blocks[$0].containerId }
        for (tableId, indices) in columnsByTable {
            guard let tableId, let tableBlock = table(tableId), tableBlock.kind == .table,
                  indices.allSatisfy({ blocks[$0].props.width == nil }) else { continue }
            let ordered = indices.sorted { blocks[$0].sortKey < blocks[$1].sortKey }
            for (index, columnWidth) in zip(ordered, columnWidths(ofNewTable: ordered.count, fitting: width(tableBlock))) {
                result[index].props.width = columnWidth
            }
        }
        return result
    }

    /// То же без окна, когда таблицы и их колонки страницы — все среди `blocks` (запись Markdown, импорт).
    public static func fittingNewTables(in blocks: [Block]) -> [Block] {
        let byId = Dictionary(blocks.map { ($0.id, $0) }) { first, _ in first }
        let lookup = { (id: UUID) in byId[id] }
        let columns = { (listId: UUID) in
            blocks.filter { $0.containerId == listId && $0.kind == .column }.sorted { $0.sortKey < $1.sortKey }
        }
        return fittingNewTables(in: blocks, table: lookup) { standardWidth(under: $0, lookup: lookup, columns: columns) }
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

    /// Пустой столбец на месте `index` (0…columnCount) в нынешнюю ширину таблицы: его доля — поровну на всех,
    /// остальные сужаются пропорционально до `narrowestFittedColumnWidth`; дальше таблица становится шире.
    public func insertingColumn(at index: Int) -> BlockChanges {
        let key = Self.key(at: index, in: columns, all: rows + columns)
        let widths = columns.indices.map(width(ofColumn:))
        let total = widths.reduce(0, +)
        let newWidth = max(Self.narrowestFittedColumnWidth, (total / Double(columnCount + 1)).rounded(.down))
        var column = Block(pageId: table.pageId, kind: .tableColumn, sortKey: key, containerId: table.id, props: .defaults(for: .tableColumn))
        column.props.width = columns.isEmpty ? Self.defaultColumnWidth : newWidth
        var upserts = [column]
        for (position, shrunk) in Self.shrinking(widths, toFit: total - newWidth).enumerated() where shrunk != widths[position] {
            var existing = columns[position]
            existing.props.width = shrunk
            upserts.append(existing)
        }
        return BlockChanges(upserts: upserts)
    }

    /// Строка с её ячейками; последняя строка — вся таблица.
    public func removingRow(at index: Int) -> BlockChanges {
        guard rows.indices.contains(index) else { return BlockChanges() }
        guard rowCount > 1 else { return BlockChanges(removals: [table.id]) }
        return BlockChanges(removals: [rows[index].id])
    }

    /// Столбец со всеми его ячейками, в том числе непоказанными вторыми: живая ячейка удалённого столбца вернула бы
    /// его при слиянии (`ChangeMerger`). Последний столбец — вся таблица.
    public func removingColumn(at index: Int) -> BlockChanges {
        guard columns.indices.contains(index) else { return BlockChanges() }
        guard columnCount > 1 else { return BlockChanges(removals: [table.id]) }
        let columnId = columns[index].id
        return BlockChanges(removals: [columnId] + (cellIdsByColumn[columnId] ?? []))
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

    /// Ширины всех столбцов по порядку одной правкой, не уже `minimumColumnWidth`; число ширин не по числу столбцов —
    /// правки нет.
    public func settingWidths(_ widths: [Double]) -> BlockChanges {
        guard widths.count == columnCount else { return BlockChanges() }
        var upserts: [Block] = []
        for (column, width) in zip(columns, widths) {
            let width = max(Self.minimumColumnWidth, width.rounded())
            guard column.props.width != width else { continue }
            var column = column
            column.props.width = width
            upserts.append(column)
        }
        return BlockChanges(upserts: upserts)
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

    /// Ширина под таблицей без окна (`TableGrid.standardWidth`) по блокам этой страницы.
    public func standardTableWidth(of table: Block) -> Double {
        TableGrid.standardWidth(under: table, lookup: block) { [self] listId in flow(listId).filter { $0.kind == .column } }
    }
}
