import AppKit
import Databases
import NotesCore
import VisualStyle

/// Колонка сетки: свойство вида и его ширина.
public struct GridColumn: Sendable, Hashable {
    public var property: DatabaseProperty
    public var width: CGFloat
    /// «Переносить текст» (Q1): текст ячейки — несколькими строками, высота строки — по содержимому.
    public var wraps: Bool

    public init(property: DatabaseProperty, width: CGFloat, wraps: Bool = false) {
        self.property = property
        self.width = width
        self.wraps = wraps
    }

    /// Ширина текста в ячейке: без полей, у названия — ещё без значка.
    public var textWidth: CGFloat {
        width - 2 * Metrics.DatabaseGrid.cellHorizontalPadding - (property.kind == .title ? 24 : 0)
    }

    /// Числа выровнены вправо (contracts/database-ui.md, «Таблица»).
    public var alignsRight: Bool { property.kind == .number || property.kind == .uniqueId }
}

/// Строка сетки, готовая к рисованию: значения видимых колонок по порядку.
public struct GridRow: Sendable, Hashable {
    public var id: UUID
    public var icon: String?
    public var cells: [CellPresentation]
    /// Высота строки: обычная или по перенесённому тексту.
    public var height: CGFloat = Metrics.DatabaseGrid.rowHeight
}

/// Строки вида для сетки (research R3): id строк по порядку из запроса, ячейки — только для видимых, порциями по
/// `chunkSize` строк; следующая порция читается заранее на очереди чтения, пока прокрутка до неё не дошла.
@MainActor
public final class GridContent {
    public let store: NotesStore
    public private(set) var catalog: DatabaseCatalog
    public private(set) var columns: [GridColumn]
    public private(set) var rowIds: [UUID]
    /// Предел загрузки встроенной базы (FR-304): сетка показывает не больше строк; `nil` — все.
    public var loadLimit: Int?
    public static let chunkSize = 100

    private var chunks: [Int: [GridRow]] = [:]
    /// Строки первого экрана, прочитанные на главном потоке поштучно, пока их порция читается фоном.
    private var looseRows: [Int: GridRow] = [:]
    private var loading: Set<Int> = []
    /// Строки, перечитанные (правка ячейки), пока их порция читалась фоном: в пришедшей порции они устарели.
    private var reloadedWhileLoading: [Int: Set<Int>] = [:]
    private var generation = 0
    /// Сколько порций прочитано на главном потоке (прокрутка обогнала чтение заранее) — для проб.
    public private(set) var synchronousLoads = 0
    /// Сколько строк прочитано на главном потоке — для проб и тестов.
    public private(set) var rowsReadOnMainThread = 0
    /// Порция пришла с очереди чтения: перерисовать её строки.
    public var onRowsLoaded: ((Range<Int>) -> Void)?
    /// Для тестов: вызывается на очереди чтения, когда порция уже прочитана, но ещё не отдана сетке.
    var afterBackgroundRead: (@Sendable () async -> Void)?
    /// У прочитанных строк высота не обычная (перенос текста): раскладку сетки — заново.
    public var onHeightsChange: (() -> Void)?
    /// Есть колонки с переносом текста.
    public var wrapsText: Bool { columns.contains(where: \.wraps) }

    public init(store: NotesStore, catalog: DatabaseCatalog, columns: [GridColumn], rowIds: [UUID], loadLimit: Int? = nil) {
        self.store = store
        self.catalog = catalog
        self.columns = columns
        self.rowIds = rowIds
        self.loadLimit = loadLimit
    }

    public var rowCount: Int { min(rowIds.count, loadLimit ?? .max) }

    private var indexById: [UUID: Int]?

