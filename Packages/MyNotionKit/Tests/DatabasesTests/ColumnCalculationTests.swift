import Foundation
import Testing
@testable import Databases
@testable import NotesCore

/// Итоги колонок (T078, Q1): каждое вычисление contracts по строкам после фильтра и поиска; у групп — свои.
@MainActor
@Suite("Итоги колонок (US3)")
struct ColumnCalculationTests {
    let t: ViewTestBase
    init() throws { t = try ViewTestBase() }

    func totals(search: String? = nil) throws -> ColumnTotals.Result {
        let presentation = try t.present(search: search)
        return try t.store.database.dbWriter.read { db in
            try ColumnTotals.compute(view: presentation.view, catalog: presentation.catalog, rowIds: presentation.rowIds,
                                     groups: presentation.groups, in: db)
        }
    }

    func total(_ calculation: Calculation, of property: DatabaseProperty, search: String? = nil) throws -> ColumnTotal? {
        try t.quiet.setCalculation(calculation, of: property.id, in: t.base.viewId)
        return try totals(search: search).overall[property.id]
    }

    @Test("Количество: всего, значений, уникальных, пустых, не пустых; проценты")
    func counts() throws {
        #expect(try total(.countAll, of: t.number) == ColumnTotal(label: "КОЛИЧЕСТВО", value: "6"))
        #expect(try total(.countValues, of: t.multi)?.value == "5")
        #expect(try total(.countUnique, of: t.multi)?.value == "2")
        #expect(try total(.countEmpty, of: t.text) == ColumnTotal(label: "ПУСТЫХ", value: "3"))
        #expect(try total(.countNotEmpty, of: t.select)?.value == "5")
        #expect(try total(.percentEmpty, of: t.date)?.value.hasPrefix("16") == true)
        #expect(try total(.percentNotEmpty, of: t.text)?.value == "50%")
        let title = try #require(try t.catalog().titleProperty)
        #expect(try total(.countNotEmpty, of: title)?.value == "6")
    }

    @Test("Числа: сумма, среднее, медиана, мин, макс, размах — по заполненным")
    func numbers() throws {
        // Часы: 3, 1, 5, —, 2, 8.
        #expect(try total(.sum, of: t.number) == ColumnTotal(label: "СУММА", value: "19"))
        #expect(try total(.average, of: t.number)?.value.replacingOccurrences(of: ",", with: ".").hasPrefix("3.8") == true)
        #expect(try total(.median, of: t.number)?.value == "3")
        #expect(try total(.min, of: t.number)?.value == "1")
        #expect(try total(.max, of: t.number)?.value == "8")
        #expect(try total(.range, of: t.number)?.value == "7")
    }

    @Test("Даты: ранняя, поздняя, диапазон в днях")
    func dates() throws {
        #expect(try total(.earliestDate, of: t.date)?.label == "РАННЯЯ")
        #expect(try total(.earliestDate, of: t.date)?.value.contains("21") == true)
        #expect(try total(.latestDate, of: t.date)?.value.contains("1") == true)
        #expect(try total(.dateRange, of: t.date)?.value == "41 день")
    }

    @Test("Флажок: отмечено, не отмечено, проценты")
    func checkbox() throws {
        #expect(try total(.checked, of: t.check)?.value == "2")
        #expect(try total(.unchecked, of: t.check)?.value == "4")
        #expect(try total(.percentChecked, of: t.check)?.value.hasPrefix("33") == true)
        #expect(try total(.percentUnchecked, of: t.check)?.value.hasPrefix("66") == true)
    }

    @Test("Итог — по строкам после фильтра и поиска")
    func afterFilterAndSearch() throws {
        try t.quiet.setFilter(.condition(FilterCondition(propertyId: t.check.id, op: .is, value: false)), of: t.base.viewId)
        #expect(try total(.sum, of: t.number)?.value == "18")
        #expect(try total(.countAll, of: t.number, search: "отчет")?.value == "2")
    }

    @Test("Фильтр по связи не видит строк в корзине — как и сама ячейка")
    func relationFilterSkipsTrashedTargets() throws {
        let relation = try t.quiet.addRelation(to: t.base.databaseId, name: "Связь", target: t.base.databaseId)
        try t.quiet.linkRow(t.rows[0], through: relation.id, to: t.rows[1])
        try t.quiet.setRowsTrashed([t.rows[1]], true)

        try t.quiet.setFilter(.condition(FilterCondition(propertyId: relation.id, op: .isNotEmpty, value: .null)), of: t.base.viewId)
        #expect(try t.shownTitles().isEmpty)
        try t.quiet.setFilter(.condition(FilterCondition(propertyId: relation.id, op: .isEmpty, value: .null)), of: t.base.viewId)
        #expect(try t.shownTitles().contains("Отчёт за месяц"))
    }

    @Test("У каждой группы — свой итог")
    func perGroup() throws {
        try t.quiet.group(by: t.select.id, in: t.base.viewId)
        try t.quiet.setCalculation(.sum, of: t.number.id, in: t.base.viewId)
        let result = try totals()
        #expect(result.overall[t.number.id]?.value == "19")
        #expect(result.groups[t.optionKey(t.options[0])]?[t.number.id]?.value == "8")
        #expect(result.groups[t.optionKey(t.options[1])]?[t.number.id]?.value == "9")
        #expect(result.groups[""]?[t.number.id]?.value == "2")
        #expect(result.groups[t.optionKey(t.options[2])]?[t.number.id]?.value == "—")
    }

    @Test("Меню «Посчитать ›»: «Ещё ›» — только у чисел, дат и флажка")
    func menuSections() {
        #expect(ColumnTotals.menuSections(for: .text).map(\.title) == ["Количество", "Проценты"])
        #expect(ColumnTotals.menuSections(for: .number).last?.items == Calculation.numeric)
        #expect(ColumnTotals.menuSections(for: .date).last?.items == Calculation.dates)
        #expect(ColumnTotals.menuSections(for: .checkbox).last?.items == Calculation.checkbox)
        #expect(ColumnTotals.days(1) == "1 день" && ColumnTotals.days(3) == "3 дня" && ColumnTotals.days(11) == "11 дней")
    }
}
