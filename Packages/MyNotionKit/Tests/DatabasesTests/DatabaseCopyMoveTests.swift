import Foundation
import GRDB
import Testing
@testable import Databases
@testable import NotesCore

/// «Дублировать» и «Переместить» для баз (T102, spec Edge Cases): копия базы — схема, варианты, виды, строки со значениями
/// и номерами, шаблоны строк; связь копии с другой базой — односторонняя на те же строки, связь с собой — на строки
/// копии; страница со встроенной базой копируется с базой; ⌘Z стирает копию. Строка в другую базу — значения свойств
/// с тем же названием и типом переходят, остальные скрыты и возвращаются ⌘Z; страница в базу — строка с номером;
/// строка в обычную страницу — предупреждение. База из корзины возвращает связи.
@MainActor
@Suite("Базы: дублирование и перенос")
struct DatabaseCopyMoveTests {
    let folder: URL
    let store: NotesStore
    let undo = UndoManager()
    let quiet: DatabaseOperations
    let tree: PageTreeOperations
    let parent: UUID
    let tasks: CreatedDatabase
    let projects: CreatedDatabase
    let status: DatabaseProperty
    let note: DatabaseProperty
    let number: DatabaseProperty
    let project: DatabaseProperty
    let blocking: DatabaseProperty
    let summary: DatabaseProperty
    let done: SelectOption
    let task1: UUID, task2: UUID, template: UUID
    let projectA: UUID

    init() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("copy-move-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        store = NotesStore(database: try AppDatabase.open(at: folder.appendingPathComponent("MyNotion.sqlite")), clock: HybridLogicalClock(deviceId: UUID()))
        store.addWriteHook(CellIndexer())
        store.addWriteHook(ComputationHook(store: store, queue: nil))
        store.addTreeAddon(DatabaseTreeAddon())
        undo.groupsByEvent = false
        quiet = DatabaseOperations(store: store)
        tree = PageTreeOperations(store: store, undoManager: undo)

        parent = try store.write { try $0.createPage(title: "Работа").id }
        tasks = try quiet.createDatabase(in: parent, isInline: false, title: "Задачи")
        projects = try quiet.createDatabase(in: nil, isInline: false, title: "Проекты")
        projectA = try quiet.addRow(to: projects.databaseId, in: nil, title: "Дом")
        status = try quiet.addProperty(to: tasks.databaseId, name: "Статус", kind: .select)
        done = try quiet.createOption(in: status.id, named: "Готово", color: .green)
        note = try quiet.addProperty(to: tasks.databaseId, name: "Заметка", kind: .text)
        number = try quiet.addProperty(to: tasks.databaseId, name: "Номер", kind: .uniqueId)
        project = try quiet.addRelation(to: tasks.databaseId, name: "Проект", target: projects.databaseId, relatedName: "Задачи")
        blocking = try quiet.addRelation(to: tasks.databaseId, name: "Блокирует", target: tasks.databaseId)
        summary = try quiet.addProperty(to: tasks.databaseId, name: "Итог", kind: .formula)
        _ = try quiet.setFormula(summary.id, display: "prop(\"Статус\")")
        try quiet.setSorts([SortSpec(propertyId: status.id)], of: tasks.viewId)

        task1 = try quiet.addRow(to: tasks.databaseId, in: nil, title: "Позвонить")
        task2 = try quiet.addRow(to: tasks.databaseId, in: nil, title: "Купить")
        template = try quiet.addRow(to: tasks.databaseId, in: nil, title: "Шаблон задачи")
        try store.write { tx in
            var page = try #require(try tx.page(template))
            page.isTemplate = true
            try tx.updatePage(page)
        }
        try quiet.pickOption(done.id, rowId: task1, propertyId: status.id)
        try quiet.setCell(rowId: task1, propertyId: note.id, value: text("срочно"))
        try quiet.linkRow(task1, through: project.id, to: projectA)
        try quiet.linkRow(task1, through: blocking.id, to: task2)
    }

    func text(_ string: String) -> JSONValue { ["runs": [], "string": .string(string)] }

    func step(_ body: () throws -> Void) rethrows {
        undo.beginUndoGrouping()
        try body()
        undo.endUndoGrouping()
    }

    func asyncStep(_ body: () async throws -> Void) async rethrows {
        undo.beginUndoGrouping()
        try await body()
        undo.endUndoGrouping()
    }

