import Foundation
import NotesCore

/// Страница-предок в пути над страницей: по нажатию открывается.
public struct BreadcrumbAncestor: Equatable, Identifiable, Sendable {
    public let pageId: UUID
    /// Иконка и название, как в пути.
    public let title: String
    public var id: UUID { pageId }

    public init(page: Page) {
        self.init(pageId: page.id, title: page.pathTitle)
    }

    public init(pageId: UUID, title: String) {
        self.pageId = pageId
        self.title = title
    }
}

/// Части пути над страницей в заданную ширину, как у Notion: предки нажимаются по одному, длинный путь —
/// «первый, …, последние два», текущая страница — последняя и не нажимается.
enum BreadcrumbPath {
    enum Part: Equatable {
        case page(BreadcrumbAncestor)
        /// «…»: спрятанные предки по порядку — в меню по нажатию.
        case hidden([BreadcrumbAncestor])
        case current(String)
    }

    static func parts(ancestors: [BreadcrumbAncestor], current: String, width: Double,
                      measure: (String) -> Double) -> [Part] {
        let full = ancestors.map(Part.page) + [.current(current)]
        if measure(text(of: full)) <= width { return full }

        // Первый, «…», последний предок и текущая: прячется всё между первым и последним предком.
        if ancestors.count >= 3 {
            let collapsed: [Part] = [.page(ancestors[0]), .hidden(Array(ancestors[1..<(ancestors.count - 1)])),
                                     .page(ancestors[ancestors.count - 1]), .current(current)]
            if measure(text(of: collapsed)) <= width { return collapsed }
        }

        // Не влезает и так — прячутся все предки после первого, название страницы обрезается.
        var head: [Part] = []
        if let first = ancestors.first { head.append(.page(first)) }
        if ancestors.count >= 2 { head.append(.hidden(Array(ancestors[1...]))) }
        let prefix = head.isEmpty ? "" : text(of: head) + BreadcrumbText.separator
        let title = BreadcrumbText.fitting([current], width: width - measure(prefix), measure: measure)
        return head + [.current(title)]
    }

    /// Строка, которой путь рисуется: части через « / ».
    private static func text(of parts: [Part]) -> String {
        parts.map { part in
            switch part {
            case .page(let ancestor): ancestor.title
            case .hidden: BreadcrumbText.ellipsis
            case .current(let title): title
            }
        }.joined(separator: BreadcrumbText.separator)
    }
}
