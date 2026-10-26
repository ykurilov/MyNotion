import AppKit
import Testing
@testable import NotesCore
@testable import PageEditor

// Внутри набора медиа-блоков: службы медиа общие на всех, наборы не должны идти одновременно.
extension MediaBlocksTests {
    /// Картинки вставки, которые скачиваются следом (из Notion): блок-заглушка сразу, файл — потом, без лишнего шага ⌘Z.
    @MainActor
    @Suite("Вставка: картинки, которые скачиваются следом")
    struct PastedImageDownloadTests {
        private static let notionImage = URL(string: "notion-block:3c90c3cc-0d44-4b50-8888-8dd25736052a")!

        private static func block(_ kind: BlockKind, _ text: String = "") -> Block {
            Block(pageId: UUID(), kind: kind, text: InlineText(text), sortKey: .between(nil, nil))
        }

        /// Блок разбора вставки: картинка со ссылкой, которую надо скачать, и именем файла.
        private static func pendingImage(_ url: URL = notionImage, name: String = "snimok.png") -> Block {
            var props = BlockProps()
            props.url = url
            props.title = name
            return Block(pageId: UUID(), kind: .image, sortKey: .between(nil, nil), props: props)
        }

        private func fixture(_ pasted: [Block]) throws -> (EditorFixture, FakeMediaServices) {
            let services = FakeMediaServices()
            MediaBlocks.install(services)
            let editor = try EditorFixture([.paragraph("Выше"), .paragraph()])
            editor.textView.pastedTextReader = { _, _, _, _, _ in pasted }
            editor.placeCaret(inBlock: 1)
            return (editor, services)
        }

        private func paste(_ editor: EditorFixture) {
            let pasteboard = NSPasteboard(name: NSPasteboard.Name("MyNotionTests-\(UUID().uuidString)"))
            pasteboard.clearContents()
            pasteboard.setString("Раз\nДва", forType: .string)
            editor.step { editor.textView.paste(from: pasteboard) }
        }

        private func until(_ condition: () -> Bool) async throws {
            for _ in 0..<10_000 where !condition() { await Task.yield() }
            try #require(condition())
        }

        @Test("Картинка встаёт сразу заглушкой «имя — Загружается…» на своём месте; скачалась — файл в блоке, ⌘Z — вся вставка")
        func downloadsAfterPaste() async throws {
            let (editor, services) = try fixture([Self.block(.paragraph, "Раз"), Self.pendingImage(), Self.block(.paragraph, "Два")])
            services.holdsDownloads = true
            services.downloads[Self.notionImage] = .success(try #require(FakeMediaServices.png(width: 40, height: 20)))

            paste(editor)

            #expect(editor.kinds == [.paragraph, .paragraph, .image, .paragraph])
            #expect(editor.texts == ["Выше", "Раз", "", "Два"])
            let placeholder = editor.document.blocks[2]
            let reserved = try #require(placeholder.props.attachment)
            #expect(reserved.name == "snimok.png")
            #expect(placeholder.props.url == nil, "Ссылка на блок Notion в страницу не попадает")
            #expect(placeholder.props.title == nil)
            try await until { !services.heldDownloads.isEmpty }
            #expect(MediaBlocks.availability(of: reserved) == .downloading)
            #expect(ImageBlockView(block: placeholder, width: 700).statusText == "snimok.png — Загружается…")
            #expect(services.downloaded == [Self.notionImage])

            services.releaseDownloads()
            await editor.textView.pastedDownloads?.value
            let done = try #require(editor.document.blocks[2].props.attachment)
            #expect(done.id == reserved.id)
            #expect(done.sha256 == "скачано")
            #expect(editor.document.blocks[2].props.pixelSize == PixelSize(width: 40, height: 20))
            #expect(MediaBlocks.availability(of: done).fileURL != nil)

            editor.undo()
            #expect(editor.texts == ["Выше", ""])
            #expect(editor.kinds == [.paragraph, .paragraph])
        }

        @Test("Не скачалась — блок остаётся с пометкой «имя — причина», текст вставлен, окна с ошибкой нет")
        func failedDownloadLeavesNote() async throws {
            let (editor, services) = try fixture([Self.block(.paragraph, "Раз"), Self.pendingImage(name: "схема.png")])
            services.downloads[Self.notionImage] = .failure(MediaImportError(message: "Нет доступа к странице в Notion"))

            paste(editor)
            await editor.textView.pastedDownloads?.value

            #expect(editor.kinds == [.paragraph, .paragraph, .image, .paragraph])
            let block = editor.document.blocks[2]
            #expect(MediaBlocks.availability(of: block.props.attachment) == .failed("Нет доступа к странице в Notion"))
            #expect(ImageBlockView(block: block, width: 700).statusText == "схема.png — Нет доступа к странице в Notion")
            #expect(editor.textView.window?.attachedSheet == nil)
        }

        @Test("Несколько картинок качаются по очереди; одна не скачалась — остальные всё равно на местах")
        func severalImages() async throws {
            let second = URL(string: "notion-block:11111111-1111-4111-8111-111111111111")!
            let (editor, services) = try fixture([Self.pendingImage(name: "a.png"), Self.block(.paragraph, "Раз"),
                                                  Self.pendingImage(second, name: "b.png")])
            services.downloads[Self.notionImage] = .failure(MediaImportError(message: "Нет связи с Notion"))
            services.downloads[second] = .success(try #require(FakeMediaServices.png(width: 10, height: 10)))

            paste(editor)
            await editor.textView.pastedDownloads?.value

            #expect(services.downloaded == [Self.notionImage, second])
            let images = editor.document.blocks.filter { $0.kind == .image }
            #expect(images.map { $0.props.attachment?.name } == ["a.png", "b.png"])
            #expect(MediaBlocks.availability(of: images[0].props.attachment) == .failed("Нет связи с Notion"))
            #expect(MediaBlocks.availability(of: images[1].props.attachment).fileURL != nil)
        }

        @Test("Вставку отменили до конца скачивания — файл приходит, а страница остаётся как до вставки")
        func undoBeforeDownloadFinishes() async throws {
            let (editor, services) = try fixture([Self.block(.paragraph, "Раз"), Self.pendingImage()])
            services.holdsDownloads = true
            services.downloads[Self.notionImage] = .success(try #require(FakeMediaServices.png(width: 4, height: 4)))

            paste(editor)
            try await until { !services.heldDownloads.isEmpty }
            editor.undo()
            services.releaseDownloads()
            await editor.textView.pastedDownloads?.value

            #expect(editor.texts == ["Выше", ""])
            #expect(editor.kinds == [.paragraph, .paragraph])
        }

        @Test("Обычная картинка с файлом из вставки (из самого MyNotion) не скачивается")
        func readyImagesUntouched() async throws {
            var ready = Self.block(.image)
            ready.props.attachment = AttachmentRef(name: "готово.png", byteCount: 1, contentType: "public.png", sha256: "1")
            let (editor, services) = try fixture([Self.block(.paragraph, "Раз"), ready])

            paste(editor)
            await editor.textView.pastedDownloads?.value

            #expect(services.downloaded.isEmpty)
            #expect(editor.document.blocks[2].props.attachment?.name == "готово.png")
        }
    }
}
