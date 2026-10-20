import Foundation
import Testing
@testable import NotesCore

/// Страницы по шаблону (contracts/page-operations.md, «Шаблоны», R12): пустая страница заполняется копией шаблона
/// (поля, блоки, подстраницы-копии) одной правкой с отменой; «Новая страница по шаблону» — копия в корне; «@сегодня»
/// и «@сейчас» шаблона становятся моментом создания; правка шаблона прежних копий не меняет.
@MainActor
@Suite("Шаблоны: страница по шаблону")
struct TemplateInstantiationTests {
    let folder: TemporaryFolder
    let store: NotesStore
    let tree: PageTreeOperations
    /// 2026-10-21 18:45 по Москве.
    let moment = Date(timeIntervalSince1970: 1_792_597_500)

    init() throws {
        folder = try TemporaryFolder()
        store = try NotesStore(database: AppDatabase.open(at: folder.databaseURL), clock: HybridLogicalClock(deviceId: UUID()))
        tree = PageTreeOperations(store: store)
    }

    struct Template {
        var page: Page, subpage: Page, trashedSubpage: Page
    }

    /// «Созвон»: иконка, обложка из галереи, вид; блоки «Повестка», «Дата: @сегодня», «Время: @сейчас», ссылка на подстраницу
    /// «Заметки» (в ней текст) и на подстраницу в корзине.
    private func makeTemplate() throws -> Template {
        try store.write { tx in
            var page = try tx.createPage(title: "Созвон", icon: "📞")
            page.cover = PageCover(source: .gallery("gradient_3"), offset: 0.4)
            page.isFullWidth = true
            page.isSmallText = true
            page.isTemplate = true
            page = try tx.updatePage(page)
            let subpage = try tx.createPage(title: "Заметки", parentId: page.id)
            var trashed = try tx.createPage(title: "Старое", parentId: page.id)
            trashed.trashedAt = Date()
            try tx.updatePage(trashed)
            for block in try tx.blocks(ofPage: page.id) { try tx.deleteBlock(block.id) }
            var key: FractionalSortKey?
            func add(_ make: (FractionalSortKey) -> Block) throws {
                key = .between(key, nil)
                try tx.insertBlock(make(key!))
            }
            try add { Block(pageId: page.id, kind: .heading2, text: InlineText("Повестка"), sortKey: $0) }
            let date = DateMention(start: "2020-01-01", includesTime: false, timeZone: "Europe/Moscow", templateRelative: .today)
            let time = DateMention(start: "2020-01-01T09:00", includesTime: true, timeZone: "Europe/Moscow", templateRelative: .now)
            let text = "Дата: \u{FFFC}, время: \u{FFFC}"
            let atoms = text.utf16.enumerated().filter { $0.element == InlineText.objectReplacementCharacter }.map(\.offset)
            try add { Block(pageId: page.id, text: InlineText(text, runs: [
                StyledRun(start: atoms[0], length: 1, style: .date(date)),
                StyledRun(start: atoms[1], length: 1, style: .date(time)),
            ]), sortKey: $0) }
            try add { Block(pageId: page.id, kind: .pageLink, linkedPageId: subpage.id, sortKey: $0) }
            try add { Block(pageId: page.id, kind: .pageLink, linkedPageId: trashed.id, sortKey: $0) }
            var first = try #require(try tx.blocks(ofPage: subpage.id).first)
            first.text = InlineText("Что решили")
            try tx.updateBlock(first)
            return Template(page: page, subpage: subpage, trashedSubpage: trashed)
        }
    }

    private func blocks(_ pageId: UUID) throws -> [Block] {
        try #require(try store.pageContent(pageId)).blocks
    }

    /// Даты блока по порядку: `start`.
    private func dates(in block: Block) -> [DateMention] {
        block.text.runs.compactMap { if case .date(let date) = $0.style { date } else { nil } }
    }

