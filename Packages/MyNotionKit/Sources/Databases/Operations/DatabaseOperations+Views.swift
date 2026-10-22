import Foundation
import GRDB
import NotesCore

/// Операции вида (US3, contracts/database-ui.md, «Настройки вида»): фильтр, сортировки, видимость, группировка,
/// раскладка, итоги и перенос колонок, сами виды. Каждая правка — один шаг ⌘Z; правка без изменений шага не ставит.
/// Окна считают новое дерево фильтра чистыми правками `FilterEditing` и записывают его `setFilter`.
extension DatabaseOperations {
    // MARK: Фильтр

    public func setFilter(_ filter: FilterNode?, of viewId: UUID) throws {
        try editView(viewId, "Фильтр") { view, _ in view.filter = filter.flatMap { FilterEditing.normalized(FilterEditing.root($0)) }?.json }
    }

    /// «+ Фильтр» и пункт меню колонки «Фильтр»: плашка свойства с условием по умолчанию. Возвращает путь плашки.
    @discardableResult
    public func addFilter(for propertyId: UUID, to viewId: UUID) throws -> FilterPath {
        var path: FilterPath = []
        try editView(viewId, "Фильтр") { view, catalog in
            guard let property = catalog.propertiesById[propertyId] else { throw NotesStoreError.invalidRecord("свойства нет") }
            let (root, added) = FilterEditing.addSimple(FilterEditing.defaultCondition(for: property), to: view.filterNode)
            path = added
            view.filter = root.json
        }
        return path
    }

    // MARK: Сортировка

    public func setSorts(_ sorts: [SortSpec], of viewId: UUID) throws {
        try editView(viewId, "Сортировка") { view, _ in view.sorts = .array(sorts.map(\.json)) }
    }

    /// «Сортировка › А → Я / Я → А» у колонки и «+ Добавить сортировку»: свойство уже сортирует — меняется направление,
    /// иначе — новый уровень в конце.
    public func sort(by propertyId: UUID, ascending: Bool, in viewId: UUID) throws {
        try editView(viewId, "Сортировка") { view, _ in
            var sorts = view.sortSpecs
            if let index = sorts.firstIndex(where: { $0.propertyId == propertyId }) { sorts[index].ascending = ascending } else {
                sorts.append(SortSpec(propertyId: propertyId, ascending: ascending))
            }
            view.sorts = .array(sorts.map(\.json))
        }
    }

    /// Перетащить уровень сортировки.
    public func moveSort(from source: Int, to destination: Int, in viewId: UUID) throws {
        try editView(viewId, "Сортировка") { view, _ in
            var sorts = view.sortSpecs
            guard sorts.indices.contains(source) else { return }
            let moved = sorts.remove(at: source)
            sorts.insert(moved, at: min(max(destination, 0), sorts.count))
            view.sorts = .array(sorts.map(\.json))
        }
    }

    /// «✕» у уровня сортировки.
    public func removeSort(at index: Int, in viewId: UUID) throws {
        try editView(viewId, "Сортировка") { view, _ in
            var sorts = view.sortSpecs
            guard sorts.indices.contains(index) else { return }
            sorts.remove(at: index)
            view.sorts = .array(sorts.map(\.json))
        }
    }

    /// «Удалить сортировку» — снимает все уровни.
    public func removeAllSorts(in viewId: UUID) throws {
        try setSorts([], of: viewId)
    }

    // MARK: Видимость свойств

    /// «Скрыть» у колонки и глаз в «Видимости свойств»; «Название» не скрывается.
    public func setVisible(_ propertyId: UUID, _ isVisible: Bool, in viewId: UUID) throws {
        try editColumns(of: viewId, actionName: isVisible ? "Показать свойство" : "Скрыть свойство") { entries, catalog in
            guard catalog.propertiesById[propertyId]?.kind != .title,
                  let index = entries.firstIndex(where: { DatabaseColumns.id(of: $0) == propertyId }) else { return }
            entries[index] = DatabaseColumns.setting("isVisible", to: .bool(isVisible), in: entries[index])
        }
    }

    /// «Скрыть все» / «Показать все».
    public func setAllVisible(_ isVisible: Bool, in viewId: UUID) throws {
        try editColumns(of: viewId, actionName: isVisible ? "Показать все" : "Скрыть все") { entries, catalog in
            for index in entries.indices where catalog.propertiesById[DatabaseColumns.id(of: entries[index]) ?? UUID()]?.kind != .title {
                entries[index] = DatabaseColumns.setting("isVisible", to: .bool(isVisible), in: entries[index])
            }
        }
    }

    // MARK: Колонки: перенос и итог (Q1)

