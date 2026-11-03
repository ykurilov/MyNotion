import Foundation
import GRDB
import NotesCore
import NotionSchemaFetch
import Testing
@testable import Databases
@testable import NotionImport

/// Живая проверка T108: схема настоящей базы Notion («Задачи» на странице «MyNotion — базы 004») читается по ключу,
/// ложится поверх выгрузки с теми же столбцами, формулы пересчитываются. Включается только когда задан файл с ключом
/// `MYNOTION_LIVE_NOTION_KEY_FILE`; в Notion идут только запросы GET, ключ нигде не печатается.
@Suite("Живая проверка: схема базы «Задачи» из Notion", .enabled(if: LiveNotion.keyFile != nil))
struct LiveSchemaImportTests {
    private static let databaseId = "400714fdda698045a03ff04d83b47e70"
    private let workFolder: URL
    private let store: NotesStore

    init() throws {
        workFolder = FileManager.default.temporaryDirectory.appendingPathComponent("LiveSchemaImport-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workFolder, withIntermediateDirectories: true)
        store = NotesStore(database: try AppDatabase.open(at: workFolder.appendingPathComponent("MyNotion.sqlite")),
                           clock: HybridLogicalClock(deviceId: UUID()))
    }

    /// Выгрузка с теми же столбцами, что у живой базы, и тремя строками правдоподобных значений.
    private func export(for schema: NotionDatabaseSchema) throws -> URL {
        let root = workFolder.appendingPathComponent("export", isDirectory: true)
        let ownerId = "a0000000000000000000000000000001"
        let owner = root.appendingPathComponent("Живая проверка \(ownerId)", isDirectory: true)
        let rows = owner.appendingPathComponent("Задачи", isDirectory: true)
        try FileManager.default.createDirectory(at: rows, withIntermediateDirectories: true)

        func field(_ text: String) -> String {
            text.contains(where: { ",\"\n".contains($0) }) ? "\"" + text.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : text
        }
        func value(_ property: NotionProperty, row: Int) -> String {
            switch property.kind {
            case .title: "Живая задача \(row)"
            case .text: "Текст \(row)"
            case .checkbox: row % 2 == 0 ? "Yes" : "No"
            case .url: "https://example.com/\(row)"
            case .email: "a\(row)@example.com"
            case .phone: "+7000000000\(row)"
            case .date: "October 2\(row), 2026"
            case .createdTime, .lastEditedTime: "October 2\(row), 2026 3:15 PM"
            case .number: "\(row * 10)"
            case .select(let options), .multiSelect(let options), .status(let options, _): options.first?.name ?? ""
            case .uniqueId(let prefix): prefix.map { "\($0)-\(row)" } ?? "\(row)"
            case .files, .relation, .rollup, .formula, .unsupported: ""
            }
        }
        // Как в выгрузке Notion: название страницы — первый столбец.
        let columns = schema.properties.filter { if case .title = $0.kind { true } else { false } }
            + schema.properties.filter { if case .title = $0.kind { false } else { true } }
        let header = columns.map { field($0.name) }.joined(separator: ",")
        var csv = "\u{FEFF}" + header + "\n"
        for row in 1...3 {
            csv += columns.map { field(value($0, row: row)) }.joined(separator: ",") + "\n"
            let title = "Живая задача \(row)"
            try "# \(title)\n".write(to: rows.appendingPathComponent("\(title) b\(String(format: "%031x", row)).md"), atomically: true, encoding: .utf8)
        }
        for name in ["Задачи \(Self.databaseId).csv", "Задачи \(Self.databaseId)_all.csv"] {
            try csv.write(to: owner.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        let link = "Живая проверка \(ownerId)/Задачи \(Self.databaseId).csv".addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? ""
        try "# Живая проверка\n\n[Задачи](\(link))\n".write(to: root.appendingPathComponent("Живая проверка \(ownerId).md"), atomically: true, encoding: .utf8)
        return root
    }

    private func liveSchema() async throws -> NotionDatabaseSchema {
        let key = try String(contentsOfFile: #require(LiveNotion.keyFile), encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        let result = await NotionSchemaFetch(key: { key }).fetch(databaseIds: [Self.databaseId])
        #expect(result.failures.isEmpty, "Схема не прочитана: \(result.failures.map { $0.reason.explanation })")
        return try #require(result.schemas[Self.databaseId])
    }

    @Test("Схема живой базы читается: типы, статус с группами, связь с парой, сводка, формулы")
    func liveSchemaIsRead() async throws {
        let schema = try await liveSchema()
        var kinds: [String] = []
        for property in schema.properties {
            let kind: String = switch property.kind {
            case .formula: "формула"
            case .rollup: "сводка"
            case .relation: "связь"
            case .status: "статус"
            case .unsupported(let type): "нет в MyNotion: \(type)"
            default: String(describing: property.kind).prefix(24).description
            }
            kinds.append("\(property.name) — \(kind)")
        }
        print("LIVE схема (\(schema.properties.count) свойств): " + kinds.joined(separator: "; "))
        #expect(schema.properties.count > 10)
        #expect(schema.properties.contains { if case .formula = $0.kind { true } else { false } })
        #expect(schema.properties.contains { if case .status = $0.kind { true } else { false } })
    }

    @Test("Импорт с живой схемой: схема применена, формулы живые и пересчитываются, остальное — по таблице")
    func importWithLiveSchema() async throws {
        let schema = try await liveSchema()
        let prepared = try NotionExportUnpacker().prepare(export(for: schema))
        defer { prepared.discard() }
        #expect(prepared.databaseIds() == [Self.databaseId])
        let report = try NotionImporter(store: store).importExport(prepared, schema: NotionSchemaFetchResult(schemas: [Self.databaseId: schema]))
        let summary = try #require(report.databases.first { $0.title == "Задачи" })
        print("LIVE отчёт: схема применена=\(summary.schemaApplied); свойства: " + summary.properties.joined(separator: "; "))
        for note in summary.notes { print("LIVE заметка: \(note)") }
        #expect(summary.schemaApplied)
        #expect(summary.rowCount == 3)

        let owner = try #require(try store.pageOutline().first { $0.title == "Живая проверка" })
        let database = try #require(try store.pageOutline().first { $0.title == "Задачи" && $0.parentId == owner.id })
        let properties = try store.write { try $0.properties(ofDatabase: database.id) }
        let formulas = properties.filter { $0.kind == .formula }
        print("LIVE формул в MyNotion: \(formulas.count) из \(schema.properties.filter { if case .formula = $0.kind { true } else { false } }.count) в Notion")
        _ = try FormulaRecompute(store: store, databaseId: database.id).recomputeAll()
        for formula in formulas {
            let computed = try await store.database.dbWriter.read { db in
                try String.fetchAll(db, sql: "SELECT value FROM db_computed WHERE propertyId = ? ORDER BY rowId", arguments: [formula.id.databaseText])
            }
            print("LIVE формула «\(formula.name)»: значения после пересчёта = \(computed)")
            #expect(computed.count == 3)
        }
        let status = properties.first { $0.kind == .status }
        #expect(status != nil)
    }

    @Test("Без ключа и с неверным ключом схема не читается, причина названа понятно; сеть не нужна для первого случая")
    func failuresHaveReasons() async {
        let none = await NotionSchemaFetch(key: { nil }).fetch(databaseIds: [Self.databaseId])
        #expect(none.failures.map(\.reason) == [.noKey])
        let wrong = await NotionSchemaFetch(key: { "ntn_invalid_key_for_check" }).fetch(databaseIds: [Self.databaseId])
        print("LIVE неверный ключ: \(wrong.failures.map { $0.reason.explanation })")
        #expect(wrong.failures.map(\.reason) == [.invalidKey])
    }
}

enum LiveNotion {
    static let keyFile = ProcessInfo.processInfo.environment["MYNOTION_LIVE_NOTION_KEY_FILE"]
}
