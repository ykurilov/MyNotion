import Foundation
import Testing
@testable import Databases
@testable import NotesCore

/// Группы вида по выбору и статусу (T085): значения группы — только у строк, что прошли фильтр, а группы те же, что
/// по значениям всех строк базы: пустые значения, снятый выбор, строки в корзине и шаблоны не путают группы.
@MainActor
@Suite("Вид: значения групп выбора и статуса")
struct ViewGroupValuesTests {
    let t: ViewTestBase

    init() throws { t = try ViewTestBase() }

    /// Группы по значениям всех строк базы — как читались до T085.
    private func groupsFromAllValues(_ presentation: ViewPresentation) throws -> [ViewGroup] {
        let settings = try #require(presentation.view.groupSettings)
        let property = try #require(presentation.catalog.propertiesById[settings.propertyId])
        let context = presentation.catalog.context(for: property)
        let values = try t.store.database.dbWriter.read { db in
            try PropertyValues.read(property, of: t.base.databaseId, context: context, in: db)
        }
        return ViewGrouping.groups(rowIds: presentation.rowIds, values: values, settings: settings, context: context)
    }

    /// Строка в корзине и шаблон со значением — их нет ни в строках вида, ни в группах.
    private func addHiddenRows(value: JSONValue, propertyId: UUID) throws {
        let trashed = try t.quiet.addRow(to: t.base.databaseId, in: nil, title: "В корзине")
        try t.quiet.setCell(rowId: trashed, propertyId: propertyId, value: value)
        try t.quiet.trashRows([trashed])
        let template = try t.quiet.addRow(to: t.base.databaseId, in: nil, title: "Шаблон")
        try t.quiet.setCell(rowId: template, propertyId: propertyId, value: value)
        try t.store.write { tx in
            guard var page = try tx.page(template) else { return }
            page.isTemplate = true
            try tx.updatePage(page)
        }
    }

    @Test("Выбор: снятое значение и строка без значения — в «Нет …», корзина и шаблон не в группах, фильтр сужает группы")
    func selectGroups() throws {
        try t.quiet.setCell(rowId: t.rows[1], propertyId: t.select.id, value: nil)
        try addHiddenRows(value: .string(t.optionKey(t.options[2])), propertyId: t.select.id)
        try t.quiet.group(by: t.select.id, in: t.base.viewId)

        let all = try t.present()
        #expect(all.groups == (try groupsFromAllValues(all)))
        let groups = try #require(all.groups)
        #expect(groups.map(\.key) == ["", t.optionKey(t.options[0]), t.optionKey(t.options[1]), t.optionKey(t.options[2])])
        #expect(try groups.map { try t.titles($0.rowIds) } == [["Звонок", "Альфа"], ["Отчёт за месяц", "Бюджет"], ["Яблоко"], ["Ремонт"]])

        try t.quiet.setFilter(.condition(FilterCondition(propertyId: t.number.id, op: .greaterThan, value: .number(2))), of: t.base.viewId)
        let filtered = try t.present()
        #expect(filtered.groups == (try groupsFromAllValues(filtered)))
        #expect(try #require(filtered.groups).map { try t.titles($0.rowIds) } == [[], ["Отчёт за месяц", "Бюджет"], ["Яблоко"], []])
    }

    @Test("Статус: строки без статуса, снятый статус, корзина и шаблон — те же группы, что по значениям всех строк")
    func statusGroups() throws {
        let status = try t.quiet.addProperty(to: t.base.databaseId, name: "Статус", kind: .status)
        let options = try #require(try t.catalog().options[status.id])
        try t.quiet.setCell(rowId: t.rows[0], propertyId: status.id, value: .string(options[0].id.databaseText))
        try t.quiet.setCell(rowId: t.rows[2], propertyId: status.id, value: .string(options[options.count - 1].id.databaseText))
        try t.quiet.setCell(rowId: t.rows[3], propertyId: status.id, value: .string(options[0].id.databaseText))
        try t.quiet.setCell(rowId: t.rows[3], propertyId: status.id, value: nil)
        try addHiddenRows(value: .string(options[options.count - 1].id.databaseText), propertyId: status.id)
        try t.quiet.group(by: status.id, in: t.base.viewId)

        let all = try t.present()
        let groups = try #require(all.groups)
        #expect(groups == (try groupsFromAllValues(all)))
        #expect(Set(groups.flatMap(\.rowIds)) == Set(t.rows), "каждая строка вида — ровно в одной группе")
        #expect(groups.flatMap(\.rowIds).count == t.rows.count)

        try t.quiet.setFilter(.condition(FilterCondition(propertyId: t.check.id, op: .is, value: true)), of: t.base.viewId)
        let filtered = try t.present()
        #expect(filtered.groups == (try groupsFromAllValues(filtered)))
        #expect(Set(try #require(filtered.groups).flatMap(\.rowIds)) == [t.rows[1], t.rows[3]])
    }
}
