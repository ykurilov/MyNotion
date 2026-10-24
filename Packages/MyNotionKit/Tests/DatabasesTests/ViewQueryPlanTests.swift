import Foundation
import Testing
@testable import Databases
@testable import NotesCore

/// План запроса вида (T085): строки базы ищутся по индексу живых строк `page_live_by_parent` — корзина и шаблоны
/// отсекаются в индексе, а id строки берётся из него же, без чтения самих страниц.
@MainActor
@Suite("Вид: план запроса")
struct ViewQueryPlanTests {
    let t: ViewTestBase

    init() throws { t = try ViewTestBase() }

    @Test("Фильтр и сортировка, как у вида «Задачи — работа»: строки — из покрывающего индекса живых строк")
    func liveRowsComeFromCoveringIndex() throws {
        try t.quiet.setFilter(.condition(FilterCondition(propertyId: t.select.id, op: .isNot, value: .array([.string(t.optionKey(t.options[2]))]))),
                              of: t.base.viewId)
        try t.quiet.sort(by: t.number.id, ascending: true, in: t.base.viewId)
        var spec = ViewQuerySpec(view: try t.view())
        spec.groupPropertyId = nil
        let plan = try ViewQuery.plan(spec, catalog: try t.catalog(), in: t.store)
        #expect(plan.first?.contains("USING COVERING INDEX page_live_by_parent") == true, "\(plan.joined(separator: " | "))")
        // Те же строки, что и без индекса.
        #expect(try t.shownTitles().sorted() == ["Альфа", "Бюджет", "Звонок", "Отчёт за месяц", "Яблоко"])
    }
}
