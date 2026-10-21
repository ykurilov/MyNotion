import Foundation
import Testing
@testable import Databases
@testable import DatabaseViewBar
@testable import NotesCore

/// Модели окон вида (T082): расширенный фильтр, сортировка, видимость свойств, группировка, раскладка, «Настройки вида».
@MainActor
@Suite("Окна вида: модели")
struct ViewPanelModelsTests {
    let t: PanelTestBase
    init() throws { t = try PanelTestBase() }

    func rule(_ property: DatabaseProperty, _ op: FilterOperator = .isNotEmpty) -> FilterCondition {
        FilterCondition(propertyId: property.id, op: op)
    }

    // MARK: Расширенный фильтр

    @Test("Расширенный: «Где», «И ▾» у второй, серая связка дальше; вложенная группа; пункты «•••»")
    func advancedRows() throws {
        var filter = FilterEditing.moveToAdvanced(at: [0], in: FilterEditing.addSimple(rule(t.text), to: nil).0).0
        filter = FilterEditing.addRule(rule(t.number), toGroup: [0], in: filter)
        filter = FilterEditing.addGroup(rule(t.check, .is), toGroup: [0], in: filter)
        filter = FilterEditing.setJoiner(or: true, ofGroup: [0], in: filter)
        let group = try #require(AdvancedFilterModel.group(at: [0], in: filter))
        #expect(group.isOr)
        #expect(group.canAddGroup)
        #expect(group.entries.map(\.lead) == [.whereLabel, .joinerMenu(isOr: true), .joinerText(isOr: true)])
        #expect(group.entries[0].actions == [.remove, .duplicate, .turnIntoGroup])
        guard case .group(let nested) = group.entries[2].content else { Issue.record("нет вложенной группы"); return }
        #expect(nested.path == [0, 2])
        #expect(!nested.canAddGroup)
        #expect(nested.entries.map(\.lead) == [.whereLabel])
        // Внутри вложенной группы глубже не вложить: «Превратить в группу» нет.
        #expect(nested.entries[0].actions == [.remove, .duplicate])
        #expect(group.entries[2].actions == [.remove, .duplicate])
        // «Удалить» последнего правила вложенной группы убирает и её.
        let removed = AdvancedFilterModel.apply(.remove, at: [0, 2, 0], in: filter)
        #expect(removed?.ruleCount == 2)
        #expect(AdvancedFilterModel.group(at: [0], in: removed)?.entries.count == 2)
        #expect(AdvancedFilterModel.apply(.duplicate, at: [0, 0], in: filter)?.ruleCount == 4)
        // Удалить всё — фильтра нет, окно закрывается.
        var all = filter
        for _ in 0..<3 { all = AdvancedFilterModel.apply(.remove, at: [0, 0], in: all) }
        #expect(all == nil)
        #expect(AdvancedFilterModel.group(at: [0], in: all) == nil)
    }

    @Test("Раскладка окна не зависит от текста и чисел в полях, но зависит от вариантов и условий")
    func advancedSignature() throws {
        let catalog = try t.catalog()
        let a = FilterNode.and([.condition(FilterCondition(propertyId: t.text.id, op: .contains, value: "от"))])
        let b = FilterNode.and([.condition(FilterCondition(propertyId: t.text.id, op: .contains, value: "отчёт"))])
        #expect(AdvancedFilterModel.layoutSignature(a, catalog: catalog) == AdvancedFilterModel.layoutSignature(b, catalog: catalog))
        let c = FilterNode.and([.condition(FilterCondition(propertyId: t.text.id, op: .isEmpty))])
        #expect(AdvancedFilterModel.layoutSignature(a, catalog: catalog) != AdvancedFilterModel.layoutSignature(c, catalog: catalog))
        let s1 = FilterNode.and([.condition(FilterCondition(propertyId: t.select.id, op: .is, value: [.string(t.options[0].id.databaseText)]))])
        let s2 = FilterNode.and([.condition(FilterCondition(propertyId: t.select.id, op: .is, value: .null))])
        #expect(AdvancedFilterModel.layoutSignature(s1, catalog: catalog) != AdvancedFilterModel.layoutSignature(s2, catalog: catalog))
        #expect(AdvancedFilterModel.newRule(catalog: catalog)?.propertyId == catalog.titleProperty?.id)
    }

    // MARK: Сортировка

