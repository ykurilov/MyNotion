import Foundation
import Synchronization
import Testing
@testable import NotionSchemaFetch

/// Чтение схемы по ключу (T106/T107): только `GET`, ключ — в заголовке и больше нигде, понятные причины отказа.
@Suite("Схема Notion: чтение по ключу")
struct SchemaFetchTests {
    private static let secret = "ntn_SECRET_KEY_FOR_TESTS"
    private static let tasksId = "a0000000000000000000000000000002"
    private static let projectsId = "a0000000000000000000000000000003"

    /// Сервер Notion в памяти: путь → (код, файл ответа). Запросы запоминаются.
    private final class FakeNotion: Sendable {
        let requests = Mutex<[URLRequest]>([])
        let sleeps = Mutex<[Double]>([])
        let answers: Mutex<[String: [(Int, String, [String: String])]]>

        init(_ answers: [String: [(Int, String, [String: String])]]) { self.answers = Mutex(answers) }

        func send(_ request: URLRequest) async throws -> (Data, URLResponse) {
            requests.withLock { $0.append(request) }
            let path = request.url!.path
            let next: (Int, String, [String: String])? = answers.withLock { all in
                guard var list = all[path], !list.isEmpty else { return nil }
                let first = list.count > 1 ? list.removeFirst() : list[0]
                all[path] = list
                return first
            }
            guard let (code, file, headers) = next else {
                return (Data("{}".utf8), HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!)
            }
            if file == "offline" { throw URLError(.notConnectedToInternet) }
            let response = HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: nil, headerFields: headers)!
            return (try Fixture.data(file), response)
        }
    }

    private func client(_ notion: FakeNotion, key: String? = secret) -> NotionSchemaFetch {
        NotionSchemaFetch(key: { key }, send: { try await notion.send($0) }, pause: { seconds in notion.sleeps.withLock { $0.append(seconds) } })
    }

    private func normal() -> FakeNotion {
        FakeNotion([
            "/v1/databases/\(Self.tasksId)": [(200, "import-tasks-database", [:])],
            "/v1/databases/\(Self.projectsId)": [(200, "import-projects-database", [:])],
            "/v1/data_sources/d0000000000000000000000000000002": [(200, "import-tasks-data-source", [:])],
            "/v1/data_sources/d0000000000000000000000000000003": [(200, "import-projects-data-source", [:])],
        ])
    }

    @Test("Две базы: схема каждой по её id; запросы — только GET к api.notion.com, ключ в заголовке, без тела")
    func fetchesTwoDatabases() async {
        let notion = normal()
        let result = await client(notion).fetch(databaseIds: [Self.tasksId, Self.projectsId])
        #expect(result.schemas.keys.sorted() == [Self.tasksId, Self.projectsId])
        #expect(result.schemas[Self.tasksId]?.title == "Задачи")
        #expect(result.schemas[Self.projectsId]?.property(named: "Всего часов") != nil)
        #expect(result.failures.isEmpty)
        let requests = notion.requests.withLock { $0 }
        #expect(requests.count == 4)
        #expect(requests.allSatisfy { $0.httpMethod == "GET" && $0.httpBody == nil && $0.httpBodyStream == nil })
        #expect(requests.allSatisfy { $0.url?.host == "api.notion.com" && $0.url?.scheme == "https" })
        #expect(requests.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == "Bearer \(Self.secret)" })
        #expect(requests.allSatisfy { $0.value(forHTTPHeaderField: "Notion-Version") == "2026-03-11" })
        #expect(requests.map { $0.url!.path } == ["/v1/databases/\(Self.tasksId)", "/v1/data_sources/d0000000000000000000000000000002",
                                                   "/v1/databases/\(Self.projectsId)", "/v1/data_sources/d0000000000000000000000000000003"])
    }

    @Test("Id с дефисами и в верхнем регистре приводится к 32 hex; повторы не запрашиваются дважды")
    func normalizedIds() async {
        let notion = normal()
        let result = await client(notion).fetch(databaseIds: ["A0000000-0000-0000-0000-000000000002", Self.tasksId])
        #expect(result.schemas.keys.sorted() == [Self.tasksId])
        #expect(notion.requests.withLock { $0.count } == 2)
    }

    @Test("Нет доступа к базе (404): причина у этой базы, остальные читаются")
    func noAccessToOne() async {
        let notion = normal()
        notion.answers.withLock { $0["/v1/databases/\(Self.projectsId)"] = [(404, "error-not-found", [:])] }
        let result = await client(notion).fetch(databaseIds: [Self.projectsId, Self.tasksId])
        #expect(result.schemas.keys.sorted() == [Self.tasksId])
        #expect(result.failures == [NotionSchemaFailure(databaseId: Self.projectsId, reason: .noAccess)])
        #expect(NotionSchemaFailure.Reason.noAccess.explanation.contains("Подключения"))
    }

    @Test("Ключ не принят (401): дальше не ходим, остальные базы получают ту же причину")
    func invalidKeyStops() async {
        let notion = FakeNotion(["/v1/databases/\(Self.tasksId)": [(401, "error-unauthorized", [:])]])
        let result = await client(notion).fetch(databaseIds: [Self.tasksId, Self.projectsId])
        #expect(result.schemas.isEmpty)
        #expect(result.failures == [NotionSchemaFailure(databaseId: Self.tasksId, reason: .invalidKey),
                                    NotionSchemaFailure(databaseId: Self.projectsId, reason: .invalidKey)])
        #expect(notion.requests.withLock { $0.count } == 1)
    }

    @Test("Ключа нет: в сеть не ходим вовсе")
    func noKey() async {
        let notion = normal()
        let result = await client(notion, key: nil).fetch(databaseIds: [Self.tasksId])
        #expect(result.failures == [NotionSchemaFailure(databaseId: Self.tasksId, reason: .noKey)])
        #expect(notion.requests.withLock { $0.isEmpty })
        let blank = await client(notion, key: "  ").fetch(databaseIds: [Self.tasksId])
        #expect(blank.failures.first?.reason == .noKey)
    }

    @Test("Нет сети: одна причина на все базы, остановка после первой")
    func offline() async {
        let notion = FakeNotion(["/v1/databases/\(Self.tasksId)": [(200, "offline", [:])]])
        let result = await client(notion).fetch(databaseIds: [Self.tasksId, Self.projectsId])
        #expect(result.failures.map(\.reason) == [.offline, .offline])
        #expect(notion.requests.withLock { $0.count } == 1)
    }

    @Test("Notion просит подождать (429): пауза по Retry-After и повтор; после трёх отказов — причина")
    func rateLimit() async {
        let notion = normal()
        notion.answers.withLock {
            $0["/v1/databases/\(Self.tasksId)"] = [(429, "error-not-found", ["Retry-After": "2"]), (200, "import-tasks-database", [:])]
        }
        let result = await client(notion).fetch(databaseIds: [Self.tasksId])
        #expect(result.schemas[Self.tasksId] != nil)
        #expect(notion.sleeps.withLock { $0 } == [2])

        let stuck = FakeNotion(["/v1/databases/\(Self.tasksId)": [(429, "error-not-found", ["Retry-After": "1"])]])
        let failed = await client(stuck).fetch(databaseIds: [Self.tasksId])
        #expect(failed.failures == [NotionSchemaFailure(databaseId: Self.tasksId, reason: .rateLimited)])
        #expect(stuck.requests.withLock { $0.count } == 4)
    }

    @Test("Ответ старой версии API (свойства прямо в базе) читается одним запросом")
    func oldStyleDatabase() async {
        let notion = FakeNotion(["/v1/databases/\(Self.tasksId)": [(200, "old-style-database", [:])]])
        let result = await client(notion).fetch(databaseIds: [Self.tasksId])
        #expect(result.schemas[Self.tasksId]?.property(named: "Name")?.kind == .title)
        #expect(notion.requests.withLock { $0.count } == 1)
    }

    @Test("Ключ не попадает ни в объяснения отказов, ни в описания ошибок")
    func keyNeverLeaks() async {
        let reasons: [NotionSchemaFailure.Reason] = [.noKey, .invalidKey, .noAccess, .offline, .rateLimited, .server(502), .unreadable]
        for reason in reasons {
            #expect(!reason.explanation.contains(Self.secret))
            #expect(!reason.explanation.isEmpty)
        }
        let notion = FakeNotion(["/v1/databases/\(Self.tasksId)": [(500, "error-unauthorized", [:])]])
        let result = await client(notion).fetch(databaseIds: [Self.tasksId])
        #expect(result.failures == [NotionSchemaFailure(databaseId: Self.tasksId, reason: .server(500))])
        #expect(!String(describing: result).contains(Self.secret))
    }

    @Test("Связь на источник данных: база-цель находится по id источника")
    func databaseOfDataSource() async {
        let notion = normal()
        let result = await client(notion).fetch(databaseIds: [Self.tasksId, Self.projectsId])
        #expect(result.databaseId(ofDataSource: "d0000000-0000-0000-0000-000000000003") == Self.projectsId)
        #expect(result.databaseId(ofDataSource: "nothing") == nil)
    }
}
