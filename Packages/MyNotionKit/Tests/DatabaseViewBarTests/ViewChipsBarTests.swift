import Foundation
import Testing
@testable import DatabaseViewBar
import Databases
import NotesCore

/// Полоса плашек и подписи фильтра (T081): плашка условия, расширенного фильтра, сортировки, «+ Фильтр».
@MainActor
@Suite("Полоса плашек вида (US3)")
struct ViewChipsBarTests {
    let database = UUID()
    let status: DatabaseProperty
    let hours: DatabaseProperty
    let done: SelectOption
    let catalog: DatabaseCatalog

    init() {
        status = DatabaseProperty(databaseId: database, name: "Статус", kind: .status, sortKey: .between(nil, nil))
        hours = DatabaseProperty(databaseId: database, name: "Часы", kind: .number, sortKey: .between(status.sortKey, nil))
        done = SelectOption(propertyId: status.id, name: "Готово", color: .green, sortKey: .between(nil, nil), statusGroup: .complete)
        catalog = DatabaseCatalog(databaseId: database, properties: [status, hours], options: [done])
    }

    @Test("Плашки: условия корня, «N правил», сортировка, «+ Фильтр»")
    func chips() {
        let filter = FilterNode.and([
            .condition(FilterCondition(propertyId: status.id, op: .isNot, value: [.string(done.id.databaseText)])),
            .condition(FilterCondition(propertyId: hours.id, op: .greaterThan)),
            .or([.condition(FilterCondition(propertyId: hours.id, op: .isEmpty)), .condition(FilterCondition(propertyId: hours.id, op: .equals, value: 2))]),
        ])
        var view = DatabaseView(databaseId: database, sortKey: .between(nil, nil), filter: filter.json)
        view.sorts = [SortSpec(propertyId: hours.id).json, SortSpec(propertyId: status.id, ascending: false).json]
        let chips = ViewChipsBar.chips(view: view, catalog: catalog)
        #expect(chips.map(\.title) == ["Статус: не Готово", "Часы", "2 правила", "2 сортировки", "Фильтр"])
        #expect(chips.map(\.chip) == [.filter([0]), .filter([1]), .advanced([2]), .sorts, .addFilter])
        #expect(chips[1].style == .plain)
    }

    @Test("Подписи: «пусто», дата словами, «Относительно сегодня», склонения")
    func texts() {
        #expect(FilterTexts.chipText(FilterCondition(propertyId: hours.id, op: .isEmpty), catalog: catalog).text == "Часы: пусто")
        #expect(FilterTexts.chipText(FilterCondition(propertyId: hours.id, op: .greaterThan, value: 2), catalog: catalog).text == "Часы: > 2")
        #expect(FilterTexts.dateText(["relative": "today"], op: .isBefore) == "Сегодня")
        #expect(FilterTexts.dateText(["direction": "past", "count": 2, "unit": "week"], op: .isRelativeToToday) == "Прошлые 2 недели")
        #expect(FilterTexts.rules(1) == "1 правило" && FilterTexts.rules(5) == "5 правил" && FilterTexts.sorts(3) == "3 сортировки")
    }
}
