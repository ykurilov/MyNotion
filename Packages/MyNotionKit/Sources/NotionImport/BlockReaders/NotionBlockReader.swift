import Foundation
import NotesCore

/// Разбор блока 002 из Markdown выгрузки (contracts/markdown-and-notion.md). Каждый тип — свой файл в `BlockReaders/`
/// и строка в `NotionBlockReaders.all`: этап, вводящий тип, не правит общий разбор. Читатели спрашиваются раньше
/// разбора 001, поэтому то, что 001 упрощал до текста (код, формулы, таблицы), они забирают себе.
protocol NotionBlockReader: Sendable {
    /// Если со строки `index` начинается блок этого типа — разобрать его. `nil` — строка не его.
    func read(_ lines: ArraySlice<String>, at index: Int) -> NotionBlockReading?
}

/// Что прочитал читатель: блоки по порядку и строка, с которой разбор продолжается.
struct NotionBlockReading {
    var blocks: [ParsedBlock]
    var nextIndex: Int
    /// Что упрощено внутри прочитанного (например, таблица в переключателе).
    var simplifications: [NotionSimplification: Int] = [:]
    /// Имена языков кода, которых MyNotion не знает: такой код стал «Простым текстом».
    var unknownCodeLanguages: [String] = []
}

enum NotionBlockReaders {
    static let all: [any NotionBlockReader] = [ToggleReader(), CalloutReader(), QuoteReader(), DividerReader(),
                                                CodeReader(), EquationReader(), TableOfContentsReader()]
}
