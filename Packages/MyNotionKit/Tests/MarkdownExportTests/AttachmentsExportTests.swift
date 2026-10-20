import CryptoKit
import Foundation
import Testing
@testable import MarkdownExport
@testable import NotesCore

/// Выгрузка картинок, файлов, видео и закладок (contracts/markdown-and-notion.md, «Блоки» и «Файлы»).
@Suite("Картинки, файлы, видео, закладки в Markdown")
struct AttachmentsExportTests {
    private let pageId = UUID()
    private let writer = MarkdownBlockWriter()

    private func ref(_ name: String, contentType: String = "public.data") -> AttachmentRef {
        AttachmentRef(name: name, byteCount: 10, contentType: contentType, sha256: String(repeating: "0", count: 64))
    }

    private func block(_ kind: BlockKind, _ caption: String = "", props: BlockProps) -> Block {
        Block(pageId: pageId, kind: kind, text: InlineText(caption), sortKey: .between(nil, nil), props: props)
    }

    private func media(_ kind: BlockKind, _ ref: AttachmentRef, caption: String = "", width: Double? = nil,
                       source: VideoSource? = nil) -> Block {
        var props = BlockProps()
        props.attachment = ref
        props.width = width
        props.videoSource = source
        return block(kind, caption, props: props)
    }

    // MARK: Запись блоков

    @Test("Картинка — ![подпись](путь); ширина не 100 % — <img data-width>")
    func image() {
        let photo = ref("фото 1.png")
        let paths = [photo.id: "Моя страница/фото 1.png"]
        let full = writer.markdown(for: [media(.image, photo, caption: "Закат")], resolveLink: { _ in nil },
                                   resolveAttachment: { paths[$0.id] })
        #expect(full == "![Закат](Моя%20страница/фото%201.png)\n")
        let narrow = writer.markdown(for: [media(.image, photo, caption: "Сказал \"да\"", width: 0.6)], resolveLink: { _ in nil },
                                     resolveAttachment: { paths[$0.id] })
        #expect(narrow == "<img src=\"Моя%20страница/фото%201.png\" alt=\"Сказал &quot;да&quot;\" data-width=\"0.6\">\n")
    }

