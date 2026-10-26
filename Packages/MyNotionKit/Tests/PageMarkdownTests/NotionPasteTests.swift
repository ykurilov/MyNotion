import Foundation
import NotesCore
import Testing
import NotionAPI
@testable import PageMarkdown

/// Вставка из Notion в Chrome: в HTML пустых блоков нет, их места знает только буфер Chromium
/// (`org.chromium.web-custom-data`), куда Notion кладёт выделенные блоки JSON.
@Suite("Вставка из Notion: пустые блоки")
struct NotionPasteTests {
    /// Блок выделения Notion: тип, текст (`nil` — свойства `title` нет, пустой блок) и вложенные блоки.
    struct NotionBlock {
        var type = "text"
        var title: String?
        var children: [NotionBlock] = []
        /// id блока в Notion; `nil` — выдуманный по месту в выделении.
        var id: String?
        /// `properties.source` картинки: `attachment:<uuid>:<имя>` или адрес в сети.
        var source: String?

        static let empty = NotionBlock()
        static func text(_ title: String) -> NotionBlock { NotionBlock(title: title) }
    }

    /// JSON `text/_notion-multi-text-production`: `blockSelection.blocks` по порядку, у каждого — поддерево блоков.
    /// `blocksV3` — JSON `text/_notion-blocks-v3-production` (⌘A, выделение блоков): `blocks` в корне.
    static func notionJSON(_ blocks: [NotionBlock], blocksV3: Bool = false) -> String {
        func records(_ block: NotionBlock, id: String, into map: inout [String: Any]) {
            var value: [String: Any] = ["id": id, "type": block.type, "alive": true]
            var properties: [String: Any] = [:]
            if let title = block.title { properties["title"] = [[title]] }
            if let source = block.source { properties["source"] = [[source]] }
            if !properties.isEmpty { value["properties"] = properties }
            let childIds = block.children.indices.map { "\(id)-\($0)" }
            if !childIds.isEmpty { value["content"] = childIds }
            map[id] = ["value": value]
            for (child, childId) in zip(block.children, childIds) { records(child, id: childId, into: &map) }
        }
        let selection = blocks.enumerated().map { index, block -> [String: Any] in
            var map: [String: Any] = [:]
            records(block, id: block.id ?? "block-\(index)", into: &map)
            return ["blockSubtree": ["block": map]]
        }
        let json: [String: Any] = blocksV3
            ? ["action": "copy", "blocks": selection, "wasContiguousSelection": true]
            : ["blockSelection": ["blocks": selection], "multiTextSelection": [:] as [String: Any]]
        let data = try! JSONSerialization.data(withJSONObject: json)
        return String(decoding: data, as: UTF8.self)
    }

    /// Буфер Chromium: размер, число пар и пары строк UTF-16LE с длиной в символах, выровненные до 4 байт.
    static func webCustomData(_ pairs: [(String, String)]) -> Data {
        var payload = Data()
        func append(_ number: Int) { withUnsafeBytes(of: UInt32(number).littleEndian) { payload.append(contentsOf: $0) } }
        append(pairs.count)
        for (type, value) in pairs {
            for string in [type, value] {
                let units = Array(string.utf16)
                append(units.count)
                for unit in units { withUnsafeBytes(of: unit.littleEndian) { payload.append(contentsOf: $0) } }
                while payload.count % 4 != 0 { payload.append(0) }
            }
        }
        var data = Data()
        withUnsafeBytes(of: UInt32(payload.count).littleEndian) { data.append(contentsOf: $0) }
        return data + payload
    }

    static func notionData(_ blocks: [NotionBlock]) -> Data {
        webCustomData([("text/_notion-page-source-production", "https://app.notion.com/p/test"),
                       ("text/_notion-multi-text-production", notionJSON(blocks))])
    }

    private func blocks(html: String, text: String = "", webCustomData: Data?) -> [Block]? {
        PastedText.blocks(from: text, html: html, webCustomData: webCustomData, pageId: UUID(), hasRichText: true)
    }

