import Foundation
import NotesCore

/// Страницы для снимков в симуляторе (`--sample-pages`): верхний уровень с иконками, подстраницы и страница с текстом.
@MainActor
enum SamplePages {
    static func addIfEmpty(to store: NotesStore) throws {
        guard try store.pageOutline().isEmpty else { return }
        let operations = PageTreeOperations(store: store)
        @discardableResult
        func page(_ title: String, _ icon: String, in parent: UUID? = nil) throws -> Page {
            let page = if let parent { try operations.createSubpage(in: parent, title: title) } else { try operations.createRootPage(title: title) }
            try operations.setIcon(page.id, to: icon)
            return page
        }
        let notes = try page("Заметки на неделю", "📝")
        let work = try page("Работа", "💼")
        try page("Планы на квартал", "🎯", in: work.id)
        try page("Встречи", "🗓️", in: work.id)
        try page("Идеи для курса", "💡", in: work.id)
        let home = try page("Дом", "🏡")
        try page("Покупки", "🛒", in: home.id)
        try page("Книги", "📚")
        try page("Путешествия", "✈️")
        try operations.createRootPage(title: "")
        try fill(notes.id, in: store)
    }

    /// Текст «Заметок на неделю»: заголовки, списки, чекбоксы и цитата — чтобы видно было, как страница читается.
    private static func fill(_ pageId: UUID, in store: NotesStore) throws {
        let lines: [(BlockKind, String, Bool)] = [
            (.paragraph, "Главное на эту неделю — закончить первую версию MyNotion для iPhone.", false),
            (.heading2, "Сделать", false),
            (.checkbox, "Подключить iPhone к синхронизации", true),
            (.checkbox, "Дерево страниц на главном экране", true),
            (.checkbox, "Выложить сборку в TestFlight", false),
            (.heading2, "Идеи", false),
            (.bulletItem, "Быстрая заметка с экрана блокировки", false),
            (.bulletItem, "Поиск по всем страницам", false),
            (.quote, "Лучшее приложение для заметок — то, которое всегда под рукой.", false),
        ]
        try store.write { transaction in
            // Новая страница начинается с пустого абзаца: он становится первой строкой.
            guard var first = try transaction.blocks(ofPage: pageId).first else { return }
            first.text = InlineText(lines[0].1)
            try transaction.updateBlock(first)
            var previous: FractionalSortKey? = first.sortKey
            for (kind, text, isChecked) in lines.dropFirst() {
                let key = FractionalSortKey.between(previous, nil)
                try transaction.insertBlock(Block(pageId: pageId, kind: kind, text: InlineText(text), isChecked: isChecked, sortKey: key))
                previous = key
            }
        }
    }
}
