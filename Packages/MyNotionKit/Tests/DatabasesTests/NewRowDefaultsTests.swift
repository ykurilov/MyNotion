import Foundation
import Testing
@testable import Databases
@testable import NotesCore

/// Значения новой строки (T077, FR-330): по каждому условию contracts и по группе; строка видна в виде сразу;
/// «Создать» — вверх вида.
@MainActor
@Suite("Новая строка при фильтре и группе (US3)")
struct NewRowDefaultsTests {
    let t: ViewTestBase
    init() throws { t = try ViewTestBase() }

    let now = ISO8601DateFormatter().date(from: "2026-10-21T12:00:00Z")!
    var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    func defaults(_ filter: FilterNode?, group: (GroupSettings, String)? = nil) throws -> NewRowDefaults {
        NewRowDefaults.make(filter: filter, group: group.map { (settings: $0.0, key: $0.1) }, catalog: try t.catalog(), now: now, calendar: calendar)
    }

    func rule(_ property: DatabaseProperty, _ op: FilterOperator, _ value: JSONValue = .null) -> FilterNode {
        .condition(FilterCondition(propertyId: property.id, op: op, value: value))
    }

    @Test("Текст, ссылка: «равно» и «содержит» дают значение; «не содержит», «пусто» — нет")
    func text() throws {
        #expect(try defaults(rule(t.text, .is, "план")).cells[t.text.id] == ["runs": [], "string": "план"])
        #expect(try defaults(rule(t.text, .contains, "план")).cells[t.text.id]?["string"] == "план")
        #expect(try defaults(rule(t.text, .doesNotContain, "план")).isEmpty)
        #expect(try defaults(rule(t.text, .isEmpty)).isEmpty)
        let url = try t.quiet.addProperty(to: t.base.databaseId, name: "Ссылка", kind: .url)
        #expect(try defaults(rule(url, .is, "https://a.ru")).cells[url.id] == "https://a.ru")
        #expect(try defaults(rule(try #require(try t.catalog().titleProperty), .contains, "отчёт")).title == "отчёт")
    }

    @Test("Число: «=» — значение; «>» — пусто")
    func number() throws {
        #expect(try defaults(rule(t.number, .equals, .number(4))).cells[t.number.id] == .number(4))
        #expect(try defaults(rule(t.number, .greaterThan, .number(4))).isEmpty)
    }

    @Test("Выбор: «равно» — первый из отмеченных; «не равно» — пусто; статус «в группе» — первый вариант группы")
    func select() throws {
        let ids: JSONValue = [.string(t.optionKey(t.options[1])), .string(t.optionKey(t.options[0]))]
        #expect(try defaults(rule(t.select, .is, ids)).cells[t.select.id] == .string(t.optionKey(t.options[1])))
        #expect(try defaults(rule(t.select, .isNot, ids)).isEmpty)
        let status = try t.quiet.addProperty(to: t.base.databaseId, name: "Статус", kind: .status)
        let done = try t.store.write { tx throws in
            try tx.saveOption(SelectOption(propertyId: status.id, name: "Готово", color: .green, sortKey: .between(nil, nil), statusGroup: .complete))
        }
        #expect(try defaults(rule(status, .isInGroup, "complete")).cells[status.id] == .string(done.id.databaseText))
    }

    @Test("Множественный выбор «содержит», флажок «отмечен», дата «равно» (Сегодня, Через неделю, точная)")
    func multiCheckDate() throws {
        let tag: JSONValue = [.string(t.optionKey(t.tags[1]))]
        #expect(try defaults(rule(t.multi, .contains, tag)).cells[t.multi.id] == tag)
        #expect(try defaults(rule(t.check, .is, true)).cells[t.check.id] == true)
        #expect(try defaults(rule(t.check, .is, false)).isEmpty)
        #expect(try defaults(rule(t.date, .is, ["relative": "today"])).cells[t.date.id] == ["start": "2026-10-21", "hasTime": false])
        #expect(try defaults(rule(t.date, .is, ["relative": "oneWeekFromNow"])).cells[t.date.id]?["start"] == "2026-10-28")
        #expect(try defaults(rule(t.date, .is, ["exact": "2026-12-31"])).cells[t.date.id]?["start"] == "2026-12-31")
        #expect(try defaults(rule(t.date, .isBefore, ["relative": "today"])).isEmpty)
    }

    @Test("«И» — все условия, «ИЛИ» — первое, вложенные группы")
    func joiners() throws {
        let both = FilterNode.and([rule(t.check, .is, true), rule(t.number, .equals, .number(2))])
        #expect(try defaults(both).cells.count == 2)
        let either = FilterNode.or([rule(t.check, .is, true), rule(t.number, .equals, .number(2))])
        #expect(try defaults(either).cells == [t.check.id: true])
        let nested = FilterNode.and([rule(t.text, .is, "а"), .or([.and([rule(t.number, .equals, .number(1)), rule(t.check, .is, true)]), rule(t.check, .is, false)])])
        #expect(Set(try defaults(nested).cells.keys) == [t.text.id, t.number.id, t.check.id])
    }

    @Test("Группа: значение группы главнее фильтра; «Нет …» — пусто; день даты — значение, месяц — нет")
    func groupValues() throws {
        let settings = GroupSettings(propertyId: t.select.id)
        let filter = rule(t.select, .is, [.string(t.optionKey(t.options[0]))])
        #expect(try defaults(filter, group: (settings, t.optionKey(t.options[2]))).cells[t.select.id] == .string(t.optionKey(t.options[2])))
        #expect(try defaults(filter, group: (settings, "")).cells[t.select.id] == .string(t.optionKey(t.options[0])))
        #expect(try defaults(nil, group: (GroupSettings(propertyId: t.multi.id), t.optionKey(t.tags[0]))).cells[t.multi.id] == [.string(t.optionKey(t.tags[0]))])
        #expect(try defaults(nil, group: (GroupSettings(propertyId: t.check.id), "checked")).cells[t.check.id] == true)
        #expect(try defaults(nil, group: (GroupSettings(propertyId: t.date.id, bucket: "day"), "2026-10-22")).cells[t.date.id]?["start"] == "2026-10-22")
        #expect(try defaults(nil, group: (GroupSettings(propertyId: t.date.id), "2026-10")).isEmpty)
    }

    @Test("Строка со значениями видна в отфильтрованном виде; «Создать» — вверху; ⌘Z убирает её одним шагом")
    func addedRowIsVisible() throws {
        let filter = FilterNode.and([rule(t.check, .is, true), rule(t.select, .is, [.string(t.optionKey(t.options[2]))])])
        try t.quiet.setFilter(filter, of: t.base.viewId)
        #expect(try t.shownTitles() == ["Ремонт"])
        var row = UUID()
        try t.step {
            row = try t.operations.addRow(to: t.base.databaseId, in: t.base.viewId, at: .top,
                                          defaults: NewRowDefaults.make(filter: filter, catalog: try t.catalog()))
        }
        #expect(try t.present().rowIds == [row, t.rows[3]])
        t.undo.undo()
        #expect(try t.shownTitles() == ["Ремонт"])
    }
}