    private func shape(_ blocks: [Block]?) -> [String]? {
        blocks?.filter { $0.containerId == nil }.map { "\($0.kind) \($0.indent) \($0.text.string)" }
    }

    @Test("Пустые абзацы на своих местах: между абзацами, несколько подряд, в начале и в конце")
    func emptyParagraphs() throws {
        let html = "<meta charset='utf-8'><p>Первый абзац</p><p>Второй <strong>жирный</strong></p><!-- notionvc: 1a2b -->"
        let data = Self.notionData([.empty, .text("Первый абзац"), .empty, .empty, .text("Второй жирный"), .empty])

        let pasted = try #require(blocks(html: html, text: "Первый абзац\nВторой жирный", webCustomData: data))

        #expect(pasted.map(\.kind) == Array(repeating: .paragraph, count: 6))
        #expect(pasted.map(\.text.string) == ["", "Первый абзац", "", "", "Второй жирный", ""])
        #expect(pasted.map(\.indent) == [0, 0, 0, 0, 0, 0])
        #expect(pasted[4].text.runs.map(\.style) == [.bold])
    }

    @Test("⌘A в Notion: выделение блоков (`blocks` в корне JSON) — пустые абзацы тоже на своих местах")
    func emptyParagraphsInBlockSelection() throws {
        let html = "<meta charset='utf-8'><p>Первый абзац</p><p>Второй</p><!-- notionvc: 1a2b -->"
        let json = Self.notionJSON([.text("Первый абзац"), .empty, .text("Второй"), .empty], blocksV3: true)
        let data = Self.webCustomData([("text/_notion-page-source-production", "https://app.notion.com/p/test"),
                                       ("text/_notion-blocks-v3-production", json)])

        let pasted = try #require(blocks(html: html, text: "Первый абзац\nВторой", webCustomData: data))

        #expect(pasted.map(\.text.string) == ["Первый абзац", "", "Второй", ""])
    }

    static let imageId = "3c90c3cc-0d44-4b50-8888-8dd25736052a"

    static func image(_ name: String = "snimok.png", source: String? = nil) -> NotionBlock {
        NotionBlock(type: "image", title: name, id: imageId, source: source ?? "attachment:1a2b:\(name)")
    }

    @Test("Картинка среди блоков: в HTML её нет — встаёт блоком-картинкой со ссылкой на блок Notion; пустые абзацы на местах")
    func emptyParagraphsAroundImage() throws {
        let html = """
        <meta charset='utf-8'><p>Первый</p><p><img src="attachment:1a2b:snimok.png" alt="snimok.png"></p>\
        <p>Второй</p><!-- notionvc: 1a2b -->
        """
        let json = Self.notionJSON([.text("Первый"), .empty, Self.image(), .empty, .text("Второй")], blocksV3: true)
        let data = Self.webCustomData([("text/_notion-blocks-v3-production", json)])

        let pasted = try #require(blocks(html: html, text: "Первый\nВторой", webCustomData: data))

        #expect(pasted.map(\.kind) == [.paragraph, .paragraph, .image, .paragraph, .paragraph])
        #expect(pasted.map(\.text.string) == ["Первый", "", "", "", "Второй"])
        let image = pasted[2]
        #expect(image.props.url == NotionBlockLink.url(forBlock: UUID(uuidString: Self.imageId)!))
        #expect(image.props.title == "snimok.png")
        #expect(image.props.attachment == nil)
    }

