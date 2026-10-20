import Foundation
import Testing
@testable import NotesCore

/// Обложка и вид страницы (research R1, R2; contracts/page-operations.md, «Обложка»): каждая правка — одно поле
/// со своей меткой часов и один шаг ⌘Z; открытый документ подхватывает их, не перечитываясь.
@MainActor
@Suite("Обложка и вид страницы: операции ядра")
struct PageAppearanceOperationsTests {
    let folder: TemporaryFolder
    let wall = AdjustableWallClock(millis: 1_000)
    let store: NotesStore
    let tree: PageTreeOperations
    let undoManager = UndoManager()
    let page: Page

    init() throws {
        folder = try TemporaryFolder()
        store = try NotesStore(database: AppDatabase.open(at: folder.databaseURL),
                               clock: HybridLogicalClock(deviceId: UUID(), wallClock: wall.reading))
        undoManager.groupsByEvent = false
        tree = PageTreeOperations(store: store, undoManager: undoManager)
        page = try store.write { try $0.createPage(title: "Проекты") }
    }

    private func stored() throws -> Page {
        try #require(try store.pageOutline().first { $0.id == page.id })
    }

    private func step(_ action: () throws -> Void) rethrows {
        undoManager.beginUndoGrouping()
        defer { undoManager.endUndoGrouping() }
        try action()
    }

    @Test("Широкая и мелкий шрифт — по одному полю, «изменено» сдвигается, хозяин узнаёт о смене")
    func layoutFlagsAreOneFieldEdits() throws {
        let recorder = RecordingHook()
        store.addWriteHook(recorder)
        var reported: [UUID] = []
        tree.onAppearanceChange = { reported.append($0) }
        wall.set(5_000)

        try step { try tree.setFullWidth(page.id, true) }
        try step { try tree.setSmallText(page.id, true) }

        #expect(try stored().isFullWidth)
        #expect(try stored().isSmallText)
        #expect(recorder.transactions.map { $0.pages.map(\.changedFields) } == [[[.isFullWidth]], [[.isSmallText]]])
        #expect(try stored().updatedAt > page.updatedAt)
        #expect(reported == [page.id, page.id])
        #expect(undoManager.undoActionName == "Вид страницы")
    }

    @Test("То же значение — не правка; ⌘Z и ⇧⌘Z переключают обратно")
    func undoRedoLayout() throws {
        let recorder = RecordingHook()
        store.addWriteHook(recorder)
        // Без шага отмены: то же значение отмену не трогает (иначе пустая группа без открытой — исключение).
        try tree.setFullWidth(page.id, false)
        #expect(recorder.transactions.allSatisfy { $0.pages.isEmpty })
        #expect(!undoManager.canUndo)

        try step { try tree.setSmallText(page.id, true) }
        undoManager.undo()
        #expect(try !stored().isSmallText)
        undoManager.redo()
        #expect(try stored().isSmallText)
    }

    @Test("Обложка — одно поле cover; ⌘Z возвращает прежнюю")
    func setCover() throws {
        let recorder = RecordingHook()
        store.addWriteHook(recorder)
        try step { try tree.setCover(page.id, to: PageCover(source: .gallery("solid_red"))) }
        try step { try tree.setCover(page.id, to: PageCover(source: .gallery("solid_red"), offset: 0.3), actionName: "Положение обложки") }
        #expect(recorder.transactions.map { $0.pages.map(\.changedFields) } == [[[.cover]], [[.cover]]])
        #expect(undoManager.undoActionName == "Положение обложки")
        undoManager.undo()
        #expect(try stored().cover == PageCover(source: .gallery("solid_red")))
        undoManager.undo()
        #expect(try stored().cover == nil)
    }

    @Test("Открытый документ подхватывает обложку и вид; его автосохранение их не затирает")
    func documentAdoptsAppearance() throws {
        let document = PageDocument(content: try #require(try store.pageContent(page.id)))
        try step { try tree.setCover(page.id, to: PageCover(source: .gallery("gradients_3"))) }
        try step { try tree.setFullWidth(page.id, true) }
        try step { try tree.setSmallText(page.id, true) }

        document.adoptAppearance(of: try stored())
        #expect(document.page.cover == PageCover(source: .gallery("gradients_3")))
        #expect(document.page.isFullWidth)
        #expect(document.page.isSmallText)
        #expect(!document.hasUnsavedChanges)

        document.setTitle("Дела")
        let changes = document.unsavedChanges()
        let result = try store.write { try PageDocumentWriter.write(changes, pageId: page.id, in: $0) }
        document.didSave(changes, result: result)
        #expect(try stored().cover == PageCover(source: .gallery("gradients_3")))
        #expect(try stored().isFullWidth)
        #expect(try stored().title == "Дела")
    }
}
