import AppKit
import Databases
import NotesCore

/// Открытый вид базы в окне (US1): итог запроса вида, колонки, строки сетки и правки через операции окна. Перечитывает
/// себя по `DatabaseOperations.didChange` — правка в любом окне, отмена, правки с другого Mac.
@MainActor
public final class DatabaseTableController {
    public let store: NotesStore
    public let operations: DatabaseOperations
    public let databaseId: UUID
    public internal(set) var viewId: UUID
    public private(set) var view: DatabaseView
    public private(set) var catalog: DatabaseCatalog
    public let content: GridContent
    /// Встроенная база: сетка показывает не больше предела загрузки, пока не нажали «Загрузить ещё».
    public let isInline: Bool
    /// Сколько строк показано сверх предела («Загрузить ещё» — ещё порция).
    public internal(set) var extraLoaded = 0
    /// Поиск в базе (US3); `nil` — поле закрыто.
    public internal(set) var search: String?
    /// Все группы вида (и скрытые, и пустые) — для списка групп; `nil` — без группировки.
    public internal(set) var groups: [ViewGroup]?
    /// Показанные группы с местами строк в сетке.
    public internal(set) var sections: [GridGroupSection]?
    /// Итоги колонок (Q1) — считаются в фоне после каждого перечитывания.
    public internal(set) var totals = ColumnTotals.Result()
    /// Итоги пересчитаны.
    public var onTotalsChange: (() -> Void)?
    var totalsTask: Task<Void, Never>?
    /// Поиск открыт: вид без поиска и текст строк для поиска (каждый символ сужает их без запроса к базе).
    var searchBase: (presentation: ViewPresentation, index: ViewSearchIndex)?

    /// Строки или колонки сменились — перерисовать (и пересчитать высоту встроенной базы).
    public var onReload: (() -> Void)?
    /// Открыть строку способом вида (`nil`) или заданным; `inNewTab` — ⇧⌘↩ и меню «Открыть в › Новой вкладке».
    public var onOpenRow: ((UUID, RowOpenMode?, Bool) -> Void)?

    private var observer: NSObjectProtocol?

    public init?(store: NotesStore, operations: DatabaseOperations, databaseId: UUID, viewId: UUID? = nil) {
        guard let viewId = viewId ?? (try? ViewQuery.firstViewId(of: databaseId, in: store)),
              let opened = try? ViewQuery.present(viewId, in: store),
              let isInline = try? store.write({ try $0.database(databaseId)?.isInline }) else { return nil }
        self.store = store
        self.operations = operations
        self.databaseId = databaseId
        self.viewId = viewId
        self.isInline = isInline
        view = opened.view
        catalog = opened.catalog
        let shown = Self.shownRows(opened)
        content = GridContent(store: store, catalog: opened.catalog, columns: Self.columns(of: opened.view, catalog: opened.catalog),
                              rowIds: shown.rowIds)
        groups = opened.groups
        sections = shown.sections
        observer = NotificationCenter.default.addObserver(forName: DatabaseOperations.didChange, object: nil, queue: .main) { [weak self] note in
            let touched = note.userInfo?[DatabaseOperations.touchedKey] as? Set<UUID>
            MainActor.assumeIsolated { self?.databaseDidChange(touched) }
        }
    }

    isolated deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    /// Предел загрузки вида (FR-304): 10, 25, 50 (по умолчанию) или 100.
    public var loadLimit: Int { Int(view.layoutOptions["loadLimit"]?.number ?? 50) }
    public var openMode: RowOpenMode { RowOpenMode(view: view) }
    public var title: String { (try? store.write { try $0.page(databaseId)?.title }) ?? "" }

    /// Сетка встроенной базы — по пределу; полностраничная — все строки.
    public var shownLimit: Int? { isInline ? loadLimit + extraLoaded : nil }
    public var hasMoreRows: Bool { shownLimit.map { content.rowIds.count > $0 } ?? false }

    /// Колонки вида: видимые свойства по порядку и их ширины.
    static func columns(of view: DatabaseView, catalog: DatabaseCatalog) -> [GridColumn] {
        ViewQuery.visiblePropertyIds(of: view, catalog: catalog).compactMap { id in
            catalog.propertiesById[id].map { GridColumn(property: $0, width: CGFloat(DatabaseColumns.width(of: $0, in: view)), wraps: view.wraps(id)) }
        }
    }

    /// Перечитать вид: схема, колонки, строки.
    public func reload() {
        // Правка базы или вида: прочитанное для поиска устарело.
        searchBase = nil
        showRows()
    }

