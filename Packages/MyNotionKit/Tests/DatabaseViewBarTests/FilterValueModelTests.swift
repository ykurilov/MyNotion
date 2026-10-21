import Foundation
import Testing
@testable import Databases
@testable import DatabaseViewBar
@testable import NotesCore

/// Окно значения фильтра (T082): условия по типам, что показывает окно, какое значение пишет.
@MainActor
@Suite("Окно фильтра: условия и значения")
struct FilterValueModelTests {
    let t: PanelTestBase
    init() throws { t = try PanelTestBase() }

    func titles(_ property: DatabaseProperty) -> [String] {
        FilterEditing.operators(for: property).map { FilterTexts.title(of: $0, kind: property.kind) }
    }

    @Test("Условия по типам: текст, число, выбор, статус, мн. выбор, флажок, дата")
    func operatorsByKind() throws {
        #expect(titles(t.text) == ["Равно", "Не равно", "Содержит", "Не содержит", "Начинается с", "Заканчивается на", "Пусто", "Не пусто"])
        #expect(titles(t.number) == ["=", "≠", ">", "<", "≥", "≤", "Пусто", "Не пусто"])
        #expect(titles(t.select) == ["Равно", "Не равно", "Пусто", "Не пусто"])
        #expect(titles(t.status) == ["Равно", "Не равно", "В группе", "Пусто", "Не пусто"])
        #expect(titles(t.multi) == ["Содержит", "Не содержит", "Пусто", "Не пусто"])
        #expect(titles(t.check) == ["Равно"])
        #expect(titles(t.date) == ["Равно", "До", "После", "Не позже", "Не раньше", "Между", "Относительно сегодня", "Пусто", "Не пусто"])
    }

    @Test("Формула — условия и значение по типу итога; условие по умолчанию — первое из них")
    func formulaByResultType() throws {
        #expect(FilterEditing.operators(for: t.formula).first == .equals)
        #expect(FilterEditing.defaultCondition(for: t.formula).op == .equals)
        let flag = DatabaseProperty(databaseId: t.base.databaseId, name: "Готово?", kind: .formula, config: ["resultType": "checkbox"], sortKey: .between(nil, nil))
        #expect(FilterEditing.operators(for: flag) == [.is])
        #expect(FilterEditing.defaultCondition(for: flag).value == .bool(true))
        let day = DatabaseProperty(databaseId: t.base.databaseId, name: "Когда", kind: .formula, config: ["resultType": "date"], sortKey: .between(nil, nil))
        #expect(FilterEditing.operators(for: day).contains(.isRelativeToToday))
        let list = DatabaseProperty(databaseId: t.base.databaseId, name: "Список", kind: .formula, config: ["resultType": "list"], sortKey: .between(nil, nil))
        #expect(FilterEditing.operators(for: list) == [.contains, .doesNotContain, .isEmpty, .isNotEmpty])
        let catalog = try t.catalog()
        #expect(FilterValues.editor(for: FilterCondition(propertyId: t.formula.id, op: .greaterThan, value: .number(2)), catalog: catalog) == .number("2"))
    }

