import Foundation
import NotesCore

/// Страница в окне «@»: иконка, название и путь родителей (как выдача ⇧⌘F, 001).
public struct PageLookupResult: Sendable, Hashable {
    public var pageId: UUID
    public var title: String
    public var icon: String?
    public var path: [String]

    public init(pageId: UUID, title: String, icon: String?, path: [String]) {
        self.pageId = pageId
        self.title = title
        self.icon = icon
        self.path = path
    }
}

/// Поиск страниц для окна «@» и «[[». Приложение ищет по названиям через FTS5 (research R12); тесты подменяют.
@MainActor
public protocol PageLookup {
    /// До `limit` страниц, подходящих к `query`; пустой запрос — какие предложить сразу.
    func pages(matching query: String, limit: Int) -> [PageLookupResult]
}

/// Как показать упоминание: название и иконка страницы, «Удалённая страница» или «Страница загружается».
public struct MentionDisplay: Sendable, Hashable {
    public enum State: Sendable, Hashable { case page, deleted, loading }

    public var title: String
    public var icon: String?
    public var state: State
}

/// Справочник страниц для упоминаний (research R12): тот же источник, что у блоков-подстраниц. Название и иконка
/// в тексте не хранятся — их берёт отсюда вложение, поэтому переименование видно сразу.
public struct MentionDirectory: Sendable, Hashable {
    /// Страницы вне корзины.
    public var pages: [UUID: LinkedPage]
    public var trashedPageIds: Set<UUID>
    /// Страницы может ещё не быть на этом Mac (включена синхронизация): нет в справочнике — «Страница загружается».
    /// Без синхронизации её уже не будет — «Удалённая страница».
    public var expectsMissingPages: Bool
    /// Сделанные напоминания: просроченная дата с ними не красная.
    public var doneReminderIds: Set<UUID>

    public init(pages: [UUID: LinkedPage] = [:], trashedPageIds: Set<UUID> = [], expectsMissingPages: Bool = false,
                doneReminderIds: Set<UUID> = []) {
        self.pages = pages
        self.trashedPageIds = trashedPageIds
        self.expectsMissingPages = expectsMissingPages
        self.doneReminderIds = doneReminderIds
    }

    public static let loadingTitle = "Страница загружается"

    public func display(of pageId: UUID) -> MentionDisplay {
        if let page = pages[pageId], !trashedPageIds.contains(pageId) {
            return MentionDisplay(title: page.displayTitle, icon: page.icon, state: .page)
        }
        if trashedPageIds.contains(pageId) || !expectsMissingPages {
            return MentionDisplay(title: InlineText.deletedPageTitle, icon: nil, state: .deleted)
        }
        return MentionDisplay(title: Self.loadingTitle, icon: nil, state: .loading)
    }

    /// Название для простого текста; страницы нет — `nil` («Удалённая страница»).
    func plainTitle(of pageId: UUID) -> String? {
        let shown = display(of: pageId)
        return shown.state == .page ? shown.title : nil
    }
}