    @Test("Файл — ссылка отдельной строкой; видео-файл — <video> и подпись под ним")
    func fileAndVideoFile() {
        let pdf = ref("отчёт.pdf")
        let movie = ref("ролик.mp4")
        let paths = [pdf.id: "Стр/отчёт.pdf", movie.id: "Стр/ролик.mp4"]
        let text = writer.markdown(for: [media(.file, pdf), media(.video, movie, caption: "Подпись видео", source: .file)],
                                   resolveLink: { _ in nil }, resolveAttachment: { paths[$0.id] })
        #expect(text == """
            [отчёт.pdf](Стр/отчёт.pdf)

            <video src="Стр/ролик.mp4" controls></video>
            Подпись видео

            """)
    }

    @Test("YouTube и Vimeo — <iframe data-video> и ссылка на ролик строкой ниже")
    func webVideo() {
        var props = BlockProps()
        props.videoSource = .youtube
        props.url = URL(string: "https://www.youtube.com/watch?v=dQw4w9WgXcQ")
        props.title = "Ролик"
        var vimeo = BlockProps()
        vimeo.videoSource = .vimeo
        vimeo.url = URL(string: "https://vimeo.com/76979871")
        let text = writer.markdown(for: [block(.video, props: props), block(.video, props: vimeo)], resolveLink: { _ in nil })
        #expect(text == """
            <iframe src="https://www.youtube-nocookie.com/embed/dQw4w9WgXcQ" data-video="youtube"></iframe>
            [Ролик](https://www.youtube.com/watch?v=dQw4w9WgXcQ)

            <iframe src="https://player.vimeo.com/video/76979871" data-video="vimeo"></iframe>
            [https://vimeo.com/76979871](https://vimeo.com/76979871)

            """)
    }

    @Test("Закладка — <a data-bookmark>, описание курсивом строкой ниже")
    func bookmark() {
        var props = BlockProps()
        props.url = URL(string: "https://example.com/post?a=1&b=2")
        props.title = "Пост <важный>"
        props.description = "Короткое описание"
        var bare = BlockProps()
        bare.url = URL(string: "https://example.org")
        let text = writer.markdown(for: [block(.bookmark, props: props), block(.bookmark, props: bare)], resolveLink: { _ in nil })
        #expect(text == """
            <a href="https://example.com/post?a=1&amp;b=2" data-bookmark>Пост &lt;важный&gt;</a>
            *Короткое описание*

            <a href="https://example.org" data-bookmark>https://example.org</a>

            """)
    }

    @Test("Файл, которого нет на этом Mac, — строка «[файл не скачан: имя]»")
    func notDownloaded() {
        let text = writer.markdown(for: [media(.file, ref("отчёт.pdf")), media(.image, ref("фото.png"))], resolveLink: { _ in nil },
                                   resolveAttachment: { _ in nil })
        #expect(text == "[файл не скачан: отчёт.pdf]\n\n[файл не скачан: фото.png]\n")
    }

    // MARK: Копии в папке страницы

    @Test("Копии лежат в папке страницы, совпадающие имена получают « (2)», нескачанные считаются в итоге")
    func copiesInPageFolder() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("MyNotionExportFiles-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = NotesStore(database: try AppDatabase.open(at: folder.appendingPathComponent("db/MyNotion.sqlite")),
                               clock: HybridLogicalClock(deviceId: UUID()))
        let sources = folder.appendingPathComponent("src", isDirectory: true)
        try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
        func source(_ name: String, _ text: String) throws -> (AttachmentRef, URL) {
            let url = sources.appendingPathComponent(UUID().uuidString)
            try Data(text.utf8).write(to: url)
            let sha = SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
            return (AttachmentRef(name: name, byteCount: text.utf8.count, contentType: "public.data", sha256: sha), url)
        }
        let (first, firstURL) = try source("отчёт.pdf", "первый")
        let (second, secondURL) = try source("отчёт.pdf", "второй")
        let (clash, clashURL) = try source("Подстраница.md", "не страница")
        let missing = AttachmentRef(name: "ещё в пути.png", byteCount: 1, contentType: "public.png", sha256: String(repeating: "0", count: 64))
        let files = [first.id: firstURL, second.id: secondURL, clash.id: clashURL]

        try store.write { transaction in
            let page = try transaction.createPage(title: "Страница")
            let child = try transaction.createPage(title: "Подстраница", parentId: page.id)
            var key: FractionalSortKey? = try transaction.blocks(ofPage: page.id).map(\.sortKey).max()
            for (kind, ref) in [(BlockKind.file, first), (.file, second), (.file, clash), (.image, missing)] {
                key = .between(key, nil)
                var props = BlockProps()
                props.attachment = ref
                try transaction.insertBlock(Block(pageId: page.id, kind: kind, sortKey: key!, props: props))
            }
            key = .between(key, nil)
            try transaction.insertBlock(Block(pageId: page.id, kind: .pageLink, linkedPageId: child.id, sortKey: key!))
        }

        let result = try MarkdownExporter(store: store, attachmentFile: { files[$0] }).export(into: folder)

        let pageFolder = result.folder.appendingPathComponent("Страница", isDirectory: true)
        #expect(try String(contentsOf: pageFolder.appendingPathComponent("отчёт.pdf"), encoding: .utf8) == "первый")
        #expect(try String(contentsOf: pageFolder.appendingPathComponent("отчёт (2).pdf"), encoding: .utf8) == "второй")
        #expect(try String(contentsOf: pageFolder.appendingPathComponent("Подстраница (2).md"), encoding: .utf8) == "не страница")
        #expect(FileManager.default.fileExists(atPath: pageFolder.appendingPathComponent("Подстраница.md").path))
        let markdown = try String(contentsOf: result.folder.appendingPathComponent("Страница.md"), encoding: .utf8)
        #expect(markdown.contains("[отчёт.pdf](Страница/отчёт.pdf)"))
        #expect(markdown.contains("[отчёт.pdf](Страница/отчёт%20%282%29.pdf)"))
        #expect(markdown.contains("[файл не скачан: ещё в пути.png]"))
        #expect(result.missingFileCount == 1)
        #expect(MarkdownExportResult.missingFilesMessage(count: 1) == "Не выгружено файлов: 1 — они ещё не скачались с сервера")
    }
}