    func read<T>(_ body: (NotesTransaction) throws -> T) throws -> T { try store.write { tx throws in try body(tx) } }

    func related(_ row: UUID, _ property: UUID, in databaseId: UUID) throws -> [String] {
        let catalog = try DatabaseCatalog.read(databaseId, in: store)
        return try RowWindowReader.read([row], catalog: catalog, store: store)[row]?.relations[property]?.map(\.title) ?? []
    }

    func children(_ pageId: UUID) throws -> [Page] {
        try read { tx in try tx.allPages().filter { $0.parentId == pageId && $0.trashedAt == nil }.sorted { $0.sortKey < $1.sortKey } }
    }

    func cell(_ row: UUID, _ property: UUID) throws -> JSONValue? { try read { try $0.cell(rowId: row, propertyId: property)?.value } }

    func property(named name: String, in databaseId: UUID) throws -> DatabaseProperty {
        try #require(try read { try $0.properties(ofDatabase: databaseId).first { $0.name == name } })
    }

    // MARK: Дублирование

    @Test("Копия базы: схема, варианты, виды и формула — со своими id; строки со значениями, номерами и шаблоном")
    func duplicateCopiesSchemaAndRows() async throws {
        var duplicated: Page?
        try await asyncStep { duplicated = try await tree.duplicate(tasks.databaseId) }
        let copy = try #require(duplicated)
        #expect(copy.title == "Задачи (1)")
        #expect(copy.parentId == parent)
        let schema = try #require(try read { try $0.database(copy.id) })
        #expect(!schema.isInline)

        let original = try read { try $0.properties(ofDatabase: tasks.databaseId) }
        let copied = try read { try $0.properties(ofDatabase: copy.id) }
        #expect(copied.map(\.name) == original.map(\.name))
        #expect(copied.map(\.kind) == original.map(\.kind))
        #expect(Set(copied.map(\.id)).isDisjoint(with: original.map(\.id)))

        let copyStatus = try property(named: "Статус", in: copy.id)
        let copyOptions = try read { try $0.options(ofProperty: copyStatus.id) }
        #expect(copyOptions.map(\.name) == ["Готово"])
        #expect(copyOptions.first?.optionColor == .green)
        #expect(copyOptions.first?.id != done.id)

        let views = try read { try $0.views(ofDatabase: copy.id) }
        #expect(views.count == 1)
        #expect(views.first?.sortSpecs.map(\.propertyId) == [copyStatus.id], "сортировка вида — по свойству копии")

        let copySummary = try property(named: "Итог", in: copy.id)
        #expect(copySummary.config["expression"]?.string?.contains(copyStatus.id.databaseText) == true, "формула — по свойству копии")

        let rows = try children(copy.id)
        #expect(rows.map(\.title) == ["Позвонить", "Купить", "Шаблон задачи"])
        #expect(rows.map(\.isTemplate) == [false, false, true])
        let copyTask1 = rows[0].id
        #expect(try cell(copyTask1, copyStatus.id) == .string(copyOptions[0].id.databaseText))
        #expect(try cell(copyTask1, try property(named: "Заметка", in: copy.id).id) == text("срочно"))
        let copyNumber = try property(named: "Номер", in: copy.id)
        #expect(try cell(copyTask1, copyNumber.id) == cell(task1, number.id), "номер строки — как у оригинала")
        #expect(try cell(rows[1].id, copyNumber.id) == cell(task2, number.id))
    }

    @Test("Связь копии с другой базой — односторонняя на те же строки; связь с собой — на строки копии; оригинал не тронут")
    func duplicateRelations() async throws {
        var duplicated: Page?
        try await asyncStep { duplicated = try await tree.duplicate(tasks.databaseId) }
        let copy = try #require(duplicated)
        let rows = try children(copy.id)
        let copyProject = try property(named: "Проект", in: copy.id)
        #expect(copyProject.relationTarget == projects.databaseId)
        #expect(copyProject.pairedRelation == nil, "копия связи — односторонняя")
        #expect(try related(rows[0].id, copyProject.id, in: copy.id) == ["Дом"])

        let copyBlocking = try property(named: "Блокирует", in: copy.id)
        #expect(copyBlocking.relationTarget == copy.id)
        #expect(try related(rows[0].id, copyBlocking.id, in: copy.id) == ["Купить"])
        let linked = try read { try $0.relationLinks(propertyId: copyBlocking.id, rowId: rows[0].id) }
        #expect(linked.map(\.targetRowId) == [rows[1].id], "связь с собой ведёт на строку копии")

        #expect(try read { try $0.properties(ofDatabase: projects.databaseId).map(\.name) } == ["Название", "Задачи"])
        let back = try property(named: "Задачи", in: projects.databaseId)
        #expect(try related(projectA, back.id, in: projects.databaseId) == ["Позвонить"], "у проекта — только оригинальная задача")
        #expect(try related(task1, project.id, in: tasks.databaseId) == ["Дом"])
        #expect(try related(task1, blocking.id, in: tasks.databaseId) == ["Купить"])
    }

