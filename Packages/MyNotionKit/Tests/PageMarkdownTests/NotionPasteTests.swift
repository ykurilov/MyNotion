import Foundation
import NotesCore
import Testing
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

        static let empty = NotionBlock()
        static func text(_ title: String) -> NotionBlock { NotionBlock(title: title) }
    }

    /// JSON `text/_notion-multi-text-production`: `blockSelection.blocks` по порядку, у каждого — поддерево блоков.
    static func notionJSON(_ blocks: [NotionBlock]) -> String {
        func records(_ block: NotionBlock, id: String, into map: inout [String: Any]) {
            var value: [String: Any] = ["id": id, "type": block.type, "alive": true]
            if let title = block.title { value["properties"] = ["title": [[title]]] }
            let childIds = block.children.indices.map { "\(id)-\($0)" }
            if !childIds.isEmpty { value["content"] = childIds }
            map[id] = ["value": value]
            for (child, childId) in zip(block.children, childIds) { records(child, id: childId, into: &map) }
        }
        let selection = blocks.enumerated().map { index, block -> [String: Any] in
            var map: [String: Any] = [:]
            records(block, id: "block-\(index)", into: &map)
            return ["blockSubtree": ["block": map]]
        }
        let json: [String: Any] = ["blockSelection": ["blocks": selection], "multiTextSelection": [:] as [String: Any]]
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
            // Блоков с текстом в Notion больше, чем в HTML (картинка, которой нет в HTML), — не гадать.
            (withList, Self.notionData([.text("Первый"), .empty, NotionBlock(type: "image"), NotionBlock(type: "bulleted_list", title: "Пункт")])),
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