    @Test("Картинки без пустых блоков: каждая на своём месте, в начале, между абзацами и в конце")
    func imagesWithoutEmptyBlocks() throws {
        let html = "<meta charset='utf-8'><p><img src='attachment:1:a.png'></p><p>Раз</p><p><img src='x'></p><p>Два</p><p><img src='y'></p>"
        let first = NotionBlock(type: "image", title: "a.png", id: "11111111-1111-4111-8111-111111111111", source: "attachment:1:a.png")
        let data = Self.notionData([first, .text("Раз"), Self.image("b.jpg"), .text("Два"), Self.image("c.gif")])

        let pasted = try #require(blocks(html: html, webCustomData: data))

        #expect(pasted.map(\.kind) == [.image, .paragraph, .image, .paragraph, .image])
        #expect(pasted.compactMap(\.props.title) == ["a.png", "b.jpg", "c.gif"])
        #expect(pasted[0].props.url == NotionBlockLink.url(forBlock: UUID(uuidString: "11111111-1111-4111-8111-111111111111")!))
    }

    @Test("Картинка по ссылке из сети — та же ссылка, без Notion API; имя — из адреса, если подписи нет")
    func externalImage() throws {
        let html = "<meta charset='utf-8'><p>Раз</p><p><img src='https://images.example.org/cat.jpg'></p>"
        let external = NotionBlock(type: "image", id: Self.imageId, source: "https://images.example.org/cat.jpg")
        let pasted = try #require(blocks(html: html, webCustomData: Self.notionData([.text("Раз"), external])))

        #expect(pasted.map(\.kind) == [.paragraph, .image])
        #expect(pasted[1].props.url == URL(string: "https://images.example.org/cat.jpg"))
        #expect(pasted[1].props.title == "cat.jpg")
    }

    @Test("Имя картинки без подписи — из `attachment:<uuid>:<имя>`; без всего — «Картинка»")
    func imageNames() throws {
        let html = "<meta charset='utf-8'><p><img src='a'></p><p><img src='b'></p>"
        let fromSource = NotionBlock(type: "image", id: Self.imageId, source: "attachment:9f:Снимок экрана.png")
        let bare = NotionBlock(type: "image", id: "22222222-2222-4222-8222-222222222222")
        let pasted = try #require(blocks(html: html, webCustomData: Self.notionData([fromSource, bare])))
        #expect(pasted.compactMap(\.props.title) == ["Снимок экрана.png", "Картинка"])
    }

    @Test("Видео, файл, PDF и звук Notion по-прежнему не вставляются и сверке не мешают; картинка без id — тоже")
    func otherAttachmentsSkipped() throws {
        let html = "<meta charset='utf-8'><p>Раз</p><p>Два</p>"
        let noId = NotionBlock(type: "image", title: "x.png", id: "не-uuid")
        let data = Self.notionData([.text("Раз"), NotionBlock(type: "video"), NotionBlock(type: "file"), noId, .empty,
                                    NotionBlock(type: "pdf"), .text("Два")])
        let pasted = try #require(blocks(html: html, webCustomData: data))
        #expect(shape(pasted) == ["paragraph 0 Раз", "paragraph 0 ", "paragraph 0 Два"])
    }

    @Test("Выделена одна картинка — один блок-картинка")
    func onlyImage() throws {
        let html = "<meta charset='utf-8'><p><img src=\"attachment:1a2b:snimok.png\" alt=\"snimok.png\"></p>"
        let pasted = try #require(blocks(html: html, text: "", webCustomData: Self.notionData([Self.image()])))
        #expect(pasted.map(\.kind) == [.image])
    }

    @Test("Пустая строка внутри блока Notion: в HTML это два абзаца — пустые блоки всё равно на своих местах")
    func blankLineInsideBlock() throws {
        let html = "<meta charset='utf-8'><p>Раз</p><p>Два</p><p>Три<br>четыре</p><p>Пять</p><!-- notionvc: 1a2b -->"
        let json = Self.notionJSON([.text("Раз\n\nДва"), .empty, .text("Три\nчетыре"), .empty, .text("Пять")], blocksV3: true)
        let data = Self.webCustomData([("text/_notion-blocks-v3-production", json)])

        let pasted = try #require(blocks(html: html, text: "", webCustomData: data))

        #expect(pasted.map(\.text.string.isEmpty) == [false, false, true, false, true, false])
        #expect(pasted.first?.text.string == "Раз")
        #expect(pasted.last?.text.string == "Пять")
    }

