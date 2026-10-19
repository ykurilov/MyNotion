import CryptoKit
import Foundation
import MarkdownExport
import NotesCore
import Synchronization
import Testing
@testable import NotionImport

/// Импорт картинок, файлов, видео и закладок из Notion и из нашей выгрузки (contracts/markdown-and-notion.md).
@Suite("Картинки, файлы, видео, закладки из Markdown")
struct AttachmentsImportTests {
    private let parser = NotionMarkdownParser()

    private func parse(_ markdown: String) -> ParsedNotionPage {
        parser.parse("# Страница\n\n" + markdown)
    }

    // MARK: Разбор

    @Test("Notion: картинка и файл на своей строке — блоки с путём файла выгрузки; внутри текста — «[файл: имя]», как в 001")
    func notionImageAndFile() {
        let page = parse("""
            ![](%D0%A1%D1%82%D1%80%D0%B0%D0%BD%D0%B8%D1%86%D0%B0/картинка%201.png)

            ![Подпись](Стр/a.png)

            [отчёт.pdf](Страница/%D0%BE%D1%82%D1%87%D1%91%D1%82.pdf)

            Смотри [отчёт](a.pdf) тут
            """)
        #expect(page.blocks.map(\.kind) == [.image, .image, .file, .paragraph])
        #expect(page.blocks[0].attachmentPath == "Страница/картинка 1.png")
        #expect(page.blocks[0].text.string == "")
        #expect(page.blocks[1].text.string == "Подпись")
        #expect(page.blocks[2].attachmentPath == "Страница/отчёт.pdf")
        #expect(page.blocks[3].text.string == "Смотри [файл: отчёт] тут")
    }

    @Test("Наша выгрузка: <img data-width>, <video> с подписью, <iframe data-video>, <a data-bookmark> с описанием")
    func ownFormats() {
        let page = parse("""
            <img src="Стр/фото%201.png" alt="Сказал &quot;да&quot;" data-width="0.6">

            <video src="Стр/ролик.mp4" controls></video>
            Подпись **видео**

            <iframe src="https://www.youtube-nocookie.com/embed/dQw4w9WgXcQ" data-video="youtube"></iframe>
            [Ролик](https://www.youtube.com/watch?v=dQw4w9WgXcQ)

            <a href="https://example.com/post?a=1&amp;b=2" data-bookmark>Пост &lt;важный&gt;</a>
            *Короткое описание*

            <a href="https://example.org" data-bookmark>https://example.org</a>
            """)
        #expect(page.blocks.map(\.kind) == [.image, .video, .video, .bookmark, .bookmark])
        let image = page.blocks[0]
        #expect(image.attachmentPath == "Стр/фото 1.png")
        #expect(image.text.string == "Сказал \"да\"")
        #expect(image.props.width == 0.6)
        let videoFile = page.blocks[1]
        #expect(videoFile.attachmentPath == "Стр/ролик.mp4")
        #expect(videoFile.props.videoSource == .file)
        #expect(videoFile.text.string == "Подпись видео")
        #expect(videoFile.text.runs.contains { $0.style == .bold })
        let youtube = page.blocks[2]
        #expect(youtube.props.videoSource == .youtube)
        #expect(youtube.props.url == URL(string: "https://www.youtube.com/watch?v=dQw4w9WgXcQ"))
        #expect(youtube.props.title == "Ролик")
        let bookmark = page.blocks[3]
        #expect(bookmark.props.url == URL(string: "https://example.com/post?a=1&b=2"))
        #expect(bookmark.props.title == "Пост <важный>")
        #expect(bookmark.props.description == "Короткое описание")
        #expect(page.blocks[4].props.title == nil)
        #expect(page.simplifications.isEmpty)
    }

    // MARK: Импорт выгрузки

