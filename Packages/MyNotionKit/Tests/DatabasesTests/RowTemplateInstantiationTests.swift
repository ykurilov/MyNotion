import Foundation
import GRDB
import Testing
@testable import Databases
@testable import NotesCore

/// Шаблоны строк базы (T095, spec US6, research R13): новый шаблон, по умолчанию, дублировать, удалить; строка по
/// шаблону получает значения, связи, иконку, обложку, вид, блоки и подстраницы; «Сегодня» / «Сейчас» у даты и
/// «@сегодня» в теле — момент создания (часы подменены); значения фильтра — поверх шаблона; правка шаблона прежних
/// строк не меняет; шаблонов нет в таблице, дереве и разделе «Шаблоны» 003.
@MainActor
@Suite("Шаблоны строк базы (US6)")
struct RowTemplateInstantiationTests {
    let folder: URL
    let store: NotesStore
    let undo = UndoManager()
    let operations: DatabaseOperations
    /// Подготовка без шагов отмены.
    let quiet: DatabaseOperations
    let tasks: CreatedDatabase
    let projects: CreatedDatabase
    let tag: UUID, due: UUID, project: UUID
    let bug: SelectOption, urgent: SelectOption
    let projectA: UUID
    /// 3 ноября 2026, 14:30 по Макассару (UTC+8) = 06:30 UTC.
    let now = Date(timeIntervalSince1970: 1_793_687_400)
    let zone = "Asia/Makassar"

    init() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("row-templates-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        store = NotesStore(database: try AppDatabase.open(at: folder.appendingPathComponent("MyNotion.sqlite")), clock: HybridLogicalClock(deviceId: UUID()))
        store.addWriteHook(CellIndexer())
        store.addWriteHook(ComputationHook(store: store, queue: nil))
        undo.groupsByEvent = false
        operations = DatabaseOperations(store: store, undoManager: undo)
        quiet = DatabaseOperations(store: store)
        tasks = try quiet.createDatabase(in: nil, isInline: false, title: "Задачи")
        projects = try quiet.createDatabase(in: nil, isInline: false, title: "Проекты")
        tag = try quiet.addProperty(to: tasks.databaseId, name: "Тег", kind: .select).id
        bug = try quiet.createOption(in: tag, named: "Баг", color: .red)
        urgent = try quiet.createOption(in: tag, named: "Срочно", color: .orange)
        due = try quiet.addProperty(to: tasks.databaseId, name: "Срок", kind: .date).id
        project = try quiet.addRelation(to: tasks.databaseId, name: "Проект", target: projects.databaseId).id
        projectA = try quiet.addRow(to: projects.databaseId, in: nil, title: "Дом")
    }

    func step<T>(_ body: () throws -> T) rethrows -> T {
        undo.beginUndoGrouping()
        defer { undo.endUndoGrouping() }
        return try body()
    }

