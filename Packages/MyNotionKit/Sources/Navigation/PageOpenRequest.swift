import Foundation

/// Просьба открыть страницу (research R5): из панели, поиска, ссылки, упоминания, недавних.
/// `inNewTab` — ⌘-щелчок; `revealBlockId` — после открытия перейти к блоку (поиск, обратные ссылки).
public struct PageOpenRequest: Sendable, Hashable {
    public var pageId: UUID
    public var inNewTab: Bool
    public var revealBlockId: UUID?

    public init(pageId: UUID, inNewTab: Bool = false, revealBlockId: UUID? = nil) {
        self.pageId = pageId
        self.inNewTab = inNewTab
        self.revealBlockId = revealBlockId
    }
}
