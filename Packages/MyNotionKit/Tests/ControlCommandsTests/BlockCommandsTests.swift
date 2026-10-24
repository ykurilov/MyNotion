import ControlProtocol
import Foundation
import Testing
@testable import ControlCommands
@testable import NotesCore

/// Команды блоков на настоящем хранилище и открытых документах (US2, FR-416): запись доходит до базы до ответа,
/// страница в окне видит правку, пакет и отмена откатывают всё одним шагом.
@MainActor @Suite struct BlockCommandsTests {
    let host: TestHost
    let executor: CommandExecutor
    let page: Page
    let ids: [UUID]

    init() throws {
        host = try TestHost()
        executor = CommandExecutor(host: host, log: RecordingLog())
        page = try host.page("Заметки", texts: ["один", "два", "три"])
        ids = try host.store.pageContent(page.id)?.blocks.map(\.id) ?? []
    }

    // MARK: Помощники

    @discardableResult
    func run(_ command: String, _ args: [String: ControlJSON] = [:]) async -> ControlResponse {
        await executor.run(ControlRequest(command: command, args: args))
    }

    func stored(_ pageId: UUID? = nil) throws -> [Block] {
        try host.store.pageContent(pageId ?? page.id)?.blocks.filter { $0.containerId == nil } ?? []
    }

    /// «отступ:вид:текст» блоков потока страницы.
    func outline(_ pageId: UUID? = nil) throws -> [String] {
        try stored(pageId).map { "\($0.indent):\($0.kind.rawValue):\($0.text.string)" }
    }

    /// Страница с блоками заданных видов, текстов и вложенности.
    func makePage(_ title: String, _ specs: [(BlockKind, String, Int)]) throws -> (page: Page, ids: [UUID]) {
        let created = try host.page(title)
        try host.store.write { tx in
            for block in try tx.blocks(ofPage: created.id) { try tx.deleteBlock(block.id) }
            var key: FractionalSortKey?
            for (kind, text, indent) in specs {
                key = .between(key, nil)
                try tx.insertBlock(Block(pageId: created.id, kind: kind, text: InlineText(text), indent: indent, sortKey: key!))
            }
        }
        return (created, try stored(created.id).map(\.id))
    }

    /// А с двумя вложенными, Б с одним вложенным, В.
    func nestedPage() throws -> (page: Page, ids: [UUID]) {
        try makePage("Вложенные", [(.bulletItem, "А", 0), (.bulletItem, "а1", 1), (.bulletItem, "а2", 1), (.bulletItem, "Б", 0),
                                   (.bulletItem, "б1", 1), (.paragraph, "В", 0)])
    }

    func id(_ block: UUID) -> ControlJSON { .string(block.controlText) }

    func expectError(_ response: ControlResponse, _ code: ControlErrorCode) {
        #expect(!response.ok)
        #expect(response.error?.code == code, "Получили \(response.error?.code.rawValue ?? "успех"): \(response.error?.message ?? "")")
    }

    // MARK: Виды

    @Test func kindsListsEveryInsertableKindWithProps() async throws {
        let response = await run("block.kinds")
        #expect(response.ok)
        let kinds = response.data?["kinds"]?.array ?? []
        #expect(Set(kinds.compactMap { $0["kind"]?.string }) == Set(CommandCatalog.insertableBlockKinds))
        let callout = kinds.first { $0["kind"] == "callout" }
        #expect(callout?["props"]?.array?.contains("icon") == true)
        #expect(kinds.first { $0["kind"] == "code" }?["props"]?.array?.contains("language") == true)
        #expect(kinds.first { $0["kind"] == "divider" }?["hasText"] == false)
        #expect(kinds.first { $0["kind"] == "checkbox" }?["hasText"] == true)
        #expect(kinds.allSatisfy { $0["summary"]?.string?.isEmpty == false })
    }

    @Test func getReturnsBlockWithRichTextAndPage() async throws {
        let response = await run("block.get", ["block": id(ids[1])])
        #expect(response.ok)
        #expect(response.data?["block"]?["id"] == id(ids[1]))
        #expect(response.data?["block"]?["text"] == "два")
        #expect(response.data?["block"]?["rich"]?["string"] == "два")
        #expect(response.data?["pageId"] == .string(page.id.controlText))
    }

    @Test func getUnknownBlockFails() async throws {
        expectError(await run("block.get", ["block": id(UUID())]), .blockNotFound)
        expectError(await run("block.get", ["block": "не-id"]), .invalidValue)
    }

    // MARK: Вставка

