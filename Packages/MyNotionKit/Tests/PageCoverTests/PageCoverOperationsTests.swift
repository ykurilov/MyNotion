import AppKit
import Foundation
import Testing
@testable import Attachments
@testable import NotesCore
@testable import PageCover

/// Операции обложки (contracts/page-operations.md, «Обложка»; research R1): из галереи, случайная, своя картинка,
/// сдвиг, убрать. Каждая — одна правка поля `cover` и один шаг ⌘Z; файл обложки не стирается, пока на него ссылаются.
@MainActor
@Suite("Обложка: операции")
struct PageCoverOperationsTests {
    let folder: CoverTestFolder
    let store: NotesStore
    let attachments: AttachmentStore
    let tree: PageTreeOperations
    let covers: PageCoverOperations
    let undoManager = UndoManager()
    let pageId: UUID

    init() throws {
        folder = try CoverTestFolder()
        store = NotesStore(database: try AppDatabase.open(at: folder.url.appendingPathComponent("MyNotion.sqlite")),
                           clock: HybridLogicalClock(deviceId: UUID()))
        store.addWriteHook(AttachmentReferenceCounter())
        attachments = AttachmentStore(store: store, folder: folder.url.appendingPathComponent("Attachments", isDirectory: true))
        undoManager.groupsByEvent = false
        tree = PageTreeOperations(store: store, undoManager: undoManager)
        covers = PageCoverOperations(tree: tree, attachments: attachments)
        pageId = try store.write { try $0.createPage(title: "Проекты").id }
    }

    private func stored() throws -> Page {
        try #require(try store.pageOutline().first { $0.id == pageId })
    }

    private func step<T>(_ action: () throws -> T) rethrows -> T {
        undoManager.beginUndoGrouping()
        defer { undoManager.endUndoGrouping() }
        return try action()
    }

    @Test("Из галереи: обложка по id, сдвиг по умолчанию 0,5; меняется только поле cover")
    func galleryCover() throws {
        let recorder = CoverRecordingHook()
        store.addWriteHook(recorder)
        var reported: [UUID] = []
        tree.onAppearanceChange = { reported.append($0) }

        try step { try covers.setGalleryCover("gradients_3", on: pageId) }

        #expect(try stored().cover == PageCover(source: .gallery("gradients_3")))
        #expect(try stored().cover?.offset == 0.5)
        #expect(recorder.changedFields == [[.cover]])
        #expect(reported == [pageId])
        #expect(undoManager.undoActionName == "Обложка")
    }

