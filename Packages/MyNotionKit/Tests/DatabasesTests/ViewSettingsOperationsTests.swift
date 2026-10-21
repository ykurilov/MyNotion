import Foundation
import Testing
@testable import Databases
@testable import NotesCore

/// Операции вида (T076, US3): фильтр простой и расширенный, сортировки, видимость, группировка, виды, раскладка, перенос
/// и итоги колонок — каждая правка один шаг ⌘Z, ⇧⌘Z повторяет.
@MainActor
@Suite("Операции вида (US3)")
struct ViewSettingsOperationsTests {
    let t: ViewTestBase
    init() throws { t = try ViewTestBase() }

    func condition(_ property: DatabaseProperty, _ op: FilterOperator, _ value: JSONValue) -> FilterCondition {
        FilterCondition(propertyId: property.id, op: op, value: value)
    }

    // MARK: Фильтр

    @Test("Простой фильтр: плашка с условием по умолчанию, значение, «Удалить фильтр» — каждое шагом ⌘Z")
    func simpleFilter() throws {
        var path: FilterPath = []
        try t.step { path = try t.operations.addFilter(for: t.select.id, to: t.base.viewId) }
        #expect(path == [0])
        let added = try #require(try t.view().filterNode?.node(at: path)?.condition)
        #expect(added.op == .is)
        // Без значения условие не сужает таблицу.
        #expect(try t.shownTitles().count == 6)
        let filled = FilterEditing.update(at: path, in: try t.view().filterNode) { $0.value = [.string(t.optionKey(t.options[0]))] }
        try t.step { try t.operations.setFilter(filled, of: t.base.viewId) }
        #expect(try t.shownTitles() == ["Отчёт за месяц", "Бюджет"])
        try t.step { try t.operations.setFilter(FilterEditing.remove(at: path, in: try t.view().filterNode), of: t.base.viewId) }
        #expect(try t.view().filter == nil)
        #expect(try t.shownTitles().count == 6)
        t.undo.undo()
        #expect(try t.shownTitles() == ["Отчёт за месяц", "Бюджет"])
        t.undo.undo()
        #expect(try t.shownTitles().count == 6)
        t.undo.redo()
        #expect(try t.shownTitles() == ["Отчёт за месяц", "Бюджет"])
    }

    @Test("Флажок по умолчанию — «отмечен»; две плашки — «И»")
    func checkboxAndTwoChips() throws {
        try t.step { try t.operations.addFilter(for: t.check.id, to: t.base.viewId) }
        #expect(try t.shownTitles() == ["Звонок", "Ремонт"])
        let (root, _) = FilterEditing.addSimple(condition(t.number, .greaterThan, .number(2)), to: try t.view().filterNode)
        try t.step { try t.operations.setFilter(root, of: t.base.viewId) }
        #expect(try t.shownTitles().isEmpty)
    }

