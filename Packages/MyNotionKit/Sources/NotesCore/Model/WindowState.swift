import Foundation

/// Вид окна (data-model.md, «WindowState»): локальный, не синхронизируется.
public struct WindowState: Sendable, Hashable {
    /// Главное окно приложения. Пока окно одно, его состояние хранится под этим id.
    public static let mainWindowId = UUID(uuidString: "00000000-0000-7000-8000-000000000001")!

    public let windowId: UUID
    public var openPageId: UUID?
    public var collapsedPageIds: Set<UUID>
    public var sidebarWidth: Double
    /// Боковая панель спрятана шторкой (⌘⌥S).
    public var isSidebarCollapsed: Bool
    /// Вкладки окна (003); пусто — одна вкладка с `openPageId`, как в 002.
    public var tabs: TabsState?
    /// Свёрнутые разделы панели (003).
    public var collapsedSidebarSections: Set<SidebarSectionID>

    public init(windowId: UUID, openPageId: UUID? = nil, collapsedPageIds: Set<UUID> = [], sidebarWidth: Double = 270,
                isSidebarCollapsed: Bool = false, tabs: TabsState? = nil, collapsedSidebarSections: Set<SidebarSectionID> = []) {
        self.windowId = windowId
        self.openPageId = openPageId
        self.collapsedPageIds = collapsedPageIds
        self.sidebarWidth = sidebarWidth
        self.isSidebarCollapsed = isSidebarCollapsed
        self.tabs = tabs
        self.collapsedSidebarSections = collapsedSidebarSections
    }
}

/// Вкладки окна, как они хранятся (data-model.md, «window_state.tabs»): `{active: индекс, items: [Tab]}`.
public struct TabsState: Sendable, Hashable, Codable {
    public var active: Int
    public var items: [Tab]

    public init(active: Int, items: [Tab]) {
        self.active = active
        self.items = items
    }
}

/// Вкладка: страница (пусто — «Новая вкладка»), место прокрутки и своя история «назад/вперёд» (до 50 записей).
public struct Tab: Sendable, Hashable, Codable, Identifiable {
    public var id: UUID
    public var pageId: UUID?
    public var scroll: TabScroll?
    public var back: [TabEntry]
    public var forward: [TabEntry]

    public static let historyLimit = 50

    public init(id: UUID = .timeOrdered(), pageId: UUID? = nil, scroll: TabScroll? = nil, back: [TabEntry] = [], forward: [TabEntry] = []) {
        self.id = id
        self.pageId = pageId
        self.scroll = scroll
        self.back = back
        self.forward = forward
    }
}

/// Запись истории вкладки: страница и место прокрутки.
public struct TabEntry: Sendable, Hashable, Codable {
    public var pageId: UUID
    public var scroll: TabScroll?

    public init(pageId: UUID, scroll: TabScroll? = nil) {
        self.pageId = pageId
        self.scroll = scroll
    }
}

/// Место прокрутки: блок у верха видимой области и сдвиг от его верха.
public struct TabScroll: Sendable, Hashable, Codable {
    public var blockId: UUID
    public var offset: Double

    public init(blockId: UUID, offset: Double) {
        self.blockId = blockId
        self.offset = offset
    }
}

/// Разделы боковой панели, которые можно свернуть (contracts/pages-ui.md, «Боковая панель»), по порядку сверху вниз.
public enum SidebarSectionID: String, Sendable, Hashable, Codable, CaseIterable {
    case recent
    case favorites
    case templates
    case pages
}
