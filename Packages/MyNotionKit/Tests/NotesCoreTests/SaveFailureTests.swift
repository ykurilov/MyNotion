import Foundation
import GRDB
import Synchronization
import Testing
@testable import NotesCore

/// Неудачная запись (FR-015): приложение говорит «не сохранено» с причиной,
/// текст в памяти не теряется, повторная попытка его записывает.
@MainActor
@Suite("Ошибка записи")
struct SaveFailureTests {
    let folder: TemporaryFolder
    let store: NotesStore
    let disk = FlakyDisk()
    let scheduler = ManualAutosaveScheduler()
    let documents: OpenDocuments
    let pageId: UUID

    init() throws {
        folder = try TemporaryFolder()
        store = try NotesStore(database: AppDatabase.open(at: folder.databaseURL), clock: HybridLogicalClock(deviceId: UUID()))
        pageId = try store.write { try $0.createPage(title: "Черновик").id }
        // Отказ подписчика отменяет транзакцию так же, как отказ диска.
        store.addWriteHook(disk)
        documents = OpenDocuments(store: store, scheduler: scheduler)
    }

    private func storedText() throws -> String {
        try #require(try store.pageContent(pageId)?.blocks.first).text.string
    }

    @Test("Отказ диска — состояние «не сохранено» с причиной, текст в окне цел")
    func failureIsReportedAndTextKept() throws {
        let document = try documents.open(pageId)
        disk.isBroken = true

        document.setText(InlineText("важная мысль"), ofBlock: document.blocks[0].id)
        scheduler.advance(by: .milliseconds(300))

        #expect(document.saveStatus == .failed(reason: "диск недоступен"))
        #expect(document.blocks[0].text.string == "важная мысль")
        #expect(document.hasUnsavedChanges)
        #expect(try storedText() == "")
    }

    @Test("Пока запись не удаётся, состояние не становится «сохранено» ни от правок, ни от повторов")
    func failureIsNeverReportedAsSaved() throws {
        let document = try documents.open(pageId)
        disk.isBroken = true

        document.setText(InlineText("раз"), ofBlock: document.blocks[0].id)
        scheduler.advance(by: .milliseconds(300))
        document.setText(InlineText("раз два"), ofBlock: document.blocks[0].id)
        #expect(document.saveStatus.isFailed)
        scheduler.advance(by: .seconds(3))
        #expect(document.saveStatus.isFailed)
        #expect(!documents.saveAll(), "Выход знает, что записать не удалось")
    }

    @Test("Повторная попытка записывает текст, когда диск снова доступен")
    func retryWritesTextAfterRecovery() throws {
        let document = try documents.open(pageId)
        disk.isBroken = true
        document.setText(InlineText("не потеряется"), ofBlock: document.blocks[0].id)
        scheduler.advance(by: .milliseconds(300))
        #expect(document.saveStatus.isFailed)

        disk.isBroken = false
        scheduler.advance(by: AutosaveCoordinator.retryDelay)

        #expect(try storedText() == "не потеряется")
        #expect(document.saveStatus == .saved)
        #expect(!document.hasUnsavedChanges)
    }

    @Test("Правку стёрли после неудачной записи — «не сохранено» снимается, выход не спрашивает")
    func revertedEditClearsFailure() throws {
        let document = try documents.open(pageId)
        disk.isBroken = true
        document.setText(InlineText("!"), ofBlock: document.blocks[0].id)
        scheduler.advance(by: .milliseconds(300))
        #expect(document.saveStatus.isFailed)

        // Диск всё ещё недоступен, но на нём уже то же, что в окне.
        document.setText(InlineText(""), ofBlock: document.blocks[0].id)

        #expect(!document.hasUnsavedChanges)
        #expect(document.saveStatus == .saved)
        #expect(documents.saveAll(), "Выход не спрашивает про несохранённое")
        scheduler.advance(by: .seconds(3))
        #expect(document.saveStatus == .saved, "Повтор не возвращает ошибку")
        #expect(try storedText() == "")
    }

    @Test("Вернули прежнее название после неудачной записи — «не сохранено» снимается")
    func revertedTitleClearsFailure() throws {
        let document = try documents.open(pageId)
        disk.isBroken = true
        document.setTitle("Черновик 2")
        scheduler.advance(by: .milliseconds(300))
        #expect(document.saveStatus.isFailed)

        document.setTitle("Черновик")

        #expect(document.saveStatus == .saved)
        #expect(documents.saveAll())
    }

    @Test("Стёрли одну из несохранённых правок — «не сохранено» остаётся, другая запишется после починки")
    func partlyRevertedEditsStayFailed() throws {
        let content = try #require(try store.pageContent(pageId))
        let second = Block(pageId: pageId, sortKey: .between(content.blocks[0].sortKey, nil))
        _ = try store.write { try $0.insertBlock(second) }
        let secondId = second.id
        let document = try documents.open(pageId)
        disk.isBroken = true
        document.setText(InlineText("стереть"), ofBlock: document.blocks[0].id)
        document.setText(InlineText("оставить"), ofBlock: secondId)
        scheduler.advance(by: .milliseconds(300))

        document.setText(InlineText(""), ofBlock: document.blocks[0].id)
        #expect(document.saveStatus.isFailed)
        #expect(!documents.saveAll())

        disk.isBroken = false
        scheduler.advance(by: AutosaveCoordinator.retryDelay)
        #expect(document.saveStatus == .saved)
        #expect(try store.pageContent(pageId)?.blocks.map(\.text.string) == ["", "оставить"])
    }

    @Test("Причина отказа SQLite понятна человеку")
    func sqliteFailureReasons() {
        #expect(SaveStatus.reason(for: DatabaseError(resultCode: .SQLITE_FULL)) == "на диске нет места")
        #expect(SaveStatus.reason(for: DatabaseError(resultCode: .SQLITE_READONLY)) == "нет доступа к файлу записей")
        #expect(SaveStatus.reason(for: DatabaseError(resultCode: .SQLITE_IOERR)) == "ошибка чтения или записи диска")
        #expect(SaveStatus.reason(for: DiskUnavailable()) == "диск недоступен")
    }
}

/// Подписчик, который по команде теста отказывает в каждой записи.
final class FlakyDisk: NotesWriteHook {
    private let broken = Mutex(false)

    var isBroken: Bool {
        get { broken.withLock { $0 } }
        set { broken.withLock { $0 = newValue } }
    }

    func notesWillCommit(_ changes: NotesChanges, in transaction: NotesTransaction) throws {
        if isBroken { throw DiskUnavailable() }
    }
}

struct DiskUnavailable: LocalizedError {
    var errorDescription: String? { "диск недоступен" }
}

extension SaveStatus {
    var isFailed: Bool {
        if case .failed = self { true } else { false }
    }
}
