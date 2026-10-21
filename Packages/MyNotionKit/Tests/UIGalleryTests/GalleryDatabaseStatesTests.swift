import Testing
@testable import UIGallery

/// Состояния галереи баз (T029): пустая база и таблица эталона — в обеих темах; истории 004 добавляют свои в конец.
@Suite("Галерея баз")
struct GalleryDatabaseStatesTests {
    @Test("«Пустая база» и «Таблица эталона» — в разделе «Базы», в обеих темах")
    func databaseStates() {
        let states = GalleryCatalog.states.filter { $0.section == "Базы" }
        #expect(states.map(\.id) == ["database-empty", "database-sample-table"])
        #expect(states.map(\.scene) == [.databases(.empty), .databases(.sampleTable)])
        #expect(GalleryCatalog.shots.filter { $0.state.section == "Базы" }.count == 4)
    }
}