    @Test("«Добавить обложку» — случайная из галереи «Цвета и градиенты»")
    func randomCoverFromGallery() throws {
        var seen: Set<String> = []
        for seed in 0..<40 {
            var random = SeededRandom(seed: UInt64(seed))
            try step { try covers.addRandomCover(to: pageId, using: &random) }
            guard case .gallery(let id)? = try stored().cover?.source else { Issue.record("не из галереи"); return }
            seen.insert(id)
            try step { try covers.removeCover(from: pageId) }
        }
        #expect(seen.isSubset(of: Set(CoverGallery.ids)))
        #expect(seen.count > 3)
        #expect(CoverGallery.ids == ["solid_red", "solid_yellow", "solid_blue", "solid_beige", "gradients_8", "gradients_4",
                                     "gradients_2", "gradients_11", "gradients_10", "gradients_5", "gradients_3"])
    }

    @Test("Своя картинка — копия в хранилище файлов 002, обложка ссылается на неё")
    func imageCover() throws {
        let picture = try folder.file("Закат.png", CoverTestFolder.png(width: 40, height: 20))

        try step { try covers.setImageCover(from: picture, on: pageId) }

        let cover = try #require(try stored().cover)
        let ref = try #require(cover.attachment)
        #expect(ref.name == "Закат.png")
        #expect(cover.offset == 0.5)
        #expect(attachments.fileURL(for: ref.id) != nil)
        // Обложка — ссылка на файл: файл не сирота.
        #expect(try attachments.record(ref.id)?.orphanedAt == nil)
    }

    @Test("Не картинка — ошибка, обложка прежняя; больше 100 МБ — ошибка, обложка прежняя, файл не копируется")
    func rejectsNonImageAndTooLarge() throws {
        try step { try covers.setGalleryCover("solid_red", on: pageId) }
        let text = try folder.file("заметка.txt", Data("не картинка".utf8))
        #expect(throws: PageCoverError.notImage(name: "заметка.txt")) { try covers.setImageCover(from: text, on: pageId) }
        let huge = try folder.sparseFile("огромная.png", byteCount: AttachmentRef.maximumByteCount + 1)
        #expect(throws: PageCoverError.tooLarge(name: "огромная.png")) { try covers.setImageCover(from: huge, on: pageId) }

        #expect(try stored().cover == PageCover(source: .gallery("solid_red")))
        #expect(try attachments.allRecords().isEmpty)
        #expect(PageCoverError.notImage(name: "a.txt").errorDescription == "«a.txt» — не картинка")
        #expect(PageCoverError.tooLarge(name: "a.png").errorDescription == "Картинка больше 100 МБ — MyNotion такие не хранит")
    }

    @Test("Сдвиг «Сохранить положение» — одна правка offset; вне 0…1 урезается")
    func reposition() throws {
        try step { try covers.setGalleryCover("gradients_5", on: pageId) }
        try step { try covers.reposition(pageId, offset: 0.2) }
        #expect(try stored().cover == PageCover(source: .gallery("gradients_5"), offset: 0.2))
        #expect(undoManager.undoActionName == "Положение обложки")
        try step { try covers.reposition(pageId, offset: 1.7) }
        #expect(try stored().cover?.offset == 1)

        undoManager.undo()
        #expect(try stored().cover?.offset == 0.2)
        undoManager.undo()
        #expect(try stored().cover?.offset == 0.5)
    }

    @Test("Каждая правка — один шаг ⌘Z: галерея → своя → сдвиг → убрать и обратно")
    func eachEditIsOneUndoStep() throws {
        let picture = try folder.file("фото.png", CoverTestFolder.png(width: 30, height: 30))
        try step { try covers.setGalleryCover("solid_blue", on: pageId) }
        try step { try covers.setImageCover(from: picture, on: pageId) }
        let imageCover = try #require(try stored().cover)
        try step { try covers.reposition(pageId, offset: 0.9) }
        try step { try covers.removeCover(from: pageId) }
        #expect(try stored().cover == nil)
        #expect(undoManager.undoActionName == "Обложка")

        undoManager.undo()
        #expect(try stored().cover?.offset == 0.9)
        undoManager.undo()
        #expect(try stored().cover == imageCover)
        undoManager.undo()
        #expect(try stored().cover == PageCover(source: .gallery("solid_blue")))
        undoManager.undo()
        #expect(try stored().cover == nil)
        #expect(!undoManager.canUndo)

        undoManager.redo()
        undoManager.redo()
        #expect(try stored().cover == imageCover)
    }

    @Test("«Убрать» не стирает файл: он сирота с отметкой времени и возвращается ⌘Z; чужая ссылка держит его")
    func removedFileStaysWhileReferenced() throws {
        let picture = try folder.file("фото.png", CoverTestFolder.png(width: 30, height: 30))
        try step { try covers.setImageCover(from: picture, on: pageId) }
        let ref = try #require(try stored().cover?.attachment)
        // Та же картинка — обложка второй страницы (например, копии страницы).
        let otherId = try store.write { transaction in
            var page = try transaction.createPage(title: "Копия")
            page.cover = PageCover(source: .file(ref))
            try transaction.updatePage(page)
            return page.id
        }

        try step { try covers.removeCover(from: pageId) }
        #expect(try attachments.record(ref.id)?.orphanedAt == nil)
        #expect(attachments.fileURL(for: ref.id) != nil)

        try step { try covers.removeCover(from: otherId) }
        #expect(try attachments.record(ref.id)?.orphanedAt != nil)
        #expect(attachments.fileURL(for: ref.id) != nil)

        undoManager.undo()
        #expect(try attachments.record(ref.id)?.orphanedAt == nil)
    }

    @Test("Убрать обложку у страницы без обложки — не правка и не шаг отмены")
    func removeWithoutCoverIsNoOp() throws {
        // Без группы отмены: запись шага без открытой группы бросила бы исключение.
        try covers.removeCover(from: pageId)
        #expect(!undoManager.canUndo)
    }
}

/// Генератор с заданным зерном: случайная обложка в тесте повторяется.
struct SeededRandom: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) { state = seed &+ 0x9E37_79B9_7F4A_7C15 }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        return value ^ (value >> 31)
    }
}

/// Какие поля страниц меняла каждая транзакция.
final class CoverRecordingHook: NotesWriteHook, @unchecked Sendable {
    private(set) var changedFields: [Set<Page.Field>] = []

    func notesWillCommit(_ changes: NotesChanges, in transaction: NotesTransaction) throws {
        changedFields += changes.pages.map(\.changedFields)
    }
}

/// Пустая папка на время теста; стирается вместе с объектом.
final class CoverTestFolder: Sendable {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("MyNotionCoverTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: url) }

    func file(_ name: String, _ data: Data) throws -> URL {
        let file = url.appendingPathComponent("Оригиналы", isDirectory: true).appendingPathComponent(name)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: file)
        return file
    }

    /// Файл заданного размера без чтения в память (разреженный).
    func sparseFile(_ name: String, byteCount: Int) throws -> URL {
        let file = url.appendingPathComponent("Оригиналы", isDirectory: true).appendingPathComponent(name)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: file.path, contents: nil)
        let handle = try FileHandle(forWritingTo: file)
        try handle.truncate(atOffset: UInt64(byteCount))
        try handle.close()
        return file
    }

    /// Настоящий PNG заданного размера.
    static func png(width: Int, height: Int) throws -> Data {
        let image = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 4,
                                     hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        return try #require(image?.representation(using: .png, properties: [:]))
    }
}
