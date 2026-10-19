import Foundation
import NotesCore

/// Запись блока 002 в Markdown (contracts/markdown-and-notion.md). Каждый тип — свой файл в `BlockWriters/`
/// и строка в `MarkdownBlockWriters.all`: этап, вводящий тип, не правит общую запись блоков.
protocol MarkdownBlockKindWriter: Sendable {
    var kinds: Set<BlockKind> { get }
    /// Писатель сам пишет вложенных под блоком (переключатель, цитата, выноска): они приходят готовым Markdown в `children`.
    var writesChildren: Bool { get }
    /// Строки блока без разделяющих пустых строк; `nil` — блок ничего не пишет.
    func lines(for block: Block, children: [String], context: MarkdownWriteContext) -> [String]?
}

extension MarkdownBlockKindWriter {
    var writesChildren: Bool { false }
}

/// Что писатель блока может спросить у выгрузки страницы.
struct MarkdownWriteContext {
    /// Блоки контейнера по порядку: колонки, блоки колонки, строки и столбцы таблицы, ячейки строки.
    let flow: (UUID) -> [Block]
    /// Markdown потока блоков — для колонок и других контейнеров.
    let render: ([Block]) -> String
    let resolveLink: (UUID) -> PageLinkTarget?
}

enum MarkdownBlockWriters {
    /// Писатели типов 002; у кого писателя нет, тот пишется текстом абзаца — текст не теряется.
    static let all: [any MarkdownBlockKindWriter] = [ToggleWriter(), QuoteWriter(), CalloutWriter(), DividerWriter(),
                                                     TableWriter(), ColumnsWriter()]

    private static let byKind: [BlockKind: any MarkdownBlockKindWriter] = Dictionary(
        all.flatMap { writer in writer.kinds.map { ($0, writer) } }, uniquingKeysWith: { first, _ in first })

    static func writer(for kind: BlockKind) -> (any MarkdownBlockKindWriter)? {
        byKind[kind]
    }
}