    /// Строки вида заново: с поиском — сужением готового итога, без — запросом.
    func showRows() {
        let presented: ViewPresentation?
        if let search, !search.isEmpty {
            if searchBase == nil { searchBase = (try? ViewQuery.searchBase(viewId, in: store)) ?? nil }
            presented = searchBase.map { $0.index.filter($0.presentation, search: search) }
        } else {
            presented = try? ViewQuery.present(viewId, in: store)
        }
        guard let opened = presented else { return }
        view = opened.view
        catalog = opened.catalog
        content.loadLimit = shownLimit
        let shown = Self.shownRows(opened)
        groups = opened.groups
        sections = shown.sections
        content.replace(rowIds: shown.rowIds, columns: Self.columns(of: opened.view, catalog: opened.catalog), catalog: opened.catalog)
        recomputeTotals(rowIds: opened.rowIds)
        onReload?()
    }

    /// «Загрузить ещё»: ещё порция по пределу.
    public func loadMore() {
        extraLoaded += loadLimit
        content.loadLimit = shownLimit
        onReload?()
    }

    /// Порядок и состав строк вида зависят от значений: фильтр, сортировка, группа.
    private var dependsOnValues: Bool {
        view.filter.map { $0 != .null } == true || !(view.sorts.array ?? []).isEmpty || view.group.map { $0 != .null } == true
            || search != nil || !totals.overall.isEmpty
    }

    /// Строки вида, изменённые правкой ячеек.
    public var onRowsChange: ((Set<Int>) -> Void)?

    private func databaseDidChange(_ touched: Set<UUID>?) {
        guard let touched else { return reload() }
        if touched.contains(databaseId) { return reload() }
        let rows = Set(touched.compactMap { content.rowIndex(of: $0) })
        if !rows.isEmpty {
            // Правка значений без фильтра и сортировки — перечитать только эти строки, а не весь вид (SC-303).
            guard !dependsOnValues, Self.rowsStillShown(touched, in: content, store: store) else { return reload() }
            for row in rows where row < content.rowCount { content.reloadRow(row) }
            onRowsChange?(rows)
            return
        }
        // Строка, которой не было в виде, — новая строка этой базы (её id — ребёнок базы): спросить хранилище дёшево.
        let unknown = touched.subtracting(content.rowIds)
        guard !unknown.isEmpty else { return }
        let parents = (try? store.write { tx in try unknown.compactMap { try tx.page($0)?.parentId } }) ?? []
        if parents.contains(databaseId) { reload() }
    }

    /// Строки на месте: не ушли в корзину (иначе нужен новый запрос вида).
    private static func rowsStillShown(_ ids: Set<UUID>, in content: GridContent, store: NotesStore) -> Bool {
        let shown = ids.filter { content.rowIndex(of: $0) != nil }
        return (try? store.write { tx in try shown.allSatisfy { try tx.page($0)?.trashedAt == nil } }) ?? false
    }

    // MARK: Правки

    /// Правка, которая не удалась, — не роняет окно; сообщение идёт в журнал.
    func attempt(_ body: () throws -> Void) {
        do { try body() } catch { NSLog("MyNotion: правка базы не удалась: \(error.localizedDescription)") }
    }

    /// Новая строка: внизу, вверху вида («Создать») или под строкой («+» при наведении). Возвращает её место в виде.
    @discardableResult
    public func addRow(at placement: NewRowPlacement = .bottom, groupKey: String? = nil, template: RowTemplateChoice = .databaseDefault) -> Int? {
        var rowId: UUID?
        // Строка получает значения, при которых она видна в виде (фильтр, группа — FR-330).
        let defaults = NewRowDefaults.make(filter: view.filterNode, group: groupKey.flatMap { key in view.groupSettings.map { (settings: $0, key: key) } },
                                           catalog: catalog)
        attempt { rowId = try operations.addRow(to: databaseId, in: viewId, at: placement, defaults: defaults, template: template) }
        if isInline, let rowId, let limit = shownLimit, content.rowIds.count >= limit, placement == .bottom {
            // Новая строка внизу встроенной базы должна быть видна: предел раздвигается на неё.
            extraLoaded += 1
            content.loadLimit = shownLimit
        }
        reload()
        return rowId.flatMap(content.rowIndex(of:))
    }

    /// Значение текстовой ячейки после правки на месте (название — в `Page.title`).
    public func commitText(_ text: String, row: Int, column: Int) {
        guard let rowId = content.rowId(at: row), let property = content.columns[safe: column]?.property else { return }
        if property.kind == .title {
            attempt { try operations.setTitle(of: rowId, to: text) }
            return
        }
        let context = catalog.context(for: property)
        guard case .value(let value) = PropertyTypes.type(for: property.kind).parseCSV(text, in: context) else { return }
        attempt { try operations.setCell(rowId: rowId, propertyId: property.id, value: value) }
    }

