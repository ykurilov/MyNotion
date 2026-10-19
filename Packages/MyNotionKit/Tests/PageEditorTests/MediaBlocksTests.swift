import AppKit
import Testing
@testable import NotesCore
@testable import PageEditor
import VisualStyle

/// Картинка, файл, видео, закладка в редакторе (contracts/blocks-and-keys.md, «Картинка», «Файл», «Видео», «Закладка»).
@MainActor
@Suite("Блоки картинки, файла, видео и закладки", .serialized)
struct MediaBlocksTests {
    typealias Spec = EditorFixture.Spec

    private func fixture(_ specs: [Spec] = [.paragraph("До"), .paragraph(), .paragraph("После")]) throws -> (EditorFixture, FakeMediaServices) {
        let services = FakeMediaServices()
        MediaBlocks.install(services)
        return (try EditorFixture(specs), services)
    }

    private func asyncStep(_ fixture: EditorFixture, _ action: () async -> Void) async {
        fixture.undoManager.beginUndoGrouping()
        await action()
        fixture.undoManager.endUndoGrouping()
    }

    private func imageBlock(width: Double? = nil, pixels: PixelSize? = PixelSize(width: 1600, height: 900), caption: String = "") -> Block {
        var props = BlockProps()
        props.attachment = AttachmentRef(name: "фото.png", byteCount: 2_400_000, contentType: "public.png", sha256: String(repeating: "0", count: 64))
        props.width = width
        props.pixelSize = pixels
        return Block(pageId: UUID(), kind: .image, text: InlineText(caption), sortKey: .between(nil, nil), props: props)
    }

    // MARK: Картинка