    @Test("Сортировка: уровни с направлением по типу, свойства без уровня, смена свойства и направления, перетаскивание")
    func sorts() throws {
        try t.operations.sort(by: t.number.id, ascending: true, in: t.base.viewId)
        try t.operations.sort(by: t.text.id, ascending: false, in: t.base.viewId)
        let catalog = try t.catalog()
        let model = SortPanelModel(view: try t.view(), catalog: catalog)
        #expect(model.levels.map(\.property.name) == ["Часы", "Описание"])
        #expect(model.levels.map(\.directionTitle) == ["По возрастанию", "Я → А"])
        #expect(SortPanelModel.directions(for: .text).map(\.title) == ["А → Я", "Я → А"])
        #expect(!model.addChoices(catalog: catalog).map(\.name).contains("Часы"))
        #expect(model.propertyChoices(forLevel: 0, catalog: catalog).map(\.name).contains("Часы"))
        #expect(!model.propertyChoices(forLevel: 0, catalog: catalog).map(\.name).contains("Описание"))
        try t.operations.setSorts(model.replacingProperty(atLevel: 1, with: t.date.id), of: t.base.viewId)
        try t.operations.setSorts(SortPanelModel(view: try t.view(), catalog: catalog).settingDirection(atLevel: 0, ascending: false), of: t.base.viewId)
        let changed = SortPanelModel(view: try t.view(), catalog: catalog)
        #expect(changed.levels.map(\.property.name) == ["Часы", "Срок"])
        #expect(changed.levels.map(\.ascending) == [false, false])
        // Первый уровень отпущен под второй.
        try t.operations.moveSort(from: 0, to: SortPanelModel.moveDestination(from: 0, insertion: 2), in: t.base.viewId)
        #expect(SortPanelModel(view: try t.view(), catalog: catalog).levels.map(\.property.name) == ["Срок", "Часы"])
    }

    // MARK: Видимость

