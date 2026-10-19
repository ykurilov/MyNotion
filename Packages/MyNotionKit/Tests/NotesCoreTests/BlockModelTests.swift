import Foundation
import Testing
@testable import NotesCore

@Suite("Модель блока 002")
struct BlockModelTests {
    let pageId = UUID()

    @Test("Все типы блоков из data-model.md")
    func allKinds() {
        let expected: Set<String> = [
            "paragraph", "heading1", "heading2", "heading3", "bulletItem", "numberedItem", "checkbox", "pageLink",
            "toggle", "quote", "callout", "divider", "code", "equation", "tableOfContents", "image", "file", "video", "bookmark",
            "table", "tableRow", "tableColumn", "tableCell", "columnList", "column",
        ]
        #expect(Set(BlockKind.allCases.map(\.rawValue)) == expected)
    }

    @Test("Кто может иметь детей и кто — контейнер вне текста страницы")
    func kindRoles() {
        #expect(Set(BlockKind.allCases.filter(\.canHaveChildren)) == [.bulletItem, .numberedItem, .checkbox, .toggle, .callout, .quote])
        #expect(Set(BlockKind.allCases.filter(\.isContainer)) == [.columnList, .column, .table, .tableRow])
        #expect(Set(BlockKind.allCases.filter(\.rendersAsAttachment))
                == [.divider, .equation, .tableOfContents, .image, .file, .video, .bookmark, .table, .columnList])
    }

    @Test("props по типам: значения по умолчанию")
    func defaultProps() {
        #expect(BlockProps.defaults(for: .callout).icon == "💡")
        #expect(BlockProps.defaults(for: .code).language == "plain")
        #expect(BlockProps.defaults(for: .table).hasHeaderRow == false)
        #expect(BlockProps.defaults(for: .table).hasHeaderColumn == false)
        #expect(BlockProps.defaults(for: .tableColumn).width == 120)
        for kind in [BlockKind.paragraph, .toggle, .quote, .divider, .equation, .tableOfContents, .tableRow, .columnList] {
            #expect(BlockProps.defaults(for: kind) == .empty, "\(kind)")
        }
        #expect(BlockColor.defaults(for: .callout) == BlockColor(background: .gray))
        #expect(BlockColor.defaults(for: .paragraph) == .none)
    }

    @Test("props по типам: каждое поле записывается и читается")
    func typedProps() throws {
        let file = AttachmentRef(id: UUID(), name: "отчёт.pdf", byteCount: 9_000_000, contentType: "com.adobe.pdf",
                                 sha256: String(repeating: "a", count: 64))
        var props = BlockProps.empty
        props.icon = "🔥"
        props.language = "swift"
        props.attachment = file
        props.width = 0.5
        props.pixelSize = PixelSize(width: 1920, height: 1080)
        props.videoSource = .youtube
        props.url = URL(string: "https://www.youtube.com/watch?v=abc")
        props.poster = file
        props.title = "Видео"
        props.description = "Описание"
        props.image = file
        props.fetchedAt = Date(timeIntervalSince1970: 1_760_000_000)
        props.hasHeaderRow = true
        props.hasHeaderColumn = true
        props.columnId = UUID()
        props.widthRatio = 0.3

        let decoded = try JSONDecoder().decode(BlockProps.self, from: try JSONEncoder().encode(props))
        #expect(decoded == props)
        #expect(decoded.attachment == file)
        #expect(decoded.pixelSize == PixelSize(width: 1920, height: 1080))
        #expect(decoded.videoSource == .youtube)
        #expect(decoded.fetchedAt == Date(timeIntervalSince1970: 1_760_000_000))
        #expect(file.partCount == 2)
    }

    @Test("Неизвестные ключи props сохраняются при записи")
    func unknownPropsSurvive() throws {
        let json = #"{"future":{"nested":[1,"два",true,null]},"icon":"💡","rank":2.5}"#
        var props = try JSONDecoder().decode(BlockProps.self, from: Data(json.utf8))
        props.icon = "🌟"
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let written = String(decoding: try encoder.encode(props), as: UTF8.self)
        #expect(written == #"{"future":{"nested":[1,"два",true,null]},"icon":"🌟","rank":2.5}"#)
    }

    @Test("AttachmentRef.byteCount «≤ 104 857 600»: больше — описание не читается")
    func attachmentSizeLimit() throws {
        #expect(AttachmentRef.maximumByteCount == 104_857_600)
        #expect(AttachmentRef.partSize == 8_388_608)
        let limit = AttachmentRef(id: UUID(), name: "a", byteCount: 104_857_600, contentType: "public.data", sha256: "00")
        #expect(limit.partCount == 13)
        #expect(try JSONDecoder().decode(AttachmentRef.self, from: try JSONEncoder().encode(limit)) == limit)

        let tooLarge = #"{"byteCount":104857601,"contentType":"public.data","id":"\#(UUID().uuidString)","name":"a","partCount":13,"sha256":"00"}"#
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(AttachmentRef.self, from: Data(tooLarge.utf8)) }
        var props = BlockProps.empty
        props.values["attachment"] = try JSONDecoder().decode(JSONValue.self, from: Data(tooLarge.utf8))
        #expect(props.attachment == nil)
    }

    @Test("changedFields различает placement, color и props")
    func changedFields() {
        let base = Block(pageId: pageId, sortKey: .between(nil, nil))
        var moved = base
        moved.sortKey = .between(base.sortKey, nil)
        #expect(moved.changedFields(comparedTo: base) == [.placement])
        var rehomed = base
        rehomed.containerId = UUID()
        #expect(rehomed.changedFields(comparedTo: base) == [.placement])
        var colored = base
        colored.color = BlockColor(text: .red)
        #expect(colored.changedFields(comparedTo: base) == [.color])
        var withProps = base
        withProps.props.icon = "💡"
        #expect(withProps.changedFields(comparedTo: base) == [.props])
        #expect(Set(Block.Field.allCases.map(\.rawValue)) == ["kindAndIndent", "text", "isChecked", "placement", "color", "props", "deleted"])
    }

    // MARK: Глубина

    private func blocks(_ specs: [(BlockKind, Int)]) -> [Block] {
        var key: FractionalSortKey?
        return specs.map { kind, indent in
            key = .between(key, nil)
            return Block(pageId: pageId, kind: kind, indent: indent, sortKey: key!)
        }
    }

    @Test("""
        Правило глубины дословно: «Глубина ≤ глубина соседа сверху + 1, если сосед — пункт, чекбокс, переключатель, \
        выноска или цитата; иначе 0. Заголовок глубже 0 — только внутри переключателя, выноски или цитаты. \
        Больше допустимого (после слияния) при показе урезается»
        """)
    func depthRule() {
        // Под пунктом, чекбоксом, переключателем, выноской, цитатой — на один уровень глубже.
        for parent in [BlockKind.bulletItem, .numberedItem, .checkbox, .toggle, .callout, .quote] {
            #expect(BlockNesting.displayIndents(blocks([(parent, 0), (.paragraph, 1)])) == [0, 1], "\(parent)")
            #expect(BlockNesting.displayIndents(blocks([(parent, 0), (.paragraph, 3)])) == [0, 1], "\(parent): урезано")
        }
        // Под абзацем, заголовком, кодом — не глубже соседа («иначе» прибавляется 0).
        #expect(BlockNesting.displayIndents(blocks([(.paragraph, 0), (.paragraph, 1)])) == [0, 0])
        #expect(BlockNesting.displayIndents(blocks([(.code, 0), (.bulletItem, 2)])) == [0, 0])
        // Второй ребёнок переключателя — вровень с первым.
        #expect(BlockNesting.displayIndents(blocks([(.toggle, 0), (.paragraph, 1), (.paragraph, 1), (.paragraph, 0)])) == [0, 1, 1, 0])
        // Первый блок страницы — всегда 0.
        #expect(BlockNesting.displayIndents(blocks([(.bulletItem, 2)])) == [0])
        // Заголовок вкладывается только внутрь переключателя, выноски или цитаты.
        for parent in [BlockKind.toggle, .callout, .quote] {
            #expect(BlockNesting.displayIndents(blocks([(parent, 0), (.heading2, 1)])) == [0, 1], "\(parent)")
        }
        #expect(BlockNesting.displayIndents(blocks([(.bulletItem, 0), (.heading1, 1)])) == [0, 0])
        #expect(BlockNesting.displayIndents(blocks([(.toggle, 0), (.bulletItem, 1), (.heading3, 2)])) == [0, 1, 1])
        // Урезание глубины родителя тянет за собой детей.
        #expect(BlockNesting.displayIndents(blocks([(.paragraph, 0), (.toggle, 1), (.paragraph, 2)])) == [0, 0, 1])
    }

    @Test("Заголовок с отступом записывается: допустимость решает показ, не хранилище")
    func headingWithIndentIsStorable() throws {
        let folder = try TemporaryFolder()
        let store = try NotesStore(database: AppDatabase.open(at: folder.databaseURL), clock: HybridLogicalClock(deviceId: UUID()))
        try store.write { tx in
            let page = try tx.createPage(title: "Страница")
            let first = try tx.blocks(ofPage: page.id)[0]
            try tx.insertBlock(Block(pageId: page.id, kind: .toggle, sortKey: .between(first.sortKey, nil)))
            let heading = Block(pageId: page.id, kind: .heading2, indent: 1, sortKey: .between(first.sortKey, nil).after)
            #expect(try tx.insertBlock(heading).indent == 1)
        }
    }
}

private extension FractionalSortKey {
    var after: FractionalSortKey { .between(self, nil) }
}
