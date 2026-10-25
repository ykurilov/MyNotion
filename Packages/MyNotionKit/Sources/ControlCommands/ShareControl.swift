import Foundation

/// Ссылка на страницу для чтения (006): `App/Sharing/ShareController.swift`. Ссылки идут через сервер синхронизации;
/// без неё — `nil` у хоста.
@MainActor
public protocol ShareControl: AnyObject {
    /// Ссылки работают только при включённой синхронизации.
    var isAvailable: Bool { get }
    /// `nil` — ссылку для страницы ни разу не включали.
    func shareLink(of pageId: UUID) async throws -> ShareLinkState?
    /// Включить (снимок публикуется сразу) или выключить; `includeSubpages` — `nil`, не менять.
    func setShareLink(of pageId: UUID, enabled: Bool, includeSubpages: Bool?) async throws -> ShareLinkState
    /// Новая ссылка; старая сразу перестаёт открываться.
    func rotateShareLink(of pageId: UUID) async throws -> ShareLinkState
}

/// Ссылка страницы для `page share`.
public struct ShareLinkState: Sendable, Hashable {
    public var url: URL
    public var enabled: Bool
    public var includeSubpages: Bool
    /// Последний снимок страницы уже на сервере.
    public var isPublished: Bool

    public init(url: URL, enabled: Bool, includeSubpages: Bool, isPublished: Bool) {
        self.url = url
        self.enabled = enabled
        self.includeSubpages = includeSubpages
        self.isPublished = isPublished
    }
}

extension ControlHost {
    public var shareControl: (any ShareControl)? { nil }
}