    @Test("Картинки и файлы из выгрузки копируются во вложения; больше 100 МБ или нет файла — «[файл: имя]» и строка в отчёте")
    func filesAreCopied() throws {
        let fixture = try ImportFixture()
        try fixture.write("Медиа 0123456789abcdef0123456789abcdef.md", """
            # Медиа

            ![](Медиа/фото.png)

            [договор.pdf](Медиа/договор.pdf)

            [огромный.mov](Медиа/огромный.mov)

            ![](Медиа/нет-такого.png)
            """)
        try fixture.write("Медиа/фото.png", "картинка")
        try fixture.write("Медиа/договор.pdf", "договор")
        try fixture.sparse("Медиа/огромный.mov", byteCount: AttachmentRef.maximumByteCount + 1)

        let report = try fixture.runImport()

        let blocks = try fixture.blocks(ofPage: "Медиа")
        #expect(blocks.map(\.kind) == [.image, .file, .paragraph, .paragraph])
        let photo = try #require(blocks[0].props.attachment)
        #expect(photo.name == "фото.png")
        #expect(fixture.importer.data(of: photo.id) == Data("картинка".utf8))
        #expect(photo.sha256 == ImportFixture.sha("картинка"))
        #expect(blocks[1].props.attachment?.name == "договор.pdf")
        #expect(blocks[2].text.string == "[файл: огромный.mov]")
        #expect(blocks[3].text.string == "[файл: нет-такого.png]")
        #expect(report.simplified.first { $0.pageTitle == "Медиа" }?.items == ["картинки и файлы (2) — вместо них их имена"])
    }

    @Test("Notion: ссылка на YouTube или Vimeo на своей строке — видео, прочая ссылка — закладка, ссылка в тексте — ссылка")
    func soleLinks() throws {
        let fixture = try ImportFixture()
        try fixture.write("Ссылки.md", """
            # Ссылки

            [https://youtu.be/dQw4w9WgXcQ](https://youtu.be/dQw4w9WgXcQ)

            https://vimeo.com/76979871

            [https://example.com/article](https://example.com/article)

            [Сайт MyNotion](https://mynotion.example)

            Читай [здесь](https://example.com) подробнее
            """)
        try fixture.runImport()

        let blocks = try fixture.blocks(ofPage: "Ссылки")
        #expect(blocks.map(\.kind) == [.video, .video, .bookmark, .bookmark, .paragraph])
        #expect(blocks[0].props.videoSource == .youtube)
        #expect(blocks[0].props.url == URL(string: "https://youtu.be/dQw4w9WgXcQ"))
        #expect(blocks[1].props.videoSource == .vimeo)
        #expect(blocks[2].props.url == URL(string: "https://example.com/article"))
        #expect(blocks[2].props.title == nil)
        #expect(blocks[3].props.title == "Сайт MyNotion")
        #expect(blocks[4].text.string == "Читай здесь подробнее")
    }

