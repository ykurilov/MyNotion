import Foundation
import Testing
@testable import MarkdownExport
@testable import NotesCore

/// Выгрузка обложки (contracts/sync-v3-and-export.md, «Выгрузка в Markdown»): сразу под строкой названия — комментарий
/// `mynotion:cover`; своя картинка — копией `Обложка.<расширение>` в папке страницы (при занятом — `Обложка 2.…`).
/// Вид страницы не выгружается.
@Suite("Обложка в Markdown")
struct CoverExportTests {
    private final class Fixture {
        let folder: URL
        let store: NotesStore
        var files: [UUID: URL] = [:]

        init() throws {
            folder = FileManager.default.temporaryDirectory.appendingPathComponent("MyNotionCoverExport-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            store = NotesStore(database: try AppDatabase.open(at: folder.appendingPathComponent("db/MyNotion.sqlite")),
                               clock: HybridLogicalClock(deviceId: UUID()))
        }

        deinit { try? FileManager.default.removeItem(at: folder) }

        @discardableResult
        func page(_ title: String, cover: PageCover?, isFullWidth: Bool = false, blocks: [String] = ["Текст"]) throws -> UUID {
            try store.write { transaction in
                var page = try transaction.createPage(title: title)
                page.cover = cover
                page.isFullWidth = isFullWidth
                page.isSmallText = isFullWidth
                try transaction.updatePage(page)
                for block in try transaction.blocks(ofPage: page.id) { try transaction.deleteBlock(block.id) }
                var key: FractionalSortKey?
                for text in blocks {
                    key = .between(key, nil)
                    try transaction.insertBlock(Block(pageId: page.id, kind: .paragraph, text: InlineText(text), sortKey: key!))
                }
                return page.id
            }
        }

        /// Файл картинки на «этом Mac» под описанием `ref`.
        func picture(_ name: String, _ text: String) throws -> AttachmentRef {
            let url = folder.appendingPathComponent("files/\(UUID().uuidString)/\(name)")
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url)
            let ref = AttachmentRef(name: name, byteCount: text.utf8.count, contentType: "public.jpeg", sha256: String(repeating: "0", count: 64))
            files[ref.id] = url
            return ref
        }

        func export() throws -> MarkdownExportResult {
            let destination = folder.appendingPathComponent("out", isDirectory: true)
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            let copies = files
            return try MarkdownExporter(store: store, attachmentFile: { copies[$0] }).export(into: destination)
        }
    }

    @Test("Галерея — комментарий сразу под названием; вид страницы не выгружается")
    func galleryCover() throws {
        let fixture = try Fixture()
        try fixture.page("Проекты", cover: PageCover(source: .gallery("gradients_3")), isFullWidth: true)
        let result = try fixture.export()
        let markdown = try String(contentsOf: result.folder.appendingPathComponent("Проекты.md"), encoding: .utf8)
        #expect(markdown == "# Проекты\n<!-- mynotion:cover gallery=gradients_3 offset=0.5 -->\n\nТекст\n")
    }

    @Test("Своя картинка — копия «Обложка.jpg» в папке страницы и комментарий с её именем и сдвигом")
    func fileCover() throws {
        let fixture = try Fixture()
        let ref = try fixture.picture("IMG_0042.JPG", "байты обложки")
        try fixture.page("Отпуск", cover: PageCover(source: .file(ref), offset: 0.42))
        let result = try fixture.export()
        let markdown = try String(contentsOf: result.folder.appendingPathComponent("Отпуск.md"), encoding: .utf8)
        #expect(markdown == "# Отпуск\n<!-- mynotion:cover file=\"Обложка.JPG\" offset=0.42 -->\n\nТекст\n")
        let copy = result.folder.appendingPathComponent("Отпуск/Обложка.JPG")
        #expect(try String(contentsOf: copy, encoding: .utf8) == "байты обложки")
        #expect(result.missingFileCount == 0)
    }

    @Test("Имя «Обложка.png» занято файлом страницы — «Обложка 2.png»")
    func takenName() throws {
        let fixture = try Fixture()
        let cover = try fixture.picture("cover.png", "обложка")
        let other = try fixture.picture("Обложка.png", "картинка в тексте")
        let pageId = try fixture.page("Стр", cover: PageCover(source: .file(cover), offset: 1))
        try fixture.store.write { transaction in
            var props = BlockProps()
            props.attachment = other
            let last = try transaction.blocks(ofPage: pageId).map(\.sortKey).max()
            try transaction.insertBlock(Block(pageId: pageId, kind: .image, sortKey: .between(last, nil), props: props))
        }
        let result = try fixture.export()
        let markdown = try String(contentsOf: result.folder.appendingPathComponent("Стр.md"), encoding: .utf8)
        #expect(markdown.hasPrefix("# Стр\n<!-- mynotion:cover file=\"Обложка 2.png\" offset=1 -->\n\n"))
        #expect(try String(contentsOf: result.folder.appendingPathComponent("Стр/Обложка 2.png"), encoding: .utf8) == "обложка")
        #expect(try String(contentsOf: result.folder.appendingPathComponent("Стр/Обложка.png"), encoding: .utf8) == "картинка в тексте")
    }

    @Test("Картинка обложки ещё не скачана — комментария нет, файл в «Не выгружено файлов»")
    func missingCoverFile() throws {
        let fixture = try Fixture()
        let ref = AttachmentRef(name: "далеко.png", byteCount: 1, contentType: "public.png", sha256: String(repeating: "0", count: 64))
        try fixture.page("Стр", cover: PageCover(source: .file(ref)))
        let result = try fixture.export()
        let markdown = try String(contentsOf: result.folder.appendingPathComponent("Стр.md"), encoding: .utf8)
        #expect(markdown == "# Стр\n\nТекст\n")
        #expect(result.missingFileCount == 1)
    }
}
