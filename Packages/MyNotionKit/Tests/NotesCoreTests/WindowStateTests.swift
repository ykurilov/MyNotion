import Foundation
import Testing
@testable import NotesCore

/// Состояние окна (FR-006): какая страница была открыта — переживает перезапуск.
@Suite("Состояние окна")
struct WindowStateTests {
    @Test("Открытая страница и вид окна переживают закрытие базы")
    func windowStateSurvivesReopen() throws {
        let folder = try TemporaryFolder()
        let pageId = UUID.timeOrdered()
        let collapsed: Set<UUID> = [.timeOrdered(), .timeOrdered()]

        do {
            let database = try AppDatabase.open(at: folder.databaseURL)
            let store = NotesStore(database: database, clock: HybridLogicalClock(deviceId: UUID()))
            #expect(try store.windowState(WindowState.mainWindowId) == nil)
            try store.saveWindowState(WindowState(windowId: WindowState.mainWindowId, openPageId: UUID()))
            try store.saveWindowState(WindowState(windowId: WindowState.mainWindowId, openPageId: pageId,
                                                  collapsedPageIds: collapsed, sidebarWidth: 310))
            database.close()
        }

        let database = try AppDatabase.open(at: folder.databaseURL)
        defer { database.close() }
        let store = NotesStore(database: database, clock: HybridLogicalClock(deviceId: UUID()))
        let restored = try #require(try store.windowState(WindowState.mainWindowId))
        #expect(restored.openPageId == pageId)
        #expect(restored.collapsedPageIds == collapsed)
        #expect(restored.sidebarWidth == 310)
    }
}