    @Test("Расширенный фильтр: «В расширенный», правило, «Или», вложенная группа, «Превратить в группу», «Дублировать», «Удалить»")
    func advancedFilter() throws {
        // «Приоритет = Высокий» → в расширенный фильтр.
        var filter: FilterNode? = FilterEditing.addSimple(condition(t.select, .is, [.string(t.optionKey(t.options[0]))]), to: nil).0
        let moved = FilterEditing.moveToAdvanced(at: [0], in: filter)
        filter = moved.0
        let advanced = moved.1
        #expect(advanced == [0])
        #expect(filter?.node(at: advanced)?.isGroup == true)
        #expect(filter?.ruleCount == 1)
        // Второе правило «Сделано» и связка «Или».
        filter = FilterEditing.addRule(condition(t.check, .is, true), toGroup: advanced, in: filter)
        filter = FilterEditing.setJoiner(or: true, ofGroup: advanced, in: filter)
        try t.step { try t.operations.setFilter(filter, of: t.base.viewId) }
        #expect(try t.shownTitles() == ["Отчёт за месяц", "Звонок", "Бюджет", "Ремонт"])
        // Вложенная группа «И»: Часы > 4 и Теги содержит «Срочно» → добавляется «Яблоко».
        filter = FilterEditing.addGroup(condition(t.number, .greaterThan, .number(4)), toGroup: advanced, in: filter)
        let nested = advanced + [2]
        #expect(filter?.node(at: nested)?.isGroup == true)
        filter = FilterEditing.addRule(condition(t.multi, .contains, [.string(t.optionKey(t.tags[0]))]), toGroup: nested, in: filter)
        try t.step { try t.operations.setFilter(filter, of: t.base.viewId) }
        #expect(try t.shownTitles() == ["Отчёт за месяц", "Звонок", "Бюджет", "Ремонт", "Яблоко"])
        // Глубже второй группы вложить нельзя: «Превратить в группу» внутри вложенной ничего не делает.
        #expect(!FilterEditing.canAddGroup(toGroup: nested))
        #expect(FilterEditing.turnIntoGroup(at: nested + [0], in: filter) == filter)
        // «Превратить в группу» у правила расширенного фильтра.
        let grouped = FilterEditing.turnIntoGroup(at: advanced + [1], in: filter)
        #expect(grouped?.node(at: advanced + [1])?.isGroup == true)
        #expect(grouped?.ruleCount == filter?.ruleCount)
        // «Дублировать» правило — копия ниже.
        let duplicated = FilterEditing.duplicate(at: advanced + [0], in: filter)
        #expect(duplicated?.node(at: advanced)?.children.count == 4)
        #expect(duplicated?.node(at: advanced + [1]) == filter?.node(at: advanced + [0]))
        // «Удалить» оба правила вложенной группы — группа уходит с последним.
        var trimmed = FilterEditing.remove(at: nested + [1], in: filter)
        trimmed = FilterEditing.remove(at: nested + [0], in: trimmed)
        #expect(trimmed?.node(at: advanced)?.children.count == 2)
        // «Удалить фильтр» у расширенного — всё дерево.
        try t.step { try t.operations.setFilter(FilterEditing.remove(at: advanced, in: filter), of: t.base.viewId) }
        #expect(try t.view().filter == nil)
        t.undo.undo()
        #expect(try t.shownTitles().count == 5)
        t.undo.undo()
        #expect(try t.shownTitles().count == 4)
    }

    // MARK: Сортировки

    @Test("Сортировки: два уровня, перестановка, ✕, «Удалить сортировку» — шагами ⌘Z")
    func sorts() throws {
        try t.step { try t.operations.sort(by: t.select.id, ascending: true, in: t.base.viewId) }
        try t.step { try t.operations.sort(by: t.base.titlePropertyId, ascending: true, in: t.base.viewId) }
        // Приоритет по порядку вариантов, пустые в конце; при равенстве — по названию.
        #expect(try t.shownTitles() == ["Бюджет", "Отчёт за месяц", "Звонок", "Яблоко", "Ремонт", "Альфа"])
        try t.step { try t.operations.sort(by: t.base.titlePropertyId, ascending: false, in: t.base.viewId) }
        #expect(try t.view().sortSpecs.count == 2)
        #expect(try t.shownTitles() == ["Отчёт за месяц", "Бюджет", "Яблоко", "Звонок", "Ремонт", "Альфа"])
        try t.step { try t.operations.moveSort(from: 1, to: 0, in: t.base.viewId) }
        #expect(try t.view().sortSpecs.map(\.propertyId) == [t.base.titlePropertyId, t.select.id])
        #expect(try t.shownTitles().first == "Яблоко")
        try t.step { try t.operations.removeSort(at: 0, in: t.base.viewId) }
        #expect(try t.view().sortSpecs.map(\.propertyId) == [t.select.id])
        try t.step { try t.operations.removeAllSorts(in: t.base.viewId) }
        #expect(try t.view().sortSpecs.isEmpty)
        t.undo.undo()
        #expect(try t.view().sortSpecs.count == 1)
        t.undo.undo()
        #expect(try t.view().sortSpecs.count == 2)
        t.undo.undo()
        #expect(try t.view().sortSpecs.map(\.propertyId) == [t.select.id, t.base.titlePropertyId])
    }