    /// «Переносить текст» у колонки.
    public func setWrap(_ propertyId: UUID, _ wraps: Bool, in viewId: UUID) throws {
        try editColumns(of: viewId, actionName: "Перенос текста") { entries, _ in
            guard let index = entries.firstIndex(where: { DatabaseColumns.id(of: $0) == propertyId }) else { return }
            entries[index] = DatabaseColumns.setting("wrap", to: wraps ? .bool(true) : nil, in: entries[index])
        }
    }

    /// «Посчитать ›» у колонки; `nil` — «Нет».
    public func setCalculation(_ calculation: Calculation?, of propertyId: UUID, in viewId: UUID) throws {
        try editColumns(of: viewId, actionName: "Итог колонки") { entries, _ in
            guard let index = entries.firstIndex(where: { DatabaseColumns.id(of: $0) == propertyId }) else { return }
            entries[index] = DatabaseColumns.setting("calculation", to: calculation.map { .string($0.rawValue) }, in: entries[index])
        }
    }

    // MARK: Группировка

    /// «Группировать по ›»; `nil` — «Нет» и «Убрать группировку».
    public func setGroup(_ settings: GroupSettings?, of viewId: UUID) throws {
        try editView(viewId, "Группировка") { view, _ in view.group = settings?.json }
    }

    /// Группировать по свойству: настройки по умолчанию («Скрывать пустые группы» включено).
    public func group(by propertyId: UUID, in viewId: UUID) throws {
        try editView(viewId, "Группировка") { view, catalog in
            guard let property = catalog.propertiesById[propertyId], PropertyTypes.type(for: property.kind).isGroupable else {
                throw NotesStoreError.invalidRecord("по этому свойству не группируют")
            }
            if view.groupSettings?.propertyId == propertyId { return }
            view.group = GroupSettings(propertyId: propertyId).json
        }
    }

    /// Правка настроек группировки. `order` — ключи групп в показанном порядке: при ручном порядке состояние новой группы
    /// встаёт на её место, а не в конец.
    public func editGroup(of viewId: UUID, order: [String] = [], _ actionName: String = "Группировка", _ edit: (inout GroupSettings) -> Void) throws {
        try editView(viewId, actionName) { view, _ in
            guard var settings = view.groupSettings else { return }
            settings.materialize(order: order)
            edit(&settings)
            view.group = settings.json
        }
    }

    /// Скрыть или показать группу (глаз в списке групп, «Скрыть группу» в её меню).
    public func setGroupHidden(_ key: String, _ isHidden: Bool, order: [String], in viewId: UUID) throws {
        try editGroup(of: viewId, order: order, isHidden ? "Скрыть группу" : "Показать группу") { $0.update(key) { $0.isHidden = isHidden } }
    }

    /// «▾» у заголовка группы.
    public func setGroupCollapsed(_ key: String, _ isCollapsed: Bool, order: [String], in viewId: UUID) throws {
        try editGroup(of: viewId, order: order, isCollapsed ? "Свернуть группу" : "Развернуть группу") { $0.update(key) { $0.isCollapsed = isCollapsed } }
    }

    /// «Скрыть все» / «Показать все» у списка групп.
    public func setAllGroupsHidden(_ isHidden: Bool, order: [String], in viewId: UUID) throws {
        try editGroup(of: viewId, order: order, isHidden ? "Скрыть группы" : "Показать группы") { settings in
            for key in order { settings.update(key) { $0.isHidden = isHidden } }
        }
    }

    /// Перетащить группу в списке групп: порядок становится ручным.
    public func moveGroup(_ key: String, to index: Int, order: [String], in viewId: UUID) throws {
        try editGroup(of: viewId, order: order, "Порядок групп") { settings in
            guard let from = settings.groups.firstIndex(where: { $0.key == key }) else { return }
            let moved = settings.groups.remove(at: from)
            settings.groups.insert(moved, at: min(max(index, 0), settings.groups.count))
            settings.groupSort = .manual
        }
    }

    // MARK: Раскладка

    /// «Открывать строки» › Сбоку / По центру / На всю страницу.
    public func setOpenRowsIn(_ mode: RowOpenMode, in viewId: UUID) throws {
        try editView(viewId, "Открывать строки") { view, _ in view.layoutOptions["openRowsIn"] = .string(mode.rawValue) }
    }

    /// «Предел загрузки» › 10 / 25 / 50 / 100.
    public func setLoadLimit(_ limit: Int, in viewId: UUID) throws {
        try editView(viewId, "Предел загрузки") { view, _ in view.layoutOptions["loadLimit"] = .number(Double(limit)) }
    }

    /// «Переносить весь текст».
    public func setWrapAllContent(_ wraps: Bool, in viewId: UUID) throws {
        try editView(viewId, "Перенос текста") { view, _ in view.layoutOptions["wrapAllContent"] = .bool(wraps) }
    }

