import AppKit
import NotesCore
import XCTest

/// Замер «Дублировать» (US4, SC-204): ветка 50 подстраниц, 5 000 блоков, 10 картинок — настоящей операцией
/// `PageTreeOperations.duplicate` (копия с очереди записи) ≤ 2 с; главный поток не замирает дольше 100 мс;
/// копия читается с тем же текстом. Для сведения — ⌘Z (стирание копии) на главном потоке.
@MainActor
final class DuplicatePageBenchmarkTests: XCTestCase {
    func testDuplicatingLargeBranchFitsBudget() async throws {
        _ = NSApplication.shared
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("MyNotion-dup-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = try NotesStore(database: AppDatabase.open(at: folder.appendingPathComponent("MyNotion.sqlite")),
                                   clock: HybridLogicalClock(deviceId: UUID()))
        let rootId = try BranchCopyProbeTests.makeBranch(in: store)
        let original = try BranchCopyProbeTests.texts(ofBranch: rootId, in: store)
        let tree = PageTreeOperations(store: store)
        let undoManager = UndoManager()
        undoManager.groupsByEvent = false
        tree.undoManager = undoManager

        let watch = MainThreadWatch()
        watch.start()
        let started = ContinuousClock.now
        undoManager.beginUndoGrouping()
        let copy = try await tree.duplicate(rootId)
        undoManager.endUndoGrouping()
        let seconds = BranchCopyProbeTests.seconds(ContinuousClock.now - started)
        watch.stop()
        let copied = try BranchCopyProbeTests.texts(ofBranch: copy.id, in: store)

        let undoStarted = ContinuousClock.now
        undoManager.undo()
        let undoSeconds = BranchCopyProbeTests.seconds(ContinuousClock.now - undoStarted)
        let afterUndo = try store.pageOutline().count

        // ⇧⌘Z: копия заново, тоже с очереди записи.
        let redoWatch = MainThreadWatch()
        redoWatch.start()
        let redoStarted = ContinuousClock.now
        undoManager.redo()
        let redoCopy = try await XCTUnwrap(tree.pendingDuplicate).value
        let redoSeconds = BranchCopyProbeTests.seconds(ContinuousClock.now - redoStarted)
        redoWatch.stop()
        let redone = try BranchCopyProbeTests.texts(ofBranch: redoCopy.id, in: store)

        let summary = """
            Дублирование: 51 страница, \(original.blockCount) блоков, 10 картинок — \(String(format: "%.2f", seconds)) с (предел 2), \
            главный поток замирал не дольше \(ProbeEditor.format(watch.maxGapMs)) мс (предел 100)
            Дублирование: копия «\(copy.title)» — \(copied.pageCount) страниц, текст совпал: \(copied.texts == original.texts ? "да" : "нет")
            Дублирование: ⌘Z стёр копию за \(String(format: "%.2f", undoSeconds)) с, страниц в базе \(afterUndo)
            Дублирование: ⇧⌘Z — \(String(format: "%.2f", redoSeconds)) с, главный поток замирал не дольше \(ProbeEditor.format(redoWatch.maxGapMs)) мс, \
            текст совпал: \(redone.texts == original.texts ? "да" : "нет")
            """
        print(summary)
        add(XCTAttachment(string: summary))
        XCTAssertLessThanOrEqual(seconds, 2, "Дублирование дольше 2 с")
        XCTAssertLessThanOrEqual(watch.maxGapMs, 100, "Главный поток замирал дольше 100 мс")
        XCTAssertEqual(copied.texts, original.texts)
        XCTAssertEqual(afterUndo, original.pageCount, "⌘Z не стёр копию")
        XCTAssertLessThanOrEqual(redoSeconds, 2, "Повтор дублирования дольше 2 с")
        XCTAssertLessThanOrEqual(redoWatch.maxGapMs, 100, "Повтор дублирования замораживал главный поток дольше 100 мс")
        XCTAssertEqual(redone.texts, original.texts)
    }
}
