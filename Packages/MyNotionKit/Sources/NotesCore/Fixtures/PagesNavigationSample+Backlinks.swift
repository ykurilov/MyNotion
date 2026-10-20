import Foundation

extension PagesNavigationSample {
    public static let backlinksTargetTitle = "Ссылки: цель"
    public static let backlinksPopularTitle = "Ссылки: популярная"

    /// US5: «цель» с тремя обратными ссылками — упоминание на «А», упоминание на «В», блок-ссылка на «Г»;
    /// «популярная» с 30 обратными ссылками (упоминания на страницах-детях «Ссылки: источники»).
    static let backlinks: Part? = Part(title: backlinksTargetTitle) { tx, _ in
        let target = try tx.createPage(title: backlinksTargetTitle, icon: "🎯")
        let popular = try tx.createPage(title: backlinksPopularTitle, icon: "⭐")

        func mention(_ prefix: String, of page: Page) -> InlineText {
            let start = (prefix as NSString).length
            return InlineText(prefix + "\u{FFFC}", runs: [StyledRun(start: start, length: 1, style: .mention(page.id))])
        }
        func fill(_ page: Page, with blocks: [(FractionalSortKey) -> Block]) throws {
            for block in try tx.blocks(ofPage: page.id) { try tx.deleteBlock(block.id) }
            var key: FractionalSortKey?
            for make in blocks {
                key = .between(key, nil)
                try tx.insertBlock(make(key!))
            }
        }

        let sourceA = try tx.createPage(title: "Ссылки: А")
        try fill(sourceA, with: [
            { Block(pageId: sourceA.id, text: InlineText("Первый абзац А"), sortKey: $0) },
            { Block(pageId: sourceA.id, text: mention("Смотри ", of: target), sortKey: $0) },
        ])
        let sourceB = try tx.createPage(title: "Ссылки: В")
        try fill(sourceB, with: [{ Block(pageId: sourceB.id, text: mention("Ещё раз ", of: target), sortKey: $0) }])
        let sourceG = try tx.createPage(title: "Ссылки: Г")
        try fill(sourceG, with: [
            { Block(pageId: sourceG.id, text: InlineText("Ссылка-страница ниже"), sortKey: $0) },
            { Block(pageId: sourceG.id, kind: .pageLink, linkedPageId: target.id, sortKey: $0) },
        ])

        let folder = try tx.createPage(title: "Ссылки: источники", icon: "📚")
        for index in 1...30 {
            let source = try tx.createPage(title: "Источник \(index)", parentId: folder.id)
            try fill(source, with: [{ Block(pageId: source.id, text: mention("Читай ", of: popular), sortKey: $0) }])
        }
    }
}
