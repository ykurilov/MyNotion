import Foundation

/// Страница «MyNotion — образец» с тем же содержимым, что на снимках Notion
/// в `specs/001-core-pages-editor/visual-reference/`. Нужна для сверки внешнего вида.
public enum VisualSamplePage {
    public static let title = "MyNotion — образец"
    static let parentTitle = "Буфер"

    /// Создать образец, если его ещё нет; вернуть страницу образца.
    @discardableResult
    public static func ensure(in store: NotesStore) throws -> Page {
        if let existing = try store.pageOutline().first(where: { $0.title == title && $0.trashedAt == nil }) {
            return existing
        }
        return try store.write { transaction in
            let now = Date()
            func newPage(_ title: String, icon: String? = nil, parentId: UUID? = nil, after: FractionalSortKey? = nil) throws -> Page {
                let page = Page(title: title, icon: icon, parentId: parentId, sortKey: .between(after, nil), createdAt: now, updatedAt: now)
                try transaction.insertPage(page)
                return page
            }
            var lastRootKey: FractionalSortKey?
            for page in try store.pageOutline() where page.parentId == nil {
                lastRootKey = max(lastRootKey ?? page.sortKey, page.sortKey)
            }

            let parent = try newPage(parentTitle, after: lastRootKey)
            let sample = try newPage(title, icon: "📘", parentId: parent.id)
            let firstSubpage = try newPage("Подстраница первая", icon: "📝", parentId: sample.id)
            let secondSubpage = try newPage("Подстраница без иконки", parentId: sample.id, after: firstSubpage.sortKey)
            try transaction.insertBlock(Block(pageId: parent.id, kind: .pageLink, linkedPageId: sample.id, sortKey: .between(nil, nil)))
            try transaction.insertBlock(Block(pageId: firstSubpage.id, sortKey: .between(nil, nil)))
            try transaction.insertBlock(Block(pageId: secondSubpage.id, sortKey: .between(nil, nil)))

            var sortKey: FractionalSortKey?
            func add(_ kind: BlockKind, _ text: InlineText, indent: Int = 0, checked: Bool = false, linkedPageId: UUID? = nil) throws {
                sortKey = .between(sortKey, nil)
                try transaction.insertBlock(Block(
                    pageId: sample.id, kind: kind, text: text, indent: indent,
                    isChecked: checked, linkedPageId: linkedPageId, sortKey: sortKey!
                ))
            }

            try add(.paragraph, styledFirstParagraph)
            try add(.heading1, InlineText("Заголовок первого уровня"))
            try add(.paragraph, InlineText("Абзац под заголовком первого уровня."))
            try add(.heading2, InlineText("Заголовок второго уровня"))
            try add(.paragraph, InlineText("Абзац под заголовком второго уровня."))
            try add(.heading3, InlineText("Заголовок третьего уровня"))
            try add(.paragraph, InlineText("Абзац под заголовком третьего уровня."))
            try add(.bulletItem, InlineText("Первый пункт маркированного списка"))
            try add(.bulletItem, InlineText("Второй пункт"))
            try add(.bulletItem, InlineText("Вложенный пункт"), indent: 1)
            try add(.bulletItem, InlineText("Ещё глубже"), indent: 2)
            try add(.bulletItem, InlineText("Третий пункт"))
            try add(.numberedItem, InlineText("Первый пункт нумерованного списка"))
            try add(.numberedItem, InlineText("Второй пункт"))
            try add(.numberedItem, InlineText("Вложенный нумерованный"), indent: 1)
            try add(.numberedItem, InlineText("Третий пункт"))
            try add(.checkbox, InlineText("Невыполненная задача"))
            try add(.checkbox, InlineText("Выполненная задача"), checked: true)
            try add(.checkbox, InlineText("Задача со вложенной"))
            try add(.checkbox, InlineText("Вложенная задача"), indent: 1)
            try add(.paragraph, InlineText("Последний абзац страницы."))
            try add(.pageLink, .empty, linkedPageId: firstSubpage.id)
            try add(.pageLink, .empty, linkedPageId: secondSubpage.id)
            return sample
        }
    }

    /// «Обычный абзац текста. Здесь есть **жирный**, *курсив*, ~~зачёркнутый~~, `код в строке` и [ссылка](…). …»
    private static var styledFirstParagraph: InlineText {
        var string = "Обычный абзац текста. Здесь есть "
        var runs: [StyledRun] = []
        func append(_ fragment: String, _ style: InlineStyle? = nil) {
            if let style {
                runs.append(StyledRun(start: (string as NSString).length, length: (fragment as NSString).length, style: style))
            }
            string += fragment
        }
        append("жирный", .bold)
        append(", ")
        append("курсив", .italic)
        append(", ")
        append("зачёркнутый", .strikethrough)
        append(", ")
        append("код в строке", .code)
        append(" и ")
        append("ссылка", .link(URL(string: "https://www.notion.so")!))
        append(". Второе предложение, чтобы строка перенеслась и было видно межстрочный интервал в длинном абзаце.")
        return InlineText(string, runs: runs)
    }
}
