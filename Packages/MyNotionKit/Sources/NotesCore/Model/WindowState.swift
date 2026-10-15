import Foundation

/// Вид окна (data-model.md, «WindowState»): локальный, не синхронизируется.
public struct WindowState: Sendable, Hashable {
    /// Главное окно приложения. Пока окно одно, его состояние хранится под этим id.
    public static let mainWindowId = UUID(uuidString: "00000000-0000-7000-8000-000000000001")!

    public let windowId: UUID
    public var openPageId: UUID?
    public var collapsedPageIds: Set<UUID>
    public var sidebarWidth: Double

    public init(windowId: UUID, openPageId: UUID? = nil, collapsedPageIds: Set<UUID> = [], sidebarWidth: Double = 270) {
        self.windowId = windowId
        self.openPageId = openPageId
        self.collapsedPageIds = collapsedPageIds
        self.sidebarWidth = sidebarWidth
    }
}