    @Test("Что показывает окно: поле текста и числа, флажки вариантов с поиском, флажок, даты; «пусто» — без значения")
    func editors() throws {
        let catalog = try t.catalog()
        #expect(FilterValues.editor(for: FilterCondition(propertyId: t.text.id, op: .contains, value: "отч"), catalog: catalog) == .text("отч"))
        #expect(FilterValues.editor(for: FilterCondition(propertyId: t.text.id, op: .isEmpty), catalog: catalog) == .none)
        #expect(FilterValues.editor(for: FilterCondition(propertyId: t.number.id, op: .equals, value: .number(2.5)), catalog: catalog) == .number("2.5"))
        let chosen = FilterCondition(propertyId: t.select.id, op: .is, value: [.string(t.options[1].id.databaseText)])
        guard case .options(let items) = FilterValues.editor(for: chosen, catalog: catalog) else { Issue.record("не варианты"); return }
        #expect(items.map(\.name) == ["Высокий", "Средний", "Низкий"])
        #expect(items.map(\.isSelected) == [false, true, false])
        guard case .options(let found) = FilterValues.editor(for: chosen, catalog: catalog, query: "низ") else { Issue.record("не варианты"); return }
        #expect(found.map(\.name) == ["Низкий"])
        #expect(FilterValues.editor(for: FilterCondition(propertyId: t.status.id, op: .isInGroup, value: "complete"), catalog: catalog) == .statusGroup(.complete))
        #expect(FilterValues.editor(for: FilterCondition(propertyId: t.check.id, op: .is, value: false), catalog: catalog) == .checkbox(false))
        #expect(FilterValues.editor(for: FilterCondition(propertyId: t.date.id, op: .is, value: ["relative": "today"]), catalog: catalog) == .date(.relative("today")))
        #expect(FilterValues.editor(for: FilterCondition(propertyId: t.date.id, op: .isBefore, value: ["exact": "2026-10-21"]), catalog: catalog)
            == .date(.exact("2026-10-21")))
        #expect(FilterValues.editor(for: FilterCondition(propertyId: t.date.id, op: .isAfter), catalog: catalog) == .date(.unset))
        let range = FilterValues.dateRange(start: "2026-10-01", end: "2026-10-31")
        #expect(FilterValues.editor(for: FilterCondition(propertyId: t.date.id, op: .isBetween, value: try #require(range)), catalog: catalog)
            == .dateRange(start: "2026-10-01", end: "2026-10-31"))
        #expect(FilterValues.editor(for: FilterCondition(propertyId: t.date.id, op: .isRelativeToToday, value: FilterValues.relative(direction: "past", count: 2, unit: "month")),
                                    catalog: catalog) == .relative(direction: "past", count: 2, unit: "month"))
    }

    @Test("Значения: флажки вариантов накапливаются, число с запятой, дата ГГГГ-ММ-ДД, неверная дата не пишется")
    func values() throws {
        var value = FilterValues.toggling(t.options[0].id, in: .null)
        value = FilterValues.toggling(t.options[2].id, in: value)
        #expect(FilterValues.selectedIds(value) == [t.options[0].id, t.options[2].id])
        value = FilterValues.toggling(t.options[0].id, in: value)
        value = FilterValues.toggling(t.options[2].id, in: value)
        #expect(value == .null)
        #expect(FilterValues.number("2,5") == .number(2.5))
        #expect(FilterValues.number("") == .null)
        #expect(FilterValues.number("абв") == .null)
        #expect(FilterValues.text("") == .null)
        #expect(FilterValues.exactDate("2026-10-21") == ["exact": "2026-10-21"])
        #expect(FilterValues.exactDate("2026-13-40") == nil)
        #expect(FilterValues.exactDate("21.10.2026") == nil)
        #expect(FilterValues.dateRange(start: "2026-10-01", end: "") == nil)
        #expect(FilterValues.dateChoice("tomorrow") == ["relative": "tomorrow"])
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        #expect(FilterValues.dateChoice("exact", today: Date(timeIntervalSince1970: 1_792_584_000), calendar: calendar) == ["exact": "2026-10-21"])
        #expect(FilterValues.relative(direction: "next", count: 0, unit: "day") == ["direction": "next", "count": 1, "unit": "day"])
    }

    @Test("Смена условия: значение остаётся, если подходит; «пусто» стирает; «Относительно сегодня» — «Этот неделя»")
    func changingOperator() throws {
        let catalog = try t.catalog()
        let text = FilterCondition(propertyId: t.text.id, op: .contains, value: "отч")
        #expect(FilterValues.changingOperator(text, to: .startsWith, catalog: catalog).value == "отч")
        #expect(FilterValues.changingOperator(text, to: .isEmpty, catalog: catalog).value == .null)
        let date = FilterCondition(propertyId: t.date.id, op: .is, value: ["relative": "today"])
        #expect(FilterValues.changingOperator(date, to: .isBefore, catalog: catalog).value == ["relative": "today"])
        #expect(FilterValues.changingOperator(date, to: .isBetween, catalog: catalog).value == .null)
        let relative = FilterValues.changingOperator(date, to: .isRelativeToToday, catalog: catalog)
        #expect(FilterTexts.chipText(relative, catalog: catalog).text == "Срок: относительно сегодня Этот неделя")
        #expect(FilterValues.changingOperator(relative, to: .isAfter, catalog: catalog).value == .null)
        let status = FilterCondition(propertyId: t.status.id, op: .is, value: [.string(UUID().uuidString)])
        #expect(FilterValues.changingOperator(status, to: .isInGroup, catalog: catalog).value == .null)
        #expect(FilterValues.changingOperator(status, to: .isNot, catalog: catalog).value == status.value)
    }

    @Test("Смена свойства у правила — условие по умолчанию нового; списки свойств — по алфавиту, с поиском")
    func propertiesAndLists() throws {
        let catalog = try t.catalog()
        let rule = FilterCondition(propertyId: t.text.id, op: .contains, value: "x")
        #expect(FilterValues.changingProperty(rule, to: t.check) == FilterCondition(propertyId: t.check.id, op: .is, value: true))
        #expect(FilterValues.changingProperty(rule, to: t.text) == rule)
        #expect(PropertyChoices.forFilter(catalog).map(\.name) == ["Итог", "Название", "Описание", "Приоритет", "Сделано", "Срок", "Статус", "Теги", "Часы"])
        #expect(PropertyChoices.forFilter(catalog, matching: "ст").map(\.name) == ["Статус"])
        #expect(!PropertyChoices.forGroup(catalog).isEmpty)
    }

    @Test("Запись: простой фильтр через окно — один шаг, плашка показывает значение")
    func writesThroughOperations() throws {
        let path = try t.operations.addFilter(for: t.number.id, to: t.base.viewId)
        let filled = FilterEditing.update(at: path, in: try t.view().filterNode) { $0.value = FilterValues.number("2") }
        try t.operations.setFilter(filled, of: t.base.viewId)
        let condition = try #require(try t.view().filterNode?.node(at: path)?.condition)
        #expect(FilterTexts.chipText(condition, catalog: try t.catalog()).text == "Часы: 2")
        let shown = try #require(try ViewQuery.present(t.base.viewId, in: t.store)).rowIds.count
        #expect(shown == 0)
        let greater = FilterEditing.update(at: path, in: try t.view().filterNode) { $0 = FilterValues.changingOperator($0, to: .greaterThan, catalog: try! t.catalog()) }
        try t.operations.setFilter(greater, of: t.base.viewId)
        #expect(try #require(try ViewQuery.present(t.base.viewId, in: t.store)).rowIds.count == 2)
    }
}