    // MARK: Видимость

    @Test("Скрыть свойство, «Скрыть все», «Показать все»; «Название» не скрывается; данные целы")
    func visibility() throws {
        try t.step { try t.operations.setVisible(t.text.id, false, in: t.base.viewId) }
        var visible = ViewQuery.visiblePropertyIds(of: try t.view(), catalog: try t.catalog())
        #expect(!visible.contains(t.text.id))
        try t.step { try t.operations.setVisible(t.base.titlePropertyId, false, in: t.base.viewId) }
        #expect(ViewQuery.visiblePropertyIds(of: try t.view(), catalog: try t.catalog()).contains(t.base.titlePropertyId))
        try t.step { try t.operations.setAllVisible(false, in: t.base.viewId) }
        visible = ViewQuery.visiblePropertyIds(of: try t.view(), catalog: try t.catalog())
        #expect(visible == [t.base.titlePropertyId])
        #expect(try t.store.write { try $0.cell(rowId: t.rows[0], propertyId: t.text.id)?.value } != nil)
        try t.step { try t.operations.setAllVisible(true, in: t.base.viewId) }
        #expect(ViewQuery.visiblePropertyIds(of: try t.view(), catalog: try t.catalog()).count == 7)
        t.undo.undo()
        #expect(ViewQuery.visiblePropertyIds(of: try t.view(), catalog: try t.catalog()) == [t.base.titlePropertyId])
        t.undo.undo()
        #expect(ViewQuery.visiblePropertyIds(of: try t.view(), catalog: try t.catalog()).count == 6)
    }

    // MARK: Группировка

    @Test("Группировка по выбору: «Нет …» первой, группы по вариантам, «Скрывать пустые» по умолчанию; шаг ⌘Z")
    func groupBySelect() throws {
        try t.step { try t.operations.group(by: t.select.id, in: t.base.viewId) }
        let settings = try #require(try t.view().groupSettings)
        #expect(settings.hideEmpty)
        let groups = try #require(try t.present().groups)
        #expect(groups.map(\.key) == ["", t.optionKey(t.options[0]), t.optionKey(t.options[1]), t.optionKey(t.options[2])])
        #expect(groups.map { $0.rowIds.count } == [1, 2, 2, 1])
        #expect(groups[0].label == .empty("Нет «Приоритет»"))
        #expect(groups[1].label == .option(name: "Высокий", color: .red))
        t.undo.undo()
        #expect(try t.view().group == nil)
        t.undo.redo()
        #expect(try t.present().groups?.count == 4)
    }

    @Test("Свернуть, скрыть, переставить группу; ручной порядок не сбивается; по алфавиту; «Убрать группировку»")
    func groupStates() throws {
        try t.quiet.group(by: t.select.id, in: t.base.viewId)
        let order = try #require(try t.present().groups).map(\.key)
        let low = t.optionKey(t.options[2])
        try t.step { try t.operations.setGroupCollapsed(low, true, order: order, in: t.base.viewId) }
        var groups = try #require(try t.present().groups)
        #expect(groups.map(\.key) == order)
        #expect(groups.last?.isCollapsed == true)
        try t.step { try t.operations.setGroupHidden("", true, order: order, in: t.base.viewId) }
        groups = try #require(try t.present().groups)
        #expect(ViewGrouping.shown(groups, hideEmpty: true).map(\.key) == Array(order.dropFirst()))
        try t.step { try t.operations.moveGroup(low, to: 0, order: order, in: t.base.viewId) }
        #expect(try #require(try t.present().groups).first?.key == low)
        try t.step { try t.operations.editGroup(of: t.base.viewId) { $0.groupSort = .alphabetical } }
        groups = try #require(try t.present().groups)
        #expect(groups.map(\.label.title) == ["Нет «Приоритет»", "Высокий", "Низкий", "Средний"])
        try t.step { try t.operations.setAllGroupsHidden(true, order: order, in: t.base.viewId) }
        #expect(ViewGrouping.shown(try #require(try t.present().groups), hideEmpty: true).isEmpty)
        try t.step { try t.operations.setGroup(nil, of: t.base.viewId) }
        #expect(try t.present().groups == nil)
        for _ in 0..<6 { t.undo.undo() }
        #expect(try t.view().groupSettings?.groups.contains { $0.isCollapsed } == false)
    }