    @Test("Страница со встроенной базой копируется вместе с базой; ⌘Z стирает копию вместе с записями базы")
    func duplicatePageWithInlineDatabase() async throws {
        let page = try store.write { try $0.createPage(title: "Дневник").id }
        let inline = try quiet.createDatabase(in: page, isInline: true, title: "Покупки",
                                              linkAt: .after(blockId: try read { try #require(try $0.blocks(ofPage: page).first).id }))
        let item = try quiet.addRow(to: inline.databaseId, in: nil, title: "Молоко")
        let price = try quiet.addProperty(to: inline.databaseId, name: "Цена", kind: .number)
        try quiet.setCell(rowId: item, propertyId: price.id, value: .number(90))

        var copy: Page?
        try await asyncStep { copy = try await tree.duplicate(page) }
        let copyPage = try #require(copy)
        let databaseBlock = try #require(try read { try $0.blocks(ofPage: copyPage.id) }.first { $0.kind == .database })
        let copyDatabase = try #require(databaseBlock.linkedPageId)
        #expect(copyDatabase != inline.databaseId)
        #expect(try read { try $0.database(copyDatabase) }?.isInline == true)
        let rows = try children(copyDatabase)
        #expect(rows.map(\.title) == ["Молоко"])
        #expect(try cell(rows[0].id, try property(named: "Цена", in: copyDatabase).id) == .number(90))

        undo.undo()
        #expect(try read { try $0.page(copyPage.id) } == nil)
        #expect(try read { try $0.database(copyDatabase) } == nil)
        #expect(try read { try $0.properties(ofDatabase: copyDatabase, includingDeleted: true) }.isEmpty)
    }

    /// Значение со ссылкой на удалённый вариант — так его может оставить правка с другого Mac.
    func pointAtDeletedOption(_ row: UUID) throws -> UUID {
        let cancelled = try quiet.createOption(in: status.id, named: "Отменено", color: .red)
        try quiet.deleteOption(cancelled.id)
        try store.write { try $0.setCell(rowId: row, propertyId: status.id, value: .string(cancelled.id.databaseText)) }
        return cancelled.id
    }

    @Test("Копия базы не ссылается на варианты оригинала, даже на удалённые")
    func duplicateDropsDeletedOptionValues() async throws {
        let cancelled = try pointAtDeletedOption(task2)
        var duplicated: Page?
        try await asyncStep { duplicated = try await tree.duplicate(tasks.databaseId) }
        let copy = try #require(duplicated)
        let copyStatus = try property(named: "Статус", in: copy.id)
        let originals: Set<JSONValue> = [.string(done.id.databaseText), .string(cancelled.databaseText)]
        let values = try children(copy.id).map { try cell($0.id, copyStatus.id) }
        #expect(values.compactMap { $0 }.count == 1, "у «Позвонить» — свой «Готово», у «Купить» — пусто")
        #expect(values.allSatisfy { $0.map { !originals.contains($0) } ?? true })
    }

    // MARK: Перенос

    @Test("Строка с удалённым вариантом в другую базу — пусто, чужой id не переходит")
    func moveRowWithDeletedOption() throws {
        _ = try pointAtDeletedOption(task2)
        let archive = try quiet.createDatabase(in: nil, isInline: false, title: "Архив")
        let archiveStatus = try quiet.addProperty(to: archive.databaseId, name: "Статус", kind: .select)
        try step { try tree.move(task2, toParent: archive.databaseId, at: .max) }
        #expect(try cell(task2, archiveStatus.id) == nil)
        #expect(try read { try $0.options(ofProperty: archiveStatus.id) }.isEmpty)
    }

    @Test("Строка возвращается в прежнюю базу — её прежние значения и связи там не затираются")
    func moveRowBackKeepsItsValues() throws {
        let garden = try quiet.addRow(to: projects.databaseId, in: nil, title: "Сад")
        let archive = try quiet.createDatabase(in: nil, isInline: false, title: "Архив")
        let archiveNote = try quiet.addProperty(to: archive.databaseId, name: "Заметка", kind: .text)
        let archiveProject = try quiet.addRelation(to: archive.databaseId, name: "Проект", target: projects.databaseId)
        try step { try tree.move(task1, toParent: archive.databaseId, at: .max) }
        #expect(try cell(task1, archiveNote.id) == text("срочно"))
        #expect(try related(task1, archiveProject.id, in: archive.databaseId) == ["Дом"])

        try quiet.setCell(rowId: task1, propertyId: archiveNote.id, value: text("в архиве"))
        try quiet.unlinkRow(task1, through: archiveProject.id, from: projectA)
        try quiet.linkRow(task1, through: archiveProject.id, to: garden)
        try step { try tree.move(task1, toParent: tasks.databaseId, at: .max) }
        #expect(try cell(task1, note.id) == text("срочно"))
        #expect(try related(task1, project.id, in: tasks.databaseId) == ["Дом"])
    }

    @Test("Строка в другую базу: то же название и тип — значение переходит (вариант по названию), остальное скрыто; ⌘Z — как было")
    func moveRowToOtherDatabase() throws {
        let archive = try quiet.createDatabase(in: nil, isInline: false, title: "Архив")
        let archiveStatus = try quiet.addProperty(to: archive.databaseId, name: "Статус", kind: .select)
        let archiveNote = try quiet.addProperty(to: archive.databaseId, name: "Заметка", kind: .number)
        let archiveNumber = try quiet.addProperty(to: archive.databaseId, name: "Номер", kind: .uniqueId)
        let old = try quiet.addRow(to: archive.databaseId, in: nil, title: "Старое")

        try step { try tree.move(task1, toParent: archive.databaseId, at: .max) }
        #expect(try read { try $0.page(task1) }?.parentId == archive.databaseId)
        let options = try read { try $0.options(ofProperty: archiveStatus.id) }
        #expect(options.map(\.name) == ["Готово"], "варианта не было — создан с тем же названием")
        #expect(try cell(task1, archiveStatus.id) == .string(options[0].id.databaseText))
        #expect(try cell(task1, archiveNote.id) == nil, "тот же заголовок, другой тип — значение не переходит")
        #expect(try cell(task1, archiveNumber.id) == .number(2), "номер — следующий в новой базе")
        #expect(try cell(old, archiveNumber.id) == .number(1))

        undo.undo()
        #expect(try read { try $0.page(task1) }?.parentId == tasks.databaseId)
        #expect(try cell(task1, status.id) == .string(done.id.databaseText))
        #expect(try cell(task1, note.id) == text("срочно"))
        #expect(try related(task1, project.id, in: tasks.databaseId) == ["Дом"])
    }

    @Test("Страница в базу — строка с пустыми свойствами и номером; строка в обычную страницу — предупреждение")
    func movePageIntoDatabaseAndRowOut() throws {
        let loose = try store.write { try $0.createPage(title: "Идея").id }
        #expect(try !DatabaseTreeAddon.movingLosesProperties(loose, to: tasks.databaseId, in: store))
        try step { try tree.move(loose, toParent: tasks.databaseId, at: .max) }
        #expect(try cell(loose, number.id) == .number(4), "после трёх строк базы, шаблон тоже считается")
        #expect(try cell(loose, status.id) == nil)

        #expect(try DatabaseTreeAddon.movingLosesProperties(task1, to: parent, in: store))
        #expect(try DatabaseTreeAddon.movingLosesProperties(task1, to: nil, in: store))
        #expect(try !DatabaseTreeAddon.movingLosesProperties(task1, to: projects.databaseId, in: store))
    }

    @Test("База из корзины возвращается со связями")
    func trashedDatabaseKeepsRelations() throws {
        try step { try tree.moveToTrash(projects.databaseId) }
        #expect(try related(task1, project.id, in: tasks.databaseId).isEmpty)
        try step { try tree.restore(projects.databaseId) }
        #expect(try related(task1, project.id, in: tasks.databaseId) == ["Дом"])
        let back = try property(named: "Задачи", in: projects.databaseId)
        #expect(try related(projectA, back.id, in: projects.databaseId) == ["Позвонить"])
    }
}
