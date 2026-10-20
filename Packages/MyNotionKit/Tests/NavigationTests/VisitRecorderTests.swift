import Foundation
import Testing
@testable import Navigation
import NotesCore

/// Запись открытий (research R4, contracts/page-operations.md, «Недавние»): с подменёнными часами.
@MainActor
@Suite("Запись открытий страниц")
struct VisitRecorderTests {
    /// Ручные часы: время идёт только от `advance`; отложенные действия срабатывают в свой срок.
    @MainActor
    final class ManualClock {
        private(set) var now = Date(timeIntervalSince1970: 1_790_000_000)
        private var pending: [(id: Int, fireAt: Date, action: @MainActor () -> Void)] = []
        private var nextId = 0

        func schedule(after seconds: TimeInterval, _ action: @escaping @MainActor () -> Void) -> @MainActor () -> Void {
            nextId += 1
            let id = nextId
            pending.append((id, now.addingTimeInterval(seconds), action))
            return { [weak self] in self?.pending.removeAll { $0.id == id } }
        }

        func advance(_ seconds: TimeInterval) {
            let target = now.addingTimeInterval(seconds)
            while let next = pending.filter({ $0.fireAt <= target }).min(by: { $0.fireAt < $1.fireAt }) {
                pending.removeAll { $0.id == next.id }
                now = max(now, next.fireAt)
                next.action()
            }
            now = target
        }
    }

    let folder: TemporaryFolder
    let store: NotesStore
    let clock = ManualClock()
    let recorder: VisitRecorder
    let pageA: Page, pageB: Page

    init() throws {
        folder = try TemporaryFolder()
        let store = try NotesStore(database: AppDatabase.open(at: folder.databaseURL), clock: HybridLogicalClock(deviceId: UUID()))
        self.store = store
        pageA = try store.write { try $0.createPage(title: "A") }
        pageB = try store.write { try $0.createPage(title: "B") }
        let clock = self.clock
        recorder = VisitRecorder(store: store, now: { clock.now }, schedule: { clock.schedule(after: $0, $1) })
    }

    private func visitedAt(_ page: Page) throws -> Date? {
        try store.pageOutline().first { $0.id == page.id }?.visitedAt
    }

    @Test("2 секунды на странице — запись с моментом открытия")
    func twoSecondsRecords() throws {
        recorder.pageOpened(pageA.id)
        let openedAt = clock.now
        clock.advance(1.9)
        #expect(try visitedAt(pageA) == nil)
        clock.advance(0.1)
        #expect(try visitedAt(pageA) == openedAt.addingTimeInterval(2))
    }

    @Test("Уход за 1,9 с — записи нет, даже если потом пройдёт время")
    func leavingEarlyRecordsNothing() throws {
        recorder.pageOpened(pageA.id)
        clock.advance(1.9)
        recorder.pageOpened(pageB.id)
        clock.advance(1.9)
        #expect(try visitedAt(pageA) == nil)
        #expect(try visitedAt(pageB) == nil)
    }

    @Test("Правка раньше 2 с — запись сразу, второго отложенного действия нет")
    func editRecordsAtOnce() throws {
        recorder.pageOpened(pageA.id)
        clock.advance(0.5)
        recorder.pageEdited(pageA.id)
        let editedAt = clock.now
        #expect(try visitedAt(pageA) == editedAt)
        clock.advance(5)
        #expect(try visitedAt(pageA) == editedAt, "таймер отменён: повторной записи нет")
    }

    @Test("Правка не открытой сейчас страницы запись не делает")
    func editOfOtherPageIgnored() throws {
        recorder.pageOpened(pageA.id)
        recorder.pageEdited(pageB.id)
        #expect(try visitedAt(pageB) == nil)
    }

    @Test("Много правок за пребывание — одна запись")
    func manyEditsOneWrite() throws {
        var recorded: [UUID] = []
        let clock = self.clock
        let recorder = VisitRecorder(store: store, now: { clock.now }, schedule: { clock.schedule(after: $0, $1) },
                                     onRecorded: { recorded.append($0) })
        recorder.pageOpened(pageA.id)
        for _ in 0..<20 { recorder.pageEdited(pageA.id); clock.advance(0.1) }
        clock.advance(3)
        #expect(recorded == [pageA.id])
    }

    @Test("Повторное открытие той же страницы — одна запись, время обновляется, а страница одна в «Недавних»")
    func reopeningKeepsOneEntry() throws {
        recorder.pageOpened(pageA.id)
        clock.advance(2)
        let first = try #require(try visitedAt(pageA))
        recorder.pageOpened(pageA.id)   // та же страница, уже открыта — не новое открытие
        clock.advance(10)
        #expect(try visitedAt(pageA) == first)
        recorder.pageOpened(pageB.id)
        clock.advance(3)
        recorder.pageOpened(pageA.id)
        clock.advance(2)
        let second = try #require(try visitedAt(pageA))
        #expect(second > first)
        #expect(try store.recentPages(limit: 5).map(\.id) == [pageA.id, pageB.id])
    }

    @Test("«Изменено» страницы не меняется от записи открытия")
    func updatedAtUntouched() throws {
        let before = try #require(try store.pageOutline().first { $0.id == pageA.id }).updatedAt
        recorder.pageOpened(pageA.id)
        clock.advance(2)
        #expect(try visitedAt(pageA) != nil)
        #expect(try store.pageOutline().first { $0.id == pageA.id }?.updatedAt == before)
    }

    @Test("Закрыли страницу (nil) раньше 2 с — отложенная запись отменена; страница исчезла — записи нет")
    func closingCancels() throws {
        recorder.pageOpened(pageA.id)
        recorder.pageOpened(Optional<UUID>.none)
        clock.advance(5)
        #expect(try visitedAt(pageA) == nil)
        let ghost = UUID.timeOrdered()
        recorder.pageOpened(ghost)
        clock.advance(5)   // страницы нет в базе — не падаем
    }
}
