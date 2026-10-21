import AppKit
import Databases
import NotesCore

/// Открытый вид и его настройки (US3): переключение видов, поиск, группы в сетке, итоги в фоне и правки вида через
/// операции окна (каждая — шаг ⌘Z; таблица перечитывается по `DatabaseOperations.didChange`).
extension DatabaseTableController {
    /// Строки сетки: у сгруппированного вида — показанные группы подряд (свёрнутые — без строк).
    static func shownRows(_ presentation: ViewPresentation) -> (rowIds: [UUID], sections: [GridGroupSection]?) {
        guard let groups = presentation.groups, let settings = presentation.view.groupSettings else { return (presentation.rowIds, nil) }
        var rowIds: [UUID] = []
        var sections: [GridGroupSection] = []
        for group in ViewGrouping.shown(groups, hideEmpty: settings.hideEmpty) {
            let start = rowIds.count
            if !group.isCollapsed { rowIds += group.rowIds }
            sections.append(GridGroupSection(key: group.key, label: group.label, count: group.rowIds.count, rows: start..<rowIds.count,
                                             isCollapsed: group.isCollapsed))
        }
        return (rowIds, sections)
    }

    /// Ключи групп в показанном порядке (для правок состояния групп при ручном порядке).
    public var groupOrder: [String] { groups?.map(\.key) ?? [] }

    /// Итоги колонок — на очереди чтения; устаревший пересчёт не отдаёт итог.
    func recomputeTotals(rowIds: [UUID]) {
        totalsTask?.cancel()
        let view = view, catalog = catalog, groups = groups, store = store
        guard ViewQuery.visiblePropertyIds(of: view, catalog: catalog).contains(where: { view.calculation(of: $0) != nil }) else {
            if !totals.overall.isEmpty || !totals.groups.isEmpty {
                totals = ColumnTotals.Result()
                onTotalsChange?()
            }
            return
        }
        totalsTask = Task { [weak self] in
            let result = try? await Task.detached(priority: .userInitiated) {
                try store.database.dbWriter.read { db in
                    try ColumnTotals.compute(view: view, catalog: catalog, rowIds: rowIds, groups: groups, in: db)
                }
            }.value
            guard !Task.isCancelled, let self, let result else { return }
            totals = result
            onTotalsChange?()
        }
    }

    /// Вкладка вида: открыть другой вид той же базы (поиск закрывается, как у Notion).
    public func switchView(to viewId: UUID) {
        guard viewId != self.viewId else { return }
        self.viewId = viewId
        search = nil
        extraLoaded = 0
        reload()
    }

    /// Поиск в базе: с каждым символом — новый запрос; пусто — все строки, `nil` — поле закрыто.
    public func setSearch(_ text: String?) {
        let trimmed = text?.trimmingCharacters(in: .whitespaces)
        let next = text == nil ? nil : trimmed ?? ""
        guard next != search else { return }
        search = next
        reload()
    }

    /// Найденное для подсветки: непустой поиск.
    public var searchHighlight: String? { search.flatMap { $0.isEmpty ? nil : $0 } }

    /// «+ Новая строка» группы: строка в конце группы со значением группы.
    @discardableResult
    public func addRow(inGroup key: String) -> Int? {
        addRow(at: .bottom, groupKey: key)
    }

    /// «▾» у группы.
    public func toggleGroup(_ key: String) {
        let collapsed = groups?.first { $0.key == key }?.isCollapsed ?? false
        attempt { try operations.setGroupCollapsed(key, !collapsed, order: groupOrder, in: viewId) }
    }

    /// Правка вида окнами строки вида (фильтр, сортировка, группировка, раскладка…).
    public func editView(_ body: (DatabaseOperations, UUID) throws -> Void) {
        attempt { try body(operations, viewId) }
    }
}
