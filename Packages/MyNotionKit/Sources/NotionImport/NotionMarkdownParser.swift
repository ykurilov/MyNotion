import Foundation
import NotesCore

/// Что при разборе пришлось упростить до простого текста (FR-026). Название — для отчёта.
public enum NotionSimplification: String, CaseIterable, Sendable, Codable, Hashable {
    case table, file, quote, callout, code, toggle, divider, equation, embed

    public var title: String {
        switch self {
        case .table: "таблица"
        case .file: "файл или картинка"
        case .quote: "цитата"
        case .callout: "выноска"
        case .code: "блок кода"
        case .toggle: "переключатель"
        case .divider: "разделитель"
        case .equation: "формула"
        case .embed: "встраивание"
        }
    }
}

/// Блок после разбора: ещё не запись базы — без страницы, ключа порядка и меток часов.
public struct ParsedBlock: Sendable, Hashable {
    public var kind: BlockKind
    public var text: InlineText
    public var indent: Int
    public var isChecked: Bool
    /// Только у `.pageLink`: путь файла страницы из ссылки, раскодированный (`Папка/Страница.md`). Найдёт ли импорт
    /// такую страницу, разбор не знает: не нашёл — блок станет абзацем с названием.
    public var pagePath: String?
    /// Абзац — одна ссылка на адрес и ничего больше (например, на notion.so): импорт может узнать в нём страницу выгрузки.
    public var standaloneURL: URL?

    public init(kind: BlockKind, text: InlineText = .empty, indent: Int = 0, isChecked: Bool = false,
                pagePath: String? = nil, standaloneURL: URL? = nil) {
        self.kind = kind
        self.text = text
        self.indent = indent
        self.isChecked = isChecked
        self.pagePath = pagePath
        self.standaloneURL = standaloneURL
    }
}

/// Страница после разбора: название и иконка из первой строки `# 📘 Название`, блоки и что упрощено.
public struct ParsedNotionPage: Sendable, Hashable {
    public var title: String?
    public var icon: String?
    public var blocks: [ParsedBlock]
    public var simplifications: [NotionSimplification: Int]
}

/// Разбор подмножества Markdown, которое пишет Notion (и наша выгрузка), в блоки MyNotion по таблице
/// contracts/files-import-export.md (research R11).
public struct NotionMarkdownParser: Sendable {
    public init() {}

    public func parse(_ markdown: String) -> ParsedNotionPage {
        ParsedNotionPage(title: nil, icon: nil, blocks: [], simplifications: [:])
    }
}