    @Test("Программы и скрипты из файлов не запускаются — показываются в Finder; документы открываются")
    func runnableFilesAreNotOpenedDirectly() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("MyNotionOpenTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        func file(_ name: String, executable: Bool = false) throws -> URL {
            let url = folder.appendingPathComponent(name)
            try Data("x".utf8).write(to: url)
            if executable { try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path) }
            return url
        }
        for name in ["Установка.app", "запуск.command", "скрипт.sh", "пакет.pkg", "ссылка.webloc", "a.terminal", "a.workflow", "a.scpt"] {
            #expect(!MediaFileActions.opensDirectly(try file(name)), "\(name)")
        }
        #expect(!MediaFileActions.opensDirectly(try file("без расширения", executable: true)))
        #expect(MediaFileActions.opensDirectly(try file("отчёт.pdf")))
        #expect(MediaFileActions.opensDirectly(try file("заметки.txt")))
    }

    @Test("Картинка по ширине колонки с пропорциями файла; ширина — доля колонки 10–100 %; подпись добавляет строку")
    func imageGeometry() throws {
        _ = try fixture()
        let factory = MediaBlockViewFactory(kind: .image)
        let full = try #require(factory.height(for: imageBlock(), width: 800))
        let half = try #require(factory.height(for: imageBlock(width: 0.5), width: 800))
        #expect(full == 450 + 2 * Metrics.Media.verticalPadding)
        #expect(half == 225 + 2 * Metrics.Media.verticalPadding)
        let captioned = try #require(factory.height(for: imageBlock(caption: "Закат"), width: 800))
        #expect(captioned == full + Metrics.Media.captionHeight)
        #expect(ImageBlockView.clampedWidth(0.05) == 0.1)
        #expect(ImageBlockView.clampedWidth(1.4) == 1)
        #expect(ImageBlockView.clampedWidth(0.42) == 0.42)
    }

    @Test("Ширина и подпись картинки пишутся в блок одним шагом ⌘Z")
    func imageWidthAndCaption() throws {
        let (fixture, _) = try fixture([.paragraph("До"), Spec(kind: .image), .paragraph("После")])
        let id = fixture.document.blocks[1].id
        fixture.step { fixture.textView.setMediaWidth(0.05, ofBlock: id) }
        #expect(fixture.document.blocks[1].props.width == 0.1)
        fixture.step { fixture.textView.setMediaCaption("Закат над морем", ofBlock: id) }
        #expect(fixture.document.blocks[1].text.string == "Закат над морем")
        #expect(fixture.textView.string == "До\n\u{FFFC}\nПосле\n", "подпись — в тексте блока, не на странице")
        fixture.undo()
        #expect(fixture.document.blocks[1].text.string == "")
        fixture.undo()
        #expect(fixture.document.blocks[1].props.width == nil)
    }

    @Test("Пока файла нет — серая заглушка с именем и «Загружается…» или «Ждёт отправки с другого Mac»")
    func placeholders() throws {
        let (_, services) = try fixture()
        let block = imageBlock()
        services.availability = .downloading
        let downloading = ImageBlockView(block: block, width: 700)
        #expect(downloading.statusText == "фото.png — Загружается…")
        services.availability = .waitingForOtherMac
        let waiting = ImageBlockView(block: block, width: 700)
        #expect(waiting.statusText == "фото.png — Ждёт отправки с другого Mac")
        services.availability = .failed("Файл пришёл повреждённым")
        #expect(ImageBlockView(block: block, width: 700).statusText == "фото.png — Файл пришёл повреждённым")
    }

    // MARK: Файл

    @Test("Блок-файл: значок листа цветом вторичного текста (виден в светлой теме), имя и размер «2,4 МБ»")
    func fileRow() throws {
        let (_, services) = try fixture()
        services.availability = .ready(URL(fileURLWithPath: "/tmp/отчёт.pdf"))
        var props = BlockProps()
        props.attachment = AttachmentRef(name: "отчёт.pdf", byteCount: 2_400_000, contentType: "com.adobe.pdf", sha256: "")
        let view = FileBlockView(block: Block(pageId: UUID(), kind: .file, sortKey: .between(nil, nil), props: props), width: 700)
        #expect(view.nameText == "отчёт.pdf")
        #expect(view.sizeText == "2,4 МБ")
        #expect(view.iconImage != nil)
        #expect(view.iconTint == Palette.textSecondary)
        let factory = MediaBlockViewFactory(kind: .file)
        #expect(factory.height(for: view.block, width: 700) == Metrics.Media.fileRowHeight + 2 * Metrics.Media.verticalPadding)
    }

    // MARK: Вставка

    @Test("Файлы из Finder: картинка — картинка с размером в пикселях, видео — видео, прочее — файл; пустой абзац заменяется")
    func insertFromFinder() async throws {
        let (fixture, services) = try fixture()
        let png = try services.sampleFile("снимок.png", pngWidth: 40, height: 30)
        let movie = try services.sampleFile("ролик.mov")
        let pdf = try services.sampleFile("договор.pdf")

        await asyncStep(fixture) { await fixture.textView.insertFiles([png, movie, pdf], at: 1) }

        #expect(fixture.kinds == [.paragraph, .image, .video, .file, .paragraph])
        #expect(fixture.document.blocks[1].props.pixelSize == PixelSize(width: 40, height: 30))
        #expect(fixture.document.blocks[2].props.videoSource == .file)
        #expect(fixture.document.blocks[3].props.attachment?.name == "договор.pdf")
        #expect(services.imported.map(\.lastPathComponent) == ["снимок.png", "ролик.mov", "договор.pdf"])
        fixture.undo()
        #expect(fixture.kinds == [.paragraph, .paragraph, .paragraph])
    }

    @Test("Файл копируется — блок сразу, заглушка «Копируется… N %»; готово — файл и SHA-256 в блоке, без лишнего шага ⌘Z")
    func copyPlaceholder() async throws {
        let (fixture, services) = try fixture()
        let pdf = try services.sampleFile("отчёт.pdf")
        services.holdsCopies = true
        let insertion = Task { await asyncStep(fixture) { await fixture.textView.insertFiles([pdf], at: 1) } }
        try await until { !services.progressReporters.isEmpty }
        let block = fixture.document.blocks[1]
        #expect(block.kind == .file)
        #expect(MediaBlocks.availability(of: block.props.attachment) == .copying(0))
        #expect(FileBlockView(block: block, width: 700).sizeText.hasSuffix("Копируется… 0 %"))

        services.progressReporters[0](0.4)
        try await until { MediaBlocks.availability(of: block.props.attachment) == .copying(0.4) }
        #expect(FileBlockView(block: block, width: 700).sizeText.hasSuffix("Копируется… 40 %"))

        services.releaseCopies()
        await insertion.value
        #expect(fixture.document.blocks[1].props.attachment?.sha256 == "готово")
        #expect(MediaBlocks.availability(of: fixture.document.blocks[1].props.attachment).fileURL == pdf)
        fixture.undo()
        #expect(fixture.kinds == [.paragraph, .paragraph, .paragraph])
    }

    /// Ждать условия, отдавая ход другим задачам главного потока.
    private func until(_ condition: () -> Bool) async throws {
        for _ in 0..<10_000 where !condition() { await Task.yield() }
        try #require(condition())
    }

    @Test("Больше 100 МБ — сообщение, блок не создаётся")
    func tooLarge() async throws {
        let (fixture, services) = try fixture()
        services.importError = "Файл больше 100 МБ — MyNotion такие не хранит"
        await asyncStep(fixture) { await fixture.textView.insertFiles([URL(fileURLWithPath: "/tmp/огромный.mov")], at: 1) }
        #expect(fixture.kinds == [.paragraph, .paragraph, .paragraph])
        #expect(fixture.textView.lastAttachmentError == "Файл больше 100 МБ — MyNotion такие не хранит")
    }

    @Test("⌘V картинки из буфера — блок-картинка PNG")
    func pasteImage() async throws {
        let (fixture, services) = try fixture()
        fixture.placeCaret(inBlock: 1)
        let pasteboard = NSPasteboard(name: .init("MediaBlocksTests-\(UUID().uuidString)"))
        pasteboard.clearContents()
        pasteboard.setData(try #require(FakeMediaServices.png(width: 20, height: 10)), forType: .png)
        // «Вставить» включено и при одной картинке в буфере.
        #expect(fixture.textView.readablePasteboardTypes.contains(.png))
        #expect(fixture.textView.readablePasteboardTypes.contains(.fileURL))

        await asyncStep(fixture) { await fixture.textView.pasteAttachments(from: pasteboard) }

        #expect(fixture.kinds == [.paragraph, .image, .paragraph])
        #expect(services.importedData.first?.name == "Картинка.png")
        #expect(fixture.document.blocks[1].props.pixelSize == PixelSize(width: 20, height: 10))
    }

    @Test("Ссылка на YouTube в пустой строке — меню «Встроить видео / Закладка / Ссылка»")
    func pastedVideoLinkMenu() throws {
        let (fixture, _) = try fixture()
        fixture.placeCaret(inBlock: 1)
        let pasteboard = NSPasteboard(name: .init("MediaBlocksTests-\(UUID().uuidString)"))
        pasteboard.clearContents()
        pasteboard.setString("https://youtu.be/dQw4w9WgXcQ", forType: .string)

        fixture.step { fixture.textView.paste(from: pasteboard) }
        #expect(fixture.textView.pastedLinkMenuTitles == ["Встроить видео", "Закладка", "Ссылка"])
        #expect(fixture.texts[1] == "https://youtu.be/dQw4w9WgXcQ", "пока меню открыто — ссылка вставлена текстом, как у Notion")

        fixture.step { fixture.textView.choosePastedLink(.embed) }
        #expect(fixture.kinds == [.paragraph, .video, .paragraph])
        #expect(fixture.document.blocks[1].props.videoSource == .youtube)
        #expect(fixture.document.blocks[1].props.url == URL(string: "https://youtu.be/dQw4w9WgXcQ"))
        #expect(fixture.textView.pastedLinkMenuTitles == nil)
        fixture.undo()
        #expect(fixture.kinds == [.paragraph, .paragraph, .paragraph])
        #expect(fixture.texts[1] == "https://youtu.be/dQw4w9WgXcQ")
    }

    @Test("Из меню ссылки «Закладка» — карточка с адресом; «Ссылка» — остаётся текстом-ссылкой")
    func pastedLinkBookmarkOrText() throws {
        let (fixture, _) = try fixture()
        let pasteboard = NSPasteboard(name: .init("MediaBlocksTests-\(UUID().uuidString)"))
        pasteboard.clearContents()
        pasteboard.setString("https://vimeo.com/76979871", forType: .string)
        fixture.placeCaret(inBlock: 1)
        fixture.step { fixture.textView.paste(from: pasteboard) }
        fixture.step { fixture.textView.choosePastedLink(.bookmark) }
        #expect(fixture.kinds == [.paragraph, .bookmark, .paragraph])
        #expect(fixture.document.blocks[1].props.url == URL(string: "https://vimeo.com/76979871"))

        fixture.undo()
        fixture.undo()
        #expect(fixture.texts[1] == "")
        fixture.placeCaret(inBlock: 1)
        fixture.step { fixture.textView.paste(from: pasteboard) }
        fixture.step { fixture.textView.choosePastedLink(.link) }
        #expect(fixture.kinds == [.paragraph, .paragraph, .paragraph])
        #expect(fixture.document.blocks[1].text.runs.contains { if case .link = $0.style { true } else { false } })
    }

    @Test("Ссылка не на видео или в строке с текстом — обычная вставка без меню")
    func plainLinkPaste() throws {
        let (fixture, _) = try fixture()
        let pasteboard = NSPasteboard(name: .init("MediaBlocksTests-\(UUID().uuidString)"))
        pasteboard.clearContents()
        pasteboard.setString("https://youtu.be/dQw4w9WgXcQ", forType: .string)
        fixture.placeCaret(inBlock: 0, at: nil)
        fixture.step { fixture.textView.paste(from: pasteboard) }
        #expect(fixture.textView.pastedLinkMenuTitles == nil)
        #expect(fixture.texts[0] == "Доhttps://youtu.be/dQw4w9WgXcQ")
    }

    @Test("Закладка открывается только по http и https: smb, ssh, vnc, file с другого Mac или из импорта — нет")
    func bookmarkOpensOnlyWebAddresses() throws {
        let (_, services) = try fixture()
        for text in ["smb://nas/share", "ssh://host", "vnc://host", "file://localhost/Applications/Calculator.app", "x-apple.systempreferences:"] {
            MediaBlocks.openLink(try #require(URL(string: text)))
        }
        #expect(services.opened.isEmpty)
        MediaBlocks.openLink(try #require(URL(string: "https://example.com")))
        #expect(services.opened == [URL(string: "https://example.com")!])
    }

    @Test("«/» → «Закладка» с адресом — карточка; данные сайта приходят позже и не отдельный шаг ⌘Z")
    func bookmarkFromSlashMenu() async throws {
        let (fixture, services) = try fixture()
        services.preview = MediaLinkPreview(title: "Пример", description: "Описание", image: nil, icon: nil)
        await asyncStep(fixture) { await fixture.textView.insertLink(URL(string: "https://example.com")!, as: .bookmark, at: 1) }
        #expect(fixture.kinds == [.paragraph, .bookmark, .paragraph])
        let bookmark = fixture.document.blocks[1].props
        #expect(bookmark.url == URL(string: "https://example.com"))
        #expect(bookmark.title == "Пример")
        #expect(bookmark.description == "Описание")
        #expect(bookmark.fetchedAt != nil)
        // Данные сайта, пришедшие позже, не закрывают меню «/», которое Юрий уже открыл.
        fixture.placeCaret(inBlock: 2)
        fixture.type("/")
        #expect(fixture.textView.popups.isOpen)
        fixture.textView.applyFetchedPreview(MediaLinkPreview(title: "Новее", description: nil, image: nil, icon: nil),
                                             toBlock: fixture.document.blocks[1].id)
        #expect(fixture.textView.popups.isOpen)
        #expect(fixture.document.blocks[1].props.title == "Новее")
        fixture.textView.popups.close()
        fixture.undo()
        fixture.undo()
        #expect(fixture.kinds == [.paragraph, .paragraph, .paragraph])
    }

    @Test("Меню «/» показывает «Картинка», «Файл», «Видео», «Закладка»")
    func slashMenuItems() throws {
        _ = try fixture()
        let titles = PopupMenuItem.slashItems(matching: "").map(\.title)
        for title in ["Картинка", "Файл", "Видео", "Закладка"] { #expect(titles.contains(title)) }
        #expect(PopupMenuItem.slashItems(matching: "youtube").map(\.title) == ["Видео"])
        #expect(PopupMenuItem.slashItems(matching: "фото").map(\.title) == ["Картинка"])
    }
}

/// Хранилище файлов и сеть редактора в памяти.
@MainActor
final class FakeMediaServices: MediaBlockServices {
    var availability: MediaAvailability = .downloading
    var importError: String?
    var preview = MediaLinkPreview(title: nil, description: nil, image: nil, icon: nil)
    private(set) var imported: [URL] = []
    private(set) var importedData: [(name: String, data: Data)] = []
    private var copies: [UUID: URL] = [:]
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("MediaBlocksTests-\(UUID().uuidString)")

    func availability(of ref: AttachmentRef) -> MediaAvailability {
        copies[ref.id].map(MediaAvailability.ready) ?? availability
    }

    /// Копии ждут `releaseCopies()`: так видно заглушку копирования.
    var holdsCopies = false
    private(set) var progressReporters: [@Sendable (Double) -> Void] = []
    private var heldCopies: [CheckedContinuation<Void, Never>] = []

    func reserveFileImport(at url: URL) throws -> AttachmentRef {
        if let importError { throw MediaImportError(message: importError) }
        let size = (try? Data(contentsOf: url).count) ?? 0
        return AttachmentRef(name: url.lastPathComponent, byteCount: size, contentType: Self.contentType(url), sha256: "")
    }

    func importFile(at url: URL, into reserved: AttachmentRef, progress: @escaping @Sendable (Double) -> Void) async throws -> AttachmentRef {
        imported.append(url)
        if holdsCopies {
            progressReporters.append(progress)
            await withCheckedContinuation { heldCopies.append($0) }
        }
        progress(1)
        var ref = reserved
        ref.sha256 = "готово"
        copies[ref.id] = url
        return ref
    }

    func releaseCopies() {
        heldCopies.forEach { $0.resume() }
        heldCopies = []
    }

    func importFile(at url: URL) async throws -> AttachmentRef {
        if let importError { throw MediaImportError(message: importError) }
        imported.append(url)
        let data = try Data(contentsOf: url)
        let ref = AttachmentRef(name: url.lastPathComponent, byteCount: data.count, contentType: Self.contentType(url), sha256: "")
        copies[ref.id] = url
        return ref
    }

    func importData(_ data: Data, name: String, contentType: String) async throws -> AttachmentRef {
        importedData.append((name, data))
        let url = folder.appendingPathComponent(UUID().uuidString + "-" + name)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try data.write(to: url)
        let ref = AttachmentRef(name: name, byteCount: data.count, contentType: contentType, sha256: "")
        copies[ref.id] = url
        return ref
    }

    func downloadFile(from url: URL) async throws -> AttachmentRef { throw MediaImportError(message: "нет сети") }

    func videoSource(for url: URL) -> VideoSource? {
        let host = url.host ?? ""
        if host.contains("youtu") { return .youtube }
        if host.contains("vimeo") { return .vimeo }
        return nil
    }

    func linkPreview(for url: URL) async -> MediaLinkPreview { preview }
    func videoCover(for url: URL) async -> MediaLinkPreview? { nil }
    func posterImage(forVideoAt url: URL) async -> NSImage? { nil }
    func makePlayer(for block: Block, fileURL: URL?) -> NSView? { nil }
    private(set) var opened: [URL] = []
    func open(_ url: URL) { opened.append(url) }

    func sampleFile(_ name: String, pngWidth: Int? = nil, height: Int = 0) throws -> URL {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(name)
        let data = pngWidth.flatMap { Self.png(width: $0, height: height) } ?? Data("содержимое \(name)".utf8)
        try data.write(to: url)
        return url
    }

    static func png(width: Int, height: Int) -> Data? {
        let image = NSImage(size: NSSize(width: width, height: height))
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 4,
                                   hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        image.addRepresentation(rep!)
        // Непрозрачная заливка: картинку видно на снимке.
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep!)
        NSColor.systemTeal.setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()
        NSGraphicsContext.restoreGraphicsState()
        return rep?.representation(using: .png, properties: [:])
    }

    private static func contentType(_ url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "png": "public.png"
        case "mov": "com.apple.quicktime-movie"
        case "pdf": "com.adobe.pdf"
        default: "public.data"
        }
    }
}

struct MediaImportError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

extension MediaBlocksTests {
    /// Снимки окна (галерея) рисуют виды через `cacheDisplay`: картинка, заглушка, рамка закладки должны рисоваться
    /// самим видом, а не только содержимым слоя.
    @Test("Картинка, заглушка и карточка закладки видны на снимке вида")
    func viewsDrawThemselves() async throws {
        let services = FakeMediaServices()
        MediaBlocks.install(services)
        let png = try services.sampleFile("снимок.png", pngWidth: 400, height: 200)
        let ref = try await services.importFile(at: png)
        var props = BlockProps()
        props.attachment = ref
        props.pixelSize = PixelSize(width: 400, height: 200)
        let block = Block(pageId: UUID(), kind: .image, sortKey: .between(nil, nil), props: props)
        let factory = MediaBlockViewFactory(kind: .image)
        let height = try #require(factory.height(for: block, width: 600))
        _ = await ImageThumbnailCache.shared.thumbnail(png, maxPixelSize: Int(600 * (NSScreen.main?.backingScaleFactor ?? 2)))
        let image = try #require(factory.makeView(for: block, context: BlockViewContext(textView: nil, width: 600)))
        image.frame = NSRect(x: 0, y: 0, width: 600, height: height)
        // Уменьшенная картинка может прийти из фона чуть позже (кэш вытеснен соседними тестами) — ждём до 2 с.
        var inkWidth: CGFloat = 0
        for _ in 0..<40 {
            inkWidth = try ViewPixels(image, appearance: .aqua).inkBounds(in: image.bounds)?.width ?? 0
            if inkWidth >= 590 { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(inkWidth >= 590, "картинка во всю ширину не нарисовалась")

        services.availability = .downloading
        var waiting = props
        waiting.attachment = AttachmentRef(name: "нет.png", byteCount: 1, contentType: "public.png", sha256: "")
        let placeholder = ImageBlockView(block: Block(pageId: UUID(), kind: .image, sortKey: .between(nil, nil), props: waiting), width: 600)
        placeholder.frame.size = NSSize(width: 600, height: height)
        #expect(try ViewPixels(placeholder, appearance: .darkAqua).inkBounds(in: placeholder.bounds, threshold: 0.02) != nil,
                "серая заглушка не нарисовалась")

        var bookmark = BlockProps()
        bookmark.url = URL(string: "https://example.com")
        let card = BookmarkBlockView(block: Block(pageId: UUID(), kind: .bookmark, sortKey: .between(nil, nil), props: bookmark), width: 600)
        card.frame.size = NSSize(width: 600, height: Metrics.Media.bookmarkHeight + 2 * Metrics.Media.verticalPadding)
        #expect(try ViewPixels(card, appearance: .aqua).inkBounds(in: card.bounds, threshold: 0.05) != nil, "карточка закладки не нарисовалась")
    }
}

extension MediaBlocksTests {
    /// Снимки самих видов для сверки глазами (пока страница не показывает виды-вложения — их чинит US4):
    /// `MYNOTION_MEDIA_SNAPSHOTS=<папка> swift test --filter mediaViewSnapshots`.
    @Test("Снимки медиа-видов в обеих темах", .enabled(if: ProcessInfo.processInfo.environment["MYNOTION_MEDIA_SNAPSHOTS"] != nil))
    func mediaViewSnapshots() async throws {
        let folder = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["MYNOTION_MEDIA_SNAPSHOTS"]))
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let services = FakeMediaServices()
        MediaBlocks.install(services)
        let png = try services.sampleFile("закат.png", pngWidth: 1600, height: 900)
        let ref = try await services.importFile(at: png)
        _ = await ImageThumbnailCache.shared.thumbnail(png, maxPixelSize: 1440)
        func block(_ kind: BlockKind, _ caption: String = "", _ props: BlockProps) -> Block {
            Block(pageId: UUID(), kind: kind, text: InlineText(caption), sortKey: .between(nil, nil), props: props)
        }
        var image = BlockProps()
        image.attachment = ref
        image.pixelSize = PixelSize(width: 1600, height: 900)
        var half = image
        half.width = 0.5
        var missing = image
        missing.attachment = AttachmentRef(name: "фото с другого Mac.png", byteCount: 1, contentType: "public.png", sha256: "")
        var file = BlockProps()
        file.attachment = AttachmentRef(name: "Договор аренды.pdf", byteCount: 2_400_000, contentType: "com.adobe.pdf", sha256: "")
        var youtube = BlockProps()
        youtube.videoSource = .youtube
        youtube.url = URL(string: "https://www.youtube.com/watch?v=dQw4w9WgXcQ")
        youtube.title = "Видео YouTube"
        youtube.poster = ref
        var bookmark = BlockProps()
        bookmark.url = URL(string: "https://www.notion.com/help/guides")
        bookmark.title = "Руководства Notion — как устроены страницы и блоки"
        bookmark.description = "Пошаговые руководства: страницы, блоки, базы данных и совместная работа. Всё, чтобы начать быстро."
        bookmark.image = ref
        let samples: [(String, Block, MediaAvailability?)] = [
            ("image", block(.image, "Закат над морем", image), nil),
            ("image-half", block(.image, "", half), nil),
            ("image-waiting", block(.image, "", missing), .waitingForOtherMac),
            ("file", block(.file, "", file), .ready(png)),
            ("video-youtube", block(.video, "Подпись видео", youtube), nil),
            ("bookmark", block(.bookmark, "", bookmark), nil),
        ]
        for (name, sample, availability) in samples {
            services.availability = availability ?? .downloading
            for appearance in [NSAppearance.Name.aqua, .darkAqua] {
                let factory = MediaBlockViewFactory(kind: sample.kind)
                let height = try #require(factory.height(for: sample, width: 708))
                let view = try #require(factory.makeView(for: sample, context: BlockViewContext(textView: nil, width: 708)))
                let canvas = NSView(frame: NSRect(x: 0, y: 0, width: 740, height: height + 32))
                canvas.wantsLayer = true
                canvas.appearance = NSAppearance(named: appearance)
                view.frame = NSRect(x: 16, y: 16, width: 708, height: height)
                canvas.addSubview(view)
                let background = NSView(frame: canvas.bounds)
                canvas.addSubview(background, positioned: .below, relativeTo: view)
                canvas.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(50))
                let rep = try #require(canvas.bitmapImageRepForCachingDisplay(in: canvas.bounds))
                canvas.appearance?.performAsCurrentDrawingAppearance {
                    NSGraphicsContext.saveGraphicsState()
                    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
                    (appearance == .aqua ? NSColor.white : NSColor(white: 0.098, alpha: 1)).setFill()
                    canvas.bounds.fill()
                    NSGraphicsContext.restoreGraphicsState()
                }
                canvas.cacheDisplay(in: canvas.bounds, to: rep)
                try rep.representation(using: .png, properties: [:])?
                    .write(to: folder.appendingPathComponent("\(name)-\(appearance == .aqua ? "light" : "dark").png"))
            }
        }
    }
}

