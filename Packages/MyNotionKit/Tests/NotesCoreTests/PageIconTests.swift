import Foundation
import Testing
@testable import NotesCore

/// Иконка страницы (FR-034): ставится, меняется и убирается одной правкой поля `icon` со своей меткой часов,
/// отменяется ⌘Z; открытый документ подхватывает её, не перечитываясь и не затирая её своим автосохранением.
@MainActor
@Suite("Иконка страницы")
struct PageIconTests {
    let folder: TemporaryFolder
    let wall = AdjustableWallClock(millis: 1_000)
    let store: NotesStore
    let tree: PageTreeOperations
    let page: Page

    init() throws {
        folder = try TemporaryFolder()
        store = try NotesStore(database: AppDatabase.open(at: folder.databaseURL),
                               clock: HybridLogicalClock(deviceId: UUID(), wallClock: wall.reading))
        tree = PageTreeOperations(store: store)
        page = try store.write { try $0.createPage(title: "Проекты") }
    }

    private func stored() throws -> Page {
        try #require(try store.pageOutline().first { $0.id == page.id })
    }

    @Test("Ставится одной транзакцией: меняется только поле icon и его метка часов")
    func setIconIsOneFieldEdit() throws {
        let recorder = RecordingHook()
        store.addWriteHook(recorder)
        var reported: [UUID: String?] = [:]
        tree.onIconChange = { reported[$0] = $1 }
        wall.set(2_000)

        try tree.setIcon(page.id, to: "📘")

        #expect(try stored().icon == "📘")
        #expect(try stored().title == "Проекты")
        #expect(recorder.transactions.count == 1)
        #expect(recorder.transactions.first?.pages.map(\.changedFields) == [[.icon]])
        #expect(try stored().fieldClocks.icon != page.fieldClocks.icon)
        #expect(try stored().fieldClocks.title == page.fieldClocks.title)
        #expect(reported == [page.id: "📘"])
    }

    @Test("Убирается и меняется; та же иконка — не правка")
    func removeAndReplace() throws {
        try tree.setIcon(page.id, to: "📘")
        let recorder = RecordingHook()
        store.addWriteHook(recorder)

        try tree.setIcon(page.id, to: "📘")
        #expect(recorder.transactions.allSatisfy { $0.pages.isEmpty })
        try tree.setIcon(page.id, to: "🌿")
        #expect(try stored().icon == "🌿")
        try tree.setIcon(page.id, to: nil)
        #expect(try stored().icon == nil)
    }

    @Test("Не эмодзи и два эмодзи сразу не ставятся")
    func rejectsNonEmoji() throws {
        #expect(throws: NotesStoreError.self) { try tree.setIcon(page.id, to: "ab") }
        #expect(throws: NotesStoreError.self) { try tree.setIcon(page.id, to: "📘🌿") }
        #expect(try stored().icon == nil)
    }

    @Test("⌘Z возвращает прежнюю иконку, ⇧⌘Z — новую")
    func undoRedo() throws {
        let undoManager = UndoManager()
        undoManager.groupsByEvent = false
        tree.undoManager = undoManager
        undoManager.beginUndoGrouping()
        try tree.setIcon(page.id, to: "📘")
        undoManager.endUndoGrouping()

        undoManager.beginUndoGrouping()
        try tree.setIcon(page.id, to: "🌿")
        undoManager.endUndoGrouping()
        #expect(undoManager.undoActionName == "Иконка страницы")

        undoManager.undo()
        #expect(try stored().icon == "📘")
        undoManager.redo()
        #expect(try stored().icon == "🌿")
    }

    @Test("Открытый документ подхватывает иконку; его автосохранение названия её не затирает")
    func documentAdoptsIcon() throws {
        let document = PageDocument(content: try #require(try store.pageContent(page.id)))
        try tree.setIcon(page.id, to: "📘")

        document.adoptIcon(of: try stored())
        #expect(document.page.icon == "📘")
        #expect(document.page.pathTitle == "📘 Проекты")
        #expect(!document.hasUnsavedChanges)

        document.setTitle("Дела")
        let changes = document.unsavedChanges()
        let result = try store.write { try PageDocumentWriter.write(changes, pageId: page.id, in: $0) }
        document.didSave(changes, result: result)
        #expect(try stored().icon == "📘")
        #expect(try stored().title == "Дела")
        #expect(document.page.icon == "📘")
    }
}