    @Test("Пустые абзацы между заголовком, списками с вложенностью и абзацем; оформление и ссылки — из HTML")
    func emptyBetweenLists() throws {
        let html = """
        <meta charset='utf-8'><h1>Заголовок</h1><ul><li>Раз<ul><li>Вложенный</li></ul></li><li>Два</li></ul>\
        <ol><li>Три</li></ol><p>Конец <a href="https://example.com/doc">ссылка</a></p><!-- notionvc: 3c4d -->
        """
        let data = Self.notionData([
            NotionBlock(type: "header", title: "Заголовок"), .empty,
            NotionBlock(type: "bulleted_list", title: "Раз", children: [NotionBlock(type: "bulleted_list", title: "Вложенный")]),
            NotionBlock(type: "bulleted_list", title: "Два"), .empty,
            NotionBlock(type: "numbered_list", title: "Три"), .empty, .empty,
            .text("Конец ссылка"),
        ])

        let pasted = try #require(blocks(html: html, webCustomData: data))

        #expect(pasted.map(\.kind) == [.heading1, .paragraph, .bulletItem, .bulletItem, .bulletItem, .paragraph, .numberedItem,
                                       .paragraph, .paragraph, .paragraph])
        #expect(pasted.map(\.text.string) == ["Заголовок", "", "Раз", "Вложенный", "Два", "", "Три", "", "", "Конец ссылка"])
        #expect(pasted.map(\.indent) == [0, 0, 0, 1, 0, 0, 0, 0, 0, 0])
        #expect(pasted[9].text.runs.map(\.style) == [.link(URL(string: "https://example.com/doc")!)])
    }

    @Test("Без пустых блоков, при несовпадении блоков и при испорченных данных — вставка как без буфера Notion")
    func fallsBackToHTML() throws {
        let paragraphs = "<p>Первый</p><p>Второй</p>"
        let withList = "<p>Первый</p><ul><li>Пункт</li></ul>"
        let notionJSON = Self.notionJSON([.text("Первый"), .empty, .text("Второй")])
        let cases: [(html: String, data: Data)] = [
            // Пустых блоков нет: абзацы без строения, как раньше, — вставка с оформлением, а не блоками.
            (paragraphs, Self.notionData([.text("Первый"), .text("Второй")])),
            (withList, Self.notionData([.text("Первый"), NotionBlock(type: "bulleted_list", title: "Пункт")])),
            // Блоков с текстом в Notion больше, чем в HTML, — не гадать.
            (withList, Self.notionData([.text("Первый"), .empty, .text("Лишний"), NotionBlock(type: "bulleted_list", title: "Пункт")])),
            (paragraphs, Self.notionData([.text("Первый"), .empty])),
            // Испорченный буфер, чужой JSON, другой сайт.
            (paragraphs, Data([1, 2, 3])),
            (paragraphs, Self.notionData([.text("Первый"), .empty, .text("Второй")]).prefix(40)),
            (paragraphs, Self.webCustomData([("text/_notion-multi-text-production", "{\"blocks\": 1}")])),
            (paragraphs, Self.webCustomData([("text/_notion-multi-text-production", "не JSON")])),
            (paragraphs, Self.webCustomData([("text/x-other-site", notionJSON)])),
        ]
        for (html, data) in cases {
            #expect(shape(blocks(html: html, webCustomData: data)) == shape(blocks(html: html, webCustomData: nil)))
        }
        #expect(blocks(html: paragraphs, webCustomData: Self.notionData([.text("Первый"), .text("Второй")])) == nil)
    }

    @Test("Только пустые блоки выделения — пустые абзацы")
    func onlyEmptyBlocks() throws {
        let pasted = try #require(blocks(html: "<meta charset='utf-8'><!-- notionvc: 5e6f -->", webCustomData: Self.notionData([.empty, .empty])))
        #expect(shape(pasted) == ["paragraph 0 ", "paragraph 0 "])
    }
}