    func read<T>(_ body: (NotesTransaction) throws -> T) throws -> T { try store.write { tx throws in try body(tx) } }
    func page(_ id: UUID) throws -> Page { try #require(try read { try $0.page(id) }) }
    func cell(_ row: UUID, _ property: UUID) throws -> JSONValue? { try read { try $0.cell(rowId: row, propertyId: property)?.value } }
    func templates() throws -> RowTemplateList { try RowTemplates.list(of: tasks.databaseId, in: store) }
    func shownRows() throws -> [UUID] { try #require(try ViewQuery.present(tasks.viewId, in: store)).rowIds }
    func related(_ row: UUID) throws -> [UUID] {
        let property = try #require(try read { try $0.property(project) })
        return try RelationLinks.related(row, through: property, in: store).map(\.id)
    }

    /// Шаблон «Баг»: тег, проект, иконка, обложка, широкая страница, чек-лист в теле и подстраница «Шаги».
    func makeBugTemplate() throws -> UUID {
        let id = try quiet.addRowTemplate(to: tasks.databaseId, title: "Баг")
        try quiet.setCell(rowId: id, propertyId: tag, value: .string(bug.id.databaseText))
        try quiet.linkRow(id, through: project, to: projectA)
        try store.write { tx in
            var template = try #require(try tx.page(id))
            template.icon = "🐞"
            template.cover = PageCover(source: .gallery("gradient_1"), offset: 0.3)
            template.isFullWidth = true
            try tx.updatePage(template)
            for block in try tx.blocks(ofPage: id) { try tx.deleteBlock(block.id) }
            try tx.insertBlock(Block(pageId: id, kind: .checkbox, text: InlineText("Повторить"), sortKey: .between(nil, nil)))
            let steps = try tx.createPage(title: "Шаги", parentId: id)
            let last = try tx.blocks(ofPage: id).last?.sortKey
            try tx.insertBlock(Block(pageId: id, kind: .pageLink, linkedPageId: steps.id, sortKey: .between(last, nil)))
        }
        return id
    }

    /// Шаблон «Созвон»: срок «Сегодня» или «Сейчас» и «@сегодня» в теле.
    func makeCallTemplate(relative: String) throws -> UUID {
        let id = try quiet.addRowTemplate(to: tasks.databaseId, title: "Созвон")
        try quiet.setCell(rowId: id, propertyId: due, value: ["start": "2026-10-01", "hasTime": false, "timeZone": .string(zone),
                                                              "relative": .string(relative)])
        try store.write { tx in
            for block in try tx.blocks(ofPage: id) { try tx.deleteBlock(block.id) }
            let date = DateMention(start: "2026-10-01", includesTime: false, timeZone: zone, templateRelative: .today)
            try tx.insertBlock(Block(pageId: id, text: InlineText("Созвон \u{FFFC}", runs: [StyledRun(start: 7, length: 1, style: .date(date))]),
                                     sortKey: .between(nil, nil)))
        }
        return id
    }

    func bodyDates(_ pageId: UUID) throws -> [DateMention] {
        try #require(try store.pageContent(pageId)).blocks.flatMap(\.text.runs).compactMap { run in
            if case .date(let date) = run.style { date } else { nil }
        }
    }

    // MARK: Шаблоны базы

    @Test("«+ Новый шаблон»: страница-шаблон базы, не строка таблицы, без номера ID; ⌘Z убирает, ⇧⌘Z возвращает")
    func newTemplate() throws {
        _ = try quiet.addProperty(to: tasks.databaseId, name: "ID", kind: .uniqueId)
        let row = try quiet.addRow(to: tasks.databaseId, in: tasks.viewId, title: "Строка")
        let id = try step { try operations.addRowTemplate(to: tasks.databaseId) }
        let template = try page(id)
        #expect(template.isTemplate && template.parentId == tasks.databaseId)
        #expect(try templates().templates.map(\.id) == [id])
        #expect(try templates().defaultTemplateId == nil, "по умолчанию — «Пустая»")
        #expect(try shownRows() == [row], "шаблон не виден строкой в таблице")
        let uniqueId = try #require(try read { try UniqueIds.property(ofDatabase: tasks.databaseId, in: $0) })
        #expect(try cell(id, uniqueId.id) == nil, "шаблону номер ID не выдаётся")

        undo.undo()
        #expect(try templates().templates.isEmpty)
        undo.redo()
        #expect(try templates().templates.map(\.id) == [id])
    }

    @Test("«Сделать по умолчанию»: метка у шаблона; «Пустая» снова по умолчанию; ⌘Z возвращает прежнее")
    func defaultTemplate() throws {
        let bugId = try makeBugTemplate()
        try step { try operations.setDefaultRowTemplate(bugId, of: tasks.databaseId) }
        #expect(try templates().defaultTemplateId == bugId)
        try step { try operations.setDefaultRowTemplate(nil, of: tasks.databaseId) }
        #expect(try templates().defaultTemplateId == nil)
        undo.undo()
        #expect(try templates().defaultTemplateId == bugId)
        undo.undo()
        #expect(try templates().defaultTemplateId == nil)
    }

    @Test("«Дублировать»: копия рядом со своими значениями, связями и телом, «Сегодня» остаётся относительным")
    func duplicateTemplate() throws {
        let bugId = try makeBugTemplate()
        let callId = try makeCallTemplate(relative: "today")
        let bugCopy = try step { try operations.duplicateRowTemplate(bugId) }
        let callCopy = try step { try operations.duplicateRowTemplate(callId) }
        #expect(try templates().templates.map(\.id) == [bugId, bugCopy, callId, callCopy])
        #expect(try page(bugCopy).isTemplate && page(bugCopy).title == "Баг (1)" && page(bugCopy).icon == "🐞")
        #expect(try cell(bugCopy, tag) == .string(bug.id.databaseText))
        #expect(try related(bugCopy) == [projectA])
        #expect(try cell(callCopy, due)?["relative"] == "today", "копия шаблона — тоже шаблон: дата не разрешается")
        #expect(try bodyDates(callCopy).first?.templateRelative == .today)
        undo.undo()
        undo.undo()
        #expect(try templates().templates.map(\.id) == [bugId, callId])
    }

    @Test("«Удалить»: шаблон в корзину; удалённый по умолчанию — «Пустая»; ⌘Z возвращает и метку")
    func deleteTemplate() throws {
        let bugId = try makeBugTemplate()
        try quiet.setDefaultRowTemplate(bugId, of: tasks.databaseId)
        try step { try operations.trashRowTemplate(bugId) }
        #expect(try page(bugId).trashedAt != nil)
        #expect(try templates().templates.isEmpty)
        #expect(try templates().defaultTemplateId == nil)
        let row = try quiet.addRow(to: tasks.databaseId, in: tasks.viewId, defaults: NewRowDefaults(), now: now)
        #expect(try cell(row, tag) == nil, "по шаблону в корзине строка не делается")
        undo.undo()
        #expect(try page(bugId).trashedAt == nil)
        #expect(try templates().defaultTemplateId == bugId)
    }

    // MARK: Строка по шаблону

    @Test("Строка по шаблону: значения, связи, иконка, обложка, вид, блоки и подстраница-копия; одним шагом ⌘Z")
    func rowFromTemplate() throws {
        let bugId = try makeBugTemplate()
        let row = try step { try operations.addRow(to: tasks.databaseId, in: tasks.viewId, at: .top, defaults: NewRowDefaults(), template: .template(bugId), now: now) }
        let created = try page(row)
        #expect(!created.isTemplate && created.parentId == tasks.databaseId)
        #expect(created.title == "Баг" && created.icon == "🐞" && created.isFullWidth)
        #expect(created.cover == PageCover(source: .gallery("gradient_1"), offset: 0.3))
        #expect(try cell(row, tag) == .string(bug.id.databaseText))
        #expect(try related(row) == [projectA])
        let content = try #require(try store.pageContent(row))
        #expect(content.blocks.map(\.kind) == [.checkbox, .pageLink])
        #expect(content.blocks.first?.text.string == "Повторить")
        let subpage = try #require(content.blocks.last?.linkedPageId)
        let subpagePage = try page(subpage)
        #expect(subpage != bugId && subpagePage.title == "Шаги" && subpagePage.parentId == row)
        #expect(try shownRows() == [row])

        undo.undo()
        #expect(try page(row).trashedAt != nil)
        #expect(try shownRows().isEmpty)
    }

    @Test("Шаблон по умолчанию: «Создать» и «+ Новая строка» делают строку по нему; «Пустая» — пустую")
    func defaultTemplateUsedByNewRows() throws {
        let bugId = try makeBugTemplate()
        try quiet.setDefaultRowTemplate(bugId, of: tasks.databaseId)
        let byDefault = try quiet.addRow(to: tasks.databaseId, in: tasks.viewId, at: .bottom, defaults: NewRowDefaults(), now: now)
        #expect(try page(byDefault).title == "Баг")
        #expect(try cell(byDefault, tag) == .string(bug.id.databaseText))
        let empty = try quiet.addRow(to: tasks.databaseId, in: tasks.viewId, at: .bottom, defaults: NewRowDefaults(), template: .empty, now: now)
        #expect(try page(empty).title.isEmpty)
        #expect(try cell(empty, tag) == nil)
        #expect(try store.pageContent(empty)?.blocks.map(\.kind) == [.paragraph])
    }

    @Test("«Сегодня» у даты и «@сегодня» в теле — день создания строки; «Сейчас» — день и время")
    func relativeDatesResolve() throws {
        let today = try makeCallTemplate(relative: "today")
        let row = try quiet.addRow(to: tasks.databaseId, in: tasks.viewId, defaults: NewRowDefaults(), template: .template(today), now: now)
        let value = try #require(try cell(row, due))
        #expect(value["start"] == "2026-11-03" && value["hasTime"] == false && value["relative"] == nil, "\(value)")
        let mention = try #require(try bodyDates(row).first)
        #expect(mention.start == "2026-11-03" && mention.templateRelative == nil)

        let moment = try makeCallTemplate(relative: "now")
        let timed = try quiet.addRow(to: tasks.databaseId, in: tasks.viewId, defaults: NewRowDefaults(), template: .template(moment), now: now)
        let timedValue = try #require(try cell(timed, due))
        #expect(timedValue["start"] == "2026-11-03T14:30" && timedValue["hasTime"] == true && timedValue["relative"] == nil, "\(timedValue)")
        #expect(try cell(today, due)?["relative"] == "today", "шаблон остаётся относительным")
    }

    @Test("Значения фильтра вида — поверх значений шаблона")
    func filterValuesOverTemplate() throws {
        let bugId = try makeBugTemplate()
        let defaults = NewRowDefaults(title: "Из фильтра", cells: [tag: .string(urgent.id.databaseText)])
        let row = try quiet.addRow(to: tasks.databaseId, in: tasks.viewId, defaults: defaults, template: .template(bugId), now: now)
        #expect(try cell(row, tag) == .string(urgent.id.databaseText))
        #expect(try page(row).title == "Из фильтра")
        #expect(try related(row) == [projectA], "остальное — из шаблона")
    }

    @Test("Правка шаблона не меняет строки, сделанные по нему раньше")
    func editingTemplateKeepsRows() throws {
        let bugId = try makeBugTemplate()
        let row = try quiet.addRow(to: tasks.databaseId, in: tasks.viewId, defaults: NewRowDefaults(), template: .template(bugId), now: now)
        try quiet.setCell(rowId: bugId, propertyId: tag, value: .string(urgent.id.databaseText))
        try quiet.setTitle(of: bugId, to: "Ошибка")
        try store.write { tx in
            let block = try #require(try tx.blocks(ofPage: bugId).first)
            var changed = block
            changed.text = InlineText("Иначе")
            try tx.updateBlock(changed)
        }
        #expect(try cell(row, tag) == .string(bug.id.databaseText))
        #expect(try page(row).title == "Баг")
        #expect(try store.pageContent(row)?.blocks.first?.text.string == "Повторить")
    }

    @Test("Шаблон на пустой странице строки: тело, иконка и значения; ⌘Z возвращает пустую строку")
    func applyToEmptyRow() throws {
        let bugId = try makeBugTemplate()
        let row = try quiet.addRow(to: tasks.databaseId, in: tasks.viewId, title: "Своё")
        try step { try operations.applyRowTemplate(bugId, toRow: row, now: now) }
        #expect(try page(row).title == "Своё", "название строки остаётся")
        #expect(try page(row).icon == "🐞")
        #expect(try cell(row, tag) == .string(bug.id.databaseText))
        #expect(try related(row) == [projectA])
        #expect(try store.pageContent(row)?.blocks.map(\.kind) == [.checkbox, .pageLink])

        undo.undo()
        #expect(try page(row).icon == nil)
        #expect(try cell(row, tag) == nil)
        #expect(try related(row).isEmpty)
        #expect(try store.pageContent(row)?.blocks.map(\.kind) == [.paragraph])
        #expect(try store.pageTree().children(of: row).isEmpty)
        #expect(try read { try $0.allPages() }.filter { $0.parentId == row }.isEmpty)
    }

    // MARK: Где шаблонов нет

    @Test("Шаблоны строк не в дереве (поиск страниц идёт по нему), не в разделе «Шаблоны» 003 и не в окне связи")
    func templatesHiddenElsewhere() throws {
        let bugId = try makeBugTemplate()
        let tree = try store.pageTree()
        #expect(tree.page(bugId) == nil)
        #expect(!tree.templates.map(\.id).contains(bugId))
        let backLink = try quiet.addRelation(to: projects.databaseId, name: "Задачи", target: tasks.databaseId)
        #expect(!(try RelationLinks.candidates(for: backLink, matching: "", in: store)).map(\.id).contains(bugId), "в окне связи шаблона нет")
    }

    // MARK: Копия базы

    @Test("Копия шаблонов в другую базу: свойства, варианты и строки по таблице замены, метка по умолчанию — на копию")
    func copyTemplatesToAnotherDatabase() throws {
        let bugId = try makeBugTemplate()
        try quiet.setDefaultRowTemplate(bugId, of: tasks.databaseId)
        let copy = try quiet.createDatabase(in: nil, isInline: false, title: "Задачи (копия)")
        let copyTag = try quiet.addProperty(to: copy.databaseId, name: "Тег", kind: .select).id
        let copyBug = try quiet.createOption(in: copyTag, named: "Баг", color: .red)
        let copyProject = try quiet.addRelation(to: copy.databaseId, name: "Проект", target: projects.databaseId).id
        let idMap: [UUID: UUID] = [tag: copyTag, bug.id: copyBug.id, project: copyProject]
        let copied = try store.write { tx in try RowTemplateCopier.copyTemplates(from: tasks.databaseId, to: copy.databaseId, idMap: idMap, in: tx) }
        let copyTemplate = try #require(copied[bugId])
        let list = try RowTemplates.list(of: copy.databaseId, in: store)
        #expect(list.templates.map(\.id) == [copyTemplate] && list.defaultTemplateId == copyTemplate)
        #expect(try page(copyTemplate).isTemplate && page(copyTemplate).title == "Баг" && page(copyTemplate).parentId == copy.databaseId)
        #expect(try cell(copyTemplate, copyTag) == .string(copyBug.id.databaseText))
        let relation = try #require(try read { try $0.property(copyProject) })
        #expect(try RelationLinks.related(copyTemplate, through: relation, in: store).map(\.id) == [projectA])
        #expect(try store.pageContent(copyTemplate)?.blocks.map(\.kind) == [.checkbox, .pageLink])
        #expect(try templates().templates.map(\.id) == [bugId], "у исходной базы шаблоны на месте")
    }
}