    @Test("Круговая проверка: выгрузка → импорт — те же блоки, подписи, свойства и файлы (SHA-256)")
    func roundTrip() throws {
        let fixture = try ImportFixture()
        let source = NotesStore(database: try AppDatabase.open(at: fixture.folder.appendingPathComponent("source/MyNotion.sqlite")),
                                clock: HybridLogicalClock(deviceId: UUID()))
        var files: [UUID: URL] = [:]
        func ref(_ name: String, _ text: String) throws -> AttachmentRef {
            let url = fixture.folder.appendingPathComponent("originals/\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url)
            let ref = AttachmentRef(name: name, byteCount: text.utf8.count, contentType: "public.data", sha256: ImportFixture.sha(text))
            files[ref.id] = url
            return ref
        }
        var image = BlockProps()
        image.attachment = try ref("фото (1).png", "пиксели")
        image.width = 0.5
        var file = BlockProps()
        file.attachment = try ref("отчёт.pdf", "отчёт")
        var videoFile = BlockProps()
        videoFile.videoSource = .file
        videoFile.attachment = try ref("ролик.mp4", "кадры")
        var youtube = BlockProps()
        youtube.videoSource = .youtube
        youtube.url = URL(string: "https://www.youtube.com/watch?v=dQw4w9WgXcQ")
        youtube.title = "Ролик"
        var bookmark = BlockProps()
        bookmark.url = URL(string: "https://example.com/a?b=1&c=2")
        bookmark.title = "Статья"
        bookmark.description = "Описание статьи"
        let originals: [(BlockKind, String, BlockProps)] = [
            (.image, "Подпись картинки", image), (.file, "", file), (.video, "Подпись видео", videoFile),
            (.video, "", youtube), (.bookmark, "", bookmark),
        ]
        try source.write { transaction in
            let page = try transaction.createPage(title: "Медиа")
            var key = try transaction.blocks(ofPage: page.id).map(\.sortKey).max()
            for (kind, caption, props) in originals {
                key = .between(key, nil)
                try transaction.insertBlock(Block(pageId: page.id, kind: kind, text: InlineText(caption), sortKey: key!, props: props))
            }
        }
        let exportFolder = fixture.folder.appendingPathComponent("export", isDirectory: true)
        try FileManager.default.createDirectory(at: exportFolder, withIntermediateDirectories: true)
        let copies = files
        let exported = try MarkdownExporter(store: source, attachmentFile: { copies[$0] }).export(into: exportFolder)

        try fixture.runImport(from: exported.folder)

        let blocks = try fixture.blocks(ofPage: "Медиа").filter { $0.kind != .paragraph }
        #expect(blocks.map(\.kind) == originals.map(\.0))
        #expect(blocks.map(\.text.string) == originals.map(\.1))
        for (block, original) in zip(blocks, originals) {
            var props = block.props
            var expected = original.2
            #expect(props.attachment?.sha256 == expected.attachment?.sha256)
            #expect(props.attachment?.name == expected.attachment?.name)
            props.attachment = nil
            expected.attachment = nil
            #expect(props == expected)
        }
    }
}

/// Выгрузка Notion во временной папке, база и подменённое хранилище вложений.
private final class ImportFixture {
    let folder: URL
    let root: URL
    let store: NotesStore
    let importer = FakeAttachmentImporter()

    init() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("MyNotionAttachmentImport-\(UUID().uuidString)")
        root = folder.appendingPathComponent("export-root", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        store = NotesStore(database: try AppDatabase.open(at: folder.appendingPathComponent("db/MyNotion.sqlite")),
                           clock: HybridLogicalClock(deviceId: UUID()))
    }

    deinit { try? FileManager.default.removeItem(at: folder) }

    func write(_ path: String, _ text: String) throws {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    func sparse(_ path: String, byteCount: Int) throws {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: UInt64(byteCount))
        try handle.close()
    }

    @discardableResult
    func runImport(from source: URL? = nil) throws -> NotionImportReport {
        let prepared = try NotionExportUnpacker().prepare(source ?? root)
        defer { prepared.discard() }
        return try NotionImporter(store: store, attachments: importer).importExport(prepared)
    }

    func blocks(ofPage title: String) throws -> [Block] {
        let page = try #require(try store.pageOutline().first { $0.title == title }, "Нет страницы «\(title)»")
        return try #require(try store.pageContent(page.id)).blocks
    }

    static func sha(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

/// Хранилище вложений в памяти: запоминает скопированное.
private final class FakeAttachmentImporter: NotionAttachmentImporting, Sendable {
    private let copies = Mutex<[UUID: Data]>([:])

    func importFile(at url: URL) throws -> AttachmentRef {
        let data = try Data(contentsOf: url)
        let ref = AttachmentRef(name: url.lastPathComponent, byteCount: data.count, contentType: "public.data",
                                sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined())
        copies.withLock { $0[ref.id] = data }
        return ref
    }

    func data(of id: UUID) -> Data? {
        copies.withLock { $0[id] }
    }
}