    private func page(_ id: UUID) throws -> Page { try #require(try store.pageTree().page(id)) }

    private func makeUndoManager() -> UndoManager {
        let undoManager = UndoManager()
        undoManager.groupsByEvent = false
        tree.undoManager = undoManager
        return undoManager
    }

    private func newEmptyPage() throws -> Page {
        try store.write { try $0.createPage() }
    }

    @Test("Заполнение пустой страницы: название, иконка, обложка, вид, блоки; подстраницы — копии под ней")
    func fillCopiesFieldsBlocksAndSubpages() throws {
        let template = try makeTemplate()
        let target = try newEmptyPage()

        try tree.fill(target.id, fromTemplate: template.page.id, now: moment)

        let filled = try page(target.id)
        #expect(filled.title == "Созвон" && filled.icon == "📞")
        #expect(filled.cover == PageCover(source: .gallery("gradient_3"), offset: 0.4))
        #expect(filled.isFullWidth && filled.isSmallText)
        #expect(!filled.isTemplate, "заполненная страница — обычная, не шаблон")
        #expect(filled.parentId == nil)

        let content = try blocks(target.id)
        #expect(content.map(\.kind) == [.heading2, .paragraph, .pageLink])
        #expect(content[0].text.string == "Повестка")
        let copy = try #require(try store.pageTree().children(of: target.id).first)
        #expect(try store.pageTree().children(of: target.id).count == 1, "подстраница в корзине не копируется")
        #expect(copy.title == "Заметки" && copy.id != template.subpage.id)
        #expect(content[2].linkedPageId == copy.id)
        #expect(try blocks(copy.id).first?.text.string == "Что решили")
        // Шаблон не тронут.
        #expect(try blocks(template.page.id).count == 4)
        #expect(try page(template.page.id).isTemplate)
    }

    @Test("Даты шаблона: «сегодня» — день создания, «сейчас» — день и время; метка `templateRelative` в копии снята, в шаблоне осталась")
    func relativeDatesBecomeCreationMoment() throws {
        let template = try makeTemplate()
        let target = try newEmptyPage()

        try tree.fill(target.id, fromTemplate: template.page.id, now: moment)

        let found = dates(in: try blocks(target.id)[1])
        #expect(found.map(\.start) == ["2026-10-21", "2026-10-21T18:45"], "\(found)")
        #expect(found.map(\.includesTime) == [false, true])
        #expect(found.allSatisfy { $0.templateRelative == nil })
        let original = dates(in: try blocks(template.page.id)[1])
        #expect(original.map(\.templateRelative) == [.today, .now])
    }

    @Test("Одна правка: ⌘Z возвращает пустую страницу и стирает копии подстраниц; повтор заполняет снова")
    func fillIsOneUndoStep() throws {
        let template = try makeTemplate()
        let target = try newEmptyPage()
        let before = try blocks(target.id)
        let undoManager = makeUndoManager()

        undoManager.beginUndoGrouping()
        try tree.fill(target.id, fromTemplate: template.page.id, now: moment)
        undoManager.endUndoGrouping()
        undoManager.undo()

        let restored = try page(target.id)
        #expect(restored.title == "" && restored.icon == nil && restored.cover == nil)
        #expect(!restored.isFullWidth && !restored.isSmallText)
        #expect(try blocks(target.id).map(\.id) == before.map(\.id), "пустой абзац — тот же")
        #expect(try store.pageTree().children(of: target.id).isEmpty)
        #expect(!undoManager.canUndo, "заполнение — один шаг отмены")
        #expect(try store.pageTree().visiblePageCount == 3, "шаблон, его подстраница (вторая в корзине) и пустая страница")

        undoManager.redo()
        #expect(try page(target.id).title == "Созвон")
        #expect(try blocks(target.id).map(\.kind) == [.heading2, .paragraph, .pageLink])
        #expect(try store.pageTree().children(of: target.id).map(\.title) == ["Заметки"])
    }

    @Test("Не пустая страница: ошибка, ничего не изменилось")
    func nonEmptyPageIsRejected() throws {
        let template = try makeTemplate()
        let target = try store.write { tx in
            let page = try tx.createPage(title: "Моё")
            var block = try #require(try tx.blocks(ofPage: page.id).first)
            block.text = InlineText("уже есть текст")
            try tx.updateBlock(block)
            return page
        }

        #expect(throws: NotesStoreError.self) { try tree.fill(target.id, fromTemplate: template.page.id, now: moment) }

        #expect(try page(target.id).title == "Моё")
        #expect(try blocks(target.id).map(\.text.string) == ["уже есть текст"])
        #expect(try tree.isEmptyForTemplate(target.id) == false)
    }

    @Test("Пустота: страница без текста и без подстраниц пуста, пустое название не мешает")
    func emptinessIgnoresTitle() throws {
        let titled = try store.write { try $0.createPage(title: "Название есть, тела нет") }
        #expect(try tree.isEmptyForTemplate(titled.id))
        let withSubpage = try store.write { tx in
            let page = try tx.createPage()
            _ = try tx.createPage(parentId: page.id)
            return page
        }
        #expect(try tree.isEmptyForTemplate(withSubpage.id) == false)
    }

    @Test("Не шаблон или шаблон в корзине: ошибка")
    func notATemplateIsRejected() throws {
        let template = try makeTemplate()
        let target = try newEmptyPage()
        let plain = try store.write { try $0.createPage(title: "Просто страница") }

        #expect(throws: NotesStoreError.self) { try tree.fill(target.id, fromTemplate: plain.id, now: moment) }
        try tree.moveToTrash(template.page.id)
        #expect(throws: NotesStoreError.self) { try tree.fill(target.id, fromTemplate: template.page.id, now: moment) }
        #expect(throws: NotesStoreError.self) { try tree.createPage(fromTemplate: template.page.id, now: moment) }
    }

    @Test("Новая страница по шаблону: копия в корне последней, не шаблон, с подстраницами и датой создания; ⌘Z стирает её")
    func newPageFromTemplate() throws {
        let template = try makeTemplate()
        let other = try store.write { try $0.createPage(title: "Другая") }
        let undoManager = makeUndoManager()

        undoManager.beginUndoGrouping()
        let created = try tree.createPage(fromTemplate: template.page.id, now: moment)
        undoManager.endUndoGrouping()

        #expect(created.parentId == nil && !created.isTemplate)
        #expect(created.id != template.page.id)
        #expect(created.title == "Созвон" && created.icon == "📞")
        #expect(created.sortKey > other.sortKey)
        #expect(try store.pageTree().children(of: nil).last?.id == created.id)
        #expect(dates(in: try blocks(created.id)[1]).map(\.start) == ["2026-10-21", "2026-10-21T18:45"])
        #expect(try store.pageTree().children(of: created.id).map(\.title) == ["Заметки"])
        #expect(try page(template.page.id).isTemplate)

        undoManager.undo()

        #expect(try store.pageTree().page(created.id) == nil)
        #expect(try store.pageTree().children(of: nil).map(\.title).contains("Созвон") == true, "шаблон на месте")
        #expect(try store.pageTree().visiblePageCount == 3, "шаблон, его подстраница и «Другая»: копия и её подстраница стёрты")
    }

    @Test("Правка шаблона не меняет прежние копии")
    func editingTemplateLeavesEarlierCopies() throws {
        let template = try makeTemplate()
        let first = try tree.createPage(fromTemplate: template.page.id, now: moment)

        try store.write { tx in
            var heading = try #require(try tx.blocks(ofPage: template.page.id).first)
            heading.text = InlineText("Новая повестка")
            try tx.updateBlock(heading)
            var page = try #require(try tx.page(template.page.id))
            page.title = "Созвон v2"
            try tx.updatePage(page)
        }
        let second = try tree.createPage(fromTemplate: template.page.id, now: moment)

        #expect(try blocks(first.id).first?.text.string == "Повестка")
        #expect(try page(first.id).title == "Созвон")
        #expect(try blocks(second.id).first?.text.string == "Новая повестка")
        #expect(try page(second.id).title == "Созвон v2")
    }

    @Test("Копии, созданные по одному шаблону, не делят ни страниц, ни блоков")
    func twoCopiesAreIndependent() throws {
        let template = try makeTemplate()

        let first = try tree.createPage(fromTemplate: template.page.id, now: moment)
        let second = try tree.createPage(fromTemplate: template.page.id, now: moment)

        let firstIds = Set(try blocks(first.id).map(\.id) + (try blocks(try #require(try store.pageTree().children(of: first.id).first?.id))).map(\.id))
        let secondIds = Set(try blocks(second.id).map(\.id) + (try blocks(try #require(try store.pageTree().children(of: second.id).first?.id))).map(\.id))
        #expect(firstIds.isDisjoint(with: secondIds))
        #expect(try store.pageTree().children(of: first.id).first?.id != store.pageTree().children(of: second.id).first?.id)
    }
}
