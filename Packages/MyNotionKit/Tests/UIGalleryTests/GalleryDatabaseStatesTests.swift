import Testing
@testable import UIGallery

/// Состояния галереи баз (T029): пустая база и таблица эталона — в обеих темах; истории 004 добавляют свои в конец.
@Suite("Галерея баз")
struct GalleryDatabaseStatesTests {
    @Test("«Пустая база» и «Таблица эталона» — в разделе «Базы», в обеих темах")
    func databaseStates() {
        let states = GalleryCatalog.states.filter { $0.section == "Базы" }
        #expect(states.prefix(2).map(\.id) == ["database-empty", "database-sample-table"])
        #expect(states.prefix(2).map(\.scene) == [.databases(.empty), .databases(.sampleTable)])
        #expect(GalleryCatalog.shots.filter { $0.state.section == "Базы" }.count == states.count * 2)
    }

    @Test("US5: редактор формулы пустой, с итогом, с ошибкой, с кругом и ячейки формул — в обеих темах")
    func formulaStates() {
        let ids = ["formula-editor-empty", "formula-editor-result", "formula-editor-error", "formula-editor-cycle", "formula-cells"]
        let states = GalleryCatalog.states.filter { ids.contains($0.id) }
        #expect(states.map(\.scene) == [.databases(.formulaEditorEmpty), .databases(.formulaEditorResult), .databases(.formulaEditorError),
                                        .databases(.formulaEditorCycle), .databases(.formulaCells)])
        #expect(GalleryCatalog.shots.filter { ids.contains($0.state.id) }.count == 10)
    }

    @Test("US2: окна выбора, статуса, даты, файлов, настройки и плашки — в обеих темах")
    func typeStates() {
        let states = GalleryCatalog.states.filter { $0.id.hasPrefix("type-") }
        #expect(states.count == 11)
        #expect(states.allSatisfy { $0.section == "Базы" })
        #expect(GalleryCatalog.shots.filter { $0.state.id.hasPrefix("type-") }.count == 22)
    }
}
