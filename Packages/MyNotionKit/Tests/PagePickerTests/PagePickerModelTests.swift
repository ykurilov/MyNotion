import Foundation
import Testing
import NotesCore
@testable import PagePicker

/// Модель окна «Переместить в…» (research R9, contracts/pages-ui.md, «Окно «Переместить в»»): без запроса — 5 недавних
/// и дерево с раскрытием; с запросом — выдача поиска; недоступные строки; клавиатура ↑↓ → ← Enter Esc.
@MainActor
@Suite("Окно «Переместить в»: модель")
struct PagePickerModelTests {
    /// Корень: «Дом» › «Кухня» › «Полка»; «Работа» › «Отчёт»; «Шаблон» (шаблон). «Старое» — в корзине, «Внутри старого» — под ним.
    struct Pages {
        var home, kitchen, shelf, work, report, template, trashed, insideTrashed: Page
        var all: [Page] { [home, kitchen, shelf, work, report, template, trashed, insideTrashed] }
        var tree: PageTreeSnapshot { PageTreeSnapshot(allPages: all) }
    }

    func pages() -> Pages {
        var key: FractionalSortKey?
        func page(_ title: String, parent: Page? = nil) -> Page {
            key = .between(key, nil)
            return Page(title: title, parentId: parent?.id, sortKey: key!, createdAt: Date(), updatedAt: Date())
        }
        let home = page("Дом"), work = page("Работа")
        var template = page("Шаблон")
        template.isTemplate = true
        var trashed = page("Старое")
        trashed.trashedAt = Date()
        let kitchen = page("Кухня", parent: home)
        return Pages(home: home, kitchen: kitchen, shelf: page("Полка", parent: kitchen), work: work, report: page("Отчёт", parent: work),
                     template: template, trashed: trashed, insideTrashed: page("Внутри старого", parent: trashed))
    }

    func model(_ subject: PagePickerSubject, _ pages: Pages, recents: [Page]? = nil,
               search: @escaping (String) -> [UUID] = { _ in [] }) -> PagePickerModel {
        PagePickerModel(subject: subject, tree: pages.tree, recentPages: recents ?? [], search: search)
    }

    func titles(_ rows: [PagePickerRow], in section: PagePickerRow.Section) -> [String] {
        rows.filter { $0.section == section }.map(\.title)
    }

    @Test("Без запроса: не больше 5 недавних, затем дерево верхнего уровня")
    func emptyQueryShowsRecentsAndTree() {
        let pages = pages()
        let many = [pages.report, pages.shelf, pages.kitchen, pages.work, pages.home, pages.template]
        let model = model(.blocks(fromPage: pages.work.id), pages, recents: many)

        #expect(titles(model.rows, in: .recent) == ["Отчёт", "Полка", "Кухня", "Работа", "Дом"])
        #expect(titles(model.rows, in: .pages) == ["Дом", "Работа", "Шаблон"])
        #expect(model.rows.first { $0.section == .pages && $0.title == "Дом" }?.hasChildren == true)
        #expect(model.rows.first { $0.section == .pages && $0.title == "Шаблон" }?.hasChildren == false)
    }

    @Test("Недавняя страница из корзины не показывается; корзины нет и в дереве")
    func trashIsHidden() {
        let pages = pages()
        let model = model(.blocks(fromPage: pages.work.id), pages, recents: [pages.insideTrashed, pages.home])

        #expect(titles(model.rows, in: .recent) == ["Дом"])
        #expect(!model.rows.contains { $0.title == "Старое" || $0.title == "Внутри старого" })
    }

    @Test("Раскрытие показывает детей под строкой со сдвигом; повтор сворачивает")
    func expandingShowsChildren() {
        let pages = pages()
        let model = model(.blocks(fromPage: pages.work.id), pages)

        model.toggleExpanded(pages.home.id)
        #expect(model.rows.map(\.title) == ["Дом", "Кухня", "Работа", "Шаблон"])
        #expect(model.rows.map(\.depth) == [0, 1, 0, 0])
        model.toggleExpanded(pages.kitchen.id)
        #expect(model.rows.map(\.title) == ["Дом", "Кухня", "Полка", "Работа", "Шаблон"])
        model.toggleExpanded(pages.home.id)
        #expect(model.rows.map(\.title) == ["Дом", "Работа", "Шаблон"])
    }