    @Test("Пустые группы: скрыты при «Скрывать пустые», видны без него; множественный выбор — строка в каждой группе")
    func emptyGroupsAndMulti() throws {
        try t.quiet.setFilter(.condition(FilterCondition(propertyId: t.check.id, op: .is, value: true)), of: t.base.viewId)
        try t.quiet.group(by: t.select.id, in: t.base.viewId)
        let groups = try #require(try t.present().groups)
        #expect(ViewGrouping.shown(groups, hideEmpty: true).count == 2)
        #expect(ViewGrouping.shown(groups, hideEmpty: false).count == 4)
        try t.quiet.setFilter(nil, of: t.base.viewId)
        try t.quiet.group(by: t.multi.id, in: t.base.viewId)
        let tagged = try #require(try t.present().groups)
        #expect(tagged.map { $0.rowIds.count } == [2, 3, 2])
        #expect(try t.titles(tagged[2].rowIds) == ["Бюджет", "Ремонт"])
    }

    @Test("Группировка по дате с шагом и по флажку")
    func dateAndCheckboxGroups() throws {
        try t.quiet.group(by: t.date.id, in: t.base.viewId)
        try t.step { try t.operations.editGroup(of: t.base.viewId) { $0.bucket = "day" } }
        let days = try #require(try t.present().groups)
        #expect(days.map(\.key) == ["", "2026-10-21", "2026-10-22", "2026-11-02", "2026-12-01"])
        #expect(days[1].rowIds.count == 2)
        try t.quiet.editGroup(of: t.base.viewId) { $0.bucket = "month" }
        #expect(try #require(try t.present().groups).map(\.key) == ["", "2026-10", "2026-11", "2026-12"])
        try t.quiet.group(by: t.check.id, in: t.base.viewId)
        let checks = try #require(try t.present().groups)
        #expect(checks.map(\.label.title) == ["Нет «Сделано»", "Не отмечено", "Отмечено"])
        #expect(checks.map { $0.rowIds.count } == [0, 4, 2])
    }

    @Test("По ID и файлам не группируют")
    func notGroupable() throws {
        let files = try t.quiet.addProperty(to: t.base.databaseId, name: "Файлы", kind: .files)
        #expect(throws: (any Error).self) { try t.operations.group(by: files.id, in: t.base.viewId) }
    }

    // MARK: Виды

    @Test("Виды: добавить, переименовать, дублировать «Таблица (1)», удалить — не последний; у каждого свои настройки")
    func views() throws {
        var added = UUID()
        try t.step { added = try t.operations.addView(to: t.base.databaseId) }
        #expect(try t.store.write { try $0.views(ofDatabase: t.base.databaseId) }.map(\.name) == ["Таблица", "Таблица"])
        try t.step { try t.operations.renameView(added, to: "Все") }
        #expect(throws: (any Error).self) { try t.operations.renameView(added, to: " ") }
        try t.quiet.setFilter(.condition(FilterCondition(propertyId: t.check.id, op: .is, value: true)), of: t.base.viewId)
        try t.quiet.setColumnWidth(t.text.id, in: t.base.viewId, to: 320)
        var copy = UUID()
        try t.step { copy = try t.operations.duplicateView(t.base.viewId) }
        let names = try t.store.write { try $0.views(ofDatabase: t.base.databaseId) }.map(\.name)
        #expect(names == ["Таблица", "Таблица (1)", "Все"])
        #expect(try t.shownTitles(copy) == ["Звонок", "Ремонт"])
        #expect(try t.shownTitles(added).count == 6)
        #expect(DatabaseColumns.width(of: t.text, in: try t.view(copy)) == 320)
        // Своя сортировка копии не трогает исходный вид.
        try t.quiet.sort(by: t.base.titlePropertyId, ascending: false, in: copy)
        #expect(try t.view().sortSpecs.isEmpty)
        try t.step { try t.operations.deleteView(t.base.viewId) }
        #expect(try t.store.write { try $0.views(ofDatabase: t.base.databaseId) }.map(\.name) == ["Таблица (1)", "Все"])
        #expect(try ViewQuery.firstViewId(of: t.base.databaseId, in: t.store) == copy)
        try t.quiet.deleteView(added)
        #expect(throws: (any Error).self) { try t.operations.deleteView(copy) }
        t.undo.undo()
        #expect(try t.store.write { try $0.views(ofDatabase: t.base.databaseId) }.map(\.name) == ["Таблица", "Таблица (1)"])
        t.undo.undo()
        #expect(try t.store.write { try $0.views(ofDatabase: t.base.databaseId) }.map(\.name) == ["Таблица"])
    }