extension MediaBlocksTests {
    @Test("Вид картинки стоит на странице; новая ширина и пришедший файл — вид заново на том же месте")
    func viewOnPageFollowsBlock() async throws {
        let (fixture, services) = try fixture()
        let png = try services.sampleFile("снимок.png", pngWidth: 400, height: 200)
        await asyncStep(fixture) { await fixture.textView.insertFiles([png], at: 1) }
        fixture.textView.layoutSubtreeIfNeeded()
        fixture.textView.blockViews.update()
        func mediaViews() -> [MediaBlockView] {
            func all(_ view: NSView) -> [MediaBlockView] { ((view as? MediaBlockView).map { [$0] } ?? []) + view.subviews.flatMap(all) }
            return all(fixture.textView)
        }
        let id = fixture.document.blocks[1].id
        #expect(mediaViews().map(\.block.id) == [id])
        fixture.step { fixture.textView.setMediaWidth(0.5, ofBlock: id) }
        #expect(mediaViews().first?.block.props.width == 0.5)
        let before = try #require(mediaViews().first)
        NotificationCenter.default.post(name: AttachmentRef.availabilityDidChange, object: try #require(before.block.props.attachment?.id))
        try await Task.sleep(for: .milliseconds(50))
        #expect(mediaViews().count == 1)
        #expect(mediaViews().first !== before)
    }
}
