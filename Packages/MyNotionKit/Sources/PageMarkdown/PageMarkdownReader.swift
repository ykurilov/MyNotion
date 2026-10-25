import Foundation
import MarkdownExport
import NotesCore

/// Страница → Markdown тем же `MarkdownBlockWriter`, что выгрузка, без строки названия (FR-413). Ссылки на страницы —
/// `mynotion://page/<id>`, файлы — полным путём копии во вложениях: `MarkdownBlocksBuilder` вернёт из них те же блоки (SC-404).
public struct PageMarkdownReader {
    public typealias PageTitle = (title: String, icon: String?)

    /// Название и иконка страницы ссылки или упоминания; `nil` — страницы нет, ссылка пропадает.
    private let pageTitle: (UUID) -> PageTitle?
    /// Путь файла вложения; `nil` — «[файл не скачан: имя]».
    private let attachmentPath: (AttachmentRef) -> String?

    public init(pageTitle: @escaping (UUID) -> PageTitle?, attachmentPath: @escaping (AttachmentRef) -> String?) {
        self.pageTitle = pageTitle
        self.attachmentPath = attachmentPath
    }

    /// `blocks` — блоки страницы всех потоков.
    public func markdown(for blocks: [Block]) -> String {
        MarkdownBlockWriter().markdown(for: blocks, resolveLink: { id in
            pageTitle(id).map { PageLinkTarget(title: $0.title, path: PageMarkdown.pageLink(id), icon: $0.icon) }
        }, resolveAttachment: attachmentPath)
    }
}
