import Foundation
import NotesCore

/// Markdown одной строки тем же `InlineMarkdown`, что выгрузка (005: ответы команд, `text` блока).
public enum InlineMarkdownWriter {
    /// `pageLink` — куда ведёт упоминание страницы; `nil` — страницы нет, в тексте остаётся заглушка. `dateIds` — id дат
    /// в `<time data-id>`: разбор `InlineMarkdownReader` вернёт те же даты.
    public static func markdown(_ text: InlineText, pageLink: (UUID) -> PageLinkTarget? = { _ in nil }, dateIds: Bool = false) -> String {
        InlineMarkdown.render(text, resolveLink: pageLink, dateIds: dateIds)
    }
}