    /// Место строки в виде (среди всех строк запроса, не только показанных).
    public func rowIndex(of rowId: UUID) -> Int? {
        if indexById == nil { indexById = Dictionary(rowIds.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first }) }
        return indexById?[rowId]
    }

    /// Ширина колонки на время протяжки края (записывается в вид по отпусканию).
    public func setWidth(_ width: CGFloat, column: Int) {
        guard columns.indices.contains(column) else { return }
        columns[column].width = width
    }

    /// Строка на месте `index` среди показанных.
    public func rowId(at index: Int) -> UUID? { index >= 0 && index < rowCount ? rowIds[index] : nil }

    /// Новый итог запроса вида или новые колонки: прочитанное сбрасывается.
    public func replace(rowIds: [UUID], columns: [GridColumn]? = nil, catalog: DatabaseCatalog? = nil) {
        self.rowIds = rowIds
        indexById = nil
        if let columns { self.columns = columns }
        if let catalog { self.catalog = catalog }
        chunks = [:]
        looseRows = [:]
        loading = []
        reloadedWhileLoading = [:]
        heights = [:]
        generation += 1
    }

    /// Строка для рисования; не прочитанная порция читается сразу.
    public func row(at index: Int) -> GridRow? {
        guard index >= 0, index < rowCount else { return nil }
        let chunk = index / Self.chunkSize
        if chunks[chunk] == nil, let row = looseRows[index] { return row }
        if chunks[chunk] == nil {
            synchronousLoads += 1
            rowsReadOnMainThread += idsOf(chunk).count
            chunks[chunk] = try? readChunk(chunk, generation: generation)
            if let rows = chunks[chunk] { remember(heights: rows, from: chunk * Self.chunkSize) }
            dropLooseRows(of: chunk)
        }
        let rows = chunks[chunk] ?? []
        let offset = index - chunk * Self.chunkSize
        return offset < rows.count ? rows[offset] : nil
    }

    /// Строки, которые сейчас будут нарисованы: не прочитанные — сразу, только они (порция целиком придёт с очереди
    /// чтения). Профиль T085: первая отрисовка вида в 10 000 строк читала на главном потоке всю порцию в 100 строк.
    public func prepareRows(_ range: Range<Int>) {
        let range = max(0, range.lowerBound)..<min(rowCount, range.upperBound)
        let missing = range.filter { chunks[$0 / Self.chunkSize] == nil && looseRows[$0] == nil }
        guard let first = missing.first, let last = missing.last else { return }
        synchronousLoads += 1
        rowsReadOnMainThread += last - first + 1
        guard let rows = try? Self.makeRows(Array(rowIds[first...last]), catalog: catalog, columns: columns, store: store) else { return }
        for (offset, row) in rows.enumerated() { looseRows[first + offset] = row }
        remember(heights: rows, from: first)
    }

    /// Прочитать заранее порции вокруг видимых строк.
    public func prefetch(around visible: Range<Int>) {
        // Видимых строк не бывает больше нескольких экранов: широкая полоса — ошибка места, а не повод читать всё.
        let visible = visible.lowerBound..<min(visible.upperBound, visible.lowerBound + 400)
        let first = max(0, (visible.lowerBound - Self.chunkSize / 2) / Self.chunkSize)
        let last = min((rowCount - 1) / Self.chunkSize, (visible.upperBound + Self.chunkSize / 2) / Self.chunkSize)
        guard first <= last else { return }
        for chunk in first...last where chunks[chunk] == nil && !loading.contains(chunk) {
            loading.insert(chunk)
            let ids = idsOf(chunk)
            let catalog = catalog, columns = columns, store = store, generation = generation, afterRead = afterBackgroundRead
            Task.detached(priority: .userInitiated) {
                let rows = try? Self.makeRows(ids, catalog: catalog, columns: columns, store: store)
                await afterRead?()
                await MainActor.run {
                    guard generation == self.generation else { return }
                    self.loading.remove(chunk)
                    let reloaded = self.reloadedWhileLoading.removeValue(forKey: chunk) ?? []
                    if self.chunks[chunk] == nil, var rows {
                        for index in reloaded {
                            let offset = index - chunk * Self.chunkSize
                            guard offset < rows.count, let fresh = self.looseRows[index]
                                    ?? (try? Self.makeRows([self.rowIds[index]], catalog: catalog, columns: columns, store: store).first)
                            else { continue }
                            rows[offset] = fresh
                        }
                        self.chunks[chunk] = rows
                        self.dropLooseRows(of: chunk)
                        self.remember(heights: rows, from: chunk * Self.chunkSize)
                        self.onRowsLoaded?(chunk * Self.chunkSize..<chunk * Self.chunkSize + rows.count)
                    }
                }
            }
        }
        // Далёкие порции отпускаются: память — на экран и запас, а не на всю базу.
        for chunk in chunks.keys where chunk < first - 2 || chunk > last + 2 { chunks[chunk] = nil }
        looseRows = looseRows.filter { $0.key / Self.chunkSize >= first - 2 && $0.key / Self.chunkSize <= last + 2 }
    }

    private func dropLooseRows(of chunk: Int) {
        let rows = chunk * Self.chunkSize..<(chunk + 1) * Self.chunkSize
        looseRows = looseRows.filter { !rows.contains($0.key) }
    }

    /// Перечитать одну строку (правка ячейки).
    public func reloadRow(_ index: Int) {
        let chunk = index / Self.chunkSize
        if loading.contains(chunk) { reloadedWhileLoading[chunk, default: []].insert(index) }
        if chunks[chunk] == nil, looseRows[index] != nil,
           let fresh = try? Self.makeRows([rowIds[index]], catalog: catalog, columns: columns, store: store).first {
            looseRows[index] = fresh
            remember(heights: [fresh], from: index)
            return
        }
        guard var rows = chunks[chunk], let fresh = try? Self.makeRows([rowIds[index]], catalog: catalog, columns: columns, store: store).first
        else { return }
        let offset = index - chunk * Self.chunkSize
        if offset < rows.count { rows[offset] = fresh; chunks[chunk] = rows }
        remember(heights: [fresh], from: index)
    }

    /// Высоты строк с переносом (по месту), пока строки не перечитаны заново; прочитанные не отпускаются вместе с
    /// порцией — иначе раскладка прыгала бы при прокрутке назад.
    private var heights: [Int: CGFloat] = [:]

    /// Высота строки по месту без чтения: не прочитана — обычная.
    public func knownHeight(at index: Int) -> CGFloat { heights[index] ?? Metrics.DatabaseGrid.rowHeight }

    private func remember(heights rows: [GridRow], from start: Int) {
        guard wrapsText else { return }
        var changed = false
        for (offset, row) in rows.enumerated() {
            let fresh: CGFloat? = row.height == Metrics.DatabaseGrid.rowHeight ? nil : row.height
            if heights[start + offset] != fresh {
                heights[start + offset] = fresh
                changed = true
            }
        }
        if changed { onHeightsChange?() }
    }

    private func idsOf(_ chunk: Int) -> [UUID] {
        let start = chunk * Self.chunkSize
        return Array(rowIds[start..<min(start + Self.chunkSize, rowCount)])
    }

    private func readChunk(_ chunk: Int, generation: Int) throws -> [GridRow] {
        let ids = idsOf(chunk)
        return try Self.makeRows(ids, catalog: catalog, columns: columns, store: store)
    }

    nonisolated static func makeRows(_ ids: [UUID], catalog: DatabaseCatalog, columns: [GridColumn], store: NotesStore) throws -> [GridRow] {
        let snapshots = try RowWindowReader.read(ids, catalog: catalog, store: store)
        let contexts = columns.map { catalog.context(for: $0.property) }
        let wrapped = columns.indices.filter { columns[$0].wraps }
        return ids.map { id in
            guard let snapshot = snapshots[id] else { return GridRow(id: id, icon: nil, cells: columns.map { _ in .empty }) }
            var row = GridRow(id: id, icon: snapshot.icon,
                              cells: zip(columns, contexts).map { CellPresenter.present($0.property, in: snapshot, context: $1) })
            for index in wrapped {
                guard case .text(let text) = row.cells[index] else { continue }
                row.height = max(row.height, WrappedText.rowHeight(text, width: columns[index].textWidth,
                                                                   weight: columns[index].property.kind == .title ? .medium : .regular))
            }
            return row
        }
    }
}
