import Foundation

/// Дополнения 003 к эталону замеров и галерее (quickstart.md, «Эталон»): каждая история добавляет свою часть
/// файлом `PagesNavigationSample+<История>.swift`; части будущих историй — заготовки `nil`.
/// Часть создаётся, только если её корневой страницы ещё нет.
public struct PagesNavigationSample: Sendable {
    /// Часть дополнений: название корневой страницы и как её записать.
    public struct Part: Sendable {
        public let title: String
        public let write: @Sendable (NotesTransaction, PagesNavigationSample) throws -> Void
    }

    /// Свойства блока-картинки (файл-образец кладёт приложение, `SampleMedia`).
    public let imageProps: BlockProps

    public init(imageProps: BlockProps) {
        self.imageProps = imageProps
    }

    public var parts: [Part] {
        [Self.copiesSource, Self.copiesTarget, Self.duplicationBranch, Self.covers, Self.favoritesAndRecents, Self.templates, Self.backlinks, Self.versions].compactMap { $0 }
    }

    public func ensure(in store: NotesStore) throws {
        let titles = Set(try store.pageOutline().filter { $0.trashedAt == nil && $0.parentId == nil }.map(\.title))
        for part in parts where !titles.contains(part.title) {
            try store.write { try part.write($0, self) }
        }
    }
}

extension PagesNavigationSample {
    public static let duplicationBranchTitle = "Замер: ветка для дублирования"

    /// Этап 0: ветка для дублирования — корень, 10 детей по 4 внука (50 подстраниц), у каждой 100 блоков, у первых
    /// десяти — по картинке; у родителей — ссылки на детей.
    static let duplicationBranch: Part? = Part(title: duplicationBranchTitle) { tx, sample in
        let root = try tx.createPage(title: duplicationBranchTitle, icon: "🌳")
        var subpage = 0
        func fill(_ page: Page, children: Int, depth: Int) throws {
            for block in try tx.blocks(ofPage: page.id) { try tx.deleteBlock(block.id) }
            var key: FractionalSortKey?
            func add(_ make: (FractionalSortKey) -> Block) throws {
                key = .between(key, nil)
                try tx.insertBlock(make(key!))
            }
            if page.id != root.id {
                subpage += 1
                let number = subpage
                for index in 0..<100 {
                    if index == 50, number <= 10 {
                        try add { Block(pageId: page.id, kind: .image, sortKey: $0, props: sample.imageProps) }
                    } else {
                        try add { Block(pageId: page.id, kind: index % 10 == 0 ? .heading2 : .paragraph,
                                        text: InlineText("Подстраница \(number), блок \(index + 1): текст для дублирования ветки."), sortKey: $0) }
                    }
                }
            }
            guard depth < 2 else { return }
            for child in 0..<children {
                let childPage = try tx.createPage(title: "Ветка \(depth + 1).\(child + 1)", parentId: page.id)
                try add { Block(pageId: page.id, kind: .pageLink, linkedPageId: childPage.id, sortKey: $0) }
                try fill(childPage, children: 4, depth: depth + 1)
            }
        }
        try fill(root, children: 10, depth: 0)
    }
}