    @Test("С запросом — выдача поиска в её порядке, с путём; недавних и дерева нет")
    func queryShowsSearchResults() {
        let pages = pages()
        let model = model(.blocks(fromPage: pages.work.id), pages, recents: [pages.home]) { query in
            query == "по" ? [pages.shelf.id, pages.report.id, pages.insideTrashed.id] : []
        }

        model.query = "по"

        #expect(model.rows.map(\.section) == [.results, .results])
        #expect(model.rows.map(\.title) == ["Полка", "Отчёт"])
        #expect(model.rows.map(\.path) == ["Дом / Кухня", "Работа"])
        model.query = "  "
        #expect(titles(model.rows, in: .recent) == ["Дом"])
    }

    @Test("Блоки: исходная страница недоступна, остальные и шаблоны — доступны; верхнего уровня нет")
    func blocksSubjectDisablesSourcePage() {
        let pages = pages()
        let model = model(.blocks(fromPage: pages.work.id), pages, recents: [pages.work, pages.home])

        #expect(model.rows.filter { $0.title == "Работа" }.allSatisfy { !$0.isAvailable })
        #expect(model.rows.filter { $0.title != "Работа" }.allSatisfy(\.isAvailable))
        #expect(!model.rows.contains { $0.target == .topLevel })
    }

    @Test("Страница: недоступны она сама и её потомки; первой строкой дерева — «верхний уровень»")
    func pageSubjectDisablesItsBranch() {
        let pages = pages()
        let model = model(.page(pages.home.id), pages, recents: [pages.shelf, pages.report])
        model.toggleExpanded(pages.home.id)
        model.toggleExpanded(pages.kitchen.id)

        let available = Dictionary(model.rows.filter { $0.section == .pages }.map { ($0.title, $0.isAvailable) }) { $1 }
        #expect(available == ["Страницы — верхний уровень": true, "Дом": false, "Кухня": false, "Полка": false,
                              "Работа": true, "Шаблон": true])
        #expect(model.rows.first { $0.section == .pages }?.target == .topLevel)
        #expect(model.rows.first { $0.section == .recent && $0.title == "Полка" }?.isAvailable == false)
        #expect(model.rows.first { $0.section == .recent && $0.title == "Отчёт" }?.isAvailable == true)
    }

    @Test("↑↓ переходят по доступным строкам, недоступные пропускаются; Enter выбирает")
    func arrowsSkipUnavailableAndEnterChooses() {
        let pages = pages()
        var chosen: PagePickerTarget?
        let model = model(.blocks(fromPage: pages.home.id), pages, recents: [pages.report])
        model.onChoose = { chosen = $0 }

        #expect(model.selectedRow?.title == "Отчёт", "Первая доступная строка выбрана сразу")
        #expect(model.handle(.down))
        #expect(model.selectedRow?.title == "Работа", "«Дом» — исходная, пропущен")
        #expect(model.handle(.down))
        #expect(model.selectedRow?.title == "Шаблон")
        #expect(model.handle(.down))
        #expect(model.selectedRow?.title == "Шаблон", "Ниже последней — остаётся на ней")
        #expect(model.handle(.up))
        #expect(model.handle(.up))
        #expect(model.selectedRow?.title == "Отчёт")
        #expect(model.handle(.enter))
        #expect(chosen == .page(pages.report.id))
    }

    @Test("→ раскрывает выбранную строку, ← сворачивает; Esc закрывает")
    func rightExpandsLeftCollapsesEscapeDismisses() {
        let pages = pages()
        var dismissed = false
        let model = model(.blocks(fromPage: pages.report.id), pages)
        model.onDismiss = { dismissed = true }

        #expect(model.selectedRow?.title == "Дом")
        #expect(model.handle(.right))
        #expect(model.rows.map(\.title) == ["Дом", "Кухня", "Работа", "Шаблон"])
        #expect(model.handle(.left))
        #expect(model.rows.map(\.title) == ["Дом", "Работа", "Шаблон"])
        #expect(model.handle(.escape))
        #expect(dismissed)
    }

    @Test("Щелчок по недоступной строке ничего не выбирает")
    func unavailableRowCannotBeChosen() {
        let pages = pages()
        var chosen: PagePickerTarget?
        let model = model(.page(pages.work.id), pages)
        model.onChoose = { chosen = $0 }
        let work = try! #require(model.rows.firstIndex { $0.title == "Работа" })

        model.choose(at: work)
        #expect(chosen == nil)
        model.choose(at: model.rows.firstIndex { $0.title == "Дом" }!)
        #expect(chosen == .page(pages.home.id))
    }
}
