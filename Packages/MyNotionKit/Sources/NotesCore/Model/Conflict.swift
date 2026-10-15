import Foundation

/// Конфликт текста блока (data-model.md, «Conflict»): две версии, ни одна не потеряна; выбирает Юрий.
public struct Conflict: Sendable, Hashable, Identifiable {
    public let id: UUID
    public let blockId: UUID
    /// Версия этого Mac — она показана в окне.
    public var localVersion: InlineText
    /// Версия, которая к моменту записи уже лежала в базе.
    public var remoteVersion: InlineText
    /// С какого Mac пришла вторая версия.
    public var remoteDeviceName: String
    public var detectedAt: Date
    /// Пусто — ждёт выбора Юрия.
    public var resolvedAt: Date?

    public init(id: UUID = .timeOrdered(), blockId: UUID, localVersion: InlineText, remoteVersion: InlineText,
                remoteDeviceName: String, detectedAt: Date = Date(), resolvedAt: Date? = nil) {
        self.id = id
        self.blockId = blockId
        self.localVersion = localVersion
        self.remoteVersion = remoteVersion
        self.remoteDeviceName = remoteDeviceName
        self.detectedAt = detectedAt
        self.resolvedAt = resolvedAt
    }
}
