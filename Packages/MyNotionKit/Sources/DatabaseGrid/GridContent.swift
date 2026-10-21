import AppKit
import Databases
import NotesCore

/// Колонка сетки: свойство вида и его ширина.
public struct GridColumn: Sendable, Hashable {
    public var property: DatabaseProperty
    public var width: CGFloat

    public init(property: DatabaseProperty, width: CGFloat) {
        self.property = property
        self.width = width
    }

    /// Числа выровнены вправо (contracts/database-ui.md, «Таблица»).
    public var alignsRight: Bool { property.kind == .number || property.kind == .uniqueId }
}

/// Строка сетки, готовая к рисованию: значения видимых колонок по порядку.
public struct GridRow: Sendable, Hashable {
    public var id: UUID
    public var icon: String?
    public var cells: [CellPresentation]
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
    private var loading: Set<Int> = []
    private var generation = 0
    /// Сколько порций прочитано на главном потоке (прокрутка обогнала чтение заранее) — для проб.
    public private(set) var synchronousLoads = 0
    /// Порция пришла с очереди чтения: перерисовать её строки.
    public var onRowsLoaded: ((Range<Int>) -> Void)?

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
        loading = []
        generation += 1
    }

    /// Строка для рисования; не прочитанная порция читается сразу.
    public func row(at index: Int) -> GridRow? {
        guard index >= 0, index < rowCount else { return nil }
        let chunk = index / Self.chunkSize
        if chunks[chunk] == nil {
            synchronousLoads += 1
            chunks[chunk] = try? readChunk(chunk, generation: generation)
        }
        let rows = chunks[chunk] ?? []
        let offset = index - chunk * Self.chunkSize
        return offset < rows.count ? rows[offset] : nil
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
            let catalog = catalog, columns = columns, store = store, generation = generation
            Task.detached(priority: .userInitiated) {
                let rows = try? Self.makeRows(ids, catalog: catalog, columns: columns, store: store)
                await MainActor.run {
                    guard generation == self.generation else { return }
                    self.loading.remove(chunk)
                    if self.chunks[chunk] == nil, let rows {
                        self.chunks[chunk] = rows
                        self.onRowsLoaded?(chunk * Self.chunkSize..<chunk * Self.chunkSize + rows.count)
                    }
                }
            }
        }
        // Далёкие порции отпускаются: память — на экран и запас, а не на всю базу.
        for chunk in chunks.keys where chunk < first - 2 || chunk > last + 2 { chunks[chunk] = nil }
    }

    /// Перечитать одну строку (правка ячейки).
    public func reloadRow(_ index: Int) {
        let chunk = index / Self.chunkSize
        guard var rows = chunks[chunk], let fresh = try? Self.makeRows([rowIds[index]], catalog: catalog, columns: columns, store: store).first
        else { return }
        let offset = index - chunk * Self.chunkSize
        if offset < rows.count { rows[offset] = fresh; chunks[chunk] = rows }
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
        return ids.map { id in
            guard let snapshot = snapshots[id] else { return GridRow(id: id, icon: nil, cells: columns.map { _ in .empty }) }
            return GridRow(id: id, icon: snapshot.icon,
                           cells: zip(columns, contexts).map { CellPresenter.present($0.property, in: snapshot, context: $1) })
        }
    }
}
