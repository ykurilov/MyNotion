import Foundation

extension PagesNavigationSample {
    public static let copiesSourceTitle = "Копии: исходная"
    public static let copiesTargetTitle = "Копии: цель"

    /// US4: страница с переключателем и вложенными пунктами, двумя подстраницами, картинкой и файлом — для «Дублировать»
    /// и «Переместить в»; файл — та же картинка-образец, показанная строкой файла.
    static let copiesSource: Part? = Part(title: copiesSourceTitle) { tx, sample in
        let root = try tx.createPage(title: copiesSourceTitle, icon: "📦")
        for block in try tx.blocks(ofPage: root.id) { try tx.deleteBlock(block.id) }
        var key: FractionalSortKey?
        func add(_ kind: BlockKind = .paragraph, _ text: String = "", indent: Int = 0, linked: UUID? = nil, props: BlockProps = .empty) throws {
            key = .between(key, nil)
            try tx.insertBlock(Block(pageId: root.id, kind: kind, text: InlineText(text), indent: indent, linkedPageId: linked,
                                     sortKey: key!, props: props))
        }
        try add(.paragraph, "Начало")
        try add(.toggle, "Список")
        try add(.bulletItem, "пункт 1", indent: 1)
        try add(.bulletItem, "пункт 1.1", indent: 2)
        try add(.paragraph, "Конец")
        for title in ["Копии: подстраница А", "Копии: подстраница Б"] {
            let child = try tx.createPage(title: title, parentId: root.id)
            var first = try tx.blocks(ofPage: child.id)[0]
            first.text = InlineText("Текст: \(title)")
            try tx.updateBlock(first)
            try add(.pageLink, linked: child.id)
        }
        try add(.image, props: sample.imageProps)
        try add(.file, props: sample.imageProps)
    }

    /// US4: страница-цель для «Переместить в».
    static let copiesTarget: Part? = Part(title: copiesTargetTitle) { tx, _ in
        let page = try tx.createPage(title: copiesTargetTitle, icon: "🎯")
        var first = try tx.blocks(ofPage: page.id)[0]
        first.text = InlineText("Первый абзац цели")
        try tx.updateBlock(first)
    }
}