    /// Щелчок по флажку.
    public func toggleCheckbox(row: Int, column: Int) {
        guard let rowId = content.rowId(at: row), let property = content.columns[safe: column]?.property, property.kind == .checkbox else { return }
        let checked = (try? store.write { try $0.cell(rowId: rowId, propertyId: property.id)?.value?.bool }) ?? nil
        attempt { try operations.setCell(rowId: rowId, propertyId: property.id, value: (checked ?? false) ? nil : .bool(true)) }
    }

    /// Текст ячейки для правки на месте: название — как есть, остальное — текст показа без форматирования чисел.
    public func editingText(row: Int, column: Int) -> String {
        guard let rowId = content.rowId(at: row), let property = content.columns[safe: column]?.property else { return "" }
        if property.kind == .title { return (try? store.write { try $0.page(rowId)?.title }) ?? "" }
        let value = try? store.write { try $0.cell(rowId: rowId, propertyId: property.id)?.value }
        return GridCellTypes.type(for: property.kind).editingText(value ?? nil, context: catalog.context(for: property))
    }

    /// ⌘C: текст выбранных ячеек.
    public func copyValues(_ selection: CellSelection) -> [[String]] {
        selection.rows.filter { $0 < content.rowCount }.map { row in
            let gridRow = content.row(at: row)
            return selection.columns.map { column in gridRow?.cells[safe: column]?.plainText ?? "" }
        }
    }

    /// ⌘V: блок из буфера с выбранной ячейки — одним шагом отмены.
    public func paste(_ values: [[String]], at selection: CellSelection) {
        let plan = CellClipboard.pastePlan(values, at: selection, rowIds: Array(content.rowIds.prefix(content.rowCount)), contexts: contexts)
        guard !plan.writes.isEmpty || plan.appendedRows > 0 else { return }
        if isInline, plan.appendedRows > 0 { extraLoaded += plan.appendedRows }
        attempt { try operations.writeCells(plan.writes, appendingRows: plan.appendedRows, to: databaseId, in: viewId) }
    }

    /// ⌫ по выбранным ячейкам.
    public func erase(_ selection: CellSelection) {
        let writes = CellClipboard.eraseWrites(selection, rowIds: Array(content.rowIds.prefix(content.rowCount)), contexts: contexts)
        guard !writes.isEmpty else { return }
        attempt { try operations.writeCells(writes, appendingRows: 0, to: databaseId, in: viewId) }
    }

    var contexts: [PropertyContext] { content.columns.map { catalog.context(for: $0.property) } }

    /// Протяжка края колонки — по отпусканию.
    public func setWidth(_ width: CGFloat, column: Int) {
        guard let property = content.columns[safe: column]?.property else { return }
        attempt { try operations.setColumnWidth(property.id, in: viewId, to: Double(width)) }
    }

    /// Колонку перетащили на место `index` среди видимых.
    public func moveColumn(_ column: Int, to index: Int) {
        guard let property = content.columns[safe: column]?.property else { return }
        attempt { try operations.moveColumn(property.id, in: viewId, to: index) }
    }

    /// Строки перетащили: встают перед строкой `index` (или в конец).
    public func moveRows(_ rows: [Int], before index: Int) {
        let ids = rows.compactMap(content.rowId(at:))
        let moving = Set(ids)
        let order = content.rowIds.filter { !moving.contains($0) }
        let beforeId = index < content.rowIds.count ? content.rowIds[index] : nil
        let insertion = beforeId.flatMap { id in order.firstIndex(of: id) } ?? order.count
        let previous = insertion > 0 ? order[insertion - 1] : nil
        let next = insertion < order.count ? order[insertion] : nil
        attempt { try operations.moveRows(ids, in: viewId, between: previous, and: next) }
    }

    public func duplicateRows(_ rows: [Int]) {
        let ids = rows.compactMap(content.rowId(at:))
        attempt { try operations.duplicateRows(ids, in: viewId) }
    }

    public func trashRows(_ rows: [Int]) {
        let ids = rows.compactMap(content.rowId(at:))
        guard !ids.isEmpty else { return }
        attempt { try operations.trashRows(ids) }
    }

    public func openRow(_ row: Int, mode: RowOpenMode? = nil, inNewTab: Bool = false) {
        guard let rowId = content.rowId(at: row) else { return }
        onOpenRow?(rowId, mode, inNewTab)
    }

    /// Название базы (серый заголовок встроенной): правка страницы-базы с шагом отмены.
    public func setDatabaseTitle(_ title: String) {
        attempt { try operations.setTitle(of: databaseId, to: title) }
    }
}

extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
