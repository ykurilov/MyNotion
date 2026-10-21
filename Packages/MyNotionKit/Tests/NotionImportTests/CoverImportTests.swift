import CryptoKit
import Foundation
import MarkdownExport
import NotesCore
import Synchronization
import Testing
@testable import NotionImport

/// Обложка при импорте (contracts/sync-v3-and-export.md, «Выгрузка в Markdown»): своя выгрузка возвращает обложку
/// из комментария `mynotion:cover` (картинку — копией с тем же SHA-256); в выгрузке Notion обложек нет — отчёт это называет.
@Suite("Обложка при импорте")
struct CoverImportTests {
    @Test("Комментарий под названием — обложка страницы, а не блок")
    func parsesCoverComment() {
        let gallery = NotionMarkdownParser().parse("# Проекты\n<!-- mynotion:cover gallery=gradients_3 offset=0.5 -->\n\nТекст\n")
        #expect(gallery.title == "Проекты")
        #expect(gallery.cover == ParsedCover(source: .gallery("gradients_3"), offset: 0.5))
        #expect(gallery.blocks.map(\.text.string) == ["Текст"])

        let file = NotionMarkdownParser().parse("# 📘 Отпуск\n<!-- mynotion:cover file=\"Обложка 2.JPG\" offset=0.42 -->\n\nТекст\n")
        #expect(file.icon == "📘")
        #expect(file.cover == ParsedCover(source: .file("Обложка 2.JPG"), offset: 0.42))
        #expect(file.blocks.map(\.text.string) == ["Текст"])

        // Не наш комментарий и комментарий не под названием — не обложка.
        let other = NotionMarkdownParser().parse("# Стр\n\nТекст\n<!-- mynotion:cover gallery=solid_red offset=0.5 -->\n")
        #expect(other.cover == nil)
    }

    @Test("Своя выгрузка → импорт: обложка галереи и картинка с тем же SHA-256 и сдвигом")
    func roundTrip() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("MyNotionCoverRoundTrip-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = NotesStore(database: try AppDatabase.open(at: folder.appendingPathComponent("source/MyNotion.sqlite")),
                                clock: HybridLogicalClock(deviceId: UUID()))
        let target = NotesStore(database: try AppDatabase.open(at: folder.appendingPathComponent("target/MyNotion.sqlite")),
                                clock: HybridLogicalClock(deviceId: UUID()))
        let bytes = Data("картинка обложки".utf8)
        let original = folder.appendingPathComponent("originals/закат.jpg")
        try FileManager.default.createDirectory(at: original.deletingLastPathComponent(), withIntermediateDirectories: true)
        try bytes.write(to: original)
        let ref = AttachmentRef(name: "закат.jpg", byteCount: bytes.count, contentType: "public.jpeg", sha256: Self.sha(bytes))
        try source.write { transaction in
            var gallery = try transaction.createPage(title: "Галерея")
            gallery.cover = PageCover(source: .gallery("solid_beige"), offset: 0.25)
            try transaction.updatePage(gallery)
            var picture = try transaction.createPage(title: "Картинка")
            picture.cover = PageCover(source: .file(ref), offset: 0.42)
            try transaction.updatePage(picture)
        }
        let out = folder.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let exported = try MarkdownExporter(store: source, attachmentFile: { $0 == ref.id ? original : nil }).export(into: out)

        let importer = HashingCoverImporter()
        let prepared = try NotionExportUnpacker().prepare(exported.folder)
        defer { prepared.discard() }
        _ = try NotionImporter(store: target, attachments: importer).importExport(prepared)