    /// Аргументы вставки вида: тексту — слова, ссылке на страницу — название подстраницы, файлам — адрес.
    func insertArguments(_ kind: String) -> [String: ControlJSON] {
        var args: [String: ControlJSON] = ["page": .string(page.id.controlText), "kind": .string(kind), "last": true]
        switch kind {
        case "divider", "tableOfContents", "columnList", "table": break
        case "image", "file", "video", "bookmark": args["props"] = ["url": "https://example.com/a"]
        default: args["text"] = "Проба"
        }
        return args
    }

    @Test(arguments: CommandCatalog.insertableBlockKinds.filter { $0 != "database" })
    func insertsEveryKind(_ kind: String) async throws {
        let response = await run("block.insert", insertArguments(kind))
        #expect(response.ok, "\(kind): \(response.error?.message ?? "")")
        let inserted = try #require(try stored().last)
        #expect(inserted.kind.rawValue == kind)
        #expect(response.data?["block"]?["id"] == id(inserted.id))
        #expect(response.data?["block"]?["kind"] == .string(kind))
        #expect(try stored().count == 4)
        switch kind {
        case "pageLink":
            let linked = try #require(inserted.linkedPageId)
            #expect(try host.stored(linked)?.title == "Проба")
            #expect(try host.stored(linked)?.parentId == page.id)
        case "divider", "tableOfContents", "columnList", "table", "image", "file", "video", "bookmark":
            break
        default:
            #expect(inserted.text.string == "Проба")
        }
    }

    @Test func insertDatabaseIsRedirectedToDbCreate() async throws {
        let response = await run("block.insert", ["page": .string(page.id.controlText), "kind": "database"])
        expectError(response, .invalidArgument)
        #expect(response.error?.hint?.contains("db create") == true)
        #expect(try stored().count == 3)
    }

    @Test func insertWithoutPlaceGoesToTheEnd() async throws {
        let response = await run("block.insert", ["page": .string(page.id.controlText), "kind": "paragraph", "text": "конец"])
        #expect(response.ok)
        #expect(try outline() == ["0:paragraph:один", "0:paragraph:два", "0:paragraph:три", "0:paragraph:конец"])
    }

