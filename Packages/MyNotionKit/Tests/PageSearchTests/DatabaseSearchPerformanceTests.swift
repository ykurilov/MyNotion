import Foundation
import GRDB
import Testing
@testable import Databases
@testable import NotesCore
@testable import PageSearch

/// Замер T105: поиск на эталоне баз («Задачи» 10 000 строк × 30 свойств, «Проекты» 500, встроенная база на 10 000 строк).
/// Частое слово есть в тысячах названий строк и значений — выдача (20 строк с путём до базы) должна укладываться в бюджет
/// ввода в поле поиска: p95 ≤ 50 мс. Индекс эталона заполняется здесь: генератор пишет таблицы без подписчиков.
/// Долгий: включается `MYNOTION_PERF=1`.
@MainActor
@Suite("Поиск: замер на эталоне баз", .enabled(if: ProcessInfo.processInfo.environment["MYNOTION_PERF"] != nil))
struct DatabaseSearchPerformanceTests {
    @Test("Частое и редкое слово по строкам баз — p95 ≤ 50 мс")
    func searchRows() throws {
        let folder = try TemporaryFolder()
        let store = NotesStore(database: try AppDatabase.open(at: folder.databaseURL), clock: HybridLogicalClock(deviceId: UUID()))
        _ = try DatabaseSampleGenerator().ensure(in: store)
        try store.database.dbWriter.write { db in
            try db.execute(sql: "INSERT INTO search_index (rowid, pageId, blockId, content) SELECT -rowid, id, NULL, title FROM page WHERE title != ''")
            try db.execute(sql: """
                INSERT INTO search_index (rowid, pageId, blockId, content)
                SELECT \(NotesTransaction.cellSearchRowidOffset) + ROW_NUMBER() OVER (), rowId, NULL, searchText FROM db_cell
                WHERE searchText IS NOT NULL AND searchText != ''
                """)
        }
        let search = PageSearch(store: store)
        let tree = try store.pageTree()

        for query in ["договор", "описание 9999", "проект бюджет"] {
            var times: [Double] = []
            var found = 0
            for _ in 0..<40 {
                let start = DispatchTime.now().uptimeNanoseconds
                found = try search.results(for: query, in: tree).count
                times.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6)
            }
            let sorted = times.sorted()
            let p95 = sorted[Int(Double(sorted.count - 1) * 0.95)]
            print("T105 замер поиска «\(query)»: найдено \(found), p50 \(String(format: "%.1f", sorted[sorted.count / 2])) мс, p95 \(String(format: "%.1f", p95)) мс")
            #expect(found > 0)
            #expect(p95 <= 50, "поиск «\(query)» медленнее бюджета")
        }
    }
}