    @Test("Видимость: показанные по порядку колонок, скрытые, поиск, «Название» не скрыть и не сдвинуть, места перестановки")
    func visibility() throws {
        try t.operations.setVisible(t.text.id, false, in: t.base.viewId)
        let catalog = try t.catalog()
        let model = PropertyVisibilityModel(view: try t.view(), catalog: catalog)
        #expect(model.shown.map(\.property.name) == ["Название", "Приоритет", "Теги", "Статус", "Часы", "Сделано", "Срок", "Итог"])
        #expect(model.hidden.map(\.property.name) == ["Описание"])
        #expect(model.shown[0].isTitle)
        #expect(model.shownCount == 8)
        #expect(PropertyVisibilityModel(view: try t.view(), catalog: catalog, query: "оп").hidden.map(\.property.name) == ["Описание"])
        #expect(PropertyVisibilityModel(view: try t.view(), catalog: catalog, query: "оп").shown.isEmpty)
        // «Часы» (место 4) — в начало: встаёт сразу за «Названием».
        let index = try #require(model.moveIndex(of: t.number.id, insertion: 0))
        try t.operations.moveColumn(t.number.id, in: t.base.viewId, to: index)
        #expect(PropertyVisibilityModel(view: try t.view(), catalog: catalog).shown.map(\.property.name).prefix(3) == ["Название", "Часы", "Приоритет"])
        // «Приоритет» (место 2) — в конец.
        let moved = PropertyVisibilityModel(view: try t.view(), catalog: catalog)
        try t.operations.moveColumn(t.select.id, in: t.base.viewId, to: try #require(moved.moveIndex(of: t.select.id, insertion: moved.shownCount)))
        #expect(PropertyVisibilityModel(view: try t.view(), catalog: catalog).shown.last?.property.name == "Приоритет")
        #expect(moved.moveIndex(of: catalog.titleProperty!.id, insertion: 3) == nil)
        #expect(moved.moveIndex(of: t.number.id, insertion: 1) == nil)
        try t.operations.setAllVisible(false, in: t.base.viewId)
        let none = PropertyVisibilityModel(view: try t.view(), catalog: catalog)
        #expect(none.shown.map(\.property.name) == ["Название"])
        #expect(!none.canHideAll)
        #expect(none.canShowAll)
    }

    // MARK: Группировка

    @Test("Группировка: список «Группировать по», шаг по типу, порядок групп, глаз и перестановка групп")
    func grouping() throws {
        let catalog = try t.catalog()
        #expect(GroupingPanelModel(view: try t.view(), catalog: catalog, groups: nil).isGrouped == false)
        try t.operations.group(by: t.select.id, in: t.base.viewId)
        var model = GroupingPanelModel(view: try t.view(), catalog: catalog, groups: try t.groups())
        #expect(model.property?.name == "Приоритет")
        #expect(model.bucket == .none)
        #expect(model.sortTitle == "Вручную")
        #expect(model.hideEmpty)
        #expect(model.groups.map(\.label.title) == ["Нет «Приоритет»", "Высокий", "Средний", "Низкий"])
        let order = model.groups.map(\.key)
        try t.operations.setGroupHidden(order[1], true, order: order, in: t.base.viewId)
        model = GroupingPanelModel(view: try t.view(), catalog: catalog, groups: try t.groups())
        #expect(model.groups.map(\.isHidden) == [false, true, false, false])
        #expect(!model.allHidden)
        // «Низкий» — в начало.
        try t.operations.moveGroup(order[3], to: try #require(model.moveIndex(of: order[3], insertion: 0)), order: order, in: t.base.viewId)
        model = GroupingPanelModel(view: try t.view(), catalog: catalog, groups: try t.groups())
        #expect(model.groups.first?.key == order[3])
        try t.operations.setAllGroupsHidden(true, order: model.groups.map(\.key), in: t.base.viewId)
        #expect(GroupingPanelModel(view: try t.view(), catalog: catalog, groups: try t.groups()).allHidden)
        // Шаг даты и числа, «По группам» у статуса.
        try t.operations.group(by: t.date.id, in: t.base.viewId)
        #expect(GroupingPanelModel(view: try t.view(), catalog: catalog, groups: try t.groups()).bucket == .date(selected: "month"))
        try t.operations.editGroup(of: t.base.viewId) { $0.bucket = "week" }
        #expect(GroupingPanelModel(view: try t.view(), catalog: catalog, groups: try t.groups()).bucket == .date(selected: "week"))
        try t.operations.group(by: t.number.id, in: t.base.viewId)
        #expect(GroupingPanelModel(view: try t.view(), catalog: catalog, groups: try t.groups()).bucket == .number(from: "0", to: "1000", step: "100"))
        let bucket = try #require(GroupingPanelModel.numberBucket(from: "0", to: "10", step: "2"))
        try t.operations.editGroup(of: t.base.viewId) { $0.bucket = bucket }
        #expect(GroupingPanelModel(view: try t.view(), catalog: catalog, groups: try t.groups()).groups.map(\.label.title).contains("2 – 4"))
        #expect(GroupingPanelModel.numberBucket(from: "5", to: "1", step: "1") == nil)
        #expect(GroupingPanelModel.numberBucket(from: "0", to: "10", step: "0") == nil)
        try t.operations.group(by: t.status.id, in: t.base.viewId)
        #expect(GroupingPanelModel(view: try t.view(), catalog: catalog, groups: try t.groups()).bucket == .status(byGroups: false))
        #expect(!PropertyChoices.forGroup(catalog).contains { $0.kind == .uniqueId || $0.kind == .files })
    }

    // MARK: Раскладка и настройки вида

    @Test("Раскладка: способы открытия с пояснениями, предел загрузки только у встроенной")
    func layout() throws {
        var model = LayoutPanelModel(view: try t.view(), isInline: false)
        #expect(model.openModeTitle == "Сбоку")
        #expect(!model.showsLoadLimit)
        #expect(!model.options.wrapAllContent)
        #expect(LayoutPanelModel.openModes.map(\.title) == ["Сбоку", "По центру", "На всю страницу"])
        #expect(LayoutPanelModel.loadLimits == [10, 25, 50, 100])
        try t.operations.setOpenRowsIn(.centerPeek, in: t.base.viewId)
        try t.operations.setWrapAllContent(true, in: t.base.viewId)
        try t.operations.setLoadLimit(25, in: t.base.viewId)
        model = LayoutPanelModel(view: try t.view(), isInline: true)
        #expect(model.openModeTitle == "По центру")
        #expect(model.options.wrapAllContent)
        #expect(model.options.loadLimit == 25)
        #expect(model.showsLoadLimit)
    }

    @Test("«Настройки вида»: пункты и серые значения — число колонок, фильтров, сортировок, свойство группы")
    func viewSettings() throws {
        var model = ViewSettingsModel(view: try t.view(), catalog: try t.catalog())
        #expect(model.name == "Таблица")
        #expect(model.rows.map(\.title) == ["Раскладка", "Видимость свойств", "Фильтр", "Сортировка", "Группировка", "Свойства"])
        #expect(model.rows.map(\.value) == ["Таблица", "9", nil, nil, nil, nil])
        try t.operations.addFilter(for: t.text.id, to: t.base.viewId)
        try t.operations.addFilter(for: t.number.id, to: t.base.viewId)
        try t.operations.sort(by: t.number.id, ascending: true, in: t.base.viewId)
        try t.operations.group(by: t.select.id, in: t.base.viewId)
        try t.operations.setVisible(t.text.id, false, in: t.base.viewId)
        model = ViewSettingsModel(view: try t.view(), catalog: try t.catalog())
        #expect(model.rows.map(\.value) == ["Таблица", "8", "2 фильтра", "1 сортировка", "Приоритет", nil])
    }
}
