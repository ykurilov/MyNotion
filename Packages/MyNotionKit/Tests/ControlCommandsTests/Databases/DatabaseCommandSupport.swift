import ControlProtocol
import Databases
import Foundation
import Testing
@testable import ControlCommands
@testable import NotesCore

/// Хост с подписчиками записи, как у приложения: сравнимые колонки ячеек (фильтр, сортировка) и пересчёт формул и
/// сводок. Команды идут настоящим исполнителем со стандартными обработчиками.
@MainActor
final class DatabaseCommandFixture {
    let host: TestHost
    let queue: FormulaRecomputeQueue
    let executor: CommandExecutor
    let root: Page

    init() throws {
        host = try TestHost()
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        queue = FormulaRecomputeQueue(store: host.store, calendar: utc)
        host.store.addWriteHook(CellIndexer())
        host.store.addWriteHook(ComputationHook(store: host.store, queue: queue, calendar: utc))
        executor = CommandExecutor(host: host, log: RecordingLog())
        root = try host.page("Проекты", texts: ["вступление"])
    }

    var store: NotesStore { host.store }

    /// Ответ команды (`db.row.add` или `db row add`).
    func run(_ command: String, _ args: [String: ControlJSON] = [:]) async -> ControlResponse {
        await executor.run(ControlRequest(command: command, args: args))
    }

    /// `data` успешного ответа; ошибка — провал теста с её текстом.
    @discardableResult
    func ok(_ command: String, _ args: [String: ControlJSON] = [:], sourceLocation: SourceLocation = #_sourceLocation) async throws -> ControlJSON {
        let response = await run(command, args)
        #expect(response.ok, "\(command): \(response.error?.code.rawValue ?? "") \(response.error?.message ?? "")", sourceLocation: sourceLocation)
        return try #require(response.data, sourceLocation: sourceLocation)
    }

    /// Код ошибки неуспешного ответа.
    func failure(_ command: String, _ args: [String: ControlJSON] = [:], sourceLocation: SourceLocation = #_sourceLocation) async throws -> ControlError {
        let response = await run(command, args)
        #expect(!response.ok, "\(command) должна была не выполниться", sourceLocation: sourceLocation)
        return try #require(response.error, sourceLocation: sourceLocation)
    }

    /// База «Задачи» под «Проектами» командой `db create`.
    func createDatabase(_ title: String = "Задачи") async throws -> UUID {
        let data = try await ok("db.create", ["parent": .string(root.id.controlText), "title": .string(title)])
        return try #require(data["database"]?["id"]?.string.flatMap(UUID.init(uuidString:)))
    }

    func catalog(_ databaseId: UUID) throws -> DatabaseCatalog {
        try DatabaseCatalog.read(databaseId, in: store)
    }

    func property(_ name: String, in databaseId: UUID) throws -> DatabaseProperty {
        try #require(try catalog(databaseId).properties.first { $0.name == name })
    }

    func views(_ databaseId: UUID) throws -> [DatabaseView] {
        try ViewQuery.views(of: databaseId, in: store)
    }

    /// Живые строки базы по порядку создания.
    func rows(_ databaseId: UUID) throws -> [Page] {
        try store.pageOutline().filter { $0.parentId == databaseId && $0.trashedAt == nil }
    }

    func cell(_ rowId: UUID, _ propertyId: UUID) throws -> JSONValue? {
        try store.write { try $0.cell(rowId: rowId, propertyId: propertyId)?.value }
    }

    func computed(_ rowId: UUID, _ propertyId: UUID) throws -> JSONValue? {
        try RowWindowReader.read([rowId], catalog: try catalog(try #require(try host.stored(rowId)?.parentId)), store: store)[rowId]?.computed[propertyId]
    }

    /// Строки ответа `db rows` по всем группам подряд.
    static func rowTitles(_ data: ControlJSON) -> [String] {
        (data["groups"]?.array ?? []).flatMap { $0["rows"]?.array ?? [] }.compactMap { $0["title"]?.string }
    }
}