    // MARK: Виды

    /// «+» в строке видов: новая таблица в конце вкладок, все свойства видны.
    @discardableResult
    public func addView(to databaseId: UUID, name: String = "Таблица") throws -> UUID {
        try perform("Новый вид") { transaction in
            let views = try transaction.views(ofDatabase: databaseId, includingDeleted: true)
            let view = try transaction.saveView(DatabaseView(databaseId: databaseId, name: name, sortKey: Self.key(between: views.map(\.sortKey).max(), nil),
                                                             layoutOptions: ["openRowsIn": "sidePeek", "loadLimit": 50, "wrapAllContent": false]))
            return (view.id, { try $0.setViewDeleted(view.id, true) })
        }
    }

    /// «Переименовать» во вкладке и поле имени в настройках вида; пустое имя не принимается.
    public func renameView(_ viewId: UUID, to name: String) throws {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw NotesStoreError.invalidRecord("имя вида пустое") }
        try editView(viewId, "Переименование вида") { view, _ in view.name = trimmed }
    }

    /// «Дублировать вид»: копия всех настроек и ручного порядка строк сразу за видом, имя «Таблица (1)».
    @discardableResult
    public func duplicateView(_ viewId: UUID) throws -> UUID {
        try perform("Дублирование вида") { transaction in
            guard let original = try transaction.view(viewId) else { throw NotesStoreError.invalidRecord("вида нет") }
            let siblings = try transaction.views(ofDatabase: original.databaseId, includingDeleted: true)
            let next = siblings.map(\.sortKey).filter { $0 > original.sortKey }.min()
            let taken = Set(siblings.filter { !$0.isDeleted }.map(\.name))
            var number = 1
            while taken.contains("\(original.name) (\(number))") { number += 1 }
            let copy = try transaction.saveView(DatabaseView(databaseId: original.databaseId, name: "\(original.name) (\(number))", type: original.type,
                                                             sortKey: Self.key(between: original.sortKey, next), filter: original.filter,
                                                             sorts: original.sorts, columns: original.columns, group: original.group,
                                                             layoutOptions: original.layoutOptions))
            for row in try Row.fetchAll(transaction.database, sql: "SELECT rowId, sortKey FROM db_row_order WHERE viewId = ?",
                                        arguments: [viewId.databaseText]) {
                guard let rowId = UUID(uuidString: row[0]), let key = FractionalSortKey(rawValue: row[1]) else { continue }
                try transaction.setRowOrder(viewId: copy.id, rowId: rowId, sortKey: key)
            }
            return (copy.id, { try $0.setViewDeleted(copy.id, true) })
        }
    }

    /// «Удалить вид» — нет при одном виде. Запись остаётся следом (`layoutOptions.deletedAt`): у вида нет поля удаления,
    /// а след доходит до другого Mac обычной правкой поля.
    public func deleteView(_ viewId: UUID) throws {
        try setViewDeleted(viewId, true)
    }

    func setViewDeleted(_ viewId: UUID, _ isDeleted: Bool) throws {
        try perform(isDeleted ? "Удаление вида" : "Возврат вида") { transaction in
            guard var view = try transaction.view(viewId) else { throw NotesStoreError.invalidRecord("вида нет") }
            if isDeleted, try transaction.views(ofDatabase: view.databaseId).filter({ $0.id != viewId }).isEmpty {
                throw NotesStoreError.invalidRecord("последний вид не удаляется")
            }
            view.layoutOptions[ViewLayoutOptions.deletedAtKey] = isDeleted ? .string(ISO8601DateFormatter().string(from: Date())) : nil
            try transaction.saveView(view)
            return ((), { try $0.setViewDeleted(viewId, !isDeleted) })
        }
    }

    /// Перетащить вкладку вида на место `index`.
    public func moveView(_ viewId: UUID, to index: Int) throws {
        try performChange("Порядок видов") { transaction in
            guard let view = try transaction.view(viewId) else { throw NotesStoreError.invalidRecord("вида нет") }
            let others = try transaction.views(ofDatabase: view.databaseId).filter { $0.id != viewId }
            let position = min(max(index, 0), others.count)
            let key = Self.key(between: position > 0 ? others[position - 1].sortKey : nil, position < others.count ? others[position].sortKey : nil)
            guard key != view.sortKey else { return nil }
            let previous = view
            var moved = view
            moved.sortKey = key
            try transaction.saveView(moved)
            return { try $0.restoreView(previous, actionName: "Порядок видов") }
        }
    }

    /// «+ Новая группа» у группировки по выбору и статусу: новый вариант свойства («Новая группа», «Новая группа 1»…) в конце
    /// (у статуса — в «К выполнению»). Название правится в настройках свойства.
    @discardableResult
    public func addGroupOption(to propertyId: UUID) throws -> UUID {
        try perform("Новая группа") { transaction in
            let property = try Self.requireProperty(propertyId, transaction)
            let options = try transaction.options(ofProperty: propertyId, includingDeleted: true)
            let name = Self.freeName("Новая группа", taken: Set(options.filter { $0.deletedAt == nil }.map(\.name)))
            let colors = OptionColor.allCases.filter { $0.rawValue != options.last?.color }
            let option = try transaction.saveOption(SelectOption(propertyId: propertyId, name: name, color: colors.randomElement() ?? .default,
                                                                 sortKey: Self.key(between: options.map(\.sortKey).max(), nil),
                                                                 statusGroup: property.kind == .status ? .todo : nil))
            return (option.id, { try $0.setOptionDeleted(option.id) })
        }
    }

    /// Отмена «+ Новая группа»: вариант удалён (как удаление варианта — следом `deletedAt`).
    func setOptionDeleted(_ optionId: UUID) throws {
        try perform("Новая группа") { transaction in
            guard var option = try transaction.option(optionId) else { throw NotesStoreError.invalidRecord("варианта нет") }
            let previous = option.deletedAt
            option.deletedAt = Date()
            try transaction.saveOption(option)
            return ((), { operations in
                try operations.perform("Новая группа") { transaction in
                    guard var option = try transaction.option(optionId) else { throw NotesStoreError.invalidRecord("варианта нет") }
                    option.deletedAt = previous
                    try transaction.saveOption(option)
                    return ((), { try $0.setOptionDeleted(optionId) })
                }
            })
        }
    }

    // MARK: Новая строка со значениями вида

    /// «+ Новая строка», «Создать» и «+ Новая строка» группы при фильтре или группе: строка сразу получает значения,
    /// при которых она видна (`NewRowDefaults`), одним шагом.
    @discardableResult
    public func addRow(to databaseId: UUID, in viewId: UUID?, at placement: NewRowPlacement = .bottom, defaults: NewRowDefaults) throws -> UUID {
        try perform("Новая строка") { transaction in
            let rowId = try Self.writeRow(in: databaseId, viewId: viewId, placement: placement, title: defaults.title ?? "", transaction)
            for (propertyId, value) in defaults.cells.sorted(by: { $0.key.uuidString < $1.key.uuidString }) {
                try transaction.setCell(rowId: rowId, propertyId: propertyId, value: value)
            }
            return (rowId, { try $0.setRowsTrashed([rowId], true) })
        }
    }

    // MARK: Внутреннее

    /// Правка записи вида одним шагом: ⌘Z возвращает прежние поля целиком.
    func editView(_ viewId: UUID, _ actionName: String, _ edit: (inout DatabaseView, DatabaseCatalog) throws -> Void) throws {
        try performChange(actionName) { transaction in
            guard let previous = try transaction.view(viewId) else { throw NotesStoreError.invalidRecord("вида нет") }
            var view = previous
            try edit(&view, try DatabaseCatalog.read(view.databaseId, in: transaction.database))
            guard !view.changedFields(comparedTo: previous).isEmpty else { return nil }
            try transaction.saveView(view)
            return { try $0.restoreView(previous, actionName: actionName) }
        }
    }

    /// Вернуть поля вида; шаг повтора — поля до возврата.
    func restoreView(_ previous: DatabaseView, actionName: String) throws {
        try perform(actionName) { transaction in
            guard var view = try transaction.view(previous.id) else { throw NotesStoreError.invalidRecord("вида нет") }
            let current = view
            view.name = previous.name
            view.type = previous.type
            view.sortKey = previous.sortKey
            view.filter = previous.filter
            view.sorts = previous.sorts
            view.columns = previous.columns
            view.group = previous.group
            view.layoutOptions = previous.layoutOptions
            try transaction.saveView(view)
            return ((), { try $0.restoreView(current, actionName: actionName) })
        }
    }
}

extension GroupSettings {
    /// Ручной порядок: группы из показанного порядка, которых ещё нет в списке, встают по нему (иначе первая правка
    /// состояния переставила бы группу в начало).
    mutating func materialize(order: [String]) {
        guard groupSort == .manual else { return }
        let listed = Set(groups.map(\.key))
        let missing = order.filter { !listed.contains($0) }
        guard !missing.isEmpty else { return }
        var result: [GroupState] = []
        var stored = groups[...]
        for key in order {
            if let state = stored.first(where: { $0.key == key }) {
                result.append(state)
                stored = stored.filter { $0.key != key }[...]
            } else {
                result.append(GroupState(key: key))
            }
        }
        groups = result + stored
    }
}
