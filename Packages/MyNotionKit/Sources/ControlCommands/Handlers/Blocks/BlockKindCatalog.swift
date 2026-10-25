import ControlProtocol
import Foundation
import NotesCore

/// Описание видов блоков для `block kinds` (contracts/block-json.md, «Виды»): что вставляется командой и какие у вида
/// свойства (`props`). Порядок и состав — `CommandCatalog.insertableBlockKinds`.
enum BlockKindCatalog {
    struct Entry {
        let kind: BlockKind
        let summary: String
        let hasText: Bool
        let props: [String]
    }

    static let entries: [Entry] = [
        Entry(kind: .paragraph, summary: "Обычный абзац", hasText: true, props: []),
        Entry(kind: .heading1, summary: "Заголовок 1", hasText: true, props: []),
        Entry(kind: .heading2, summary: "Заголовок 2", hasText: true, props: []),
        Entry(kind: .heading3, summary: "Заголовок 3", hasText: true, props: []),
        Entry(kind: .quote, summary: "Цитата", hasText: true, props: []),
        Entry(kind: .bulletItem, summary: "Пункт маркированного списка", hasText: true, props: []),
        Entry(kind: .numberedItem, summary: "Пункт нумерованного списка", hasText: true, props: []),
        Entry(kind: .checkbox, summary: "Задача с галочкой (block check / uncheck)", hasText: true, props: []),
        Entry(kind: .toggle, summary: "Раскрывающийся список (block expand / collapse)", hasText: true, props: []),
        Entry(kind: .callout, summary: "Выноска с иконкой", hasText: true, props: ["icon"]),
        Entry(kind: .code, summary: "Код: текст как есть, без Markdown", hasText: true, props: ["language"]),
        Entry(kind: .equation, summary: "Формула LaTeX: текст как есть", hasText: true, props: []),
        Entry(kind: .divider, summary: "Разделитель", hasText: false, props: []),
        Entry(kind: .tableOfContents, summary: "Оглавление страницы", hasText: false, props: []),
        Entry(kind: .pageLink, summary: "Ссылка на новую подстраницу: текст — её название", hasText: true, props: []),
        Entry(kind: .image, summary: "Картинка по адресу; файл — mynotion attachment add", hasText: true, props: ["url"]),
        Entry(kind: .file, summary: "Файл; файл с диска — mynotion attachment add", hasText: true, props: ["url"]),
        Entry(kind: .video, summary: "Видео по адресу", hasText: true, props: ["url"]),
        Entry(kind: .bookmark, summary: "Закладка на сайт", hasText: true, props: ["url"]),
        Entry(kind: .table, summary: "Таблица: props.rows — строки ячеек, по умолчанию 2 столбца и 3 строки", hasText: false,
              props: ["rows", "hasHeaderRow", "hasHeaderColumn"]),
        Entry(kind: .columnList, summary: "Колонки: props.columns — от 2 до \(ColumnLayout.maximumColumns), по умолчанию 2", hasText: false,
              props: ["columns"]),
        Entry(kind: .database, summary: "Встроенная база создаётся командой mynotion db create", hasText: false, props: []),
    ]

    static var json: ControlJSON {
        .array(entries.map { entry in
            ["kind": .string(entry.kind.rawValue), "summary": .string(entry.summary), "hasText": .bool(entry.hasText),
             "canHaveChildren": .bool(entry.kind.canHaveChildren), "props": .array(entry.props.map(ControlJSON.string))]
        })
    }

    /// Виды без собственного текста: на `--text` и `--rich` они отвечают ошибкой.
    static let textless: Set<BlockKind> = Set(entries.filter { !$0.hasText }.map(\.kind))
}