        let pages = try target.pageOutline()
        let gallery = try #require(pages.first { $0.title == "Галерея" })
        #expect(gallery.cover == PageCover(source: .gallery("solid_beige"), offset: 0.25))
        let picture = try #require(pages.first { $0.title == "Картинка" })
        let imported = try #require(picture.cover)
        #expect(imported.offset == 0.42)
        let importedRef = try #require(imported.attachment)
        #expect(importer.hash(of: importedRef.id) == Self.sha(bytes))
    }

    @Test("Файл вне папки выгрузки (`..`, ссылка-ярлык) не копируется ни обложкой, ни картинкой; обложка — только картинка")
    func filesOutsideExportAreRefused() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("MyNotionCoverEscape-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let root = folder.appendingPathComponent("export", isDirectory: true)
        let pageFolder = root.appendingPathComponent("Стр", isDirectory: true)
        try FileManager.default.createDirectory(at: pageFolder, withIntermediateDirectories: true)
        try Data("секрет".utf8).write(to: folder.appendingPathComponent("secret.png"))
        try FileManager.default.createSymbolicLink(at: pageFolder.appendingPathComponent("ярлык.png"),
                                                   withDestinationURL: folder.appendingPathComponent("secret.png"))
        try Data("не картинка".utf8).write(to: pageFolder.appendingPathComponent("заметки.txt"))
        try Data("своя".utf8).write(to: pageFolder.appendingPathComponent("своя.png"))
        let markdown = { (cover: String) in
            "# Стр\n<!-- mynotion:cover file=\"\(cover)\" offset=0.5 -->\n\n![](../secret.png)\n\n![](Стр/ярлык.png)\n\n![](Стр/своя.png)\n"
        }
        for (name, cover) in [("Стр", "../../secret.png"), ("Стр2", "ярлык.png"), ("Стр3", "заметки.txt")] {
            try Data(markdown(cover).replacingOccurrences(of: "# Стр\n", with: "# \(name)\n").utf8)
                .write(to: root.appendingPathComponent("\(name).md"))
        }
        for name in ["Стр2", "Стр3"] {
            try FileManager.default.createSymbolicLink(at: root.appendingPathComponent(name, isDirectory: true), withDestinationURL: pageFolder)
        }
        let store = NotesStore(database: try AppDatabase.open(at: folder.appendingPathComponent("db/MyNotion.sqlite")),
                               clock: HybridLogicalClock(deviceId: UUID()))
        let importer = HashingCoverImporter()
        let prepared = try NotionExportUnpacker().prepare(root)
        defer { prepared.discard() }
        _ = try NotionImporter(store: store, attachments: importer).importExport(prepared)

        #expect(importer.copiedNames.allSatisfy { $0 == "своя.png" }, "Скопировано: \(importer.copiedNames)")
        for page in try store.pageOutline() where page.title.hasPrefix("Стр") {
            #expect(page.cover == nil, "У «\(page.title)» обложка — не картинка из папки выгрузки")
            let texts = try #require(try store.pageContent(page.id)).blocks.map(\.text.string)
            #expect(texts.filter { $0.hasPrefix("[файл:") }.count == 2, "\(page.title): \(texts)")
        }
    }

    @Test("Отчёт импорта называет потерю обложек Notion")
    func reportNamesCoverLoss() {
        #expect(NotionImportReport.coverLossNotice == "Обложки страниц Notion в выгрузку не попадают")
        let report = NotionImportReport(rootPageId: UUID(), rootTitle: "Импорт", pageCount: 1, blockCount: 1, simplified: [])
        #expect(report.notices == [NotionImportReport.markdownLossNotice, NotionImportReport.coverLossNotice])
    }

    static func sha(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

/// Хранилище файлов импорта в памяти: SHA-256 скопированного по id ссылки.
private final class HashingCoverImporter: NotionAttachmentImporting, Sendable {
    private let copies = Mutex<[UUID: String]>([:])

    func importFile(at url: URL) throws -> AttachmentRef {
        let data = try Data(contentsOf: url)
        let sha = CoverImportTests.sha(data)
        let ref = AttachmentRef(name: url.lastPathComponent, byteCount: data.count, contentType: "public.jpeg", sha256: sha)
        copies.withLock { $0[ref.id] = sha }
        names.withLock { $0.append(url.lastPathComponent) }
        return ref
    }

    func hash(of id: UUID) -> String? { copies.withLock { $0[id] } }

    private let names = Mutex<[String]>([])
    var copiedNames: [String] { names.withLock { $0 } }
}
