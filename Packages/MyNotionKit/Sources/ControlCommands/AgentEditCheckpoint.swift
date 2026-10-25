import Foundation
import NotesCore
import PageVersions

/// Версия «до правки агента» (data-model.md): перед первой записью агента в страницу, если у неё нет такой версии
/// моложе 10 минут, — снять версию с именем агента. Вернуть всё, что сделал агент, — одной кнопкой «Восстановить».
/// Работа агента с паузами короче 10 минут — одна работа: срок считается от его последней правки, а не от версии.
@MainActor
public struct AgentEditCheckpoint {
    public static let freshness: TimeInterval = 600

    /// Снятый, но ещё не записанный вид страницы до правки.
    public struct Pending: Sendable {
        let content: PageContent
        let agent: String
        /// Автор вида до правки — Mac последней ещё не снятой правки; `nil` — этот Mac.
        let deviceName: String?
    }

    let host: any ControlHost

    public init(host: any ControlHost) {
        self.host = host
    }

    /// Вид страницы до правки — синхронно на главном потоке, без пауз до самой правки: ввод в окне, пришедший между
    /// снимком и правкой, не теряется при восстановлении. `nil` — свежая версия агента уже есть или страницы нет.
    /// `lastAgentWrite` — последняя удачная правка агента в эту страницу (с запуска приложения).
    public func capture(_ pageId: UUID, agent: String, lastAgentWrite: Date? = nil) throws -> Pending? {
        let now = host.now
        let latest = try host.versions.versions(ofPage: pageId).filter { $0.summary.agent != nil }.map(\.createdAt).max()
        if let latest, now.timeIntervalSince(max(latest, lastAgentWrite ?? latest)) < Self.freshness { return nil }
        // Незаписанный ввод в открытом окне — тоже «до правки агента»: сначала на диск, потом снимок.
        host.openDocuments.saveAll()
        let deviceName = try host.versions.dueMark(ofPage: pageId)?.deviceName
        return try host.store.pageContent(pageId).map { Pending(content: $0, agent: agent, deviceName: deviceName) }
    }

    /// Записать снятый вид версией (на очереди записывателя версий).
    public func record(_ pending: Pending) async throws {
        _ = try await host.versionRecorder.recordAgentCheckpoint(pending.content, agent: pending.agent, deviceName: pending.deviceName)
    }

    public func beforeWriting(_ pageId: UUID, agent: String) async throws {
        guard let pending = try capture(pageId, agent: agent) else { return }
        try await record(pending)
    }
}

/// Время последней удачной правки агентов по страницам — в памяти, на время работы приложения.
@MainActor
final class AgentWriteTimes {
    private var times: [UUID: Date] = [:]

    subscript(pageId: UUID) -> Date? { times[pageId] }

    func record(_ pageIds: Set<UUID>, at date: Date) {
        for id in pageIds { times[id] = date }
    }
}
