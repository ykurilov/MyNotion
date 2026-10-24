import Foundation
import NotesCore

/// Разобранные блоки → блоки страницы: ссылки на найденные страницы — pageLink (встроенная база — database),
/// на ненайденные — абзац с названием; ссылка на адрес отдельной строкой — закладка или видео; блок 002 с цветом,
/// свойствами и потоками внутри (колонки, таблица) — со своими потоками. Общий для импорта Notion и записи
/// страницы командой (005, research R7).
public enum ParsedBlockConverter {
    /// Куда ведёт блок-ссылка.
    public enum LinkTarget: Sendable, Hashable {
        case page(UUID)
        /// Встроенная база страницы — блок `database` на месте ссылки.
        case database(UUID)
    }

    /// `linkTarget` — страница блока-ссылки или абзаца из одной ссылки; `nil` — не ссылка или страницы нет.
    /// `mentionTarget` — страница упоминания по пути файла из текста; `nil` — название простым текстом.
    /// Ключи порядка — по порядку блоков, с начала потока.
    public static func blocks(from parsed: [ParsedBlock], pageId: UUID, linkTarget: (ParsedBlock) -> LinkTarget?,
                              mentionTarget: (String) -> UUID?) -> [Block] {
        var result: [Block] = []
        var sortKey: FractionalSortKey?
        func append(_ kind: BlockKind, _ text: InlineText = .empty, indent: Int = 0, checked: Bool = false, link: UUID? = nil) {
            sortKey = .between(sortKey, nil)
            // Заголовок бывает вложен в переключатель, выноску, цитату (research R1).
            result.append(Block(pageId: pageId, kind: kind, text: text, indent: indent,
                                isChecked: kind == .checkbox && checked, linkedPageId: link, sortKey: sortKey!))
        }
        /// Блок 002 с цветом, свойствами и потоками внутри (колонки, таблица).
        func appendRich(_ parsed: ParsedBlock) {
            sortKey = .between(sortKey, nil)
            let block = Block(id: parsed.id ?? .timeOrdered(), pageId: pageId, kind: parsed.kind, text: parsed.text, indent: parsed.indent,
                              isChecked: parsed.kind == .checkbox && parsed.isChecked, sortKey: sortKey!,
                              color: parsed.color, props: parsed.props)
            result.append(block)
            func appendContained(_ children: [ParsedBlock], in containerId: UUID) {
                var key: FractionalSortKey?
                for child in children {
                    key = .between(key, nil)
                    // Упоминания в ячейках таблицы и блоках колонок — как в потоке страницы.
                    let text = child.mentions.isEmpty ? child.text
                        : NotionImporter.resolvingMentions(in: child.text, mentions: child.mentions, pageId: mentionTarget)
                    let inner = Block(id: child.id ?? .timeOrdered(), pageId: pageId, kind: child.kind, text: text, indent: child.indent,
                                      isChecked: child.kind == .checkbox && child.isChecked, sortKey: key!, containerId: containerId,
                                      color: child.color, props: child.props)
                    result.append(inner)
                    appendContained(child.contained, in: inner.id)
                }
            }
            appendContained(parsed.contained, in: block.id)
        }
        for var block in parsed {
            if !block.mentions.isEmpty {
                block.text = NotionImporter.resolvingMentions(in: block.text, mentions: block.mentions, pageId: mentionTarget)
            }
            if let target = linkTarget(block) {
                switch target {
                case .page(let id): append(.pageLink, link: id)
                case .database(let id): append(.database, link: id)
                }
            } else if block.kind == .pageLink {
                append(.paragraph, block.text)
            } else if let url = block.standaloneURL, block.kind == .paragraph, ["http", "https"].contains(url.scheme?.lowercased()) {
                appendRich(NotionImporter.linkCard(for: url, text: block.text, indent: block.indent))
            } else if !block.color.isNone || !block.props.isEmpty || !block.contained.isEmpty {
                appendRich(block)
            } else {
                append(block.kind, block.text, indent: block.indent, checked: block.isChecked)
            }
        }
        return result
    }
}