    @Test("Перестановка вкладок вида")
    func moveView() throws {
        let second = try t.quiet.addView(to: t.base.databaseId, name: "Второй")
        try t.step { try t.operations.moveView(second, to: 0) }
        #expect(try t.store.write { try $0.views(ofDatabase: t.base.databaseId) }.map(\.name) == ["Второй", "Таблица"])
        t.undo.undo()
        #expect(try t.store.write { try $0.views(ofDatabase: t.base.databaseId) }.map(\.name) == ["Таблица", "Второй"])
    }

    // MARK: Раскладка, перенос, итоги

    @Test("«Открывать строки», «Предел загрузки», «Переносить весь текст», перенос и итог колонки — шагами ⌘Z")
    func layoutAndColumns() throws {
        try t.step { try t.operations.setOpenRowsIn(.centerPeek, in: t.base.viewId) }
        #expect(RowOpenMode(view: try t.view()) == .centerPeek)
        try t.step { try t.operations.setLoadLimit(25, in: t.base.viewId) }
        #expect(try t.view().layout.loadLimit == 25)
        try t.step { try t.operations.setWrapAllContent(true, in: t.base.viewId) }
        #expect(try t.view().wraps(t.number.id))
        try t.step { try t.operations.setWrapAllContent(false, in: t.base.viewId) }
        try t.step { try t.operations.setWrap(t.text.id, true, in: t.base.viewId) }
        #expect(try t.view().wraps(t.text.id))
        #expect(try !t.view().wraps(t.number.id))
        try t.step { try t.operations.setCalculation(.sum, of: t.number.id, in: t.base.viewId) }
        #expect(try t.view().calculation(of: t.number.id) == .sum)
        try t.step { try t.operations.setCalculation(nil, of: t.number.id, in: t.base.viewId) }
        #expect(try t.view().calculation(of: t.number.id) == nil)
        t.undo.undo()
        #expect(try t.view().calculation(of: t.number.id) == .sum)
        t.undo.undo()
        t.undo.undo()
        #expect(try !t.view().wraps(t.text.id))
        t.undo.undo()
        t.undo.undo()
        t.undo.undo()
        #expect(try t.view().layout.loadLimit == 50)
        t.undo.undo()
        #expect(RowOpenMode(view: try t.view()) == .sidePeek)
    }

    @Test("Правка без изменений шага отмены не ставит")
    func noOpEdits() throws {
        // Без группы: шаг ставила бы только сама операция (пустая группа отмены — тоже шаг).
        try t.operations.setLoadLimit(50, in: t.base.viewId)
        try t.operations.removeAllSorts(in: t.base.viewId)
        #expect(!t.undo.canUndo)
    }

    @Test("Поиск: название и значения видимых свойств, без регистра и «ё»; скрытое свойство не ищется")
    func search() throws {
        #expect(try t.shownTitles(search: "отчет") == ["Отчёт за месяц", "Альфа"])
        #expect(try t.shownTitles(search: "срочно") == ["Отчёт за месяц", "Бюджет", "Яблоко"])
        try t.quiet.setVisible(t.text.id, false, in: t.base.viewId)
        #expect(try t.shownTitles(search: "отчёт") == ["Отчёт за месяц"])
    }
}
