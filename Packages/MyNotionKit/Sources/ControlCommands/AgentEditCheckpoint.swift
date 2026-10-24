import Foundation
import NotesCore
import PageVersions

/// Версия «до правки агента» (data-model.md): перед первой записью агента в страницу, если у неё нет такой версии
/// моложе 10 минут, — снять версию с именем агента. Вернуть всё, что сделал агент, — одной кнопкой «Восстановить».
@MainActor
public struct AgentEditCheckpoint {
    public static let freshness: TimeInterval = 600

    let host: any ControlHost

    public init(host: any ControlHost) {
        self.host = host
    }

    public func beforeWriting(_ pageId: UUID, agent: String) async throws {
        let now = host.now
        let hasFresh = try host.versions.versions(ofPage: pageId).contains { version in
            version.summary.agent != nil && now.timeIntervalSince(version.createdAt) < Self.freshness
        }
        guard !hasFresh else { return }
        // Незаписанный ввод в открытом окне — тоже «до правки агента»: сначала на диск, потом снимок.
        host.openDocuments.saveAll()
        _ = try await host.versionRecorder.recordAgentCheckpoint(pageId, agent: agent)
    }
}
