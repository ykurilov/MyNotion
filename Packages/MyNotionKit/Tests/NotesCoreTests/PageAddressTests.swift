import Foundation
import Testing
@testable import NotesCore

/// Адрес страницы `mynotion://page/<id>` и блока `mynotion://page/<id>#<blockId>`: один формат для Mac, iPhone и ссылок агентов.
@Suite("Адрес страницы")
struct PageAddressTests {
    let pageId = UUID(uuidString: "3F2A91C0-1111-4222-8333-444455556666")!
    let blockId = UUID(uuidString: "A1B2C3D4-AAAA-4BBB-8CCC-DDDDEEEEFFFF")!

    @Test("адрес страницы и блока — строчными буквами")
    func formats() {
        #expect(PageAddress(pageId: pageId).text == "mynotion://page/3f2a91c0-1111-4222-8333-444455556666")
        #expect(PageAddress(pageId: pageId, blockId: blockId).text
                == "mynotion://page/3f2a91c0-1111-4222-8333-444455556666#a1b2c3d4-aaaa-4bbb-8ccc-ddddeeeeffff")
        #expect(PageAddress(pageId: pageId, blockId: blockId).url.absoluteString == PageAddress(pageId: pageId, blockId: blockId).text)
    }

    @Test("разбор: туда и обратно, регистр не важен")
    func parses() throws {
        let page = PageAddress(pageId: pageId), block = PageAddress(pageId: pageId, blockId: blockId)
        #expect(PageAddress(url: page.url) == page)
        #expect(PageAddress(url: block.url) == block)
        #expect(PageAddress(url: try #require(URL(string: "MyNotion://PAGE/3F2A91C0-1111-4222-8333-444455556666"))) == page)
        #expect(PageAddress(url: try #require(URL(string: "mynotion://page/3f2a91c0-1111-4222-8333-444455556666/"))) == page)
    }

    @Test("испорченный id блока — страница всё равно открывается")
    func badBlockKeepsPage() throws {
        let url = try #require(URL(string: "mynotion://page/3f2a91c0-1111-4222-8333-444455556666#нет"))
        #expect(PageAddress(url: url) == PageAddress(pageId: pageId))
    }

    @Test("не адрес страницы", arguments: [
        "https://page/3f2a91c0-1111-4222-8333-444455556666",
        "mynotion://block/3f2a91c0-1111-4222-8333-444455556666",
        "mynotion://page/3f2a91c0",
        "mynotion://page/",
        "mynotion://page/x/3f2a91c0-1111-4222-8333-444455556666",
    ])
    func rejects(_ text: String) throws {
        #expect(PageAddress(url: try #require(URL(string: text))) == nil)
    }
}