    @Test func insertFirstAfterAndLast() async throws {
        let pageId = JSONArgument.page(page)
        await run("block.insert", pageId + ["kind": "checkbox", "text": "в начало", "first": true])
        await run("block.insert", pageId + ["kind": "checkbox", "text": "после двух", "after": id(ids[1])])
        await run("block.insert", pageId + ["kind": "quote", "text": "в конец", "last": true])
        #expect(try outline() == ["0:checkbox:в начало", "0:paragraph:один", "0:paragraph:два", "0:checkbox:после двух",
                                  "0:paragraph:три", "0:quote:в конец"])
    }

    @Test func insertAfterBlockWithNestedItemsGoesBelowThem() async throws {
        let (nested, nestedIds) = try nestedPage()
        let response = await run("block.insert", JSONArgument.page(nested) + ["kind": "bulletItem", "text": "новый", "after": id(nestedIds[0])])
        #expect(response.ok)
        #expect(try outline(nested.id) == ["0:bulletItem:А", "1:bulletItem:а1", "1:bulletItem:а2", "0:bulletItem:новый", "0:bulletItem:Б",
                                           "1:bulletItem:б1", "0:paragraph:В"])
    }

    @Test func insertAfterNestedItemKeepsItsLevel() async throws {
        let (nested, nestedIds) = try nestedPage()
        await run("block.insert", JSONArgument.page(nested) + ["kind": "bulletItem", "text": "а1.5", "after": id(nestedIds[1])])
        #expect(try outline(nested.id).prefix(4) == ["0:bulletItem:А", "1:bulletItem:а1", "1:bulletItem:а1.5", "1:bulletItem:а2"])
    }

    @Test func insertInsideGoesLastAmongChildren() async throws {
        let (nested, nestedIds) = try nestedPage()
        let response = await run("block.insert", JSONArgument.page(nested) + ["kind": "checkbox", "text": "ещё один", "inside": id(nestedIds[0])])
        #expect(response.ok)
        #expect(try outline(nested.id).prefix(5) == ["0:bulletItem:А", "1:bulletItem:а1", "1:bulletItem:а2", "1:checkbox:ещё один",
                                                      "0:bulletItem:Б"])
    }

    @Test func insertInsideToggleAndOutsideParagraph() async throws {
        let (withToggle, toggleIds) = try makePage("С переключателем", [(.toggle, "список", 0), (.paragraph, "рядом", 0)])
        await run("block.insert", JSONArgument.page(withToggle) + ["kind": "paragraph", "text": "внутри", "inside": id(toggleIds[0])])
        #expect(try outline(withToggle.id) == ["0:toggle:список", "1:paragraph:внутри", "0:paragraph:рядом"])

        let response = await run("block.insert", JSONArgument.page(page) + ["kind": "paragraph", "inside": id(ids[0])])
        expectError(response, .invalidArgument)
        #expect(response.error?.message.contains("внутрь") == true)
    }

    @Test func insertHeadingInsideBulletKeepsLevelZero() async throws {
        let (nested, nestedIds) = try nestedPage()
        await run("block.insert", JSONArgument.page(nested) + ["kind": "heading2", "text": "Заголовок", "inside": id(nestedIds[0])])
        #expect(try outline(nested.id).prefix(4) == ["0:bulletItem:А", "1:bulletItem:а1", "1:bulletItem:а2", "0:heading2:Заголовок"])
    }

    @Test func insertInsideColumn() async throws {
        await run("block.insert", JSONArgument.page(page) + ["kind": "columnList", "props": ["columns": 3], "last": true])
        let content = try #require(try host.store.pageContent(page.id))
        let list = try #require(content.blocks.first { $0.kind == .columnList })
        let columns = content.blocks.filter { $0.containerId == list.id }.sorted { $0.sortKey < $1.sortKey }
        try #require(columns.count == 3)
        #expect(columns.allSatisfy { $0.kind == .column })
        let response = await run("block.insert", JSONArgument.page(page) + ["kind": "paragraph", "text": "в колонке", "inside": id(columns[1].id)])
        #expect(response.ok)
        let after = try #require(try host.store.pageContent(page.id))
        #expect(after.blocks.filter { $0.containerId == columns[1].id }.map(\.text.string).contains("в колонке"))
        #expect(try stored().count == 4, "Страница видит только колонки: блок внутри не попал в поток страницы")
    }

    @Test func insertTableFromRows() async throws {
        let response = await run("block.insert", JSONArgument.page(page) + [
            "kind": "table", "props": ["rows": [["Имя", "Возраст"], ["Аня", "7"], ["Миша", "9"]], "hasHeaderRow": true], "last": true,
        ])
        #expect(response.ok)
        let content = try #require(try host.store.pageContent(page.id))
        let table = try #require(content.blocks.first { $0.kind == .table })
        #expect(table.props.hasHeaderRow == true)
        let inside = content.blocks.filter { $0.containerId == table.id }
        #expect(inside.filter { $0.kind == .tableColumn }.count == 2)
        #expect(inside.filter { $0.kind == .tableRow }.count == 3)
        let grid = TableGrid(table: table) { containerId in
            content.blocks.filter { $0.containerId == containerId }.sorted { $0.sortKey < $1.sortKey }
        }
        #expect(grid.cell(row: 2, column: 0)?.text.string == "Миша")
        #expect(grid.cell(row: 0, column: 1)?.text.string == "Возраст")
    }

    @Test func insertColumnListDefaultsToTwoColumns() async throws {
        await run("block.insert", JSONArgument.page(page) + ["kind": "columnList", "last": true])
        let content = try #require(try host.store.pageContent(page.id))
        let list = try #require(content.blocks.first { $0.kind == .columnList })
        #expect(content.blocks.filter { $0.containerId == list.id }.count == 2)
        let tooMany = await run("block.insert", JSONArgument.page(page) + ["kind": "columnList", "props": ["columns": 9]])
        expectError(tooMany, .invalidValue)
    }

    @Test func insertTextAsMarkdownKeepsStyle() async throws {
        await run("block.insert", JSONArgument.page(page) + ["kind": "checkbox", "text": "Купить **молоко**", "last": true])
        let inserted = try #require(try stored().last)
        #expect(inserted.text.string == "Купить молоко")
        #expect(inserted.text.runs.contains { $0.style == .bold && $0.start == 7 && $0.length == 6 })
    }

    @Test func insertRichTextIsExact() async throws {
        let rich: ControlJSON = ["string": "Купить молоко", "runs": [["from": 7, "to": 13, "style": "italic"]]]
        let response = await run("block.insert", JSONArgument.page(page) + ["kind": "paragraph", "rich": rich, "last": true])
        #expect(response.ok)
        let inserted = try #require(try stored().last)
        #expect(inserted.text.runs.map(\.style) == [.italic])
        let bad = await run("block.insert", JSONArgument.page(page) + ["kind": "paragraph", "rich": ["string": "а", "runs": [["from": 0, "to": 5, "style": "bold"]]]])
        expectError(bad, .invalidValue)
    }

    @Test func insertPropsForKind() async throws {
        await run("block.insert", JSONArgument.page(page) + ["kind": "callout", "text": "Итог", "props": ["icon": "🔥"], "last": true])
        await run("block.insert", JSONArgument.page(page) + ["kind": "code", "text": "let x = 1", "props": ["language": "swift"], "last": true])
        let blocks = try stored()
        try #require(blocks.count == 5)
        #expect(blocks[3].props.icon == "🔥")
        #expect(blocks[4].props.language == "swift")
        #expect(blocks[4].text.string == "let x = 1")
    }

    @Test func insertCodeKeepsMarkdownCharactersAsText() async throws {
        await run("block.insert", JSONArgument.page(page) + ["kind": "code", "text": "a **b** c", "last": true])
        #expect(try stored().last?.text.string == "a **b** c")
    }

    @Test func insertNeedsExistingPageAndMatchingBlockPage() async throws {
        expectError(await run("block.insert", ["page": "Нет такой", "kind": "paragraph"]), .pageNotFound)
        let other = try host.page("Другая", texts: ["чужой"])
        let foreign = try #require(try host.store.pageContent(other.id)?.blocks.first)
        let response = await run("block.insert", JSONArgument.page(page) + ["kind": "paragraph", "after": id(foreign.id)])
        expectError(response, .wrongPage)
        #expect(try stored().count == 3)
    }

    @Test func insertUnknownAndInternalKindsAreRejectedWithList() async throws {
        for kind in ["колбаса", "tableRow", "tableCell", "column"] {
            let response = await run("block.insert", JSONArgument.page(page) + ["kind": .string(kind)])
            expectError(response, .invalidValue)
            let allowed = response.error?.details?["allowed"]?.array?.compactMap(\.string) ?? []
            #expect(allowed == CommandCatalog.insertableBlockKinds, "\(kind): в ответе полный список видов")
        }
        #expect(try stored().count == 3)
    }

    @Test func insertIntoTrashedPageFails() async throws {
        let trashed = try host.page("В корзине", texts: ["а"])
        let now = host.now
        try host.store.write { tx in
            var page = try #require(try tx.page(trashed.id))
            page.trashedAt = now
            try tx.updatePage(page)
        }
        expectError(await run("block.insert", JSONArgument.page(trashed) + ["kind": "paragraph"]), .pageInTrash)
    }

    // MARK: Правка

    @Test func updateTextFromMarkdown() async throws {
        let response = await run("block.update", ["block": id(ids[1]), "text": "новый *текст*"])
        #expect(response.ok)
        let block = try #require(try host.store.block(ids[1]))
        #expect(block.text.string == "новый текст")
        #expect(block.text.runs.contains { $0.style == .italic })
        #expect(response.data?["block"]?["text"] == "новый *текст*")
    }

    @Test func updateTextFromRich() async throws {
        let rich: ControlJSON = ["string": "жирный", "runs": [["from": 0, "to": 6, "style": "bold"]]]
        await run("block.update", ["block": id(ids[0]), "rich": rich])
        let block = try #require(try host.store.block(ids[0]))
        #expect(block.text.string == "жирный")
        #expect(block.text.runs.map(\.style) == [.bold])
    }

    @Test func updatePropsMergeWithExisting() async throws {
        await run("block.insert", JSONArgument.page(page) + ["kind": "callout", "text": "Итог", "props": ["icon": "🔥"], "last": true])
        let callout = try #require(try stored().last)
        await run("block.update", ["block": id(callout.id), "props": ["icon": "✅", "extra": 1]])
        var updated = try #require(try host.store.block(callout.id))
        #expect(updated.props.icon == "✅")
        #expect(updated.props.values["extra"]?.number == 1)
        await run("block.update", ["block": id(callout.id), "props": ["extra": .null]])
        updated = try #require(try host.store.block(callout.id))
        #expect(updated.props.values["extra"] == nil, "null убирает свойство")
        #expect(updated.props.icon == "✅")
    }

    @Test func updateKindKeepsTextAndFollowsWindowRules() async throws {
        await run("block.update", ["block": id(ids[0]), "kind": "heading2"])
        await run("block.update", ["block": id(ids[1]), "kind": "checkbox"])
        await run("block.update", ["block": id(ids[2]), "kind": "callout"])
        #expect(try outline() == ["0:heading2:один", "0:checkbox:два", "0:callout:три"])
        #expect(try host.store.block(ids[2])?.props.icon == "💡", "Выноска получает иконку по умолчанию")
    }

    @Test func updateKindToHeadingDropsIllegalNesting() async throws {
        let (nested, nestedIds) = try nestedPage()
        await run("block.update", ["block": id(nestedIds[1]), "kind": "heading3"])
        #expect(try outline(nested.id).prefix(3) == ["0:bulletItem:А", "0:heading3:а1", "1:bulletItem:а2"])
    }

    @Test func updateKindFromCheckedCheckboxClearsMark() async throws {
        let (tasks, taskIds) = try makePage("Задачи", [(.checkbox, "сделать", 0)])
        await run("block.check", ["block": id(taskIds[0])])
        await run("block.update", ["block": id(taskIds[0]), "kind": "paragraph"])
        #expect(try host.store.block(taskIds[0])?.isChecked == false)
        #expect(try outline(tasks.id) == ["0:paragraph:сделать"])
    }

    @Test func updateKindRejectsKindsThatCannotBeTurnedInto() async throws {
        let response = await run("block.update", ["block": id(ids[0]), "kind": "table"])
        expectError(response, .invalidArgument)
        #expect(try outline().first == "0:paragraph:один")
        await run("block.insert", JSONArgument.page(page) + ["kind": "table", "last": true])
        let table = try #require(try stored().last)
        expectError(await run("block.update", ["block": id(table.id), "kind": "paragraph"]), .invalidArgument)
    }

    @Test func updateNeedsSomethingToChange() async throws {
        expectError(await run("block.update", ["block": id(ids[0])]), .missingArgument)
        expectError(await run("block.update", ["block": id(ids[0]), "text": "а", "rich": ["string": "б"]]), .invalidArgument)
    }

    @Test func updateUnknownBlockFails() async throws {
        expectError(await run("block.update", ["block": id(UUID()), "text": "а"]), .blockNotFound)
    }

    // MARK: Перенос

    @Test func moveCarriesNestedItems() async throws {
        let (nested, nestedIds) = try nestedPage()
        let response = await run("block.move", ["block": id(nestedIds[0]), "after": id(nestedIds[5])])
        #expect(response.ok)
        #expect(try outline(nested.id) == ["0:bulletItem:Б", "1:bulletItem:б1", "0:paragraph:В", "0:bulletItem:А", "1:bulletItem:а1",
                                           "1:bulletItem:а2"])
    }

    @Test func moveFirstAndLast() async throws {
        let (nested, nestedIds) = try nestedPage()
        await run("block.move", ["block": id(nestedIds[3]), "first": true])
        #expect(try outline(nested.id).prefix(3) == ["0:bulletItem:Б", "1:bulletItem:б1", "0:bulletItem:А"])
        await run("block.move", ["block": id(nestedIds[3]), "last": true])
        #expect(try outline(nested.id) == ["0:bulletItem:А", "1:bulletItem:а1", "1:bulletItem:а2", "0:paragraph:В", "0:bulletItem:Б",
                                           "1:bulletItem:б1"])
    }

    @Test func moveNestedItemUnderNewNeighbourTakesItsLevel() async throws {
        let (nested, nestedIds) = try nestedPage()
        await run("block.move", ["block": id(nestedIds[1]), "after": id(nestedIds[5])])
        #expect(try outline(nested.id) == ["0:bulletItem:А", "1:bulletItem:а2", "0:bulletItem:Б", "1:bulletItem:б1", "0:paragraph:В",
                                           "0:bulletItem:а1"])
    }

    @Test func moveBesideItselfOrIntoOwnNestedFails() async throws {
        let (nested, nestedIds) = try nestedPage()
        expectError(await run("block.move", ["block": id(nestedIds[0]), "after": id(nestedIds[0])]), .invalidArgument)
        expectError(await run("block.move", ["block": id(nestedIds[0]), "after": id(nestedIds[2])]), .invalidArgument)
        #expect(try outline(nested.id).first == "0:bulletItem:А")
    }

    @Test func moveAfterBlockOfAnotherPageFails() async throws {
        let other = try host.page("Другая", texts: ["чужой"])
        let foreign = try #require(try host.store.pageContent(other.id)?.blocks.first)
        expectError(await run("block.move", ["block": id(ids[0]), "after": id(foreign.id)]), .wrongPage)
    }

    @Test func moveNeedsPlace() async throws {
        expectError(await run("block.move", ["block": id(ids[0])]), .missingArgument)
    }

    // MARK: Отступ

    @Test func indentAndOutdentFollowWindowRules() async throws {
        let response = await run("block.indent", ["block": id(ids[1])])
        #expect(response.ok)
        #expect(response.data?["changed"] == false)
        #expect(try outline() == ["0:paragraph:один", "0:paragraph:два", "0:paragraph:три"],
                "Под абзац вкладывать нельзя: окно тоже не вкладывает")
        #expect(response.data?["block"]?["indent"] == 0)

        let (list, listIds) = try makePage("Список", [(.bulletItem, "один", 0), (.bulletItem, "два", 0), (.checkbox, "три", 0)])
        await run("block.indent", ["block": id(listIds[1])])
        await run("block.indent", ["block": id(listIds[1])])
        #expect(try stored(list.id).map(\.indent) == [0, 1, 0], "Глубже соседа сверху + 1 не вкладывается")
        await run("block.indent", ["block": id(listIds[2])])
        await run("block.indent", ["block": id(listIds[2])])
        #expect(try stored(list.id).map(\.indent) == [0, 1, 2])
        await run("block.outdent", ["block": id(listIds[2])])
        #expect(try stored(list.id).map(\.indent) == [0, 1, 1])
    }

    @Test func indentCarriesNestedItems() async throws {
        let (nested, nestedIds) = try nestedPage()
        await run("block.indent", ["block": id(nestedIds[3])])
        #expect(try stored(nested.id).map(\.indent) == [0, 1, 1, 1, 2, 0])
        await run("block.outdent", ["block": id(nestedIds[3])])
        #expect(try stored(nested.id).map(\.indent) == [0, 1, 1, 0, 1, 0])
    }

    @Test func indentNoOpReportsUnchanged() async throws {
        let first = await run("block.indent", ["block": id(ids[0])])
        #expect(first.ok)
        #expect(first.data?["changed"] == false)
        let top = await run("block.outdent", ["block": id(ids[0])])
        #expect(top.ok)
        #expect(top.data?["changed"] == false)
    }

    @Test func headingIndentsOnlyInsideContainers() async throws {
        let (plain, plainIds) = try makePage("Пункт и заголовок", [(.bulletItem, "пункт", 0), (.heading2, "Заголовок", 0)])
        let refused = await run("block.indent", ["block": id(plainIds[1])])
        #expect(refused.data?["changed"] == false)
        #expect(try stored(plain.id).map(\.indent) == [0, 0])

        let (inToggle, toggleIds) = try makePage("Переключатель и заголовок", [(.toggle, "список", 0), (.heading2, "Заголовок", 0)])
        await run("block.indent", ["block": id(toggleIds[1])])
        #expect(try stored(inToggle.id).map(\.indent) == [0, 1])
    }

    @Test func indentStopsAtEight() async throws {
        var chain: [(BlockKind, String, Int)] = (0...8).map { (BlockKind.bulletItem, "пункт \($0)", $0) }
        chain.append((.bulletItem, "последний", 8))
        let (deep, deepIds) = try makePage("Глубокий", chain)
        let response = await run("block.indent", ["block": id(deepIds[9])])
        #expect(response.data?["changed"] == false)
        #expect(try stored(deep.id).last?.indent == 8)
        await run("block.outdent", ["block": id(deepIds[9])])
        #expect(try stored(deep.id).last?.indent == 7)
        await run("block.indent", ["block": id(deepIds[9])])
        #expect(try stored(deep.id).last?.indent == 8)
    }

    // MARK: Отметка и раскрытие

    @Test func checkAndUncheck() async throws {
        let (tasks, taskIds) = try makePage("Задачи", [(.checkbox, "молоко", 0), (.checkbox, "хлеб", 0)])
        let checked = await run("block.check", ["block": id(taskIds[0])])
        #expect(checked.ok)
        #expect(checked.data?["block"]?["checked"] == true)
        #expect(try stored(tasks.id).map(\.isChecked) == [true, false])
        await run("block.check", ["block": id(taskIds[0])])
        #expect(try stored(tasks.id).map(\.isChecked) == [true, false], "Повторная отметка ничего не ломает")
        await run("block.uncheck", ["block": id(taskIds[0])])
        #expect(try stored(tasks.id).map(\.isChecked) == [false, false])
    }

    @Test func checkNeedsCheckbox() async throws {
        let response = await run("block.check", ["block": id(ids[0])])
        expectError(response, .invalidArgument)
        #expect(response.error?.message.contains("задач") == true || response.error?.message.contains("чекбокс") == true)
    }

    @Test func expandAndCollapseToggle() async throws {
        let (withToggle, toggleIds) = try makePage("Переключатель", [(.toggle, "список", 0), (.paragraph, "внутри", 1)])
        let viewState = BlockViewStateStore(database: host.store.database)
        let collapsed = await run("block.collapse", ["block": id(toggleIds[0])])
        #expect(collapsed.ok)
        #expect(collapsed.data?["collapsed"] == true)
        #expect(try viewState.collapsedBlockIds(ofPage: withToggle.id) == [toggleIds[0]])
        let expanded = await run("block.expand", ["block": id(toggleIds[0])])
        #expect(expanded.data?["collapsed"] == false)
        #expect(try viewState.collapsedBlockIds(ofPage: withToggle.id).isEmpty)
    }

    @Test func expandNeedsToggle() async throws {
        expectError(await run("block.expand", ["block": id(ids[0])]), .invalidArgument)
        expectError(await run("block.collapse", ["block": id(ids[0])]), .invalidArgument)
    }

    // MARK: Удаление

    @Test func deleteTakesNestedItemsAlong() async throws {
        let (nested, nestedIds) = try nestedPage()
        let response = await run("block.delete", ["block": id(nestedIds[0])])
        #expect(response.ok)
        #expect(response.data?["deleted"]?.array?.count == 3)
        #expect(try outline(nested.id) == ["0:bulletItem:Б", "1:bulletItem:б1", "0:paragraph:В"])
        #expect(try host.store.block(nestedIds[1]) == nil)
    }

    @Test func deleteLastBlockLeavesEmptyParagraph() async throws {
        let (single, singleIds) = try makePage("Одинокая", [(.heading1, "Единственный", 0)])
        let response = await run("block.delete", ["block": id(singleIds[0])])
        #expect(response.ok)
        #expect(try outline(single.id) == ["0:paragraph:"])
    }

    @Test func deleteContainerRemovesItsContents() async throws {
        await run("block.insert", JSONArgument.page(page) + ["kind": "columnList", "last": true])
        let before = try #require(try host.store.pageContent(page.id)?.blocks.count)
        let list = try #require(try stored().last)
        await run("block.delete", ["block": id(list.id)])
        let after = try #require(try host.store.pageContent(page.id))
        #expect(after.blocks.count == 3, "Колонки и их содержимое ушли вместе с блоком (было \(before))")
    }

    // MARK: На другую страницу

    @Test func moveToPageCarriesNestedItemsToTheEnd() async throws {
        let (nested, nestedIds) = try nestedPage()
        let target = try host.page("Архив", texts: ["старое"])
        let response = await run("block.move-to-page", ["block": id(nestedIds[0]), "page": "Архив"])
        #expect(response.ok)
        #expect(response.data?["pageId"] == .string(target.id.controlText))
        #expect(response.data?["moved"]?.array?.count == 3)
        #expect(try outline(nested.id) == ["0:bulletItem:Б", "1:bulletItem:б1", "0:paragraph:В"])
        #expect(try outline(target.id) == ["0:paragraph:старое", "0:bulletItem:А", "1:bulletItem:а1", "1:bulletItem:а2"])
        let newIds = response.data?["moved"]?.array?.compactMap { $0.string.flatMap(UUID.init) } ?? []
        #expect(Set(newIds) == Set(try stored(target.id).dropFirst().map(\.id)), "В ответе — новые id перенесённых блоков")
        #expect(host.directWrites.contains { $0.contains(target.id) && $0.contains(nested.id) })
    }

    @Test func moveToSamePageOrTrashedPageFails() async throws {
        expectError(await run("block.move-to-page", ["block": id(ids[0]), "page": "Заметки"]), .invalidArgument)
        expectError(await run("block.move-to-page", ["block": id(ids[0]), "page": "Нет такой"]), .pageNotFound)
        #expect(try stored().count == 3)
    }

    // MARK: Запись и отмена

    @Test func openWindowDocumentSeesEditAndNothingStaysUnsaved() async throws {
        let document = try host.openDocuments.open(page.id)
        defer { host.openDocuments.release(page.id) }
        await run("block.insert", JSONArgument.page(page) + ["kind": "paragraph", "text": "из команды", "after": id(ids[0])])
        #expect(document.blocks.map(\.text.string) == ["один", "из команды", "два", "три"])
        #expect(!document.hasUnsavedChanges, "Запись дошла до базы до ответа")
        #expect(try host.texts(page.id) == ["один", "из команды", "два", "три"])
        await run("block.update", ["block": id(ids[2]), "text": "правка"])
        #expect(document.block(ids[2])?.text.string == "правка")
        #expect(!document.hasUnsavedChanges)
    }

    @Test func eachCommandIsOneUndoStep() async throws {
        await run("block.insert", JSONArgument.page(page) + ["kind": "paragraph", "text": "новый", "first": true])
        #expect(try host.texts(page.id) == ["новый", "один", "два", "три"])
        executor.lastUndoManager?.undo()
        #expect(try host.texts(page.id) == ["один", "два", "три"])
        executor.lastUndoManager?.redo()
        #expect(try host.texts(page.id) == ["новый", "один", "два", "три"])

        await run("block.update", ["block": id(ids[0]), "text": "правка", "kind": "heading1"])
        executor.lastUndoManager?.undo()
        let restored = try outline()
        #expect(restored == ["0:paragraph:новый", "0:paragraph:один", "0:paragraph:два", "0:paragraph:три"], "\(restored)")
    }

    @Test func deleteAndMoveAreUndoable() async throws {
        let (nested, nestedIds) = try nestedPage()
        let original = try outline(nested.id)
        await run("block.delete", ["block": id(nestedIds[0])])
        executor.lastUndoManager?.undo()
        #expect(try outline(nested.id) == original)
        #expect(try host.store.block(nestedIds[1]) != nil)

        await run("block.move", ["block": id(nestedIds[0]), "last": true])
        executor.lastUndoManager?.undo()
        #expect(try outline(nested.id) == original)
    }

    @Test func moveToPageIsUndoable() async throws {
        let (nested, nestedIds) = try nestedPage()
        let target = try host.page("Архив", texts: [])
        await run("block.move-to-page", ["block": id(nestedIds[3]), "page": "Архив"])
        executor.lastUndoManager?.undo()
        #expect(try outline(nested.id).count == 6)
        #expect(try stored(target.id).allSatisfy { $0.text.string.isEmpty })
    }

    @Test func failedStepRollsBackBatch() async throws {
        let before = try outline()
        let response = await run("batch", ["steps": [
            ["command": "block.insert", "args": ["page": .string(page.id.controlText), "kind": "paragraph", "text": "новый", "first": true]],
            ["command": "block.update", "args": ["block": id(ids[1]), "text": "правка"]],
            ["command": "block.delete", "args": ["block": id(UUID())]],
        ]])
        #expect(response.error?.code == .batchFailed)
        #expect(response.error?.details?["step"] == 3, "\(response.error?.message ?? "")")
        let restored = try outline()
        #expect(restored == before, "\(restored)")
    }

    @Test func batchStepsSeeEachOtherAndUndoTogether() async throws {
        let response = await run("batch", ["steps": [
            ["command": "block.insert", "args": ["page": .string(page.id.controlText), "kind": "checkbox", "text": "задача", "last": true]],
            ["command": "block.check", "args": ["block": "$1.block.id"]],
            ["command": "block.indent", "args": ["block": "$1.block.id"]],
        ]])
        #expect(response.ok)
        #expect(try stored().last.map { "\($0.indent):\($0.kind.rawValue):\($0.isChecked)" } == "0:checkbox:true")
        #expect(try stored().count == 4)
    }

    @Test func firstWriteLeavesAgentVersion() async throws {
        await run("block.update", ["block": id(ids[0]), "text": "правка"])
        let versions = try host.versions.versions(ofPage: page.id).filter { $0.summary.agent != nil }
        #expect(versions.count == 1)
        await run("block.update", ["block": id(ids[1]), "text": "ещё правка"])
        #expect(try host.versions.versions(ofPage: page.id).filter { $0.summary.agent != nil }.count == 1, "Не чаще раза в десять минут")
    }

    @Test func writtenPagesAreReportedToTheWindow() async throws {
        await run("block.update", ["block": id(ids[0]), "text": "правка"])
        #expect(host.treeChanges.contains { $0.contains(page.id) } || host.directWrites.contains { $0.contains(page.id) })
    }
}

/// Короткие записи аргументов в тестах.
private enum JSONArgument {
    static func page(_ page: Page) -> [String: ControlJSON] { ["page": .string(page.id.controlText)] }
}

private func + (lhs: [String: ControlJSON], rhs: [String: ControlJSON]) -> [String: ControlJSON] {
    lhs.merging(rhs) { _, new in new }
}
