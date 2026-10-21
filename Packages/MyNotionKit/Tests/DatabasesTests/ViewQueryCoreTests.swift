import Foundation
import GRDB
import Testing
@testable import Databases
@testable import NotesCore

/// Ядро запроса вида (T015, research R3): дерево фильтра И/ИЛИ с вложенной группой, несколько сортировок, ручной порядок
/// вида, корзина и шаблоны, группы, окно видимых строк, отмена прежнего запроса. Итог — как фильтр и сортировка «в лоб»
/// на 1 000 случайных строк.
@Suite("Запрос вида", .serialized)
struct ViewQueryCoreTests {
    struct Fixture {
        let store: NotesStore
        let database: UUID
        let view: UUID
        let text, number, select, multi, check, date: DatabaseProperty
        let options: [SelectOption]
        let tags: [SelectOption]
        let rows: [UUID]
        let trashed: Set<UUID>
        let templates: Set<UUID>
    }

    static let fixture: Fixture = try! makeFixture()

    static func makeFixture() throws -> Fixture {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("viewquery-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let store = NotesStore(database: try AppDatabase.open(at: folder.appendingPathComponent("MyNotion.sqlite")), clock: HybridLogicalClock(deviceId: UUID()))
        store.addWriteHook(CellIndexer())
        var random = SplitMix(seed: 42)
        let words = ["альфа", "бета", "гамма", "Ёж", "delta", "Эхо", "яблоко", "zeta", "ива", "йод"]
        return try store.write { tx throws in
            let page = try tx.createPage(title: "Случайная")
            try tx.saveDatabase(DatabaseSchema(pageId: page.id))
            var key: FractionalSortKey?
            func add(_ name: String, _ kind: PropertyKind) throws -> DatabaseProperty {
                key = .between(key, nil)
                return try tx.saveProperty(DatabaseProperty(databaseId: page.id, name: name, kind: kind, sortKey: key!))
            }
            _ = try add("Название", .title)
            let text = try add("Текст", .text), number = try add("Число", .number), select = try add("Выбор", .select)
            let multi = try add("Теги", .multiSelect), check = try add("Флажок", .checkbox), date = try add("Дата", .date)
            var optionKey: FractionalSortKey?
            let options = try (0..<5).map { index -> SelectOption in
                optionKey = .between(optionKey, nil)
                return try tx.saveOption(SelectOption(propertyId: select.id, name: "Вариант \(index)", sortKey: optionKey!))
            }
            optionKey = nil
            let tags = try (0..<5).map { index -> SelectOption in
                optionKey = .between(optionKey, nil)
                return try tx.saveOption(SelectOption(propertyId: multi.id, name: "Тег \(index)", sortKey: optionKey!))
            }
            let view = try tx.saveView(DatabaseView(databaseId: page.id, sortKey: .between(nil, nil)))
            var rows: [UUID] = [], trashed: Set<UUID> = [], templates: Set<UUID> = []
            for index in 0..<1_000 {
                var row = try tx.createPage(title: index % 13 == 0 ? "" : words[random.int(words.count)] + " \(random.int(100))", parentId: page.id)
                if random.int(10) < 8 { try tx.setCell(rowId: row.id, propertyId: text.id, value: ["runs": [], "string": .string(words[random.int(words.count)])]) }
                if random.int(10) < 8 { try tx.setCell(rowId: row.id, propertyId: number.id, value: .number(Double(random.int(100)))) }
                if random.int(10) < 8 { try tx.setCell(rowId: row.id, propertyId: select.id, value: .string(options[random.int(5)].id.databaseText)) }
                if random.int(10) < 7 {
                    let chosen = Set((0..<1 + random.int(3)).map { _ in random.int(5) }).sorted()
                    try tx.setCell(rowId: row.id, propertyId: multi.id, value: .array(chosen.map { .string(tags[$0].id.databaseText) }))
                }
                if random.int(2) == 0 { try tx.setCell(rowId: row.id, propertyId: check.id, value: .bool(random.int(2) == 0)) }
                if random.int(10) < 7 {
                    try tx.setCell(rowId: row.id, propertyId: date.id, value: ["start": .string(String(format: "2026-%02d-%02d", 1 + random.int(12), 1 + random.int(28))),
                                                                              "hasTime": false, "timeZone": "Europe/Moscow"])
                }
                if index % 50 == 7 { row.trashedAt = Date(); row = try tx.updatePage(row); trashed.insert(row.id) }
                else if index % 97 == 3 { row.isTemplate = true; row = try tx.updatePage(row); templates.insert(row.id) }
                rows.append(row.id)
            }
            return Fixture(store: store, database: page.id, view: view.id, text: text, number: number, select: select, multi: multi, check: check,
                           date: date, options: options, tags: tags, rows: rows, trashed: trashed, templates: templates)
        }
    }

    // MARK: Подсчёт «в лоб»

    struct Values {
        var title = "", text: String?, number: Double?, select: UUID?, tags: [UUID] = [], check = false, date: Date?
        var sortKey = "", id = ""
    }

    func values(_ fixture: Fixture, order: [UUID: String] = [:]) throws -> [UUID: Values] {
        try fixture.store.write { tx in
            var result: [UUID: Values] = [:]
            for row in fixture.rows where !fixture.trashed.contains(row) && !fixture.templates.contains(row) {
                let page = try tx.page(row)!
                var v = Values(title: page.title, sortKey: order[row] ?? page.sortKey.rawValue, id: row.databaseText)
                for cell in try tx.cells(ofRow: row) {
                    switch cell.propertyId {
                    case fixture.text.id: v.text = cell.value?["string"]?.string
                    case fixture.number.id: v.number = cell.value?.number
                    case fixture.select.id: v.select = cell.value?.string.flatMap(UUID.init(uuidString:))
                    case fixture.multi.id: v.tags = cell.value?.array?.compactMap { $0.string.flatMap(UUID.init(uuidString:)) } ?? []
                    case fixture.check.id: v.check = cell.value?.bool ?? false
                    case fixture.date.id: v.date = cell.value.flatMap(DateValues.start)
                    default: break
                    }
                }
                result[row] = v
            }
            return result
        }
    }

    func position(_ id: UUID?, in options: [SelectOption]) -> Double? { id.flatMap { id in options.firstIndex { $0.id == id }.map(Double.init) } }

    static func binaryLess(_ a: String, _ b: String) -> Bool { Array(a.utf8).lexicographicallyPrecedes(b.utf8) }

    /// Ключ сортировки: пустые — в конце при любом направлении.
    func ordered(_ ids: [UUID], _ all: [UUID: Values], keys: [(Values) -> (Double?, String?)], ascending: [Bool]) -> [UUID] {
        ids.sorted { left, right in
            let a = all[left]!, b = all[right]!
            for (index, key) in keys.enumerated() {
                let (an, at) = key(a), (bn, bt) = key(b)
                let aEmpty = an == nil && at == nil, bEmpty = bn == nil && bt == nil
                if aEmpty != bEmpty { return !aEmpty }
                if aEmpty { continue }
                if let an, let bn, an != bn { return ascending[index] ? an < bn : an > bn }
                if let at, let bt, at != bt { return ascending[index] ? Self.binaryLess(at, bt) : Self.binaryLess(bt, at) }
            }
            if a.sortKey != b.sortKey { return Self.binaryLess(a.sortKey, b.sortKey) }
            return Self.binaryLess(a.id, b.id)
        }
    }

    func query(_ fixture: Fixture, filter: FilterNode?, sorts: [SortSpec] = [], group: UUID? = nil) throws -> ViewQueryResult {
        let catalog = try DatabaseCatalog.read(fixture.database, in: fixture.store)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Moscow")!
        return try fixture.store.database.dbWriter.read { db in
            var sql = ViewQuerySQL(spec: ViewQuerySpec(databaseId: fixture.database, viewId: fixture.view, filter: filter, sorts: sorts,
                                                       groupPropertyId: group), catalog: catalog, calendar: calendar)
            return try sql.fetch(in: db)
        }
    }

    func id(_ option: SelectOption) -> JSONValue { .string(option.id.databaseText) }

    @Test("И/ИЛИ с вложенной группой и две сортировки — как «в лоб»; корзины и шаблонов нет")
    func filterAndSortsMatchBruteForce() throws {
        let f = Self.fixture
        let all = try values(f)
        let cutoff = DateText.parse("2026-07-01", timeZone: "Europe/Moscow")!
        let filters: [(FilterNode, (Values) -> Bool)] = [
            (.and([.condition(FilterCondition(propertyId: f.text.id, op: .contains, value: "а")),
                   .or([.condition(FilterCondition(propertyId: f.number.id, op: .greaterThan, value: 50)),
                        .condition(FilterCondition(propertyId: f.select.id, op: .is, value: [id(f.options[0]), id(f.options[1])]))])]),
             { v in (v.text.map { SortableText.make($0).contains("а") } ?? false)
                 && ((v.number ?? -1) > 50 || [f.options[0].id, f.options[1].id].contains(v.select ?? UUID())) }),
            (.or([.condition(FilterCondition(propertyId: f.check.id, op: .is, value: true)),
                  .and([.condition(FilterCondition(propertyId: f.multi.id, op: .contains, value: [id(f.tags[1])])),
                        .condition(FilterCondition(propertyId: f.date.id, op: .isBefore, value: ["exact": "2026-07-01"]))]),
                  .condition(FilterCondition(propertyId: f.number.id, op: .isEmpty))]),
             { v in v.check || (v.tags.contains(f.tags[1].id) && (v.date.map { $0 < cutoff } ?? false)) || v.number == nil }),
            (.and([.condition(FilterCondition(propertyId: f.text.id, op: .isNotEmpty)),
                   .or([.and([.condition(FilterCondition(propertyId: f.select.id, op: .isNot, value: [id(f.options[3])])),
                              .condition(FilterCondition(propertyId: f.number.id, op: .lessThanOrEqual, value: 20))]),
                        .condition(FilterCondition(propertyId: f.multi.id, op: .doesNotContain, value: [id(f.tags[2])]))])]),
             { v in !(v.text ?? "").isEmpty && ((v.select != f.options[3].id && (v.number.map { $0 <= 20 } ?? false)) || !v.tags.contains(f.tags[2].id)) }),
        ]
        let sorts: [([SortSpec], [(Values) -> (Double?, String?)], [Bool])] = [
            ([SortSpec(propertyId: f.select.id), SortSpec(propertyId: f.number.id, ascending: false)],
             [{ (position($0.select, in: f.options), nil) }, { ($0.number, nil) }], [true, false]),
            ([SortSpec(propertyId: f.text.id, ascending: false), SortSpec(propertyId: f.date.id)],
             [{ (nil, $0.text.map(SortableText.make)) }, { ($0.date?.timeIntervalSince1970, nil) }], [false, true]),
            ([SortSpec(propertyId: f.multi.id), SortSpec(propertyId: f.check.id, ascending: false)],
             [{ (position($0.tags.first, in: f.tags), nil) }, { ($0.check ? 1 : 0, nil) }], [true, false]),
        ]
        for (filter, matches) in filters {
            for (spec, keys, ascending) in sorts {
                let expected = ordered(all.keys.filter { matches(all[$0]!) }, all, keys: keys, ascending: ascending)
                let result = try query(f, filter: filter, sorts: spec)
                #expect(result.rowIds == expected, "фильтр и сортировки дали не тот порядок")
                #expect(result.rowIds.allSatisfy { !f.trashed.contains($0) && !f.templates.contains($0) })
            }
        }
        #expect(try query(f, filter: nil).rowIds.count == all.count)
    }

    @Test("Без сортировок — ручной порядок вида (`db_row_order`), иначе порядок создания; у другого вида — свой")
    func manualOrder() throws {
        let f = Self.fixture
        let before = try query(f, filter: nil).rowIds
        let moved = before[500]
        let firstKey = try f.store.write { try $0.page(before[0])!.sortKey }
        try f.store.write { tx in try tx.setRowOrder(viewId: f.view, rowId: moved, sortKey: .between(nil, firstKey)) }
        let after = try query(f, filter: nil).rowIds
        #expect(after.first == moved && after.count == before.count)
        let other = try DatabaseCatalog.read(f.database, in: f.store)
        let otherOrder = try f.store.database.dbWriter.read { db in
            var sql = ViewQuerySQL(spec: ViewQuerySpec(databaseId: f.database, viewId: UUID()), catalog: other)
            return try sql.fetch(in: db).rowIds
        }
        #expect(otherOrder == before, "место в одном виде не трогает другой")
        try f.store.write { tx in try tx.execute(sql: "DELETE FROM db_row_order") }
    }

    @Test("Группы: ключ группы первым, «Нет …» в конце; границы групп")
    func groups() throws {
        let f = Self.fixture
        let result = try query(f, filter: nil, sorts: [SortSpec(propertyId: f.number.id)], group: f.select.id)
        let groups = result.groups
        #expect(groups.map(\.key) == [0, 1, 2, 3, 4, nil])
        #expect(groups.map(\.rows.count).reduce(0, +) == result.rowIds.count)
        #expect(groups.first?.rows.lowerBound == 0 && groups.last?.rows.upperBound == result.rowIds.count)
    }

    @Test("Окно видимых строк: ячейки — только для запрошенных строк")
    func window() throws {
        let f = Self.fixture
        let ids = Array(try query(f, filter: nil).rowIds[10..<20])
        let catalog = try DatabaseCatalog.read(f.database, in: f.store)
        let window = try RowWindowReader.read(ids, catalog: catalog, store: f.store)
        #expect(Set(window.keys) == Set(ids))
    }

    @Test("Новый запрос отменяет прежний: итог старого не отдаётся")
    func latestWins() async throws {
        let f = Self.fixture
        let catalog = try DatabaseCatalog.read(f.database, in: f.store)
        let runner = LatestViewQuery(store: f.store)
        let first = runner.begin()
        let second = runner.begin()
        let spec = ViewQuerySpec(databaseId: f.database, viewId: f.view)
        #expect(try await runner.run(spec, catalog: catalog, ticket: first) == nil)
        #expect(try await runner.run(spec, catalog: catalog, ticket: second)?.rowIds.count == (try query(f, filter: nil).rowIds.count))
    }
}

/// Постоянное зерно для случайных строк.
struct SplitMix {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        return value ^ (value >> 31)
    }
    mutating func int(_ bound: Int) -> Int { Int(next() % UInt64(bound)) }
}
